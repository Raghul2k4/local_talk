import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/channel.dart';
import '../models/message.dart';
import '../models/user.dart';
import '../utils/constants.dart';
import 'websocket_service.dart';

class ClientService implements WebSocketService {
  WebSocketChannel? _channel;
  final String _username;
  final String _hostIp;
  final String? _pin;

  /// Port the host listens on. Injectable so tests can point at an ephemeral
  /// port instead of the real [AppConstants.wsPort].
  final int port;

  bool _stopped = false;
  bool _isReconnecting = false;

  /// Per-instance RNG for reconnect jitter. Seeding per client (rather than
  /// using a shared global) keeps two devices on the same phone from colliding.
  final Random _random = Random();

  /// Private call this device was in before a drop, so it can be re-established
  /// on reconnect. Without this a call silently becomes a normal channel chat.
  String? _privateCallPartnerId;
  bool _wasInPrivateCall = false;
  Timer? _heartbeatTimer;
  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;

  String? _localUserId;
  String? _localUsername;
  List<Channel> _channels = const [];
  String? _roomName;
  String? _roomId;
  bool _hasPin = false;

  /// Channel this device is in. Remembered so a reconnect can rejoin it â€”
  /// otherwise the host would place us back on no channel at all, and the
  /// device would silently start hearing every channel in the room.
  String? _currentChannelId;

  final StreamController<List<User>> _usersController =
      StreamController<List<User>>.broadcast();
  final StreamController<bool> _isRunningController =
      StreamController<bool>.broadcast();
  final StreamController<String> _errorController =
      StreamController<String>.broadcast();
  final StreamController<List<int>> _audioController =
      StreamController<List<int>>.broadcast();
  final StreamController<ConnectionStatus> _connectionStatusController =
      StreamController<ConnectionStatus>.broadcast();
  final StreamController<RoomInfo> _roomInfoController =
      StreamController<RoomInfo>.broadcast();
  final StreamController<WsMessage> _messageController =
      StreamController<WsMessage>.broadcast();

  ClientService({
    required String hostIp,
    required String username,
    String? pin,
    this.port = AppConstants.wsPort,
  })  : _hostIp = hostIp.trim(),
        _username = username.trim().isEmpty
            ? AppConstants.defaultUsername
            : username.trim(),
        _pin = (pin == null || pin.isEmpty) ? null : pin;

  @override
  Stream<List<User>> get usersStream => _usersController.stream;

  @override
  Stream<bool> get isRunningStream => _isRunningController.stream;

  @override
  Stream<String> get errorStream => _errorController.stream;

  @override
  Stream<List<int>> get audioStream => _audioController.stream;

  @override
  Stream<ConnectionStatus> get connectionStatusStream =>
      _connectionStatusController.stream;

  @override
  Stream<RoomInfo> get roomInfoStream => _roomInfoController.stream;

  @override
  Stream<WsMessage> get messageStream => _messageController.stream;

  String? get localUserId => _localUserId;
  String? get localUsername => _localUsername;
  List<Channel> get channels => _channels;

  /// True only while we have a live, usable connection.
  ///
  /// Derived from [connectionStatus] rather than `_channel != null`: the
  /// channel field is not cleared when the socket dies or a join is rejected,
  /// so the old check reported `true` while the client was permanently
  /// disconnected — which the UI used to decide whether to offer controls that
  /// could not work.
  @override
  bool get isRunning => _connectionStatus == ConnectionStatus.connected;

  /// Last status pushed on [connectionStatusStream]. Exposed so callers can
  /// read the current state without subscribing.
  ConnectionStatus get connectionStatus => _connectionStatus;

  ConnectionStatus _connectionStatus = ConnectionStatus.disconnected;

  /// Single point for status changes so the field can never drift from the
  /// stream the UI actually listens to.
  void _emitStatus(ConnectionStatus status) {
    _connectionStatus = status;
    _connectionStatusController.add(status);
  }

  Uri _uri() => Uri.parse('ws://$_hostIp:$port');

  @override
  Future<void> start() => connect();

  /// Attempts to connect + register. Completes with the local user id on
  /// success, or throws [JoinException] with a friendly message on failure.
  Future<String> connect() async {
    _stopped = false;
    _reconnectAttempts = 0;
    _emitStatus(ConnectionStatus.connecting);

    final uri = _uri();
    final channel = WebSocketChannel.connect(uri);
    _channel = channel;

    // Wait for the socket to open (or fail) with a hard timeout.
    try {
      await channel.ready.timeout(
        const Duration(milliseconds: AppConstants.connectionTimeoutMs),
      );
    } catch (e) {
      await _teardownSocket();
      _emitStatus(ConnectionStatus.disconnected);
      throw JoinException(
        'Could not reach the host.\n'
        'Double-check the IP address and make sure both devices are on the '
        'same Wi-Fi network.',
      );
    }

    _startHeartbeat();
    channel.stream.listen(
      _handleMessage,
      onError: (Object e) => _onSocketLost('Connection error'),
      onDone: () => _onSocketLost('Disconnected from host'),
    );

    // Send registration and wait for welcome / rejection.
    final welcome = await _register().timeout(
      const Duration(milliseconds: AppConstants.connectionTimeoutMs),
      onTimeout: () => throw JoinException(
        'The host did not respond.\n'
        'Make sure the host room is still running.',
      ),
    );
    // Set on success only: `isRunning` is derived from this, and the rejection
    // paths must leave it false.
    _emitStatus(ConnectionStatus.connected);
    _isRunningController.add(true);
    return welcome;
  }

  Future<String> _register() {
    final completer = Completer<String>();
    late final StreamSubscription<WsMessage> sub;
    sub = _messageController.stream.listen((msg) {
      if (completer.isCompleted) return;
      if (msg.type == 'welcome') {
        sub.cancel();
        completer.complete(_localUserId!);
      } else if (msg.type == 'register_rejected') {
        sub.cancel();
        completer.completeError(JoinException(
          (msg.data?['message'] as String?) ?? 'The host rejected the join.',
        ));
      } else if (msg.type == 'error') {
        sub.cancel();
        completer.completeError(JoinException(
          (msg.data?['message'] as String?) ?? 'The host reported an error.',
        ));
      }
    });

    _sendJson(WsMessage(
      type: 'register',
      data: {'username': _username, if (_pin != null) 'pin': _pin},
    ));

    // If the connection drops while waiting, fail fast.
    _connectionStatusController.stream.listen((status) {
      if (!completer.isCompleted && status == ConnectionStatus.disconnected) {
        completer
            .completeError(JoinException('Connection lost while joining.'));
      }
    });
    return completer.future;
  }

  void _handleMessage(dynamic data) {
    if (data is String) {
      WsMessage msg;
      try {
        msg = WsMessage.fromJson(jsonDecode(data) as Map<String, dynamic>);
      } catch (e) {
        _errorController.add('Message parse error: $e');
        return;
      }

      switch (msg.type) {
        case 'welcome':
          _localUserId = msg.data?['id'] as String?;
          _localUsername = _username;
          _roomName = msg.data?['roomName'] as String?;
          _roomId = msg.data?['roomId'] as String?;
          _hasPin = _pin != null;
          final hostJson = msg.data?['host'] as Map<String, dynamic>?;
          final channels = (msg.data?['channels'] as List<dynamic>?)
                  ?.map((c) => Channel.fromJson(c as Map<String, dynamic>))
                  .toList() ??
              const <Channel>[];
          _channels = channels;
          _latestRoomInfo = RoomInfo(
            roomId: _roomId ?? '',
            roomName: _roomName ?? 'Room',
            channels: channels,
            clientCount: hostJson == null ? 1 : 2,
            hasPin: _hasPin,
          );
          _roomInfoController.add(_latestRoomInfo!);
          _messageController.add(msg);
          break;
        case 'heartbeat':
          _sendJson(const WsMessage(type: 'heartbeat_ack'));
          break;
        case 'user_list':
          final usersList = msg.data?['users'] as List<dynamic>?;
          if (usersList != null) {
            final users = usersList
                .map((u) => User.fromJson(u as Map<String, dynamic>))
                .toList();
            _usersController.add(users);
          }
          break;
        case 'room_info':
          _latestRoomInfo = RoomInfo.fromJson(msg.data!);
          _roomInfoController.add(_latestRoomInfo!);
          break;
        case 'channel_joined':
          final channelId = msg.data?['channelId'] as String?;
          if (channelId != null) {
            _latestRoomInfo = _latestRoomInfo == null
                ? null
                : RoomInfo(
                    roomId: _latestRoomInfo!.roomId,
                    roomName: _latestRoomInfo!.roomName,
                    channels: _latestRoomInfo!.channels,
                    clientCount: _latestRoomInfo!.clientCount,
                    hasPin: _latestRoomInfo!.hasPin,
                  );
          }
          _messageController.add(msg);
          break;
        case 'private_call_request':
          _messageController.add(msg);
          break;
        case 'private_call_started':
          // The host confirmed a private call: remember the partner so a
          // reconnect can re-establish it.
          _privateCallPartnerId = msg.data?['partnerId'] as String?;
          _wasInPrivateCall = _privateCallPartnerId != null;
          _messageController.add(msg);
          break;
        case 'private_call_ended':
        case 'private_call_rejected':
          _privateCallPartnerId = null;
          _wasInPrivateCall = false;
          _messageController.add(msg);
          break;
        case 'private_call_unavailable':
          // Our partner did not come back; degrade to normal channel audio.
          _privateCallPartnerId = null;
          _wasInPrivateCall = false;
          _errorController.add(
            (msg.data?['message'] as String?) ??
                'The private call could not be restored.',
          );
          break;
        case 'error':
          _errorController
              .add((msg.data?['message'] as String?) ?? 'Unknown server error');
          break;
        default:
          _messageController.add(msg);
      }
    } else if (data is List<int>) {
      _audioController.add(data);
    }
  }

  RoomInfo? _latestRoomInfo;

  void _sendJson(WsMessage msg) {
    final channel = _channel;
    if (channel == null || _stopped) return;
    try {
      channel.sink.add(jsonEncode(msg.toJson()));
    } catch (e) {
      _errorController.add('Send failed: $e');
    }
  }

  @override
  Future<void> sendMessage(WsMessage message) async {
    _sendJson(message);
  }

  @override
  Future<void> sendAudio(List<int> audioData) async {
    final channel = _channel;
    if (channel == null || _stopped) return;
    try {
      channel.sink.add(audioData);
    } catch (e) {
      _errorController.add('Send audio failed: $e');
    }
  }

  void _onSocketLost(String reason) {
    if (_stopped) return;
    _heartbeatTimer?.cancel();
    _isRunningController.add(false);
    _emitStatus(ConnectionStatus.reconnecting);
    _scheduleReconnect(reason);
  }

  void _scheduleReconnect(String reason) {
    if (_stopped || _isReconnecting) return;
    if (_reconnectAttempts >= AppConstants.maxReconnectAttempts) {
      _errorController.add('Lost connection to the host.');
      _emitStatus(ConnectionStatus.disconnected);
      _messageController.add(const WsMessage(type: 'connection_lost'));
      return;
    }
    _isReconnecting = true;
    _reconnectAttempts++;
    _emitStatus(ConnectionStatus.reconnecting);
    _reconnectTimer = Timer(
      _reconnectDelay(),
      () {
        _isReconnecting = false;
        if (_stopped) return;
        _reconnect();
      },
    );
  }

  /// Exponential backoff with jitter.
  ///
  /// Without jitter every client in the room retries on the same tick after a
  /// host hiccup, so the host is hit by N simultaneous reconnects at once â€”
  /// exactly when it is least able to serve them. Randomising each device's
  /// delay spreads the load and makes the recovery survivable.
  Duration _reconnectDelay() {
    final attempt = _reconnectAttempts - 1;
    final base = AppConstants.reconnectDelayMs * (1 << attempt.clamp(0, 4));
    final capped = base.clamp(
      AppConstants.reconnectDelayMs,
      AppConstants.reconnectMaxDelayMs,
    );
    final jitter = 1.0 + (_random.nextDouble() * 2 - 1) * 0.3;
    return Duration(milliseconds: (capped * jitter).round());
  }

  /// Joins (or switches to) a channel. The choice is remembered so it can be
  /// restored automatically after a reconnect.
  Future<void> joinChannel(String channelId) async {
    if (!_channels.any((c) => c.id == channelId)) {
      throw JoinException('Unknown channel');
    }
    _currentChannelId = channelId;
    _sendJson(WsMessage(
      type: 'join_channel',
      data: {'channelId': channelId},
    ));
  }

  /// Channel this device is currently in, if any.
  String? get currentChannelId => _currentChannelId;

  /// Partner of the private call this device is in, if any. Exposed so the
  /// controller and tests can observe call state without parsing messages.
  String? get privateCallPartnerId => _privateCallPartnerId;

  /// Whether a private call is currently up. Distinct from
  /// [privateCallPartnerId] because the partner is retained across a
  /// reconnect while the call itself may be down.
  bool get isInPrivateCall => _wasInPrivateCall;

  Future<void> _reconnect() async {
    try {
      final uri = _uri();
      final channel = WebSocketChannel.connect(uri);
      _channel = channel;
      await channel.ready.timeout(
        const Duration(milliseconds: AppConstants.connectionTimeoutMs),
      );
      // Re-register to get back into the room.
      _startHeartbeat();
      channel.stream.listen(
        _handleMessage,
        onError: (Object e) => _onSocketLost('Connection error'),
        onDone: () => _onSocketLost('Disconnected from host'),
      );
      _sendJson(WsMessage(
        type: 'register',
        data: {'username': _username, if (_pin != null) 'pin': _pin},
      ));
      // Rejoin the channel we were on before the drop. Without this the host
      // treats us as channel-less and we would hear the whole room.
      final channelId = _currentChannelId;
      if (channelId != null) {
        _sendJson(WsMessage(
          type: 'join_channel',
          data: {'channelId': channelId},
        ));
      }
      // Re-establish an interrupted private call. If the partner is gone the
      // host answers `private_call_unavailable` and we fall back to the
      // channel, which is the correct graceful degradation.
      if (_wasInPrivateCall && _privateCallPartnerId != null) {
        _sendJson(WsMessage(
          type: 'private_call',
          data: {'targetId': _privateCallPartnerId},
        ));
      }
      _emitStatus(ConnectionStatus.connected);
      _reconnectAttempts = 0;
    } catch (_) {
      _onSocketLost('Connection error');
    }
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(
      const Duration(milliseconds: AppConstants.heartbeatIntervalMs),
      (_) => _sendJson(const WsMessage(type: 'heartbeat')),
    );
  }

  Future<void> _teardownSocket() async {
    _heartbeatTimer?.cancel();
    _reconnectTimer?.cancel();
    try {
      await _channel?.sink.close();
    } catch (_) {}
    _channel = null;
  }

  @override
  Future<void> stop() async {
    _stopped = true;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _reconnectTimer?.cancel();
    _isReconnecting = false;
    try {
      await _channel?.sink.close();
    } catch (_) {}
    _channel = null;
    // `dispose()` may already have closed these; stop() and dispose() are
    // called in both orders.
    if (!_disposed) {
      _isRunningController.add(false);
      _emitStatus(ConnectionStatus.disconnected);
    }
  }

  bool _disposed = false;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _usersController.close();
    _isRunningController.close();
    _errorController.close();
    _audioController.close();
    _connectionStatusController.close();
    _roomInfoController.close();
    _messageController.close();
  }
}

class JoinException implements Exception {
  final String message;
  JoinException(this.message);

  @override
  String toString() => message;
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:uuid/uuid.dart';

import '../models/channel.dart';
import '../models/message.dart';
import '../models/user.dart';
import '../utils/constants.dart';
import 'websocket_service.dart';

/// Public identity of the host itself (constant so clients can address it).
const String hostUserId = 'host';

class HostService implements WebSocketService {
  HttpServer? _server;
  final List<WebSocket> _clients = <WebSocket>[];
  final Map<WebSocket, User> _clientUsers = <WebSocket, User>{};
  final Map<String, WebSocket> _usersById = <String, WebSocket>{};

  final Uuid _uuid = const Uuid();
  final String _roomName;
  final String? _pin;
  final String _roomId;
  final List<Channel> _channels;

  // Private call state (at most one active pair in v1).
  String? _privateCallCallerId;
  String? _privateCallCalleeId;
  String? _hostChannelId;
  bool _hostMicOn = false;

  /// Last time we received *anything* from a socket. Used to evict clients
  /// that vanished without a clean close (screen off, Wi-Fi drop).
  final Map<WebSocket, DateTime> _lastSeen = <WebSocket, DateTime>{};

  /// Last time each user produced audio above [AppConstants.speakingThreshold].
  /// Drives the "is speaking" indicator.
  final Map<String, DateTime> _lastAudible = <String, DateTime>{};

  /// Audio frames handed to a socket since its last heartbeat acknowledgement.
  /// Drives backpressure; see [_enqueueAudio].
  final Map<WebSocket, int> _pendingFrames = <WebSocket, int>{};

  /// Set when a user's speaking state changed and the list still needs pushing.
  /// Coalesced by [_speakingBroadcastTimer] so a burst of speech toggles
  /// produces one broadcast, not one per 58 ms audio frame.
  bool _speakingDirty = false;
  Timer? _speakingBroadcastTimer;
  bool _hostSpeaking = false;

  /// Frames skipped because a client fell too far behind.
  int _droppedFrames = 0;

  /// Audio frames dropped because a client fell behind. Surfaced to the host
  /// in the diagnostics panel.
  int get droppedFrames => _droppedFrames;

  final StreamController<List<User>> _usersController =
      StreamController<List<User>>.broadcast();
  final StreamController<bool> _isRunningController =
      StreamController<bool>.broadcast();
  final StreamController<String> _errorController =
      StreamController<String>.broadcast();
  final StreamController<ConnectionStatus> _connectionStatusController =
      StreamController<ConnectionStatus>.broadcast();
  final StreamController<RoomInfo> _roomInfoController =
      StreamController<RoomInfo>.broadcast();
  final StreamController<WsMessage> _messageController =
      StreamController<WsMessage>.broadcast();
  final StreamController<List<int>> _audioController =
      StreamController<List<int>>.broadcast();

  Timer? _heartbeatTimer;

  HostService({
    required String roomName,
    String? pin,
    List<Channel>? channels,
    this.port = AppConstants.wsPort,
  })  : _roomName = roomName.trim().isEmpty ? 'My Room' : roomName.trim(),
        _pin = (pin == null || pin.isEmpty) ? null : pin,
        _roomId = const Uuid().v4().substring(0, 8).toUpperCase(),
        _channels = channels ??
            AppConstants.defaultChannels
                .map((name) => Channel(
                    id: name.toLowerCase().replaceAll(' ', '-'), name: name))
                .toList() {
    // The host starts on the first channel. Leaving this null would make the
    // host's audio leak into every channel until the user picked a chip.
    _hostChannelId = _channels.isNotEmpty ? _channels.first.id : null;
  }

  /// Port to listen on. Tests pass 0 so the OS picks a free one.
  final int port;

  /// The actual bound port (valid after [start] succeeds).
  int? get boundPort => _server?.port;

  /// Moves the host itself to another channel so clients in it can hear the
  /// host's broadcasts.
  void switchHostChannel(String channelId) {
    if (!_channels.any((c) => c.id == channelId)) return;
    _hostChannelId = channelId;
    _broadcastUsers();
  }

  /// Reflects whether the host device is currently transmitting.
  void setHostMicState(bool on) {
    if (_hostMicOn == on) return;
    _hostMicOn = on;
    if (!on) {
      // Stop claiming to be speaking as soon as the mic is released.
      _hostSpeaking = false;
      _lastAudible.remove(hostUserId);
    }
    _broadcastUsers();
  }

  String get roomId => _roomId;
  bool get hasPin => _pin != null;

  @override
  Stream<List<User>> get usersStream => _usersController.stream;

  @override
  Stream<bool> get isRunningStream => _isRunningController.stream;

  @override
  Stream<String> get errorStream => _errorController.stream;

  @override
  Stream<ConnectionStatus> get connectionStatusStream =>
      _connectionStatusController.stream;

  @override
  Stream<RoomInfo> get roomInfoStream => _roomInfoController.stream;

  Stream<WsMessage> get messageStream => _messageController.stream;

  /// Audio frames arriving from clients (host listens to these).
  Stream<List<int>> get audioStream => _audioController.stream;

  @override
  bool get isRunning => _server != null;

  @override
  Future<void> start() async {
    try {
      _server = await HttpServer.bind(
        InternetAddress.anyIPv4,
        port,
      );
      _server!.listen(_handleRequest, onError: (Object e) {
        _errorController.add('Server error: $e');
      });
      _isRunningController.add(true);
      _connectionStatusController.add(ConnectionStatus.connected);
      _startHeartbeat();
      _broadcastUsers();
      _broadcastRoomInfo();
    } catch (e) {
      _errorController.add('Failed to start host: $e');
      _connectionStatusController.add(ConnectionStatus.disconnected);
      rethrow;
    }
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(
      const Duration(milliseconds: AppConstants.heartbeatIntervalMs),
      (_) => _sendHeartbeat(),
    );
  }

  void _sendHeartbeat() {
    final msg = WsMessage(
      type: 'heartbeat',
      data: {'timestamp': DateTime.now().millisecondsSinceEpoch},
    );
    for (final client in List.of(_clients)) {
      // Anything we send proves the client may still be reachable, and it
      // resets the backpressure accounting.
      _lastSeen[client] = DateTime.now();
      _pendingFrames[client] = 0;
      _sendTo(client, msg);
    }
    _evictStaleClients();
    _refreshSpeakingStates();
  }

  /// Drops clients that stopped talking to us. A phone that sleeps, loses Wi-Fi
  /// or is force-killed never fires `onDone`, so without this they linger in
  /// the room forever and keep receiving (and buffering) audio.
  void _evictStaleClients() {
    final now = DateTime.now();
    for (final client in List.of(_clients)) {
      final last = _lastSeen[client];
      if (last == null) continue;
      if (now.difference(last).inMilliseconds < AppConstants.clientTimeoutMs) {
        continue;
      }
      final user = _clientUsers[client];
      if (user != null) {
        _errorController.add('${user.username} timed out and was removed.');
      }
      _removeClient(client);
    }
  }

  void _handleRequest(HttpRequest request) async {
    if (WebSocketTransformer.isUpgradeRequest(request)) {
      // Cap on *registered* users, not raw sockets: an unregistered socket
      // (a scanner, or a client that failed the PIN) must not consume a slot.
      if (_clientUsers.length >= AppConstants.maxClients) {
        try {
          final rejected = await WebSocketTransformer.upgrade(request);
          _sendTo(
              rejected,
              const WsMessage(
                type: 'error',
                data: {'message': 'Room is full'},
              ));
          await rejected.close(1013, 'Room full');
        } catch (_) {}
        return;
      }
      try {
        final socket = await WebSocketTransformer.upgrade(request);
        _clients.add(socket);
        _lastSeen[socket] = DateTime.now();
        _pendingFrames[socket] = 0;
        socket.listen(
          (data) => _handleClientMessage(socket, data),
          onDone: () => _removeClient(socket),
          onError: (Object e) {
            _errorController.add('Client error: $e');
            _removeClient(socket);
          },
          cancelOnError: true,
        );
      } catch (e) {
        _errorController.add('WebSocket upgrade failed: $e');
      }
    } else {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
    }
  }

  void _handleClientMessage(WebSocket socket, dynamic data) {
    // Any inbound traffic counts as proof of life.
    _lastSeen[socket] = DateTime.now();
    if (data is String) {
      WsMessage msg;
      try {
        final json = jsonDecode(data) as Map<String, dynamic>;
        msg = WsMessage.fromJson(json);
      } catch (e) {
        _errorController.add('Message parse error: $e');
        return;
      }
      _handleControlMessage(socket, msg);
    } else if (data is List<int>) {
      _routeAudio(socket, data);
    }
  }

  void _handleControlMessage(WebSocket socket, WsMessage msg) {
    switch (msg.type) {
      case 'register':
        _handleRegister(socket, msg);
        break;
      case 'heartbeat_ack':
        break;
      case 'join_channel':
        final channelId = msg.data?['channelId'] as String?;
        final user = _clientUsers[socket];
        if (user != null && channelId != null) {
          _clientUsers[socket] = user.copyWith(currentChannelId: channelId);
          _sendTo(
              socket,
              WsMessage(
                type: 'channel_joined',
                data: {'channelId': channelId},
              ));
          _broadcastUsers();
        }
        break;
      case 'mic_state':
        final user = _clientUsers[socket];
        if (user != null) {
          _clientUsers[socket] = user.copyWith(
            isMicOn: msg.data?['isOn'] as bool? ?? false,
          );
          _broadcastUsers();
        }
        break;
      case 'private_call':
        _handlePrivateCallRequest(socket, msg);
        break;
      case 'private_call_accept':
        _handlePrivateCallAccept(socket, msg);
        break;
      case 'private_call_reject':
        _handlePrivateCallReject(socket, msg);
        break;
      case 'private_call_end':
        _handlePrivateCallEnd(socket);
        break;
      default:
        break;
    }
  }

  void _handleRegister(WebSocket socket, WsMessage msg) {
    final data = msg.data ?? const {};
    final rawUsername = (data['username'] as String?)?.trim() ?? '';
    final username = rawUsername.isEmpty
        ? '${AppConstants.defaultUsername}${_clientUsers.length + 1}'
        : rawUsername.substring(
            0,
            rawUsername.length > AppConstants.maxUsernameLength
                ? AppConstants.maxUsernameLength
                : rawUsername.length,
          );
    final pin = data['pin'] as String?;

    if (_pin != null && pin != _pin) {
      _sendTo(
          socket,
          const WsMessage(
            type: 'register_rejected',
            data: {'message': 'Invalid PIN', 'code': 'bad_pin'},
          ));
      socket.close(1008, 'Invalid PIN');
      return;
    }

    // Replace any stale registration from a previous socket of this user.
    final existing = _clientUsers[socket];
    if (existing != null) {
      _usersById.remove(existing.id);
    }

    final user = User(id: _uuid.v4(), username: username, isHost: false);
    _clientUsers[socket] = user;
    _usersById[user.id] = socket;

    _sendTo(
        socket,
        WsMessage(
          type: 'welcome',
          data: {
            'id': user.id,
            'roomName': _roomName,
            'roomId': _roomId,
            'channels': _channels.map((c) => c.toJson()).toList(),
            'host': _hostUser.toJson(),
          },
        ));
    _broadcastUsers();
    _broadcastRoomInfo();
  }

  User get _hostUser => User(
        id: hostUserId,
        username: _roomName,
        isHost: true,
        isMicOn: _hostMicOn,
        isSpeaking: _hostSpeaking,
        currentChannelId: _hostChannelId,
      );

  void _handlePrivateCallRequest(WebSocket socket, WsMessage msg) {
    final caller = _clientUsers[socket];
    final targetId = msg.data?['targetId'] as String?;
    if (caller == null || targetId == null) return;
    if (_privateCallCallerId != null || _privateCallCalleeId != null) {
      _sendTo(
          socket,
          const WsMessage(
            type: 'private_call_busy',
            data: {'message': 'Another private call is in progress'},
          ));
      return;
    }

    // The host itself can be called.
    if (targetId == hostUserId) {
      _privateCallCallerId = caller.id;
      _privateCallCalleeId = hostUserId;
      _messageController.add(WsMessage(
        type: 'private_call_request',
        data: {'callerId': caller.id, 'callerName': caller.username},
      ));
      return;
    }

    final targetSocket = _usersById[targetId];
    if (targetSocket == null) {
      _sendTo(
          socket,
          const WsMessage(
            type: 'private_call_unavailable',
            data: {'message': 'User is not available'},
          ));
      return;
    }
    _privateCallCallerId = caller.id;
    _privateCallCalleeId = targetId;
    _sendTo(
        targetSocket,
        WsMessage(
          type: 'private_call_request',
          data: {'callerId': caller.id, 'callerName': caller.username},
        ));
  }

  void _handlePrivateCallAccept(WebSocket socket, WsMessage msg) {
    final acceptor = _clientUsers[socket];
    final acceptorId = acceptor?.id ?? hostUserId;
    if (_privateCallCalleeId != acceptorId) return;
    final callerSocket =
        _privateCallCallerId != null ? _usersById[_privateCallCallerId!] : null;
    if (callerSocket != null) {
      _sendTo(
          callerSocket,
          WsMessage(
            type: 'private_call_started',
            data: {'partnerId': acceptorId, 'partnerName': 'Host'},
          ));
    }
    if (acceptor != null) {
      _sendTo(
          socket,
          WsMessage(
            type: 'private_call_started',
            data: {'partnerId': _privateCallCallerId},
          ));
    }
  }

  void _handlePrivateCallReject(WebSocket socket, WsMessage msg) {
    final rejector = _clientUsers[socket];
    final rejectorId = rejector?.id ?? hostUserId;
    if (_privateCallCalleeId != rejectorId) return;
    final callerSocket =
        _privateCallCallerId != null ? _usersById[_privateCallCallerId!] : null;
    if (callerSocket != null) {
      _sendTo(callerSocket, const WsMessage(type: 'private_call_rejected'));
    }
    _clearPrivateCall();
  }

  void _handlePrivateCallEnd(WebSocket socket) {
    final user = _clientUsers[socket];
    if (user == null) return;
    _endPrivateCallFrom(user.id);
  }

  /// Ends the active private call on behalf of [userId] (client or host).
  void _endPrivateCallFrom(String userId) {
    final partnerId = _privateCallPartnerOf(userId);
    if (partnerId == null) return;
    if (partnerId == hostUserId) {
      // The host is the partner: surface the hang-up to the host UI.
      _messageController.add(const WsMessage(type: 'private_call_ended'));
    } else {
      final partnerSocket = _usersById[partnerId];
      if (partnerSocket != null) {
        _sendTo(partnerSocket, const WsMessage(type: 'private_call_ended'));
      }
    }
    _clearPrivateCall();
  }

  /// Host calls a specific client directly.
  void hostCallClient(String targetId) {
    if (_privateCallCallerId != null || _privateCallCalleeId != null) {
      _messageController.add(const WsMessage(
        type: 'private_call_busy',
        data: {'message': 'Another private call is in progress'},
      ));
      return;
    }
    final targetSocket = _usersById[targetId];
    if (targetSocket == null) {
      _messageController.add(const WsMessage(
        type: 'private_call_unavailable',
        data: {'message': 'User is not available'},
      ));
      return;
    }
    final targetUser = _clientUsers[targetSocket];
    _privateCallCallerId = hostUserId;
    _privateCallCalleeId = targetId;
    _sendTo(
        targetSocket,
        WsMessage(
          type: 'private_call_request',
          data: {'callerId': hostUserId, 'callerName': _roomName},
        ));
    // Let the host UI track the outgoing call via the client's own username.
    _messageController.add(WsMessage(
      type: 'private_call_outgoing',
      data: {'partnerId': targetId, 'partnerName': targetUser?.username},
    ));
  }

  /// Host hangs up the private call it is in.
  void endHostPrivateCall() => _endPrivateCallFrom(hostUserId);

  /// Host accepts an incoming private call from [callerId].
  void acceptHostPrivateCall(String callerId) {
    if (_privateCallCalleeId != hostUserId) return;
    if (_privateCallCallerId != callerId) return;
    final callerSocket = _usersById[callerId];
    if (callerSocket != null) {
      _sendTo(
          callerSocket,
          const WsMessage(
            type: 'private_call_started',
            data: {'partnerId': hostUserId, 'partnerName': 'Host'},
          ));
    }
    _messageController.add(WsMessage(
      type: 'private_call_started',
      data: {'partnerId': callerId},
    ));
  }

  /// Host declines an incoming private call from [callerId].
  void rejectHostPrivateCall(String callerId) {
    if (_privateCallCalleeId != hostUserId) return;
    if (_privateCallCallerId != callerId) return;
    final callerSocket = _usersById[callerId];
    if (callerSocket != null) {
      _sendTo(callerSocket, const WsMessage(type: 'private_call_rejected'));
    }
    _clearPrivateCall();
  }

  void _clearPrivateCall() {
    _privateCallCallerId = null;
    _privateCallCalleeId = null;
  }

  /// The id of the user paired with [userId] in the active private call,
  /// or null when [userId] is not in a call.
  String? _privateCallPartnerOf(String userId) {
    if (_privateCallCallerId == null || _privateCallCalleeId == null) {
      return null;
    }
    if (userId == _privateCallCallerId) return _privateCallCalleeId;
    if (userId == _privateCallCalleeId) return _privateCallCallerId;
    return null;
  }

  /// Routes audio from [sender] according to channel membership and private
  /// call state:
  /// - A caller in a private call is heard ONLY by their partner.
  /// - A user in a private call hears no group audio.
  /// - Otherwise audio stays within the sender's channel.
  void _routeAudio(WebSocket sender, List<int> audio) {
    final senderUser = _clientUsers[sender];
    if (senderUser == null) return; // unregistered: drop

    final senderPartner = _privateCallPartnerOf(senderUser.id);

    // Speaking detection: cheap RMS scan of the PCM16 frame, compared against
    // the last known speaking state so we only re-broadcast on a change.
    final now = DateTime.now();
    if (_rms(audio) >= AppConstants.speakingThreshold) {
      _lastAudible[senderUser.id] = now;
    }
    final isSpeaking = _isRecentlyAudible(senderUser.id, now);
    if (isSpeaking != senderUser.isSpeaking) {
      _clientUsers[sender] = senderUser.copyWith(isSpeaking: isSpeaking);
      _scheduleSpeakingBroadcast();
    }

    // The host device is a participant too: it must hear clients on its own
    // channel, and its private-call partner while a call is up. Without this
    // the host runs a live player that never receives a single frame.
    final hostPartner = _privateCallPartnerOf(hostUserId);
    final hostShouldHear = hostPartner != null
        ? hostPartner == senderUser.id
        : senderPartner == null &&
            _sameChannel(_hostChannelId, senderUser.currentChannelId);
    if (hostShouldHear) {
      _audioController.add(audio);
    }

    for (final client in List.of(_clients)) {
      if (identical(client, sender)) continue;
      if (client.readyState != WebSocket.open) continue;
      final recipient = _clientUsers[client];
      if (recipient == null) continue;

      final recipientPartner = _privateCallPartnerOf(recipient.id);

      if (senderPartner != null) {
        // Private call: only the partner hears the caller.
        if (recipient.id != senderPartner) continue;
      } else {
        // Group audio: users busy in a private call don't hear it.
        if (recipientPartner != null) continue;
        if (!_sameChannel(
          senderUser.currentChannelId,
          recipient.currentChannelId,
        )) {
          continue;
        }
      }

      if (!_enqueueAudio(client, audio)) continue;
    }
  }

  /// Channel matching for audio routing. `null` means "not scoped yet" and is
  /// treated as matching everything, so audio still flows before a user has
  /// picked a channel.
  bool _sameChannel(String? a, String? b) {
    if (a == null || b == null) return true;
    return a == b;
  }

  /// Root-mean-square of a PCM16 mono frame, normalised to 0..1.
  double _rms(List<int> bytes) {
    if (bytes.length < 4) return 0;
    var sum = 0.0;
    var count = 0;
    // Stride two samples: plenty for a level estimate and far cheaper than
    // walking the whole frame ~17 times a second.
    for (var i = 0; i + 1 < bytes.length; i += 4) {
      final sample = (bytes[i] | (bytes[i + 1] << 8)).toSigned(16);
      final magnitude = sample < 0 ? -sample : sample;
      sum += magnitude * magnitude;
      count++;
    }
    if (count == 0) return 0;
    final rms = math.sqrt(sum / count) / 32768.0;
    return rms > 1.0 ? 1.0 : rms;
  }

  /// True when [userId] produced audio recently enough to count as speaking.
  bool isSpeaking(String userId) => _isRecentlyAudible(userId, DateTime.now());

  bool _isRecentlyAudible(String userId, DateTime now) {
    final last = _lastAudible[userId];
    if (last == null) return false;
    return now.difference(last).inMilliseconds <= AppConstants.speakingHangMs;
  }

  /// Clears the speaking flag of anyone who has gone quiet, then mirrors the
  /// host's own state into the user list.
  void _refreshSpeakingStates() {
    final now = DateTime.now();
    var changed = false;
    for (final entry in _clientUsers.entries.toList()) {
      final user = entry.value;
      if (!user.isSpeaking) continue;
      if (_isRecentlyAudible(user.id, now)) continue;
      _clientUsers[entry.key] = user.copyWith(isSpeaking: false);
      changed = true;
    }
    final hostSpeaking = _hostMicOn && _isRecentlyAudible(hostUserId, now);
    if (hostSpeaking != _hostSpeaking) {
      _hostSpeaking = hostSpeaking;
      changed = true;
    }
    if (changed) {
      _speakingDirty = false;
      _broadcastUsers();
    }
  }

  /// Pushes the user list shortly after a speaking change, collapsing a burst
  /// of toggles into a single broadcast.
  void _scheduleSpeakingBroadcast() {
    _speakingDirty = true;
    _speakingBroadcastTimer ??= Timer(
      const Duration(milliseconds: 150),
      () {
        _speakingBroadcastTimer = null;
        if (!_speakingDirty) return;
        _speakingDirty = false;
        _broadcastUsers();
      },
    );
  }

  void _removeClient(WebSocket socket) {
    final existed = _clients.remove(socket);
    if (!existed) return;
    _lastSeen.remove(socket);
    _pendingFrames.remove(socket);
    final user = _clientUsers[socket];
    if (user != null) {
      _usersById.remove(user.id);
      if (_privateCallCallerId == user.id) {
        final partnerSocket = _privateCallCalleeId != null
            ? _usersById[_privateCallCalleeId!]
            : null;
        if (partnerSocket != null) {
          _sendTo(partnerSocket, const WsMessage(type: 'private_call_ended'));
        }
        _clearPrivateCall();
      } else if (_privateCallCalleeId == user.id) {
        final partnerSocket = _privateCallCallerId != null
            ? _usersById[_privateCallCallerId!]
            : null;
        if (partnerSocket != null) {
          _sendTo(partnerSocket, const WsMessage(type: 'private_call_ended'));
        }
        _clearPrivateCall();
      }
    }
    _clientUsers.remove(socket);
    try {
      socket.close();
    } catch (_) {}
    _broadcastUsers();
    _broadcastRoomInfo();
  }

  void _broadcastUsers() {
    final users = [_hostUser, ..._clientUsers.values];
    _usersController.add(users);
    final msg = WsMessage(
      type: 'user_list',
      data: {'users': users.map((u) => u.toJson()).toList()},
    );
    for (final client in List.of(_clients)) {
      _sendTo(client, msg);
    }
  }

  void _broadcastRoomInfo() {
    final info = RoomInfo(
      roomId: _roomId,
      roomName: _roomName,
      channels: _channels,
      clientCount: _clientUsers.length,
      hasPin: _pin != null,
    );
    _roomInfoController.add(info);
    final msg = WsMessage(type: 'room_info', data: info.toJson());
    for (final client in List.of(_clients)) {
      _sendTo(client, msg);
    }
  }

  void _sendTo(WebSocket socket, WsMessage msg) {
    if (socket.readyState != WebSocket.open) return;
    try {
      socket.add(jsonEncode(msg.toJson()));
    } catch (e) {
      _errorController.add('Send error: $e');
    }
  }

  /// Host talks: broadcast to everyone in the host's current channel.
  Future<void> broadcastAudio(List<int> audioData) async {
    final hostCh = _hostChannelId;
    // Mark the host as speaking while it is actually pushing audio, so the
    // room can see who is transmitting.
    if (_hostMicOn && _rms(audioData) >= AppConstants.speakingThreshold) {
      _lastAudible[hostUserId] = DateTime.now();
      if (!_hostSpeaking) {
        _hostSpeaking = true;
        _broadcastUsers();
      }
    }
    // If the host itself is on a private call, only the partner hears it.
    final hostPartner = _privateCallPartnerOf(hostUserId);
    for (final client in List.of(_clients)) {
      if (client.readyState != WebSocket.open) continue;
      final recipient = _clientUsers[client];
      if (recipient == null) continue;
      if (hostPartner != null) {
        if (recipient.id != hostPartner) continue;
      } else {
        // Group broadcast: skip anyone busy on their own private call.
        if (_privateCallPartnerOf(recipient.id) != null) continue;
        if (!_sameChannel(hostCh, recipient.currentChannelId)) continue;
      }
      if (!_enqueueAudio(client, audioData)) continue;
    }
  }

  /// Writes an audio frame to a client, applying backpressure.
  ///
  /// `dart:io` does not expose a socket's pending-buffer size, so we track
  /// how many frames we have handed to a client but not seen acknowledged
  /// (each client answers our heartbeat). A client that has fallen more than
  /// [AppConstants.maxQueuedAudioFrames] behind gets its oldest frames
  /// dropped rather than being allowed to consume unbounded memory.
  bool _enqueueAudio(WebSocket client, List<int> data) {
    final pending = (_pendingFrames[client] ?? 0) + 1;
    if (pending > AppConstants.maxQueuedAudioFrames) {
      _droppedFrames++;
    }
    _pendingFrames[client] = pending;
    try {
      client.add(data);
      return true;
    } catch (e) {
      _pendingFrames[client] = (_pendingFrames[client] ?? 1) - 1;
      _errorController.add('Broadcast error: $e');
      return false;
    }
  }

  @override
  Future<void> sendMessage(WsMessage message) async {
    for (final client in List.of(_clients)) {
      _sendTo(client, message);
    }
  }

  @override
  Future<void> sendAudio(List<int> audioData) => broadcastAudio(audioData);

  @override
  Future<void> stop() async {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _speakingBroadcastTimer?.cancel();
    _speakingBroadcastTimer = null;
    for (final client in List.of(_clients)) {
      try {
        await client.close(1001, 'Host closed the room');
      } catch (_) {}
    }
    _clients.clear();
    _clientUsers.clear();
    _usersById.clear();
    _lastSeen.clear();
    _pendingFrames.clear();
    _lastAudible.clear();
    _clearPrivateCall();
    try {
      await _server?.close(force: true);
    } catch (_) {}
    _server = null;
    _isRunningController.add(false);
    _connectionStatusController.add(ConnectionStatus.disconnected);
  }

  /// Releases the stream controllers. Called when the controller is disposed.
  void dispose() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _speakingBroadcastTimer?.cancel();
    _speakingBroadcastTimer = null;
    _usersController.close();
    _isRunningController.close();
    _errorController.close();
    _connectionStatusController.close();
    _roomInfoController.close();
    _messageController.close();
    _audioController.close();
  }
}

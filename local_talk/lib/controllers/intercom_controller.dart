import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/app_data.dart';
import '../models/channel.dart';
import '../models/message.dart';
import '../models/user.dart';
import '../services/audio_service.dart';
import '../services/client_service.dart';
import '../services/host_service.dart';
import '../services/hotspot_service.dart';
import '../services/session_keeper.dart';
import '../services/websocket_service.dart';
import '../utils/constants.dart';

enum IntercomRole { none, host, client }

/// Incoming private-call ring state.
class IncomingCall {
  final String callerId;
  final String callerName;

  const IncomingCall({required this.callerId, required this.callerName});
}

class IntercomController extends ChangeNotifier {
  IntercomRole _role = IntercomRole.none;
  HostService? _hostService;
  ClientService? _clientService;
  AudioService? _audioService;

  StreamSubscription<List<User>>? _usersSub;
  StreamSubscription<String>? _errorSub;
  StreamSubscription<ConnectionStatus>? _statusSub;
  StreamSubscription<RoomInfo>? _roomInfoSub;
  StreamSubscription<WsMessage>? _messageSub;
  StreamSubscription<List<int>>? _audioInSub;
  StreamSubscription<List<int>>? _audioOutSub;
  StreamSubscription<double>? _levelSub;

  HotspotService? _hotspotService;
  final SessionKeeper _sessionKeeper = SessionKeeper();
  bool _isHotspotActive = false;
  String? _hotspotSsid;
  String? _hotspotPassword;
  String? _hotspotIp;

  final List<User> _users = [];
  String? _error;
  ConnectionStatus _connectionStatus = ConnectionStatus.disconnected;
  RoomInfo? _roomInfo;
  String? _currentChannelId;
  bool _isMicOn = false;
  bool _isConnecting = false;
  double _micLevel = 0;
  int _packetsSent = 0;
  int _packetsReceived = 0;

  // Private call state
  bool _isInPrivateCall = false;
  String? _privateCallPartnerId;
  String? _privateCallPartnerName;
  IncomingCall? _incomingCall;

  AppData? _appData;

  IntercomRole get role => _role;
  List<User> get users => List.unmodifiable(_users);
  String? get error => _error;
  bool get isHost => _role == IntercomRole.host;
  bool get isClient => _role == IntercomRole.client;
  bool get isInRoom => _role != IntercomRole.none;
  bool get isConnecting => _isConnecting;
  AudioService? get audioService => _audioService;
  ConnectionStatus get connectionStatus => _connectionStatus;
  RoomInfo? get roomInfo => _roomInfo;
  List<Channel> get channels => _roomInfo?.channels ?? const [];
  String? get currentChannelId => _currentChannelId;
  bool get isMicOn => _isMicOn;
  double get micLevel => _micLevel;

  /// Drives the PTT level ring without rebuilding the rest of the screen.
  /// See the level subscription in [startTalking].
  final ValueNotifier<double> micLevelNotifier = ValueNotifier<double>(0);
  int get packetsSent => _packetsSent;
  int get packetsReceived => _packetsReceived;
  bool get isInPrivateCall => _isInPrivateCall;
  String? get privateCallPartnerName => _privateCallPartnerName;
  IncomingCall? get incomingCall => _incomingCall;

  /// True while waiting for the other side to accept an outgoing call.
  bool get isCallingOut =>
      !_isInPrivateCall &&
      _incomingCall == null &&
      _privateCallPartnerId != null;

  bool get isHotspotActive => _isHotspotActive;
  String? get hotspotSsid => _hotspotSsid;
  String? get hotspotPassword => _hotspotPassword;
  String? get hotspotIp => _hotspotIp;

  /// id of this device's user as known by the room (null for host role).
  String? get localUserId => _clientService?.localUserId;

  User? get localUser {
    final id = localUserId;
    if (id == null) return null;
    for (final u in _users) {
      if (u.id == id) return u;
    }
    return null;
  }

  // ---------------------------------------------------------------- setup

  Future<void> initialize({AppData? appData}) async {
    _appData = appData;
    _audioService = AudioService();
    try {
      await _audioService!.initialize();
    } on AudioInitException {
      // Mic may not be granted yet; retry lazily on first PTT press.
      _audioService = AudioService();
    }
  }

  AppData? get appData => _appData;

  String get username => _appData?.username ?? 'User';

  Future<void> setUsername(String value) async {
    await _appData?.setUsername(value);
    notifyListeners();
  }

  /// Creates a fresh [AudioService], e.g. after mic permission was granted.
  Future<bool> recreateAudioService() async {
    try {
      final old = _audioService;
      final audio = AudioService();
      await audio.initialize();
      _audioService = audio;
      try {
        await old?.dispose();
      } catch (_) {}
      notifyListeners();
      return true;
    } on AudioInitException {
      return false;
    }
  }

  // ------------------------------------------------------------ host mode

  Future<void> startHost(String roomName,
      {String? pin,
      bool useHotspot = false,
      String? hotspotSsid,
      String? hotspotPassword}) async {
    if (_isConnecting || _role != IntercomRole.none) return;
    _error = null;
    _isConnecting = true;
    _connectionStatus = ConnectionStatus.connecting;
    notifyListeners();

    if (useHotspot) {
      _hotspotService = HotspotService();
      _hotspotService!.statusStream.listen((active) {
        _isHotspotActive = active;
        notifyListeners();
      });
      _hotspotService!.errorStream.listen((err) {
        _error = err;
        notifyListeners();
      });

      final hotspotStarted = await _hotspotService!.startHotspot(
        ssid: hotspotSsid,
        password: hotspotPassword,
      );
      if (!hotspotStarted) {
        _error = _hotspotService == null
            ? 'Could not start hotspot. Try again or use Wi-Fi.'
            : 'Hotspot failed. Try again or use Wi-Fi.';
        _connectionStatus = ConnectionStatus.disconnected;
        _isConnecting = false;
        _hotspotService = null;
        _isHotspotActive = false;
        notifyListeners();
        return;
      }

      _hotspotSsid = _hotspotService!.ssid;
      _hotspotPassword = _hotspotService!.password;
      _hotspotIp = _hotspotService!.ipAddress;
    }

    final host = HostService(roomName: roomName, pin: pin);
    _hostService = host;
    _role = IntercomRole.host;
    _listenToCommonStreams(host, isHost: true);

    _audioInSub = host.audioStream.listen((data) {
      _packetsReceived++;
      _audioService?.feedAudioData(data);
    });

    try {
      await host.start();
      // Keep the session alive: screen on, foreground service, audio focus.
      // Without this, backgrounding the app can suspend the process and the
      // room dies for everyone.
      await _sessionKeeper.start();
      await _audioService?.startPlayback();
      _connectionStatus = ConnectionStatus.connected;
    } catch (e) {
      _error = 'Could not start the room.\n'
          'Another app may be using port ${_portForError(e)}. '
          'Try restarting the app.';
      _connectionStatus = ConnectionStatus.disconnected;
      await _teardownServices();
    } finally {
      _isConnecting = false;
      notifyListeners();
    }
  }

  /// Best-effort port extraction from a bind failure, so a "port already in
  /// use" message names the port the user actually has to free.
  static String _portForError(Object e) {
    final match =
        RegExp(r'port\s*(\d+)', caseSensitive: false).firstMatch(e.toString());
    return match?.group(1) ?? '${AppConstants.wsPort}';
  }

  // ----------------------------------------------------------- client mode

  /// Throws [JoinException] with a friendly message when joining fails.
  Future<void> joinRoom(String hostIp, String username, {String? pin}) async {
    if (_isConnecting || _role != IntercomRole.none) return;
    _error = null;
    _isConnecting = true;
    _connectionStatus = ConnectionStatus.connecting;
    notifyListeners();

    await _appData?.setUsername(username);
    if (hostIp.trim().isNotEmpty) {
      await _appData?.setLastHostIp(hostIp);
    }
    if (pin != null && pin.isNotEmpty) {
      await _appData?.setLastPin(pin);
    }

    final client = ClientService(hostIp: hostIp, username: username, pin: pin);
    _clientService = client;
    _role = IntercomRole.client;
    _listenToCommonStreams(client, isHost: false);

    _audioInSub = client.audioStream.listen((data) {
      _packetsReceived++;
      _audioService?.feedAudioData(data);
    });

    try {
      await client.connect();
      // Join the first channel by default so audio flows immediately.
      final firstChannel =
          client.channels.isNotEmpty ? client.channels.first.id : null;
      _currentChannelId = firstChannel;
      if (firstChannel != null) {
        // Goes through joinChannel so the channel is remembered for reconnects.
        await client.joinChannel(firstChannel);
      }
      await _audioService?.startPlayback();
      // Clients need the same protections: a backgrounded client gets
      // suspended and silently stops receiving audio.
      await _sessionKeeper.start();
      _connectionStatus = ConnectionStatus.connected;
    } on JoinException catch (e) {
      _error = e.message;
      _connectionStatus = ConnectionStatus.disconnected;
      await _teardownServices();
      rethrow;
    } catch (e) {
      _error = 'Could not join the room: $e';
      _connectionStatus = ConnectionStatus.disconnected;
      await _teardownServices();
      throw JoinException(_error!);
    } finally {
      _isConnecting = false;
      notifyListeners();
    }
  }

  void _listenToCommonStreams(WebSocketService service,
      {required bool isHost}) {
    _cancelStreamSubs();
    _usersSub = service.usersStream.listen((users) {
      _users
        ..clear()
        ..addAll(users);
      notifyListeners();
    });
    _errorSub = service.errorStream.listen((err) {
      _error = err;
      notifyListeners();
    });
    _statusSub = service.connectionStatusStream.listen((status) {
      // Host status is managed locally; client reconnect status flows through.
      if (!isHost) {
        _connectionStatus = status;
      }
      notifyListeners();
    });
    _roomInfoSub = service.roomInfoStream.listen((info) {
      _roomInfo = info;
      notifyListeners();
    });
    // Control messages are part of the contract for both roles now, so this
    // needs no per-role branch and no downcast.
    _messageSub = service.messageStream.listen(_handleMessage);
  }

  void _cancelStreamSubs() {
    _usersSub?.cancel();
    _errorSub?.cancel();
    _statusSub?.cancel();
    _roomInfoSub?.cancel();
    _messageSub?.cancel();
    _audioInSub?.cancel();
    _audioOutSub?.cancel();
    _levelSub?.cancel();
    _usersSub = null;
    _errorSub = null;
    _statusSub = null;
    _roomInfoSub = null;
    _messageSub = null;
    _audioInSub = null;
    _audioOutSub = null;
    _levelSub = null;
  }

  void _handleMessage(WsMessage msg) {
    switch (msg.type) {
      case 'private_call_request':
        _incomingCall = IncomingCall(
          callerId: msg.data?['callerId'] as String? ?? '',
          callerName: msg.data?['callerName'] as String? ?? 'Unknown',
        );
        break;
      case 'private_call_outgoing':
        _privateCallPartnerId =
            msg.data?['partnerId'] as String? ?? _privateCallPartnerId;
        _privateCallPartnerName =
            msg.data?['partnerName'] as String? ?? _privateCallPartnerName;
        break;
      case 'private_call_started':
        _isInPrivateCall = true;
        _incomingCall = null;
        _privateCallPartnerId =
            msg.data?['partnerId'] as String? ?? _privateCallPartnerId;
        _privateCallPartnerName =
            msg.data?['partnerName'] as String? ?? _privateCallPartnerName;
        break;
      case 'private_call_rejected':
        _isInPrivateCall = false;
        _privateCallPartnerId = null;
        _privateCallPartnerName = null;
        _error = 'Private call declined';
        break;
      case 'private_call_ended':
        _isInPrivateCall = false;
        _privateCallPartnerId = null;
        _privateCallPartnerName = null;
        break;
      case 'private_call_busy':
        _error = msg.data?['message'] as String? ?? 'Private call busy';
        break;
      case 'private_call_unavailable':
        _error = msg.data?['message'] as String? ?? 'User is not available';
        break;
      case 'channel_joined':
        _currentChannelId =
            msg.data?['channelId'] as String? ?? _currentChannelId;
        break;
      case 'connection_lost':
        // surfaced via status; nothing extra for now
        break;
      default:
        break;
    }
    notifyListeners();
  }

  // ------------------------------------------------------------- push to talk

  /// Begins transmitting. Safe to call repeatedly.
  Future<bool> startTalking() async {
    if (_role == IntercomRole.none || _isMicOn) return _isMicOn;
    var audio = _audioService;
    if (audio == null || !audio.isReady) {
      // Lazy retry (e.g. mic permission granted after startup failure).
      audio = AudioService();
      try {
        await audio.initialize();
        _audioService = audio;
      } on AudioInitException {
        _error = 'Microphone is not available. Check app permissions.';
        notifyListeners();
        return false;
      }
    }
    try {
      await audio.startRecording();
      _isMicOn = true;
      _hostService?.setHostMicState(true);
      _micLevel = 0;
      // Deliberately does NOT call notifyListeners(): the level arrives ~20x per
      // second, and rebuilding the whole screen that often drops frames on
      // budget phones. The PTT button listens to [micLevelNotifier] instead and
      // repaints only its own level ring.
      _levelSub = audio.levelStream.listen((level) {
        _micLevel = level;
        micLevelNotifier.value = level;
      });
      _audioOutSub = audio.audioStream.listen((data) {
        _packetsSent++;
        if (_role == IntercomRole.host) {
          _hostService?.broadcastAudio(data);
        } else if (_role == IntercomRole.client) {
          _clientService?.sendAudio(data);
        }
      });
      _clientService?.sendMessage(
        const WsMessage(type: 'mic_state', data: {'isOn': true}),
      );
      notifyListeners();
      return true;
    } catch (e) {
      _error = 'Could not start the microphone: $e';
      notifyListeners();
      return false;
    }
  }

  Future<void> stopTalking() async {
    if (!_isMicOn) return;
    _isMicOn = false;
    _micLevel = 0;
    micLevelNotifier.value = 0;
    await _audioOutSub?.cancel();
    _audioOutSub = null;
    await _levelSub?.cancel();
    _levelSub = null;
    try {
      await _audioService?.stopRecording();
    } catch (_) {}
    _hostService?.setHostMicState(false);
    _clientService?.sendMessage(
      const WsMessage(type: 'mic_state', data: {'isOn': false}),
    );
    notifyListeners();
  }

  // ----------------------------------------------------------------- channels

  Future<void> switchChannel(String channelId) async {
    if (_currentChannelId == channelId) return;
    _currentChannelId = channelId;
    notifyListeners();
    if (isHost) {
      _hostService?.switchHostChannel(channelId);
    } else {
      // Remembered by ClientService so a reconnect restores this channel.
      await _clientService?.joinChannel(channelId);
    }
  }

  // ------------------------------------------------------------- private call

  Future<void> initiatePrivateCall(String targetUserId) async {
    if (_isInPrivateCall || _incomingCall != null) return;
    final target = _users.where((u) => u.id == targetUserId).firstOrNull;
    _privateCallPartnerId = targetUserId;
    _privateCallPartnerName = target?.username;
    notifyListeners();
    if (isHost) {
      _hostService?.hostCallClient(targetUserId);
    } else {
      _clientService?.sendMessage(WsMessage(
        type: 'private_call',
        data: {'targetId': targetUserId},
      ));
    }
  }

  Future<void> acceptPrivateCall() async {
    final call = _incomingCall;
    if (call == null) return;
    _incomingCall = null;
    _privateCallPartnerId = call.callerId;
    _privateCallPartnerName = call.callerName;
    if (isHost) {
      _hostService?.acceptHostPrivateCall(call.callerId);
    } else {
      _clientService?.sendMessage(WsMessage(
        type: 'private_call_accept',
        data: {'callerId': call.callerId},
      ));
    }
    notifyListeners();
  }

  Future<void> rejectPrivateCall() async {
    final call = _incomingCall;
    if (call == null) return;
    _incomingCall = null;
    if (isHost) {
      _hostService?.rejectHostPrivateCall(call.callerId);
    } else {
      _clientService?.sendMessage(WsMessage(
        type: 'private_call_reject',
        data: {'callerId': call.callerId},
      ));
    }
    notifyListeners();
  }

  Future<void> endPrivateCall() async {
    if (!_isInPrivateCall) return;
    if (isHost) {
      _hostService?.endHostPrivateCall();
    } else {
      _clientService?.sendMessage(const WsMessage(type: 'private_call_end'));
    }
    _isInPrivateCall = false;
    _privateCallPartnerId = null;
    _privateCallPartnerName = null;
    notifyListeners();
  }

  void cancelOutgoingCall() {
    if (_isInPrivateCall) return;
    if (_privateCallPartnerId == null) return;
    if (isHost) {
      _hostService?.endHostPrivateCall();
    } else {
      _clientService?.sendMessage(const WsMessage(type: 'private_call_end'));
    }
    _privateCallPartnerId = null;
    _privateCallPartnerName = null;
    notifyListeners();
  }

  // ------------------------------------------------------------------ leaving

  Future<void> leaveRoom() async {
    await stopTalking();
    await _audioService?.stopPlayback();
    await _teardownServices();
    _role = IntercomRole.none;
    _users.clear();
    _connectionStatus = ConnectionStatus.disconnected;
    _roomInfo = null;
    _currentChannelId = null;
    _isInPrivateCall = false;
    _privateCallPartnerId = null;
    _privateCallPartnerName = null;
    _incomingCall = null;
    _packetsSent = 0;
    _packetsReceived = 0;
    notifyListeners();
  }

  Future<void> _teardownServices() async {
    _cancelStreamSubs();
    // Release the wakelock and foreground service before anything else, so we
    // never leave a notification or a held screen behind.
    await _sessionKeeper.stop();
    try {
      await _hostService?.stop();
    } catch (_) {}
    try {
      await _clientService?.stop();
    } catch (_) {}
    // Releases the host's stream controllers and timers. Safe to call even if
    // the room never started.
    _hostService?.dispose();
    _clientService?.dispose();
    _hostService = null;
    _clientService = null;
    if (_hotspotService?.isActive == true) {
      await _hotspotService?.stopHotspot();
    }
    _hotspotService = null;
    _hotspotSsid = null;
    _hotspotPassword = null;
    _hotspotIp = null;
    _isHotspotActive = false;
  }

  void clearError() {
    _error = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _cancelStreamSubs();
    _teardownServices();
    micLevelNotifier.dispose();
    _audioService?.dispose();
    _hotspotService?.dispose();
    super.dispose();
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

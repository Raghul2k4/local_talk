import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/app_data.dart';
import '../models/channel.dart';
import '../models/message.dart';
import '../models/room_invite.dart';
import '../models/user.dart';
import '../services/audio_service.dart';
import '../services/client_service.dart';
import '../services/host_service.dart';
import '../services/hotspot_service.dart';
import '../services/mic_permission_service.dart';
import '../services/session_keeper.dart';
import '../services/websocket_service.dart';
import '../utils/constants.dart';
import '../utils/ip_utils.dart';

enum IntercomRole { none, host, client }

/// Ordered stages of bringing a room up, surfaced verbatim in the UI.
///
/// The brief asks for named states rather than a spinner; having them as an
/// enum keeps the wording in one place and makes it impossible to skip or
/// reorder a step without editing the screen too.
enum RoomSetupStage {
  none,
  checkingNetwork,
  preparingNetwork,
  startingServer,
  findingAddress,
  ready,
  failed,
}

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
  final MicPermissionService _micPermission = const MicPermissionService();

  RoomSetupStage _setupStage = RoomSetupStage.none;
  MicPermissionStatus _micStatus = MicPermissionStatus.granted;
  bool _hotspotNeedsUserAction = false;

  /// Last invite payload published by the host, for the QR panel.
  RoomInvite? _invite;

  IntercomRole get role => _role;
  RoomSetupStage get setupStage => _setupStage;
  MicPermissionStatus get micStatus => _micStatus;
  String? get micMessage => _micStatus == MicPermissionStatus.granted
      ? null
      : MicPermissionService.messageFor(_micStatus);

  /// True when the OS blocked a programmatic hotspot and the user has to turn
  /// it on from system settings. Drives the guidance screen.
  bool get hotspotNeedsUserAction => _hotspotNeedsUserAction;

  /// The QR payload for the room currently hosted.
  RoomInvite? get invite => _invite;

  /// The verified address guests should use, or null when it could not be
  /// determined.
  HostAddress? get advertisedAddress => _hostService?.advertisedAddress;

  /// The port the host actually bound.
  int? get hostPort => _hostService?.boundPort;

  /// `ip:port` for the manual fallback, or null when unknown.
  String? get connectionEndpoint {
    final address = advertisedAddress;
    final port = hostPort;
    if (address == null || port == null) return null;
    return '${address.ip}:$port';
  }

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

    // Ask for the microphone *before* touching audio. The old flow called
    // `AudioService.initialize()` first, let it throw for want of permission,
    // and swallowed the failure — which is why users met "Microphone is not
    // available" only after pressing the mic button.
    await ensureMicPermission(requestIfNeeded: true);

    if (_micStatus == MicPermissionStatus.granted) {
      await _initAudio();
    }
    // Otherwise audio stays uninitialised and every entry point re-checks the
    // permission first. The app is still fully usable for listening.
  }

  /// Creates and initialises the audio stack, recording any user-facing
  /// failure on [error] rather than throwing it at the caller.
  Future<void> _initAudio() async {
    final audio = AudioService();
    try {
      await audio.initialize();
      _audioService = audio;
    } on AudioInitException catch (e) {
      _audioService = null;
      _error = e.message;
    } catch (_) {
      _audioService = null;
      _error = 'Could not set up audio. Restart the app, and check that '
          'LocalTalk is allowed to use the microphone.';
    }
  }

  /// Checks — and optionally requests — microphone access.
  ///
  /// Safe to call repeatedly; returns the resulting status. The only caller
  /// that should prompt is one the user just triggered (app launch, creating a
  /// room, first PTT press).
  Future<MicPermissionStatus> ensureMicPermission({
    required bool requestIfNeeded,
  }) async {
    final status = requestIfNeeded
        ? await _micPermission.request()
        : await _micPermission.check();
    if (status != _micStatus) {
      _micStatus = status;
      notifyListeners();
    }
    return status;
  }

  /// Whether the user must visit system settings before we can retry.
  bool get micNeedsSettings =>
      MicPermissionService.requiresSettings(_micStatus);

  AppData? get appData => _appData;

  String get username => _appData?.username ?? 'User';

  Future<void> setUsername(String value) async {
    await _appData?.setUsername(value);
    notifyListeners();
  }

  /// Creates a fresh [AudioService], e.g. after mic permission was granted.
  Future<bool> recreateAudioService() async {
    final status = await ensureMicPermission(requestIfNeeded: true);
    if (status != MicPermissionStatus.granted) {
      _error = MicPermissionService.messageFor(status);
      notifyListeners();
      return false;
    }
    final previous = _audioService;
    _audioService = null;
    await _initAudio();
    if (_audioService == null) {
      try {
        await previous?.dispose();
      } catch (_) {}
      return false;
    }
    try {
      await previous?.dispose();
    } catch (_) {}
    notifyListeners();
    return true;
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
    _setupStage = RoomSetupStage.checkingNetwork;
    notifyListeners();

    if (useHotspot) {
      _setupStage = RoomSetupStage.preparingNetwork;
      _hotspotNeedsUserAction = false;
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
        // Android 10+ blocks apps from enabling a hotspot, so this is an
        // expected outcome rather than a bug. Flag it for the guidance
        // screen instead of dead-ending on a generic error.
        _hotspotNeedsUserAction = true;
        _error = _hotspotService?.lastError ??
            'This device will not let LocalTalk turn on a hotspot. Turn it on '
                'from your quick settings, then try again.';
        _connectionStatus = ConnectionStatus.disconnected;
        _isConnecting = false;
        _setupStage = RoomSetupStage.failed;
        notifyListeners();
        return;
      }

      _hotspotSsid = _hotspotService!.ssid;
      _hotspotPassword = _hotspotService!.password;
      _hotspotIp = _hotspotService!.ipAddress;
    }

    final host = HostService(roomName: roomName, pin: pin);
    host.hotspotExpected = _isHotspotActive;
    _hostService = host;
    _role = IntercomRole.host;
    _listenToCommonStreams(host, isHost: true);

    _audioInSub = host.audioStream.listen((data) {
      _packetsReceived++;
      _audioService?.feedAudioData(data);
    });

    try {
      _setupStage = RoomSetupStage.startingServer;
      notifyListeners();
      await host.start();

      // Detect/verify the address *before* announcing readiness. A room that
      // reports ready with an unreachable address is the original bug, and it
      // is worse than an explicit failure because the guest fails instead.
      _setupStage = RoomSetupStage.findingAddress;
      notifyListeners();
      final addressError = host.addressError;
      if (addressError != null) {
        _error = addressError;
        _connectionStatus = ConnectionStatus.disconnected;
        _setupStage = RoomSetupStage.failed;
        await _teardownServices();
        notifyListeners();
        return;
      }
      _invite = host.invite;
      if (_invite == null) {
        _error =
            'The room started, but its address could not be shared. Check your '
            'Wi-Fi and start the room again.';
        _connectionStatus = ConnectionStatus.disconnected;
        _setupStage = RoomSetupStage.failed;
        await _teardownServices();
        notifyListeners();
        return;
      }

      // Keep the session alive: screen on, foreground service, audio focus.
      // Without this, backgrounding the app can suspend the process and the
      // room dies for everyone.
      await _sessionKeeper.start();
      await _audioService?.startPlayback();
      _connectionStatus = ConnectionStatus.connected;
      _setupStage = RoomSetupStage.ready;
    } catch (e) {
      _error = 'Could not start the room.\n'
          'Another app may be using port ${_portForError(e)}. '
          'Try restarting the app.';
      _connectionStatus = ConnectionStatus.disconnected;
      _setupStage = RoomSetupStage.failed;
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
  ///
  /// [invite] is the scanned QR payload. When present its address, port and
  /// room credentials are used verbatim — the guest never derives or guesses an
  /// endpoint, which is the whole point of the QR flow. Omitting it is the
  /// advanced/manual fallback.
  Future<void> joinRoom(
    String hostIp,
    String username, {
    String? pin,
    RoomInvite? invite,
    int? port,
  }) async {
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

    // An invite wins over anything typed by hand: it is the address the host
    // itself verified as reachable.
    final targetIp = invite?.ip ?? hostIp.trim();
    final targetPort = invite?.port ?? port ?? AppConstants.wsPort;
    if (targetIp.isEmpty) {
      _isConnecting = false;
      throw JoinException(
        'No host address was provided. Scan the QR code on the host screen, '
        'or enter the address manually.',
      );
    }

    final client = ClientService(
      hostIp: targetIp,
      username: username,
      pin: pin,
      port: targetPort,
      roomId: invite?.roomId,
      roomToken: invite?.token,
    );
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

    // Re-check before every first press. The permission can have been revoked
    // in system settings while the room was open, and the mic may still be
    // held by another app.
    var audio = _audioService;
    if (audio == null || !audio.isReady) {
      final status = await ensureMicPermission(requestIfNeeded: true);
      if (status != MicPermissionStatus.granted) {
        _error = MicPermissionService.messageFor(status);
        notifyListeners();
        return false;
      }
      await _initAudio();
      audio = _audioService;
      if (audio == null || !audio.isReady) {
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

  /// Guards against a second leave running while the first is still awaiting.
  ///
  /// Leave is reachable from the app bar *and* the back button, and a double
  /// tap is easy. Without this, two overlapping teardowns both reach
  /// `_teardownServices`, and the loser's `dispose()` runs against services the
  /// winner already nulled — which surfaces as a leave that "sometimes" does
  /// nothing.
  bool _isLeaving = false;

  /// Leaves the room and returns the device to a clean, re-joinable state.
  ///
  /// Every teardown step is guarded individually. This runs on the user's way
  /// out of a working call, so a single failing plugin must never strand them
  /// in the room: if `stopRecording` or `stopPlayer` throws, the host server
  /// still has to be closed and the local state still has to be reset.
  Future<void> leaveRoom() async {
    if (_isLeaving) return;
    _isLeaving = true;
    try {
      // Stop transmitting first so the room stops receiving our audio before
      // the socket goes away.
      try {
        await stopTalking();
      } catch (_) {}

      try {
        await _audioService?.stopPlayback();
      } catch (_) {}

      // Never skipped: this is what actually closes the host server and
      // releases the wakelock/foreground service.
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

      // Without these the device is not actually re-joinable. `joinRoom`
      // early-returns while `_isConnecting` is set, and `HostScreen` reads
      // `_setupStage` to decide whether the room came up — so a stale `ready`
      // or a stuck `true` makes the *next* attempt silently do nothing.
      _isConnecting = false;
      _setupStage = RoomSetupStage.none;
      _hotspotNeedsUserAction = false;
      _invite = null;
      _error = null;
      notifyListeners();
    } finally {
      _isLeaving = false;
    }
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
    // Guarded like the rest: a hotspot that refuses to stop must not leave the
    // device stuck in a room it already left, with `_hotspotService` non-null.
    try {
      if (_hotspotService?.isActive == true) {
        await _hotspotService?.stopHotspot();
      }
    } catch (_) {}
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

import 'package:permission_handler/permission_handler.dart';

/// Why the microphone is not usable, in terms the user can act on.
enum MicPermissionStatus {
  /// All good; audio may be initialised.
  granted,

  /// The user said no this time. Asking again later is allowed.
  denied,

  /// The user said no permanently ("Don't ask again"). Only an app-settings
  /// trip can recover this, so the UI must offer that and not re-prompt.
  permanentlyDenied,

  /// Blocked by policy (parental controls, MDM) — retrying will never help.
  restricted,

  /// This device has no microphone, or it is disabled at the system level.
  unavailable,

  /// Another app is holding the microphone. Usable later, once it releases.
  inUse,
}

/// Thin, testable wrapper over `permission_handler`.
///
/// The point of this class is that *nothing else in the app touches
/// `Permission.microphone` directly*. That was how the original flow ended up
/// asking for the mic only after audio had already failed.
class MicPermissionService {
  const MicPermissionService();

  /// Current state without prompting. Safe to call on launch.
  Future<MicPermissionStatus> check() async {
    try {
      return _from(await Permission.microphone.status);
    } catch (_) {
      // A plugin that cannot answer its own status is not a reason to block
      // the user from reaching the app at all.
      return MicPermissionStatus.granted;
    }
  }

  /// Requests the permission if needed and reports the outcome.
  ///
  /// Returns the current state without prompting when it is already granted,
  /// so callers can treat "ask" as idempotent.
  Future<MicPermissionStatus> request() async {
    try {
      final current = await Permission.microphone.status;
      if (current.isGranted) return MicPermissionStatus.granted;
      return _from(await Permission.microphone.request());
    } catch (_) {
      return MicPermissionStatus.granted;
    }
  }

  MicPermissionStatus _from(PermissionStatus status) {
    if (status.isGranted || status.isLimited) {
      return MicPermissionStatus.granted;
    }
    if (status.isPermanentlyDenied) {
      return MicPermissionStatus.permanentlyDenied;
    }
    if (status.isRestricted) return MicPermissionStatus.restricted;
    if (status.isDenied) return MicPermissionStatus.denied;
    return MicPermissionStatus.unavailable;
  }

  /// A sentence explaining what to do, given the state.
  ///
  /// Every branch tells the user their next action. The old code showed
  /// "Microphone is not available. Check app permissions.", which told nobody
  /// anything they could do.
  static String messageFor(MicPermissionStatus status) {
    return switch (status) {
      MicPermissionStatus.granted =>
        'Microphone access granted.',
      MicPermissionStatus.denied =>
        'LocalTalk needs the microphone to send your voice. '
            'Tap "Allow microphone" when Android asks.',
      MicPermissionStatus.permanentlyDenied =>
        'Microphone access is turned off for LocalTalk. Open the app settings '
            'and enable Microphone, then come back.',
      MicPermissionStatus.restricted =>
        'Microphone access is blocked on this device, usually by a parental '
            'control or device policy. It has to be allowed there first.',
      MicPermissionStatus.unavailable =>
        'No microphone is available on this device, so LocalTalk cannot '
            'transmit audio. You can still listen to the room.',
      MicPermissionStatus.inUse =>
        'Another app is using the microphone right now. Close it, then press '
            'the mic button again.',
    };
  }

  /// Whether re-prompting is pointless and the user must go to Settings.
  static bool requiresSettings(MicPermissionStatus status) =>
      status == MicPermissionStatus.permanentlyDenied ||
      status == MicPermissionStatus.restricted;

  /// Whether the app can still receive and play audio despite this status.
  ///
  /// Muting the local mic is not a reason to kick someone out of the room.
  static bool canStillListen(MicPermissionStatus status) => status !=
      MicPermissionStatus.granted;
}
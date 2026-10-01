import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// Keeps an intercom session alive while the app is in a room.
///
/// Three separate concerns, one owner:
///
///  * **Wakelock** — stops the screen sleeping. Only while in a room; a phone
///    in your pocket should still time out normally.
///  * **Foreground service** — Android suspends/kills a backgrounded app, which
///    silently ends the host's room and disconnects every client. A foreground
///    service with a visible notification prevents that.
///  * **Audio session** — declares this as speech so the OS ducks other audio
///    instead of stealing it, and routes to a Bluetooth headset when one is
///    connected.
///
/// Every method is defensive: none of these plugins should be able to take the
/// intercom down if they fail on an unexpected device or OS version.
class SessionKeeper {
  bool _active = false;

  /// Whether `FlutterForegroundTask.init` has run. The plugin's own
  /// `isInitialized` is test-only.
  bool _initialized = false;

  /// Whether [start] succeeded in engaging the platform. The UI surfaces this
  /// so a user whose OS refused the service knows why the room may drop.
  bool get isActive => _active;

  /// Starts keeping the session alive. Safe to call repeatedly.
  Future<void> start() async {
    if (_active) return;
    _active = true;

    await _guard(() => WakelockPlus.enable(), 'wakelock');
    await _guard(_startForeground, 'foreground service');
    await _guard(_configureAudio, 'audio session');
  }

  /// Stops keeping the session alive. Safe to call when not started.
  Future<void> stop() async {
    if (!_active) return;
    _active = false;
    await _guard(() => WakelockPlus.disable(), 'wakelock');
    await _guard(_stopForeground, 'foreground service');
  }

  /// Runs [action], swallowing any failure.
  ///
  /// These are all best-effort platform conveniences. If the foreground
  /// service cannot start on some OEM build, the correct behaviour is to run
  /// degraded and visible — not to crash a working intercom.
  static Future<void> _guard(
    Future<void> Function() action,
    String what,
  ) async {
    try {
      await action();
    } catch (e) {
      debugPrint('SessionKeeper: $what failed: $e');
    }
  }

  // ------------------------------------------------------------ foreground

  Future<void> _startForeground() async {
    // `init` registers the notification channel and the task handler. It is
    // static/global state, so it must run before the first startService and
    // must not be repeated. (`isInitialized` is test-only, so track it here.)
    if (!_initialized) {
      _initialized = true;
      FlutterForegroundTask.init(
        androidNotificationOptions: AndroidNotificationOptions(
          channelId: 'localtalk_intercom',
          channelName: 'Intercom session',
          channelDescription: 'Shown while you are in a LocalTalk room.',
          // LOW importance: this is a "still alive" indicator, not an alert.
          channelImportance: NotificationChannelImportance.LOW,
          playSound: false,
          enableVibration: false,
        ),
        iosNotificationOptions: const IOSNotificationOptions(),
        foregroundTaskOptions: ForegroundTaskOptions(
          eventAction: ForegroundTaskEventAction.repeat(5000),
          autoRunOnBoot: false,
          // Hold the CPU so the audio socket is not starved when the screen is
          // off — this is the whole point of the service.
          allowWakeLock: true,
          // A host broadcasts to every client over Wi-Fi; a Wi-Fi lock keeps
          // the radio alive when the screen turns off.
          allowWifiLock: true,
          allowAutoRestart: false,
        ),
      );
      FlutterForegroundTask.setTaskHandler(_TaskHandler());
    }

    await FlutterForegroundTask.startService(
      serviceId: 1001,
      notificationTitle: 'LocalTalk is live',
      notificationText: 'Talking to your room on this Wi-Fi.',
      serviceTypes: const [ForegroundServiceTypes.microphone],
    );
  }

  Future<void> _stopForeground() async {
    await FlutterForegroundTask.stopService();
  }

  // ---------------------------------------------------------------- audio

  Future<void> _configureAudio() async {
    final session = await AudioSession.instance;

    // AudioSession is a SINGLETON shared across the app, so there is exactly
    // one configuration for both playback and recording — the second
    // `configure()` call would simply overwrite the first. This one config has
    // to serve the intercom in both directions:
    //
    //  - playAndRecord + allowBluetooth so a headset mic can be used
    //  - spokenAudio so the OS treats this as speech (ducks music rather than
    //    pausing it)
    //  - voiceCommunication so Android routes calls/headset buttons correctly
    await session.configure(
      const AudioSessionConfiguration(
        avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
        avAudioSessionCategoryOptions:
            AVAudioSessionCategoryOptions.allowBluetooth,
        avAudioSessionMode: AVAudioSessionMode.spokenAudio,
        androidAudioAttributes: AndroidAudioAttributes(
          contentType: AndroidAudioContentType.speech,
          usage: AndroidAudioUsage.voiceCommunication,
        ),
        androidAudioFocusGainType: AndroidAudioFocusGainType.gainTransient,
      ),
    );

    // A phone call or another app taking focus must pause us cleanly instead
    // of playing noise.
    session.interruptionEventStream.listen((event) {
      if (event.begin) {
        debugPrint('SessionKeeper: audio interrupted (${event.type})');
      }
    });
  }
}

/// Keeps the foreground service alive. The service exists purely to stop the
/// OS suspending the process while a room is live, so every callback is a
/// no-op: there is no work to do on the task isolate.
class _TaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}

import 'dart:async';
import 'dart:collection';
import 'dart:typed_data' show Uint8List;

import 'package:flutter_sound/flutter_sound.dart';

import '../utils/constants.dart';

class AudioService {
  FlutterSoundRecorder? _recorder;
  FlutterSoundPlayer? _player;
  bool _recorderReady = false;
  bool _playerReady = false;
  bool _isRecording = false;
  bool _isPlaying = false;

  StreamSubscription<RecordingDisposition>? _levelSubscription;

  final StreamController<Uint8List> _audioStreamController =
      StreamController<Uint8List>.broadcast();
  final StreamController<double> _levelController =
      StreamController<double>.broadcast();

  int _packetsReceived = 0;
  double _lastLevel = 0;

  /// Frames waiting to be handed to the player. See [_drainJitterBuffer].
  final ListQueue<Uint8List> _jitter = ListQueue<Uint8List>();
  Timer? _playbackTimer;
  int _primedFrames = 0;
  int _droppedFrames = 0;
  int _underrunFrames = 0;

  Stream<Uint8List> get audioStream => _audioStreamController.stream;
  Stream<double> get levelStream => _levelController.stream;

  bool get isRecording => _isRecording;
  bool get isPlaying => _isPlaying;
  bool get isReady => _recorderReady && _playerReady;
  int get packetsReceived => _packetsReceived;
  double get lastLevel => _lastLevel;

  Future<void> initialize() async {
    _recorder ??= FlutterSoundRecorder();
    _player ??= FlutterSoundPlayer();
    try {
      await _recorder!.openRecorder();
      // MUST match the playback tick in [_drainJitterBuffer] (AppConstants
      // .audioFrameMs). These were previously 50 ms and 58 ms, so capture
      // produced 20 frames/s while the drain timer consumed 17.2 frames/s. The
      // jitter buffer therefore grew without bound until it hit its ceiling
      // and then dropped the oldest frame on every single arrival - audible as
      // growing lag, then gaps and clipped syllables for the whole
      // transmission. Any mismatch here shows up as lag, not as an error.
      await _recorder!.setSubscriptionDuration(
        const Duration(milliseconds: AppConstants.audioFrameMs),
      );
      _recorderReady = true;
    } on AudioInitException {
      rethrow;
    } catch (e) {
      throw AudioInitException(
        'Could not open the microphone. '
        '${_explain(e)}',
        MicFailure.unavailable,
      );
    }
    try {
      await _player!.openPlayer();
      _playerReady = true;
    } catch (e) {
      // Listening is still possible without a player on some devices, but
      // say what actually failed rather than reporting a mic problem.
      _playerReady = false;
      throw AudioInitException(
        'Could not start audio playback. ${_explain(e)}',
        MicFailure.playback,
      );
    }
  }

  /// Maps a platform error onto a plain sentence.
  ///
  /// `flutter_sound` surfaces `PlatformException`s whose `code` is the only
  /// reliable signal; the `message` is usually a raw Java stack fragment that
  /// means nothing to a user.
  static String _explain(Object e) {
    final text = e.toString().toLowerCase();

    if (text.contains('in_use') ||
        text.contains('already in use') ||
        text.contains('audio recorder error') ||
        text.contains('mic busy')) {
      return 'Another app is using the microphone right now. Close it and try '
          'again.';
    }
    if (text.contains('permission') ||
        text.contains('securityexception') ||
        text.contains('denied')) {
      return 'Microphone permission was not granted. Enable it for LocalTalk '
          'in Settings.';
    }
    if (text.contains('no microphone') ||
        text.contains('not available') ||
        text.contains('nodriver')) {
      return 'No microphone was found on this device.';
    }
    return 'Something went wrong while setting up audio. Try again, and '
        'restart the app if it keeps happening.';
  }

  /// Records live PCM16 frames onto [audioStream].
  Future<void> startRecording() async {
    if (_isRecording || !_recorderReady) return;
    try {
      await _recorder!.startRecorder(
        codec: Codec.pcm16,
        numChannels: AppConstants.audioChannels,
        sampleRate: AppConstants.audioSampleRate,
        toStream: _audioStreamController.sink,
        enableVoiceProcessing: false,
      );
      _isRecording = true;
      _levelSubscription ??= _recorder!.onProgress?.listen((disp) {
        final db = disp.decibels;
        if (db != null) {
          // Map roughly -60..0 dB to 0..1.
          final normalized = ((db + 60) / 60).clamp(0.0, 1.0);
          _lastLevel = normalized;
          _levelController.add(normalized);
        }
      });
    } catch (e) {
      _isRecording = false;
      rethrow;
    }
  }

  Future<void> stopRecording() async {
    if (!_isRecording) return;
    try {
      await _recorder!.stopRecorder();
    } finally {
      _isRecording = false;
      _lastLevel = 0;
      _levelController.add(0);
      await _levelSubscription?.cancel();
      _levelSubscription = null;
    }
  }

  /// Starts the stream player so incoming frames are audible immediately.
  ///
  /// Frames are not written straight to the player: they go through a small
  /// jitter buffer that primes with a couple of frames and then feeds one frame
  /// per [AppConstants.audioFrameMs] tick. Without it, every network hiccup
  /// is audible as a click or a gap, and the first word after pressing the mic
  /// is routinely clipped because the player starts with an empty buffer.
  Future<void> startPlayback() async {
    if (_isPlaying || !_playerReady) return;
    try {
      await _player!.startPlayerFromStream(
        codec: Codec.pcm16,
        numChannels: AppConstants.audioChannels,
        sampleRate: AppConstants.audioSampleRate,
        bufferSize: AppConstants.audioBufferSize,
        interleaved: true,
      );
      _isPlaying = true;
      _primedFrames = 0;
      _playbackTimer?.cancel();
      _playbackTimer = Timer.periodic(
        const Duration(milliseconds: AppConstants.audioFrameMs),
        (_) => _drainJitterBuffer(),
      );
    } catch (e) {
      _isPlaying = false;
      rethrow;
    }
  }

  /// Feeds buffered frames to the player, one per tick, keeping the buffer at
  /// its target depth. Drops the oldest frame if we fall too far behind so a
  /// slow sink cannot grow the queue without bound.
  void _drainJitterBuffer() {
    final player = _player;
    if (player == null || !_isPlaying) return;

    // Stop feeding silence once the source goes quiet, so the player's buffer
    // drains and does not accumulate latency between transmissions.
    if (_jitter.isEmpty) {
      _primedFrames = 0;
      return;
    }

    if (_primedFrames < AppConstants.jitterPrimedFrames) {
      // Pre-roll: fill the player before the first frame reaches the speaker.
      player.feedUint8FromStream(_jitter.removeFirst());
      _primedFrames++;
      return;
    }

    final frame = _jitter.isNotEmpty
        ? _jitter.removeFirst()
        : Uint8List(AppConstants.audioFrameBytes);
    if (_jitter.isEmpty) _underrunFrames++;
    player.feedUint8FromStream(frame);
  }

  /// Queues an incoming audio frame. Returns immediately: a slow or blocked
  /// player must never stall the network read loop.
  void feedAudioData(List<int> data) {
    _packetsReceived++;
    if (!_isPlaying || _player == null) return;
    if (_jitter.length >= AppConstants.jitterMaxFrames) {
      _jitter.removeFirst();
      _droppedFrames++;
    }
    _jitter.addLast(Uint8List.fromList(data));
  }

  /// Frames the jitter buffer had to discard because it overran.
  int get droppedFrames => _droppedFrames;

  /// Times the jitter buffer ran dry mid-transmission (a dropped syllable).
  int get underrunFrames => _underrunFrames;

  Future<void> stopPlayback() async {
    _playbackTimer?.cancel();
    _playbackTimer = null;
    _jitter.clear();
    _primedFrames = 0;
    if (!_isPlaying) return;
    try {
      await _player?.stopPlayer();
    } finally {
      _isPlaying = false;
    }
  }

  Future<void> dispose() async {
    try {
      await stopRecording();
    } catch (_) {}
    try {
      await stopPlayback();
    } catch (_) {}
    try {
      await _recorder?.closeRecorder();
    } catch (_) {}
    try {
      await _player?.closePlayer();
    } catch (_) {}
    _recorderReady = false;
    _playerReady = false;
    await _audioStreamController.close();
    await _levelController.close();
  }
}

/// Why audio setup failed.
///
/// Carried as an enum rather than inferred from the message so callers can
/// branch (offer Settings, disable the mic button, keep playback running)
/// without string-matching, which is how vague errors tend to grow.
enum MicFailure {
  /// The recorder could not be opened.
  unavailable,

  /// The recorder is fine but the player could not start.
  playback,

  /// The platform refused for a reason worth sending the user to Settings.
  permission,
}

/// Audio failed to initialise, with a message safe to show a user.
///
/// The message is never a raw exception: the old version interpolated `$e`,
/// which on Android meant dumping a Java stack trace into the UI.
class AudioInitException implements Exception {
  final String message;
  final MicFailure reason;

  const AudioInitException(this.message, this.reason);

  @override
  String toString() => message;
}

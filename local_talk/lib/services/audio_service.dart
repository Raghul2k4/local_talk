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
    try {
      _recorder ??= FlutterSoundRecorder();
      _player ??= FlutterSoundPlayer();
      await _recorder!.openRecorder();
      await _recorder!.setSubscriptionDuration(
        const Duration(milliseconds: 50),
      );
      _recorderReady = true;
      await _player!.openPlayer();
      _playerReady = true;
    } catch (e) {
      throw AudioInitException('Microphone/audio init failed: $e');
    }
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

class AudioInitException implements Exception {
  final String message;
  AudioInitException(this.message);

  @override
  String toString() => message;
}

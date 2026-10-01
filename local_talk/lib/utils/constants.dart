class AppConstants {
  AppConstants._();

  /// Port the host WebSocket server listens on.
  static const int wsPort = 8080;

  static const String defaultUsername = 'User';
  static const int audioSampleRate = 16000;
  static const int audioChannels = 1;

  /// ~58 ms of PCM16 mono audio per network frame. Small enough for a snappy
  /// push-to-talk feel, big enough that WebSocket framing overhead stays low.
  static const int audioFrameMs = 58;
  static const int audioFrameBytes = audioSampleRate * 2 * audioFrameMs ~/ 1000;
  static const int audioBufferSize = 8192;

  /// Frames the jitter buffer pre-rolls before playback starts. Two frames is
  /// ~116 ms: enough to avoid clipping the first syllable, small enough to stay
  /// imperceptible.
  static const int jitterPrimedFrames = 2;

  /// Upper bound on buffered incoming frames. Beyond this the oldest frame is
  /// dropped, trading a syllable for bounded latency.
  static const int jitterMaxFrames = 12;

  static const int reconnectDelayMs = 2000;
  static const int maxReconnectAttempts = 6;
  static const int connectionTimeoutMs = 8000;

  /// Ceiling for the exponential reconnect backoff.
  ///
  /// Deliberately modest: with six attempts the total wait to give up is
  /// ~30 s. A longer ceiling sounds kinder but leaves a user staring at
  /// "Reconnecting…" for a minute and a half after the host is long gone.
  static const int reconnectMaxDelayMs = 6000;

  /// A socket that connects but never registers is closed after this long, so a
  /// half-open or malicious connection cannot hold memory indefinitely.
  static const int registrationTimeoutMs = 10000;

  static const int heartbeatIntervalMs = 10000;

  /// A client that has not been heard from for this long is dropped by the
  /// host. Three missed heartbeats.
  static const int clientTimeoutMs = heartbeatIntervalMs * 3;

  /// How long a client must keep talking before it counts as "speaking", and
  /// how long the indicator stays lit after it goes quiet.
  static const int speakingHangMs = 1500;

  /// Normalised RMS above which a sender is considered to be talking.
  static const double speakingThreshold = 0.06;

  /// How often to poll for the hotspot to come up after enabling it.
  static const int hotspotPollMs = 600;

  /// Max audio frames buffered per client before the oldest is dropped.
  /// Keeps a stalled client from growing the queue without bound.
  static const int maxQueuedAudioFrames = 40;

  static const int maxClients = 24;

  /// Hard cap on raw WebSocket sockets, registered or not. Leaves headroom
  /// above [maxClients] for clients mid-reconnect.
  static const int maxSockets = maxClients * 2;

  static const List<String> defaultChannels = ['General', 'Team A', 'Team B'];

  static const int maxUsernameLength = 24;
  static const int maxRoomNameLength = 32;
  static const int pinLength = 4;

  /// Bytes of random salt used when hashing a room PIN for storage.
  static const int pinSaltBytes = 16;
}

# AGENTS.md

## Commands

Run everything from `local_talk/`:
- `flutter pub get`
- `flutter run` (mobile/desktop; web cannot host or serve audio)
- `flutter analyze` (linter is `flutter_lints`)
- `flutter test`
- `dart format .`

CI (`.github/workflows/ci.yml`) runs format + `flutter analyze --fatal-infos` + `flutter test` on every push and PR.

## Architecture

Flutter app under `local_talk/`. Entry point: `lib/main.dart` -> `IntercomController` (Provider `ChangeNotifier`) -> screens.

Key separation:
- `controllers/intercom_controller.dart` — single state holder; owns `HostService`, `ClientService`, `AudioService`, `HotspotService`
- `services/` — networking and audio
- `screens/` — UI; `IntercomScreen` is shared by host and client
- `widgets/` — reusable UI; `PttButton` owns the live level ring

## Networking

Host: raw `dart:io` `HttpServer` + `WebSocket` on `InternetAddress.anyIPv4:8080`.
Client: `web_socket_channel` connecting to `ws://hostIp:8080`.

Both implement `WebSocketService` (`services/websocket_service.dart`), which is the
seam the controller talks to.

- Audio is raw PCM16 (`List<int>`) WebSocket frames; control messages are JSON (`WsMessage`).
- **The host is a full participant.** `HostService._routeAudio` feeds the host's own
  `audioStream` (so it hears its channel), and `broadcastAudio` scopes the host's
  voice to its current channel. Regression tests in `test/host_service_test.dart`
  cover both directions — do not "optimise" this away.
- Routing rules: audio goes to everyone sharing the sender's channel, except the
  sender; a user on a private call neither sends nor receives group audio; during a
  private call only the two participants hear each other.
- `null` channel means "not scoped yet" and matches everything, so audio flows
  before a user picks a channel.
- **Liveness:** `_lastSeen` is refreshed by any inbound frame; the heartbeat sweep
  evicts clients silent for `AppConstants.clientTimeoutMs`. Without this, sleeping
  or force-killed phones linger in the room.
- **Backpressure:** `_enqueueAudio` tracks unacknowledged frames per socket and
  drops for clients that fall too far behind (reset on each heartbeat).
- Clients reconnect up to `maxReconnectAttempts`; **`ClientService._currentChannelId`
  is re-sent on reconnect** — the host would otherwise treat the device as
  channel-less and leak the whole room to it.

## Audio

`flutter_sound` PCM16, 16000 Hz, mono, ~58 ms frames. Recording streams to
`AudioService.audioStream`; playback runs through a **jitter buffer**
(`_drainJitterBuffer`) that pre-rolls `jitterPrimedFrames` and then feeds one frame
per `audioFrameMs`, dropping the oldest beyond `jitterMaxFrames`. `feedAudioData` is
synchronous and must never block the network read loop.

## State & performance

`micLevelNotifier` on the controller drives the PTT level ring via
`ValueListenableBuilder`. **Do not call `notifyListeners()` from the level stream** —
it fires ~20x/sec and rebuilding the whole screen drops frames. Keep high-frequency
signals on a `ValueNotifier`.

## Permissions

`permission_handler` is in `pubspec.yaml`. Android permissions are declared in `AndroidManifest.xml`
(`RECORD_AUDIO`, `INTERNET`, `ACCESS_NETWORK_STATE`, `ACCESS_WIFI_STATE`,
`CHANGE_WIFI_STATE`, `ACCESS_FINE_LOCATION`, `MODIFY_AUDIO_SETTINGS`, Bluetooth).
Runtime mic permission is requested before recording starts
(`lib/screens/intercom_screen.dart`, `lib/screens/settings_screen.dart`). Hotspot
mode additionally needs location permission (`host_screen.dart`). iOS declares
`NSMicrophoneUsageDescription`, `NSLocalNetworkUsageDescription` and the `audio`
background mode.

## Security posture

Traffic is plaintext `ws://` on the local network and the 4-digit PIN is stored as
a salted SHA-256 digest (`data/app_data.dart`). This deters casual joiners; it is
**not** encryption. Do not describe it as secure in UI copy or docs.

## Conventions

- Dark theme in `lib/theme/app_theme.dart`: background `#0B0F14`, primary `#3DFFA8`,
  secondary `#4DB5FF`, call `#B57BFF`
- `IpUtils.getLocalIpAddress()` prefers `192.168.*` / `10.*` / `172.*` over
  link-local and carrier ranges
- `AppConstants` holds ports, audio params, timeouts and room limits. No magic
  numbers in services or screens.

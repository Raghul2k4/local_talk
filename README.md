# LocalTalk

**Local Wi-Fi push-to-talk intercom.** The phones on the same Wi-Fi become a real-time
voice intercom — no server, no account, no internet connection required.

[![CI](https://github.com/Raghul2k4/local_talk/actions/workflows/ci.yml/badge.svg)](https://github.com/Raghul2k4/local_talk/actions/workflows/ci.yml)
[![Release](https://github.com/Raghul2k4/local_talk/actions/workflows/release.yml/badge.svg)](https://github.com/Raghul2k4/local_talk/actions/workflows/release.yml)
[![Latest release](https://img.shields.io/github/v/release/Raghul2k4/local_talk?label=download)](https://github.com/Raghul2k4/local_talk/releases/latest)

## Download

Prebuilt Android APKs are attached to every
[GitHub Release](https://github.com/Raghul2k4/local_talk/releases/latest).

### Latest release

**Android 5.0+ — [⬇ Download the APK](https://github.com/Raghul2k4/local_talk/releases/latest/download/local-talk-universal-release.apk)**

Or browse [all releases](https://github.com/Raghul2k4/local_talk/releases) and pick the
asset for your device:

| Asset | Use it on |
|-------|-----------|
| `local-talk-universal-release.apk` | Any Android phone or tablet (works everywhere, larger file) |
| `local-talk-arm64-v8a-release.apk` | Modern phones — fastest and smallest |
| `local-talk-armeabi-v7a-release.apk` | Older 32-bit devices |
| `local-talk-x86_64-release.apk` | Emulators and Chromebooks |

Every release also ships a `SHA256SUMS.txt` so you can verify the download:

```bash
sha256sum -c SHA256SUMS.txt
```

### Installing

1. Download the APK on the device you want to install it on.
2. Tap it. Android will ask you to allow installs from this source — grant it for your
   browser/file manager, then go back and confirm.
3. Open LocalTalk and grant the **microphone** permission.

> **iOS:** no prebuilt binary is published — iOS builds need macOS and a signing team.
> Clone the repo and `flutter build ipa`, or see [Building from source](#building-from-source).

### Publishing a release

Push a `v*` tag and the release workflow builds the APKs and attaches them:

```bash
git tag v1.2.0
git push origin v1.2.0
```

The version comes from `local_talk/pubspec.yaml`. Without signing secrets configured the
APK is signed with the debug key — fine for sideloading and testing, not for Play Store.

## What It Does

- **Push-to-talk** — hold the big mic button to speak, quick-tap to lock it on.
- **Group channels** — split the room into General / Team A / Team B; badges show occupancy.
- **Private calls** — tap a user for a one-on-one call; group audio is muted for both of you.
- **Live status** — see who is online, who is transmitting, and connection health.
- **Session stays alive** — wakelock + foreground service keep the room up with the
  screen off, and the audio session survives interruptions.

## Requirements

- Android 5.0+ (prebuilt APK) or iOS 11+ (build from source)
- All devices on the same Wi-Fi network, or a hotspot started from the host device
- Microphone permission
- Port 8080 free on the host device

## Quick Start

### Host a room

1. Open LocalTalk and tap **Create a room**.
2. Enter a room name, optionally protect it with a 4-digit PIN.
3. Tap **Start the room**.
4. Share the `ip:port` shown on the setup screen (tap it to copy).

### Join a room

1. Connect to the same Wi-Fi as the host.
2. Tap **Join a room**.
3. Enter the host's IP, your name, and the PIN if there is one.
4. Tap **Join the room** — your name and last-used host IP are remembered.

### Talk

- **Hold** the big mic button and speak — release to stop.
- **Quick-tap** to lock the mic on; tap again to stop.
- You hear everyone on your channel the whole time you are in the room — there is no
  separate "start intercom" step.
- Switch channels with the chips at the top. You only hear audio from your own channel.
- Tap the phone icon on a user's row for a private call. **End** hangs up and group
  audio returns automatically.

## Settings

- **Your name** — the display name everyone sees.
- **Microphone test** — a 3-second recording with a live level meter.

## Permissions

| Permission | Why |
|------------|-----|
| Microphone | Recording and playback. |
| Local network (iOS) | Required to reach the host on the LAN. |
| Network / Wi-Fi state (Android) | Connectivity check before joining. |
| Nearby Wi-Fi devices (Android 12+) | Programmatic hotspot. |
| Location (Android) | Wi-Fi scanning/toggling is location-gated from API 29. |

## Building from source

Requires Flutter 3.27+ (Dart 3.6+). The app lives in `local_talk/`.

```bash
git clone https://github.com/Raghul2k4/local_talk.git
cd local_talk/local_talk
flutter pub get
flutter run
```

Build an installable APK yourself:

```bash
flutter build apk --release                  # universal APK
flutter build apk --release --split-per-abi # per-ABI APKs, smaller download
```

Output lands in `local_talk/build/app/outputs/flutter-apk/`.

`local_talk/SETUP.md` covers per-platform dependencies, Android manifest permissions and
the iOS `Info.plist` keys.

## Troubleshooting

| Issue | Fix |
|-------|-----|
| IP shows *Detecting…* | Connect the device to Wi-Fi. |
| Cannot connect | Verify the host IP, port 8080, and that both devices are on the same network. |
| "Invalid PIN" | Ask the host for the 4-digit PIN. |
| No sound | Check the mic permission; use the mic test in Settings. |
| Dropped connection | The app auto-reconnects and restores your channel. |
| Someone vanished from the list | Expected — they stopped responding and were evicted after 30 s. |
| Host can't hear anyone | Check the host is on the same channel as the speaker. |
| Android 12+ hotspot fails | Grant the *Nearby Wi-Fi devices* permission when prompted. |
| Installed but no audio on a new device | Re-grant the mic permission; Android resets it on some OEM upgrades. |

## Architecture

Flutter app under `local_talk/`. Entry point: `lib/main.dart` -> `IntercomController`
(Provider `ChangeNotifier`) -> screens.

| Area | Responsibility |
|------|----------------|
| `controllers/intercom_controller.dart` | Single state holder; owns `HostService`, `ClientService`, `AudioService`, `HotspotService`, `SessionKeeper` |
| `services/` | Networking and audio |
| `screens/` | UI; `IntercomScreen` is shared by host and client |
| `widgets/` | Reusable UI; `PttButton` owns the live level ring |
| `utils/constants.dart` | Ports, audio params, timeouts, room limits — no magic numbers in services or screens |

### Networking

- Host: raw `dart:io` `HttpServer` + `WebSocket` on `InternetAddress.anyIPv4:8080`.
- Client: `web_socket_channel` connecting to `ws://hostIp:8080`.
- Both implement `WebSocketService` (`services/websocket_service.dart`), the seam the
  controller talks to.
- Audio is raw PCM16 (`List<int>`) WebSocket frames; control messages are JSON (`WsMessage`).
- **The host is a full participant.** `HostService._routeAudio` feeds the host's own
  `audioStream` (so it hears its channel), and `broadcastAudio` scopes the host's voice
  to its current channel. Regression tests in `test/host_service_test.dart` cover both
  directions — do not "optimise" this away.
- Routing rules: audio goes to everyone sharing the sender's channel, except the sender;
  a user on a private call neither sends nor receives group audio; during a private call
  only the two participants hear each other.
- `null` channel means "not scoped yet" and matches everything, so audio flows before a
  user picks a channel.
- **Liveness:** `_lastSeen` is refreshed by any inbound frame; the heartbeat sweep evicts
  clients silent for `AppConstants.clientTimeoutMs`. Without this, sleeping or force-killed
  phones linger in the room.
- **Backpressure:** `_enqueueAudio` tracks unacknowledged frames per socket and drops for
  clients that fall too far behind (reset on each heartbeat).
- Clients reconnect up to `maxReconnectAttempts`; **`ClientService._currentChannelId` is
  re-sent on reconnect** — the host would otherwise treat the device as channel-less and
  leak the whole room to it.
- Heartbeat every 10 s keeps connections alive; clients auto-reconnect up to 6 times and
  restore their channel. Speaking indicators come from a cheap RMS scan of each frame, so
  the room sees who is actually talking rather than who just holds the mic.

### Audio

`flutter_sound` PCM16, 16 kHz, mono, ~58 ms frames. Recording streams to
`AudioService.audioStream`; playback runs through a **jitter buffer** (`_drainJitterBuffer`)
that pre-rolls `jitterPrimedFrames` and then feeds one frame per `audioFrameMs`, dropping the
oldest beyond `jitterMaxFrames`, so network jitter is not audible. `feedAudioData` is
synchronous and must never block the network read loop.

Bandwidth is roughly 256 kbit/s per transmitting device — see the roadmap for the Opus fix.

### State & performance

`micLevelNotifier` on the controller drives the PTT level ring via `ValueListenableBuilder`.
**Do not call `notifyListeners()` from the level stream** — it fires ~20x/sec and rebuilding
the whole screen drops frames. Keep high-frequency signals on a `ValueNotifier`.

### Conventions

- Dark theme in `lib/theme/app_theme.dart`: background `#0B0F14`, primary `#3DFFA8`,
  secondary `#4DB5FF`, call `#B57BFF`.
- `IpUtils.getLocalIpAddress()` prefers `192.168.*` / `10.*` / `172.*` over link-local and
  carrier ranges.

## Security posture

Traffic is plaintext `ws://` on your local network and the 4-digit PIN is stored as a
salted SHA-256 digest (`data/app_data.dart`). This deters casual joiners; it is **not**
encryption — a 4-digit PIN is brute-forceable and the wire is readable.

Use LocalTalk on a network you trust: a work site, event or game night on a private LAN.
It is not designed for public Wi-Fi, and the published APKs are debug-key signed, so treat
them as pre-release builds.

## Roadmap

Known limitations, highest value first:

1. **Opus audio.** PCM16 costs ~256 kbit/s per transmitting device. Switching both ends to
   `Codec.opus` would cut that roughly 8x, which is what makes rooms of 20+ people
   practical. Needs a codec-negotiation step in `register`/`welcome`.
2. **mDNS discovery.** Users currently type an IP. `NSBonjourServices` was removed from
   `Info.plist` because nothing advertised; reintroducing it alongside real Bonjour browsing
   would remove the most error-prone step in the whole flow.
3. **Replace `flutter_sound`.** It is effectively unmaintained. `record` for capture and a
   stream-capable player for playback, behind the existing `AudioService` seam.
4. **Encrypted transport.** `wss://` with a self-signed certificate and trust-on-first-use.
   Larger change; the PIN alone is not a substitute.
5. **Proper release signing.** Automate a keystore via CI secrets so builds are
   upgrade-safe and Play Store ready.

## Project layout

```
local_talk/
  lib/
    main.dart
    controllers/intercom_controller.dart
    data/app_data.dart
    models/            user, message, channel
    services/          audio, host, client, hotspot, websocket, session_keeper
    screens/           home, host, join, intercom, settings
    theme/app_theme.dart
    widgets/           ptt_button, user_list_tile, channel_selector,
                       connection_status_indicator, incoming_call_dialog, debug_panel
    utils/             constants, ip_utils, network_utils
  test/                host_service_test.dart, client_service_test.dart
  SETUP.md             per-platform setup details
```

## CI

| Workflow | Trigger | What it does |
|----------|---------|--------------|
| `ci.yml` | push / PR to `master` | `dart format`, `flutter analyze --fatal-infos`, `flutter test --coverage` |
| `release.yml` | `v*` tag (or manual) | Builds universal + per-ABI release APKs, computes SHA-256 sums, attaches them to a GitHub Release |

## License

Private / unlicensed — all rights reserved.
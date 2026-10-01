# LocalTalk

Local Wi-Fi Push-to-Talk Intercom

## What It Does

LocalTalk turns phones on the same Wi-Fi network into a real-time voice intercom. One device hosts a room; others join with the host's IP address. Once connected you can:

- **Push-to-talk** — hold the big mic button to speak, quick-tap to lock it on.
- **Group channels** — split the room into General / Team A / Team B.
- **Private calls** — tap a user for a one-on-one call; group audio is muted for both of you.
- **Live status** — see who is online, who is transmitting, and connection health.

## Requirements

- Android 5.0+ or iOS 11+
- All devices on the same Wi-Fi network (or a hotspot from the host device)
- Microphone permission
- Port 8080 available on the host device
- Flutter 3.19+ to build

## Getting Started

### Host a Room

1. Open LocalTalk and tap **Create a room**.
2. Enter a room name, optionally protect it with a 4-digit PIN.
3. Tap **Start the room**.
4. Share the IP address shown on the setup screen (tap the copy icon).

### Join a Room

1. Connect to the same Wi-Fi as the host.
2. Tap **Join a room**.
3. Enter the host's IP, your name, and the PIN if there is one.
4. Tap **Join the room** — your name and last-used IP are remembered.

### How to Talk

1. **Hold** the big mic button and speak — release to stop.
2. **Quick-tap** the button to lock the mic on; tap again to stop.
3. You hear everyone in your channel the whole time you are in the room — no "start intercom" step.

### Group Channels

- Use the chips at the top to switch channels. The badge shows how many people are in each.
- You only hear audio from your own channel.

### Private Calls

1. Tap the phone icon next to a user (or tap their row).
2. Wait for them to accept — you can cancel while it rings.
3. Use **End** to hang up. Group audio returns automatically.

## Settings

- **Your name** — display name shown to everyone.
- **Microphone test** — a 3-second recording with a live level meter.

## Permissions

- **Microphone** — required for audio.
- **Local network** (iOS) — required to reach the host.
- **Network / Wi-Fi state** (Android) — used to check connectivity.

## Troubleshooting

| Issue | Fix |
|-------|-----|
| IP shows Detecting… | Connect the device to Wi-Fi. |
| Cannot connect | Verify the host IP, port 8080, and same network. |
| "Invalid PIN" | Ask the host for the 4-digit PIN. |
| No sound | Check the mic permission; use the mic test in Settings. |
| Dropped connection | The app auto-reconnects and restores your channel. |
| Someone vanished from the list | Expected — they stopped responding and were evicted after 30 s. |
| Host can't hear anyone | Check the host is on the same channel as the speaker. |

## Build & Run

```bash
flutter pub get
flutter run
```

Run tests and static analysis:

```bash
flutter analyze
flutter test
```

CI runs both on every push (`.github/workflows/ci.yml`).

## Roadmap

Known limitations, highest value first:

1. **Opus audio.** PCM16 costs ~256 kbit/s per transmitting device. Switching both
   ends to `Codec.opus` would cut that roughly 8x, which is what makes rooms of
   20+ people practical. Needs a codec-negotiation step in `register`/`welcome`.
2. **mDNS discovery.** Users currently type an IP. `NSBonjourServices` was removed
   from `Info.plist` because nothing advertised; reintroducing it alongside real
   Bonjour browsing would remove the most error-prone step in the whole flow.
3. **Replace `flutter_sound`.** It is effectively unmaintained. `record` for capture
   and a stream-capable player for playback, behind the existing `AudioService` seam.
4. **Encrypted transport.** `wss://` with a self-signed certificate and
   trust-on-first-use. Larger change; the PIN alone is not a substitute.

## Networking Architecture

- Host: raw `dart:io` `HttpServer` + `WebSocket` on `0.0.0.0:8080`.
- Client: `web_socket_channel` connecting to `ws://hostIp:8080`.
- Audio is raw PCM16 (16 kHz mono, ~58 ms frames) over WebSocket.
- Control messages use JSON (`WsMessage`).
- The host is a full participant: it hears its own channel and its voice is
  scoped to its current channel.
- Routing: audio reaches everyone on the sender's channel except the sender;
  a user on a private call neither sends nor receives group audio.
- Heartbeat every 10 s keeps connections alive and evicts silent clients;
  clients auto-reconnect up to 6 times and restore their channel on reconnect.
- Playback runs through a jitter buffer (2-frame pre-roll, bounded queue) so
  network jitter is not audible.
- Speaking indicators are derived from a cheap RMS scan of each frame, so the
  room can see who is actually talking rather than just who holds the mic.

## Security

Traffic is **unencrypted `ws://`** on your local network. The 4-digit room PIN is
stored as a salted SHA-256 digest, which keeps it out of SharedPreferences in
readable form, but a 4-digit PIN is still brute-forceable and the wire itself is
plaintext.

Use LocalTalk on a network you trust. It is designed for a work site, event or
game night on a private LAN — not for use over public Wi-Fi.

## Project Structure

```
lib/
  main.dart
  controllers/
    intercom_controller.dart
  data/
    app_data.dart
  models/
    user.dart
    message.dart
    channel.dart
  services/
    audio_service.dart
    host_service.dart
    client_service.dart
    hotspot_service.dart
    websocket_service.dart
  screens/
    home_screen.dart
    host_screen.dart
    join_screen.dart
    intercom_screen.dart
    settings_screen.dart
  theme/
    app_theme.dart
  widgets/
    ptt_button.dart
    user_list_tile.dart
    channel_selector.dart
    connection_status_indicator.dart
    incoming_call_dialog.dart
    debug_panel.dart
  utils/
    constants.dart
    ip_utils.dart
    network_utils.dart
```

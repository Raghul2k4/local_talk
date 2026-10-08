# LocalTalk Setup

## Requirements

- Flutter 3.27+ (Dart 3.6+)
- Android 5.0+ or iOS 11+
- Two devices on the same Wi-Fi network (or a hotspot from the host device)

## Dependencies

From `pubspec.yaml`:

| Package | Used for |
|---------|----------|
| `flutter_sound` | PCM16 recording and stream playback |
| `web_socket_channel` | Client WebSocket connection |
| `permission_handler` | Runtime mic / location permissions |
| `connectivity_plus` | Wi-Fi / ethernet check before joining |
| `wifi_iot` | Programmatic hotspot (Android only) |
| `qr_flutter` | Rendering the room invite as a QR code |
| `mobile_scanner` | Guest-side camera QR scanning |
| `provider` | State management |
| `shared_preferences` | Remembering name, last host IP, PIN |
| `uuid` | Room and user identifiers |
| `crypto` | Salted SHA-256 hashing of the stored room PIN |

## Android Permissions

Declared in `android/app/src/main/AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.RECORD_AUDIO" />
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
<uses-permission android:name="android.permission.ACCESS_WIFI_STATE" />
<uses-permission android:name="android.permission.CHANGE_WIFI_STATE" />
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
<uses-permission android:name="android.permission.MODIFY_AUDIO_SETTINGS" />
<uses-permission android:name="android.permission.BLUETOOTH" android:maxSdkVersion="30" />
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
<uses-permission android:name="android.permission.CAMERA" />
```

`ACCESS_FINE_LOCATION` is only needed for hotspot mode — Android gates Wi-Fi
scanning/toggling behind location from API 29. `host_screen.dart` requests it at
runtime only when the user enables hotspot mode.

`CAMERA` backs the guest's QR scanner. It is paired with
`<uses-feature android:name="android.hardware.camera" android:required="false" />`
so devices without a camera can still install and fall back to manual entry.

`usesCleartextTraffic="true"` is set on the application tag because intercom audio
travels over plain `ws://`.

## iOS

`ios/Runner/Info.plist` declares `NSMicrophoneUsageDescription`,
`NSLocalNetworkUsageDescription` and the `audio` background mode. iOS 14+ shows the
local-network prompt the first time you host or join; the app cannot reach a host
on your Wi-Fi until the user accepts.

Hotspot hosting is **Android-only** (`HotspotService` returns false elsewhere).
Clients can still join a room hosted by another device on iOS.

## Build & Run

```bash
flutter pub get
flutter run
```

Run on a physical device — audio and hotspot features do not work on most
emulators, and the host needs a real Wi-Fi interface to be reachable.

## Testing

```bash
flutter test
```

`test/host_service_test.dart` starts a real `HostService` on an OS-assigned port
and drives it with raw WebSocket clients, so the wire protocol, channel routing,
host playback and private-call isolation are all covered without a device.

### Manual two-device check

1. Install on device A (host) and device B (guest).
2. Connect both to the same Wi-Fi (or let A start a hotspot and join B to it).
3. On A: **Create a room** -> **Start the room**. The QR code appears.
4. On B: **Join a room** -> enter your name -> **Scan QR code** -> point at A.
5. Both should show as connected within a second or two.
6. Hold the PTT button on A: B should hear it, and A should *not* echo it back.
7. Hold PTT on B: A should hear it.
8. Switch B to a different channel chip and talk: A should hear nothing.
9. Tap the call icon on B's row for A: both should hear each other and no one else.

### Manual negative checks

- Turn on a VPN on the host and start a room: the advertised address must stay
  on the LAN, not switch to the tunnel.
- Scan a QR from a room the host has already closed: the guest must be told the
  room is gone and invited to rescan.
- Deny the microphone, then permanently deny it: the second attempt must offer
  a trip to system settings rather than failing silently.
- Deny camera access: scanning must explain itself and offer manual entry.

## Notes

- Audio is raw PCM16, 16 kHz mono, ~58 ms per WebSocket frame.
- Bandwidth is roughly 256 kbit/s per transmitting device. For larger rooms,
  switching both ends to an Opus codec (`Codec.opus` in `flutter_sound`) would cut
  this by roughly 8x — see the roadmap in the [repository README](../README.md).
- Host audio is routed by channel on the host device; see the
  [repository README](../README.md#networking) for the routing rules and the tests
  that protect them.

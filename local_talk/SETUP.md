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
```

`ACCESS_FINE_LOCATION` is only needed for hotspot mode — Android gates Wi-Fi
scanning/toggling behind location from API 29. `host_screen.dart` requests it at
runtime only when the user enables hotspot mode.

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

1. Install on device A (host) and device B (client).
2. Connect both to the same Wi-Fi.
3. On A: **Create a room** -> **Start the room** -> note the `ip:8080` shown.
4. On B: **Join a room** -> enter that IP and a name -> **Join the room**.
5. Hold the PTT button on A: B should hear it, and A should *not* echo it back.
6. Hold PTT on B: A should hear it.
7. Switch B to a different channel chip and talk: A should hear nothing.
8. Tap the call icon on B's row for A: both should hear each other and no one else.

## Notes

- Audio is raw PCM16, 16 kHz mono, ~58 ms per WebSocket frame.
- Bandwidth is roughly 256 kbit/s per transmitting device. For larger rooms,
  switching both ends to an Opus codec (`Codec.opus` in `flutter_sound`) would cut
  this by roughly 8x — see the roadmap in the [repository README](../README.md).
- Host audio is routed by channel on the host device; see the
  [repository README](../README.md#networking) for the routing rules and the tests
  that protect them.

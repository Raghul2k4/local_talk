import 'dart:io';

class IpUtils {
  static String? _lastKnownIp;

  /// The most recently detected usable IP (null before the first lookup).
  static String? get lastKnownIp => _lastKnownIp;

  static Future<String?> getLocalIpAddress() async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      String? fallback;
      for (final interface in interfaces) {
        for (final addr in interface.addresses) {
          final ip = addr.address;
          if (ip.startsWith('127.') || ip.startsWith('169.254.')) continue;
          // Prefer typical Wi-Fi/LAN ranges over link-local or carrier ranges.
          if (ip.startsWith('192.168.') ||
              ip.startsWith('10.') ||
              ip.startsWith('172.')) {
            _lastKnownIp = ip;
            return ip;
          }
          fallback ??= ip;
        }
      }
      _lastKnownIp ??= fallback;
      return fallback;
    } catch (_) {
      return _lastKnownIp;
    }
  }

  /// Kept for compatibility: hotspot range first, then any LAN address.
  static Future<String?> getHotspotIp() => getLocalIpAddress();

  static Future<String?> getUsableIp() => getLocalIpAddress();
}

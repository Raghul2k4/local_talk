import 'dart:async';
import 'dart:io';

import 'package:wifi_iot/wifi_iot.dart';

class HotspotService {
  bool _isActive = false;
  String? _ssid;
  String? _password;
  String? _ipAddress;

  final StreamController<bool> _statusController =
      StreamController<bool>.broadcast();
  final StreamController<String> _errorController =
      StreamController<String>.broadcast();

  Stream<bool> get statusStream => _statusController.stream;
  Stream<String> get errorStream => _errorController.stream;

  bool get isActive => _isActive;
  String? get ssid => _ssid;
  String? get password => _password;
  String? get ipAddress => _ipAddress;

  Future<bool> startHotspot({String? ssid, String? password}) async {
    if (!Platform.isAndroid) {
      _errorController.add('Hotspot is only supported on Android.');
      return false;
    }

    try {
      _ssid = ssid?.trim().isEmpty ?? true
          ? 'LocalTalk_${DateTime.now().millisecondsSinceEpoch % 10000}'
          : ssid!.trim();
      _password = password?.trim().isEmpty ?? true
          ? _generatePassword()
          : password!.trim();

      final enabled = await WiFiForIoTPlugin.setWiFiAPEnabled(true);
      if (!enabled) {
        _errorController
            .add('Could not enable hotspot. Try again or use Wi-Fi.');
        return false;
      }

      bool hotspotReady = false;
      for (int i = 0; i < 10; i++) {
        await Future.delayed(const Duration(seconds: 1));
        hotspotReady = await WiFiForIoTPlugin.isWiFiAPEnabled();
        if (hotspotReady) break;
      }

      if (!hotspotReady) {
        _errorController.add('Hotspot did not start. Try again or use Wi-Fi.');
        await WiFiForIoTPlugin.setWiFiAPEnabled(false);
        return false;
      }

      final actualSsid = await WiFiForIoTPlugin.getWiFiAPSSID();
      final actualPassword = await WiFiForIoTPlugin.getWiFiAPPreSharedKey();

      if (actualSsid != null && actualSsid.isNotEmpty) {
        _ssid = actualSsid.replaceAll('"', '').trim();
      }
      if (actualPassword != null && actualPassword.isNotEmpty) {
        _password = actualPassword.replaceAll('"', '').trim();
      }

      _ipAddress = await _detectHotspotIp();

      _isActive = true;
      _statusController.add(true);
      return true;
    } catch (e) {
      _errorController.add('Hotspot error: $e');
      return false;
    }
  }

  Future<void> stopHotspot() async {
    try {
      await WiFiForIoTPlugin.setWiFiAPEnabled(false);
    } catch (_) {}
    _isActive = false;
    _ipAddress = null;
    _statusController.add(false);
  }

  Future<String?> _detectHotspotIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );

      for (final interface in interfaces) {
        final name = interface.name.toLowerCase();
        if (name.startsWith('ap') || name.startsWith('wlan')) {
          for (final addr in interface.addresses) {
            final ip = addr.address;
            if (!ip.startsWith('127.') && !ip.startsWith('169.254.')) {
              return ip;
            }
          }
        }
      }

      const hotspotPrefixes = ['192.168.43.', '192.168.137.', '192.168.1.'];
      for (final interface in interfaces) {
        for (final addr in interface.addresses) {
          final ip = addr.address;
          if (hotspotPrefixes.any(ip.startsWith)) {
            return ip;
          }
        }
      }
    } catch (_) {}
    return null;
  }

  String _generatePassword() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final buffer = StringBuffer();
    final seed = DateTime.now().millisecondsSinceEpoch;
    for (int i = 0; i < 8; i++) {
      buffer.write(chars[(seed + i * 7) % chars.length]);
    }
    return buffer.toString();
  }

  void dispose() {
    _statusController.close();
    _errorController.close();
  }
}

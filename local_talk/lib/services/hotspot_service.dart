import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:wifi_iot/wifi_iot.dart';

import '../utils/constants.dart';

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

      // Poll briefly, checking first so a hotspot that is already up does not
      // cost a pointless second of delay.
      var hotspotReady = await WiFiForIoTPlugin.isWiFiAPEnabled();
      for (var i = 0; i < 5 && !hotspotReady; i++) {
        await Future<void>.delayed(
          const Duration(milliseconds: AppConstants.hotspotPollMs),
        );
        hotspotReady = await WiFiForIoTPlugin.isWiFiAPEnabled();
      }

      if (!hotspotReady) {
        _errorController.add(
          'The hotspot did not come up within a few seconds. Try again, or '
          'use Wi-Fi — the room works the same way on either.',
        );
        try {
          await WiFiForIoTPlugin.setWiFiAPEnabled(false);
        } catch (_) {
          // Best effort: we are already reporting a failure.
        }
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
    } on PlatformException catch (e) {
      _errorController.add(_describe(e));
      return false;
    } catch (e) {
      // Never surface a raw exception: `PlatformException.toString()` includes
      // the full Java stack trace, which is unreadable in the UI and tells the
      // user nothing actionable.
      _errorController.add(
        'Could not start the hotspot. Some Android versions block this — '
        'connecting to Wi-Fi and using that network instead works either way.',
      );
      return false;
    }
  }

  /// Turns a [PlatformException] into one actionable sentence.
  ///
  /// Android is inconsistent here: the same failure surfaces as a
  /// `SecurityException`, a `RemoteException` or a bare error code depending on
  /// the OEM and API level, so match on the message text.
  static String _describe(PlatformException e) {
    final text = '${e.code} ${e.message ?? ''}';

    if (text.contains('nearby devices')) {
      return 'Android needs “Nearby devices” permission before it can start a '
          'hotspot. Grant it in Settings, or connect to Wi-Fi instead.';
    }
    if (text.contains('SecurityException')) {
      return 'Android denied permission to start the hotspot. Grant '
          '“Nearby devices” and location in Settings, or use Wi-Fi.';
    }
    if (e.code == 'alreadyActive' || text.contains('already')) {
      return 'A hotspot is already running on this device.';
    }
    // Some OEM builds report a bare failure with no detail; say so plainly
    // rather than leaking internals.
    return 'Could not start the hotspot on this device. Some Android builds '
        'block apps from doing this — using Wi-Fi works either way.';
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

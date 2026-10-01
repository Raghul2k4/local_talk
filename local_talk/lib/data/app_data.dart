import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/constants.dart';

/// Keys used in SharedPreferences.
class _Keys {
  static const username = 'lt.username';
  static const lastHostIp = 'lt.lastHostIp';
  static const lastRoomName = 'lt.lastRoomName';
  static const lastPinHash = 'lt.lastPinHash';
  static const lastPinSalt = 'lt.lastPinSalt';
  static const rememberPin = 'lt.rememberPin';
}

/// Lightweight persistence for the small amount of state worth remembering
/// between sessions: display name, last host IP, room name and optional PIN.
class AppData {
  AppData(this._prefs);

  final SharedPreferences _prefs;

  static Future<AppData> load() async =>
      AppData(await SharedPreferences.getInstance());

  String get username {
    final v = _prefs.getString(_Keys.username);
    return (v == null || v.trim().isEmpty)
        ? AppConstants.defaultUsername
        : v.trim();
  }

  Future<void> setUsername(String value) =>
      _prefs.setString(_Keys.username, value.trim());

  String? get lastHostIp => _prefs.getString(_Keys.lastHostIp);

  Future<void> setLastHostIp(String value) =>
      _prefs.setString(_Keys.lastHostIp, value.trim());

  String? get lastRoomName => _prefs.getString(_Keys.lastRoomName);

  Future<void> setLastRoomName(String value) =>
      _prefs.setString(_Keys.lastRoomName, value.trim());

  /// The remembered PIN, if one was stored.
  ///
  /// The PIN is persisted as a salted SHA-256 digest rather than the plaintext
  /// or a trivially reversible encoding, so it does not sit in
  /// SharedPreferences in a form anyone can read back. This only raises the bar
  /// for casual access: a 4-digit PIN is still brute-forceable offline, and the
  /// transport itself is plaintext `ws://`, so this guards storage — not the
  /// wire. See the security note in README.md.
  String? get lastPin {
    final hash = _prefs.getString(_Keys.lastPinHash);
    final salt = _prefs.getString(_Keys.lastPinSalt);
    if (hash == null || salt == null) return null;
    return _decodePin(hash, salt);
  }

  Future<void> setLastPin(String? value) async {
    if (value == null || value.isEmpty) {
      await _prefs.remove(_Keys.lastPinHash);
      await _prefs.remove(_Keys.lastPinSalt);
      return;
    }
    final salt = _newSalt();
    await _prefs.setString(_Keys.lastPinSalt, salt);
    await _prefs.setString(_Keys.lastPinHash, _hashPin(value, salt));
  }

  static String _newSalt() {
    final rng = Random.secure();
    final bytes = Uint8List.fromList(
        List.generate(AppConstants.pinSaltBytes, (_) => rng.nextInt(256)));
    return base64Encode(bytes);
  }

  static String _hashPin(String pin, String salt) =>
      sha256.convert(utf8.encode('$salt:$pin')).toString();

  /// Recovers the PIN by brute-forcing the small keyspace against the stored
  /// digest. Only ever called on the device, immediately before joining.
  static String? _decodePin(String hash, String salt) {
    for (var i = 0; i < 10000; i++) {
      final candidate = i.toString().padLeft(AppConstants.pinLength, '0');
      if (_hashPin(candidate, salt) == hash) return candidate;
    }
    return null;
  }

  bool get rememberPin => _prefs.getBool(_Keys.rememberPin) ?? false;

  Future<void> setRememberPin(bool value) =>
      _prefs.setBool(_Keys.rememberPin, value);
}

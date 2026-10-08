import 'dart:convert';

/// The connection details a guest needs, encoded into the host's QR code.
///
/// This is the whole point of the QR flow: it carries the exact endpoint the
/// host verified it is reachable on, so the guest never types or guesses an
/// address, and never has to know what a subnet is.
class RoomInvite {
  /// Payload schema version. Bumped if the shape ever changes so an old host's
  /// QR can be rejected with a clear message instead of mis-parsed.
  static const int currentVersion = 1;

  final int version;
  final String ip;

  /// The port the host's server actually bound to, not a hardcoded constant.
  final int port;

  final String roomId;

  /// Per-room secret. Without it, anyone who can reach the port could claim to
  /// be in any room; see `HostService._handleRegister`.
  final String token;

  /// Always `ws` today — the transport is a raw WebSocket.
  final String protocol;

  const RoomInvite({
    required this.ip,
    required this.port,
    required this.roomId,
    required this.token,
    this.protocol = 'ws',
    this.version = currentVersion,
  });

  Map<String, dynamic> toJson() => {
        'v': version,
        'ip': ip,
        'port': port,
        'roomId': roomId,
        'token': token,
        'protocol': protocol,
      };

  /// Compact JSON — kept short because QR density decides whether this stays
  /// scannable at a normal on-screen size.
  String encode() => jsonEncode(toJson());

  /// Parses a scanned payload.
  ///
  /// Tolerant about shape, strict about values: anything that is not a usable
  /// endpoint produces a typed [RoomInviteException] the UI can turn into a
  /// sentence. Never throws something a user would have to decode.
  static RoomInvite decode(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      throw const RoomInviteException('That QR code is empty.');
    }

    Map<String, dynamic>? json;
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map<String, dynamic>) json = decoded;
    } catch (_) {
      // Not JSON at all — fall through to the shared error below.
    }

    if (json == null) {
      throw const RoomInviteException(
        'That QR code is not a LocalTalk invite. Scan the code on the '
        'host screen.',
      );
    }

    final version = _asInt(json['v']) ?? 1;
    if (version > currentVersion) {
      throw const RoomInviteException(
        'This invite was made by a newer version of LocalTalk. Update the app '
        'on the host device and scan again.',
      );
    }

    final ip = (json['ip'] as String?)?.trim() ?? '';
    if (!_isValidIpv4(ip)) {
      throw const RoomInviteException(
        'The address in that QR code is not valid. Have the host restart the '
        'room.',
      );
    }

    final port = _asInt(json['port']);
    if (port == null || port < 1 || port > 65535) {
      throw const RoomInviteException(
        'The port in that QR code is not valid. Have the host restart the '
        'room.',
      );
    }

    final roomId = (json['roomId'] as String?)?.trim() ?? '';
    final token = (json['token'] as String?)?.trim() ?? '';
    if (roomId.isEmpty || token.isEmpty) {
      throw const RoomInviteException(
        'That QR code is missing room details. Have the host restart the room '
        'and scan the new code.',
      );
    }

    final protocol = ((json['protocol'] as String?) ?? 'ws').trim();

    return RoomInvite(
      version: version,
      ip: ip,
      port: port,
      roomId: roomId,
      token: token,
      protocol: protocol,
    );
  }

  static int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is String) return int.tryParse(value);
    return null;
  }

  /// Local copy of the dotted-quad check.
  ///
  /// Duplicated rather than imported on purpose: `RoomInvite` is pure data and
  /// is unit-tested on its own, so it should not drag `dart:io` in through
  /// `ip_utils`.
  static bool _isValidIpv4(String value) {
    final parts = value.split('.');
    if (parts.length != 4) return false;
    for (final part in parts) {
      if (part.isEmpty || part.length > 3) return false;
      if (!RegExp(r'^\d+$').hasMatch(part)) return false;
      if (part.length > 1 && part.startsWith('0')) return false;
      if (int.parse(part) > 255) return false;
    }
    return true;
  }

  /// The address guests should dial, in a form the client can connect to.
  Uri toUri() => Uri.parse('$protocol://$ip:$port');
}

/// A rejected or unreadable invite, carrying a message worth showing.
class RoomInviteException implements Exception {
  final String message;
  const RoomInviteException(this.message);

  @override
  String toString() => message;
}
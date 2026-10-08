import 'dart:io';

/// Coarse classification of a local network interface.
///
/// Android hands back every interface the kernel knows about, mixed together.
/// Classifying them is what lets us tell an address a nearby device can reach
/// from one it never can.
enum NetworkKind {
  /// The soft-AP interface the device serves a hotspot from (`ap0`, `softap`).
  hotspot,

  /// Station-mode Wi-Fi (`wlan0`).
  wifi,

  /// Wired (`eth0`).
  ethernet,

  /// Mobile data (`rmnet_ccmni0`, `pdp0`, `wwan0`). Reachable by nobody else.
  cellular,

  /// A VPN or tunnel (`tun0`, `ppp0`, `wg0`). Reachable by nobody else.
  tunnel,

  /// Anything else we could not classify.
  other,
}

/// One IPv4 address found on one interface, flattened so the selection logic
/// is pure and can be unit-tested without a device.
class NetworkCandidate {
  final String interfaceName;
  final String ip;

  const NetworkCandidate({required this.interfaceName, required this.ip});

  @override
  String toString() => '$interfaceName=$ip';
}

/// The address the host will advertise to guests, and where it came from.
class HostAddress {
  final String ip;
  final NetworkKind kind;
  final String interfaceName;

  const HostAddress({
    required this.ip,
    required this.kind,
    required this.interfaceName,
  });

  /// Short, user-facing description of the network being shared. Used in the
  /// host UI so a wrong network is obvious without understanding IPs.
  String get label => switch (kind) {
        NetworkKind.hotspot => 'Hotspot',
        NetworkKind.wifi => 'Wi-Fi',
        NetworkKind.ethernet => 'Ethernet',
        NetworkKind.cellular => 'Mobile data',
        NetworkKind.tunnel => 'VPN',
        NetworkKind.other => 'Local network',
      };

  @override
  String toString() => '$ip ($label on $interfaceName)';
}

class IpUtils {
  IpUtils._();

  static String? _lastKnownIp;

  /// The most recently detected usable IP (null before the first lookup).
  static String? get lastKnownIp => _lastKnownIp;

  // Interface-name fragments that identify a virtual tunnel. A VPN interface
  // always owns a private address (very often 10.x), which is exactly why the
  // old "first private address wins" rule picked it and handed guests an
  // address that exists only inside this device.
  static const List<String> _tunnelNames = <String>[
    'tun', // tun0, tun1 — Android VPN
    'tap',
    'ppp', // ppp0 — legacy point-to-point
    'wg', // WireGuard
    'ipsec',
    'vpn',
    'tunl', // IPsec tunnel mode
    'tailscale',
    'zerotier',
    'nordlynx',
    'proton',
    'nordvpn',
  ];

  // Interface-name fragments that identify mobile data.
  static const List<String> _cellularNames = <String>[
    'rmnet', // rmnet_ccmni0 — the usual Android data interface
    'ccmni',
    'pdp',
    'wwan',
    'rmnet_data',
  ];

  static bool _nameContainsAny(String name, List<String> fragments) {
    final lower = name.toLowerCase();
    for (final fragment in fragments) {
      if (lower.contains(fragment)) return true;
    }
    return false;
  }

  /// Classifies an interface by name. Name-based because the OS gives us no
  /// better signal through `dart:io`, and interface naming is the one thing
  /// that is consistent enough across Android/iOS/desktop to rely on.
  static NetworkKind classifyInterface(String name) {
    final lower = name.toLowerCase();

    // Anchor the hotspot test on the *prefix*, not a substring. A substring
    // check for "tap" also matches "softap0", which would misclassify a
    // hotspot interface as a VPN tunnel — and then the host would refuse to
    // advertise the very address its own guests need.
    final isHotspotName = lower.startsWith('ap') ||
        lower.startsWith('softap') ||
        lower.startsWith('swlan') ||
        lower.startsWith('wlans') ||
        lower.startsWith('wlan1');
    if (isHotspotName) return NetworkKind.hotspot;

    if (_nameContainsAny(lower, _tunnelNames)) return NetworkKind.tunnel;
    if (_nameContainsAny(lower, _cellularNames)) return NetworkKind.cellular;

    if (lower.startsWith('wlan') || lower.startsWith('wifi')) {
      return NetworkKind.wifi;
    }
    if (lower.startsWith('eth') || lower.startsWith('en')) {
      return NetworkKind.ethernet;
    }

    return NetworkKind.other;
  }
/// Parses a dotted-quad into four ints, or null if it is not valid IPv4.
  ///
  /// Rejects out-of-range octets (`999.1.1.1`) and leading zeros
  /// (`010.1.1.1`), which some resolvers read as octal and which no real host
  /// ever prints.
  static List<int>? _parseOctets(String value) {
    final parts = value.split('.');
    if (parts.length != 4) return null;
    final octets = <int>[];
    for (final part in parts) {
      if (part.isEmpty || part.length > 3) return null;
      if (!RegExp(r'^\d+$').hasMatch(part)) return null;
      if (part.length > 1 && part.startsWith('0')) return null;
      final n = int.parse(part);
      if (n > 255) return null;
      octets.add(n);
    }
    return octets;
  }

  /// Strict IPv4 validation, per the dotted-quad rules.
  ///
  /// Accepts *any* valid IPv4 — private or public, `10.x`, `172.16-31.x` or
  /// `192.168.x`. Deliberately not restricted to a "house" range: the host may
  /// legitimately sit anywhere the user's network puts it.
  static bool isValidIpv4(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty || trimmed.contains(' ')) return false;
    return _parseOctets(trimmed) != null;
  }

  /// True for RFC 1918 private space: `10/8`, `172.16/12`, `192.168/16`.
  ///
  /// A protocol-level range check, not a hardcoded network — the app has to
  /// work on whatever subnet the user's router happens to hand out.
  static bool isPrivateIpv4(String ip) {
    final octets = _parseOctets(ip);
    if (octets == null) return false;
    final first = octets[0];
    if (first == 10) return true;
    if (first == 172) return octets[1] >= 16 && octets[1] <= 31;
    if (first == 192) return octets[1] == 168;
    return false;
  }

  /// Scores how usable an interface is for hosting a room. Higher wins.
  ///
  /// [hotspotActive] reorders the table, because once a hotspot is up guests
  /// join the AP interface specifically — the station-mode address that was
  /// correct a moment ago is now the wrong thing to share.
  static int _score(NetworkKind kind, bool hotspotActive) {
    return switch (kind) {
      NetworkKind.tunnel => -100, // never advertise a VPN address
      NetworkKind.cellular => -50, // carrier NAT: unreachable from the LAN
      NetworkKind.hotspot => hotspotActive ? 100 : 40,
      NetworkKind.wifi => hotspotActive ? 30 : 90,
      NetworkKind.ethernet => hotspotActive ? 30 : 85,
      NetworkKind.other => 10,
    };
  }

  /// Picks the address to advertise, or null when nothing is usable.
  ///
  /// Pure and deterministic: the same candidates always produce the same
  /// answer, which is what makes this testable without a device.
  static HostAddress? selectAddress(
    List<NetworkCandidate> candidates, {
    required bool hotspotActive,
  }) {
    HostAddress? best;

    for (final candidate in candidates) {
      final ip = candidate.ip.trim();
      // Loopback, APIPA and the "any" address are never something a guest can
      // dial.
      if (ip.isEmpty) continue;
      if (ip.startsWith('127.')) continue;
      if (ip.startsWith('169.254.')) continue;
      if (ip == '0.0.0.0') continue;
      if (_parseOctets(ip) == null) continue;

      final kind = classifyInterface(candidate.interfaceName);
      final score = _score(kind, hotspotActive);
      if (score <= 0) continue;

      // Ties break toward a private address, then toward the lower IP so the
      // result does not flap between two equally good interfaces.
      final rank = score * 1000 + (isPrivateIpv4(ip) ? 100 : 0);
      final bestRank = best == null
          ? null
          : _score(best.kind, hotspotActive) * 1000 +
              (isPrivateIpv4(best.ip) ? 100 : 0);
      if (bestRank != null && rank <= bestRank) continue;

      best = HostAddress(
        ip: ip,
        kind: kind,
        interfaceName: candidate.interfaceName,
      );
    }

    return best;
  }

  /// Reads the device's real interfaces and returns the address to advertise.
  static Future<HostAddress?> detectHostAddress({
    required bool hotspotActive,
  }) async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );

      final candidates = <NetworkCandidate>[];
      for (final interface in interfaces) {
        for (final addr in interface.addresses) {
          candidates.add(NetworkCandidate(
            interfaceName: interface.name,
            ip: addr.address,
          ));
        }
      }

      final selected = selectAddress(candidates, hotspotActive: hotspotActive);
      if (selected != null) _lastKnownIp = selected.ip;
      return selected;
    } catch (_) {
      return null;
    }
  }

  /// Every address currently bound to a local interface.
  ///
  /// Used to verify an address we are about to advertise is genuinely ours.
  /// Without this check the app can advertise something it does not own on
  /// that network, and guests will never connect.
  static Future<Set<String>> localIpv4Addresses() async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      return <String>{
        for (final i in interfaces)
          for (final a in i.addresses) a.address,
      };
    } catch (_) {
      return <String>{};
    }
  }

  /// The IP address only, for callers that do not care where it came from.
  static Future<String?> getLocalIpAddress() async {
    final address = await detectHostAddress(hotspotActive: false);
    return address?.ip ?? _lastKnownIp;
  }

  /// Kept for compatibility: hotspot range first, then any LAN address.
  static Future<String?> getHotspotIp() async =>
      (await detectHostAddress(hotspotActive: true))?.ip;

  static Future<String?> getUsableIp() => getLocalIpAddress();
}

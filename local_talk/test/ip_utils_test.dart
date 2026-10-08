import 'package:flutter_test/flutter_test.dart';
import 'package:local_talk/utils/ip_utils.dart';

/// Shorthand for building candidate lists.
NetworkCandidate _c(String iface, String ip) =>
    NetworkCandidate(interfaceName: iface, ip: ip);

void main() {
  group('IPv4 validation', () {
    test('accepts any valid dotted quad, not just a house range', () {
      // The old regex `^(\d{1,3}\.){3}\d{1,3}$` accepted all of these too, but
      // the point of the fix is that *no* range is privileged.
      for (final ip in [
        '10.123.45.67',
        '192.168.1.42',
        '172.16.0.9',
        '172.31.255.254',
        '8.8.8.8',
        '0.0.0.0',
        '255.255.255.255',
      ]) {
        expect(IpUtils.isValidIpv4(ip), isTrue, reason: '$ip is valid IPv4');
      }
    });

    test('rejects out-of-range octets that the old regex allowed', () {
      // `^(\d{1,3}\.){3}\d{1,3}$` matched every one of these, which is how a
      // typo could pass validation and then fail at socket time.
      for (final ip in [
        '999.999.999.999',
        '256.1.1.1',
        '192.168.1.300',
        '1.2.3',
        '1.2.3.4.5',
        '192.168.1',
        '010.1.1.1', // leading zero: read as octal by some resolvers
        '192.168.01.1',
        '192.168.1.-1',
        '192.168.1.a',
        '192.168.1. ',
        '192 .168.1.1',
        '',
      ]) {
        expect(IpUtils.isValidIpv4(ip), isFalse, reason: '$ip is not IPv4');
      }
    });

    test('trims surrounding whitespace before validating', () {
      expect(IpUtils.isValidIpv4('  10.0.0.5  '), isTrue);
    });
  });

  group('private range check', () {
    test('follows RFC 1918 rather than a naive prefix match', () {
      expect(IpUtils.isPrivateIpv4('10.0.0.1'), isTrue);
      expect(IpUtils.isPrivateIpv4('172.16.0.1'), isTrue);
      expect(IpUtils.isPrivateIpv4('172.31.255.255'), isTrue);
      expect(IpUtils.isPrivateIpv4('192.168.1.1'), isTrue);
      // Outside 172.16/12 — these are public space, not the local network.
      expect(IpUtils.isPrivateIpv4('172.15.0.1'), isFalse);
      expect(IpUtils.isPrivateIpv4('172.32.0.1'), isFalse);
      expect(IpUtils.isPrivateIpv4('192.169.0.1'), isFalse);
      expect(IpUtils.isPrivateIpv4('8.8.8.8'), isFalse);
    });
  });

  group('interface classification', () {
    test('identifies tunnels, cellular, hotspot and LAN interfaces', () {
      expect(IpUtils.classifyInterface('tun0'), NetworkKind.tunnel);
      expect(IpUtils.classifyInterface('ppp0'), NetworkKind.tunnel);
      expect(IpUtils.classifyInterface('wg0'), NetworkKind.tunnel);
      expect(IpUtils.classifyInterface('tailscale0'), NetworkKind.tunnel);
      expect(IpUtils.classifyInterface('rmnet_ccmni0'), NetworkKind.cellular);
      expect(IpUtils.classifyInterface('pdp0'), NetworkKind.cellular);
      expect(IpUtils.classifyInterface('ap0'), NetworkKind.hotspot);
      expect(IpUtils.classifyInterface('wlan1'), NetworkKind.hotspot);
      expect(IpUtils.classifyInterface('softap0'), NetworkKind.hotspot);
      expect(IpUtils.classifyInterface('wlan0'), NetworkKind.wifi);
      expect(IpUtils.classifyInterface('eth0'), NetworkKind.ethernet);
    });
  });

  group('advertised address selection', () {
    test('never advertises a VPN address even when it is the first private '
        'address', () {
      // This is the reported bug: a device on a VPN plus Wi-Fi advertised
      // 10.123.x.x from tun0, which no peer on the network can reach.
      final selected = IpUtils.selectAddress(
        [
          _c('tun0', '10.123.45.67'),
          _c('wlan0', '192.168.1.42'),
        ],
        hotspotActive: false,
      );

      expect(selected, isNotNull);
      expect(selected!.ip, '192.168.1.42');
      expect(selected.kind, NetworkKind.wifi);
      expect(selected.interfaceName, 'wlan0');
    });

    test('never advertises a cellular (carrier NAT) address', () {
      final selected = IpUtils.selectAddress(
        [
          _c('rmnet_ccmni0', '10.123.45.67'),
          _c('wlan0', '192.168.1.42'),
        ],
        hotspotActive: false,
      );
      expect(selected!.ip, '192.168.1.42');
    });

    test('returns null when only VPN and cellular interfaces exist', () {
      // Nothing here is reachable by a guest, and inventing an address would
      // put the old failure straight back.
      final none = IpUtils.selectAddress(
        [
          _c('tun0', '10.123.45.67'),
          _c('rmnet_ccmni0', '10.123.99.1'),
          _c('lo', '127.0.0.1'),
        ],
        hotspotActive: false,
      );
      expect(none, isNull);
    });

    test('prefers the hotspot interface once a hotspot is active', () {
      final candidates = [
        _c('wlan0', '192.168.1.42'),
        _c('ap0', '192.168.43.1'),
      ];

      // Without a hotspot the station-mode address is the right answer.
      expect(
        IpUtils.selectAddress(candidates, hotspotActive: false)!.ip,
        '192.168.1.42',
      );
      // With it up, guests join the AP interface — the station address is
      // either gone or no longer the one guests route to.
      final hotspot = IpUtils.selectAddress(candidates, hotspotActive: true)!;
      expect(hotspot.ip, '192.168.43.1');
      expect(hotspot.kind, NetworkKind.hotspot);
      expect(hotspot.label, 'Hotspot');
    });

    test('skips loopback, link-local and the any-address', () {
      final selected = IpUtils.selectAddress(
        [
          _c('lo', '127.0.0.1'),
          _c('wlan0', '169.254.10.5'),
          _c('dummy0', '0.0.0.0'),
          _c('eth0', '172.20.1.4'),
        ],
        hotspotActive: false,
      );
      expect(selected!.ip, '172.20.1.4');
    });

    test('is deterministic regardless of the order interfaces arrive in', () {
      final a = [
        _c('tun0', '10.123.45.67'),
        _c('wlan0', '192.168.1.42'),
        _c('rmnet_ccmni0', '10.99.99.99'),
      ];
      final b = [
        _c('rmnet_ccmni0', '10.99.99.99'),
        _c('wlan0', '192.168.1.42'),
        _c('tun0', '10.123.45.67'),
      ];
      expect(
        IpUtils.selectAddress(a, hotspotActive: false)!.ip,
        IpUtils.selectAddress(b, hotspotActive: false)!.ip,
      );
    });

    test('accepts a 10.x address when it is genuinely the Wi-Fi address', () {
      // "10.x is not a real network" is not a rule. Some routers hand out
      // 10/8 on Wi-Fi, and that address is perfectly reachable.
      final selected = IpUtils.selectAddress(
        [_c('wlan0', '10.0.14.221')],
        hotspotActive: false,
      );
      expect(selected!.ip, '10.0.14.221');
      expect(selected.kind, NetworkKind.wifi);
    });

    test('describes the network in user-facing words', () {
      expect(
        IpUtils.selectAddress([_c('wlan0', '192.168.1.5')],
                hotspotActive: false)!
            .label,
        'Wi-Fi',
      );
      expect(
        IpUtils.selectAddress([_c('ap0', '192.168.43.1')],
                hotspotActive: true)!
            .label,
        'Hotspot',
      );
    });
  });
}

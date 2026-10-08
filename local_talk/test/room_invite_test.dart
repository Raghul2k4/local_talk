import 'package:flutter_test/flutter_test.dart';
import 'package:local_talk/models/room_invite.dart';

void main() {
  group('RoomInvite round trip', () {
    const invite = RoomInvite(
      ip: '10.123.45.67',
      port: 8080,
      roomId: 'ABC123',
      token: 'e6f1a0f2-1111-2222-3333-444455556666',
    );

    test('survives encode → decode unchanged', () {
      final decoded = RoomInvite.decode(invite.encode());
      expect(decoded.ip, '10.123.45.67');
      expect(decoded.port, 8080);
      expect(decoded.roomId, 'ABC123');
      expect(decoded.token, invite.token);
      expect(decoded.protocol, 'ws');
    });

    test('carries the host\'s real bound port, not a constant', () {
      // Tests bind port 0 and get an ephemeral port; the invite has to carry
      // whatever the host actually bound or the QR is a dead end.
      const ephemeral = RoomInvite(
        ip: '127.0.0.1',
        port: 54321,
        roomId: 'R',
        token: 't',
      );
      expect(RoomInvite.decode(ephemeral.encode()).port, 54321);
    });

    test('builds a dialable URI', () {
      expect(invite.toUri().toString(), 'ws://10.123.45.67:8080');
    });
  });

  group('RoomInvite rejects bad payloads', () {
    void expectRejected(String raw, String messageContains) {
      expect(
        () => RoomInvite.decode(raw),
        throwsA(
          isA<RoomInviteException>().having(
            (e) => e.message,
            'message',
            contains(messageContains),
          ),
        ),
      );
    }

    test('rejects a QR that is not ours', () {
      expectRejected('https://example.com', 'not a LocalTalk invite');
      expectRejected('', 'empty');
    });

    test('rejects an invalid IP', () {
      expectRejected('{"v":1,"ip":"999.1.1.1","port":8080,'
          '"roomId":"A","token":"t"}', 'not valid');
      expectRejected('{"v":1,"ip":"","port":8080,"roomId":"A",'
          '"token":"t"}', 'not valid');
    });

    test('rejects an invalid port', () {
      expectRejected('{"v":1,"ip":"10.0.0.1","port":0,'
          '"roomId":"A","token":"t"}', 'port');
      expectRejected('{"v":1,"ip":"10.0.0.1","port":70000,'
          '"roomId":"A","token":"t"}', 'port');
      expectRejected('{"v":1,"ip":"10.0.0.1","port":"abc",'
          '"roomId":"A","token":"t"}', 'port');
    });

    test('rejects an invite with no room credentials', () {
      // A QR without a token is exactly the "anyone can join" case the room
      // validation exists to prevent.
      expectRejected('{"v":1,"ip":"10.0.0.1","port":8080,"roomId":"A"}',
          'missing room details');
      expectRejected('{"v":1,"ip":"10.0.0.1","port":8080,"token":"t"}',
          'missing room details');
    });

    test('refuses a payload from a newer app version', () {
      expectRejected(
        '{"v":99,"ip":"10.0.0.1","port":8080,"roomId":"A","token":"t"}',
        'newer version',
      );
    });

    test('every rejection carries a sentence, never a raw exception', () {
      for (final raw in const ['', 'garbage', '{"v":1}', '{"ip":"x"}']) {
        try {
          RoomInvite.decode(raw);
          fail('expected "$raw" to be rejected');
        } on RoomInviteException catch (e) {
          expect(e.message, isNotEmpty);
          expect(e.message, isNot(contains('Exception')));
        }
      }
    });
  });
}
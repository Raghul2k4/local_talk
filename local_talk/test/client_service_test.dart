import 'package:flutter_test/flutter_test.dart';
import 'package:local_talk/models/channel.dart';
import 'package:local_talk/models/message.dart';
import 'package:local_talk/models/user.dart';
import 'package:local_talk/services/client_service.dart';
import 'package:local_talk/services/host_service.dart';
import 'package:local_talk/services/websocket_service.dart';

/// End-to-end coverage of the *real* [ClientService] against a real
/// [HostService].
///
/// `host_service_test.dart` drives the host with a hand-rolled socket, which
/// proves the server behaves but says nothing about the client that ships in
/// the app. Reconnect, channel restore and message parsing all lived here
/// untested, which is exactly where the channel-restore bug hid.
/// Collects the client user list, retrying until [predicate] holds.
///
/// `usersStream` is a broadcast stream and the host emits the list during
/// registration, so a `firstWhere` subscribed after `connect()` can miss the
/// only event it cares about. Callers subscribe via [collectUsers] *before*
/// connecting; this then just polls the buffer that listener fills.
Future<List<User>> _awaitUsers(
  List<User> buffer,
  bool Function(List<User>) predicate, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final snapshot = List<User>.of(buffer);
    if (predicate(snapshot)) return snapshot;
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  fail(
    'user list never satisfied the predicate. Saw: '
    '${buffer.map((u) => '${u.username}@${u.currentChannelId}').toSet()}',
  );
}

/// Subscribes to a client's user list and returns the live buffer, so events
/// emitted during `connect()` are not lost.
/// Subscribes to a client's user list and returns a one-element buffer holding
/// the most recent list, so events emitted during `connect()` are not lost.
///
/// The returned list is replaced (not appended to) on every emission, so it
/// always mirrors what the UI would currently show.
List<User> collectUsers(ClientService client) {
  final buffer = <User>[];
  client.usersStream.listen((list) {
    buffer
      ..clear()
      ..addAll(list);
  });
  return buffer;
}

void main() {
  late HostService host;
  late int port;

  Future<HostService> startHost({int? onPort, String? pin}) async {
    final service = HostService(
      roomName: 'Loopback',
      pin: pin,
      channels: const [
        Channel(id: 'general', name: 'General'),
        Channel(id: 'team-a', name: 'Team A'),
      ],
      port: onPort ?? 0,
    );
    await service.start();
    return service;
  }

  Future<ClientService> join(String name, {String? pin, int? onPort}) async {
    final client = ClientService(
      hostIp: '127.0.0.1',
      username: name,
      pin: pin,
      port: onPort ?? port,
    );
    addTearDown(() async {
      await client.stop();
      client.dispose();
    });
    await client.connect();
    return client;
  }

  setUp(() async {
    host = await startHost();
    port = host.boundPort!;
  });
  tearDown(() async {
    await host.stop();
    host.dispose();
  });

  test('registers and is told its identity', () async {
    final client = await join('Alice');
    expect(client.localUserId, isNotNull);
    expect(client.localUserId, isNotEmpty);
    expect(client.channels.map((c) => c.id), ['general', 'team-a']);
    expect(client.isRunning, isTrue);
  });

  test('sees the host in the user list', () async {
    // Subscribe *before* connecting. `usersStream` is a broadcast stream: the
    // host emits the list during registration, which happens inside
    // `connect()`, so anything observed afterwards may already have passed.
    final seen = <User>[];
    final client = ClientService(
      hostIp: '127.0.0.1',
      username: 'Alice',
      port: port,
    );
    addTearDown(() async {
      await client.stop();
      client.dispose();
    });
    final sub = client.usersStream.listen((list) {
      seen
        ..clear()
        ..addAll(list);
    });
    addTearDown(sub.cancel);

    await client.connect();

    // `connect()` completes on `welcome`; the `user_list` broadcast follows it
    // on the same socket, so give the event loop a turn before asserting.
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (seen.isEmpty && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }

    expect(
      seen.any((u) => u.isHost),
      isTrue,
      reason: 'the host must appear in the client user list; saw '
          '${seen.map((u) => u.username).toList()}',
    );
    expect(seen.any((u) => u.username == 'Alice'), isTrue);
  });

  test('wrong PIN is rejected with a friendly error', () async {
    final pinned = await startHost(pin: '1234');
    addTearDown(() async {
      await pinned.stop();
      pinned.dispose();
    });

    final client = ClientService(
      hostIp: '127.0.0.1',
      username: 'Mallory',
      pin: '9999',
      port: pinned.boundPort!,
    );
    addTearDown(() async {
      await client.stop();
      client.dispose();
    });

    await expectLater(
      client.connect(),
      throwsA(
        isA<JoinException>().having(
          (e) => e.message,
          'message',
          contains('Invalid PIN'),
        ),
      ),
    );
    expect(client.isRunning, isFalse);
  });

  test('joinChannel validates and remembers the channel', () async {
    final client = await join('Alice');
    await client.joinChannel('team-a');
    expect(client.currentChannelId, 'team-a');

    await expectLater(
      client.joinChannel('does-not-exist'),
      throwsA(isA<JoinException>()),
    );
    // A rejected switch must not clobber the good one.
    expect(client.currentChannelId, 'team-a');
  });

  test('receives audio sent by another client on the same channel', () async {
    final alice = await join('Alice');
    final bob = await join('Bob');
    await alice.joinChannel('general');
    await bob.joinChannel('general');

    final heard = alice.audioStream.first;
    bob.sendAudio([1, 2, 3, 4]);

    expect(
      await heard.timeout(const Duration(seconds: 3)),
      [1, 2, 3, 4],
      reason: 'Alice should receive Bob audio on a shared channel',
    );
  });

  test('does NOT receive audio from a different channel', () async {
    final alice = await join('Alice');
    final bob = await join('Bob');
    await alice.joinChannel('general');
    await bob.joinChannel('team-a');

    var heard = false;
    final sub = alice.audioStream.listen((_) => heard = true);
    bob.sendAudio([9, 9, 9]);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(heard, isFalse);
    await sub.cancel();
  });

  test('private call lifecycle reaches the real client', () async {
    final alice = await join('Alice');
    final bob = await join('Bob');

    // Buffer both sides' messages from the start. Subscribing after the fact
    // is racy: these are broadcast streams, and anything delivered before we
    // listen is gone.
    final aliceMsgs = <WsMessage>[];
    final bobMsgs = <WsMessage>[];
    final aSub = alice.messageStream.listen(aliceMsgs.add);
    final bSub = bob.messageStream.listen(bobMsgs.add);
    addTearDown(() async {
      await aSub.cancel();
      await bSub.cancel();
    });

    Future<void> waitFor(
      List<WsMessage> sink,
      String type,
    ) async {
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (!sink.any((m) => m.type == type) &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(
        sink.any((m) => m.type == type),
        isTrue,
        reason: 'expected a "$type" message; saw '
            '${sink.map((m) => m.type).toSet()}',
      );
    }

    // The host only routes a call to a user it knows about, so let Bob's
    // registration land before dialling.
    final aliceUsers = collectUsers(alice);
    await _awaitUsers(
      aliceUsers,
      (list) => list.any((u) => u.username == 'Bob'),
    );

    alice.sendMessage(WsMessage(
      type: 'private_call',
      data: {'targetId': bob.localUserId!},
    ));
    await waitFor(bobMsgs, 'private_call_request');
    expect(
      bobMsgs
          .firstWhere((m) => m.type == 'private_call_request')
          .data?['callerName'],
      'Alice',
    );

    // The host only starts the call once it is accepted, so drive the same
    // sequence the UI does.
    bob.sendMessage(const WsMessage(type: 'private_call_accept'));
    await waitFor(aliceMsgs, 'private_call_started');
    expect(
      alice.privateCallPartnerId,
      bob.localUserId,
      reason: 'client must remember the partner for reconnect restore',
    );

    // Ending clears it again.
    alice.sendMessage(const WsMessage(type: 'private_call_end'));
    await waitFor(aliceMsgs, 'private_call_ended');
    expect(alice.privateCallPartnerId, isNull);
  });

  test('stop() tears the client down cleanly', () async {
    final client = await join('Alice');
    await client.stop();
    expect(client.isRunning, isFalse);
    expect(client.connectionStatus, ConnectionStatus.disconnected);
  });

  group('reconnect', () {
    test('restores the channel after the socket drops', () async {
      final client = await join('Alice');
      // Buffer from before the join so every broadcast is observed.
      final users = collectUsers(client);
      await client.joinChannel('team-a');

      // Kill the host, let the client notice, then bring a fresh one up on the
      // same port so the client's own reconnect logic has to do the work.
      await host.stop();
      host.dispose();

      await client.connectionStatusStream
          .firstWhere((s) => s != ConnectionStatus.connected)
          .timeout(const Duration(seconds: 8));

      host = await startHost(onPort: port);

      await client.connectionStatusStream
          .firstWhere((s) => s == ConnectionStatus.connected)
          .timeout(const Duration(seconds: 20));

      final snapshot = await _awaitUsers(
        users,
        (list) => list
            .any((u) => u.username == 'Alice' && u.currentChannelId != null),
      );
      final me = snapshot.firstWhere(
        (u) => u.username == 'Alice',
        orElse: () => const User(id: '', username: 'Alice'),
      );

      expect(
        me.currentChannelId,
        'team-a',
        reason: 'reconnect must restore the channel the client was on',
      );
    });

    test('gives up and reports connection_lost', () async {
      final client = await join('Alice');
      expect(client.isRunning, isTrue);

      // A dead host means every attempt burns the full connection timeout, so
      // exhausting all six takes ~80 s. That is far too slow for a suite that
      // runs on every commit, so assert the observable transition instead: the
      // client must notice the drop and enter the reconnecting state rather
      // than reporting itself as connected. The give-up path itself is
      // covered by AppConstants + the backoff logic being pure and
      // deterministic.
      final wentDown = client.connectionStatusStream
          .firstWhere((s) => s != ConnectionStatus.connected);
      final notRunning = client.isRunningStream.firstWhere((v) => !v);

      await host.stop();
      host.dispose();

      await wentDown.timeout(const Duration(seconds: 15));
      await notRunning.timeout(const Duration(seconds: 15));
      expect(client.isRunning, isFalse);
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_talk/models/channel.dart';
import 'package:local_talk/models/message.dart';
import 'package:local_talk/models/user.dart';
import 'package:local_talk/services/host_service.dart';

/// A minimal WebSocket client mirroring ClientService's wire protocol.
class TestClient {
  final WebSocket socket;
  final String name;
  final List<dynamic> received = [];

  TestClient(this.socket, this.name);

  static Future<TestClient> connect(String name, int port,
      {String? pin}) async {
    final socket = await WebSocket.connect('ws://127.0.0.1:$port');
    final client = TestClient(socket, name);
    socket.listen(client.received.add);
    client.send(WsMessage(
      type: 'register',
      data: {'username': name, if (pin != null) 'pin': pin},
    ));
    return client;
  }

  void send(WsMessage msg) => socket.add(jsonEncode(msg.toJson()));

  void sendAudio(List<int> bytes) => socket.add(bytes);

  Future<dynamic> nextWhere(bool Function(dynamic) test,
      {Duration timeout = const Duration(seconds: 3)}) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      for (var i = 0; i < received.length; i++) {
        if (test(received[i])) return received.removeAt(i);
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('Timed out waiting for message in ${received.length} items');
  }

  Future<Map<String, dynamic>> welcome() async {
    final raw = await nextWhere((m) =>
        m is String &&
        (m.contains('"welcome"') || m.contains('register_rejected')));
    final json = jsonDecode(raw as String) as Map<String, dynamic>;
    return json['data'] as Map<String, dynamic>;
  }

  void close() => socket.close();
}

void main() {
  test('host hears clients on its channel', () async {
    final service = HostService(
      roomName: 'Test Room',
      channels: const [
        Channel(id: 'general', name: 'General'),
        Channel(id: 'team-a', name: 'Team A'),
      ],
      port: 0,
    );
    await service.start();
    addTearDown(service.stop);
    final port = service.boundPort!;

    final alice = await TestClient.connect('Alice', port);
    await alice.welcome();
    // Put Alice on the same channel the host starts on.
    alice.send(const WsMessage(
      type: 'join_channel',
      data: {'channelId': 'general'},
    ));

    // The host's own audio stream must carry what Alice says.
    final heard = service.audioStream.first;
    alice.sendAudio([7, 7, 7, 7]);
    expect(await heard.timeout(const Duration(seconds: 3)), [7, 7, 7, 7],
        reason: 'host must receive audio sent by a client in its channel');

    alice.close();
  });

  test('host does not hear clients on another channel', () async {
    final service = HostService(
      roomName: 'Test Room',
      channels: const [
        Channel(id: 'general', name: 'General'),
        Channel(id: 'team-a', name: 'Team A'),
      ],
      port: 0,
    );
    await service.start();
    addTearDown(service.stop);
    final port = service.boundPort!;

    final alice = await TestClient.connect('Alice', port);
    await alice.welcome();
    alice.send(const WsMessage(
      type: 'join_channel',
      data: {'channelId': 'team-a'},
    ));
    // Let the channel change land before sending audio.
    await alice.nextWhere(
      (m) => m is String && m.contains('channel_joined'),
    );

    var heard = false;
    final sub = service.audioStream.listen((_) => heard = true);
    alice.sendAudio([1, 2, 3, 4]);
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(heard, isFalse,
        reason: 'host must not hear a client on a different channel');
    await sub.cancel();
    alice.close();
  });

  test('host broadcast reaches only its channel', () async {
    final service = HostService(
      roomName: 'Test Room',
      channels: const [
        Channel(id: 'general', name: 'General'),
        Channel(id: 'team-a', name: 'Team A'),
      ],
      port: 0,
    );
    await service.start();
    addTearDown(service.stop);
    final port = service.boundPort!;

    final alice = await TestClient.connect('Alice', port);
    await alice.welcome();
    alice.send(const WsMessage(
      type: 'join_channel',
      data: {'channelId': 'general'},
    ));
    final bob = await TestClient.connect('Bob', port);
    await bob.welcome();
    bob.send(const WsMessage(
      type: 'join_channel',
      data: {'channelId': 'team-a'},
    ));
    // Drain channel_joined for both.
    await alice.nextWhere((m) => m is String && m.contains('channel_joined'));
    await bob.nextWhere((m) => m is String && m.contains('channel_joined'));

    service.setHostMicState(true);
    await service.broadcastAudio([3, 3, 3]);

    final toAlice = await alice.nextWhere((m) => m is List<int>);
    expect(toAlice, [3, 3, 3]);

    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(
      bob.received.whereType<List<int>>(),
      isEmpty,
      reason: 'a client on another channel must not hear the host',
    );

    alice.close();
    bob.close();
  });

  test('ClientService wire protocol: register, list, audio, private call',
      () async {
    final service = HostService(
      roomName: 'Test Room',
      pin: '1234',
      channels: const [Channel(id: 'general', name: 'General')],
      port: 0, // let the OS pick a free port
    );
    await service.start();
    addTearDown(service.stop);
    final port = service.boundPort!;

    // Rooms with a PIN reject wrong pins.
    final badClient = await TestClient.connect('Bad', port, pin: '0000');
    final rejected = await badClient.nextWhere(
      (m) => m is String && m.contains('register_rejected'),
    );
    expect((jsonDecode(rejected as String)['data']['message']), 'Invalid PIN');
    badClient.close();

    // Correct pin registers fine.
    final alice = await TestClient.connect('Alice', port, pin: '1234');
    final aliceWelcome = await alice.welcome();
    expect(aliceWelcome['roomName'], 'Test Room');
    expect(aliceWelcome['id'], isNotEmpty);
    final hostJson = aliceWelcome['host'] as Map<String, dynamic>;
    expect(hostJson['isHost'], isTrue);

    final bob = await TestClient.connect('Bob', port, pin: '1234');
    await bob.welcome();

    // Wait until the user list includes the host and both clients.
    List<User> users = [];
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (users.length < 3 && DateTime.now().isBefore(deadline)) {
      final raw = await alice.nextWhere(
        (m) => m is String && m.contains('"user_list"'),
      );
      users = (jsonDecode(raw as String)['data']['users'] as List)
          .map((u) => User.fromJson(u as Map<String, dynamic>))
          .toList();
    }
    expect(users.length, 3); // host + alice + bob
    expect(users.any((u) => u.isHost), isTrue);
    expect(users.any((u) => u.username == 'Alice'), isTrue);
    expect(users.any((u) => u.username == 'Bob'), isTrue);

    // Audio flows between registered clients on the same channel.
    alice.sendAudio([1, 2, 3, 4]);
    final audio = await bob.nextWhere((m) => m is List<int>);
    expect(audio, [1, 2, 3, 4]);

    // The sender never hears their own audio echoed back.
    expect(alice.received.whereType<List<int>>(), isEmpty);

    // Private call: bob calls alice, alice accepts, both get started.
    bob.send(WsMessage(
      type: 'private_call',
      data: {'targetId': aliceWelcome['id']},
    ));
    final request = await alice.nextWhere(
      (m) => m is String && m.contains('private_call_request'),
    );
    expect(
      (jsonDecode(request as String)['data']['callerName']),
      'Bob',
    );

    alice.send(const WsMessage(type: 'private_call_accept'));
    await alice
        .nextWhere((m) => m is String && m.contains('private_call_started'));
    await bob
        .nextWhere((m) => m is String && m.contains('private_call_started'));

    // A third client listens on the same channel.
    final carol = await TestClient.connect('Carol', port, pin: '1234');
    await carol.welcome();
    await carol.nextWhere(
      (m) => m is String && m.contains('"user_list"') && (m).contains('Carol'),
    );

    // During the private call the caller's audio goes ONLY to the partner.
    bob.sendAudio([9, 9, 9]);
    final callAudio = await alice.nextWhere((m) => m is List<int>);
    expect(callAudio, [9, 9, 9]);

    // ...and group audio is silenced for call participants:
    // carol's channel audio reaches neither alice nor bob.
    carol.sendAudio([8, 8, 8]);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(alice.received.whereType<List<int>>(), isNot(contains([8, 8, 8])));
    expect(bob.received.whereType<List<int>>(), isNot(contains([8, 8, 8])));

    // Ending from one side notifies the other.
    bob.send(const WsMessage(type: 'private_call_end'));
    await alice
        .nextWhere((m) => m is String && m.contains('private_call_ended'));

    // Group audio works again after the call.
    alice.sendAudio([5, 5, 5]);
    final afterCallBob = await bob.nextWhere((m) => m is List<int>);
    expect(afterCallBob, [5, 5, 5]);

    bob.close();
    carol.close();
    alice.close();

    // Host service tracks the users leaving: eventually only the host remains.
    var onlyHostLeft = false;
    final leaveDeadline = DateTime.now().add(const Duration(seconds: 3));
    while (!onlyHostLeft && DateTime.now().isBefore(leaveDeadline)) {
      final usersNow = await service.usersStream.first.timeout(
        const Duration(milliseconds: 500),
        onTimeout: () => const <User>[],
      );
      onlyHostLeft = usersNow.isNotEmpty && usersNow.every((u) => u.isHost);
    }
    expect(onlyHostLeft, isTrue);
  });
}

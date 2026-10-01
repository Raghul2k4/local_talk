import 'package:flutter_test/flutter_test.dart';
import 'package:local_talk/data/app_data.dart';
import 'package:local_talk/models/channel.dart';
import 'package:local_talk/models/message.dart';
import 'package:local_talk/models/user.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('User', () {
    test('round-trips through JSON', () {
      const user = User(
        id: 'u1',
        username: 'Alice',
        isHost: false,
        isMicOn: true,
        currentChannelId: 'general',
      );
      final json = user.toJson();
      final back = User.fromJson(json);
      expect(back.id, user.id);
      expect(back.username, user.username);
      expect(back.isHost, user.isHost);
      expect(back.isMicOn, user.isMicOn);
      expect(back.currentChannelId, user.currentChannelId);
    });

    test('tolerates missing JSON fields', () {
      final user = User.fromJson({});
      expect(user.id, '');
      expect(user.username, 'Unknown');
      expect(user.isHost, isFalse);
      expect(user.status, UserStatus.online);
    });

    test('copyWith overrides and preserves', () {
      const user = User(id: 'u1', username: 'Alice');
      final renamed = user.copyWith(username: 'Bob', isMicOn: true);
      expect(renamed.username, 'Bob');
      expect(renamed.isMicOn, isTrue);
      expect(renamed.id, 'u1');
    });

    test('avatarColor is stable for the same id', () {
      const a = User(id: 'abc', username: 'A');
      const b = User(id: 'abc', username: 'B');
      expect(a.avatarColor, b.avatarColor);
    });

    test('host avatar color differs from regular users', () {
      const host = User(id: 'h', username: 'Host', isHost: true);
      const guest = User(id: 'h2', username: 'Guest');
      expect(host.avatarColor, isNot(guest.avatarColor));
    });
  });

  group('Channel', () {
    test('round-trips through JSON', () {
      const channel = Channel(id: 'team-a', name: 'Team A');
      final back = Channel.fromJson(channel.toJson());
      expect(back.id, channel.id);
      expect(back.name, channel.name);
      expect(back.isPrivate, isFalse);
    });

    test('equality is by id', () {
      expect(
        const Channel(id: 'x', name: 'X'),
        const Channel(id: 'x', name: 'Other'),
      );
    });

    test('tolerates missing fields', () {
      final c = Channel.fromJson({});
      expect(c.id, '');
      expect(c.name, 'Channel');
    });
  });

  group('WsMessage', () {
    test('round-trips data payloads', () {
      const msg = WsMessage(type: 'join_channel', data: {
        'channelId': 'general',
      });
      final back = WsMessage.fromJson(msg.toJson());
      expect(back.type, 'join_channel');
      expect(back.data?['channelId'], 'general');
    });

    test('tolerates malformed json shape', () {
      final msg = WsMessage.fromJson({'data': 'not-a-map'});
      expect(msg.type, 'unknown');
      expect(msg.data, isNull);
    });
  });

  group('AppData PIN storage', () {
    late SharedPreferences prefs;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
    });

    test('round-trips a PIN through salted hashing', () async {
      final data = AppData(prefs);
      expect(data.lastPin, isNull);
      await data.setLastPin('4821');
      expect(data.lastPin, '4821');
    });

    test('does not store the PIN in plaintext', () async {
      final data = AppData(prefs);
      await data.setLastPin('4821');
      final stored = prefs.getString('lt.lastPinHash') ?? '';
      expect(stored, isNotEmpty);
      expect(stored, isNot(contains('4821')));
    });

    test('uses a fresh salt each time', () async {
      final data = AppData(prefs);
      await data.setLastPin('4821');
      final first = prefs.getString('lt.lastPinSalt');
      await data.setLastPin('4821');
      expect(prefs.getString('lt.lastPinSalt'), isNot(first));
    });

    test('clearing removes both parts', () async {
      final data = AppData(prefs);
      await data.setLastPin('4821');
      await data.setLastPin(null);
      expect(data.lastPin, isNull);
      expect(prefs.getString('lt.lastPinSalt'), isNull);
    });

    test('a corrupted digest yields null instead of throwing', () async {
      final data = AppData(prefs);
      await data.setLastPin('4821');
      await prefs.setString('lt.lastPinHash', 'not-a-real-digest');
      expect(data.lastPin, isNull);
    });
  });

  group('RoomInfo', () {
    test('never serializes a PIN', () {
      const info = RoomInfo(
        roomId: 'ABCD1234',
        roomName: 'Game Night',
        hasPin: true,
        clientCount: 3,
      );
      expect(info.toJson().containsKey('pin'), isFalse);
      expect(info.hasPin, isTrue);
    });

    test('parses channels from json', () {
      final info = RoomInfo.fromJson({
        'roomId': 'R1',
        'roomName': 'Room',
        'channels': [
          {'id': 'general', 'name': 'General'},
        ],
        'clientCount': 5,
      });
      expect(info.channels, hasLength(1));
      expect(info.channels.first.name, 'General');
      expect(info.clientCount, 5);
    });
  });
}

import 'channel.dart';

class WsMessage {
  final String type;
  final Map<String, dynamic>? data;

  const WsMessage({required this.type, this.data});

  Map<String, dynamic> toJson() {
    return {
      'type': type,
      if (data != null) 'data': data,
    };
  }

  factory WsMessage.fromJson(Map<String, dynamic> json) {
    return WsMessage(
      type: json['type'] as String? ?? 'unknown',
      data: json['data'] is Map<String, dynamic>
          ? json['data'] as Map<String, dynamic>
          : null,
    );
  }
}

class RoomInfo {
  final String roomId;
  final String roomName;
  final List<Channel> channels;
  final int clientCount;
  final bool hasPin;

  const RoomInfo({
    required this.roomId,
    required this.roomName,
    this.channels = const [],
    this.clientCount = 0,
    this.hasPin = false,
  });

  Map<String, dynamic> toJson() {
    return {
      'roomId': roomId,
      'roomName': roomName,
      'channels': channels.map((c) => c.toJson()).toList(),
      'clientCount': clientCount,
      'hasPin': hasPin,
    };
  }

  factory RoomInfo.fromJson(Map<String, dynamic> json) {
    return RoomInfo(
      roomId: json['roomId'] as String? ?? '',
      roomName: json['roomName'] as String? ?? 'Room',
      hasPin: json['hasPin'] as bool? ?? false,
      channels: (json['channels'] as List<dynamic>?)
              ?.map((c) => Channel.fromJson(c as Map<String, dynamic>))
              .toList() ??
          const [],
      clientCount: json['clientCount'] as int? ?? 0,
    );
  }
}

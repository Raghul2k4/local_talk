import '../models/user.dart';
import '../models/message.dart';

enum ConnectionStatus { disconnected, connecting, connected, reconnecting }

/// The seam the controller talks to for either role.
///
/// Both [HostService] and [ClientService] implement this, so anything the
/// controller needs from a live session must be declared here. Downcasting to
/// a concrete service (see the `as HostService` this used to require) means the
/// abstraction is incomplete and the next role will hit the same wall.
abstract class WebSocketService {
  Stream<List<User>> get usersStream;
  Stream<bool> get isRunningStream;
  Stream<String> get errorStream;
  Stream<ConnectionStatus> get connectionStatusStream;
  Stream<RoomInfo> get roomInfoStream;

  /// Audio arriving from the room, already routed by channel and private-call
  /// state. The host hears its own channel; a client hears its channel.
  Stream<List<int>> get audioStream;

  /// Control messages that need the controller's attention (private-call
  /// lifecycle, connection loss). Bulk traffic such as `user_list` and
  /// `room_info` is delivered on the typed streams above instead.
  Stream<WsMessage> get messageStream;

  bool get isRunning;
  Future<void> start();
  Future<void> stop();
  Future<void> sendMessage(WsMessage message);
  Future<void> sendAudio(List<int> audioData);
}

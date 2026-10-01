import '../models/user.dart';
import '../models/message.dart';

enum ConnectionStatus { disconnected, connecting, connected, reconnecting }

abstract class WebSocketService {
  Stream<List<User>> get usersStream;
  Stream<bool> get isRunningStream;
  Stream<String> get errorStream;
  Stream<ConnectionStatus> get connectionStatusStream;
  Stream<RoomInfo> get roomInfoStream;
  bool get isRunning;
  Future<void> start();
  Future<void> stop();
  Future<void> sendMessage(WsMessage message);
  Future<void> sendAudio(List<int> audioData);
}

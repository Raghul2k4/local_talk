import 'package:connectivity_plus/connectivity_plus.dart';

class NetworkUtils {
  /// Whether the device is on Wi-Fi (or ethernet), which is what intercom
  /// traffic needs. Hotspots show up as Wi-Fi on the client side.
  static Future<bool> isWifiConnected() async {
    try {
      final results = await Connectivity().checkConnectivity();
      return results.contains(ConnectivityResult.wifi) ||
          results.contains(ConnectivityResult.ethernet);
    } catch (_) {
      return true; // Don't block the user on a connectivity check failure.
    }
  }
}

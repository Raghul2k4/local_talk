import 'package:flutter/material.dart';

import '../services/websocket_service.dart';
import '../theme/app_theme.dart';

class ConnectionStatusIndicator extends StatelessWidget {
  final ConnectionStatus status;

  const ConnectionStatusIndicator({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    final (color, text, icon) = switch (status) {
      ConnectionStatus.connected => (
          AppTheme.primary,
          'Connected',
          Icons.wifi_rounded,
        ),
      ConnectionStatus.connecting => (
          AppTheme.warning,
          'Connecting…',
          Icons.wifi_tethering_rounded,
        ),
      ConnectionStatus.reconnecting => (
          AppTheme.warning,
          'Reconnecting…',
          Icons.wifi_tethering_error_rounded,
        ),
      ConnectionStatus.disconnected => (
          AppTheme.danger,
          'Disconnected',
          Icons.wifi_off_rounded,
        ),
    };

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: color.withValues(alpha: 0.10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: color, size: 15),
          const SizedBox(width: 8),
          Text(
            text,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w600,
              fontSize: 12.5,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }
}

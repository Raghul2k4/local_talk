import 'package:flutter/material.dart';

import '../controllers/intercom_controller.dart';
import '../theme/app_theme.dart';

class DebugPanel extends StatelessWidget {
  final IntercomController controller;

  const DebugPanel({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    final audio = controller.audioService;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Icon(Icons.bug_report_rounded,
                  size: 16, color: AppTheme.primary),
              const SizedBox(width: 6),
              const Text(
                'Diagnostics',
                style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontWeight: FontWeight.w700,
                  fontSize: 12.5,
                  letterSpacing: 0.4,
                ),
              ),
              const Spacer(),
              Text(
                '${controller.packetsSent} ↑ / ${controller.packetsReceived} ↓ pkts',
                style: const TextStyle(
                    color: AppTheme.textSecondary, fontSize: 11),
              ),
            ],
          ),
          const Divider(height: 16),
          Wrap(
            spacing: 14,
            runSpacing: 6,
            children: [
              _Metric(label: 'Role', value: controller.role.name),
              _Metric(label: 'Status', value: controller.connectionStatus.name),
              _Metric(
                  label: 'Channel', value: controller.currentChannelId ?? '—'),
              _Metric(label: 'Users', value: '${controller.users.length}'),
              _Metric(label: 'Mic', value: controller.isMicOn ? 'on' : 'off'),
              _Metric(
                  label: 'Recording', value: '${audio?.isRecording ?? false}'),
              _Metric(label: 'Playing', value: '${audio?.isPlaying ?? false}'),
              _Metric(
                  label: 'Incoming pkts',
                  value: '${audio?.packetsReceived ?? 0}'),
              _Metric(
                  label: 'Private call',
                  value: controller.isInPrivateCall ? 'active' : 'none'),
              _Metric(label: 'Room', value: controller.roomInfo?.roomId ?? '—'),
            ],
          ),
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  final String label;
  final String value;

  const _Metric({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$label: ',
          style: const TextStyle(color: AppTheme.textSecondary, fontSize: 11),
        ),
        Text(
          value,
          style: const TextStyle(
            color: AppTheme.textPrimary,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

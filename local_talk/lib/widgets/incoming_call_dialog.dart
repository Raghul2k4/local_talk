import 'package:flutter/material.dart';

import '../controllers/intercom_controller.dart';
import '../theme/app_theme.dart';

/// Full-screen style incoming private call dialog.
class IncomingCallDialog extends StatelessWidget {
  final IncomingCall call;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  const IncomingCallDialog({
    super.key,
    required this.call,
    required this.onAccept,
    required this.onDecline,
  });

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.all(28),
        decoration: BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: AppTheme.call.withValues(alpha: 0.4)),
          boxShadow: [
            BoxShadow(
              color: AppTheme.call.withValues(alpha: 0.25),
              blurRadius: 40,
              spreadRadius: 4,
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.ring_volume_rounded,
                color: AppTheme.call, size: 40),
            const SizedBox(height: 12),
            const Text(
              'Private call',
              style: TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 13,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              call.callerName,
              style: const TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 24,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _CallAction(
                  icon: Icons.call_end_rounded,
                  color: AppTheme.danger,
                  label: 'Decline',
                  onTap: onDecline,
                ),
                _CallAction(
                  icon: Icons.call_rounded,
                  color: AppTheme.primary,
                  label: 'Accept',
                  onTap: onAccept,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _CallAction extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  final VoidCallback onTap;

  const _CallAction({
    required this.icon,
    required this.color,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(36),
          child: Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color,
              boxShadow: [
                BoxShadow(
                  color: color.withValues(alpha: 0.4),
                  blurRadius: 16,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: Icon(icon, color: Colors.black, size: 30),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          label,
          style: const TextStyle(
            color: AppTheme.textSecondary,
            fontSize: 12,
          ),
        ),
      ],
    );
  }
}

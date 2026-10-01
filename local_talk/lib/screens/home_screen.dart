import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/intercom_controller.dart';
import '../theme/app_theme.dart';
import 'host_screen.dart';
import 'join_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<IntercomController>();
    final username = controller.username;

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: IconButton(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const SettingsScreen()),
                  ),
                  icon: const Icon(Icons.settings_outlined),
                  tooltip: 'Settings',
                ),
              ),
              const Spacer(flex: 2),
              Container(
                width: 92,
                height: 92,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Color(0x1F3DFFA8),
                  border: Border.fromBorderSide(
                    BorderSide(
                      color: Color(0x803DFFA8),
                      width: 2,
                    ),
                  ),
                ),
                child: const Icon(Icons.sim_card_outlined,
                    size: 44, color: AppTheme.primary),
              ),
              const SizedBox(height: 20),
              const Text(
                'LocalTalk',
                style: TextStyle(
                  fontSize: 34,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Talk to everyone on your Wi-Fi.\nNo internet needed.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: 15,
                  height: 1.4,
                ),
              ),
              const Spacer(flex: 3),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const HostScreen()),
                  ),
                  icon: const Icon(Icons.sensors_rounded),
                  label: const Text('Create a room'),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppTheme.primary,
                    foregroundColor: Colors.black,
                  ),
                ),
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const JoinScreen()),
                  ),
                  icon: const Icon(Icons.link_rounded),
                  label: const Text('Join a room'),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppTheme.surfaceHigh,
                    foregroundColor: AppTheme.textPrimary,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextButton.icon(
                onPressed: () => _showHelpSheet(context),
                icon: const Icon(Icons.help_outline_rounded, size: 18),
                label: const Text('How does it work?'),
              ),
              const SizedBox(height: 8),
              Text(
                'Speaking as $username',
                style: const TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  void _showHelpSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => const Padding(
        padding: EdgeInsets.fromLTRB(24, 20, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'How LocalTalk works',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
            ),
            SizedBox(height: 16),
            _HelpRow(
              icon: Icons.wifi_rounded,
              title: 'Same Wi-Fi',
              text:
                  'All devices must be connected to the same Wi-Fi network (or hotspot).',
            ),
            _HelpRow(
              icon: Icons.sensors_rounded,
              title: 'One device creates',
              text:
                  'One person taps “Create a room” and shares their IP address.',
            ),
            _HelpRow(
              icon: Icons.link_rounded,
              title: 'Everyone joins',
              text:
                  'Others tap “Join a room”, enter that IP and their name. That’s it.',
            ),
            _HelpRow(
              icon: Icons.mic_rounded,
              title: 'Push to talk',
              text:
                  'Hold the big mic button to speak. Quick-tap it to lock the mic on.',
            ),
          ],
        ),
      ),
    );
  }
}

class _HelpRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String text;

  const _HelpRow({
    required this.icon,
    required this.title,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: AppTheme.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, size: 20, color: AppTheme.primary),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(
                  text,
                  style: const TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 13,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

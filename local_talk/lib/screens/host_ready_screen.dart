import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/intercom_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/room_qr.dart';
import 'intercom_screen.dart';

/// Shown right after a room is created.
///
/// The point of this screen is that a host never has to read an IP address
/// aloud. They show the QR, guests scan it, and the details panel below is
/// only there for the fallback case.
class HostReadyScreen extends StatefulWidget {
  const HostReadyScreen({super.key});

  @override
  State<HostReadyScreen> createState() => _HostReadyScreenState();
}

class _HostReadyScreenState extends State<HostReadyScreen> {
  bool _showDetails = false;

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<IntercomController>();
    final roomInfo = controller.roomInfo;
    final invite = controller.invite;
    final hotspot = controller.isHotspotActive;
    final guests = controller.users.where((u) => !u.isHost).length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Room created'),
        automaticallyImplyLeading: false,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            // Room identity — the one thing a host may still need to say out
            // loud, because it is short and does not change when the network
            // does.
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppTheme.surface,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppTheme.outline),
              ),
              child: Row(
                children: [
                  const Icon(Icons.meeting_room_rounded,
                      color: AppTheme.primary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          roomInfo?.roomName ?? 'Room',
                          style: const TextStyle(
                            color: AppTheme.textSecondary,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          roomInfo?.roomId ?? '—',
                          style: const TextStyle(
                            color: AppTheme.textPrimary,
                            fontSize: 22,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 2,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            Center(child: RoomQr(invite: invite)),
            const SizedBox(height: 16),
            Center(
              child: Text(
                guests == 0
                    ? 'Waiting for guests…'
                    : '$guests ${guests == 1 ? 'guest' : 'guests'} connected',
                style: const TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: 6),
            Center(
              child: Text(
                hotspot
                    ? 'Guests should join the hotspot shown below.'
                    : 'Guests should be on this same network.',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: 13,
                ),
              ),
            ),
            const SizedBox(height: 24),
// Hotspot credentials, when we are the one serving the network.
            // Without these a guest has nothing to connect to.
            if (hotspot) ...[
              CopyableRow(
                label: 'Hotspot name',
                value: controller.hotspotSsid ?? '—',
              ),
              const SizedBox(height: 8),
              CopyableRow(
                label: 'Hotspot password',
                value: controller.hotspotPassword ?? '—',
              ),
              const SizedBox(height: 20),
            ],

            // Fallback details. Deliberately collapsed: exposing the endpoint
            // by default is what made people type addresses by hand.
            OutlinedButton.icon(
              onPressed: () => setState(() => _showDetails = !_showDetails),
              icon: Icon(
                _showDetails
                    ? Icons.expand_less_rounded
                    : Icons.expand_more_rounded,
              ),
              label: Text(
                _showDetails
                    ? 'Hide connection details'
                    : 'Show connection details',
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppTheme.textPrimary,
                side: const BorderSide(color: AppTheme.outline),
              ),
            ),
            if (_showDetails) ...[
              const SizedBox(height: 12),
              CopyableRow(
                label: 'Address (fallback — scanning is preferred)',
                value: controller.connectionEndpoint ?? 'Unknown',
                emphasise: true,
              ),
            ],
            const SizedBox(height: 28),

            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                // Replace rather than push: the stack under this screen is
                // Home -> HostReadyScreen, so a push would leave a dead
                // "create a room" form behind the intercom and let the back
                // button walk back into it. This matches the guest path, where
                // JoinScreen also pushReplacement's into the intercom.
                onPressed: () => Navigator.of(context).pushReplacement(
                  MaterialPageRoute(builder: (_) => const IntercomScreen()),
                ),
                icon: const Icon(Icons.mic_rounded),
                label: const Text('Enter the room'),
                style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.primary,
                  foregroundColor: Colors.black,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

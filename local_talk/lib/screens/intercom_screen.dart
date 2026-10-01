import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../controllers/intercom_controller.dart';
import '../services/websocket_service.dart';
import '../theme/app_theme.dart';
import '../utils/ip_utils.dart';
import '../widgets/channel_selector.dart';
import '../widgets/connection_status_indicator.dart';
import '../widgets/debug_panel.dart';
import '../widgets/incoming_call_dialog.dart';
import '../widgets/ptt_button.dart';
import '../widgets/user_list_tile.dart';
import 'home_screen.dart';

class IntercomScreen extends StatefulWidget {
  const IntercomScreen({super.key});

  @override
  State<IntercomScreen> createState() => _IntercomScreenState();
}

class _IntercomScreenState extends State<IntercomScreen> {
  bool _showDebug = false;
  bool _callDialogOpen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _copyIpPrompt());
  }

  /// Hosts see their IP once, with a copy shortcut, right after creating.
  void _copyIpPrompt() {
    final controller = context.read<IntercomController>();
    if (!controller.isHost) return;
    final ip = controller.hotspotIp ?? IpUtils.lastKnownIp;
    if (ip == null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 6),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Share your address: $ip:8080'),
            if (controller.isHotspotActive) ...[
              const SizedBox(height: 6),
              Text('Hotspot: ${controller.hotspotSsid}'),
              Text('Password: ${controller.hotspotPassword}'),
            ],
          ],
        ),
        action: SnackBarAction(
          label: 'COPY',
          onPressed: () async {
            final ip = controller.hotspotIp ?? IpUtils.lastKnownIp;
            if (ip != null) {
              await Clipboard.setData(ClipboardData(text: '$ip:8080'));
            }
          },
        ),
      ),
    );
  }

  String _buildHostEmptyMessage(IntercomController controller) {
    final ip = controller.hotspotIp ?? IpUtils.lastKnownIp ?? 'see snackbar';
    final buffer = StringBuffer(
        'Waiting for people to join…\nShare your address: $ip:8080');
    if (controller.isHotspotActive) {
      buffer.write('\nHotspot: ${controller.hotspotSsid}');
      buffer.write('\nPassword: ${controller.hotspotPassword}');
    }
    return buffer.toString();
  }

  Future<void> _confirmLeave() async {
    final leave = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Leave the room?'),
        content: Text(
          context.read<IntercomController>().isHost
              ? 'Everyone connected will be disconnected.'
              : 'You will stop hearing the conversation.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Stay'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: AppTheme.danger,
              foregroundColor: Colors.white,
            ),
            child: const Text('Leave'),
          ),
        ],
      ),
    );
    if (leave != true || !mounted) return;

    final controller = context.read<IntercomController>();
    await controller.leaveRoom();
    if (!mounted) return;
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => const HomeScreen()),
      (route) => false,
    );
  }

  Future<void> _showIncomingCall() async {
    final controller = context.read<IntercomController>();
    final call = controller.incomingCall;
    if (call == null || _callDialogOpen) return;
    _callDialogOpen = true;
    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => IncomingCallDialog(
          call: call,
          onAccept: () {
            controller.acceptPrivateCall();
            Navigator.pop(dialogContext);
          },
          onDecline: () {
            controller.rejectPrivateCall();
            Navigator.pop(dialogContext);
          },
        ),
      );
    } finally {
      _callDialogOpen = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<IntercomController>();
    final users = controller.users;
    final localUserId = controller.localUserId;
    final inCall = controller.isInPrivateCall;
    final connecting =
        controller.connectionStatus != ConnectionStatus.connected;

    // Trigger the incoming call dialog from state changes.
    if (controller.incomingCall != null && !_callDialogOpen) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _showIncomingCall(),
      );
    }

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmLeave();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                controller.roomInfo?.roomName ?? 'Intercom',
                style:
                    const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
              ),
              Text(
                controller.isHost
                    ? 'Hosting · room ${controller.roomInfo?.roomId ?? ''}'
                    : 'Joined · ${users.length} online',
                style: const TextStyle(
                  fontSize: 11.5,
                  color: AppTheme.textSecondary,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ],
          ),
          actions: [
            IconButton(
              icon: Icon(
                _showDebug ? Icons.bug_report : Icons.bug_report_outlined,
                color: _showDebug ? AppTheme.primary : null,
              ),
              tooltip: 'Diagnostics',
              onPressed: () => setState(() => _showDebug = !_showDebug),
            ),
            IconButton(
              icon: const Icon(Icons.logout_rounded),
              tooltip: 'Leave room',
              onPressed: _confirmLeave,
            ),
          ],
        ),
        body: Column(
          children: [
            ConnectionStatusIndicator(status: controller.connectionStatus),

            // Error banner
            if (controller.error != null)
              Material(
                color: AppTheme.danger.withValues(alpha: 0.12),
                child: InkWell(
                  onTap: controller.clearError,
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Row(
                      children: [
                        const Icon(Icons.error_outline_rounded,
                            color: AppTheme.danger, size: 18),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            controller.error!,
                            style: const TextStyle(
                                color: AppTheme.danger, fontSize: 12.5),
                          ),
                        ),
                        const Icon(Icons.close_rounded,
                            color: AppTheme.danger, size: 16),
                      ],
                    ),
                  ),
                ),
              ),

            // Outgoing call bar (waiting for answer)
            if (controller.isCallingOut)
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: AppTheme.call.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(14),
                  border:
                      Border.all(color: AppTheme.call.withValues(alpha: 0.35)),
                ),
                child: Row(
                  children: [
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: AppTheme.call),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Calling '
                        '${controller.privateCallPartnerName ?? 'user'}…',
                        style: const TextStyle(
                            color: AppTheme.textPrimary, fontSize: 13.5),
                      ),
                    ),
                    GestureDetector(
                      onTap: controller.cancelOutgoingCall,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 7),
                        decoration: BoxDecoration(
                          color: AppTheme.danger,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: const Text(
                          'Cancel',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            fontSize: 12.5,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),

            // Private call bar
            if (inCall)
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: AppTheme.call.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(14),
                  border:
                      Border.all(color: AppTheme.call.withValues(alpha: 0.4)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.call_rounded,
                        color: AppTheme.call, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Private call with '
                        '${controller.privateCallPartnerName ?? 'user'}',
                        style: const TextStyle(
                            color: AppTheme.textPrimary, fontSize: 13.5),
                      ),
                    ),
                    GestureDetector(
                      onTap: controller.endPrivateCall,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 7),
                        decoration: BoxDecoration(
                          color: AppTheme.danger,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: const Row(
                          children: [
                            Icon(Icons.call_end_rounded,
                                color: Colors.white, size: 16),
                            SizedBox(width: 4),
                            Text(
                              'End',
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                                fontSize: 12.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),

            // Channels
            if (controller.channels.isNotEmpty && !inCall)
              ChannelSelector(
                channels: controller.channels,
                selectedChannelId: controller.currentChannelId,
                users: users,
                onChannelSelected: controller.switchChannel,
              ),

            if (_showDebug) DebugPanel(controller: controller),

            // User list
            Expanded(
              child: users.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.people_outline_rounded,
                              size: 48,
                              color: AppTheme.textSecondary
                                  .withValues(alpha: 0.5)),
                          const SizedBox(height: 12),
                          Text(
                            controller.isHost
                                ? _buildHostEmptyMessage(controller)
                                : 'Connecting…',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: AppTheme.textSecondary,
                              fontSize: 13,
                              height: 1.5,
                            ),
                          ),
                        ],
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 4),
                      itemCount: users.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 2),
                      itemBuilder: (context, index) {
                        final user = users[index];
                        return UserListTile(
                          user: user,
                          isCurrentUser: user.id == localUserId,
                          channels: controller.channels,
                          callDisabled: inCall ||
                              controller.incomingCall != null ||
                              connecting,
                          onCall: () => _startPrivateCall(user.id),
                        );
                      },
                    ),
            ),

            // PTT area
            SafeArea(
              top: false,
              child: Container(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
                decoration: const BoxDecoration(
                  color: AppTheme.surface,
                  borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                  border: Border(
                    top: BorderSide(color: AppTheme.outline),
                  ),
                ),
                child: Column(
                  children: [
                    PttButton(
                      isEnabled: !connecting && !inCall,
                      isTalking: controller.isMicOn,
                      level: controller.micLevel,
                      levelNotifier: controller.micLevelNotifier,
                      onStart: controller.startTalking,
                      onStop: controller.stopTalking,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      inCall
                          ? 'Mic is shared during a private call'
                          : controller.isMicOn
                              ? (controller.isHost
                                  ? 'Broadcasting to everyone'
                                  : 'Transmitting to your channel')
                              : 'Hold to talk · quick-tap to lock',
                      style: TextStyle(
                        color: controller.isMicOn
                            ? AppTheme.danger
                            : AppTheme.textSecondary,
                        fontSize: 13,
                        fontWeight: controller.isMicOn
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _startPrivateCall(String userId) async {
    final controller = context.read<IntercomController>();
    final user = controller.users.where((u) => u.id == userId).firstOrNull;
    if (user == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Call ${user.username}?'),
        content: const Text(
          'You will only hear each other while the private call lasts. '
          'The group channel is muted for both of you.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Call'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await controller.initiatePrivateCall(userId);
    }
  }
}

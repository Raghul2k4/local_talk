import 'package:flutter/material.dart';

import '../models/channel.dart';
import '../models/user.dart';
import '../theme/app_theme.dart';

class UserListTile extends StatelessWidget {
  final User user;
  final bool isCurrentUser;
  final List<Channel> channels;
  final VoidCallback? onCall;
  final bool callDisabled;

  const UserListTile({
    super.key,
    required this.user,
    this.isCurrentUser = false,
    this.channels = const [],
    this.onCall,
    this.callDisabled = false,
  });

  @override
  Widget build(BuildContext context) {
    final channelName = _channelName(user.currentChannelId);
    return ListTile(
      onTap: isCurrentUser ? null : onCall,
      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      leading: Stack(
        children: [
          CircleAvatar(
            radius: 20,
            backgroundColor: user.avatarColor.withValues(alpha: 0.22),
            child: Text(
              _initial(user.username),
              style: TextStyle(
                color: user.avatarColor,
                fontWeight: FontWeight.w700,
                fontSize: 17,
              ),
            ),
          ),
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: user.status.color,
                shape: BoxShape.circle,
                border: Border.all(color: AppTheme.surface, width: 2),
              ),
            ),
          ),
        ],
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              user.username,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppTheme.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (isCurrentUser) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: AppTheme.primary.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                'You',
                style: TextStyle(
                  color: AppTheme.primary,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
          if (user.isHost) ...[
            const SizedBox(width: 6),
            const Icon(Icons.home_work_outlined,
                size: 15, color: AppTheme.warning),
          ],
        ],
      ),
      subtitle: Row(
        children: [
          if (channelName != null) ...[
            Text(
              channelName,
              style:
                  const TextStyle(color: AppTheme.textSecondary, fontSize: 12),
            ),
            const SizedBox(width: 8),
          ],
          if (user.isMicOn)
            const Icon(Icons.mic, size: 14, color: AppTheme.primary),
          if (user.isSpeaking)
            const Padding(
              padding: EdgeInsets.only(left: 4),
              child: Icon(Icons.graphic_eq, size: 14, color: AppTheme.primary),
            ),
        ],
      ),
      trailing: (!isCurrentUser && onCall != null)
          ? IconButton(
              onPressed: callDisabled ? null : onCall,
              icon: Icon(
                Icons.call_outlined,
                color: callDisabled
                    ? AppTheme.textSecondary.withValues(alpha: 0.4)
                    : AppTheme.call,
              ),
              tooltip: 'Private call',
            )
          : null,
    );
  }

  String _initial(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return '?';
    return trimmed[0].toUpperCase();
  }

  String? _channelName(String? channelId) {
    if (channelId == null) return null;
    for (final c in channels) {
      if (c.id == channelId) return c.name;
    }
    return null;
  }
}

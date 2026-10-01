import 'package:flutter/material.dart';

import '../models/channel.dart';
import '../models/user.dart';
import '../theme/app_theme.dart';

class ChannelSelector extends StatelessWidget {
  final List<Channel> channels;
  final String? selectedChannelId;
  final List<User> users;
  final ValueChanged<String> onChannelSelected;

  const ChannelSelector({
    super.key,
    required this.channels,
    required this.selectedChannelId,
    required this.users,
    required this.onChannelSelected,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 46,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        itemCount: channels.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final channel = channels[index];
          final isSelected = channel.id == selectedChannelId;
          final members =
              users.where((u) => u.currentChannelId == channel.id).length;
          return GestureDetector(
            onTap: () => onChannelSelected(channel.id),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: isSelected ? AppTheme.primary : AppTheme.surfaceHigh,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: isSelected ? AppTheme.primary : AppTheme.outline,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    channel.name,
                    style: TextStyle(
                      color: isSelected ? Colors.black : AppTheme.textPrimary,
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                  if (members > 0) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? Colors.black.withValues(alpha: 0.15)
                            : AppTheme.primary.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '$members',
                        style: TextStyle(
                          color: isSelected ? Colors.black : AppTheme.primary,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

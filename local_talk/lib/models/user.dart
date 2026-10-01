import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

enum UserStatus { online, away, offline }

class User {
  final String id;
  final String username;
  final bool isHost;
  final UserStatus status;
  final bool isMicOn;
  final bool isSpeaking;
  final String? currentChannelId;

  const User({
    required this.id,
    required this.username,
    this.isHost = false,
    this.status = UserStatus.online,
    this.isMicOn = false,
    this.isSpeaking = false,
    this.currentChannelId,
  });

  User copyWith({
    String? id,
    String? username,
    bool? isHost,
    UserStatus? status,
    bool? isMicOn,
    bool? isSpeaking,
    String? currentChannelId,
  }) {
    return User(
      id: id ?? this.id,
      username: username ?? this.username,
      isHost: isHost ?? this.isHost,
      status: status ?? this.status,
      isMicOn: isMicOn ?? this.isMicOn,
      isSpeaking: isSpeaking ?? this.isSpeaking,
      currentChannelId: currentChannelId ?? this.currentChannelId,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'username': username,
      'isHost': isHost,
      'status': status.name,
      'isMicOn': isMicOn,
      'isSpeaking': isSpeaking,
      if (currentChannelId != null) 'currentChannelId': currentChannelId,
    };
  }

  factory User.fromJson(Map<String, dynamic> json) {
    return User(
      id: json['id'] as String? ?? '',
      username: json['username'] as String? ?? 'Unknown',
      isHost: json['isHost'] as bool? ?? false,
      status: UserStatus.values.firstWhere(
        (s) => s.name == json['status'] as String?,
        orElse: () => UserStatus.online,
      ),
      isMicOn: json['isMicOn'] as bool? ?? false,
      isSpeaking: json['isSpeaking'] as bool? ?? false,
      currentChannelId: json['currentChannelId'] as String?,
    );
  }

  /// Stable accent color derived from the user id (used for avatars).
  Color get avatarColor {
    if (isHost) return AppTheme.warning;
    const palette = [
      AppTheme.secondary,
      AppTheme.call,
      Color(0xFF3DFFA8),
      Color(0xFFFF8FB1),
      Color(0xFF7FD4FF),
      Color(0xFFFFD166),
    ];
    var hash = 0;
    for (final code in id.codeUnits) {
      hash = (hash * 31 + code) & 0x7fffffff;
    }
    return palette[hash % palette.length];
  }
}

extension UserStatusX on UserStatus {
  String get displayName {
    switch (this) {
      case UserStatus.online:
        return 'Online';
      case UserStatus.away:
        return 'Away';
      case UserStatus.offline:
        return 'Offline';
    }
  }

  Color get color {
    switch (this) {
      case UserStatus.online:
        return AppTheme.primary;
      case UserStatus.away:
        return AppTheme.warning;
      case UserStatus.offline:
        return AppTheme.danger;
    }
  }
}

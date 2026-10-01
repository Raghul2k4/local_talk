class Channel {
  final String id;
  final String name;
  final bool isPrivate;

  const Channel({
    required this.id,
    required this.name,
    this.isPrivate = false,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'isPrivate': isPrivate,
    };
  }

  factory Channel.fromJson(Map<String, dynamic> json) {
    return Channel(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? 'Channel',
      isPrivate: json['isPrivate'] as bool? ?? false,
    );
  }

  @override
  bool operator ==(Object other) => other is Channel && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

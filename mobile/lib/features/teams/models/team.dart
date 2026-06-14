import '../../auth/models/user.dart' show UserRole;

class TeamMember {
  const TeamMember({
    required this.id,
    required this.name,
    required this.email,
    required this.role,
    required this.isActive,
    this.profilePhotoUrl,
    this.liveStatus = 'OFFLINE',
  });

  final int id;
  final String name;
  final String email;
  final UserRole role;
  final bool isActive;
  final String? profilePhotoUrl;
  final String liveStatus; // ACTIVE | IDLE | OFFLINE (Redis-derived, read-time)

  String get initials {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty);
    if (parts.isEmpty) return '?';
    return parts.take(2).map((p) => p[0].toUpperCase()).join();
  }

  factory TeamMember.fromJson(Map<String, dynamic> json) => TeamMember(
        id: json['id'] as int,
        name: json['name'] as String,
        email: json['email'] as String,
        role: UserRole.fromWire(json['role'] as String),
        isActive: (json['is_active'] as bool?) ?? true,
        profilePhotoUrl: json['profile_photo_url'] as String?,
        liveStatus: (json['live_status'] as String?) ?? 'OFFLINE',
      );
}

class Team {
  const Team({
    required this.id,
    required this.name,
    required this.memberCount,
    required this.presentToday,
    required this.performancePct,
    this.description,
    this.supervisorId,
    this.supervisorName,
    this.members = const [],
  });

  final int id;
  final String name;
  final int memberCount;
  final int presentToday;
  final double performancePct;
  final String? description;
  final int? supervisorId;
  final String? supervisorName;
  final List<TeamMember> members;

  factory Team.fromJson(Map<String, dynamic> json) => Team(
        id: json['id'] as int,
        name: json['name'] as String,
        memberCount: (json['member_count'] as int?) ?? 0,
        presentToday: (json['present_today'] as int?) ?? 0,
        performancePct: ((json['performance_pct'] as num?) ?? 0).toDouble(),
        description: json['description'] as String?,
        supervisorId: json['supervisor_id'] as int?,
        supervisorName: json['supervisor_name'] as String?,
        members: ((json['members'] as List<dynamic>?) ?? [])
            .map((e) => TeamMember.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

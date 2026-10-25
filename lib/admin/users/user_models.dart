/// One account as `admin_users` returns it. The email is masked by the
/// database; the full address never reaches the browser.
class AdminUser {
  const AdminUser({
    required this.id,
    required this.displayName,
    required this.email,
    required this.providers,
    required this.isAdmin,
    required this.createdAt,
    required this.lastSignInAt,
    required this.bannedUntil,
    required this.deleted,
    required this.reports30d,
    required this.lastReportAt,
  });

  factory AdminUser.fromJson(Map<String, dynamic> json) => AdminUser(
    id: json['id'] as String,
    displayName: json['display_name'] as String? ?? '',
    email: json['email_masked'] as String? ?? '',
    providers: [for (final p in json['providers'] as List? ?? []) p as String],
    isAdmin: json['is_admin'] == true,
    createdAt: _time(json['created_at']),
    lastSignInAt: _time(json['last_sign_in_at']),
    bannedUntil: _time(json['banned_until']),
    deleted: json['deleted'] == true,
    reports30d: (json['reports_30d'] as num?)?.toInt() ?? 0,
    lastReportAt: _time(json['last_report_at']),
  );

  final String id;
  final String displayName;
  final String email;
  final List<String> providers;
  final bool isAdmin;
  final DateTime? createdAt;
  final DateTime? lastSignInAt;

  /// Only a ban still in force; the database drops expired ones.
  final DateTime? bannedUntil;
  final bool deleted;
  final int reports30d;
  final DateTime? lastReportAt;

  bool get banned => bannedUntil != null;

  /// What the page calls an account without a display name.
  String get label => displayName.isEmpty ? '未設定名稱' : displayName;

  /// Ten years or more: the indefinite choice, lifted only by an admin.
  bool get bannedIndefinitely =>
      bannedUntil != null &&
      bannedUntil!.difference(DateTime.now()).inDays > 3650;

  AdminUser withBan(DateTime? until) => AdminUser(
    id: id,
    displayName: displayName,
    email: email,
    providers: providers,
    isAdmin: isAdmin,
    createdAt: createdAt,
    lastSignInAt: lastSignInAt,
    bannedUntil: until,
    deleted: deleted,
    reports30d: reports30d,
    lastReportAt: lastReportAt,
  );
}

/// Report activity counted against `apply_report`'s daily limit (UTC day).
class ReportLimits {
  const ReportLimits({
    required this.today,
    required this.dailyLimit,
    required this.last7d,
    required this.last30d,
    required this.networks30d,
    required this.sharedAccounts30d,
  });

  factory ReportLimits.fromJson(Map<String, dynamic> json) => ReportLimits(
    today: _int(json['today']),
    dailyLimit: _int(json['daily_limit'], 10),
    last7d: _int(json['last_7d']),
    last30d: _int(json['last_30d']),
    networks30d: _int(json['networks_30d']),
    sharedAccounts30d: _int(json['shared_accounts_30d']),
  );

  final int today, dailyLimit, last7d, last30d, networks30d, sharedAccounts30d;
}

class ReportEvent {
  const ReportEvent(this.at, this.network);
  final DateTime? at;

  /// A short tag of the keyed network hash: tells networks apart only.
  final String network;
}

class ReportCounts {
  const ReportCounts(this.values);
  final Map<String, dynamic> values;
  int operator [](String key) => _int(values[key]);
}

/// A community point the account reported, for clearing its public name.
class UserSpot {
  const UserSpot({
    required this.id,
    required this.name,
    required this.place,
    required this.status,
    required this.contributorName,
    required this.nameCleared,
  });

  factory UserSpot.fromJson(Map<String, dynamic> json) => UserSpot(
    id: json['id'] as String,
    name: json['name'] as String? ?? '',
    place: [
      json['city'],
      json['district'],
    ].whereType<String>().where((s) => s.isNotEmpty).join(' '),
    status: json['status'] as String? ?? '',
    contributorName: json['contributor_name'] as String? ?? '',
    nameCleared: json['name_cleared'] == true,
  );

  final String id, name, place, status, contributorName;
  final bool nameCleared;

  UserSpot cleared() => UserSpot(
    id: id,
    name: name,
    place: place,
    status: status,
    contributorName: '',
    nameCleared: true,
  );
}

class UserHistory {
  const UserHistory({
    required this.action,
    required this.note,
    required this.at,
    required this.bannedUntil,
  });
  final String action, note;
  final DateTime? at, bannedUntil;

  String get label => switch (action) {
    'ban_user' => '停權',
    'unban_user' => '解除停權',
    _ => action,
  };
}

class AdminUserDetail {
  const AdminUserDetail({
    required this.user,
    required this.limits,
    required this.events,
    required this.reports,
    required this.spots,
    required this.history,
  });

  factory AdminUserDetail.fromJson(Map<String, dynamic> json) =>
      AdminUserDetail(
        user: AdminUser.fromJson(json['user'] as Map<String, dynamic>),
        limits: ReportLimits.fromJson(
          json['limits'] as Map<String, dynamic>? ?? const {},
        ),
        events: [
          for (final e in json['events'] as List? ?? [])
            ReportEvent(
              _time((e as Map)['created_at']),
              e['network'] as String? ?? '',
            ),
        ],
        reports: ReportCounts(
          json['reports'] as Map<String, dynamic>? ?? const {},
        ),
        spots: [
          for (final s in json['spots'] as List? ?? [])
            UserSpot.fromJson(s as Map<String, dynamic>),
        ],
        history: [
          for (final h in json['history'] as List? ?? [])
            UserHistory(
              action: (h as Map)['action'] as String? ?? '',
              note: h['note'] as String? ?? '',
              at: _time(h['created_at']),
              bannedUntil: _time(h['banned_until']),
            ),
        ],
      );

  final AdminUser user;
  final ReportLimits limits;
  final List<ReportEvent> events;
  final ReportCounts reports;
  final List<UserSpot> spots;
  final List<UserHistory> history;

  AdminUserDetail copyWith({AdminUser? user, List<UserSpot>? spots}) =>
      AdminUserDetail(
        user: user ?? this.user,
        limits: limits,
        events: events,
        reports: reports,
        spots: spots ?? this.spots,
        history: history,
      );
}

/// The ban lengths the `admin-users` function accepts.
enum BanLength {
  week('7d', '7 天'),
  month('30d', '30 天'),
  indefinite('indefinite', '直到解除');

  const BanLength(this.key, this.label);
  final String key, label;
}

DateTime? _time(Object? value) =>
    value is String ? DateTime.tryParse(value)?.toLocal() : null;

int _int(Object? value, [int fallback = 0]) => switch (value) {
  num n => n.toInt(),
  String s => int.tryParse(s) ?? fallback,
  _ => fallback,
};

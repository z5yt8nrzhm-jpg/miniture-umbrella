/// What the club knows, as the app sees it. Each class reads the JSON the
/// database functions return (see supabase/migrations) and can write itself
/// back out, so the last known answer can be saved on the phone.
library;

int _int(Object? v, [int fallback = 0]) => v is num ? v.toInt() : (v is String ? int.tryParse(v) ?? fallback : fallback);
DateTime? _time(Object? v) => v is String ? DateTime.tryParse(v)?.toLocal() : null;
List<Map<String, dynamic>> _maps(Object? v) =>
    v is List ? [for (final x in v) if (x is Map) Map<String, dynamic>.from(x)] : const [];

// ── studio time ────────────────────────────────────────────────────────────
// The studio runs on Phoenix time, UTC-7 all year (Arizona has no daylight
// saving). Class times are shown that way for everyone, so "5:00 pm" means
// the same thing to a member visiting from another time zone.
const studioUtcOffset = Duration(hours: -7);
DateTime studioTime(DateTime t) => t.toUtc().add(studioUtcOffset);

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

String clockLabel(DateTime t) {
  final s = studioTime(t);
  final h = s.hour % 12 == 0 ? 12 : s.hour % 12;
  return '$h:${s.minute.toString().padLeft(2, '0')} ${s.hour < 12 ? 'am' : 'pm'}';
}

String dayLabel(DateTime t, {DateTime? now}) {
  final s = studioTime(t), n = studioTime(now ?? DateTime.now());
  final today = DateTime.utc(n.year, n.month, n.day), that = DateTime.utc(s.year, s.month, s.day);
  final diff = that.difference(today).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Tomorrow';
  if (diff == -1) return 'Yesterday';
  return '${_days[s.weekday - 1]} ${_months[s.month - 1]} ${s.day}';
}

String monthYear(DateTime t) {
  final s = studioTime(t);
  return '${_months[s.month - 1]} ${s.year}';
}

// ── the catalog (rarely changes, so it is cached) ──────────────────────────
class ClassType {
  final String code, name, pace, blurb;
  final int sort;
  const ClassType(this.code, this.name, this.pace, this.blurb, this.sort);
  factory ClassType.fromJson(Map<String, dynamic> j) =>
      ClassType(j['code'] as String, j['name'] as String, (j['pace'] ?? 'steady') as String, (j['blurb'] ?? '') as String, _int(j['sort']));
  Map<String, Object?> toJson() => {'code': code, 'name': name, 'pace': pace, 'blurb': blurb, 'sort': sort};
}

class BadgeDef {
  final String code, title, blurb, kind;
  final int threshold, sort;
  const BadgeDef(this.code, this.title, this.blurb, this.kind, this.threshold, this.sort);
  factory BadgeDef.fromJson(Map<String, dynamic> j) => BadgeDef(j['code'] as String, j['title'] as String,
      (j['blurb'] ?? '') as String, (j['kind'] ?? 'classes') as String, _int(j['threshold'], 1), _int(j['sort']));
  Map<String, Object?> toJson() => {'code': code, 'title': title, 'blurb': blurb, 'kind': kind, 'threshold': threshold, 'sort': sort};
  bool get isStreak => kind == 'streak';
}

class PerkDef {
  final String code, title, blurb;
  final int requiredClasses, sort;
  const PerkDef(this.code, this.title, this.blurb, this.requiredClasses, this.sort);
  factory PerkDef.fromJson(Map<String, dynamic> j) => PerkDef(j['code'] as String, j['title'] as String,
      (j['blurb'] ?? '') as String, _int(j['required_classes'], 1), _int(j['sort']));
  Map<String, Object?> toJson() => {'code': code, 'title': title, 'blurb': blurb, 'required_classes': requiredClasses, 'sort': sort};
}

class Catalog {
  final List<ClassType> classTypes;
  final List<BadgeDef> badges;
  final List<PerkDef> perks;
  const Catalog({this.classTypes = const [], this.badges = const [], this.perks = const []});
  static const empty = Catalog();
  bool get isEmpty => classTypes.isEmpty && badges.isEmpty && perks.isEmpty;

  String className(String code) => classTypes.where((c) => c.code == code).firstOrNull?.name ?? _titleCase(code);
  BadgeDef? badge(String code) => badges.where((b) => b.code == code).firstOrNull;
  PerkDef? perk(String code) => perks.where((p) => p.code == code).firstOrNull;

  factory Catalog.fromJson(Map<String, dynamic> j) => Catalog(
        classTypes: [for (final m in _maps(j['class_types'])) ClassType.fromJson(m)]..sort((a, b) => a.sort.compareTo(b.sort)),
        badges: [for (final m in _maps(j['badges'])) BadgeDef.fromJson(m)]..sort((a, b) => a.sort.compareTo(b.sort)),
        perks: [for (final m in _maps(j['perks'])) PerkDef.fromJson(m)]..sort((a, b) => a.sort.compareTo(b.sort)),
      );
  Map<String, Object?> toJson() => {
        'class_types': [for (final c in classTypes) c.toJson()],
        'badges': [for (final b in badges) b.toJson()],
        'perks': [for (final p in perks) p.toJson()],
      };
}

String _titleCase(String code) =>
    code.split('_').map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1)).join(' ');

// ── the member ─────────────────────────────────────────────────────────────
const avatars = ['sage', 'clay', 'gold', 'sky', 'rose'];

class Profile {
  final String displayName, avatar;
  final String? favoriteClass;
  final int memberNumber;
  final DateTime? memberSince;
  const Profile({required this.displayName, required this.memberNumber, this.avatar = 'sage', this.favoriteClass, this.memberSince});
  factory Profile.fromJson(Map<String, dynamic> j) => Profile(
        displayName: (j['display_name'] ?? '') as String,
        memberNumber: _int(j['member_number']),
        avatar: (j['avatar'] ?? 'sage') as String,
        favoriteClass: j['favorite_class'] as String?,
        memberSince: _time(j['member_since']),
      );
  Map<String, Object?> toJson() => {
        'display_name': displayName, 'member_number': memberNumber, 'avatar': avatar,
        'favorite_class': favoriteClass, 'member_since': memberSince?.toUtc().toIso8601String(),
      };
}

class EarnedBadge {
  final String code;
  final DateTime? earnedAt;
  const EarnedBadge(this.code, this.earnedAt);
}

class EarnedPerk {
  final String id, code;
  final DateTime? earnedAt, redeemedAt;
  const EarnedPerk(this.id, this.code, this.earnedAt, this.redeemedAt);
  bool get redeemed => redeemedAt != null;
}

class MemberStats {
  final bool hasProfile;
  final Profile? profile;
  final int totalClasses, currentStreak, longestStreak, classesThisWeek;
  final DateTime? lastCheckInAt, fetchedAt;
  final List<EarnedBadge> badges;
  final List<EarnedPerk> perks;
  const MemberStats({
    this.hasProfile = false, this.profile, this.totalClasses = 0, this.currentStreak = 0, this.longestStreak = 0,
    this.classesThisWeek = 0, this.lastCheckInAt, this.fetchedAt, this.badges = const [], this.perks = const [],
  });

  bool hasBadge(String code) => badges.any((b) => b.code == code);

  MemberStats copyWith({int? totalClasses, int? currentStreak, int? longestStreak, int? classesThisWeek, DateTime? lastCheckInAt, List<EarnedBadge>? badges}) => MemberStats(
        hasProfile: hasProfile, profile: profile, totalClasses: totalClasses ?? this.totalClasses,
        currentStreak: currentStreak ?? this.currentStreak, longestStreak: longestStreak ?? this.longestStreak,
        classesThisWeek: classesThisWeek ?? this.classesThisWeek, lastCheckInAt: lastCheckInAt ?? this.lastCheckInAt,
        fetchedAt: fetchedAt, badges: badges ?? this.badges, perks: perks,
      );

  factory MemberStats.fromJson(Map<String, dynamic> j, {DateTime? fetchedAt}) => MemberStats(
        hasProfile: j['has_profile'] == true,
        profile: j['profile'] is Map ? Profile.fromJson(Map<String, dynamic>.from(j['profile'] as Map)) : null,
        totalClasses: _int(j['total_classes']),
        currentStreak: _int(j['current_streak']),
        longestStreak: _int(j['longest_streak']),
        classesThisWeek: _int(j['classes_this_week']),
        lastCheckInAt: _time(j['last_checkin_at']),
        fetchedAt: fetchedAt ?? DateTime.now(),
        badges: [for (final b in _maps(j['badges'])) EarnedBadge(b['code'] as String, _time(b['earned_at']))],
        perks: [for (final p in _maps(j['perks'])) EarnedPerk(p['id'] as String, p['code'] as String, _time(p['earned_at']), _time(p['redeemed_at']))],
      );

  Map<String, Object?> toJson() => {
        'has_profile': hasProfile, 'profile': profile?.toJson(),
        'total_classes': totalClasses, 'current_streak': currentStreak, 'longest_streak': longestStreak,
        'classes_this_week': classesThisWeek, 'last_checkin_at': lastCheckInAt?.toUtc().toIso8601String(),
        'badges': [for (final b in badges) {'code': b.code, 'earned_at': b.earnedAt?.toUtc().toIso8601String()}],
        'perks': [for (final p in perks) {'id': p.id, 'code': p.code, 'earned_at': p.earnedAt?.toUtc().toIso8601String(), 'redeemed_at': p.redeemedAt?.toUtc().toIso8601String()}],
      };
}

// ── classes and check-in ───────────────────────────────────────────────────
class StudioClass {
  final String id, classType, instructor;
  final DateTime startsAt;
  final int durationMin;
  final int? capacity;
  const StudioClass({required this.id, required this.classType, required this.instructor, required this.startsAt, this.durationMin = 50, this.capacity});
  factory StudioClass.fromJson(Map<String, dynamic> j) => StudioClass(
        id: j['id'] as String, classType: j['class_type'] as String, instructor: (j['instructor'] ?? '') as String,
        startsAt: _time(j['starts_at']) ?? DateTime.now(), durationMin: _int(j['duration_min'], 50),
        capacity: j['capacity'] == null ? null : _int(j['capacity']),
      );
  Map<String, Object?> toJson() => {
        'id': id, 'class_type': classType, 'instructor': instructor, 'starts_at': startsAt.toUtc().toIso8601String(),
        'duration_min': durationMin, 'capacity': capacity,
      };
  DateTime get endsAt => startsAt.add(Duration(minutes: durationMin));
}

enum CheckInStatus { ok, already, invalid, closed, limit, throttled, noProfile }

class CheckInResult {
  final CheckInStatus status;
  final StudioClass? studioClass;
  final int totalClasses, currentStreak;
  final List<String> newBadges, newPerks;
  const CheckInResult(this.status, {this.studioClass, this.totalClasses = 0, this.currentStreak = 0, this.newBadges = const [], this.newPerks = const []});

  /// A class counted, now or on an earlier tap of the same code.
  bool get counted => status == CheckInStatus.ok || status == CheckInStatus.already;

  factory CheckInResult.fromJson(Map<String, dynamic> j) {
    final status = switch (j['status']) {
      'ok' => CheckInStatus.ok,
      'already' => CheckInStatus.already,
      'closed' => CheckInStatus.closed,
      'limit' => CheckInStatus.limit,
      'throttled' => CheckInStatus.throttled,
      'no_profile' => CheckInStatus.noProfile,
      _ => CheckInStatus.invalid,
    };
    final stats = j['stats'] is Map ? Map<String, dynamic>.from(j['stats'] as Map) : const <String, dynamic>{};
    return CheckInResult(
      status,
      studioClass: j['class'] is Map ? StudioClass.fromJson({...Map<String, dynamic>.from(j['class'] as Map)}) : null,
      totalClasses: _int(stats['total_classes']),
      currentStreak: _int(stats['current_streak']),
      newBadges: [for (final b in (j['new_badges'] as List? ?? const [])) b as String],
      newPerks: [for (final p in (j['new_perks'] as List? ?? const [])) p as String],
    );
  }
}

// ── the wall ───────────────────────────────────────────────────────────────
class WallPost {
  final String id, authorName, authorAvatar, body;
  final DateTime createdAt;

  /// The server's own timestamp text. Paging sends this back untouched: a
  /// parsed DateTime keeps only milliseconds on the web, while the database
  /// orders posts to the microsecond, so a parsed value could skip a post.
  final String cursor;
  final int cheers;
  final bool cheeredByMe, isMine;
  WallPost({
    required this.id, required this.authorName, this.authorAvatar = 'sage', required this.body,
    required this.createdAt, String? cursor, this.cheers = 0, this.cheeredByMe = false, this.isMine = false,
  }) : cursor = cursor ?? createdAt.toUtc().toIso8601String();
  WallPost copyWith({int? cheers, bool? cheeredByMe}) => WallPost(
        id: id, authorName: authorName, authorAvatar: authorAvatar, body: body, createdAt: createdAt, cursor: cursor,
        cheers: cheers ?? this.cheers, cheeredByMe: cheeredByMe ?? this.cheeredByMe, isMine: isMine,
      );
  factory WallPost.fromJson(Map<String, dynamic> j) => WallPost(
        id: j['id'] as String, authorName: (j['author_name'] ?? 'A member') as String,
        authorAvatar: (j['author_avatar'] ?? 'sage') as String, body: (j['body'] ?? '') as String,
        createdAt: _time(j['created_at']) ?? DateTime.now(), cursor: j['created_at'] is String ? j['created_at'] as String : null,
        cheers: _int(j['cheers']), cheeredByMe: j['cheered_by_me'] == true, isMine: j['is_mine'] == true,
      );
  Map<String, Object?> toJson() => {
        'id': id, 'author_name': authorName, 'author_avatar': authorAvatar, 'body': body,
        'created_at': cursor, 'cheers': cheers, 'cheered_by_me': cheeredByMe, 'is_mine': isMine,
      };
}

enum PostStatus { ok, invalidBody, rateLimited, noProfile }

class PostResult {
  final PostStatus status;
  final String? id;
  final bool duplicate;
  const PostResult(this.status, {this.id, this.duplicate = false});
  factory PostResult.fromJson(Map<String, dynamic> j) => PostResult(
        switch (j['status']) {
          'ok' => PostStatus.ok,
          'rate_limited' => PostStatus.rateLimited,
          'no_profile' => PostStatus.noProfile,
          _ => PostStatus.invalidBody,
        },
        id: j['id'] as String?, duplicate: j['duplicate'] == true,
      );
}

/// A post written on the phone that the server has not confirmed yet. It is
/// kept on the phone until it is, and keeps the same id on every retry so it
/// can never be posted twice.
class PendingPost {
  final String clientId, body;
  final DateTime createdAt;
  const PendingPost(this.clientId, this.body, this.createdAt);
  factory PendingPost.fromJson(Map<String, dynamic> j) =>
      PendingPost(j['client_id'] as String, j['body'] as String, _time(j['created_at']) ?? DateTime.now());
  Map<String, Object?> toJson() => {'client_id': clientId, 'body': body, 'created_at': createdAt.toUtc().toIso8601String()};
}

// ── staff ──────────────────────────────────────────────────────────────────
class StaffClass {
  final StudioClass studioClass;
  final String code;
  final int checkins;
  const StaffClass(this.studioClass, this.code, this.checkins);
  factory StaffClass.fromJson(Map<String, dynamic> j) => StaffClass(StudioClass.fromJson(j), (j['code'] ?? '') as String, _int(j['checkins']));
}

class MemberLookup {
  final bool found;
  final String displayName;
  final int memberNumber, totalClasses, currentStreak;
  final List<LookupPerk> perks;
  const MemberLookup({this.found = false, this.displayName = '', this.memberNumber = 0, this.totalClasses = 0, this.currentStreak = 0, this.perks = const []});
  factory MemberLookup.fromJson(Map<String, dynamic> j) {
    if (j['status'] != 'ok') return const MemberLookup();
    final stats = j['stats'] is Map ? Map<String, dynamic>.from(j['stats'] as Map) : const <String, dynamic>{};
    return MemberLookup(
      found: true, displayName: (j['display_name'] ?? '') as String, memberNumber: _int(j['member_number']),
      totalClasses: _int(stats['total_classes']), currentStreak: _int(stats['current_streak']),
      perks: [for (final p in _maps(j['perks'])) LookupPerk(p['id'] as String, (p['title'] ?? p['code']) as String, _time(p['redeemed_at']))],
    );
  }
}

class LookupPerk {
  final String id, title;
  final DateTime? redeemedAt;
  const LookupPerk(this.id, this.title, this.redeemedAt);
  bool get redeemed => redeemedAt != null;
}

class FlaggedPost {
  final String id, authorName, body;
  final bool hidden;
  final String? hiddenReason;
  final int reports;
  final DateTime createdAt;
  const FlaggedPost(this.id, this.authorName, this.body, this.hidden, this.hiddenReason, this.reports, this.createdAt);
  factory FlaggedPost.fromJson(Map<String, dynamic> j) => FlaggedPost(
        j['id'] as String, (j['author_name'] ?? '') as String, (j['body'] ?? '') as String, j['hidden'] == true,
        j['hidden_reason'] as String?, _int(j['reports']), _time(j['created_at']) ?? DateTime.now());
}

class HistoryItem {
  final String classType, instructor;
  final DateTime startsAt, checkedInAt;
  const HistoryItem(this.classType, this.instructor, this.startsAt, this.checkedInAt);
  factory HistoryItem.fromJson(Map<String, dynamic> j) => HistoryItem(
        j['class_type'] as String, (j['instructor'] ?? '') as String,
        _time(j['starts_at']) ?? DateTime.now(), _time(j['checked_in_at']) ?? DateTime.now());
}

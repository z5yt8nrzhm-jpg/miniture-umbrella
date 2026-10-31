/// A complete club that lives in memory. It follows the same rules as the
/// database (check-in window, two a day, one count per class, weekly streaks,
/// badges, five posts an hour, three reports hide a post) so the app can be
/// tried, tested and demonstrated with no account and no network.
///
/// Sign in with any email and the code 123456. An email containing "staff"
/// signs in as front-desk staff. Check-in codes: MAT222 (open), FLOW33
/// (opens soon), REST44 (finished).
library;

import 'dart:async';

import 'backend.dart';
import 'errors.dart';
import 'models.dart';

class DemoBackend implements ClubBackend {
  DemoBackend({this.latency = const Duration(milliseconds: 250), DateTime Function()? clock}) : _now = clock ?? DateTime.now {
    final now = _now();
    _classes = [
      _C('c1', 'mat_pilates', now.subtract(const Duration(minutes: 10)), 50, 'Mia', 12, 'MAT222'),
      _C('c2', 'yoga_flow', now.add(const Duration(minutes: 30)), 60, 'Jess', 14, 'FLOW33'),
      _C('c3', 'stretch', now.subtract(const Duration(hours: 5)), 45, 'Mia', 16, 'REST44'),
      _C('c4', 'strength', now.add(const Duration(hours: 22)), 50, 'Dana', 12, 'LIFT55'),
    ];
    // Eight earlier classes, one a week, so the first milestones are close.
    for (var i = 1; i <= 8; i++) {
      final t = now.subtract(Duration(days: 7 * i));
      final c = _C('h$i', 'mat_pilates', t, 50, 'Mia', 12, 'HIS${i}00'.padRight(6, '2'));
      _classes.add(c);
      _checkins.add(_Check(c.id, t));
    }
    final names = [('Maya', 'rose'), ('Jo', 'sky'), ('Priya', 'gold'), ('Sam', 'clay')];
    const bodies = [
      'First time holding the plank for a full minute!',
      'Showed up on a rough day and left feeling lighter.',
      'Brought my sister to class and she loved it.',
      'Week six of showing up. Tiny wins add up.',
    ];
    for (var i = 0; i < names.length; i++) {
      _posts.add(_P('seed$i', 'seed-client-$i', names[i].$1, names[i].$2, bodies[i], now.subtract(Duration(hours: 3 + i * 7)), mine: false));
      _cheers['seed$i'] = {'someone'};
    }
    _award(); // the eight earlier classes have already earned their badges
  }

  final Duration latency;
  final DateTime Function() _now;

  bool _in = false;
  String? _email;
  bool _staff = false;
  String? _profileName, _favorite, _avatar;
  DateTime? _since;
  final int _number = 1042;
  late final List<_C> _classes;
  final List<_Check> _checkins = [];
  final List<DateTime> _failedCodes = [];
  final List<_P> _posts = [];
  final Map<String, Set<String>> _cheers = {};
  final Map<String, Set<String>> _reports = {};
  final Set<String> _badgeCodes = {};
  final Map<String, _Perk> _perks = {};
  final _events = StreamController<AuthEvent>.broadcast();

  static const _catalog = Catalog(
    classTypes: [
      ClassType('mat_pilates', 'Mat Pilates', 'steady', 'Core strength and control, on the mat.', 1),
      ClassType('vibe_pilates', 'VIBE Mat Pilates', 'steady', 'A VIBE community class.', 2),
      ClassType('yoga_flow', 'Yoga Flow', 'steady', 'Move with the breath.', 3),
      ClassType('yoga_gentle', 'Gentle Yoga', 'calm', 'Slow, supported poses.', 4),
      ClassType('stretch', 'Stretch & Restore', 'calm', 'Long holds to unwind.', 5),
      ClassType('strength', 'Strength & Sculpt', 'energetic', 'Resistance for the whole body.', 6),
    ],
    badges: [
      BadgeDef('first_class', 'First Class', 'You showed up. That is the hardest part.', 'classes', 1, 1),
      BadgeDef('classes_10', 'Ten Classes', 'Ten classes in. A habit is forming.', 'classes', 10, 2),
      BadgeDef('classes_25', 'Twenty-Five', 'Twenty-five classes. Look how far you came.', 'classes', 25, 3),
      BadgeDef('classes_50', 'Fifty Classes', 'Fifty classes of showing up for yourself.', 'classes', 50, 4),
      BadgeDef('classes_100', 'One Hundred', 'A hundred classes. The studio is proud of you.', 'classes', 100, 5),
      BadgeDef('streak_4', 'Four-Week Streak', 'A class every week for four weeks running.', 'streak', 4, 6),
      BadgeDef('streak_8', 'Eight-Week Streak', 'Two months without missing a week.', 'streak', 8, 7),
      BadgeDef('streak_12', 'Twelve-Week Streak', 'A full season of weekly classes.', 'streak', 12, 8),
    ],
    perks: [
      PerkDef('free_class_25', 'Free class', 'Bring a friend or take a class on us.', 25, 1),
      PerkDef('guest_pass_50', 'Guest pass', 'A class for a friend, any time.', 50, 2),
      PerkDef('gift_100', 'Studio gift', 'A thank-you from the studio.', 100, 3),
    ],
  );

  Future<T> _t<T>(T Function() f) async {
    if (latency > Duration.zero) await Future<void>.delayed(latency);
    return f();
  }

  void _needSignIn() {
    if (!_in) throw const ClubException(Failure.authExpired, 'Signed out.');
  }

  void _needStaff() {
    _needSignIn();
    if (!_staff) throw const ClubException(Failure.notAllowed, 'Not allowed.');
  }

  // ── signing in ───────────────────────────────────────────────────────────
  @override
  bool get signedIn => _in;
  @override
  Stream<AuthEvent> get authEvents => _events.stream;

  @override
  Future<void> sendCode(String email) => _t(() {
        if (!email.contains('@')) throw const ClubException(Failure.invalid, 'Please enter a valid email address.');
        _email = email.trim();
      });

  @override
  Future<void> verifyCode(String email, String code) => _t(() {
        if (code.trim() != '123456' || _email == null) {
          throw const ClubException(Failure.invalid, "That code didn't work. In the demo, the code is 123456.");
        }
        _in = true;
        _staff = _email!.toLowerCase().contains('staff');
        _events.add(AuthEvent.signedIn);
      });

  @override
  Future<void> signOut() async {
    _in = false;
    _events.add(AuthEvent.signedOut);
  }

  // ── members ──────────────────────────────────────────────────────────────
  @override
  Future<Catalog> catalog() => _t(() => _catalog);

  @override
  Future<MemberStats> myStats() => _t(() {
        _needSignIn();
        if (_profileName == null) return const MemberStats(hasProfile: false);
        return _stats();
      });

  MemberStats _stats() {
    final s = _streaks();
    final week = _weekStart(_now());
    final times = [for (final c in _checkins) c.at];
    return MemberStats(
      hasProfile: true,
      profile: Profile(displayName: _profileName!, memberNumber: _number, avatar: _avatar ?? 'sage', favoriteClass: _favorite, memberSince: _since),
      totalClasses: _checkins.length,
      currentStreak: s.$1,
      longestStreak: s.$2,
      classesThisWeek: times.where((t) => _weekStart(t) == week).length,
      lastCheckInAt: times.isEmpty ? null : (times.toList()..sort()).last,
      fetchedAt: _now(),
      badges: [for (final c in _badgeCodes) EarnedBadge(c, _now())],
      perks: [for (final p in _perks.values) EarnedPerk(p.id, p.code, p.earnedAt, p.redeemedAt)],
    );
  }

  /// Monday of the studio week containing [t], as a day number.
  int _weekStart(DateTime t) {
    final s = studioTime(t);
    final day = DateTime.utc(s.year, s.month, s.day);
    return day.subtract(Duration(days: s.weekday - 1)).millisecondsSinceEpoch ~/ Duration.millisecondsPerDay;
  }

  (int, int) _streaks() {
    final weeks = {for (final c in _checkins) _weekStart(c.at)}.toList()..sort();
    var longest = 0, run = 0, last = -999;
    final runs = <(int, int)>[]; // (last week, length)
    for (final w in weeks) {
      run = (w - last == 7) ? run + 1 : 1;
      last = w;
      if (run > longest) longest = run;
      if (runs.isNotEmpty && runs.last.$1 == w - 7) runs.removeLast();
      runs.add((w, run));
    }
    final cur = _weekStart(_now());
    final alive = runs.where((r) => r.$1 >= cur - 7).toList();
    return (alive.isEmpty ? 0 : alive.last.$2, longest);
  }

  @override
  Future<void> saveProfile({required String name, String? favoriteClass, required String avatar}) => _t(() {
        _needSignIn();
        final n = name.trim();
        if (n.isEmpty || n.length > 30) throw const ClubException(Failure.invalid, 'Please use a name between 1 and 30 characters.');
        _profileName = n;
        _favorite = (favoriteClass ?? '').trim().isEmpty ? null : favoriteClass!.trim();
        _avatar = avatar;
        _since ??= _now();
      });

  @override
  Future<List<StudioClass>> upcomingClasses() => _t(() {
        _needSignIn();
        final since = _now().subtract(const Duration(hours: 3));
        return [for (final c in _classes) if (c.startsAt.isAfter(since)) c.toClass()]..sort((a, b) => a.startsAt.compareTo(b.startsAt));
      });

  @override
  Future<List<HistoryItem>> history({int limit = 30}) => _t(() {
        _needSignIn();
        final rows = [
          for (final k in _checkins) () {
            final c = _classes.firstWhere((c) => c.id == k.classId);
            return HistoryItem(c.type, c.instructor, c.startsAt, k.at);
          }()
        ]..sort((a, b) => b.checkedInAt.compareTo(a.checkedInAt));
        return rows.take(limit).toList();
      });

  @override
  Future<CheckInResult> checkIn(String raw) => _t(() {
        _needSignIn();
        if (_profileName == null) return const CheckInResult(CheckInStatus.noProfile);
        final now = _now();
        _failedCodes.removeWhere((t) => now.difference(t) > const Duration(minutes: 15));
        if (_failedCodes.length >= 8) return const CheckInResult(CheckInStatus.throttled);
        final code = raw.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
        final c = _classes.where((c) => c.code == code).firstOrNull;
        if (c == null) {
          _failedCodes.add(now);
          return const CheckInResult(CheckInStatus.invalid);
        }
        if (now.isBefore(c.startsAt.subtract(const Duration(minutes: 45))) || now.isAfter(c.endsAt.add(const Duration(minutes: 30)))) {
          _failedCodes.add(now);
          return const CheckInResult(CheckInStatus.closed);
        }
        var status = CheckInStatus.ok;
        var newBadges = <String>[], newPerks = <String>[];
        if (_checkins.any((k) => k.classId == c.id)) {
          status = CheckInStatus.already;
        } else {
          final today = studioTime(now);
          final todays = _checkins.where((k) {
            final s = studioTime(k.at);
            return s.year == today.year && s.month == today.month && s.day == today.day;
          });
          if (todays.length >= 2) return const CheckInResult(CheckInStatus.limit);
          _checkins.add(_Check(c.id, now));
          (newBadges, newPerks) = _award();
        }
        final s = _streaks();
        return CheckInResult(status, studioClass: c.toClass(), totalClasses: _checkins.length, currentStreak: s.$1, newBadges: newBadges, newPerks: newPerks);
      });

  (List<String>, List<String>) _award() {
    final total = _checkins.length, longest = _streaks().$2;
    final nb = <String>[], np = <String>[];
    for (final b in _catalog.badges) {
      final earned = b.isStreak ? longest >= b.threshold : total >= b.threshold;
      if (earned && _badgeCodes.add(b.code)) nb.add(b.code);
    }
    for (final p in _catalog.perks) {
      if (total >= p.requiredClasses && !_perks.containsKey(p.code)) {
        _perks[p.code] = _Perk('perk-${p.code}', p.code, _now());
        np.add(p.code);
      }
    }
    return (nb, np);
  }

  @override
  Future<void> deleteAccount() => _t(() {
        _needSignIn();
        _in = false;
        _profileName = null;
        _checkins.clear();
        _badgeCodes.clear();
        _perks.clear();
        _posts.removeWhere((p) => p.mine);
        _events.add(AuthEvent.signedOut);
      });

  // ── the wall ─────────────────────────────────────────────────────────────
  @override
  Future<List<WallPost>> wallFeed({String? beforeCursor, String? beforeId, int limit = 20}) => _t(() {
        final before = beforeCursor == null ? null : DateTime.parse(beforeCursor);
        _needSignIn();
        if (_profileName == null) return const <WallPost>[];
        final rows = _posts.where((p) => !p.hidden).toList()
          ..sort((a, b) {
            final c = b.createdAt.compareTo(a.createdAt);
            return c != 0 ? c : b.id.compareTo(a.id);
          });
        final page = rows.where((p) {
          if (before == null) return true;
          final c = p.createdAt.compareTo(before);
          return c < 0 || (c == 0 && p.id.compareTo(beforeId ?? '￿') < 0);
        });
        return [
          for (final p in page.take(limit.clamp(1, 50)))
            WallPost(
              id: p.id, authorName: p.author, authorAvatar: p.avatar, body: p.body, createdAt: p.createdAt,
              cheers: (_cheers[p.id] ?? {}).length, cheeredByMe: (_cheers[p.id] ?? {}).contains('me'), isMine: p.mine,
            )
        ];
      });

  @override
  Future<PostResult> wallPost(String clientId, String body) => _t(() {
        _needSignIn();
        if (_profileName == null) return const PostResult(PostStatus.noProfile);
        final b = body.trim();
        if (b.isEmpty || b.length > 500) return const PostResult(PostStatus.invalidBody);
        final dup = _posts.where((p) => p.mine && p.clientId == clientId).firstOrNull;
        if (dup != null) return PostResult(PostStatus.ok, id: dup.id, duplicate: true);
        final hourAgo = _now().subtract(const Duration(hours: 1));
        if (_posts.where((p) => p.mine && p.createdAt.isAfter(hourAgo)).length >= 5) return const PostResult(PostStatus.rateLimited);
        final p = _P('p${_posts.length}-${_now().microsecondsSinceEpoch}', clientId, _profileName!, _avatar ?? 'sage', b, _now(), mine: true);
        _posts.add(p);
        return PostResult(PostStatus.ok, id: p.id);
      });

  @override
  Future<int> cheer(String postId, bool on) => _t(() {
        _needSignIn();
        final set = _cheers.putIfAbsent(postId, () => <String>{});
        on ? set.add('me') : set.remove('me');
        return set.length;
      });

  @override
  Future<void> report(String postId) => _t(() {
        _needSignIn();
        final p = _posts.where((p) => p.id == postId).firstOrNull;
        if (p == null || p.mine) return;
        final r = _reports.putIfAbsent(postId, () => <String>{})..add('me');
        if (r.length >= 3) p.hidden = true;
      });

  // ── staff ────────────────────────────────────────────────────────────────
  @override
  Future<bool> isStaff() => _t(() {
        _needSignIn();
        return _staff;
      });

  @override
  Future<List<StaffClass>> staffClasses({DateTime? day}) => _t(() {
        _needStaff();
        final d = studioTime(day ?? _now());
        return [
          for (final c in _classes)
            if (() {
              final s = studioTime(c.startsAt);
              return s.year == d.year && s.month == d.month && s.day == d.day;
            }())
              StaffClass(c.toClass(), c.code, _checkins.where((k) => k.classId == c.id).length)
        ]..sort((a, b) => a.studioClass.startsAt.compareTo(b.studioClass.startsAt));
      });

  @override
  Future<String> staffCreateClass({required String classType, required DateTime startsAt, required int durationMin, required String instructor, int? capacity}) => _t(() {
        _needStaff();
        if (instructor.trim().isEmpty || durationMin < 15 || durationMin > 180) throw const ClubException(Failure.invalid, 'Check the class details and try again.');
        final code = 'NEW${(_classes.length + 100).toString()}'.substring(0, 6).replaceAll('0', '2').replaceAll('1', '3');
        _classes.add(_C('n${_classes.length}', classType, startsAt, durationMin, instructor.trim(), capacity, code));
        return code;
      });

  @override
  Future<MemberLookup> staffLookup(int memberNumber) => _t(() {
        _needStaff();
        if (memberNumber != _number || _profileName == null) return const MemberLookup();
        final s = _streaks();
        return MemberLookup(
          found: true, displayName: _profileName!, memberNumber: _number, totalClasses: _checkins.length, currentStreak: s.$1,
          perks: [for (final p in _perks.values) LookupPerk(p.id, _catalog.perk(p.code)?.title ?? p.code, p.redeemedAt)],
        );
      });

  @override
  Future<String> staffRedeem(String memberPerkId) => _t(() {
        _needStaff();
        final p = _perks.values.where((p) => p.id == memberPerkId).firstOrNull;
        if (p == null) return 'not_found';
        if (p.redeemedAt != null) return 'already_redeemed';
        p.redeemedAt = _now();
        return 'ok';
      });

  @override
  Future<List<FlaggedPost>> staffFlagged() => _t(() {
        _needStaff();
        return [
          for (final p in _posts)
            if (p.hidden || (_reports[p.id] ?? {}).isNotEmpty)
              FlaggedPost(p.id, p.author, p.body, p.hidden, p.hidden ? 'reported' : null, (_reports[p.id] ?? {}).length, p.createdAt)
        ];
      });

  @override
  Future<void> staffSetHidden(String postId, bool hidden) => _t(() {
        _needStaff();
        final p = _posts.where((p) => p.id == postId).firstOrNull;
        if (p != null) p.hidden = hidden;
      });
}

class _C {
  final String id, type, instructor, code;
  final DateTime startsAt;
  final int duration;
  final int? capacity;
  _C(this.id, this.type, this.startsAt, this.duration, this.instructor, this.capacity, this.code);
  DateTime get endsAt => startsAt.add(Duration(minutes: duration));
  StudioClass toClass() => StudioClass(id: id, classType: type, instructor: instructor, startsAt: startsAt, durationMin: duration, capacity: capacity);
}

class _Check {
  final String classId;
  final DateTime at;
  _Check(this.classId, this.at);
}

class _P {
  final String id, clientId, author, avatar, body;
  final DateTime createdAt;
  final bool mine;
  bool hidden = false;
  _P(this.id, this.clientId, this.author, this.avatar, this.body, this.createdAt, {required this.mine});
}

class _Perk {
  final String id, code;
  final DateTime earnedAt;
  DateTime? redeemedAt;
  _Perk(this.id, this.code, this.earnedAt);
}

/// Holds everything the screens show, and keeps it honest on a bad connection:
///
///  * The app opens instantly from what the phone last saved, then updates.
///  * With no signal it keeps showing that, says so, and retries by itself.
///  * A member is signed out only when the sign-in is really invalid, never
///    because the signal dropped.
///  * A post is saved on the phone first and sent with the same id on every
///    retry, so it is never lost and never doubled, even if the app is closed.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/backend.dart';
import '../data/errors.dart';
import '../data/local_store.dart';
import '../data/models.dart';

enum Phase { booting, signedOut, unreachable, needsProfile, ready }

class ClubController extends ChangeNotifier {
  ClubController(this.backend, this.store, {this.autoPoll = true, DateTime Function()? clock, this.pollEvery = const Duration(seconds: 30)})
      : _now = clock ?? DateTime.now;

  final ClubBackend backend;
  final LocalStore store;
  final bool autoPoll;
  final Duration pollEvery;
  final DateTime Function() _now;

  // ── what the screens read ────────────────────────────────────────────────
  Phase phase = Phase.booting;
  String? pendingEmail; // set once a code has been sent
  Catalog catalog = Catalog.empty;
  MemberStats? stats;
  List<StudioClass> schedule = const [];
  List<HistoryItem> history = const [];
  List<WallPost> wall = const [];
  bool wallLoaded = false, wallLoading = false, wallHasMore = true;
  List<PendingPost> pending = const [];
  bool isStaff = false;
  bool offline = false;
  DateTime? lastSynced;
  String? notice;

  Set<String> _reported = {};
  Set<String> get reportedIds => _reported;

  StreamSubscription<AuthEvent>? _sub;
  Timer? _timer, _flushRetry;
  int _flushFails = 0;
  Future<void>? _refreshing;
  DateTime? _catalogAt;
  bool _wallVisible = false, _flushing = false, _disposed = false;
  final Set<String> _cheering = {};

  // ── starting up ──────────────────────────────────────────────────────────
  Future<void> boot() async {
    _sub = backend.authEvents.listen(_onAuth);
    await _loadCache();
    if (!backend.signedIn) {
      phase = Phase.signedOut;
      _tell();
      return;
    }
    if (stats?.hasProfile == true) phase = Phase.ready; // show what we saved straight away
    _tell();
    _startPolling();
    await refreshAll();
  }

  void _onAuth(AuthEvent e) {
    if (e == AuthEvent.signedOut) {
      if (phase != Phase.signedOut) unawaited(_resetLocal(notice: null));
    } else if (phase == Phase.signedOut || phase == Phase.unreachable || phase == Phase.booting) {
      _startPolling();
      unawaited(refreshAll());
    }
  }

  void _startPolling() {
    if (!autoPoll) return;
    _timer?.cancel();
    _timer = Timer.periodic(pollEvery, (_) => _tick());
  }

  void _tick() {
    if (phase == Phase.signedOut || _disposed) return;
    if (offline || phase == Phase.unreachable) {
      unawaited(refreshAll()); // keep knocking until the club answers
    } else if (_wallVisible) {
      unawaited(refreshWall().then((_) => flushPending()));
    } else if (pending.isNotEmpty) {
      unawaited(flushPending());
    }
  }

  /// The app came back to the front.
  void onResume() {
    if (phase == Phase.signedOut || phase == Phase.booting) return;
    final last = lastSynced;
    if (last == null || _now().difference(last) > const Duration(seconds: 20)) unawaited(refreshAll());
  }

  void setWallVisible(bool visible) {
    _wallVisible = visible;
    if (visible && phase == Phase.ready && wallLoaded) unawaited(refreshWall());
  }

  // ── refreshing ───────────────────────────────────────────────────────────
  Future<void> refreshAll() => _refreshing ??= _doRefresh().whenComplete(() => _refreshing = null);

  Future<void> _doRefresh() async {
    if (!backend.signedIn) return;
    final gotStats = await _try(() async {
      stats = await backend.myStats();
      await store.writeJson('stats', stats!.toJson());
    });
    if (!gotStats) {
      if (phase == Phase.booting) phase = Phase.unreachable;
      _tell();
      return;
    }
    phase = stats!.hasProfile ? Phase.ready : Phase.needsProfile;
    lastSynced = _now();
    _tell();

    await Future.wait([
      _loadCatalog(),
      if (phase == Phase.ready) ...[_loadSchedule(), _loadHistory(), _loadStaff(), refreshWall()],
    ]);
    if (phase == Phase.ready) await flushPending();
    _tell();
  }

  Future<void> _loadCatalog() async {
    final fresh = _catalogAt != null && _now().difference(_catalogAt!) < const Duration(hours: 12);
    if (!catalog.isEmpty && fresh) return;
    await _try(() async {
      catalog = await backend.catalog();
      _catalogAt = _now();
      await store.writeJson('catalog', catalog.toJson());
    }, quiet: true);
    _tell();
  }

  Future<void> _loadSchedule() async {
    await _try(() async {
      schedule = await backend.upcomingClasses();
      await store.writeJson('schedule', [for (final c in schedule) c.toJson()]);
    }, quiet: true);
    _tell();
  }

  Future<void> _loadHistory() async {
    await _try(() async {
      history = await backend.history(limit: 30);
    }, quiet: true);
    _tell();
  }

  Future<void> _loadStaff() async {
    await _try(() async {
      isStaff = await backend.isStaff();
    }, quiet: true);
    _tell();
  }

  Future<void> refreshWall() async {
    if (phase != Phase.ready || wallLoading) return;
    wallLoading = true;
    _tell();
    await _try(() async {
      final page = await backend.wallFeed(limit: 20);
      wall = _visible(page);
      wallHasMore = page.length >= 20;
      wallLoaded = true;
      await store.writeJson('wall', [for (final p in wall) p.toJson()]);
    }, quiet: true);
    wallLoading = false;
    _tell();
  }

  Future<void> loadMoreWall() async {
    if (phase != Phase.ready || wallLoading || !wallHasMore || wall.isEmpty) return;
    wallLoading = true;
    _tell();
    final last = wall.last;
    await _try(() async {
      final page = await backend.wallFeed(beforeCursor: last.cursor, beforeId: last.id, limit: 20);
      final seen = {for (final p in wall) p.id};
      wall = [...wall, ..._visible([for (final p in page) if (!seen.contains(p.id)) p])];
      wallHasMore = page.length >= 20;
    }, quiet: true);
    wallLoading = false;
    _tell();
  }

  List<WallPost> _visible(List<WallPost> posts) => [for (final p in posts) if (!_reported.contains(p.id)) p];

  // ── signing in ───────────────────────────────────────────────────────────
  Future<void> sendCode(String email) async {
    await backend.sendCode(email);
    pendingEmail = email.trim();
    _tell();
  }

  Future<void> verifyCode(String code) async {
    final email = pendingEmail;
    if (email == null) return;
    await backend.verifyCode(email, code);
    pendingEmail = null;
    _startPolling();
    await refreshAll();
  }

  void backToEmail() {
    pendingEmail = null;
    _tell();
  }

  Future<void> saveProfile({required String name, String? favoriteClass, required String avatar}) async {
    await _guard(() => backend.saveProfile(name: name, favoriteClass: favoriteClass, avatar: avatar));
    await _try(() async {
      stats = await backend.myStats();
      await store.writeJson('stats', stats!.toJson());
    });
    if (stats?.hasProfile == true) {
      phase = Phase.ready;
      _tell();
      unawaited(refreshAll());
    }
  }

  Future<void> signOut() async {
    await _resetLocal(notice: null);
    await backend.signOut();
  }

  Future<void> deleteAccount() async {
    await _guard(backend.deleteAccount);
    await _resetLocal(notice: 'Your account and everything you shared has been deleted.');
  }

  Future<void> _resetLocal({String? notice}) async {
    _timer?.cancel();
    _flushRetry?.cancel();
    phase = Phase.signedOut;
    pendingEmail = null;
    stats = null;
    schedule = const [];
    history = const [];
    wall = const [];
    wallLoaded = false;
    wallHasMore = true;
    pending = const [];
    isStaff = false;
    offline = false;
    _reported = {};
    this.notice = notice;
    await store.clear();
    _tell();
  }

  // ── checking in ──────────────────────────────────────────────────────────
  Future<CheckInResult> checkIn(String code) async {
    final r = await _guard(() => backend.checkIn(code));
    offline = false;
    if (r.counted && stats != null) {
      stats = stats!.copyWith(
        totalClasses: r.totalClasses > 0 ? r.totalClasses : null,
        currentStreak: r.currentStreak,
        lastCheckInAt: _now(),
        badges: [...stats!.badges, for (final b in r.newBadges) if (!stats!.hasBadge(b)) EarnedBadge(b, _now())],
      );
    }
    _tell();
    if (r.counted) {
      unawaited(_try(() async {
        stats = await backend.myStats();
        await store.writeJson('stats', stats!.toJson());
        history = await backend.history(limit: 30);
      }, quiet: true).then((_) => _tell()));
    }
    return r;
  }

  // ── the wall ─────────────────────────────────────────────────────────────
  Future<void> post(String body) async {
    final text = body.trim();
    if (text.isEmpty) return;
    pending = [...pending, PendingPost(newId(), text, _now())];
    await _savePending();
    _tell();
    await flushPending();
  }

  Future<void> flushPending() async {
    if (_flushing || pending.isEmpty || phase != Phase.ready) return;
    _flushing = true;
    var posted = false;
    try {
      for (final p in List.of(pending)) {
        try {
          final r = await backend.wallPost(p.clientId, p.body);
          switch (r.status) {
            case PostStatus.ok:
              posted = true;
              offline = false;
              _flushFails = 0;
            case PostStatus.invalidBody:
              notice = "That post couldn't be shared. Please check the text.";
            case PostStatus.rateLimited:
              notice = "You've shared 5 posts this hour. Please try again a little later.";
            case PostStatus.noProfile:
              notice = 'Please finish setting up your profile first.';
          }
          await _dropPending(p);
        } on ClubException catch (e) {
          if (e.kind == Failure.authExpired) {
            await _forceSignOut();
            return;
          }
          if (e.retryable) {
            offline = true; // keep it, and knock again soon (4s, 8s, 16s, then every 30s)
            _scheduleFlushRetry();
            break;
          }
          notice = friendly(e);
          await _dropPending(p);
        }
      }
    } finally {
      _flushing = false;
      _tell();
    }
    if (posted) await refreshWall();
  }

  void _scheduleFlushRetry() {
    if (!autoPoll || _disposed) return;
    _flushRetry?.cancel();
    final secs = (4 << _flushFails.clamp(0, 3)).clamp(4, 30);
    _flushFails++;
    _flushRetry = Timer(Duration(seconds: secs), () {
      if (!_disposed && pending.isNotEmpty) unawaited(flushPending());
    });
  }

  Future<void> _dropPending(PendingPost p) async {
    pending = [for (final x in pending) if (x.clientId != p.clientId) x];
    await _savePending();
    _tell();
  }

  Future<void> _savePending() => store.writeJson('pending_posts', [for (final p in pending) p.toJson()]);

  Future<void> cheer(WallPost post) async {
    if (!_cheering.add(post.id)) return; // one tap at a time per post
    final on = !post.cheeredByMe;
    _replace(post.id, (x) => x.copyWith(cheeredByMe: on, cheers: (x.cheers + (on ? 1 : -1)).clamp(0, 1 << 30)));
    try {
      final n = await backend.cheer(post.id, on);
      _replace(post.id, (x) => x.copyWith(cheeredByMe: on, cheers: n));
    } on ClubException catch (e) {
      _replace(post.id, (x) => x.copyWith(cheeredByMe: post.cheeredByMe, cheers: post.cheers));
      if (e.kind == Failure.authExpired) {
        await _forceSignOut();
      } else {
        if (e.isConnection) offline = true;
        notice = friendly(e);
      }
    } finally {
      _cheering.remove(post.id);
      _tell();
    }
  }

  void _replace(String id, WallPost Function(WallPost) f) {
    wall = [for (final p in wall) p.id == id ? f(p) : p];
    _tell();
  }

  Future<void> report(WallPost post) async {
    _reported = {..._reported, post.id}; // gone from this phone straight away
    wall = [for (final p in wall) if (p.id != post.id) p];
    await store.writeJson('reported', _reported.toList());
    _tell();
    try {
      await backend.report(post.id);
      notice = 'Thanks. The post is hidden for you and staff will take a look.';
    } on ClubException catch (e) {
      if (e.kind == Failure.authExpired) {
        await _forceSignOut();
        return;
      }
      notice = "We've hidden it for you, but couldn't reach the club to report it. Please report it again when you're online.";
    }
    _tell();
  }

  // ── plumbing ─────────────────────────────────────────────────────────────
  /// For member actions: failures go to the screen to explain, but a lost
  /// connection is also noted, and a dead sign-in signs the member out.
  Future<T> _guard<T>(Future<T> Function() op) async {
    try {
      return await op();
    } on ClubException catch (e) {
      if (e.kind == Failure.authExpired) {
        await _forceSignOut();
      } else if (e.isConnection) {
        offline = true;
        _tell();
      }
      rethrow;
    }
  }

  /// For background loads: never throws. Returns whether it worked.
  Future<bool> _try(Future<void> Function() op, {bool quiet = false}) async {
    try {
      await op();
      if (offline) {
        offline = false;
        _tell();
      }
      return true;
    } on ClubException catch (e) {
      if (e.kind == Failure.authExpired) {
        await _forceSignOut();
      } else if (e.isConnection || e.kind == Failure.server) {
        offline = true;
      } else if (!quiet) {
        notice = friendly(e);
      }
      return false;
    }
  }

  Future<void> _forceSignOut() async {
    await _resetLocal(notice: 'Please sign in again.');
    await backend.signOut();
  }

  Future<void> _loadCache() async {
    try {
      final c = await store.readJson('catalog');
      if (c is Map) catalog = Catalog.fromJson(Map<String, dynamic>.from(c));
      final s = await store.readJson('stats');
      if (s is Map) stats = MemberStats.fromJson(Map<String, dynamic>.from(s));
      final sc = await store.readJson('schedule');
      if (sc is List) schedule = [for (final x in sc) StudioClass.fromJson(Map<String, dynamic>.from(x as Map))];
      final r = await store.readJson('reported');
      if (r is List) _reported = {for (final x in r) x as String};
      final w = await store.readJson('wall');
      if (w is List) {
        wall = _visible([for (final x in w) WallPost.fromJson(Map<String, dynamic>.from(x as Map))]);
        wallLoaded = wall.isNotEmpty;
      }
      final p = await store.readJson('pending_posts');
      if (p is List) pending = [for (final x in p) PendingPost.fromJson(Map<String, dynamic>.from(x as Map))];
    } catch (_) {
      // A damaged cache is just an empty cache.
    }
  }

  void clearNotice() {
    if (notice != null) {
      notice = null;
      _tell();
    }
  }

  void _tell() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    _flushRetry?.cancel();
    _sub?.cancel();
    super.dispose();
  }
}

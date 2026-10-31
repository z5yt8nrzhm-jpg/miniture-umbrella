import 'dart:async';

import 'package:gilbert_flex_club/data/backend.dart';
import 'package:gilbert_flex_club/data/errors.dart';
import 'package:gilbert_flex_club/data/models.dart';

/// Wraps a real backend and misbehaves on command, the way a phone's
/// connection does: no signal, a reply that never arrives after the server
/// already did the work, a server having a bad moment, an expired sign-in.
class FlakyBackend implements ClubBackend {
  FlakyBackend(this.inner);
  final ClubBackend inner;

  /// Every call fails before it reaches the server.
  bool offline = false;

  /// Calls reach the server and succeed there, but the reply is lost.
  bool loseReplies = false;

  /// The next [n] calls fail this way, then calls work again.
  int failNext = 0;
  Failure failWith = Failure.server;

  /// Every call is refused as an expired sign-in.
  bool expired = false;

  /// How many calls reached the server, by method name.
  final Map<String, int> reached = {};
  final List<String> postIds = [];

  Future<T> _run<T>(String name, Future<T> Function() op) async {
    if (expired) throw const ClubException(Failure.authExpired, 'Signed out.');
    if (offline) throw const ClubException(Failure.offline, 'No connection.');
    if (failNext > 0) {
      failNext--;
      throw ClubException(failWith, 'injected');
    }
    reached[name] = (reached[name] ?? 0) + 1;
    final r = await op();
    if (loseReplies) throw const ClubException(Failure.timeout, 'reply lost');
    return r;
  }

  @override
  bool get signedIn => inner.signedIn;
  @override
  Stream<AuthEvent> get authEvents => inner.authEvents;
  @override
  Future<void> sendCode(String email) => _run('sendCode', () => inner.sendCode(email));
  @override
  Future<void> verifyCode(String email, String code) => _run('verifyCode', () => inner.verifyCode(email, code));
  @override
  Future<void> signOut() => inner.signOut();
  @override
  Future<Catalog> catalog() => _run('catalog', inner.catalog);
  @override
  Future<MemberStats> myStats() => _run('myStats', inner.myStats);
  @override
  Future<void> saveProfile({required String name, String? favoriteClass, required String avatar}) =>
      _run('saveProfile', () => inner.saveProfile(name: name, favoriteClass: favoriteClass, avatar: avatar));
  @override
  Future<List<StudioClass>> upcomingClasses() => _run('upcomingClasses', inner.upcomingClasses);
  @override
  Future<List<HistoryItem>> history({int limit = 30}) => _run('history', () => inner.history(limit: limit));
  @override
  Future<CheckInResult> checkIn(String code) => _run('checkIn', () => inner.checkIn(code));
  @override
  Future<void> deleteAccount() => _run('deleteAccount', inner.deleteAccount);
  @override
  Future<List<WallPost>> wallFeed({String? beforeCursor, String? beforeId, int limit = 20}) =>
      _run('wallFeed', () => inner.wallFeed(beforeCursor: beforeCursor, beforeId: beforeId, limit: limit));
  @override
  Future<PostResult> wallPost(String clientId, String body) {
    postIds.add(clientId);
    return _run('wallPost', () => inner.wallPost(clientId, body));
  }

  @override
  Future<int> cheer(String postId, bool on) => _run('cheer', () => inner.cheer(postId, on));
  @override
  Future<void> report(String postId) => _run('report', () => inner.report(postId));
  @override
  Future<bool> isStaff() => _run('isStaff', inner.isStaff);
  @override
  Future<List<StaffClass>> staffClasses({DateTime? day}) => _run('staffClasses', () => inner.staffClasses(day: day));
  @override
  Future<String> staffCreateClass({required String classType, required DateTime startsAt, required int durationMin, required String instructor, int? capacity}) =>
      _run('staffCreateClass', () => inner.staffCreateClass(classType: classType, startsAt: startsAt, durationMin: durationMin, instructor: instructor, capacity: capacity));
  @override
  Future<MemberLookup> staffLookup(int memberNumber) => _run('staffLookup', () => inner.staffLookup(memberNumber));
  @override
  Future<String> staffRedeem(String memberPerkId) => _run('staffRedeem', () => inner.staffRedeem(memberPerkId));
  @override
  Future<List<FlaggedPost>> staffFlagged() => _run('staffFlagged', inner.staffFlagged);
  @override
  Future<void> staffSetHidden(String postId, bool hidden) => _run('staffSetHidden', () => inner.staffSetHidden(postId, hidden));
}

/// The club's connection to its data. The app talks only to this interface,
/// so the same screens run against Supabase, against the built-in demo, and
/// against a deliberately unreliable stand-in in the tests.
library;

import 'models.dart';

enum AuthEvent { signedIn, signedOut }

abstract class ClubBackend {
  // ── signing in ───────────────────────────────────────────────────────────
  bool get signedIn;
  Stream<AuthEvent> get authEvents;
  Future<void> sendCode(String email);
  Future<void> verifyCode(String email, String code);
  Future<void> signOut();

  // ── members ──────────────────────────────────────────────────────────────
  Future<Catalog> catalog();
  Future<MemberStats> myStats();
  Future<void> saveProfile({required String name, String? favoriteClass, required String avatar});
  Future<List<StudioClass>> upcomingClasses();
  Future<List<HistoryItem>> history({int limit = 30});
  Future<CheckInResult> checkIn(String code);
  Future<void> deleteAccount();

  // ── the wall ─────────────────────────────────────────────────────────────
  /// [beforeCursor] is the previous page's last [WallPost.cursor], untouched.
  Future<List<WallPost>> wallFeed({String? beforeCursor, String? beforeId, int limit = 20});
  Future<PostResult> wallPost(String clientId, String body);
  Future<int> cheer(String postId, bool on);
  Future<void> report(String postId);

  // ── staff ────────────────────────────────────────────────────────────────
  Future<bool> isStaff();
  Future<List<StaffClass>> staffClasses({DateTime? day});
  Future<String> staffCreateClass({required String classType, required DateTime startsAt, required int durationMin, required String instructor, int? capacity});
  Future<MemberLookup> staffLookup(int memberNumber);
  Future<String> staffRedeem(String memberPerkId);
  Future<List<FlaggedPost>> staffFlagged();
  Future<void> staffSetHidden(String postId, bool hidden);
}

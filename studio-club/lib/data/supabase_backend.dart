/// The club's backend on Supabase. Every call is one of the database
/// functions in supabase/migrations, so the rules (who may do what, one
/// check-in per class, five posts an hour) live in the database and cannot
/// be skipped by a modified app.
library;

import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'backend.dart';
import 'errors.dart';
import 'models.dart';
import 'retry.dart';

class SupabaseBackend implements ClubBackend {
  /// [sleep] and [timeout] exist so tests can run without real waiting.
  // ignore: prefer_initializing_formals
  SupabaseBackend(this._client, {Sleep? sleep, this.timeout}) : _sleep = sleep;

  final SupabaseClient _client;
  final Sleep? _sleep;
  final Duration? timeout;

  // ── plumbing ─────────────────────────────────────────────────────────────
  Future<T> _call<T>(Future<T> Function() op, {RetryPolicy policy = RetryPolicy.standard}) => withRetry(() async {
        try {
          return await op().timeout(timeout ?? policy.timeout);
        } on ClubException {
          rethrow;
        } catch (e, st) {
          Error.throwWithStackTrace(classify(e), st); // keep the original trace for debugging
        }
      }, policy: policy, sleep: _sleep);

  Future<Map<String, dynamic>> _rpcMap(String fn, [Map<String, Object?> params = const {}, RetryPolicy policy = RetryPolicy.standard]) =>
      _call(() async {
        final r = await _client.rpc(fn, params: _withoutNulls(params));
        if (r is Map) return Map<String, dynamic>.from(r);
        throw const FormatException('expected an object');
      }, policy: policy);

  Future<List<Map<String, dynamic>>> _rpcList(String fn, [Map<String, Object?> params = const {}]) => _call(() async {
        final r = await _client.rpc(fn, params: _withoutNulls(params));
        if (r is List) return [for (final x in r) Map<String, dynamic>.from(x as Map)];
        throw const FormatException('expected a list');
      });

  static Map<String, Object?> _withoutNulls(Map<String, Object?> m) => {for (final e in m.entries) if (e.value != null) e.key: e.value};

  // ── signing in ───────────────────────────────────────────────────────────
  @override
  bool get signedIn => _client.auth.currentSession != null;

  @override
  Stream<AuthEvent> get authEvents => _client.auth.onAuthStateChange.map((s) {
        if (s.event == AuthChangeEvent.signedOut) return AuthEvent.signedOut;
        return s.session != null ? AuthEvent.signedIn : AuthEvent.signedOut;
      });

  @override
  Future<void> sendCode(String email) => _call(
        () => _client.auth.signInWithOtp(email: email.trim(), shouldCreateUser: true),
        policy: RetryPolicy.once,
      );

  @override
  Future<void> verifyCode(String email, String code) => _call(() async {
        try {
          await _client.auth.verifyOTP(email: email.trim(), token: code.trim(), type: OtpType.email);
        } on AuthApiException catch (e) {
          final status = int.tryParse(e.statusCode ?? '');
          if (status != null && status >= 400 && status < 500 && status != 429) {
            throw const ClubException(Failure.invalid, "That code didn't work. Check it, or ask for a new one.");
          }
          rethrow;
        }
      }, policy: RetryPolicy.once);

  @override
  Future<void> signOut() async {
    try {
      await _client.auth.signOut(); // clears this phone first, then tells the server
    } catch (_) {
      // Offline is fine: the phone is already signed out.
    }
  }

  // ── members ──────────────────────────────────────────────────────────────
  @override
  Future<Catalog> catalog() async {
    final results = await Future.wait([
      _call(() => _client.from('class_types').select().order('sort')),
      _call(() => _client.from('badges').select().order('sort')),
      _call(() => _client.from('perks').select().order('sort')),
    ]);
    return Catalog.fromJson({'class_types': results[0], 'badges': results[1], 'perks': results[2]});
  }

  @override
  Future<MemberStats> myStats() async => MemberStats.fromJson(await _rpcMap('my_stats'));

  @override
  Future<void> saveProfile({required String name, String? favoriteClass, required String avatar}) async {
    final r = await _rpcMap('upsert_my_profile', {'p_name': name, 'p_favorite': favoriteClass, 'p_avatar': avatar});
    switch (r['status']) {
      case 'ok':
        return;
      case 'invalid_name':
        throw const ClubException(Failure.invalid, 'Please use a name between 1 and 30 characters.');
      default:
        throw const ClubException(Failure.invalid, 'Please pick one of the avatars.');
    }
  }

  @override
  Future<List<StudioClass>> upcomingClasses() async {
    final since = DateTime.now().toUtc().subtract(const Duration(hours: 3)).toIso8601String();
    final rows = await _call(() => _client.from('classes').select().gte('starts_at', since).order('starts_at').limit(40));
    return [for (final r in rows) StudioClass.fromJson(r)];
  }

  @override
  Future<List<HistoryItem>> history({int limit = 30}) async =>
      [for (final r in await _rpcList('my_history', {'p_limit': limit})) HistoryItem.fromJson(r)];

  @override
  Future<CheckInResult> checkIn(String code) async => CheckInResult.fromJson(await _rpcMap('check_in', {'p_code': code}));

  @override
  Future<void> deleteAccount() async {
    await _rpcMap('delete_my_account', const {}, RetryPolicy.once);
    await signOut();
  }

  // ── the wall ─────────────────────────────────────────────────────────────
  @override
  Future<List<WallPost>> wallFeed({String? beforeCursor, String? beforeId, int limit = 20}) async => [
        for (final r in await _rpcList('wall_feed', {'p_before': beforeCursor, 'p_before_id': beforeId, 'p_limit': limit}))
          WallPost.fromJson(r)
      ];

  @override
  Future<PostResult> wallPost(String clientId, String body) async =>
      PostResult.fromJson(await _rpcMap('wall_post', {'p_client_id': clientId, 'p_body': body}));

  @override
  Future<int> cheer(String postId, bool on) async {
    final r = await _rpcMap('wall_cheer', {'p_post': postId, 'p_on': on});
    return (r['cheers'] as num?)?.toInt() ?? 0;
  }

  @override
  Future<void> report(String postId) async {
    await _rpcMap('wall_report', {'p_post': postId});
  }

  // ── staff ────────────────────────────────────────────────────────────────
  @override
  Future<bool> isStaff() => _call(() async => (await _client.rpc('is_staff')) == true);

  @override
  Future<List<StaffClass>> staffClasses({DateTime? day}) async {
    final r = await _call(() async {
      final s = day == null ? null : studioTime(day);
      final v = await _client.rpc('staff_classes',
          params: _withoutNulls({'p_day': s == null ? null : '${s.year.toString().padLeft(4, '0')}-${s.month.toString().padLeft(2, '0')}-${s.day.toString().padLeft(2, '0')}'}));
      if (v is List) return [for (final x in v) Map<String, dynamic>.from(x as Map)];
      throw const FormatException('expected a list');
    });
    return [for (final j in r) StaffClass.fromJson(j)];
  }

  @override
  Future<String> staffCreateClass({required String classType, required DateTime startsAt, required int durationMin, required String instructor, int? capacity}) async {
    // One attempt only: creating a class twice would make two codes.
    final r = await _rpcMap('staff_create_class', {
      'p_class_type': classType, 'p_starts_at': startsAt.toUtc().toIso8601String(),
      'p_duration_min': durationMin, 'p_instructor': instructor, 'p_capacity': capacity,
    }, RetryPolicy.once);
    if (r['status'] == 'ok') return r['code'] as String;
    throw const ClubException(Failure.invalid, 'Check the class details and try again.');
  }

  @override
  Future<MemberLookup> staffLookup(int memberNumber) async => MemberLookup.fromJson(await _rpcMap('staff_member_lookup', {'p_member_number': memberNumber}));

  @override
  Future<String> staffRedeem(String memberPerkId) async => (await _rpcMap('staff_redeem_perk', {'p_member_perk': memberPerkId}))['status'] as String;

  @override
  Future<List<FlaggedPost>> staffFlagged() async {
    final r = await _call(() async {
      final v = await _client.rpc('staff_flagged_posts');
      if (v is List) return [for (final x in v) Map<String, dynamic>.from(x as Map)];
      throw const FormatException('expected a list');
    });
    return [for (final j in r) FlaggedPost.fromJson(j)];
  }

  @override
  Future<void> staffSetHidden(String postId, bool hidden) async {
    await _rpcMap('staff_set_post_hidden', {'p_post': postId, 'p_hidden': hidden, 'p_reason': hidden ? 'staff' : null});
  }
}

/// Turns whatever a failed call threw into one of our own failures.
ClubException classify(Object e) {
  if (e is ClubException) return e;
  if (e is TimeoutException) return ClubException(Failure.timeout, 'The request timed out.', e);
  if (e is http.ClientException) return ClubException(Failure.offline, 'No connection.', e);
  if (e is AuthRetryableFetchException) return ClubException(Failure.offline, 'No connection.', e);
  if (e is AuthSessionMissingException || e is AuthInvalidJwtException) return ClubException(Failure.authExpired, 'Signed out.', e);
  if (e is AuthApiException) {
    final status = int.tryParse(e.statusCode ?? '') ?? 0;
    if (status == 429 || e.code == 'over_email_send_rate_limit' || e.code == 'over_request_rate_limit') {
      return ClubException(Failure.rateLimited, 'Too many requests.', e);
    }
    if (status == 401 || status == 403) return ClubException(Failure.authExpired, 'Signed out.', e);
    if (status >= 500) return ClubException(Failure.server, 'Server error.', e);
    return ClubException(Failure.invalid, _signInMessage(e), e);
  }
  if (e is PostgrestException) return _fromPostgrest(e);
  if (e is FormatException) return ClubException(Failure.server, 'Unexpected reply.', e); // e.g. a Wi-Fi sign-in page
  final name = e.runtimeType.toString();
  if (name.contains('SocketException') || name.contains('HandshakeException') || name.contains('TlsException') || name.contains('WebSocketException')) {
    return ClubException(Failure.offline, 'No connection.', e);
  }
  return ClubException(Failure.unknown, '$e', e);
}

/// Plain wording for the sign-in errors a member can actually cause. Anything
/// else gets a general message rather than the server's own text.
String _signInMessage(AuthApiException e) {
  switch (e.code) {
    case 'otp_expired':
      return 'That code has expired. Ask for a new one.';
    case 'validation_failed':
    case 'email_address_invalid':
      return 'Please enter a valid email address.';
    case 'email_address_not_authorized':
    case 'signup_disabled':
    case 'otp_disabled':
      return "This email can't be used to sign in yet. Please ask the studio for help.";
    case 'over_email_send_rate_limit':
    case 'over_request_rate_limit':
      return 'Too many tries. Please wait a minute and try again.';
  }
  return 'Something went wrong signing in. Please try again.';
}

ClubException _fromPostgrest(PostgrestException e) {
  final code = e.code ?? '';
  if (code == 'PGRST301' || code == 'PGRST302' || code == 'PGRST303' || code == '28000' || code == '401') {
    return ClubException(Failure.authExpired, 'Signed out.', e);
  }
  if (code == '42501' || code == '403') return ClubException(Failure.notAllowed, 'Not allowed.', e);
  if (code == '429') return ClubException(Failure.rateLimited, 'Too many requests.', e);
  if (code == '408') return ClubException(Failure.timeout, 'The request timed out.', e);
  final numeric = int.tryParse(code);
  if (numeric != null && numeric >= 500) return ClubException(Failure.server, 'Server error.', e);
  // A reply that is not the club's JSON at all: a hotel or cafe Wi-Fi sign-in page, a proxy error.
  final looksLikeWebPage = e.message.trimLeft().startsWith('<');
  if (looksLikeWebPage || code.isEmpty || (numeric != null && numeric >= 200 && numeric < 300)) {
    return ClubException(Failure.server, 'Unexpected reply.', e);
  }
  if (code.startsWith('PGRST0') || code.startsWith('08') || code == '57P01' || code == '53300' || code == '57014') {
    return ClubException(Failure.server, 'The database is busy.', e); // connection, shutdown, too many connections, cancelled
  }
  if (code == '22P02' || code == '23514' || code == '22001') return ClubException(Failure.invalid, 'That did not look right.', e);
  return ClubException(Failure.unknown, e.message, e);
}

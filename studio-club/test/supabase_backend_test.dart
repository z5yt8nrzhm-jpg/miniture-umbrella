import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gilbert_flex_club/data/errors.dart';
import 'package:gilbert_flex_club/data/models.dart';
import 'package:gilbert_flex_club/data/supabase_backend.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthClientOptions, AuthFlowType, SupabaseClient;

/// What the database functions return, in the shapes the SQL tests pin down.
final canned = <String, Object>{
  'my_stats': {
    'has_profile': true,
    'profile': {'display_name': 'Maya', 'member_number': 1042, 'avatar': 'rose', 'favorite_class': 'Yoga Flow', 'member_since': '2026-03-01T17:00:00+00:00'},
    'total_classes': 24, 'current_streak': 5, 'longest_streak': 7, 'classes_this_week': 2, 'last_checkin_at': '2026-10-27T01:10:00.123456+00:00',
    'badges': [{'code': 'first_class', 'earned_at': '2026-03-02T17:00:00+00:00'}],
    'perks': [{'id': 'pk1', 'code': 'free_class_25', 'earned_at': '2026-10-01T17:00:00+00:00', 'redeemed_at': null}],
  },
  'upsert_my_profile': {'status': 'ok'},
  'my_history': [{'class_type': 'yoga_flow', 'instructor': 'Jess', 'starts_at': '2026-10-27T00:00:00+00:00', 'checked_in_at': '2026-10-27T00:05:00+00:00'}],
  'check_in': {
    'status': 'ok', 'class': {'id': 'c1', 'class_type': 'mat_pilates', 'starts_at': '2026-10-28T17:00:00+00:00', 'instructor': 'Mia'},
    'stats': {'total_classes': 25, 'current_streak': 6, 'longest_streak': 7, 'classes_this_week': 3}, 'new_badges': ['classes_25'], 'new_perks': ['free_class_25'],
  },
  'wall_feed': [
    {'id': 'w2', 'author_name': 'Jo', 'author_avatar': 'sky', 'body': 'Hello', 'created_at': '2026-10-28T03:00:00.000002+00:00', 'cheers': 3, 'cheered_by_me': true, 'is_mine': false},
    {'id': 'w1', 'author_name': 'Maya', 'author_avatar': 'rose', 'body': 'Hi', 'created_at': '2026-10-28T03:00:00.000001+00:00', 'cheers': 0, 'cheered_by_me': false, 'is_mine': true},
  ],
  'wall_post': {'status': 'ok', 'id': 'w3', 'duplicate': false},
  'wall_cheer': {'status': 'ok', 'cheers': 4},
  'wall_report': {'status': 'ok'},
  'delete_my_account': {'status': 'deleted'},
  'is_staff': true,
  'staff_create_class': {'status': 'ok', 'id': 'c9', 'code': 'AB7K2Q'},
  'staff_classes': [{'id': 'c1', 'class_type': 'mat_pilates', 'starts_at': '2026-10-28T17:00:00+00:00', 'duration_min': 50, 'instructor': 'Mia', 'capacity': 12, 'code': 'AB7K2Q', 'checkins': 3}],
  'staff_member_lookup': {'status': 'ok', 'display_name': 'Maya', 'member_number': 1042, 'stats': {'total_classes': 25, 'current_streak': 6}, 'perks': [{'id': 'pk1', 'code': 'free_class_25', 'title': 'Free class', 'earned_at': '2026-10-01T17:00:00+00:00', 'redeemed_at': null}]},
  'staff_redeem_perk': {'status': 'ok'},
  'staff_flagged_posts': [{'id': 'w5', 'author_name': 'Sam', 'body': 'x', 'created_at': '2026-10-27T00:00:00+00:00', 'hidden': true, 'hidden_reason': 'reported', 'reports': 3}],
  'staff_set_post_hidden': {'status': 'ok'},
};

const tables = {
  'class_types': [{'code': 'yoga_flow', 'name': 'Yoga Flow', 'pace': 'steady', 'blurb': '', 'sort': 3}],
  'badges': [{'code': 'first_class', 'title': 'First Class', 'blurb': 'You showed up.', 'kind': 'classes', 'threshold': 1, 'sort': 1}],
  'perks': [{'code': 'free_class_25', 'title': 'Free class', 'blurb': '', 'required_classes': 25, 'sort': 1}],
  'classes': [{'id': 'c1', 'class_type': 'mat_pilates', 'starts_at': '2026-10-28T17:00:00+00:00', 'duration_min': 50, 'instructor': 'Mia', 'capacity': 12}],
};

class Call {
  final String method, path;
  final Map<String, dynamic> body;
  Call(this.method, this.path, this.body);
  String get fn => path.startsWith('/rest/v1/rpc/') ? path.substring('/rest/v1/rpc/'.length) : '';
}

http.Response json(Object body, [int status = 200]) => http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

void main() {
  late List<Call> calls;
  late FutureOr<http.Response> Function(http.Request) handler;
  late SupabaseClient client;
  late SupabaseBackend backend;
  final sleeps = <Duration>[];

  FutureOr<http.Response> happy(http.Request r) {
    final path = r.url.path;
    if (path.startsWith('/rest/v1/rpc/')) return json(canned[path.substring('/rest/v1/rpc/'.length)]!);
    final table = path.substring('/rest/v1/'.length);
    return json(tables[table]!);
  }

  setUp(() {
    calls = [];
    sleeps.clear();
    handler = happy;
    client = SupabaseClient('https://club.example.supabase.co', 'sb_publishable_test',
        // The real app stores the sign-in on the phone; a bare test client has nowhere to, so it uses the simple flow.
        authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
        httpClient: MockClient((r) async {
          final decoded = r.bodyBytes.isEmpty ? null : jsonDecode(utf8.decode(r.bodyBytes)); // a call with no arguments sends JSON null
          calls.add(Call(r.method, r.url.path, decoded is Map ? decoded.cast<String, dynamic>() : {}));
          final resp = await handler(r);
          // A real response always knows which request it answers.
          return http.Response.bytes(resp.bodyBytes, resp.statusCode, request: r, headers: resp.headers);
        }));
    backend = SupabaseBackend(client, sleep: (d) async => sleeps.add(d), timeout: const Duration(milliseconds: 200));
  });
  tearDown(() async => client.dispose());

  group('the app and the database agree', () {
    late Map<String, dynamic> contract;
    setUpAll(() => contract = jsonDecode(File('test/contract/rpc_contract.json').readAsStringSync()) as Map<String, dynamic>);

    test('every database call the app makes exists, with the right argument names', () async {
      final now = DateTime.utc(2026, 10, 28, 18);
      await backend.myStats();
      await backend.saveProfile(name: 'Maya', favoriteClass: 'Yoga', avatar: 'rose');
      await backend.history();
      await backend.checkIn('AB7K2Q');
      await backend.wallFeed(beforeCursor: '2026-10-28T03:00:00.000001+00:00', beforeId: 'w1', limit: 20);
      await backend.wallFeed();
      await backend.wallPost('7f2c1c3a-0d6e-4a55-9a61-0c0a2f4b1a11', 'hello');
      await backend.cheer('w1', true);
      await backend.report('w1');
      await backend.isStaff();
      await backend.staffClasses();
      await backend.staffClasses(day: now);
      await backend.staffCreateClass(classType: 'mat_pilates', startsAt: now, durationMin: 50, instructor: 'Mia', capacity: 12);
      await backend.staffCreateClass(classType: 'mat_pilates', startsAt: now, durationMin: 50, instructor: 'Mia');
      await backend.staffLookup(1042);
      await backend.staffRedeem('pk1');
      await backend.staffFlagged();
      await backend.staffSetHidden('w1', true);
      await backend.staffSetHidden('w1', false);
      await backend.deleteAccount();

      final rpcs = calls.where((c) => c.fn.isNotEmpty).toList();
      for (final c in rpcs) {
        final spec = contract[c.fn] as Map<String, dynamic>?;
        expect(spec, isNotNull, reason: '${c.fn} is not a function the database offers to members');
        final args = (spec!['args'] as List).cast<String>().toSet();
        final required = (spec['args'] as List).cast<String>().take(spec['required'] as int).toSet();
        expect(c.body.keys.toSet().difference(args), isEmpty, reason: '${c.fn} sent an argument the database does not have');
        expect(required.difference(c.body.keys.toSet()), isEmpty, reason: '${c.fn} left out a required argument');
      }
      expect(rpcs.map((c) => c.fn).toSet(), contract.keys.toSet(), reason: 'the app and the database offer different sets of functions');
    });

    test('nothing sent to the database is null where the database has a default', () async {
      await backend.wallFeed();
      await backend.staffCreateClass(classType: 'mat_pilates', startsAt: DateTime.utc(2026, 10, 28, 18), durationMin: 50, instructor: 'Mia');
      for (final c in calls.where((c) => c.fn.isNotEmpty)) {
        expect(c.body.values.contains(null), isFalse, reason: c.fn);
      }
    });
  });

  group('reading the answers', () {
    test('home screen', () async {
      final s = await backend.myStats();
      expect(s.profile!.displayName, 'Maya');
      expect(s.profile!.memberNumber, 1042);
      expect([s.totalClasses, s.currentStreak, s.longestStreak, s.classesThisWeek], [24, 5, 7, 2]);
      expect(s.hasBadge('first_class'), isTrue);
      expect(s.perks.single.redeemed, isFalse);
    });

    test('check-in, including awards', () async {
      final r = await backend.checkIn('ab7k2q');
      expect(r.status, CheckInStatus.ok);
      expect(r.counted, isTrue);
      expect(r.totalClasses, 25);
      expect(r.newBadges, ['classes_25']);
      expect(r.newPerks, ['free_class_25']);
      expect(r.studioClass!.instructor, 'Mia');
      expect(calls.single.body, {'p_code': 'ab7k2q'});
    });

    test('every check-in status the database can give is understood', () {
      for (final (raw, want) in [
        ('ok', CheckInStatus.ok), ('already', CheckInStatus.already), ('invalid', CheckInStatus.invalid), ('closed', CheckInStatus.closed),
        ('limit', CheckInStatus.limit), ('throttled', CheckInStatus.throttled), ('no_profile', CheckInStatus.noProfile),
      ]) {
        expect(CheckInResult.fromJson({'status': raw}).status, want, reason: raw);
      }
      expect(CheckInResult.fromJson({'status': 'already'}).counted, isTrue, reason: 'a repeat tap still counts as checked in');
      expect(CheckInResult.fromJson({'status': 'limit'}).counted, isFalse);
    });

    test('the wall keeps the exact timestamp text for paging', () async {
      final posts = await backend.wallFeed();
      expect(posts.first.cursor, '2026-10-28T03:00:00.000002+00:00');
      expect(posts.last.cursor, '2026-10-28T03:00:00.000001+00:00');
      expect(posts.first.cheeredByMe, isTrue);
      expect(posts.last.isMine, isTrue);
      // and sends it back unchanged, microseconds included
      await backend.wallFeed(beforeCursor: posts.last.cursor, beforeId: posts.last.id);
      expect(calls.last.body['p_before'], '2026-10-28T03:00:00.000001+00:00');
      expect(calls.last.body['p_before_id'], 'w1');
    });

    test('a saved post round-trips through the phone\'s cache without losing precision', () async {
      final p = (await backend.wallFeed()).first;
      final back = WallPost.fromJson(jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>);
      expect(back.cursor, p.cursor);
    });

    test('the catalog is read from three tables', () async {
      final c = await backend.catalog();
      expect(c.className('yoga_flow'), 'Yoga Flow');
      expect(c.badge('first_class')!.title, 'First Class');
      expect(c.perk('free_class_25')!.requiredClasses, 25);
    });

    test('staff screens', () async {
      final day = (await backend.staffClasses()).single;
      expect([day.code, day.checkins], ['AB7K2Q', 3]);
      final m = await backend.staffLookup(1042);
      expect([m.found, m.displayName, m.perks.single.title], [true, 'Maya', 'Free class']);
      expect(await backend.staffRedeem('pk1'), 'ok');
      expect((await backend.staffFlagged()).single.reports, 3);
    });

    test('a studio day is sent as a Phoenix date, not a UTC one', () async {
      await backend.staffClasses(day: DateTime.utc(2026, 3, 14, 6, 30)); // Fri Mar 13, 11:30pm in Phoenix
      expect(calls.single.body['p_day'], '2026-03-13');
    });
  });

  group('when the connection misbehaves', () {
    test('no signal: tries three times, waiting longer each time, then says offline', () async {
      handler = (_) => throw http.ClientException('Failed host lookup');
      await expectLater(backend.myStats(), throwsA(isA<ClubException>().having((e) => e.kind, 'kind', Failure.offline)));
      expect(calls.length, 3);
      expect(sleeps.length, 2);
      expect(sleeps[1], greaterThan(sleeps[0]));
    });

    test('signal comes back on the second try', () async {
      var n = 0;
      handler = (r) => ++n == 1 ? throw http.ClientException('connection reset') : happy(r);
      expect((await backend.myStats()).totalClasses, 24);
      expect(calls.length, 2);
    });

    test('a request that never answers times out and is retried', () async {
      handler = (_) => Completer<http.Response>().future;
      await expectLater(backend.myStats(), throwsA(isA<ClubException>().having((e) => e.kind, 'kind', Failure.timeout)));
      expect(calls.length, 3);
    });

    test('a server error is retried, then reported as the club being busy', () async {
      handler = (_) => http.Response('Bad Gateway', 502);
      await expectLater(backend.checkIn('AB7K2Q'), throwsA(isA<ClubException>().having((e) => e.kind, 'kind', Failure.server)));
      expect(calls.length, 3);
    });

    test('a database connection limit is treated as a busy moment, not a bug', () async {
      handler = (_) => json({'code': 'PGRST000', 'message': 'could not connect to the database'}, 503);
      await expectLater(backend.myStats(), throwsA(isA<ClubException>().having((e) => e.kind, 'kind', Failure.server)));
      expect(calls.length, 3);
    });

    test('a Wi-Fi sign-in page instead of the club is not mistaken for data', () async {
      handler = (_) => http.Response('<html><body>Welcome to Guest WiFi</body></html>', 200, headers: {'content-type': 'text/html'});
      await expectLater(backend.myStats(), throwsA(isA<ClubException>().having((e) => e.retryable, 'retryable', isTrue)));
    });

    test('an expired sign-in is reported at once, not retried', () async {
      handler = (_) => json({'code': 'PGRST301', 'message': 'JWT expired'}, 401);
      await expectLater(backend.myStats(), throwsA(isA<ClubException>().having((e) => e.kind, 'kind', Failure.authExpired)));
      expect(calls.length, 1);
    });

    test('a staff-only call from a member is refused at once', () async {
      handler = (_) => json({'code': '42501', 'message': 'not_staff'}, 403);
      await expectLater(backend.staffClasses(), throwsA(isA<ClubException>().having((e) => e.kind, 'kind', Failure.notAllowed)));
      expect(calls.length, 1);
    });

    test('creating a class is never retried (it would make a second code)', () async {
      handler = (_) => http.Response('Bad Gateway', 502);
      await expectLater(backend.staffCreateClass(classType: 'mat_pilates', startsAt: DateTime.utc(2026, 10, 28, 18), durationMin: 50, instructor: 'Mia'), throwsA(isA<ClubException>()));
      expect(calls.length, 1);
    });

    test('checking in IS retried: the database makes a repeat harmless', () async {
      var n = 0;
      handler = (r) => ++n < 3 ? http.Response('Bad Gateway', 502) : happy(r);
      expect((await backend.checkIn('AB7K2Q')).counted, isTrue);
      expect(calls.length, 3);
    });
  });

  group('signing in', () {
    test('a wrong or expired code gets a plain message', () async {
      handler = (_) => json({'code': 403, 'error_code': 'otp_expired', 'msg': 'Token has expired or is invalid'}, 403);
      await expectLater(
        backend.verifyCode('maya@example.com', '000000'),
        throwsA(isA<ClubException>().having((e) => friendly(e), 'message', contains("didn't work"))),
      );
      expect(calls.length, 1, reason: 'a wrong code must not be retried');
    });

    test('asking for a code too often says to wait', () async {
      handler = (_) => json({'code': 429, 'error_code': 'over_email_send_rate_limit', 'msg': 'email rate limit exceeded'}, 429);
      await expectLater(backend.sendCode('maya@example.com'), throwsA(isA<ClubException>().having((e) => e.kind, 'kind', Failure.rateLimited)));
      expect(calls.length, 1);
    });

    test('an address the studio has not enabled gets a helpful message', () async {
      handler = (_) => json({'code': 400, 'error_code': 'email_address_not_authorized', 'msg': 'Email address not authorized'}, 400);
      await expectLater(
        backend.sendCode('maya@example.com'),
        throwsA(isA<ClubException>().having((e) => friendly(e), 'message', contains('ask the studio'))),
      );
    });

    test('the code request carries the email and asks to create the member if new', () async {
      handler = (_) => json({});
      await backend.sendCode('  maya@example.com ');
      expect(calls.single.path, '/auth/v1/otp');
      expect(calls.single.body['email'], 'maya@example.com');
      expect(calls.single.body['create_user'], isTrue);
    });

    test('signing out works with no signal', () async {
      handler = (_) => throw http.ClientException('offline');
      await backend.signOut(); // must not throw
    });
  });
}

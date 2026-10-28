import 'package:flutter_test/flutter_test.dart';
import 'package:gilbert_flex_club/data/demo_backend.dart';
import 'package:gilbert_flex_club/data/errors.dart';
import 'package:gilbert_flex_club/data/local_store.dart';
import 'package:gilbert_flex_club/data/models.dart';
import 'package:gilbert_flex_club/state/club_controller.dart';

import 'support/flaky_backend.dart';

class Rig {
  Rig(this.demo, this.net, this.store, this.c);
  final DemoBackend demo;
  final FlakyBackend net;
  final MemoryStore store;
  final ClubController c;
}

/// A member who is already signed in with a profile, unless asked otherwise.
Future<DemoBackend> memberBackend({String email = 'maya@example.com', bool profile = true, DateTime Function()? clock}) async {
  final d = DemoBackend(latency: Duration.zero, clock: clock);
  await d.sendCode(email);
  await d.verifyCode(email, '123456');
  if (profile) await d.saveProfile(name: 'Maya', favoriteClass: 'Yoga Flow', avatar: 'rose');
  return d;
}

Future<Rig> start({
  DemoBackend? demo,
  MemoryStore? store,
  bool boot = true,
  bool autoPoll = false,
  Duration pollEvery = const Duration(milliseconds: 20),
  DateTime Function()? clock,
}) async {
  final d = demo ?? await memberBackend();
  final net = FlakyBackend(d);
  final s = store ?? MemoryStore();
  final c = ClubController(net, s, autoPoll: autoPoll, pollEvery: pollEvery, clock: clock);
  addTearDown(c.dispose);
  if (boot) await c.boot();
  return Rig(d, net, s, c);
}

void main() {
  group('opening the app', () {
    test('signed out goes to sign-in', () async {
      final r = await start(demo: DemoBackend(latency: Duration.zero));
      expect(r.c.phase, Phase.signedOut);
    });

    test('a signed-in member sees their club', () async {
      final r = await start();
      expect(r.c.phase, Phase.ready);
      expect(r.c.stats!.profile!.displayName, 'Maya');
      expect(r.c.stats!.totalClasses, 8);
      expect(r.c.catalog.badges, isNotEmpty);
      expect(r.c.schedule, isNotEmpty);
      expect(r.c.wall, isNotEmpty);
      expect(r.c.offline, isFalse);
      expect(r.c.isStaff, isFalse);
    });

    test('staff are recognised', () async {
      final r = await start(demo: await memberBackend(email: 'front.staff@example.com'));
      expect(r.c.isStaff, isTrue);
    });

    test('with no signal, the app opens from what it saved and says so', () async {
      final first = await start();
      first.c.dispose();
      // Next day, in a basement with no signal:
      final second = await start(demo: first.demo, store: first.store, boot: false);
      second.net.offline = true;
      await second.c.boot();
      expect(second.c.phase, Phase.ready, reason: 'it must not throw the member out');
      expect(second.c.stats!.profile!.displayName, 'Maya');
      expect(second.c.stats!.totalClasses, 8);
      expect(second.c.wall, isNotEmpty);
      expect(second.c.catalog.badges, isNotEmpty);
      expect(second.c.offline, isTrue);
      expect(second.c.backend.signedIn, isTrue, reason: 'the sign-in is untouched by a lost signal');
    });

    test('with no signal and nothing saved, it asks to try again, then recovers', () async {
      final r = await start(boot: false);
      r.net.offline = true;
      await r.c.boot();
      expect(r.c.phase, Phase.unreachable);
      r.net.offline = false;
      await r.c.refreshAll();
      expect(r.c.phase, Phase.ready);
      expect(r.c.offline, isFalse);
    });

    test('a signal that returns clears the offline notice', () async {
      final r = await start();
      r.net.offline = true;
      await r.c.refreshAll();
      expect(r.c.offline, isTrue);
      r.net.offline = false;
      await r.c.refreshAll();
      expect(r.c.offline, isFalse);
    });

    test('a server having a bad moment is treated like no signal, not a sign-out', () async {
      final r = await start();
      r.net.failNext = 1;
      r.net.failWith = Failure.server;
      await r.c.refreshAll();
      expect(r.c.offline, isTrue);
      expect(r.c.phase, Phase.ready);
    });

    test('an expired sign-in signs out cleanly and wipes what was saved', () async {
      final r = await start();
      expect(await r.store.read('stats'), isNotNull);
      r.net.expired = true;
      await r.c.refreshAll();
      expect(r.c.phase, Phase.signedOut);
      expect(r.c.stats, isNull);
      expect(r.c.notice, 'Please sign in again.');
      expect(r.store.data, isEmpty, reason: 'nothing of the member is left on the phone');
    });

    test('a damaged saved copy is ignored, not fatal', () async {
      final store = MemoryStore()..data['stats'] = '{{{ not json'..data['wall'] = '[1,2';
      final r = await start(store: store);
      expect(r.c.phase, Phase.ready);
      expect(r.c.stats!.totalClasses, 8);
    });

    test('two refreshes at once make one round of calls', () async {
      final r = await start();
      final before = r.net.reached['myStats']!;
      await Future.wait([r.c.refreshAll(), r.c.refreshAll(), r.c.refreshAll()]);
      expect(r.net.reached['myStats'], before + 1);
    });

    test('coming back to the app refreshes only if it has been a while', () async {
      var t = DateTime(2026, 10, 28, 9);
      final r = await start(clock: () => t);
      final before = r.net.reached['myStats']!;
      t = t.add(const Duration(seconds: 10));
      r.c.onResume();
      await Future<void>.delayed(Duration.zero);
      expect(r.net.reached['myStats'], before, reason: 'a quick switch back needs no refresh');
      t = t.add(const Duration(seconds: 30));
      r.c.onResume();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(r.net.reached['myStats'], before + 1);
    });

    test('it keeps trying on its own while offline, and recovers without a tap', () async {
      final r = await start(autoPoll: true);
      r.net.offline = true;
      await r.c.refreshAll();
      expect(r.c.offline, isTrue);
      r.net.offline = false;
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(r.c.offline, isFalse);
    });
  });

  group('signing in', () {
    test('code flow: email, wrong code, right code, profile', () async {
      final r = await start(demo: DemoBackend(latency: Duration.zero));
      await r.c.sendCode(' maya@example.com ');
      expect(r.c.pendingEmail, 'maya@example.com');
      await expectLater(r.c.verifyCode('000000'), throwsA(isA<ClubException>().having((e) => e.kind, 'kind', Failure.invalid)));
      expect(r.c.phase, Phase.signedOut, reason: 'a wrong code is not a failure of the club');
      await r.c.verifyCode('123456');
      expect(r.c.phase, Phase.needsProfile);
      await r.c.saveProfile(name: 'Maya', avatar: 'rose');
      expect(r.c.phase, Phase.ready);
    });

    test('a bad email is explained', () async {
      final r = await start(demo: DemoBackend(latency: Duration.zero));
      await expectLater(r.c.sendCode('nope'), throwsA(isA<ClubException>().having((e) => friendly(e), 'message', contains('valid email'))));
    });

    test('signing out clears everything saved, so the next person on a shared phone sees nothing', () async {
      final r = await start();
      await r.c.post('hello');
      await r.c.signOut();
      expect(r.c.phase, Phase.signedOut);
      expect(r.c.stats, isNull);
      expect(r.c.wall, isEmpty);
      expect(r.store.data, isEmpty);
    });

    test('deleting the account does the same, and says what happened', () async {
      final r = await start();
      await r.c.deleteAccount();
      expect(r.c.phase, Phase.signedOut);
      expect(r.store.data, isEmpty);
      expect(r.c.notice, contains('deleted'));
    });

    test('a failed delete leaves the member signed in and tells them', () async {
      final r = await start();
      r.net.offline = true;
      await expectLater(r.c.deleteAccount(), throwsA(isA<ClubException>()));
      expect(r.c.phase, Phase.ready);
    });
  });

  group('checking in', () {
    test('a class is counted and the home screen updates at once', () async {
      final r = await start();
      final res = await r.c.checkIn('mat222');
      expect(res.status, CheckInStatus.ok);
      expect(r.c.stats!.totalClasses, 9);
      expect(r.c.stats!.hasBadge('first_class'), isTrue);
    });

    test('no signal: the member is told, the app notes it, nothing is counted', () async {
      final r = await start();
      r.net.offline = true;
      await expectLater(r.c.checkIn('MAT222'), throwsA(isA<ClubException>().having((e) => e.isConnection, 'isConnection', isTrue)));
      expect(r.c.offline, isTrue);
      r.net.offline = false;
      expect((await r.demo.myStats()).totalClasses, 8);
    });

    test('the reply is lost after the club counted it: trying again says already, and the count is right', () async {
      final r = await start();
      r.net.loseReplies = true;
      await expectLater(r.c.checkIn('MAT222'), throwsA(isA<ClubException>()));
      r.net.loseReplies = false;
      final again = await r.c.checkIn('MAT222');
      expect(again.status, CheckInStatus.already);
      expect(again.counted, isTrue);
      expect(r.c.stats!.totalClasses, 9);
      expect((await r.demo.myStats()).totalClasses, 9, reason: 'counted once, not twice');
    });

    test('hammering the button counts one class', () async {
      final r = await start();
      final results = await Future.wait([for (var i = 0; i < 12; i++) r.c.checkIn('MAT222')]);
      expect(results.where((x) => x.status == CheckInStatus.ok).length, 1);
      expect(results.where((x) => x.counted).length, 12);
      expect((await r.demo.myStats()).totalClasses, 9);
    });

    test('an expired sign-in during check-in signs out instead of failing mysteriously', () async {
      final r = await start();
      r.net.expired = true;
      await expectLater(r.c.checkIn('MAT222'), throwsA(isA<ClubException>()));
      expect(r.c.phase, Phase.signedOut);
    });
  });

  group('the wall', () {
    test('a post goes straight up and appears', () async {
      final r = await start();
      await r.c.post('  Did my first handstand!  ');
      expect(r.c.pending, isEmpty);
      expect(r.c.wall.first.body, 'Did my first handstand!');
      expect(r.c.wall.first.isMine, isTrue);
    });

    test('an empty post is ignored', () async {
      final r = await start();
      await r.c.post('   ');
      expect(r.c.pending, isEmpty);
      expect(r.net.reached['wallPost'], isNull);
    });

    test('posted from a lift: it waits on the phone, survives closing the app, and goes up once when signal returns', () async {
      final r = await start();
      r.net.offline = true;
      await r.c.post('Posting from the lift');
      expect(r.c.pending.length, 1);
      expect(r.c.offline, isTrue);
      expect(r.store.data['pending_posts'], contains('Posting from the lift'), reason: 'saved on the phone');

      // The app is closed and opened again, still with no signal.
      r.c.dispose();
      final r2 = await start(demo: r.demo, store: r.store, boot: false);
      r2.net.offline = true;
      await r2.c.boot();
      expect(r2.c.pending.single.body, 'Posting from the lift');

      // Signal returns.
      r2.net.offline = false;
      await r2.c.refreshAll();
      expect(r2.c.pending, isEmpty);
      expect(r2.c.wall.where((p) => p.body == 'Posting from the lift').length, 1);
      expect(r2.store.data['pending_posts'], '[]');
    });

    test('the reply is lost after the club saved the post: it retries with the same id and appears once', () async {
      final r = await start();
      r.net.loseReplies = true;
      await r.c.post('A post on a bad connection');
      expect(r.c.pending.length, 1, reason: 'the phone cannot know it worked');
      r.net.loseReplies = false;
      await r.c.flushPending();
      await r.c.flushPending();
      expect(r.c.pending, isEmpty);
      expect(r.c.wall.where((p) => p.body == 'A post on a bad connection').length, 1);
      expect(r.net.postIds.toSet().length, 1, reason: 'every try carried the same id');
      expect(r.net.postIds.length, greaterThanOrEqualTo(2));
    });

    test('the sixth post in an hour is declined politely and not retried forever', () async {
      final r = await start();
      for (var i = 1; i <= 6; i++) {
        await r.c.post('Post number $i');
      }
      expect(r.c.pending, isEmpty);
      expect(r.c.notice, contains('5 posts'));
      expect(r.c.wall.where((p) => p.isMine).length, 5);
    });

    test('a cheer shows at once, and the true count replaces it', () async {
      final r = await start();
      final p = r.c.wall.firstWhere((p) => !p.cheeredByMe);
      final before = p.cheers;
      final f = r.c.cheer(p);
      expect(r.c.wall.firstWhere((x) => x.id == p.id).cheeredByMe, isTrue, reason: 'optimistic');
      await f;
      expect(r.c.wall.firstWhere((x) => x.id == p.id).cheers, before + 1);
    });

    test('a cheer that cannot be sent is taken back and explained', () async {
      final r = await start();
      final p = r.c.wall.firstWhere((p) => !p.cheeredByMe);
      r.net.offline = true;
      await r.c.cheer(p);
      final after = r.c.wall.firstWhere((x) => x.id == p.id);
      expect(after.cheeredByMe, isFalse);
      expect(after.cheers, p.cheers);
      expect(r.c.notice, contains('offline'));
    });

    test('tapping a cheer twice quickly sends one request', () async {
      final r = await start();
      final p = r.c.wall.first;
      await Future.wait([r.c.cheer(p), r.c.cheer(p), r.c.cheer(p)]);
      expect(r.net.reached['cheer'], 1);
    });

    test('a reported post disappears at once, and stays gone after a refresh and a restart', () async {
      final r = await start();
      final p = r.c.wall.first;
      await r.c.report(p);
      expect(r.c.wall.any((x) => x.id == p.id), isFalse);
      await r.c.refreshWall();
      expect(r.c.wall.any((x) => x.id == p.id), isFalse, reason: 'the club has not hidden it yet; this phone does');
      r.c.dispose();
      final r2 = await start(demo: r.demo, store: r.store);
      expect(r2.c.wall.any((x) => x.id == p.id), isFalse);
    });

    test('a report that cannot be sent still hides the post, and says to try again', () async {
      final r = await start();
      final p = r.c.wall.first;
      r.net.offline = true;
      await r.c.report(p);
      expect(r.c.wall.any((x) => x.id == p.id), isFalse);
      expect(r.c.notice, contains('report it again'));
    });

    test('paging through a long wall loads every post once, newest first', () async {
      var t = DateTime(2026, 10, 1, 8);
      final d = await memberBackend(clock: () => t);
      for (var batch = 0; batch < 10; batch++) {
        for (var i = 0; i < 5; i++) {
          t = t.add(const Duration(minutes: 1));
          await d.wallPost('batch$batch-$i-${t.millisecondsSinceEpoch}', 'Post $batch.$i');
        }
        t = t.add(const Duration(hours: 2)); // the hourly limit resets
      }
      final r = await start(demo: d, clock: () => t);
      final firstPage = r.c.wall.length;
      expect(firstPage, 20);
      while (r.c.wallHasMore) {
        await r.c.loadMoreWall();
      }
      final ids = r.c.wall.map((p) => p.id).toList();
      expect(ids.toSet().length, ids.length, reason: 'no post appears twice');
      expect(ids.length, 54, reason: '50 new posts and 4 from other members, none missing');
      for (var i = 1; i < r.c.wall.length; i++) {
        expect(r.c.wall[i - 1].createdAt.isBefore(r.c.wall[i].createdAt), isFalse, reason: 'newest first');
      }
    });

    test('with no signal, saved posts still show', () async {
      final first = await start();
      first.c.dispose();
      final second = await start(demo: first.demo, store: first.store, boot: false);
      second.net.offline = true;
      await second.c.boot();
      expect(second.c.wall, isNotEmpty);
    });
  });

  test('notices are shown once and cleared', () async {
    final r = await start();
    r.net.offline = true;
    final p = r.c.wall.first;
    await r.c.cheer(p);
    expect(r.c.notice, isNotNull);
    r.c.clearNotice();
    expect(r.c.notice, isNull);
  });
}

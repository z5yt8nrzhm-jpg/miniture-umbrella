import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:gilbert_flex_club/data/errors.dart';
import 'package:gilbert_flex_club/data/retry.dart';

class _NoJitter implements Random {
  @override
  bool nextBool() => false;
  @override
  double nextDouble() => 0;
  @override
  int nextInt(int max) => 0;
}

void main() {
  group('retry', () {
    test('a call that works is made once', () async {
      var calls = 0;
      expect(await withRetry(() async => ++calls), 1);
      expect(calls, 1);
    });

    test('a dropped connection is retried, with growing waits', () async {
      var calls = 0;
      final waits = <Duration>[];
      final r = await withRetry(() async {
        if (++calls < 3) throw const ClubException(Failure.offline, 'no signal');
        return 'ok';
      }, sleep: (d) async => waits.add(d), random: _NoJitter());
      expect(r, 'ok');
      expect(calls, 3);
      expect(waits, [const Duration(milliseconds: 500), const Duration(seconds: 1)]);
    });

    test('gives up after the last attempt and reports why', () async {
      var calls = 0;
      await expectLater(
        withRetry(() async {
          calls++;
          throw const ClubException(Failure.timeout, 'slow');
        }, sleep: (_) async {}),
        throwsA(isA<ClubException>().having((e) => e.kind, 'kind', Failure.timeout)),
      );
      expect(calls, 3);
    });

    test('waits never exceed the cap', () async {
      final waits = <Duration>[];
      await expectLater(
        withRetry(() async => throw const ClubException(Failure.server, 'x'),
            policy: const RetryPolicy(attempts: 8, base: Duration(seconds: 1), max: Duration(seconds: 4)),
            sleep: (d) async => waits.add(d), random: _NoJitter()),
        throwsA(isA<ClubException>()),
      );
      expect(waits.every((w) => w <= const Duration(seconds: 4)), isTrue);
      expect(waits.last, const Duration(seconds: 4));
    });

    test('jitter spreads retries out, by at most a quarter', () async {
      final waits = <Duration>[];
      for (var i = 0; i < 30; i++) {
        var first = true;
        await withRetry(() async {
          if (first) {
            first = false;
            throw const ClubException(Failure.offline, 'x');
          }
          return 1;
        }, sleep: (d) async => waits.add(d), random: Random(i));
      }
      expect(waits.every((w) => w >= const Duration(milliseconds: 500) && w <= const Duration(milliseconds: 625)), isTrue);
      expect(waits.toSet().length, greaterThan(10), reason: 'phones that lost signal together must not retry in lockstep');
    });

    for (final kind in [Failure.authExpired, Failure.notAllowed, Failure.invalid, Failure.rateLimited, Failure.unknown]) {
      test('${kind.name} is not retried', () async {
        var calls = 0;
        await expectLater(withRetry(() async {
          calls++;
          throw ClubException(kind, 'no');
        }, sleep: (_) async {}), throwsA(isA<ClubException>()));
        expect(calls, 1);
      });
    }

    test('a call that must not repeat is made once, even when it could be retried', () async {
      var calls = 0;
      await expectLater(withRetry(() async {
        calls++;
        throw const ClubException(Failure.offline, 'x');
      }, policy: RetryPolicy.once, sleep: (_) async {}), throwsA(isA<ClubException>()));
      expect(calls, 1);
    });

    test('friendly messages never show codes or stack traces', () {
      for (final k in Failure.values.where((k) => k != Failure.invalid)) {
        final text = friendly(ClubException(k, 'Row level security violation 42501'));
        expect(text, isNot(contains('42501')));
        expect(text, isNot(contains('Exception')));
        expect(text, isNotEmpty);
      }
      // "invalid" carries a message written for members, and shows it as is.
      expect(friendly(const ClubException(Failure.invalid, 'Please use a shorter name.')), 'Please use a shorter name.');
    });
  });
}

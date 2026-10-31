/// Retry with backoff, for the kind of failure a phone has all the time.
///
/// Safe because every club call is built to be repeated: a check-in, a post
/// (which carries a client id), a cheer (which sets on or off rather than
/// toggling) and a redeem all give the same answer the second time. The one
/// call that is not repeatable, creating a class, uses a single attempt.
library;

import 'dart:async';
import 'dart:math';

import 'errors.dart';

typedef Sleep = Future<void> Function(Duration d);

class RetryPolicy {
  final int attempts;
  final Duration base, max, timeout;
  const RetryPolicy({this.attempts = 3, this.base = const Duration(milliseconds: 500), this.max = const Duration(seconds: 4), this.timeout = const Duration(seconds: 12)});

  /// For calls that must not be repeated.
  static const once = RetryPolicy(attempts: 1);
  static const standard = RetryPolicy();
}

/// Runs [op]. Failures that are [ClubException.retryable] are retried after
/// 0.5 s, 1 s, 2 s... plus up to 25% jitter, so a room full of phones that
/// lost signal together do not all knock again at the same instant.
Future<T> withRetry<T>(
  Future<T> Function() op, {
  RetryPolicy policy = RetryPolicy.standard,
  Sleep? sleep,
  Random? random,
  void Function(int attempt, ClubException error)? onRetry,
}) async {
  final wait = sleep ?? (d) => Future<void>.delayed(d);
  final rng = random ?? Random();
  for (var attempt = 1;; attempt++) {
    try {
      return await op();
    } on ClubException catch (e) {
      if (!e.retryable || attempt >= policy.attempts) rethrow;
      final backoff = policy.base * pow(2, attempt - 1);
      final capped = backoff > policy.max ? policy.max : backoff;
      final jitter = Duration(milliseconds: (capped.inMilliseconds * 0.25 * rng.nextDouble()).round());
      onRetry?.call(attempt, e);
      await wait(capped + jitter);
    }
  }
}

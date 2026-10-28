/// Every way a call can fail, reduced to what the app needs to decide:
/// try again quietly, tell the member, or sign them out.
library;

enum Failure {
  offline,      // no signal, DNS, connection dropped
  timeout,      // the request took too long
  server,       // a 5xx or an overloaded server
  authExpired,  // the sign-in is no longer valid
  notAllowed,   // staff-only or otherwise forbidden
  rateLimited,  // too many requests
  invalid,      // the input was wrong; retrying will not help
  unknown,
}

class ClubException implements Exception {
  final Failure kind;
  final String message;
  final Object? cause;
  const ClubException(this.kind, this.message, [this.cause]);

  /// Worth trying again without bothering the member.
  bool get retryable => kind == Failure.offline || kind == Failure.timeout || kind == Failure.server;

  /// The phone has no usable connection right now.
  bool get isConnection => kind == Failure.offline || kind == Failure.timeout;

  @override
  String toString() => 'ClubException(${kind.name}: $message)';
}

/// Plain words for the member. Never shows a stack trace or a status code.
String friendly(ClubException e) => switch (e.kind) {
      Failure.offline => "You're offline. We'll try again when you have signal.",
      Failure.timeout => 'That took too long. Check your signal and try again.',
      Failure.server => 'The club is having a moment. Please try again shortly.',
      Failure.authExpired => 'Please sign in again.',
      Failure.notAllowed => "That isn't available to your account.",
      Failure.rateLimited => 'Too many tries. Please wait a minute and try again.',
      Failure.invalid => e.message,
      Failure.unknown => 'Something went wrong. Please try again.',
    };

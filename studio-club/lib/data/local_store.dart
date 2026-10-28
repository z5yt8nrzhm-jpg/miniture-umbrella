/// What the phone remembers between launches: the last answers it got (so the
/// app opens instantly and still works with no signal), posts waiting to be
/// sent, and posts this member reported. Wiped on sign-out, so a shared
/// phone never shows the next person someone else's club.
library;

import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

abstract class LocalStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> clear();
}

class MemoryStore implements LocalStore {
  final Map<String, String> data = {};
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async => data[key] = value;
  @override
  Future<void> clear() async => data.clear();
}

class PrefsStore implements LocalStore {
  PrefsStore._(this._p);
  final SharedPreferences? _p;
  static const _prefix = 'club.';

  /// Storage can be unavailable (private browsing, a full disk). The app
  /// still works without it, it just can't remember anything.
  static Future<PrefsStore> open() async {
    try {
      return PrefsStore._(await SharedPreferences.getInstance());
    } catch (_) {
      return PrefsStore._(null);
    }
  }

  @override
  Future<String?> read(String key) async {
    try {
      return _p?.getString('$_prefix$key');
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(String key, String value) async {
    try {
      await _p?.setString('$_prefix$key', value);
    } catch (_) {}
  }

  @override
  Future<void> clear() async {
    try {
      final p = _p;
      if (p == null) return;
      for (final k in p.getKeys().where((k) => k.startsWith(_prefix)).toList()) {
        await p.remove(k);
      }
    } catch (_) {}
  }
}

extension JsonStore on LocalStore {
  Future<Object?> readJson(String key) async {
    final raw = await read(key);
    if (raw == null) return null;
    try {
      return jsonDecode(raw);
    } catch (_) {
      return null; // a damaged cache is just an empty cache
    }
  }

  Future<void> writeJson(String key, Object? value) => write(key, jsonEncode(value));
}

/// A random version-4 id, made on the phone for each post so a retry reuses it.
String newId([Random? random]) {
  final r = random ?? Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  String h(int from, int to) => b.sublist(from, to).map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h(0, 4)}-${h(4, 6)}-${h(6, 8)}-${h(8, 10)}-${h(10, 16)}';
}

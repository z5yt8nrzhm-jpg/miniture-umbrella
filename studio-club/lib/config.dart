/// Where the club lives. Pass these when building; real keys never go in git:
///   flutter run --dart-define=SUPABASE_URL=https://xxxx.supabase.co --dart-define=SUPABASE_KEY=sb_publishable_...
/// With neither, the app runs in demo mode on built-in sample data.
///
/// The publishable key (formerly "anon" key) is designed to be shipped inside
/// an app. What it can do is limited by the database rules, not by secrecy.
/// The secret / service_role key must NEVER go in this app.
library;

class AppConfig {
  static const url = String.fromEnvironment('SUPABASE_URL');
  static const key = String.fromEnvironment('SUPABASE_KEY');
  static bool get configured => url.isNotEmpty && key.isNotEmpty;
}

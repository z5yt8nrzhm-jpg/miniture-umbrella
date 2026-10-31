import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'config.dart';
import 'data/backend.dart';
import 'data/demo_backend.dart';
import 'data/local_store.dart';
import 'data/supabase_backend.dart';
import 'state/club_controller.dart';
import 'ui/app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = await PrefsStore.open();

  final ClubBackend backend;
  if (AppConfig.configured) {
    // The sign-in is kept on the phone and refreshed for you. A member stays
    // signed in across launches, and a dropped connection doesn't sign them out.
    await Supabase.initialize(url: AppConfig.url, publishableKey: AppConfig.key);
    backend = SupabaseBackend(Supabase.instance.client);
  } else {
    backend = DemoBackend();
  }

  final controller = ClubController(backend, store);
  runApp(ClubApp(controller: controller, demo: !AppConfig.configured));
  await controller.boot();
}

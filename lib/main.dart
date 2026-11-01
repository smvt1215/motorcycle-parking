import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';
import 'core/config.dart';
import 'data/app_store.dart';
import 'data/repositories.dart';
import 'features/map/heavy_glyph.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  AppConfig.validate();
  // The licensed badge silhouette, when this build carries it.
  unawaited(loadHeavyGlyph());
  SupabaseClient? client;
  if (!AppConfig.demo) {
    await Supabase.initialize(
      url: AppConfig.supabaseUrl,
      publishableKey: AppConfig.supabaseKey,
    );
    client = Supabase.instance.client;
  }
  final store = AppStore(
    LocalRepository(await SharedPreferences.getInstance()),
    client,
  );
  // The launch screen covers the app until data and location are ready.
  unawaited(store.start());
  runApp(
    ProviderScope(
      overrides: [storeProvider.overrideWith((ref) => store)],
      child: const ParkingApp(),
    ),
  );
}

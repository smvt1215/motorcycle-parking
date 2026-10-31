import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';
import 'core/app_check.dart';
import 'core/config.dart';
import 'data/app_store.dart';
import 'data/repositories.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  AppConfig.validate();
  // Off without the Firebase dart-defines; never delays or blocks launch.
  unawaited(AppCheck.start());
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

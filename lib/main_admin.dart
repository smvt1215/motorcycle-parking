import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'admin/admin_app.dart';
import 'admin/admin_controller.dart';
import 'admin/admin_gateway.dart';
import 'core/config.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Keep the admin font out of mobile assets. Flutter serves web/ files as-is.
  try {
    final font = FontLoader('Noto Sans TC')
      ..addFont(
        http
            .readBytes(Uri.base.resolve('/admin/fonts/NotoSansTC.ttf'))
            .then(ByteData.sublistView),
      );
    await font.load().timeout(const Duration(seconds: 10));
  } catch (_) {
    // A temporary font download failure must not block login or sign-out.
  }
  AdminGateway? gateway;
  String? configurationError;
  try {
    AppConfig.validate();
    // Missing configuration never enables demo management access.
    if (!AppConfig.demo) {
      await Supabase.initialize(
        url: AppConfig.supabaseUrl,
        publishableKey: AppConfig.supabaseKey,
      );
      gateway = SupabaseAdminGateway(Supabase.instance.client);
    }
  } catch (_) {
    configurationError = '登入服務目前無法連線，請重新整理；若仍無法登入，請聯絡專案擁有者。';
  }
  final controller = AdminController(
    gateway,
    configurationError: configurationError,
  );
  unawaited(controller.refresh());
  runApp(AdminApp(controller: controller));
}

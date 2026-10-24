import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show appFlavor;
import 'package:package_info_plus/package_info_plus.dart';

/// The installed build, shown so tester feedback names the exact binary.
class AppVersion {
  const AppVersion(this.version, this.build, {this.channel});
  final String version, build;

  /// Distribution channel when the build itself tells it apart.
  final String? channel;

  static Future<AppVersion>? _current;

  /// Read once per launch; the installed build cannot change while running.
  static Future<AppVersion> get current => _current ??= load();

  @visibleForTesting
  static void reset() => _current = null;

  static Future<AppVersion> load() async {
    final info = await PackageInfo.fromPlatform();
    return AppVersion(
      info.version,
      info.buildNumber,
      channel: channelOf(
        flavor: appFlavor,
        build: info.buildNumber,
        debug: !kReleaseMode,
      ),
    );
  }

  /// Staging builds are the internal alpha. Production build numbers end in
  /// 1–4 for a beta and 5–9 for an RC, which the store release ships
  /// unchanged, so those carry no tag (see tool/cd_gate.py).
  static String? channelOf({
    required String? flavor,
    required String build,
    bool debug = false,
  }) {
    if (debug) return 'Debug';
    if (flavor == 'staging') return 'Alpha';
    final digit = (int.tryParse(build) ?? 0) % 10;
    return digit >= 1 && digit <= 4 ? 'Beta' : null;
  }

  /// e.g. `v0.2.0 · Build 1234 · Beta`.
  String get label => ['v$version', 'Build $build', ?channel].join(' · ');
}

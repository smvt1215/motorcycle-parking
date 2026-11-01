import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../api/v1/api_v1.g.dart';

/// `major.minor.patch`, each part compared as a number: 1.10.0 > 1.9.0.
/// Null for anything else, which never blocks.
List<int>? parseAppVersion(String value) {
  final match = RegExp(r'^(\d+)\.(\d+)\.(\d+)$').firstMatch(value.trim());
  if (match == null) return null;
  return [for (var i = 1; i <= 3; i++) int.parse(match.group(i)!)];
}

/// Whether [installed] is older than [minimum]; false whenever either is
/// not `x.y.z` (寧可不擋).
bool isBelowMinimum(String installed, String minimum) {
  final have = parseAppVersion(installed), need = parseAppVersion(minimum);
  if (have == null || need == null) return false;
  for (var i = 0; i < 3; i++) {
    if (have[i] != need[i]) return have[i] < need[i];
  }
  return false;
}

/// Where an update comes from, by how the build was made.
enum UpdateChannel {
  /// App Store or Google Play. The RC binary is the one the store ships, so
  /// an `rc` build is a store build too (see [updateChannelOf]).
  store,

  /// A beta through TestFlight or Play testing.
  beta,

  /// The staging flavor through Firebase App Distribution.
  staging,
}

/// [appChannel] is the `APP_CHANNEL` dart-define, the release workflow's
/// RELEASE_CHANNEL (beta, rc, release) or `staging`; the staging flavor is
/// staging whatever it says.
UpdateChannel updateChannelOf(String appChannel, {String? flavor}) {
  if (flavor == 'staging' || appChannel == 'staging') {
    return UpdateChannel.staging;
  }
  // The RC's build is promoted to the stores unchanged (docs/CICD.md), so it
  // must read as a store build; only a beta never reaches a store.
  return appChannel == 'beta' ? UpdateChannel.beta : UpdateChannel.store;
}

/// Firebase App Distribution for testers: the App Tester app on Android,
/// the web clip on iOS (firebase.google.com/docs/app-distribution).
final appTesterUrl = Uri.parse('https://appdistribution.firebase.google.com');

/// Where the update button goes; null when this build has no link, so the
/// screen tells the way in words instead.
Uri? updateLink({
  required UpdateChannel channel,
  required bool ios,
  required String packageName,
  String appStoreId = '',
  String testflightUrl = '',
}) {
  switch (channel) {
    case UpdateChannel.staging:
      return appTesterUrl;
    case UpdateChannel.beta when ios:
      final url = Uri.tryParse(testflightUrl.trim());
      return url != null && url.scheme == 'https' && url.host.isNotEmpty
          ? url
          : null;
    case UpdateChannel.store when ios:
      final id = appStoreId.trim();
      return RegExp(r'^\d+$').hasMatch(id)
          ? Uri.parse('https://apps.apple.com/app/id$id')
          : null;
    // Testers on Play testing get the test build from the same store page.
    case UpdateChannel.store || UpdateChannel.beta:
      if (packageName.isEmpty) return null;
      return Uri.https('play.google.com', '/store/apps/details', {
        'id': packageName,
      });
  }
}

/// The installed build, as the update check needs it.
typedef InstalledApp = ({String version, String packageName});

/// Why the app is blocked: [installed] is below [minimum].
@immutable
class UpdateRequirement {
  const UpdateRequirement({
    required this.installed,
    required this.minimum,
    required this.packageName,
  });
  final String installed, minimum, packageName;

  @override
  bool operator ==(Object other) =>
      other is UpdateRequirement &&
      other.installed == installed &&
      other.minimum == minimum &&
      other.packageName == packageName;

  @override
  int get hashCode => Object.hash(installed, minimum, packageName);
}

/// Compares the installed version with the backend's minimum
/// (`client_config.min_supported_app_version`) at launch and on every
/// return to the foreground. Any failure lets the app in (寧可不擋).
class UpdateGate extends ChangeNotifier {
  UpdateGate({required this.minimum, required this.installed});

  /// Nothing to check against: the example build, or no backend.
  UpdateGate.off() : minimum = null, installed = _noInstalled;

  /// Reads the minimum through api_v1; null [client] is the example build.
  factory UpdateGate.forClient(SupabaseClient? client) => client == null
      ? UpdateGate.off()
      : UpdateGate(
          minimum: () async =>
              (await ApiV1Client(client).clientConfig()).minSupportedAppVersion,
          installed: installedFromPlatform,
        );

  /// The backend's minimum version; may throw.
  final Future<String> Function()? minimum;

  /// The installed build; may throw.
  final Future<InstalledApp> Function() installed;

  static Future<InstalledApp> _noInstalled() async =>
      (version: '', packageName: '');

  static Future<InstalledApp> installedFromPlatform() async {
    final info = await PackageInfo.fromPlatform();
    return (version: info.version, packageName: info.packageName);
  }

  /// Non-null while the app must be updated before use.
  UpdateRequirement? get required => _required;
  UpdateRequirement? _required;

  int _check = 0;

  /// Never throws. A failed check keeps what the last answer said: nothing
  /// new is known, and the installed build cannot change while running.
  Future<void> check() async {
    final minimum = this.minimum;
    if (minimum == null) return;
    final number = ++_check;
    UpdateRequirement? next;
    try {
      final need = await minimum();
      final have = await installed();
      next = isBelowMinimum(have.version, need)
          ? UpdateRequirement(
              installed: have.version,
              minimum: need,
              packageName: have.packageName,
            )
          : null;
    } catch (_) {
      // Offline, an error from the backend, or an older backend without the
      // field, whose cast fails with a TypeError (an Error, not an
      // Exception): all of them let the app in.
      return;
    }
    // Only the newest check started may land.
    if (number != _check || next == _required) return;
    _required = next;
    notifyListeners();
  }
}

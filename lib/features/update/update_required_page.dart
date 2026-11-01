import 'package:cupertino_native_better/cupertino_native_better.dart';
import 'package:cupertino_ui/cupertino_ui.dart' as cu;
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/config.dart';
import '../../core/update_gate.dart';
import '../../domain/update_display.dart';
import '../../ui/adaptive/adaptive.dart';

/// Opens [uri] outside the app; false when nothing could.
typedef UriLauncher = Future<bool> Function(Uri uri);

Future<bool> openExternally(Uri uri) async {
  try {
    return await launchUrl(uri, mode: LaunchMode.externalApplication);
  } on PlatformException {
    return false;
  }
}

/// 需要更新 (P14): the only screen while the installed version is below the
/// backend's minimum. It has no way back or out; the system back button and
/// gesture stay on it. Its route is the app's only one while it shows.
class UpdateRequiredPage extends StatelessWidget {
  const UpdateRequiredPage({
    super.key,
    required this.requirement,
    this.channel,
    this.appStoreId = AppConfig.appStoreId,
    this.testflightUrl = AppConfig.testflightPublicUrl,
    this.launch = openExternally,
  });
  final UpdateRequirement requirement;

  /// This build's channel; from APP_CHANNEL and the flavor by default.
  final UpdateChannel? channel;
  final String appStoreId, testflightUrl;
  final UriLauncher launch;

  static const _ink = Color(0xff16313a), _quiet = Color(0xff59646c);

  /// 24 on a phone; centres a 480-wide column on a tablet.
  static double side(double width) => width > 528 ? (width - 480) / 2 : 24;

  @override
  Widget build(BuildContext context) {
    final ios = isCupertino;
    final channel =
        this.channel ??
        updateChannelOf(AppConfig.appChannel, flavor: appFlavor);
    final link = updateLink(
      channel: channel,
      ios: ios,
      packageName: requirement.packageName,
      appStoreId: appStoreId,
      testflightUrl: testflightUrl,
    );
    final offer = updateOffer(channel, ios: ios, hasLink: link != null);
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    // Light mode is the board's; dark mode follows the theme.
    final background = dark
        ? scheme.surface
        : (ios ? Colors.white : const Color(0xfff4f8f9));
    final ink = dark ? scheme.onSurface : _ink;
    final body = dark
        ? scheme.onSurfaceVariant
        : (ios ? const Color(0xff3c4a52) : const Color(0xff3e4a50));
    final quiet = dark ? scheme.onSurfaceVariant : _quiet;

    return PopScope(
      canPop: false,
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
        child: Material(
          key: const ValueKey('update-required'),
          color: background,
          child: SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) => SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: Padding(
                    // Phone width on a tablet, as on the board.
                    padding: EdgeInsets.fromLTRB(
                      side(constraints.maxWidth),
                      24,
                      side(constraints.maxWidth),
                      ios ? 16 : 32,
                    ),
                    child: IntrinsicHeight(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Spacer(),
                          _Message(
                            ios: ios,
                            ink: ink,
                            body: body,
                            quiet: quiet,
                            requirement: requirement,
                          ),
                          const Spacer(flex: 2),
                          const SizedBox(height: 32),
                          if (offer.button case final label?)
                            _UpdateButton(
                              ios: ios,
                              label: label,
                              onPressed: () => launch(link!),
                            )
                          else if (offer.fallback case final text?)
                            Text(
                              text,
                              key: const ValueKey('update-fallback'),
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: ios ? 17 : 16,
                                fontWeight: FontWeight.w600,
                                color: ink,
                              ),
                            ),
                          if (offer.note case final note?) ...[
                            const SizedBox(height: 10),
                            Text(
                              note,
                              textAlign: TextAlign.center,
                              style: TextStyle(fontSize: 12, color: quiet),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({
    required this.ios,
    required this.ink,
    required this.body,
    required this.quiet,
    required this.requirement,
  });
  final bool ios;
  final Color ink, body, quiet;
  final UpdateRequirement requirement;

  static const _mark =
      '<svg viewBox="0 0 24 24"><path d="M12 3.5v10.2" fill="none" '
      'stroke="#FFFFFF" stroke-width="2.2" stroke-linecap="round"/>'
      '<path d="M7.6 9.6 12 14l4.4-4.4" fill="none" stroke="#FFFFFF" '
      'stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/>'
      '<path d="M4.5 14.5v3.2a2.3 2.3 0 0 0 2.3 2.3h10.4a2.3 2.3 0 0 0 '
      '2.3-2.3v-3.2" fill="none" stroke="#FFFFFF" stroke-width="2.2" '
      'stroke-linecap="round"/></svg>';

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Container(
        width: 72,
        height: 72,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: brand,
          borderRadius: BorderRadius.circular(ios ? 18 : 24),
        ),
        child: SvgPicture.string(_mark, width: 40, height: 40),
      ),
      const SizedBox(height: 24),
      Semantics(
        header: true,
        child: Text(
          updateTitle,
          style: TextStyle(
            fontSize: ios ? 34 : 32,
            height: ios ? 41 / 34 : 40 / 32,
            fontWeight: ios ? FontWeight.w700 : FontWeight.w500,
            letterSpacing: ios ? .4 : 0,
            color: ink,
          ),
        ),
      ),
      const SizedBox(height: 16),
      Text(
        updateBody,
        style: TextStyle(fontSize: ios ? 17 : 16, height: 1.5, color: body),
      ),
      const SizedBox(height: 16),
      Text(
        updateVersions(requirement.installed, requirement.minimum),
        key: const ValueKey('update-versions'),
        style: TextStyle(
          fontFamily: 'Outfit',
          fontSize: ios ? 13 : 12,
          color: quiet,
        ),
      ),
    ],
  );
}

/// The board's full-width pill in the brand color: 50 high on iOS, 56 on
/// Android.
class _UpdateButton extends StatelessWidget {
  const _UpdateButton({
    required this.ios,
    required this.label,
    required this.onPressed,
  });
  final bool ios;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    const key = ValueKey('update-button');
    if (nativeGlass) {
      return SizedBox(
        key: key,
        height: 50,
        child: CNButton(
          label: label,
          onPressed: onPressed,
          tint: brand,
          config: const CNButtonConfig(
            style: CNButtonStyle.prominentGlass,
            minHeight: 50,
          ),
        ),
      );
    }
    if (ios) {
      return SizedBox(
        key: key,
        height: 50,
        child: cu.CupertinoButton.filled(
          color: brand,
          borderRadius: BorderRadius.circular(25),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          onPressed: onPressed,
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
        ),
      );
    }
    return SizedBox(
      key: key,
      height: 56,
      child: M3EButton(
        onPressed: onPressed,
        size: M3EButtonSize.md,
        decoration: const M3EButtonDecoration(
          backgroundColor: WidgetStatePropertyAll(brand),
          foregroundColor: WidgetStatePropertyAll(Colors.white),
        ),
        child: Text(
          label,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w500,
            letterSpacing: .1,
          ),
        ),
      ),
    );
  }
}

import '../../ui/adaptive/adaptive.dart';

/// Sign-in buttons drawn to each provider's own brand rules, the same on
/// iOS and Android (P11, P15a ④⑤, P16a; #219):
/// - Google: Sign in with Google branding guidelines — white fill, 1px
///   #747775 stroke, #1F1F1F label and the four-colour G (dark theme:
///   #131314 fill, #8E918F stroke, #E3E3E3 label), pill shape.
/// - Apple: HIG "Creating a custom Sign in with Apple button" — black fill
///   with white logo and title (dark theme: white with black), the logo file
///   from Apple Design Resources at the button's height, title at 43% of the
///   button's height, at least 8% of the width after the title.

/// Minimum heights: the platform touch target (iOS 44pt, Android 48dp),
/// equal for both providers so Apple is never smaller than Google (HIG).
double brandButtonHeight() => isCupertino ? 44 : 48;

/// Google's fill, stroke and label colours for the light and dark themes.
@visibleForTesting
({Color fill, Color stroke, Color label}) googleColors({required bool dark}) =>
    dark
    ? (
        fill: const Color(0xff131314),
        stroke: const Color(0xff8e918f),
        label: const Color(0xffe3e3e3),
      )
    : (
        fill: const Color(0xffffffff),
        stroke: const Color(0xff747775),
        label: const Color(0xff1f1f1f),
      );

/// Apple's fill and logo/title colour: black on light, white on dark.
@visibleForTesting
({Color fill, Color label}) appleColors({required bool dark}) => dark
    ? (fill: const Color(0xffffffff), label: const Color(0xff000000))
    : (fill: const Color(0xff000000), label: const Color(0xffffffff));

class BrandSignInButton extends StatelessWidget {
  const BrandSignInButton({
    super.key,
    required this.apple,
    required this.label,
    required this.onPressed,
  });
  final bool apple;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final height = brandButtonHeight();
    final Color fill, foreground;
    final BorderSide side;
    if (apple) {
      final c = appleColors(dark: dark);
      (fill, foreground, side) = (c.fill, c.label, BorderSide.none);
    } else {
      final c = googleColors(dark: dark);
      (fill, foreground) = (c.fill, c.label);
      side = BorderSide(color: c.stroke);
    }
    final content = apple
        ? _AppleContent(label: label, color: foreground, height: height)
        : _GoogleContent(label: label, color: foreground);
    final button = Material(
      key: const ValueKey('brand-sign-in-surface'),
      color: fill,
      shape: StadiumBorder(side: side),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        splashFactory: isCupertino ? NoSplash.splashFactory : null,
        highlightColor: foreground.withValues(alpha: .12),
        splashColor: foreground.withValues(alpha: .12),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: height),
          child: Center(child: content),
        ),
      ),
    );
    return Semantics(
      button: true,
      enabled: onPressed != null,
      child: onPressed == null ? Opacity(opacity: .38, child: button) : button,
    );
  }
}

/// Google's padding: Android 12 before the G, 10 after, 12 after the text;
/// iOS 16, 12 and 16. The group is centred in a full-width button (P11).
class _GoogleContent extends StatelessWidget {
  const _GoogleContent({required this.label, required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final ios = isCupertino;
    final edge = ios ? 16.0 : 12.0;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: edge, vertical: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const GoogleLogo(size: 20),
          SizedBox(width: ios ? 12 : 10),
          Flexible(
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: color,
                fontSize: ios ? 17 : 15,
                fontWeight: FontWeight.w500,
                height: 20 / 15,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The Apple logo file sits at the button's height (its built-in padding
/// keeps the logo, title and button in proportion) and the title is 43% of
/// that height. Larger text grows the button in the same proportion; when
/// the title wraps, the logo stays centred at the single-line height.
class _AppleContent extends StatelessWidget {
  const _AppleContent({
    required this.label,
    required this.color,
    required this.height,
  });
  final String label;
  final Color color;
  final double height;

  @override
  Widget build(BuildContext context) {
    final fontSize = height * .43;
    final scaled = MediaQuery.textScalerOf(context).scale(fontSize);
    final logoHeight = scaled / .43 > height ? scaled / .43 : height;
    // 8% of the width on each side keeps the title at least that far from
    // the trailing edge; the logo and title are centred in between.
    return Row(
      children: [
        const Spacer(flex: 8),
        Flexible(
          flex: 84,
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AppleLogo(height: logoHeight, color: color),
                Flexible(
                  child: Text(
                    label,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: color,
                      fontSize: fontSize,
                      fontWeight: isCupertino
                          ? FontWeight.w600
                          : FontWeight.w500,
                      height: 1.2,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const Spacer(flex: 8),
      ],
    );
  }
}

/// The four-colour Google G, from the approved P11 board
/// (assets/brand/google/g-logo.svg, 48×48 view box).
class GoogleLogo extends StatelessWidget {
  const GoogleLogo({super.key, required this.size});
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: const CustomPaint(painter: _SvgPainter(googleLogoPaths, 48, 48)),
  );
}

/// Apple's "Logo - SIWA - Left-aligned - Medium" file: a 31×44 frame with
/// the logo and its built-in padding, drawn at [height] (HIG: match the
/// logo file's height to the button's; never crop or re-pad it).
class AppleLogo extends StatelessWidget {
  const AppleLogo({super.key, required this.height, required this.color});
  final double height;
  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: height * appleLogoWidth / appleLogoHeight,
    height: height,
    child: CustomPaint(
      painter: _SvgPainter(
        [(color, appleLogoPath)],
        appleLogoWidth,
        appleLogoHeight,
      ),
    ),
  );
}

/// Google G paths from assets/brand/google/g-logo.svg (P11).
const googleLogoPaths = <(Color, String)>[
  (
    Color(0xffea4335),
    'M24 9.5c3.5 0 6.6 1.2 9 3.5l6.7-6.7C35.6 2.4 30.2 0 24 0 14.6 0 6.6 5.4 '
        '2.6 13.2l7.8 6.1C12.3 13.6 17.7 9.5 24 9.5z',
  ),
  (
    Color(0xff4285f4),
    'M46.5 24.5c0-1.6-.1-3.1-.4-4.5H24v9h12.7c-.6 3-2.3 5.5-4.8 7.2l7.6 '
        '5.9c4.4-4.1 7-10.1 7-17.6z',
  ),
  (
    Color(0xfffbbc05),
    'M10.4 28.7c-.5-1.4-.8-3-.8-4.7s.3-3.3.8-4.7l-7.8-6.1C.9 16.5 0 20.1 0 '
        '24s.9 7.5 2.6 10.8l7.8-6.1z',
  ),
  (
    Color(0xff34a853),
    'M24 48c6.5 0 11.9-2.1 15.9-5.8l-7.6-5.9c-2.1 1.4-4.9 2.3-8.3 2.3-6.3 '
        '0-11.7-4.1-13.6-9.8l-7.8 6.1C6.6 42.6 14.6 48 24 48z',
  ),
];

/// The Apple logo frame and path, copied unchanged from Apple Design
/// Resources "Sign in with Apple Logo" (Logo-Sign-in-with-Apple.dmg,
/// "Logo - SIWA - Left-aligned - White/Black - Medium.svg"); the files are
/// kept in assets/brand/apple/ and a test checks this copy matches them.
const appleLogoWidth = 31.0;
const appleLogoHeight = 44.0;
const appleLogoPath =
    'M15.7099491,14.8846154 C16.5675461,14.8846154 17.642562,14.3048315 '
    '18.28274,13.5317864 C18.8625238,12.8312142 19.2852829,11.852829 '
    '19.2852829,10.8744437 C19.2852829,10.7415766 19.2732041,10.6087095 '
    '19.2490464,10.5 C18.2948188,10.5362365 17.1473299,11.140178 '
    '16.4588366,11.9494596 C15.9152893,12.56548 15.4200572,13.5317864 '
    '15.4200572,14.5222505 C15.4200572,14.6671964 15.4442149,14.8121424 '
    '15.4562937,14.8604577 C15.5166879,14.8725366 15.6133185,14.8846154 '
    '15.7099491,14.8846154 Z M12.6902416,29.5 C13.8618881,29.5 '
    '14.3812778,28.714876 15.8428163,28.714876 C17.3285124,28.714876 '
    '17.6546408,29.4758423 18.9591545,29.4758423 C20.2395105,29.4758423 '
    '21.0971074,28.292117 21.9063891,27.1325493 C22.8123013,25.8038779 '
    '23.1867451,24.4993643 23.2109027,24.4389701 C23.1263509,24.4148125 '
    '20.6743484,23.4122695 20.6743484,20.5979021 C20.6743484,18.1579784 '
    '22.6069612,17.0588048 22.7156707,16.974253 C21.4353147,15.1382708 '
    '19.490623,15.0899555 18.9591545,15.0899555 C17.5217737,15.0899555 '
    '16.3501271,15.9596313 15.6133185,15.9596313 C14.8161157,15.9596313 '
    '13.7652575,15.1382708 12.521138,15.1382708 C10.1536872,15.1382708 '
    '7.75,17.0950413 7.75,20.7911634 C7.75,23.0861411 8.64383344,25.513986 '
    '9.74300699,27.0842339 C10.6851558,28.4129053 11.5065162,29.5 '
    '12.6902416,29.5 Z';

class _SvgPainter extends CustomPainter {
  const _SvgPainter(this.paths, this.viewWidth, this.viewHeight);
  final List<(Color, String)> paths;
  final double viewWidth, viewHeight;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / viewWidth, size.height / viewHeight);
    for (final (color, d) in paths) {
      canvas.drawPath(
        parseSvgPath(d),
        Paint()
          ..color = color
          ..isAntiAlias = true,
      );
    }
  }

  @override
  bool shouldRepaint(_SvgPainter old) =>
      old.paths != paths ||
      old.viewWidth != viewWidth ||
      old.viewHeight != viewHeight;
}

final _svgToken = RegExp(
  r'[MmLlHhVvCcSsZz]|[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?',
);

/// Parses SVG path data with the commands the brand files use
/// (M L H V C S Z, absolute and relative) into a [Path].
@visibleForTesting
Path parseSvgPath(String d) {
  final tokens = [for (final m in _svgToken.allMatches(d)) m[0]!];
  final path = Path();
  var i = 0;
  var command = '';
  var x = 0.0, y = 0.0, startX = 0.0, startY = 0.0;
  double? lastCx, lastCy;
  bool isCommand(String t) => RegExp(r'^[A-Za-z]$').hasMatch(t);
  double next() => double.parse(tokens[i++]);
  while (i < tokens.length) {
    if (isCommand(tokens[i])) command = tokens[i++];
    final rel = command == command.toLowerCase();
    final dx = rel ? x : 0.0, dy = rel ? y : 0.0;
    switch (command.toUpperCase()) {
      case 'M':
        x = dx + next();
        y = dy + next();
        path.moveTo(x, y);
        (startX, startY) = (x, y);
        // Further pairs after a moveto are implicit linetos.
        command = rel ? 'l' : 'L';
        lastCx = lastCy = null;
      case 'L':
        x = dx + next();
        y = dy + next();
        path.lineTo(x, y);
        lastCx = lastCy = null;
      case 'H':
        x = dx + next();
        path.lineTo(x, y);
        lastCx = lastCy = null;
      case 'V':
        y = (rel ? y : 0.0) + next();
        path.lineTo(x, y);
        lastCx = lastCy = null;
      case 'C':
        final x1 = dx + next(), y1 = dy + next();
        final x2 = dx + next(), y2 = dy + next();
        x = dx + next();
        y = dy + next();
        path.cubicTo(x1, y1, x2, y2, x, y);
        (lastCx, lastCy) = (x2, y2);
      case 'S':
        final x1 = lastCx == null ? x : 2 * x - lastCx;
        final y1 = lastCy == null ? y : 2 * y - lastCy;
        final x2 = dx + next(), y2 = dy + next();
        x = dx + next();
        y = dy + next();
        path.cubicTo(x1, y1, x2, y2, x, y);
        (lastCx, lastCy) = (x2, y2);
      case 'Z':
        path.close();
        (x, y) = (startX, startY);
        lastCx = lastCy = null;
      default:
        throw FormatException('Unsupported SVG path command', command);
    }
  }
  return path;
}

import 'package:material_ui/material_ui.dart';

/// The full-page details' fixed colours (canvas v154 A2 light, A4 dark):
/// the verdict card, the rule icons, the fee card and the place tiles read
/// the same on every device, never from the dynamic scheme (A4,
/// DynamicColorBuilder on Android). Dark values keep text at 4.5:1 or more
/// on #121B1E.
@immutable
class DetailColors {
  const DetailColors._({
    required this.ink,
    required this.muted,
    required this.divider,
    required this.border,
    required this.chip,
    required this.link,
    required this.allowed,
    required this.allowedTint,
    required this.conditional,
    required this.conditionalTint,
    required this.denied,
    required this.deniedTint,
    required this.unverified,
    required this.unverifiedTint,
  });

  static const light = DetailColors._(
    ink: Color(0xff16313a),
    muted: Color(0xff59646c),
    divider: Color(0xffe3eaed),
    border: Color(0xffc9d3d6),
    chip: Color(0xffeef2f3),
    link: Color(0xff176273),
    allowed: Color(0xff186348),
    allowedTint: Color(0xffe7f1ec),
    conditional: Color(0xff865500),
    conditionalTint: Color(0xfffbf3e4),
    denied: Color(0xffa13042),
    deniedTint: Color(0xfff9e8eb),
    unverified: Color(0xff59646c),
    unverifiedTint: Color(0xffeef2f3),
  );

  static const dark = DetailColors._(
    ink: Color(0xffe6eef0),
    muted: Color(0xffa3b4ba),
    divider: Color(0xff2a3a40),
    border: Color(0xff4a5d64),
    chip: Color(0xff22323a),
    link: Color(0xff7fd3e3),
    allowed: Color(0xff7bd8ae),
    allowedTint: Color(0xff17352a),
    conditional: Color(0xffe3a64a),
    conditionalTint: Color(0xff352914),
    denied: Color(0xffff9aa8),
    deniedTint: Color(0xff3b1f25),
    unverified: Color(0xffa3b4ba),
    unverifiedTint: Color(0xff22323a),
  );

  static DetailColors of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? dark : light;

  final Color ink, muted, divider, border, chip, link;
  final Color allowed, allowedTint, conditional, conditionalTint;
  final Color denied, deniedTint, unverified, unverifiedTint;

  /// The fee card is a white notice board in both themes (A4).
  static const paper = Color(0xffffffff);
  static const paperInk = Color(0xff16313a);
  static const paperMuted = Color(0xff59646c);
  static const paperDivider = Color(0xffe3eaed);
  static const paperRow = Color(0xfff3f5f6);
  static const paperDenied = Color(0xffa13042);

  /// A place's bay tile: the road's asphalt in both themes.
  static const asphalt = Color(0xff3d4247);
  static const asphaltInk = Color(0xfff2f2ee);
}

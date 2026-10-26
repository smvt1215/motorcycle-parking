import 'package:material_ui/material_ui.dart';

import '../ui/fee_board.dart';

abstract final class AdminColors {
  static const road = Color(0xffeceeef);
  static const white = Color(0xffffffff);
  static const asphalt = Color(0xff2a2e33);
  static const blue = Color(0xff1f5fa8);
  static const yellow = Color(0xffe3ae00);
  static const red = Color(0xffc3362e);
}

ThemeData adminTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme =
      ColorScheme.fromSeed(
        seedColor: AdminColors.blue,
        brightness: brightness,
      ).copyWith(
        primary: dark ? const Color(0xff8db8ec) : AdminColors.blue,
        onPrimary: dark ? const Color(0xff102d50) : AdminColors.white,
        surface: dark ? const Color(0xff262b30) : AdminColors.white,
        onSurface: dark ? const Color(0xffe8eaec) : AdminColors.asphalt,
        onSurfaceVariant: dark
            ? const Color(0xffa9b0b8)
            : const Color(0xff565c64),
        outlineVariant: dark
            ? const Color(0xff3a4148)
            : const Color(0xffd5d9dd),
        error: dark ? const Color(0xffee7d74) : AdminColors.red,
      );
  final base = ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    fontFamily: 'Noto Sans TC',
    scaffoldBackgroundColor: dark ? const Color(0xff1c2024) : AdminColors.road,
    visualDensity: VisualDensity.standard,
    materialTapTargetSize: MaterialTapTargetSize.padded,
  );
  final buttons = ButtonStyle(
    minimumSize: const WidgetStatePropertyAll(Size(44, 48)),
    padding: const WidgetStatePropertyAll(
      EdgeInsets.symmetric(horizontal: 20, vertical: 12),
    ),
    shape: WidgetStatePropertyAll(
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ),
    side: WidgetStateProperty.resolveWith(
      (states) => states.contains(WidgetState.focused)
          ? const BorderSide(color: AdminColors.yellow, width: 3)
          : null,
    ),
  );
  return base.copyWith(
    // The fee board in ADMIN_WEB.md colours: asphalt on white, sign blue.
    extensions: const [
      FeeBoardTheme(
        ink: AdminColors.asphalt,
        muted: Color(0xff555b61),
        accent: AdminColors.blue,
      ),
    ],
    textTheme: base.textTheme.apply().copyWith(
      headlineMedium: base.textTheme.headlineMedium?.copyWith(
        fontWeight: FontWeight.w700,
        height: 1.4,
        letterSpacing: .3,
      ),
      titleLarge: base.textTheme.titleLarge?.copyWith(
        fontWeight: FontWeight.w700,
      ),
      bodyLarge: base.textTheme.bodyLarge?.copyWith(height: 1.7),
      bodyMedium: base.textTheme.bodyMedium?.copyWith(
        height: 1.7,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(style: buttons),
    outlinedButtonTheme: OutlinedButtonThemeData(style: buttons),
    textButtonTheme: TextButtonThemeData(style: buttons),
    iconButtonTheme: IconButtonThemeData(style: buttons),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: AdminColors.blue, width: 2),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
    ),
  );
}

class AdminBrand extends StatelessWidget {
  const AdminBrand({super.key});

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Semantics(
        label: '停車指南',
        image: true,
        child: Container(
          width: 34,
          height: 34,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: AdminColors.blue,
            borderRadius: BorderRadius.circular(6),
          ),
          child: const ExcludeSemantics(
            child: Text(
              'P',
              style: TextStyle(
                color: AdminColors.white,
                fontSize: 25,
                fontWeight: FontWeight.w700,
                height: 1,
              ),
            ),
          ),
        ),
      ),
      const SizedBox(width: 10),
      const Flexible(
        child: Text(
          '停車指南管理',
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w700,
            letterSpacing: .3,
          ),
        ),
      ),
    ],
  );
}

class AdminNotice extends StatelessWidget {
  const AdminNotice(this.message, {super.key, this.error = false});
  final String message;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      liveRegion: true,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: (error ? colors.error : colors.primary).withValues(alpha: .07),
          border: Border(
            left: BorderSide(
              color: error ? colors.error : AdminColors.yellow,
              width: 4,
            ),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              error ? Icons.error_outline : Icons.info_outline,
              size: 20,
              color: error ? colors.error : colors.primary,
            ),
            const SizedBox(width: 10),
            Expanded(child: Text(message)),
          ],
        ),
      ),
    );
  }
}

class AdminPanel extends StatelessWidget {
  const AdminPanel({super.key, required this.child, this.width = 560});
  final Widget child;
  final double width;

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: width),
      child: Container(
        width: double.infinity,
        padding: EdgeInsets.all(
          MediaQuery.sizeOf(context).width < 480 ? 24 : 36,
        ),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
          borderRadius: BorderRadius.circular(12),
        ),
        child: child,
      ),
    ),
  );
}

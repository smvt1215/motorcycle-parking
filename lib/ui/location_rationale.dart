import 'package:cupertino_ui/cupertino_ui.dart' as cu;
import 'package:material_3_expressive/material_3_expressive.dart';

import 'adaptive/adaptive.dart';

/// Why the App asks for location, shown before the system asks for the
/// first time (#458, 畫板 P20a／P20c／P20t, 做法 C). Android offers 先不要
/// beside 繼續, the same size; iOS only 繼續 (HIG: the screen before a
/// permission request has one button and never skips the system's).
class LocationRationaleCard extends StatelessWidget {
  const LocationRationaleCard({
    super.key,
    required this.onContinue,
    this.onDecline,
  });

  final VoidCallback onContinue;

  /// 先不要; null hides it (iOS).
  final VoidCallback? onDecline;

  static const title = '用你的位置找附近的停車點';
  static const intro = '接下來系統會問你，要不要讓「機車停車指南」使用位置。位置會用在這三件事：';
  static const uses = [
    (Icons.near_me_outlined, '地圖定位與附近排序', '顯示你在哪裡，並依距離排列停車點。只在手機上計算，不會上傳。'),
    (Icons.local_parking, '記錄停車位置', '記下你把車停在哪裡，只存在這支手機。'),
    (
      Icons.add_location_alt_outlined,
      '回報停車點時按「移到我的位置」',
      '標記會移到你當下的位置。查縣市與門牌時，這個座標會傳出去（第一次會先問你）；你送出回報後，它就是地圖上公開的停車點位置。',
    ),
  ];
  static const footnote = 'App 只在你使用時讀取位置，不會在背景追蹤。不允許也能用：自己移動地圖找停車點。';

  /// The card's widest, on a tablet (P20t).
  static const maxWidth = 640.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final text = theme.textTheme;
    final quiet = colors.onSurfaceVariant;
    return Semantics(
      key: const ValueKey('location-rationale'),
      container: true,
      explicitChildNodes: true,
      child: Material(
        color: colors.surfaceContainerLow,
        clipBehavior: Clip.antiAlias,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: SafeArea(
          top: false,
          minimum: const EdgeInsets.only(bottom: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Drawn as on the boards; the card cannot be dragged away.
              ExcludeSemantics(
                child: Center(
                  child: Container(
                    width: 32,
                    height: 4,
                    margin: const EdgeInsets.only(top: 12, bottom: 8),
                    decoration: BoxDecoration(
                      color: quiet.withValues(alpha: .4),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
              // Large text: the uses scroll, the buttons stay in view.
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Semantics(
                        header: true,
                        child: Text(
                          title,
                          style: text.titleLarge?.copyWith(
                            color: colors.onSurface,
                            fontWeight: isCupertino
                                ? FontWeight.w700
                                : FontWeight.w400,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        intro,
                        style: text.bodyMedium?.copyWith(color: quiet),
                      ),
                      for (final (icon, label, detail) in uses) ...[
                        const SizedBox(height: 12),
                        _Use(icon: icon, label: label, detail: detail),
                      ],
                      const SizedBox(height: 16),
                      Text(
                        footnote,
                        style: text.bodySmall?.copyWith(color: quiet),
                      ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: _Buttons(onContinue: onContinue, onDecline: onDecline),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Use extends StatelessWidget {
  const _Use({required this.icon, required this.label, required this.detail});
  final IconData icon;
  final String label, detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final body = theme.textTheme.bodyMedium;
    return MergeSemantics(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            // Grows with the text it leads.
            child: Icon(
              icon,
              size: MediaQuery.textScalerOf(context).scale(20),
              color: colors.primary,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: label,
                    style: TextStyle(
                      color: colors.onSurface,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  // Read as two phrases, shown with a gap as on the boards.
                  const TextSpan(text: '　'),
                  TextSpan(text: detail),
                ],
              ),
              style: body?.copyWith(color: colors.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

/// iOS: one 繼續 across the card. Android: 先不要 and 繼續 the same size,
/// side by side, stacked once large text would squeeze them (P20c ③).
class _Buttons extends StatelessWidget {
  const _Buttons({required this.onContinue, required this.onDecline});
  final VoidCallback onContinue;
  final VoidCallback? onDecline;

  @override
  Widget build(BuildContext context) {
    final decline = onDecline;
    if (isCupertino || decline == null) {
      return _button(context, '繼續', onContinue, primary: true);
    }
    final stacked = MediaQuery.textScalerOf(context).scale(14) > 14 * 1.2;
    final no = _button(context, '先不要', decline, primary: false);
    final yes = _button(context, '繼續', onContinue, primary: true);
    return stacked
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [no, const SizedBox(height: 8), yes],
          )
        : Row(
            children: [
              Expanded(child: no),
              const SizedBox(width: 8),
              Expanded(child: yes),
            ],
          );
  }

  Widget _button(
    BuildContext context,
    String label,
    VoidCallback onPressed, {
    required bool primary,
  }) {
    final child = Text(
      label,
      textAlign: TextAlign.center,
      style: const TextStyle(fontWeight: FontWeight.w700),
    );
    return ConstrainedBox(
      key: ValueKey(
        primary ? 'location-rationale-continue' : 'location-rationale-decline',
      ),
      // Above the 44pt／48dp touch target.
      constraints: const BoxConstraints(minHeight: 50),
      child: isCupertino
          ? cu.CupertinoButton.filled(
              // The theme's colors, so dark mode keeps the label readable.
              color: Theme.of(context).colorScheme.primary,
              foregroundColor: Theme.of(context).colorScheme.onPrimary,
              borderRadius: BorderRadius.circular(999),
              onPressed: onPressed,
              child: child,
            )
          : M3EButton(
              onPressed: onPressed,
              style: primary ? M3EButtonStyle.filled : M3EButtonStyle.outlined,
              size: M3EButtonSize.md,
              child: child,
            ),
    );
  }
}

/// Shows [LocationRationaleCard] over the current view when an action is
/// about to have the system ask for location for the first time; true for
/// 繼續. Android can also swipe it away, which reads as 先不要.
Future<bool> showLocationRationale(BuildContext context) async {
  final proceed = await showModalBottomSheet<bool>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    useSafeArea: true,
    isDismissible: !isCupertino,
    enableDrag: !isCupertino,
    backgroundColor: Colors.transparent,
    elevation: 0,
    constraints: const BoxConstraints(maxWidth: LocationRationaleCard.maxWidth),
    builder: (ctx) => PopScope(
      canPop: !isCupertino,
      child: LocationRationaleCard(
        onContinue: () => Navigator.pop(ctx, true),
        onDecline: isCupertino ? null : () => Navigator.pop(ctx, false),
      ),
    ),
  );
  return proceed ?? false;
}

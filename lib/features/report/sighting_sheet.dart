import '../../data/app_store.dart';
import '../../models/parking.dart';
import '../../models/rider_sighting.dart';
import '../../ui/adaptive/adaptive.dart';
import '../auth/sign_in.dart';
import 'spot_suggestions.dart';

/// 回報現場狀況 (#154; realtime availability canvas 路邊靜態與騎士回報):
/// the three things a rider can say from the spot, as the suggestion menu
/// lists its fields. Spaces and a full bay go out at once; 無法停車／施工中
/// is also recorded, then opens the 這裡已經不能停車 form, so a closure
/// still goes through review (#116).
Future<void> showSightingSheet(
  BuildContext context,
  AppStore store,
  ParkingSpot spot,
) async {
  if (!store.canReport) {
    await showSignIn(context, store);
    return;
  }
  await showAdaptiveSheet<void>(
    context,
    (ctx) => SightingChoices(store: store, spot: spot),
  );
}

@visibleForTesting
class SightingChoices extends StatelessWidget {
  const SightingChoices({super.key, required this.store, required this.spot});
  final AppStore store;
  final ParkingSpot spot;

  static const _icons = {
    SightingKind.available: Icons.check_circle_outline,
    SightingKind.full: Icons.do_not_disturb_on_outlined,
    SightingKind.closed: Icons.construction_outlined,
  };

  Future<void> _send(BuildContext context, SightingKind kind) async {
    final messenger = ScaffoldMessenger.of(context);
    String message;
    var sent = false;
    try {
      message = await store.reportSighting(spot, kind);
      sent = true;
    } on StateError catch (e) {
      message = e.message.toString();
    } catch (_) {
      message = '回報沒有送出，請確認網路後再試一次。';
    }
    if (kind == SightingKind.closed && context.mounted) {
      if (!sent) messenger.showSnackBar(SnackBar(content: Text(message)));
      // The rider's words and the reopening date go to review whether or
      // not the sighting counted; the form closes this list once sent.
      await showGoneReport(context, store, spot);
      return;
    }
    if (context.mounted) Navigator.pop(context);
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetTitle('回報現場狀況'),
          const SizedBox(height: 8),
          Text(spot.name, style: TextStyle(color: colors.onSurfaceVariant)),
          const SizedBox(height: 12),
          const Text('只回報你現在在現場看到的狀況。其他車友 30 分鐘內會看到，不會顯示你的名字。'),
          const SizedBox(height: 20),
          Material(
            color: colors.surfaceContainerLow,
            borderRadius: BorderRadius.circular(24),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (final (i, kind) in SightingKind.values.indexed) ...[
                  if (i > 0)
                    const Divider(height: 1, indent: 20, endIndent: 20),
                  ListTile(
                    key: ValueKey('sighting-${kind.wire}'),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 8,
                    ),
                    leading: Icon(_icons[kind], color: colors.primary),
                    title: Text(kind.label),
                    subtitle: kind == SightingKind.closed
                        ? const Text('接著填寫修改建議，審核後更新地圖')
                        : null,
                    trailing: kind == SightingKind.closed
                        ? const Icon(Icons.chevron_right)
                        : null,
                    onTap: () => _send(context, kind),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

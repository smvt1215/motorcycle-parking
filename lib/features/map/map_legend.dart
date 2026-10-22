import '../../domain/eligibility.dart';
import '../../models/parking.dart';
import '../../ui/adaptive/adaptive.dart';

const pendingColor = Color(0xff59646c);

/// Shared by the Flutter and Google map markers so the legend matches both.
Color spotMarkerColor(EligibilityStatus status, {bool pending = false}) =>
    pending
    ? pendingColor
    : switch (status) {
        EligibilityStatus.allowed => allowedColor,
        EligibilityStatus.conditional => conditionalColor,
        EligibilityStatus.notAllowed => deniedColor,
      };

IconData spotMarkerIcon(EligibilityStatus status) => switch (status) {
  EligibilityStatus.allowed => Icons.local_parking,
  EligibilityStatus.conditional => Icons.priority_high,
  EligibilityStatus.notAllowed => Icons.close,
};

class SpotMarker extends StatelessWidget {
  const SpotMarker({
    super.key,
    required this.status,
    required this.pending,
    this.size = 38,
  });
  final EligibilityStatus status;
  final bool pending;
  final double size;
  @override
  Widget build(BuildContext context) => Center(
    child: Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: spotMarkerColor(status, pending: pending),
        border: Border.all(color: Colors.white, width: size * 3 / 38),
        borderRadius: BorderRadius.circular(
          size *
              switch (status) {
                EligibilityStatus.allowed => 20,
                EligibilityStatus.conditional => 10,
                EligibilityStatus.notAllowed => 4,
              } /
              38,
        ),
        boxShadow: const [
          BoxShadow(
            blurRadius: 6,
            color: Color(0x44000000),
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Icon(
        spotMarkerIcon(status),
        color: Colors.white,
        size: size * 22 / 38,
      ),
    ),
  );
}

/// Marker meanings for the selected vehicle; shape repeats the colour so the
/// legend does not rely on colour alone.
class MapLegend extends StatelessWidget {
  const MapLegend({super.key, required this.vehicle});
  final VehicleType vehicle;
  @override
  Widget build(BuildContext context) {
    final entries = [
      (
        EligibilityStatus.allowed,
        false,
        '圓形・可停',
        '依法規或場站資料，${vehicle.label}可停放',
      ),
      (EligibilityStatus.conditional, false, '圓角方形・有條件', '限時段、區域或需確認現場公告'),
      (EligibilityStatus.notAllowed, false, '方形・不可停', '${vehicle.label}不可停放'),
      (EligibilityStatus.conditional, true, '灰色・待確認', '社群回報尚未查核，形狀仍代表可停程度'),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (status, pending, title, detail) in entries)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              children: [
                ExcludeSemantics(
                  child: SizedBox.square(
                    dimension: 44,
                    child: SpotMarker(status: status, pending: pending),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      Text(
                        detail,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

Future<void> showMapLegend(BuildContext context, VehicleType vehicle) =>
    showAdaptiveSheet<void>(
      context,
      (ctx) => ContentPage(
        children: [
          SheetTitle('地圖怎麼看'),
          const SizedBox(height: 4),
          Text(
            '標記依目前車種「${vehicle.label}」判斷，切換車種會即時更新。',
            style: Theme.of(ctx).textTheme.bodyMedium,
          ),
          const SizedBox(height: 20),
          MapLegend(vehicle: vehicle),
          const Divider(height: 32),
          const Text('數字圓圈：附近有多個停車點，放大地圖即可展開。'),
          const SizedBox(height: 8),
          const Text('長按地圖：在該位置回報新的停車點。'),
          const SizedBox(height: 16),
          const Text('社群資訊可能有延遲，停車前請確認現場標示。'),
        ],
      ),
    );

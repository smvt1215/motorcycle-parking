import '../../models/parking.dart';
import '../../ui/adaptive/adaptive.dart';
import 'spot_details.dart';

/// Source-reported vehicle access, separate from the rule-based eligibility.
/// A facility admitting both motorcycles does not establish a shared bay.
class ParkingAccessView extends StatelessWidget {
  const ParkingAccessView({super.key, required this.spot});
  final ParkingSpot spot;

  @override
  Widget build(BuildContext context) {
    if (spot.zones.isEmpty) {
      return _AccessGroup(
        access: reportedAccess(spot),
        scooter: spot.scooterAllowed,
        heavy: spot.heavyAllowed,
        scooterFee: spot.fee?.scooter?.text ?? '',
        heavyFee: spot.fee?.heavy?.text ?? '',
        showFees: spot.fee != null,
      );
    }
    // A lot-wide structured rate supersedes each zone's legacy fee text.
    final lotFee = lotWideFee(spot);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (lotFee != null) ...[
          Text(
            '全場費率',
            style: Theme.of(context).textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          _ZoneNote(
            icon: Icons.moped_outlined,
            label: '普通機車',
            value: lotFee.scooter?.text ?? '費率未確認',
          ),
          const SizedBox(height: 8),
          _ZoneNote(
            icon: Icons.two_wheeler,
            label: '大型重機',
            value: lotFee.heavy?.text ?? '費率未確認',
          ),
          const SizedBox(height: 16),
          Divider(
            height: 1,
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
          const SizedBox(height: 16),
        ],
        for (final (index, zone) in spot.zones.indexed) ...[
          if (index > 0) ...[
            const SizedBox(height: 16),
            Divider(
              height: 1,
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
            const SizedBox(height: 16),
          ],
          Row(
            children: [
              Icon(
                Icons.layers_outlined,
                size: 17,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  zone.name.isEmpty ? '分區' : zone.name,
                  style: Theme.of(context).textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (lotFee != null)
            _AccessGroup(access: zone.access)
          else
            _AccessGroup(
              access: zone.access,
              scooterFee: zone.scooterFeeText,
              heavyFee: zone.heavyFeeText,
              carFee: zone.carFeeNote,
              showFees: zone.hasVehicleFees,
            ),
          if (lotFee == null &&
              zone.fee == null &&
              zone.feeNote.trim().isNotEmpty) ...[
            const SizedBox(height: 10),
            _ZoneNote(
              icon: Icons.payments_outlined,
              label: '費率',
              value: zone.feeNote,
            ),
          ],
          if (zone.guide.trim().isNotEmpty) ...[
            const SizedBox(height: 8),
            _ZoneNote(
              icon: Icons.near_me_outlined,
              label: '指引',
              value: zone.guide,
            ),
          ],
        ],
      ],
    );
  }
}

class _AccessGroup extends StatelessWidget {
  const _AccessGroup({
    required this.access,
    this.scooter,
    this.heavy,
    this.scooterFee = '',
    this.heavyFee = '',
    this.carFee = '',
    this.showFees = false,
  });
  final ParkingAccess? access;
  final bool? scooter, heavy;
  final String scooterFee, heavyFee, carFee;
  final bool showFees;

  @override
  Widget build(BuildContext context) {
    final shared =
        access == ParkingAccess.scooterHeavy ||
        access == ParkingAccess.heavyCar;
    final vehicles = switch (access) {
      ParkingAccess.scooterOnly => [
        (Icons.moped_outlined, '普通機車', true, scooterFee),
      ],
      ParkingAccess.heavyOnly => [(Icons.two_wheeler, '大型重機', true, heavyFee)],
      ParkingAccess.scooterHeavy => [
        (Icons.moped_outlined, '普通機車', true, scooterFee),
        (Icons.two_wheeler, '大型重機', true, heavyFee),
      ],
      ParkingAccess.heavyCar => [
        (Icons.two_wheeler, '大型重機', true, heavyFee),
        (Icons.directions_car_outlined, '汽車', true, carFee),
      ],
      ParkingAccess.noMotorcycle => [
        (Icons.moped_outlined, '普通機車', false, scooterFee),
        (Icons.two_wheeler, '大型重機', false, heavyFee),
      ],
      null => [
        (Icons.moped_outlined, '普通機車', scooter, scooterFee),
        (Icons.two_wheeler, '大型重機', heavy, heavyFee),
      ],
    };
    final hasRates =
        showFees || vehicles.any((vehicle) => vehicle.$4.trim().isNotEmpty);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          access?.description ?? '格位配置未確認',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            for (final (index, vehicle) in vehicles.indexed) ...[
              if (index > 0)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: shared
                      ? Icon(
                          Icons.swap_horiz,
                          semanticLabel: '共用格位',
                          color: Theme.of(context).colorScheme.primary,
                          size: 22,
                        )
                      : const SizedBox(width: 4),
                ),
              Expanded(
                child: _VehicleToken(
                  icon: vehicle.$1,
                  label: vehicle.$2,
                  state: access == null || access == ParkingAccess.noMotorcycle
                      ? switch (vehicle.$3) {
                          true => '可停',
                          false => '不可停',
                          null => '未確認',
                        }
                      : shared
                      ? '共用'
                      : '專用',
                  permitted: vehicle.$3,
                ),
              ),
            ],
          ],
        ),
        if (hasRates) ...[
          const SizedBox(height: 12),
          for (final (index, vehicle) in vehicles.indexed) ...[
            if (index > 0) const SizedBox(height: 8),
            _ZoneNote(
              icon: vehicle.$1,
              label: vehicle.$2,
              value: vehicle.$4.trim().isEmpty ? '費率未提供' : vehicle.$4,
            ),
          ],
        ],
      ],
    );
  }
}

class _VehicleToken extends StatelessWidget {
  const _VehicleToken({
    required this.icon,
    required this.label,
    required this.state,
    required this.permitted,
  });
  final IconData icon;
  final String label, state;
  final bool? permitted;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final color = permitted == false
        ? colors.error
        : permitted == null
        ? colors.onSurfaceVariant
        : colors.primary;
    return Semantics(
      label: '$label，$state',
      child: ExcludeSemantics(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            border: Border.all(color: colors.outlineVariant),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Icon(icon, size: 28, color: color),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: Theme.of(context).textTheme.labelLarge),
                    const SizedBox(height: 2),
                    Text(
                      state,
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: color),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ZoneNote extends StatelessWidget {
  const _ZoneNote({
    required this.icon,
    required this.label,
    required this.value,
  });
  final IconData icon;
  final String label, value;
  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(
        icon,
        size: 16,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      const SizedBox(width: 8),
      Expanded(
        child: Text(
          '$label：$value',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(height: 1.5),
        ),
      ),
    ],
  );
}

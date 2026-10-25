import '../../models/fee.dart';
import '../../models/parking.dart';
import '../../domain/eligibility.dart';

/// A single zone can show its actual price in the preview. A zone never
/// inherits the lot's fee or another vehicle's price.
String zoneFeeSummary(ParkingZone zone, VehicleType vehicle) {
  if (zone.hasVehicleFees) {
    final value = vehicle == VehicleType.scooter
        ? zone.scooterFeeText
        : zone.heavyFeeText;
    return value.trim().isEmpty ? '費率未確認' : value;
  }
  return zone.feeNote.trim();
}

/// Whether any zone carries its own structured rates.
bool hasZoneFees(ParkingSpot spot) => spot.zones.any((z) => z.fee != null);

/// The lot's structured rates when no zone has its own; they then supersede
/// every legacy zone text, so a newer lot rate is never hidden by them.
Fee? lotWideFee(ParkingSpot spot) => hasZoneFees(spot) ? null : spot.fee;

/// Structured rates come first (a zone's own, then the lot's); legacy text
/// is used only when neither exists.
String spotFeeSummary(ParkingSpot spot, VehicleType vehicle) {
  if (hasZoneFees(spot)) {
    return spot.zones.length == 1
        ? zoneFeeSummary(spot.zones.single, vehicle)
        : '依分區計費';
  }
  if (spot.fee case final fee?) {
    final rate = vehicle == VehicleType.scooter ? fee.scooter : fee.heavy;
    return rate?.text ?? '費率未確認';
  }
  if (spot.zones.length == 1) {
    final value = zoneFeeSummary(spot.zones.single, vehicle);
    if (value.isNotEmpty) return value;
  }
  if (spot.zones.any((z) => z.hasVehicleFees || z.feeNote.trim().isNotEmpty)) {
    return '依分區計費';
  }
  return spot.feeNote.trim().isEmpty ? '依現場公告' : spot.feeNote;
}

/// Whether [spotFeeSummary] gives the selected vehicle's own rate.
bool spotFeeIsVehicleRate(ParkingSpot spot) => hasZoneFees(spot)
    ? spot.zones.length == 1
    : spot.fee != null ||
          (spot.zones.length == 1 && spot.zones.single.hasVehicleFees);

/// Details link to the official license, never to imported community maps.
Uri? licenseLinkUri(ParkingSpot spot) =>
    spot.isOfficial ? Uri.https('data.gov.tw', '/license') : null;

String regionSummary(ParkingSpot spot) =>
    '${spot.city.trim()}${spot.district.trim()}';

String decisionExplanation(ParkingSpot spot, Eligibility eligibility) =>
    eligibility.status == EligibilityStatus.unverified &&
        spot.spaceType == SpaceType.offStreet &&
        !spot.isOfficial &&
        spot.status == TrustStatus.confirmed &&
        !spot.stale
    ? '已確認此停車點存在；目前車種是否開放仍待查核，請以入口公告為準。'
    : eligibility.reason;

String facilitySummary(ParkingSpot spot) =>
    spot.facilityType?.label ?? (spot.isFacility ? '路外停車場（型式未提供）' : '路邊停車格');

/// Do not infer shared bays from a facility admitting both vehicle types.
ParkingAccess? reportedAccess(ParkingSpot spot) {
  if (spot.access != null) return spot.access;
  if (spot.spaceType == SpaceType.heavyOnly) return ParkingAccess.heavyOnly;
  if (spot.scooterAllowed == false && spot.heavyAllowed == false) {
    return ParkingAccess.noMotorcycle;
  }
  if (spot.spaceType == SpaceType.car && spot.heavyAllowed == true) {
    return ParkingAccess.heavyCar;
  }
  if (spot.scooterAllowed == true && spot.heavyAllowed == false) {
    return ParkingAccess.scooterOnly;
  }
  if (!spot.isFacility &&
      spot.spaceType != SpaceType.car &&
      spot.scooterAllowed == true &&
      spot.heavyAllowed == true) {
    return ParkingAccess.scooterHeavy;
  }
  return null;
}

String _accessValue(bool? value) => switch (value) {
  true => '可停',
  false => '不可停',
  null => '未確認',
};

String accessSummary(ParkingSpot spot) {
  final access = reportedAccess(spot);
  if (access != null) return '${access.label} · ${access.description}';
  return '普通機車${_accessValue(spot.scooterAllowed)}\n'
      '大型重機${_accessValue(spot.heavyAllowed)}\n格位配置未確認';
}

String formatSpotTime(DateTime value) =>
    value.toLocal().toString().substring(0, 16);

String availabilitySummary(ParkingSpot spot) {
  final available = spot.available;
  if (available == null || available < 0) return '暫無即時資訊';
  final total = spot.scooterTotal;
  final capacity = total != null && total >= available ? ' / $total 格' : '';
  // Legacy TDX normalize() emits a count only with a valid live timestamp,
  // stored in updated_at. Other sources' point updates are not live times.
  final at =
      spot.availabilityUpdatedAt ??
      (spot.source == 'tdx' && spot.spaceType == SpaceType.offStreet
          ? spot.updatedAt
          : null);
  return '機車剩餘 $available 格$capacity\n'
      '${at == null ? '車位資料時間未提供' : '車位資料時間：${formatSpotTime(at)}'}';
}

String sourceSummary(ParkingSpot spot, {required bool demo}) => demo
    ? '範例資料'
    : spot.isOfficial
    // Official data is credited to the government that publishes it.
    ? (spot.source == 'official' && spot.sourceName.isNotEmpty
          ? spot.sourceName
          : spot.city.isEmpty
          ? '政府公開資料'
          : '${spot.city}政府')
    : contributorSummary(spot);

String contributorSummary(ParkingSpot spot) {
  if (spot.contributorRole == 'admin') return '由管理員新增';
  if (spot.contributorRole == 'import' || spot.source == 'import') {
    return '由管理員自其他社群統整後匯入';
  }
  final name = spot.contributorName.trim();
  // Email is an account identifier, not a public reporter name.
  return name.isEmpty || name.contains('@') ? '由車友回報' : '由車友 $name 回報';
}

String trustSummary(ParkingSpot spot, {required bool demo}) => demo
    ? '範例，僅供功能預覽'
    : switch (spot.status) {
        TrustStatus.pending => '待確認',
        TrustStatus.confirmed => spot.stale ? '已確認，資訊可能過時' : '已確認',
        TrustStatus.hidden => '已隱藏',
      };

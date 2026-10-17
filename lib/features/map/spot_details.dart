import '../../models/parking.dart';

Uri? sourceLinkUri(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      !uri.isAbsolute ||
      (uri.scheme != 'https' && uri.scheme != 'http') ||
      uri.host.isEmpty) {
    return null;
  }
  return uri;
}

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

String sourceSummary(ParkingSpot spot, {required bool demo}) =>
    demo || spot.source == 'fixture'
    ? '範例資料'
    : spot.isOfficial
    // Official data is credited to the government that publishes it.
    ? (spot.source == 'official' && spot.sourceName.isNotEmpty
          ? spot.sourceName
          : spot.city.isEmpty
          ? '政府公開資料'
          : '${spot.city}政府')
    : spot.source == 'import'
    ? '社群回報整理'
    : '社群回報';

String trustSummary(ParkingSpot spot, {required bool demo}) =>
    demo || spot.source == 'fixture'
    ? '範例，僅供功能預覽'
    : switch (spot.status) {
        TrustStatus.pending => '待確認',
        TrustStatus.confirmed => spot.stale ? '已確認，資訊可能過時' : '已確認',
        TrustStatus.hidden => '已隱藏',
      };

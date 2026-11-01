/// 推定規則 for the fee conversion (#235): the 需人工確認 readings whose
/// suggestion an admin may accept by category, with `--assume <id>`.
///
/// readFeeNote (lib/admin/import/fee_reading.dart) stays as it is: it never
/// guesses, and only marks a fee 可轉換 when the text says so for certain.
/// A category here names one kind of uncertainty it reports, and what
/// accepting it means; nothing is assumed unless the category is asked for
/// by name. Only readings that come with a suggested fee can be assumed —
/// for the rest there is nothing to accept.
library;

import 'package:motorcycle_parking/admin/import/fee_reading.dart';
import 'package:motorcycle_parking/models/fee.dart';

/// One category: its stable id (the `--assume` value), a name and what
/// assuming it means.
class FeeAssumption {
  const FeeAssumption(this.id, this.name, this.meaning);
  final String id, name, meaning;
}

const _unlabelled = '未註明是哪一種車的費率';
const _besideUnlabelled = '另有未註明車種的費率';

/// Every category, in the order the report lists them.
const feeAssumptions = <FeeAssumption>[
  FeeAssumption(
    'motorcycle-bay-unlabelled',
    '機車格的費率未註明車種',
    '格位是機車格（paidMotorcycle／freeMotorcycle）、費率沒寫車種 → 當成普通機車費率',
  ),
  FeeAssumption(
    'official-lot-unlabelled',
    '官方停車場的費率未註明車種',
    '官方停車場資料只寫一個沒有車種的費率（例：「免費」）→ 當成普通機車費率',
  ),
  FeeAssumption(
    'car-bay-unlabelled',
    '汽車格的費率未註明車種',
    '格位是汽車格（car）、車友回報的費率沒寫車種 → 當成大型重機費率',
  ),
  FeeAssumption(
    'official-scooter-beside-unlabelled',
    '官方機車費率旁另有未註明車種的費率',
    '官方資料寫明機車費率，另有沒寫車種的費率（多為汽車計時）→ 忽略沒寫車種的那段，只採機車費率',
  ),
  FeeAssumption(
    'official-heavy-beside-unlabelled',
    '官方大型重機費率旁另有未註明車種的費率',
    '官方資料提到大型重機，另有沒寫車種的費率 → 忽略沒寫車種的那段，採讀到的大型重機費率',
  ),
  FeeAssumption(
    'community-heavy-as-car',
    '車友回報：大型重機比照汽車費率',
    '車友回報「大型重機（或重機專用格）比照汽車費率」→ 把金額當成大型重機費率',
  ),
  FeeAssumption(
    'community-heavy-car-area',
    '車友回報：大型重機停汽車區',
    '車友回報「大型重機停汽車區」→ 把金額當成大型重機費率',
  ),
  FeeAssumption(
    'community-heavy-own-rate',
    '車友回報：大型重機另訂費率',
    '車友回報「大型重機另訂費率」→ 把寫出的金額當成大型重機費率',
  ),
];

final feeAssumptionIds = {for (final a in feeAssumptions) a.id};

FeeAssumption feeAssumption(String id) =>
    feeAssumptions.firstWhere((a) => a.id == id);

/// The category of a 需人工確認 [reading] of a spot's note, or null when
/// it is in none (not 需人工確認, no suggestion, or an uncertainty no
/// category covers). [spaceType] and [official] are the spot's.
String? assumptionOf(
  FeeReading reading, {
  required String? spaceType,
  required bool official,
}) {
  final fee = reading.fee;
  if (reading.verdict != FeeVerdict.manual || fee == null || fee.isEmpty) {
    return null;
  }
  final scooterOnly = fee.scooter != null && fee.heavy == null;
  final heavyOnly = fee.heavy != null && fee.scooter == null;
  if (fee.car != null) return null;
  switch (reading.reason) {
    case _unlabelled when scooterOnly && !official:
      return spaceType == 'paidMotorcycle' || spaceType == 'freeMotorcycle'
          ? 'motorcycle-bay-unlabelled'
          : null;
    case _unlabelled when scooterOnly && official:
      return 'official-lot-unlabelled';
    case _unlabelled when heavyOnly && !official && spaceType == 'car':
      return 'car-bay-unlabelled';
    case _besideUnlabelled when official && scooterOnly:
      return 'official-scooter-beside-unlabelled';
    case _besideUnlabelled when official && fee.heavy != null:
      return 'official-heavy-beside-unlabelled';
    case '大型重機比照汽車費率是車友回報、非公告明定，請核對公告' when heavyOnly && !official:
      return 'community-heavy-as-car';
    case '大型重機停汽車區的費率是車友回報、非公告明定，請核對公告' when heavyOnly && !official:
      return 'community-heavy-car-area';
    case '「另訂費率」未說明金額是否為大型重機費率' when heavyOnly && !official:
      return 'community-heavy-own-rate';
  }
  return null;
}

/// The fee to write for [reading] when [assumed] lists the categories an
/// admin accepted: the certain fee, or the suggestion of an accepted
/// category; null otherwise. [category] is the accepted category used, or
/// null for a certain one.
({Fee fee, String? category})? feeToWrite(
  FeeReading reading, {
  required String? spaceType,
  required bool official,
  Set<String> assumed = const {},
}) {
  final fee = reading.fee;
  if (fee == null || fee.isEmpty) return null;
  if (reading.verdict == FeeVerdict.convertible) {
    return (fee: fee, category: null);
  }
  final category = assumptionOf(
    reading,
    spaceType: spaceType,
    official: official,
  );
  if (category == null || !assumed.contains(category)) return null;
  return (fee: fee, category: category);
}

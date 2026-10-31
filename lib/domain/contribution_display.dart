import '../data/contributions_repository.dart';

/// 貢獻 (P8) 與我送出的建議 (P9) 的文字.
const contributeFixTitle = '修正附近停車點';
const contributeFixHint = '選目前地圖範圍內的停車點，修改資訊或回報已不存在。';
const contributeNewSpot = '新增停車點';
const contributeNewSpotHint = '回報地圖上還沒有的停車點';
const contributeFootnote = '回報會先標示待確認；停車前仍請確認現場公告。';
const myContributionsTitle = '我送出的建議';
const myContributionsIntro = '新增的停車點、修改建議和不能停車的回報，以及審核結果。';
const myContributionsAll = '查看全部紀錄';
const editSpot = '修改';

String showAllSpots(int count) => '查看全部 $count 個停車點';

/// What kind of report a row is, as its first line names it.
String contributionKindLabel(ContributionKind kind) => switch (kind) {
  ContributionKind.suggestion => '修改建議',
  ContributionKind.newSpot => '新增停車點',
  ContributionKind.gone => '不能停車回報',
};

/// The field a suggestion changed, in the four road signs' words where one
/// fits: 「怎麼算錢：20/時 → 30/時」.
String contributionFieldText(String label) => switch (label) {
  '收費資訊' => '怎麼算錢',
  '機車停放資格' => '能不能停',
  '入口與停車指引' => '停哪裡',
  _ => label,
};

/// The row's summary line: the field and what was sent, or only what was
/// sent when the field is unknown.
String? contributionSummary(MyContribution item) {
  final detail = item.detail;
  if (detail == null) return null;
  if (item.kind != ContributionKind.suggestion) return detail;
  return switch (item.fieldLabel) {
    final label? => '${contributionFieldText(label)}：$detail',
    null => detail,
  };
}

/// 10月22日, with the year when it is not this year.
String contributionDate(DateTime time, DateTime now) => time.year == now.year
    ? '${time.month}月${time.day}日'
    : '${time.year}年${time.month}月${time.day}日';

/// 「650 m」「1.2 km」.
String distanceText(double meters) => meters < 1000
    ? '${meters.round()} m'
    : '${(meters / 1000).toStringAsFixed(1)} km';

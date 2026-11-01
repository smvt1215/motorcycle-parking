/// The words of 即時車位 Beta (design canvas v157 A13, A14, P3): which
/// cities' official counts are still in Beta, and every line that says so.
/// The cities come from `api_v1.client_config()`; none is named here but
/// [defaultAvailabilityBetaCities], used until the backend has answered
/// once. 「試辦」 is never used: city rules already say 「試辦路段」.
/// Pure Dart.
library;

/// The Beta cities before the backend has ever answered.
const defaultAvailabilityBetaCities = ['臺北市'];

/// The tag beside a Beta label.
const betaTagLabel = 'Beta';

/// 台 and 臺 name the same city.
String _city(String name) => name.trim().replaceAll('台', '臺');

/// Whether [city]'s official counts are in Beta.
bool inAvailabilityBeta(String city, List<String> cities) =>
    city.trim().isNotEmpty && cities.any((c) => _city(c) == _city(city));

/// 「臺北市」, 「臺北市、新北市」.
String betaCitiesText(List<String> cities) => cities.join('、');

/// The first-time sheet (A13), shown once the map first shows a count in
/// [city].
String betaIntroTitle(String city) => '$city可以看即時空位了';

/// Its first row, beside a pill: who counts and how often.
String betaIntroSource(String provider) =>
    '停車場上方的數字是$provider提供的剩餘車位，大約每 5 分鐘更新。';

/// Its second row. The board's 「看到不一樣，可以在詳情按『回報現場狀況』」
/// waits for that action (#189 PR-E).
const betaIntroCaution = '還在試點，數字可能和現場不一樣，抵達時請以現場為準。';

/// Its third row.
const betaIntroEligibility = '能不能停仍看圖示的顏色和形狀；有空位不代表你的車種可以停。';

const betaIntroDone = '知道了';
const betaIntroLegend = '看「地圖怎麼看」';

/// The filter's empty result where the map shows no Beta city (A13).
String betaOnlyCities(List<String> cities) =>
    '即時空位目前只有${betaCitiesText(cities)}';

/// The empty result's line under [betaOnlyCities].
const betaOnlyCitiesDetail = '這個範圍的停車點都還在，只是沒有官方即時空位資料。';

/// The last line of 有沒有位 in the details (A14). The board's 「請按下方
/// 『回報現場狀況』」 waits for that action (#189 PR-E).
String betaDetailNote(List<String> cities) =>
    '${betaOnlyCities(cities)}，還在試點，抵達時請以現場為準。';

/// The legend's 即時車位 section (P3), named by the cities rather than a
/// provider, since no spot is in view.
const legendBetaHeading = '即時車位';
String legendBetaSource(List<String> cities) =>
    '停車場上方的數字是${betaCitiesText(cities)}官方提供的剩餘車位，大約每 5 分鐘更新。';

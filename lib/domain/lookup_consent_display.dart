/// 選點表單第一次自動查詢位置前的告知與同意的文字 (#462; N1c, N1d, P10b).
library;

// N1c: the card under the map.

/// The card's and its buttons' spoken group names.
const lookupCardLabel = '自動查詢位置';
const lookupChoiceLabel = '要不要自動查詢';

/// [door]: the approximate door is looked up for this rider now, which
/// takes a signed-in account and a Google map.
String lookupCardTitle({required bool door}) =>
    door ? '要自動查這個位置的縣市和門牌嗎？' : '要自動查這個位置的縣市和行政區嗎？';
const lookupCardLead = '同意後，標記每次停住，App 會把它的座標傳出去：';

const lookupTownName = '縣市與行政區';
const lookupTownDetail = '直接送到內政部國土測繪中心。對方會看到你手機的網路位址。';
const lookupDoorName = '約略門牌';
const lookupDoorDetail = '經我們的伺服器送到 Google。Google 不會收到你的帳號和網路位址。';
const lookupDoorSignedOutDetail =
    '你還沒登入，現在不會查。登入後才會查：'
    '經我們的伺服器送到 Google，Google 不會收到你的帳號和網路位址。';
const lookupMyLocationDetail = '按「移到我的位置」時，傳出去的就是你當下的位置。';

/// What declining leaves; the door is only named where it would be shown.
String lookupDeclineNote({required bool door}) =>
    '不同意也能回報：自己選縣市與行政區${door ? '，不顯示約略門牌' : ''}。'
    '之後可以到「帳號與設定 › 隱私」更改。';

const lookupDecline = '不同意，自己選';
const lookupAgree = '同意，自動查詢';
const lookupPolicyLink = '看〈隱私權政策〉的完整說明';

// N1d: the form after the answer.

const lookupAutoHint = '依地圖位置自動帶入，可以改。';
const lookupTurnOff = '關閉自動查詢';
const lookupTurnedOff = '已關閉自動查詢';
const lookupOffNote = '自動查詢已關閉。請自己選縣市與行政區。';
const lookupTurnOn = '開啟自動查詢';

/// Under the county and district while the lookups are off and the marker
/// moved since they were picked or looked up (Q462-1 C).
const lookupMovedNote = '標記移動了，請確認縣市與行政區';

// P10b: 帳號與設定 › 隱私.

const settingsLookup = '選點時自動查縣市與門牌';
const settingsLookupDetail =
    '新增停車點或建議修改位置時，App 會把標記的座標直接送到內政部國土測繪中心'
    '查縣市與行政區，對方會看到你手機的網路位址；登入時另外經我們的伺服器送到 '
    'Google 查約略門牌。按「移到我的位置」時，傳出去的就是你當下的位置。';
const settingsLookupOffDetail = '關閉時不會自動查詢：你自己選縣市與行政區，不顯示約略門牌。';

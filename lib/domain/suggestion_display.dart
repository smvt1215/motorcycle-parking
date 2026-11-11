/// 提出修改建議送出後的文字（S6、S6b，#403）：回到清單的確認區、列上的
/// 標記、「完成」、關閉後的提示條，以及送出失敗時固定在按鈕上方的說明。
library;

/// 清單上可以各自送出建議的項目。「這裡已經不能停車」與內容檢舉送出後
/// 直接結束，不在其中。
enum SuggestionItem {
  name,
  location,
  facility,
  vehicles,
  limits,
  fee,
  where,
  note;

  /// 確認區與提示條用的項目名稱；「停哪裡」那列的標題太長，依停車場或
  /// 路邊簡寫。
  String label({required bool street}) => switch (this) {
    name => '名稱',
    location => '位置',
    facility => '場站型式',
    vehicles => '可停車種',
    limits => '限時／禁停／共用時段',
    fee => '費率',
    where => street ? '路段與格位' : '分區與格位',
    note => '其他備註',
  };
}

/// 審核前地圖不會變。
const suggestionReviewNote = '管理員審核通過後才會更新地圖。';

/// 範例模式沒有後端，建議不會真的送出。
const suggestionDemoNote = '範例模式：建議沒有實際送出，只用來測試流程。';

/// 確認區的標題：一項寫出項目，多項寫件數。
String suggestionSentTitle(List<String> items) =>
    items.length == 1 ? '「${items.single}」的建議已送出' : '已送出 ${items.length} 項建議';

/// 確認區的內文：多項時先列出項目。
String suggestionSentBody(List<String> items, {bool demo = false}) {
  final note = demo ? suggestionDemoNote : suggestionReviewNote;
  return items.length == 1 ? note : '${items.join('、')}。$note';
}

/// 送出後取代清單開頭引導句的問句。
const suggestionAskMore = '還要改這個點的其他項目嗎？點進去繼續改；都改完了就按「完成」。';

/// 剛送出的那一列的標記，與朗讀。
const suggestionSentTag = '已送出，審核中';

/// 清單底部的主按鈕與說明。
const suggestionDone = '完成';
const suggestionDoneNote = '審核結果會出現在「貢獻 › 我送出的建議」';

/// 關閉修改建議後，原畫面底部的提示條。
String suggestionSentToast(int count) => '已送出 $count 項建議，審核通過後會更新地圖';
const suggestionToastView = '查看';

/// 送出失敗：內容還在，再按一次 [button]。
const sendFailedTitle = '建議沒有送出';
String sendFailedBody(String button) => '你填的內容還在。請稍後再按一次「$button」。';

/// 連不上伺服器（沒有網路）：內容還在，連上後再按一次 [button]。
const sendOfflineTitle = '目前沒有網路，建議沒有送出';
String sendOfflineBody(String button) => '你填的內容還在。連上網路後，再按一次「$button」。';

/// 檢舉內容不當的文字 (#280, canvas v172 P17b).
library;

const contentReportTitle = '檢舉內容不當';
const contentReportIntro = '送出後，被檢舉的內容會先暫時隱藏，管理員會在 5 個工作天內審核。檢舉不會通知對方。';
const contentReportQuestion = '哪裡不當？';
const contentReportSubmit = '送出檢舉';
const contentReportCancel = '取消';
const contentReportDone = '完成';
const contentReportSignIn = '登入 Google 或 Apple 帳號後，才能送出檢舉。';

/// What is inappropriate: the value sent as `proposed.target` (T280 API
/// draft L2).
enum ContentReportTarget {
  contributorName('rider_name', '車友名稱'),
  spotName('spot_name', '停車點名稱'),
  description('text', '說明文字'),
  personalData('impersonation', '個人資料或冒充他人'),
  other('other', '其他');

  const ContentReportTarget(this.wire, this.label);

  /// The stable value the backend reads.
  final String wire;
  final String label;
}

/// The option's second line; names are quoted as shown on the spot.
String contentReportTargetDetail(
  ContentReportTarget target, {
  required String riderName,
  required String spotName,
}) => switch (target) {
  ContentReportTarget.contributorName => '「$riderName」',
  ContentReportTarget.spotName => '「$spotName」',
  ContentReportTarget.description => '入口、停哪裡、備註等文字',
  ContentReportTarget.personalData => '公開了別人的個資，或假冒他人、單位',
  ContentReportTarget.other => '請在附註寫明',
};

/// The `reason` a flag needs: what was reported, in words.
String contentReportReason(ContentReportTarget target) =>
    '內容不當：${target.label}';

const contentReportNoteMax = 500;
String contentReportNoteLabel({required bool required}) =>
    required ? '附註（必填，最多 500 字）' : '附註（選填，最多 500 字）';
const contentReportNoteHint = '例：哪幾個字、哪一段';

/// Under the note, and the error when the server refuses one with an email
/// or a phone number (T280_Q_REPORT_NOTE_PII = A).
const contentReportNotePersonal = '不用貼出個資，選類別即可';

/// The error when the server refuses a note with a link (`ad_url`).
const contentReportNoteLink = '附註不能放網址連結';
const contentReportNoteMissing = '選「其他」時，請寫下哪裡不當。';
const contentReportFailed = '檢舉沒有送出，內容還在，請確認網路後再送一次。';

// Results (P17b ④⑥⑦).
const contentReportSentTitle = '檢舉已送出';
const contentReportSentBody = '已送出。被檢舉的內容會先暫時隱藏，管理員會在 5 個工作天內審核。';
const contentReportDuplicateTitle = '你已經檢舉過這個停車點';
const contentReportDuplicateBody = '上一次的檢舉還在處理中，不用再送一次。管理員會在 5 個工作天內審核。';
const contentReportLimitTitle = '今天的檢舉次數已達上限';
const contentReportLimitBody =
    '台灣時間午夜 12 點後可以再檢舉。急著處理的內容可以從「帳號與設定」的「聯絡我們」告訴我們。';
const contentReportHidePrompt = '不想再看到他新增的停車點和名稱？';

// P17b ①: the 修改建議 list's new group.
const contentProblemGroup = '內容有問題';
const contentProblemRow = '內容不當（名稱、文字）';
const contentProblemDetail = '車友名稱、停車點名稱或說明有不當內容';

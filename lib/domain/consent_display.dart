/// 同意條款 (P16a) 與新增停車點的名稱公開提示 (P16b) 的文字.
library;

/// The consent under every sign-in button group, split where P16a breaks it.
const consentLead = '登入即表示你已年滿 18 歲，並同意';
const consentAnd = '與';
const consentTerms = '服務條款';
const consentPrivacy = '隱私權政策';

/// Shown as 〈服務條款〉; read out without the brackets.
String consentLinkText(String title) => '〈$title〉';

/// The sign-in buttons' hint, so a reader who reaches a button first still
/// hears what signing in agrees to.
const consentHint = '登入即表示你已年滿 18 歲，並同意服務條款與隱私權政策';

/// A development build without the URLs: plain text plus this badge.
const consentPlain = consentHint;
const consentDevOnly = '僅開發用：未設定條款網址';

/// The failure message when a link cannot open.
String consentOpenFailed(String title) => '無法開啟$title';

/// ReportNameNotice (P16b A): what a new spot will show.
const nameNoticeLead = '停車點會公開顯示「由車友 ';
const nameNoticeTail = ' 回報」';
const nameNoticeHidden = '停車點會顯示「由車友回報」，不顯示名稱';
const nameNoticeRename = '改名稱';
const nameNoticeSetName = '設定名稱';

/// The sentence read out, with the whole name.
String nameNoticeSpoken(String name) => '$nameNoticeLead$name$nameNoticeTail';

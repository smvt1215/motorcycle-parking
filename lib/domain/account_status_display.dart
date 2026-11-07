/// 帳號停權 (#331, P18a ①–④) 的文字。停權只擋 App 的寫入；不顯示原因。
library;

/// Where 有疑問請聯絡我們 and 聯絡我們 lead, opened in the in-app browser.
final suspendedSupportUri = Uri.parse(
  'https://motoparking.smvtstudio.com/support',
);

/// The shared panel (① ②) shown when a write is refused.
const suspendedTitle = '帳號暫時不能送出內容';
const suspendedStillAllowed = '你仍然可以瀏覽地圖、管理收藏，也可以刪除帳號。';
const suspendedContact = '有疑問請聯絡我們';
const suspendedDismiss = '知道了';
const suspendedContactFailed = '無法開啟聯絡我們頁面';

/// P10's standing card (③) and P12's note (④).
const suspendedCardDetail = '瀏覽、收藏和刪除帳號不受影響。';
const suspendedContactShort = '聯絡我們';
const suspendedIndefinite = '直到另行通知';

/// [time] on Taiwan's clock (UTC+8, no daylight saving), whatever zone the
/// phone is set to.
DateTime taiwanTime(DateTime time) =>
    time.toUtc().add(const Duration(hours: 8));

String _clock(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// 「2026 年 11 月 12 日 14:00」 in Taiwan time.
String suspendedDateLong(DateTime until) {
  final t = taiwanTime(until);
  return '${t.year} 年 ${t.month} 月 ${t.day} 日 ${_clock(t)}';
}

/// 「11 月 12 日 14:00」 in Taiwan time, with the year when it is not [now]'s
/// year there.
String suspendedDateShort(DateTime until, DateTime now) {
  final t = taiwanTime(until);
  if (t.year != taiwanTime(now).year) return suspendedDateLong(until);
  return '${t.month} 月 ${t.day} 日 ${_clock(t)}';
}

/// The panel's first line: 「到 … 為止。」 or 「直到另行通知。」.
String suspendedUntilSentence(DateTime? until) => until == null
    ? '$suspendedIndefinite。'
    : '到 ${suspendedDateLong(until)} 為止。';

/// P10's card heading (③).
String suspendedCardTitle(DateTime? until, DateTime now) => until == null
    ? '帳號暫停送出內容，$suspendedIndefinite'
    : '帳號暫停送出內容，到 ${suspendedDateShort(until, now)}';

/// P12's note under the read-only name (④).
String suspendedNameNote(DateTime? until) => until == null
    ? '帳號暫停送出內容期間不能修改名稱，$suspendedIndefinite。'
    : '帳號暫停送出內容期間不能修改名稱，到 ${suspendedDateLong(until)} 為止。';

import 'account_deletion_display.dart';

/// 登入 (P11) 與編輯個人資料 (P12) 的文字.
const signInIntro = '登入後可回報停車資訊與同步收藏。';
const signInNotNeeded = '瀏覽地圖與記錄停車位置不需登入。';

const profileNameHelper = '你新增的停車點會顯示這個名稱。';

/// P12 ②: no saved name yet; the field holds the Google name as a suggestion.
const profileNameUnset = '尚未設定公開名稱';
const profileNameSuggestionHelper =
    '這是 Google 帳號的姓名，按「儲存」後才會公開顯示在你新增的停車點。不想公開可以改成暱稱。';

/// P12 ③: the field was cleared; saving keeps the name private.
const profileNameClearing = '儲存後不公開名稱';
const profileNameClearedHelper = '留空就不公開名稱，你新增的停車點會顯示「由車友回報」。已隱藏你的人仍會維持隱藏。';

/// P10 account card when there is no saved public name.
const settingsNameUnset = '尚未設定名稱';
const settingsSetName = '設定名稱';

/// Read out after 登出 in 帳號與設定, which stays open signed out.
const settingsSignedOut = '已登出';

/// The account card's line under the name: the account email, or
/// 隱藏的電子郵件 for an Apple relay address (P19a ③, #382).
String? accountEmailLine(String? email) =>
    email != null && isAppleRelayEmail(email) ? appleHiddenEmail : email;

// P19a 已連結的登入方式（#382）：唯讀，只列已連結的方式。
const linkedSignInsTitle = '已連結的登入方式';
const linkedSignInsAutoLink =
    'Google 和 Apple 的電子郵件相同時，會自動連到同一個帳號。刪除帳號時，這裡列出的登入方式會一起刪除。';
const linkedSignInsRelayNote =
    '用 Apple 登入時如果選了「隱藏我的電子郵件」，Apple 會給一個轉寄地址。它和 Google 的電子郵件不同，所以會是另一個帳號，不會連到這裡。';

/// P19a ③: the rider's own Apple sign-in gave a relay address.
const linkedSignInsRelaySelf =
    '你用 Apple 的「隱藏我的電子郵件」登入，Apple 給的是轉寄地址。它和 Google 的電子郵件不同，所以用 Google 登入會是另一個帳號，不會連到這裡。';

/// A sign-in method an account can have, in display order.
enum SignInProvider {
  google('Google'),
  apple('Apple');

  const SignInProvider(this.label);
  final String label;
}

/// One row of 已連結的登入方式.
class LinkedSignIn {
  const LinkedSignIn(this.provider, this.email);
  final SignInProvider provider;

  /// What the provider gave at its latest sign-in; may differ from the
  /// account's own email, which is shown as is (user decision, 2026-11-11).
  final String? email;

  /// An Apple relay address, shown as [appleHiddenEmail].
  bool get hiddenEmail =>
      provider == SignInProvider.apple &&
      email != null &&
      isAppleRelayEmail(email!);

  /// The line under the name: the full address (user decision,
  /// 2026-11-11), or 隱藏的電子郵件; null when there is none.
  String? get detail => hiddenEmail ? appleHiddenEmail : email;
}

/// The rows for an account's identities as `(provider, email)`: Google
/// first, then Apple, one each; other providers are left out.
List<LinkedSignIn> linkedSignIns(
  Iterable<({String provider, String? email})> identities,
) {
  final rows = <SignInProvider, LinkedSignIn>{};
  for (final (:provider, :email) in identities) {
    final known = SignInProvider.values
        .where((p) => p.name == provider)
        .firstOrNull;
    if (known == null || rows.containsKey(known)) continue;
    final trimmed = email?.trim();
    rows[known] = LinkedSignIn(
      known,
      trimmed == null || trimmed.isEmpty ? null : trimmed,
    );
  }
  return [for (final p in SignInProvider.values) ?rows[p]];
}

/// Whether both Google and Apple are linked.
bool linksGoogleAndApple(List<LinkedSignIn> rows) =>
    rows.any((r) => r.provider == SignInProvider.google) &&
    rows.any((r) => r.provider == SignInProvider.apple);

/// The second note under the group: P19a ③'s own words when Apple with a
/// relay address is the only sign-in, else the general one.
String linkedSignInsRelayLine(List<LinkedSignIn> rows) =>
    rows.length == 1 && rows.single.hiddenEmail
    ? linkedSignInsRelaySelf
    : linkedSignInsRelayNote;

import 'config.dart';

/// The privacy policy and terms URLs (#275), from `--dart-define` and
/// replaceable in tests. Settings (P10) hides a row whose URL is empty;
/// sign-in (P16a) shows plain text marked 僅開發用 instead.
({String privacy, String terms}) policyUrls = (
  privacy: AppConfig.privacyPolicyUrl,
  terms: AppConfig.termsUrl,
);

/// [url] as a link, or null when it is empty or not an absolute http(s)
/// address.
Uri? policyUri(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
  return uri.scheme == 'https' || uri.scheme == 'http' ? uri : null;
}

/// The terms' 第 5 條 (資料來源與智慧財產權), where 資料來源與授權 leads, or null
/// without a terms URL. The site numbers its anchors by article; its
/// Policy.test.tsx pins this one.
Uri? termsDataSourcesUri() =>
    policyUri(policyUrls.terms)?.replace(fragment: 'section-5');

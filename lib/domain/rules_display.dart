/// The notice shown when the backend's rules could not be read and the
/// bundled file stands in.
const bundledRulesWarning = '遠端規則讀取失敗，顯示內建規則';

/// The notice shown when rules from the last download stand in; the date is
/// the download's, in Taiwan time.
String cachedRulesWarning(DateTime downloadedAt) {
  final taiwan = downloadedAt.toUtc().add(const Duration(hours: 8));
  return '離線，使用上次下載的規則（${taiwan.month}月${taiwan.day}日）';
}

/// [cachedRulesWarning] when cached rules are in use ([cachedAt] is their
/// download time), [bundledRulesWarning] otherwise.
String rulesFallbackWarning(DateTime? cachedAt) =>
    cachedAt == null ? bundledRulesWarning : cachedRulesWarning(cachedAt);

import 'package:flutter/widgets.dart' show StringCharacters;

/// Format only (a@b.tw): an account email is an identifier, not a public
/// reporter name. A name that merely contains @ (阿哲@台北) is not one.
final _emailPattern = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');

/// Whether [value], trimmed, has the shape of an email address.
bool isEmailLike(String value) => _emailPattern.hasMatch(value.trim());

/// The name a new spot shows as 「由車友 名稱 回報」, or null when it shows
/// only 「由車友回報」: blank names and email-shaped names stay private.
String? publicContributorName(String? name) {
  final trimmed = name?.trim() ?? '';
  return trimmed.isEmpty || isEmailLike(trimmed) ? null : trimmed;
}

final _avatarLetter = RegExp(r'^[\p{L}\p{N}]', unicode: true);

/// The default avatar's letter: the first user-perceived character of the
/// trimmed name, upper-cased, when it is a letter or digit (\p{L}, \p{N});
/// null for emoji, punctuation, symbols and blank names, which show the
/// generic person instead.
String? avatarInitial(String? name) {
  final first = (name ?? '').trim().characters.firstOrNull;
  if (first == null || !_avatarLetter.hasMatch(first)) return null;
  return first.toUpperCase();
}

/// The longest name the report name notice shows before cutting it.
const noticeNameLimit = 20;

/// [name] cut to its first [limit] user-perceived characters plus 「…」;
/// only space makes the notice cut it, so the full name is still read out.
String truncateName(String name, {int limit = noticeNameLimit}) {
  final chars = name.characters;
  return chars.length <= limit ? name : '${chars.take(limit)}…';
}

/// 需要更新 (P14, design v159) 的文字. Pure Dart.
library;

import '../core/update_gate.dart';

const updateTitle = '需要更新';
const updateBody = '這個版本已不支援，更新後才能繼續使用。';

String updateVersions(String installed, String minimum) =>
    '目前版本 $installed・最低支援版本 $minimum';

/// What P14 offers: a button when the build has a link, otherwise the way to
/// update in words ([fallback]); [note] is the small print under it.
typedef UpdateOffer = ({String? button, String? fallback, String? note});

UpdateOffer updateOffer(
  UpdateChannel channel, {
  required bool ios,
  required bool hasLink,
}) {
  final (button, fallback, note) = switch (channel) {
    UpdateChannel.store when ios => ('前往 App Store', '請到 App Store 更新', null),
    UpdateChannel.store => ('前往 Google Play', '請到 Google Play 更新', null),
    UpdateChannel.beta when ios => (
      '前往 TestFlight',
      '請打開 TestFlight 更新',
      '這是測試版，透過 TestFlight 安裝',
    ),
    UpdateChannel.beta => (
      '前往 Google Play',
      '請到 Google Play 更新',
      '這是測試版，透過 Play 內部測試安裝',
    ),
    UpdateChannel.staging => (
      '前往 App Tester',
      '請打開 Firebase App Tester 更新',
      '測試版透過 Firebase App Tester 安裝',
    ),
  };
  return hasLink
      ? (button: button, fallback: null, note: note)
      : (button: null, fallback: fallback, note: note);
}

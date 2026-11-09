/// The words of 回報現場狀況 (A7, A7b) and which places it offers. Pure Dart.
library;

import '../models/sighting.dart' show SightingRefusal;
import 'four_sign.dart';
import 'four_sign_display.dart';
import 'spot_detail_display.dart' show detailPlaceName;

const sightingTitle = '回報現場狀況';
const sightingSubmit = '送出回報';
const sightingSending = '送出中…';
const sightingSignInAgain = '重新登入';
const sightingCancel = '取消';
const sightingLevelQuestion = '現在現場怎麼樣？選一個';
const sightingClosedLabel = '無法停車／施工中';
const sightingSignIn = '登入 Google 或 Apple 帳號後，才能回報現場狀況。';
const sightingSent = '回報已送出，謝謝你。';
const sightingFailed = '回報沒有送出，內容還在，請確認網路後再送一次。';

String sightingPlaceQuestion({required bool street}) =>
    street ? '哪一段？' : '哪一區？';

String sightingPlaceHint({required bool street}) =>
    street ? '只列你現在能停的段' : '只列你現在能停的區';

/// The choice about all of it, last in the list (A7e): 全區, a road's 整條路.
String sightingAllPlacesLabel({required bool street}) => street ? '整條路' : '全區';

String sightingClosedNote({required bool street, bool allPlaces = false}) =>
    allPlaces
    ? (street ? '整條路都停不了，例如施工、封路' : '整個停車場都停不了，例如施工、封閉')
    : street
    ? '整段都停不了，例如施工、封路'
    : '整區都停不了，例如施工、封閉';

/// The note above the button. A spot standing as one has no 段 or 區 to
/// name; [allPlaces] is the rider's 全區 or 整條路 (A7e).
String sightingNote({
  required bool street,
  required bool whole,
  bool allPlaces = false,
  bool closed = false,
}) {
  if (allPlaces) {
    final target = street ? '整條路' : '整個停車場';
    if (closed) {
      return '記$target。3 位車友回報才改成不能停，2 小時後或有人回報有位就解除。需登入。';
    }
    return street
        ? '記整條路，不分哪一段，標成「車友回報」：地圖顯示 15 分鐘，詳情 30 分鐘後消失。已有 2 位車友回報無法停車的段，不會因此解除。需登入。'
        : '記整個停車場，不分哪一區。官方剩餘照常顯示；你的回報標成「車友回報」，地圖顯示 15 分鐘、詳情 30 分鐘後消失。已有 2 位車友回報無法停車的區，不會因此解除。需登入。';
  }
  final place = whole
      ? '這裡'
      : street
      ? '這一段'
      : '這一區';
  if (closed) {
    return '只記$place。2 位車友回報才改成不能停，2 小時後或有人回報有位就解除。需登入。';
  }
  return street
      ? '只記$place，標成「車友回報」：地圖顯示 15 分鐘，詳情 30 分鐘後消失。需登入。'
      : '只記$place。官方剩餘照常顯示；你的回報標成「車友回報」，地圖顯示 15 分鐘、詳情 30 分鐘後消失。需登入。';
}

String sightingRefusalText(
  SightingRefusal reason, {
  required bool street,
  required bool whole,
}) => switch (reason) {
  SightingRefusal.tooSoon =>
    '${whole
        ? '這裡'
        : street
        ? '這一段'
        : '這一區'} 10 分鐘內回報過了，請稍後再回報。',
  SightingRefusal.dailyLimit => '今天的回報次數已達上限，明天再回報。',
  SightingRefusal.spotGone => '這個地點的資料已更新，請重新打開後再回報。',
  SightingRefusal.signIn => '登入已失效，請重新登入後再回報。',
};

/// The places [s] may be reported on: those the vehicle may park in now
/// (A7, A7b 「只列你現在能停的」), empty when the spot stands as one. Null
/// when there is nothing the rider could report: not parkable, or nothing
/// open now.
List<SignArea>? sightingPlaces(FourSign s) {
  if (s.denied) return null;
  final open = [
    for (final a in s.areas)
      if (a.open) a,
  ];
  final now = [
    for (final a in open)
      if (a.window.now) a,
  ];
  if (open.isNotEmpty && now.isEmpty) return null;
  return [
    for (final a in now)
      if (a.id != null) a,
  ];
}

// 車友回報無法停車 (A7d) ---------------------------------------------------

enum ClosureLineTone {
  /// Amber: riders said so, but 能不能停 still reads from the data or the
  /// other places (A7d ①③⑤⑥).
  report,

  /// Red: riders closed the spot (A7d ②).
  closed,

  /// Grey: how a closure ends (A7d ④).
  info,
}

/// A line under 能不能停 about riders' reports that nobody can park.
class ClosureLine {
  const ClosureLine(this.text, this.tone);
  final String text;
  final ClosureLineTone tone;

  /// Read out with pauses, not the dot (A7d 朗讀).
  String get semantics => text.replaceAll('・', '，');
}

/// The lines under 能不能停 (A7d): once riders closed the spot, the
/// preview says by whom and the details how it ends (their verdict card
/// says by whom); otherwise one line for a report about the whole spot
/// and one for each place open to the vehicle that riders reported.
List<ClosureLine> closureLines(
  FourSign s,
  DateTime now, {
  required bool details,
}) {
  if (s.verdict.riderClosed case final c?) {
    return [
      details
          ? const ClosureLine(riderClosedLift, ClosureLineTone.info)
          : ClosureLine(riderClosedNote(c, now), ClosureLineTone.closed),
    ];
  }
  if (s.denied) return const [];
  return [
    if (s.closure case final c? when !c.confirmed)
      ClosureLine(riderClosedUnsure(c, now), ClosureLineTone.report),
    for (final a in s.areas)
      if (!a.whole && a.open)
        if (a.riderClosure case final c?)
          ClosureLine(
            '${detailPlaceName(a)}：${c.confirmed ? riderClosedCount(c, now) : riderClosedUnsure(c, now)}',
            ClosureLineTone.report,
          ),
  ];
}

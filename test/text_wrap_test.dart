import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motorcycle_parking/features/map/spot_preview.dart';
import 'package:motorcycle_parking/features/report/form_parts.dart';
import 'package:motorcycle_parking/models/parking.dart';
import 'package:motorcycle_parking/ui/adaptive/adaptive.dart';
import 'package:motorcycle_parking/ui/text_wrap.dart';

import 'spot_detail_fixtures.dart';
import 'spot_suggestions_test.dart' show createStore, openDetails;

/// #467: no lone last character in the suggestion list, and 臺北市中山區
/// kept on one line in the spot's subtitle, on the phone widths, text
/// sizes and themes the App supports.
const _widths = [360.0, 390.0, 411.0, 430.0];
const _scales = [1.0, 1.3, 2.0];

final _platforms = TargetPlatformVariant({
  TargetPlatform.iOS,
  TargetPlatform.android,
});

/// The lines [finder]'s paragraph lays its characters on, top to bottom.
List<String> _lines(WidgetTester tester, Finder finder) {
  final paragraph = tester.renderObject<RenderParagraph>(finder);
  final text = paragraph.text.toPlainText().replaceAll('\n', ' ');
  final byTop = <double, StringBuffer>{};
  for (var i = 0; i < text.length; i++) {
    final boxes = paragraph.getBoxesForSelection(
      TextSelection(baseOffset: i, extentOffset: i + 1),
    );
    if (boxes.isEmpty) continue;
    byTop
        .putIfAbsent(boxes.first.top.roundToDouble(), StringBuffer.new)
        .write(text[i]);
  }
  final tops = byTop.keys.toList()..sort();
  return [for (final top in tops) byTop[top].toString().trim()];
}

Future<void> _pumpText(WidgetTester tester, double width, Widget child) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: width, child: child),
        ),
      ),
    ),
  );
}

void main() {
  group('NoOrphanText', () {
    testWidgets('會剩一個字時把各行排平均，字不變', (tester) async {
      // 10 characters of 16 at 150 wide: 9 + 1 without it.
      await _pumpText(
        tester,
        150,
        const NoOrphanText('限時／禁停／共用時段', style: TextStyle(fontSize: 16)),
      );
      final lines = _lines(tester, find.byType(RichText));
      expect(lines, hasLength(2));
      expect(lines.last.length, greaterThan(1));
      expect(lines.join(), '限時／禁停／共用時段');
    });

    testWidgets('排平均仍剩一個字：前一行讓一個字下來，朗讀仍是原句', (tester) async {
      const value = '松壽路側車道下坡・3 區';
      final semantics = tester.ensureSemantics();
      // 3 lines only from 132 wide, and those end on 區 alone.
      await _pumpText(
        tester,
        140,
        const NoOrphanText(
          value,
          maxLines: 3,
          textAlign: TextAlign.end,
          style: TextStyle(fontSize: 26),
        ),
      );
      final lines = _lines(tester, find.byType(RichText));
      expect(lines, hasLength(3));
      expect(lines.last, '3 區');
      expect(find.bySemanticsLabel(value), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('放得下一行或最後一行不只一個字：不動', (tester) async {
      await _pumpText(
        tester,
        200,
        const NoOrphanText('限時／禁停／共用時段', style: TextStyle(fontSize: 16)),
      );
      expect(_lines(tester, find.byType(RichText)), hasLength(1));
      await _pumpText(
        tester,
        130,
        const NoOrphanText('限時／禁停／共用時段', style: TextStyle(fontSize: 16)),
      );
      // 8 + 2: already more than one on the last line.
      expect(
        tester.getSize(find.text('限時／禁停／共用時段')).width,
        greaterThanOrEqualTo(128),
      );
    });
  });

  group('KeepGroupsText', () {
    testWidgets('一組放不下就整組換行，朗讀仍是原句', (tester) async {
      const subtitle = '路外停車場（型式未提供）　臺北市中山區　500 m';
      final semantics = tester.ensureSemantics();
      // 12 + 1 + 6 characters of 13 do not fit 227.
      await _pumpText(
        tester,
        227,
        const KeepGroupsText(subtitle, style: TextStyle(fontSize: 13)),
      );
      final lines = _lines(tester, find.byType(RichText));
      expect(lines.first, '路外停車場（型式未提供）');
      expect(lines[1], startsWith('臺北市中山區'));
      expect(find.bySemanticsLabel(subtitle), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('放得下：原句一行，不插換行', (tester) async {
      const subtitle = '地下停車場　臺北市內湖區　330 m';
      await _pumpText(
        tester,
        400,
        const KeepGroupsText(subtitle, style: TextStyle(fontSize: 13)),
      );
      expect(find.text(subtitle), findsOneWidget);
    });

    testWidgets('一組本身比一行長：照常折行', (tester) async {
      const subtitle = '路外停車場（型式未提供）　臺北市中山區';
      await _pumpText(
        tester,
        100,
        const KeepGroupsText(subtitle, style: TextStyle(fontSize: 13)),
      );
      expect(tester.takeException(), isNull);
      expect(_lines(tester, find.byType(RichText)).join(), contains('臺北市中山區'));
    });
  });

  group('預覽卡副標（#467）', () {
    final lot = ParkingSpot.fromJson({
      ...detailLotJson,
      'district': '中山區',
      'facility_type': null,
    });

    for (final width in _widths) {
      for (final scale in _scales) {
        testWidgets('$width 寬字級 $scale：臺北市中山區不拆開', variant: _platforms, (
          tester,
        ) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = Size(width, 800);
          addTearDown(tester.view.reset);
          await tester.pumpWidget(
            MaterialApp(
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(scale)),
                // ignore: deprecated_member_use
                child: MaterialUiCompatibilityBridge(child: child!),
              ),
              home: Scaffold(
                body: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: SpotPreview(
                    spot: lot,
                    plates: const [],
                    subtitle: previewSubtitle(lot, meters: 500),
                    favorite: false,
                    onFavorite: () {},
                    onShare: (_) async {},
                    onClose: () {},
                  ),
                ),
              ),
            ),
          );
          expect(tester.takeException(), isNull);
          final lines = _lines(
            tester,
            find.descendant(
              of: find.byKey(const ValueKey('spot-subtitle')),
              matching: find.byType(RichText),
            ),
          );
          expect(
            lines.where((l) => l.contains('臺北市中山區')),
            hasLength(1),
            reason: '$lines',
          );
          expect(
            lines.where((l) => l.contains('500 m')),
            hasLength(1),
            reason: '$lines',
          );
        });
      }
    }
  });

  group('修改建議清單沒有孤字（#467）', () {
    for (final (name, spot) in [('路外', detailLot), ('路邊', detailStreet)]) {
      for (final width in _widths) {
        for (final scale in _scales) {
          for (final dark in [false, true]) {
            testWidgets(
              '$name $width 寬字級 $scale${dark ? ' 深色' : ''}',
              variant: _platforms,
              (tester) async {
                tester.view.devicePixelRatio = 1;
                tester.view.physicalSize = Size(width, 900);
                addTearDown(tester.view.reset);
                final store = (await tester.runAsync(createStore))!;
                addTearDown(store.dispose);
                store.spots = [spot];
                await openDetails(
                  tester,
                  store,
                  selectedSpot: spot,
                  scale: scale,
                  brightness: dark ? Brightness.dark : Brightness.light,
                );
                final rail = find.byKey(const ValueKey('spot-actions-rail'));
                if (rail.evaluate().isNotEmpty) {
                  await tester.drag(rail, const Offset(-900, 0));
                  await tester.pumpAndSettle();
                }
                await tester.tap(find.byKey(const ValueKey('spot-suggest')));
                await tester.pumpAndSettle();
                expect(tester.takeException(), isNull);
                final rows = find.byType(EntryRow).evaluate().toList();
                expect(rows, isNotEmpty);
                for (final e in rows) {
                  final row = e.widget as EntryRow;
                  for (final text in [row.title, ?row.value]) {
                    final found = find.descendant(
                      of: find.descendant(
                        of: find.byWidget(row),
                        matching: find.byWidgetPredicate(
                          (w) => w is NoOrphanText && w.data == text,
                        ),
                      ),
                      matching: find.byType(RichText),
                    );
                    if (found.evaluate().isEmpty) continue;
                    final lines = _lines(tester, found.first);
                    if (lines.length < 2) continue;
                    final paragraph = tester.renderObject<RenderParagraph>(
                      found.first,
                    );
                    // A value cut at its line limit ends in an ellipsis.
                    if (paragraph.didExceedMaxLines) continue;
                    expect(
                      lines.last.characters.length,
                      greaterThan(1),
                      reason: '「$text」$lines',
                    );
                  }
                }
                await tester.pumpWidget(const SizedBox.shrink());
              },
            );
          }
        }
      }
    }
  });
}

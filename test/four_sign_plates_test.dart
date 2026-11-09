import 'package:flutter_test/flutter_test.dart';
import 'package:motorcycle_parking/domain/four_sign.dart';
import 'package:motorcycle_parking/domain/four_sign_display.dart';
import 'package:motorcycle_parking/ui/adaptive/adaptive.dart';
import 'package:motorcycle_parking/ui/four_sign_plates.dart';

/// The plates of 「USPACE大直典華停車場」 (iPhone report, 2026-11-08):
/// 有沒有位 and 怎麼算錢 dashed, the others solid or outlined.
const _plates = [
  SignPlate(
    face: FourSignFace.verdict,
    main: '可以停',
    tone: PlateTone.allowed,
    semantics: '能不能停：可以停',
  ),
  SignPlate(
    face: FourSignFace.seat,
    main: '空位未知',
    tone: PlateTone.dashed,
    semantics: '有沒有位：空位未知',
  ),
  SignPlate(
    face: FourSignFace.fee,
    main: '未提供',
    tone: PlateTone.dashed,
    semantics: '怎麼算錢：未提供',
  ),
  SignPlate(
    face: FourSignFace.where,
    main: 'B2',
    tone: PlateTone.line,
    semantics: '停哪裡：B2',
  ),
];

void main() {
  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    for (final width in const [390.0, 820.0]) {
      for (final dark in [false, true]) {
        for (final dense in [true, false]) {
          final where =
              '${platform.name} ${width.toInt()} 寬 ${dark ? '深色' : '淺色'}'
              '${dense ? ' 目錄' : ''}';
          testWidgets('虛線畫在整塊路牌的外緣，不是框中框（$where）', (tester) async {
            tester.view.devicePixelRatio = 1;
            tester.view.physicalSize = Size(width, 600);
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            await tester.pumpWidget(
              MaterialApp(
                theme: ThemeData(
                  brightness: dark ? Brightness.dark : Brightness.light,
                ),
                home: Scaffold(
                  body: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        FourSignPlates(
                          plates: _plates,
                          dense: dense,
                          current: dense ? FourSignFace.verdict : null,
                          onTap: (_) {},
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
            expect(tester.takeException(), isNull);
            for (final face in FourSignFace.values) {
              final plate = find.byKey(ValueKey('four-sign-${face.name}'));
              final box = find.descendant(
                of: plate,
                matching: find.byKey(const ValueKey('four-sign-plate-box')),
              );
              final paint = tester.widget<CustomPaint>(box);
              final dashed = _plates[face.index].tone == PlateTone.dashed;
              expect(paint.foregroundPainter is DashedBorder, dashed);
              // The painted box is the whole plate: full width, and as
              // tall as the plate (less the 目錄's current bar).
              final boxRect = tester.getRect(box);
              final plateRect = tester.getRect(plate);
              expect(boxRect.width, moreOrLessEquals(plateRect.width));
              expect(
                boxRect.height,
                moreOrLessEquals(plateRect.height - (dense ? 8 : 0)),
              );
              expect(
                boxRect.height,
                greaterThanOrEqualTo(dense ? (isCupertino ? 44 : 48) : 64),
              );
              // Colours (A2 light, A4 dark): the table of contents' outlined
              // plates have no card; a known answer's outline is light.
              final tone = _plates[face.index].tone;
              final decoration =
                  tester
                          .widget<Container>(
                            find.descendant(
                              of: box,
                              matching: find.byType(Container),
                            ),
                          )
                          .decoration!
                      as BoxDecoration;
              if (tone == PlateTone.line || tone == PlateTone.dashed) {
                expect(
                  decoration.color,
                  dense ? Colors.transparent : PlateColors.paper,
                  reason: '$tone',
                );
              }
              if (tone == PlateTone.line || tone == PlateTone.dashed) {
                // The question (A2, A4): ink in the table of contents.
                final question = tester.widget<Text>(
                  find.descendant(
                    of: plate,
                    matching: find.text(_plates[face.index].question),
                  ),
                );
                expect(
                  question.style!.color,
                  dense
                      ? (dark ? PlateColors.darkInk : PlateColors.ink)
                      : PlateColors.muted,
                  reason: '$tone',
                );
              }
              if (tone == PlateTone.line) {
                final side = (decoration.border! as Border).top;
                expect(
                  side.color,
                  dense
                      ? (dark ? PlateColors.darkLine : PlateColors.line)
                      : PlateColors.ink,
                );
                expect(side.width, 1.5);
              }
              if (tone == PlateTone.dashed) {
                expect(
                  (paint.foregroundPainter! as DashedBorder).color,
                  dense && dark ? PlateColors.darkMuted : PlateColors.muted,
                );
              }
            }
          }, variant: TargetPlatformVariant({platform}));
        }
      }
    }
  }
}

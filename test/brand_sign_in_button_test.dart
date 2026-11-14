import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:motorcycle_parking/features/auth/brand_sign_in_button.dart';
import 'package:motorcycle_parking/features/auth/sign_in.dart';
import 'package:motorcycle_parking/ui/adaptive/adaptive.dart';

const _platforms = [TargetPlatform.iOS, TargetPlatform.android];

Future<void> _pump(
  WidgetTester tester, {
  required bool dark,
  double scale = 1,
  double width = 390,
  VoidCallback? onPressed,
  bool disabled = false,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 844);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: dark ? Brightness.dark : Brightness.light),
      home: MediaQuery.withClampedTextScaling(
        minScaleFactor: scale,
        maxScaleFactor: scale,
        child: Scaffold(
          body: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            // As SignInButtons lays them out.
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                BrandSignInButtonColumn(
                  children: [
                    for (final apple in [true, false])
                      ProviderSignInButton(
                        key: ValueKey(apple ? 'apple' : 'google'),
                        apple: apple,
                        label: apple ? '使用 Apple 登入' : '使用 Google 登入',
                        onPressed: disabled ? null : (onPressed ?? () {}),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

Material _surface(WidgetTester tester, String key) => tester.widget<Material>(
  find.descendant(
    of: find.byKey(ValueKey(key)),
    matching: find.byKey(const ValueKey('brand-sign-in-surface')),
  ),
);

Color? _labelColor(WidgetTester tester, String text) =>
    tester.widget<Text>(find.text(text)).style?.color;

void main() {
  for (final platform in _platforms) {
    final ios = platform == TargetPlatform.iOS;
    for (final dark in [false, true]) {
      final where = '${platform.name} ${dark ? '深色' : '淺色'}';
      testWidgets('品牌顏色、標誌與觸控高度（$where）', (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        await _pump(tester, dark: dark);

        // Apple (HIG): black with white on light, white with black on dark.
        final apple = _surface(tester, 'apple');
        final appleInk = dark ? const Color(0xff000000) : Colors.white;
        expect(apple.color, dark ? Colors.white : const Color(0xff000000));
        expect((apple.shape! as StadiumBorder).side, BorderSide.none);
        expect(_labelColor(tester, '使用 Apple 登入'), appleInk);
        expect(
          tester.widget<AppleLogo>(find.byType(AppleLogo)).color,
          appleInk,
        );

        // Google: white / #747775 / #1F1F1F, dark #131314 / #8E918F / #E3E3E3.
        final google = _surface(tester, 'google');
        expect(
          google.color,
          dark ? const Color(0xff131314) : const Color(0xffffffff),
        );
        final side = (google.shape! as StadiumBorder).side;
        expect(side.width, 1);
        expect(
          side.color,
          dark ? const Color(0xff8e918f) : const Color(0xff747775),
        );
        expect(
          _labelColor(tester, '使用 Google 登入'),
          dark ? const Color(0xffe3e3e3) : const Color(0xff1f1f1f),
        );
        expect(find.byType(GoogleLogo), findsOneWidget);

        // Official artwork only: no Material glyph stands in for a logo.
        expect(find.byIcon(Icons.apple), findsNothing);
        expect(find.byType(Icon), findsNothing);

        final target = ios ? 44.0 : 48.0;
        for (final key in ['apple', 'google']) {
          final size = tester.getSize(find.byKey(ValueKey(key)));
          expect(size.height, greaterThanOrEqualTo(target), reason: key);
        }
        // HIG: Apple's button is never smaller than the other one.
        expect(
          tester.getSize(find.byKey(const ValueKey('apple'))).height,
          greaterThanOrEqualTo(
            tester.getSize(find.byKey(const ValueKey('google'))).height,
          ),
        );
        debugDefaultTargetPlatformOverride = null;
      });
    }

    testWidgets('Apple 標誌依 HIG 比例，兩家標題同字級（${platform.name}）', (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      await _pump(tester, dark: false);
      final button = find.byKey(const ValueKey('apple'));
      final height = tester.getSize(button).height;
      // The logo file matches the button's height.
      final logo = tester.getSize(find.byType(AppleLogo));
      expect(logo.height, moreOrLessEquals(height));
      expect(logo.width, moreOrLessEquals(height * 31 / 44));
      // #467: both titles at the P11 size, Android 15, iOS 17.
      final apple = tester.widget<Text>(find.text('使用 Apple 登入')).style!;
      final google = tester.widget<Text>(find.text('使用 Google 登入')).style!;
      expect(apple.fontSize, ios ? 17 : 15);
      expect(google.fontSize, apple.fontSize);
      expect(
        tester.getSize(find.text('使用 Apple 登入')).height,
        lessThanOrEqualTo(tester.getSize(find.text('使用 Google 登入')).height),
      );
      // At least 8% of the width between the title and the trailing edge.
      final title = tester.getRect(find.text('使用 Apple 登入'));
      final rect = tester.getRect(button);
      expect(rect.right - title.right, greaterThanOrEqualTo(rect.width * .08));
      debugDefaultTargetPlatformOverride = null;
    });

    for (final width in const [320.0, 390.0]) {
      testWidgets('字放大 200% 不溢位（${platform.name} ${width.toInt()} 寬）', (
        tester,
      ) async {
        debugDefaultTargetPlatformOverride = platform;
        await _pump(tester, dark: false, scale: 2, width: width);
        expect(tester.takeException(), isNull);
        for (final (key, text) in [
          ('apple', '使用 Apple 登入'),
          ('google', '使用 Google 登入'),
        ]) {
          final button = tester.getRect(find.byKey(ValueKey(key)));
          final label = tester.getRect(find.text(text));
          expect(button.intersect(label), label, reason: '$key $button $label');
          expect(
            button.height,
            greaterThanOrEqualTo(ios ? 44 : 48),
            reason: key,
          );
        }
        debugDefaultTargetPlatformOverride = null;
      });
    }

    // Larger system text grows both buttons to one height (P11): Apple's
    // logo keeps the HIG proportion, both titles keep the one P11 size.
    for (final width in const [390.0, 820.0]) {
      for (final scale in const [1.0, 1.15, 1.5, 2.0]) {
        testWidgets('兩家按鈕同高（${platform.name} ${width.toInt()} 寬，字級 $scale）', (
          tester,
        ) async {
          debugDefaultTargetPlatformOverride = platform;
          await _pump(tester, dark: false, scale: scale, width: width);
          expect(tester.takeException(), isNull);
          final apple = tester.getSize(find.byKey(const ValueKey('apple')));
          final google = tester.getSize(find.byKey(const ValueKey('google')));
          expect(apple.height, moreOrLessEquals(google.height));
          // The logo file is drawn at the height the text scale sets
          // (HIG proportion); a wrapped title may make the button taller.
          final base = ios ? 44.0 : 48.0;
          final shared = scale * base > base ? scale * base : base;
          expect(
            tester.getSize(find.byType(AppleLogo)).height,
            moreOrLessEquals(shared),
          );
          expect(apple.height, greaterThanOrEqualTo(shared - .01));
          // One type size for both, not scaled to the height (#467).
          for (final text in ['使用 Apple 登入', '使用 Google 登入']) {
            expect(
              tester.widget<Text>(find.text(text)).style!.fontSize,
              ios ? 17 : 15,
              reason: text,
            );
          }
          debugDefaultTargetPlatformOverride = null;
        });
      }
    }

    testWidgets('點按回呼與停用狀態（${platform.name}）', (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      var taps = 0;
      await _pump(tester, dark: false, onPressed: () => taps++);
      await tester.tap(find.byKey(const ValueKey('apple')));
      await tester.tap(find.byKey(const ValueKey('google')));
      expect(taps, 2);
      await _pump(tester, dark: false, disabled: true);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('apple')),
          matching: find.byType(Opacity),
        ),
        findsOneWidget,
      );
      debugDefaultTargetPlatformOverride = null;
    });
  }

  group('品牌素材', () {
    String svgPaths(String file) => [
      for (final m in RegExp(
        r' d="(M[^"]*)"',
      ).allMatches(File(file).readAsStringSync()))
        m[1]!,
    ].join('|');

    test('Apple 標誌路徑與 Apple Design Resources 原檔一致', () {
      for (final file in [
        'assets/brand/apple/siwa-left-aligned-white-medium.svg',
        'assets/brand/apple/siwa-left-aligned-black-medium.svg',
      ]) {
        expect(svgPaths(file), appleLogoPath, reason: file);
        expect(File(file).readAsStringSync(), contains('viewBox="0 0 31 44"'));
      }
      // The logo sits inside its 31×44 frame with Apple's padding.
      final bounds = parseSvgPath(appleLogoPath).getBounds();
      expect(bounds.left, closeTo(7.75, .01));
      expect(bounds.top, closeTo(10.5, .01));
      expect(bounds.right, lessThan(appleLogoWidth));
      expect(bounds.bottom, closeTo(29.5, .01));
    });

    test('Google G 路徑與 P11 素材一致', () {
      expect(
        svgPaths('assets/brand/google/g-logo.svg'),
        [for (final (_, d) in googleLogoPaths) d].join('|'),
      );
      expect(
        [for (final (c, _) in googleLogoPaths) c],
        const [
          Color(0xffea4335),
          Color(0xff4285f4),
          Color(0xfffbbc05),
          Color(0xff34a853),
        ],
      );
      final all = [
        for (final (_, d) in googleLogoPaths) parseSvgPath(d).getBounds(),
      ].reduce((a, b) => a.expandToInclude(b));
      expect(all.left, closeTo(0, .01));
      expect(all.top, closeTo(0, .01));
      expect(all.right, closeTo(46.5, .01));
      expect(all.bottom, closeTo(48, .01));
    });
  });
}

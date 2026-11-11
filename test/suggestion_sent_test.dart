// #403 (S6, S6b): a suggestion sent comes back to the list, which says what
// went and asks what else to change; 完成 closes with a toast.
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:motorcycle_parking/data/app_store.dart';
import 'package:motorcycle_parking/data/repositories.dart';
import 'package:motorcycle_parking/domain/suggestion_display.dart';
import 'package:motorcycle_parking/features/contribute/my_contributions_page.dart';
import 'package:motorcycle_parking/features/report/entry_pages.dart';
import 'package:motorcycle_parking/features/report/form_parts.dart';
import 'package:motorcycle_parking/features/report/spot_suggestions.dart';
import 'package:motorcycle_parking/models/parking.dart';
import 'package:motorcycle_parking/models/parking_condition.dart';
import 'package:motorcycle_parking/ui/adaptive/adaptive.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show FunctionsFetchException;

class _Store extends AppStore {
  _Store(LocalRepository local) : super(local, null);
  final sent = <Map<String, dynamic>>[];
  Object? refuse;
  bool example = false;

  @override
  bool get demo => example;

  @override
  bool get canReport => true;

  @override
  Future<String> submit(Map<String, dynamic> body) async {
    if (refuse case final e?) throw e;
    sent.add(body);
    return '已送交審核';
  }
}

const _lot = ParkingSpot(
  id: 'official:lot',
  name: '松壽地下停車場',
  lat: 25.03,
  lng: 121.56,
  city: '臺北市',
  spaceType: SpaceType.offStreet,
  source: 'official',
  entranceNote: '松壽路側車道下坡',
  zones: [
    ParkingZone(
      id: 'b1',
      name: 'B1 機車區',
      access: ParkingAccess.scooterOnly,
      condition: ParkingCondition(
        bay: Bay.motorcycle,
        use: BayUse.usual,
        allow: ZoneAllow(scooter: true, heavy: false),
      ),
    ),
  ],
);

const _street = ParkingSpot(
  id: 'official:street',
  name: '南京東路三段路邊機車格',
  lat: 25.05,
  lng: 121.54,
  city: '臺北市',
  spaceType: SpaceType.paidMotorcycle,
  source: 'official',
);

Future<_Store> _open(
  WidgetTester tester,
  ParkingSpot spot, {
  Size size = const Size(390, 844),
  double scale = 1,
  Brightness brightness = Brightness.light,
  bool router = false,
  bool portal = false,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final store = (await tester.runAsync(() async {
    SharedPreferences.setMockInitialValues({});
    return _Store(LocalRepository(await SharedPreferences.getInstance()));
  }))!;
  addTearDown(store.dispose);
  Widget bridge(BuildContext context, Widget? child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    // ignore: deprecated_member_use
    child: MaterialUiCompatibilityBridge(child: child!),
  );
  final opener = Builder(
    builder: (context) => TextButton(
      onPressed: () => showSpotSuggestions(context, store, spot),
      child: const Text('開啟'),
    ),
  );
  final home = Scaffold(
    // The map's details: a portal into the root overlay, over the scaffold
    // and down to the foot of the page.
    body: portal ? _Details(child: opener) : opener,
  );
  final theme = ThemeData(brightness: brightness);
  if (router) {
    final routes = GoRouter(
      routes: [
        GoRoute(path: '/', builder: (_, _) => home),
        GoRoute(
          path: myContributionsPath,
          builder: (_, _) => const Scaffold(body: Text('我送出的建議頁')),
        ),
      ],
    );
    addTearDown(routes.dispose);
    await tester.pumpWidget(
      MaterialApp.router(theme: theme, builder: bridge, routerConfig: routes),
    );
  } else {
    await tester.pumpWidget(
      MaterialApp(theme: theme, builder: bridge, home: home),
    );
  }
  await tester.tap(find.text('開啟'));
  await tester.pumpAndSettle();
  return store;
}

/// Taps [target] after scrolling it to the middle of its list, clear of the
/// sheet's header and the bar pinned at its foot.
Future<void> _tap(WidgetTester tester, Finder target) async {
  await Scrollable.ensureVisible(tester.element(target), alignment: .5);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

/// Scrolls the open form to its send button, which a long form or large
/// text builds only once in view, and taps it.
Future<void> _send(WidgetTester tester, [String label = '送出修改建議']) async {
  await tester.pumpAndSettle();
  final button = find.text(label);
  await tester.scrollUntilVisible(
    button,
    200,
    scrollable: find
        .descendant(
          of: find.byType(Form).last,
          matching: find.byType(Scrollable),
        )
        .first,
  );
  await _tap(tester, button);
}

final _toast = find.byKey(const ValueKey('suggestions-sent-toast'));

/// The toast is on screen, over whatever else is, and fits it.
void _expectToast(WidgetTester tester, Size size) {
  expect(_toast.hitTestable(), findsOneWidget);
  final rect = tester.getRect(_toast);
  expect(rect.left, greaterThanOrEqualTo(0));
  expect(rect.right, lessThanOrEqualTo(size.width));
  expect(rect.bottom, lessThanOrEqualTo(size.height));
  expect(rect.width, lessThanOrEqualTo(560));
}

/// Puts the toast away, as a tap does, so its timer does not outlive the
/// test.
Future<void> _closeToast(WidgetTester tester) async {
  await tester.tapAt(tester.getTopLeft(_toast) + const Offset(24, 12));
  await tester.pump();
  expect(_toast, findsNothing);
}

/// Stands in for the map's details, which stay open under the list: drawn
/// in the root overlay, over the page's scaffold.
class _Details extends StatefulWidget {
  const _Details({required this.child});
  final Widget child;

  @override
  State<_Details> createState() => _DetailsState();
}

class _DetailsState extends State<_Details> {
  final portal = OverlayPortalController()..show();

  @override
  Widget build(BuildContext context) => OverlayPortal(
    controller: portal,
    overlayLocation: OverlayChildLocation.rootOverlay,
    overlayChildBuilder: (_) => Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      height: 420,
      child: Material(
        key: const ValueKey('details'),
        child: Center(child: widget.child),
      ),
    ),
    child: const SizedBox.expand(),
  );
}

Future<void> _tapKey(WidgetTester tester, String key) =>
    _tap(tester, find.byKey(ValueKey(key)));

/// Sends a new name from the list.
Future<void> _sendName(WidgetTester tester, [String name = '松壽公園地下停車場']) async {
  await _tap(tester, find.text('名稱'));
  await tester.enterText(find.byKey(const ValueKey('suggestion-input')), name);
  await _send(tester);
}

/// Sends a note from the list.
Future<void> _sendNote(WidgetTester tester) async {
  await _tapKey(tester, 'suggest-note');
  await tester.enterText(
    find.byKey(const ValueKey('suggestion-input')),
    '夜間有管理員，假日常客滿',
  );
  await _send(tester);
}

/// Sends one change of a zone, from the pages of 停哪裡.
Future<void> _sendZone(WidgetTester tester) async {
  await _tapKey(tester, 'suggest-where');
  await _tap(tester, find.text('B1 機車區').last);
  await _tapKey(tester, 'entry-heavy-allowed');
  await _tap(tester, find.widgetWithText(AdaptiveButton, '送出 1 項建議'));
}

/// The row [key] carries 已送出，審核中.
bool _marked(WidgetTester tester, String key) => find
    .descendant(of: find.byKey(ValueKey(key)), matching: find.byType(SentTag))
    .evaluate()
    .isNotEmpty;

Finder _row(String title) =>
    find.ancestor(of: find.text(title), matching: find.byType(EntryRow));

void main() {
  test('確認區：一項寫項目，多項寫件數並列出', () {
    expect(suggestionSentTitle(['費率']), '「費率」的建議已送出');
    expect(suggestionSentBody(['費率']), '管理員審核通過後才會更新地圖。');
    expect(suggestionSentTitle(['名稱', '費率', '分區與格位']), '已送出 3 項建議');
    expect(
      suggestionSentBody(['名稱', '費率', '分區與格位']),
      '名稱、費率、分區與格位。管理員審核通過後才會更新地圖。',
    );
    expect(suggestionSentTitle(['費率'], demo: true), '範例：已模擬送出「費率」的建議');
    expect(suggestionSentTitle(['名稱', '費率'], demo: true), '範例：已模擬送出 2 項建議');
    expect(
      suggestionSentBody(['名稱', '費率'], demo: true),
      '名稱、費率。範例模式：建議沒有實際送出，只用來測試流程。',
    );
    expect(SuggestionItem.where.label(street: true), '路段與格位');
    expect(SuggestionItem.where.label(street: false), '分區與格位');
  });

  test('送出失敗：收不到回應算沒有網路，伺服器退回寫原因，其餘請稍後再試', () {
    final offline = SendProblem.of(
      const FunctionsFetchException(details: 'Failed host lookup'),
    );
    expect(offline.offline, isTrue);
    expect(offline.title, '目前沒有網路，建議沒有送出');
    expect(offline.body('送出修改建議'), '你填的內容還在。連上網路後，再按一次「送出修改建議」。');
    final failed = SendProblem.of(Exception('500'));
    expect(failed.offline, isFalse);
    expect(failed.title, '建議沒有送出');
    expect(failed.body('送出 2 項建議'), '你填的內容還在。請稍後再按一次「送出 2 項建議」。');
    final refused = SendProblem.of(StateError('這個停車點已經不在地圖上。'));
    expect(refused.title, '建議沒有送出');
    expect(refused.body('送出修改建議'), '這個停車點已經不在地圖上。');
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    final ios = platform == TargetPlatform.iOS;
    group(platform.name, () {
      testWidgets('送出成功回到清單：確認區、問句、該列標記、完成', (tester) async {
        final store = await _open(tester, _lot);
        expect(find.byType(SentBanner), findsNothing);
        expect(find.text(suggestionDone), findsNothing);
        expect(find.text('哪一項跟現場不一樣？點進去改，右邊是地圖上目前寫的。'), findsOneWidget);
        final leading = find.byKey(const ValueKey('form-header-leading'));
        if (ios) {
          expect(
            find.descendant(of: leading, matching: find.text('取消')),
            findsOneWidget,
          );
        }

        await _sendName(tester);

        expect(store.sent, hasLength(1));
        // Back on the list, with no success page in between.
        expect(find.text('提出修改建議'), findsOneWidget);
        expect(find.byKey(const ValueKey('suggestion-input')), findsNothing);
        expect(find.text('「名稱」的建議已送出'), findsOneWidget);
        expect(find.text('管理員審核通過後才會更新地圖。'), findsOneWidget);
        expect(find.text(suggestionAskMore), findsOneWidget);
        expect(find.textContaining('哪一項跟現場不一樣'), findsNothing);
        expect(
          find.descendant(of: _row('名稱'), matching: find.byType(SentTag)),
          findsOneWidget,
        );
        expect(find.byType(SentTag), findsOneWidget);
        expect(find.text('已送出，審核中'), findsOneWidget);
        // The value beside it is still the map's.
        expect(
          find.descendant(of: _row('名稱'), matching: find.text(_lot.name)),
          findsOneWidget,
        );
        expect(find.widgetWithText(AdaptiveButton, '完成'), findsOneWidget);
        expect(find.text(suggestionDoneNote), findsOneWidget);
        // Nothing is left to cancel.
        if (ios) {
          expect(
            find.descendant(of: leading, matching: find.text('取消')),
            findsNothing,
          );
          expect(
            find.descendant(of: leading, matching: find.text('關閉')),
            findsOneWidget,
          );
        } else {
          expect(find.byTooltip('關閉'), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
      }, variant: TargetPlatformVariant({platform}));

      testWidgets('連續送出兩項：件數、項目與兩列標記；已送出的列可再點進去', (tester) async {
        final store = await _open(tester, _lot);
        await _sendName(tester);
        await _sendZone(tester);

        expect(store.sent, hasLength(2));
        expect(find.byType(FormFlow), findsOneWidget);
        expect(find.text('提出修改建議'), findsOneWidget);
        expect(find.text('已送出 2 項建議'), findsOneWidget);
        expect(find.text('名稱、分區與格位。管理員審核通過後才會更新地圖。'), findsOneWidget);
        expect(find.byType(SentBanner), findsOneWidget);
        expect(find.byType(SentTag), findsNWidgets(2));
        expect(_marked(tester, 'suggest-where'), isTrue);
        expect(_marked(tester, 'suggest-fee'), isFalse);

        // Sent again: the same row, still two items.
        await _sendName(tester, '松壽廣場地下停車場');
        expect(store.sent, hasLength(3));
        expect(find.text('已送出 2 項建議'), findsOneWidget);
        expect(find.byType(SentTag), findsNWidgets(2));
        expect(tester.takeException(), isNull);
      }, variant: TargetPlatformVariant({platform}));

      testWidgets('按完成關閉後顯示一次提示條；沒有送出就關閉則不顯示', (tester) async {
        await _open(tester, _lot);
        await tester.tap(find.byKey(const ValueKey('form-header-leading')));
        await tester.pumpAndSettle();
        expect(find.byType(FormFlow), findsNothing);
        expect(_toast, findsNothing);

        await tester.tap(find.text('開啟'));
        await tester.pumpAndSettle();
        // A new opening starts clean.
        expect(find.byType(SentBanner), findsNothing);
        await _sendName(tester);
        await _sendNote(tester);
        await tester.tap(find.widgetWithText(AdaptiveButton, '完成'));
        await tester.pumpAndSettle();
        expect(find.byType(FormFlow), findsNothing);
        expect(find.text('已送出 2 項建議，審核通過後會更新地圖'), findsOneWidget);
        _expectToast(tester, const Size(390, 844));
        // Without the app's router there is nowhere for 查看 to go.
        expect(find.text('查看'), findsNothing);
        // It goes by itself.
        await tester.pump(const Duration(seconds: 8));
        expect(_toast, findsNothing);

        // The marks were only that opening's.
        await tester.tap(find.text('開啟'));
        await tester.pumpAndSettle();
        expect(find.byType(SentBanner), findsNothing);
        expect(find.byType(SentTag), findsNothing);
        expect(tester.takeException(), isNull);
      }, variant: TargetPlatformVariant({platform}));

      testWidgets('提示條的「查看」開啟我送出的建議', (tester) async {
        await _open(tester, _lot, router: true);
        await _sendName(tester);
        await tester.tap(find.byKey(const ValueKey('form-header-leading')));
        await tester.pumpAndSettle();
        expect(find.text('已送出 1 項建議，審核通過後會更新地圖'), findsOneWidget);
        await tester.tap(find.text('查看'));
        await tester.pumpAndSettle();
        expect(find.text('我送出的建議頁'), findsOneWidget);
        expect(_toast, findsNothing);
        expect(tester.takeException(), isNull);
      }, variant: TargetPlatformVariant({platform}));

      for (final (size, scale, brightness) in const [
        (Size(390, 844), 1.0, Brightness.light),
        (Size(390, 844), 2.0, Brightness.dark),
        (Size(820, 1180), 1.0, Brightness.dark),
        (Size(820, 1180), 2.0, Brightness.light),
      ]) {
        final label =
            '${size.width.toInt()}×${size.height.toInt()}、$scale 倍、${brightness.name}';
        testWidgets('地圖詳情蓋在頁面上時，提示條與「查看」仍在最上層：$label', (tester) async {
          await _open(
            tester,
            _lot,
            size: size,
            scale: scale,
            brightness: brightness,
            router: true,
            portal: true,
          );
          await _sendName(tester);
          await _tap(tester, find.widgetWithText(AdaptiveButton, '完成'));
          // The details are still there, over the scaffold, and the toast
          // is over them.
          expect(find.byKey(const ValueKey('details')), findsOneWidget);
          expect(find.byType(SnackBar), findsNothing);
          _expectToast(tester, size);
          final toast = tester.widget<Material>(_toast);
          final colors = Theme.of(tester.element(_toast)).colorScheme;
          expect(toast.color, colors.inverseSurface);
          final view = find.byKey(const ValueKey('suggestions-sent-view'));
          expect(view.hitTestable(), findsOneWidget);
          expect(
            tester.getSize(view).height,
            greaterThanOrEqualTo(platform == TargetPlatform.iOS ? 44 : 48),
          );
          expect(tester.takeException(), isNull);
          await tester.tap(view);
          await tester.pumpAndSettle();
          expect(find.text('我送出的建議頁'), findsOneWidget);
          expect(_toast, findsNothing);
          expect(tester.takeException(), isNull);
        }, variant: TargetPlatformVariant({platform}));
      }

      testWidgets('「這裡已經不能停車」送出後不詢問，完成即關閉修改建議', (tester) async {
        final store = await _open(tester, _lot);
        await _tapKey(tester, 'suggest-gone');
        await _tapKey(tester, 'gone-removed');
        await _send(tester, '送出回報');
        expect(store.sent.single['field'], 'gone');
        // Its own success page, not the list's question.
        expect(find.text('回報已送出。確認後，這個停車點會從地圖移除。'), findsOneWidget);
        expect(find.text(suggestionAskMore), findsNothing);
        await tester.tap(find.widgetWithText(AdaptiveButton, '完成'));
        await tester.pumpAndSettle();
        expect(find.byType(FormFlow), findsNothing);
        expect(find.text('提出修改建議'), findsNothing);
        expect(find.byType(SnackBar), findsNothing);
        expect(tester.takeException(), isNull);
      }, variant: TargetPlatformVariant({platform}));

      testWidgets('送出失敗留在表單、內容還在，錯誤在送出按鈕上方；重送成功回清單', (tester) async {
        final store = await _open(tester, _lot);
        store.refuse = Exception('500');
        await _sendName(tester);

        expect(store.sent, isEmpty);
        final input = find.byKey(const ValueKey('suggestion-input'));
        expect(
          tester.widget<TextFormField>(input).controller!.text,
          '松壽公園地下停車場',
        );
        final note = find.byType(SendProblemNote);
        expect(note, findsOneWidget);
        expect(find.byKey(const ValueKey('send-failed')), findsOneWidget);
        expect(find.text('建議沒有送出'), findsOneWidget);
        expect(find.text('你填的內容還在。請稍後再按一次「送出修改建議」。'), findsOneWidget);
        final button = find.widgetWithText(AdaptiveButton, '送出修改建議');
        expect(
          tester.getRect(note).bottom,
          lessThanOrEqualTo(tester.getRect(button).top),
        );
        expect(tester.getSemantics(note), isSemantics(isLiveRegion: true));

        // No answer at all reads as no network, with its own icon.
        store.refuse = const FunctionsFetchException(details: 'offline');
        await _tap(tester, button);
        expect(find.byKey(const ValueKey('send-offline')), findsOneWidget);
        expect(find.byKey(const ValueKey('send-failed')), findsNothing);
        expect(find.text('目前沒有網路，建議沒有送出'), findsOneWidget);
        expect(find.text('你填的內容還在。連上網路後，再按一次「送出修改建議」。'), findsOneWidget);
        expect(
          tester.widget<TextFormField>(input).controller!.text,
          '松壽公園地下停車場',
        );

        store.refuse = null;
        await _tap(tester, button);
        expect(store.sent, hasLength(1));
        expect(find.text('「名稱」的建議已送出'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }, variant: TargetPlatformVariant({platform}));

      testWidgets('流程頁送出失敗固定在送出列，不用提示條；先前送出的項目不受影響', (tester) async {
        final store = await _open(tester, _lot);
        await _sendName(tester);
        store.refuse = const FunctionsFetchException(details: 'offline');
        await _sendZone(tester);

        expect(store.sent, hasLength(1));
        expect(find.byType(SnackBar), findsNothing);
        final note = find.byType(SendProblemNote);
        expect(
          find.descendant(of: find.byType(SubmitBar), matching: note),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('send-offline')), findsOneWidget);
        expect(find.text('你填的內容還在。連上網路後，再按一次「送出 1 項建議」。'), findsOneWidget);
        final button = find.widgetWithText(AdaptiveButton, '送出 1 項建議');
        expect(button, findsOneWidget);
        expect(
          tester.getRect(note).bottom,
          lessThanOrEqualTo(tester.getRect(button).top),
        );

        // A refusal says why in the server's words.
        store.refuse = StateError('這個停車點已經不在地圖上。');
        await _tap(tester, button);
        expect(find.byKey(const ValueKey('send-failed')), findsOneWidget);
        expect(find.text('這個停車點已經不在地圖上。'), findsOneWidget);

        // Back at the list the earlier item is as it was; this one is not
        // marked.
        final flow = tester.state<NavigatorState>(
          find.descendant(
            of: find.byType(FormFlow),
            matching: find.byType(Navigator),
          ),
        );
        flow.popUntil((route) => route.isFirst);
        await tester.pumpAndSettle();
        expect(find.text('「名稱」的建議已送出'), findsOneWidget);
        expect(find.byType(SentTag), findsOneWidget);
        expect(_marked(tester, 'suggest-where'), isFalse);
        expect(tester.takeException(), isNull);
      }, variant: TargetPlatformVariant({platform}));

      testWidgets('路邊：只看過沒送出的列不標記，送出的那列才標', (tester) async {
        final store = await _open(tester, _street);
        await _tapKey(tester, 'suggest-limits');
        await tester.tap(find.byKey(const ValueKey('form-header-leading')));
        await tester.pumpAndSettle();
        expect(find.byType(SentBanner), findsNothing);
        await _sendNote(tester);
        expect(store.sent, hasLength(1));
        expect(find.text('「其他備註」的建議已送出'), findsOneWidget);
        expect(_marked(tester, 'suggest-note'), isTrue);
        expect(_marked(tester, 'suggest-limits'), isFalse);
        expect(tester.takeException(), isNull);
      }, variant: TargetPlatformVariant({platform}));

      for (final (size, scale) in const [
        (Size(390, 844), 1.0),
        (Size(390, 844), 2.0),
        (Size(320, 640), 2.0),
        (Size(820, 1180), 2.0),
      ]) {
        final label = '${size.width.toInt()}×${size.height.toInt()}、$scale 倍';
        testWidgets('範例模式：寫「已模擬送出」與「範例，未實際送出」，不寫已送出（$label）', (tester) async {
          final store = await _open(tester, _lot, size: size, scale: scale);
          store.example = true;
          await _sendName(tester);
          expect(find.text('範例：已模擬送出「名稱」的建議'), findsOneWidget);
          expect(find.text(suggestionDemoNote), findsOneWidget);
          expect(
            find.descendant(of: _row('名稱'), matching: find.text('範例，未實際送出')),
            findsOneWidget,
          );
          expect(find.textContaining('的建議已送出'), findsNothing);
          expect(find.text('已送出，審核中'), findsNothing);
          expect(find.text(suggestionDoneNote), findsNothing);
          expect(tester.takeException(), isNull);

          await _sendZone(tester);
          expect(find.text('範例：已模擬送出 2 項建議'), findsOneWidget);
          expect(find.text('名稱、分區與格位。$suggestionDemoNote'), findsOneWidget);
          expect(find.text('範例，未實際送出'), findsNWidgets(2));
          expect(find.textContaining('已送出 2 項建議'), findsNothing);
          expect(tester.takeException(), isNull);

          await _tap(tester, find.widgetWithText(AdaptiveButton, '完成'));
          expect(find.text(suggestionDemoNote), findsOneWidget);
          expect(find.textContaining('審核通過後會更新地圖'), findsNothing);
          expect(find.text('查看'), findsNothing);
          _expectToast(tester, size);
          expect(tester.takeException(), isNull);
          await _closeToast(tester);
        }, variant: TargetPlatformVariant({platform}));
      }

      for (final (size, scale, brightness) in const [
        (Size(320, 640), 1.0, Brightness.light),
        (Size(390, 844), 1.0, Brightness.light),
        (Size(390, 844), 1.0, Brightness.dark),
        (Size(390, 844), 2.0, Brightness.light),
        (Size(390, 844), 2.0, Brightness.dark),
        (Size(700, 1000), 1.0, Brightness.light),
        (Size(820, 1180), 1.0, Brightness.light),
        (Size(820, 1180), 2.0, Brightness.dark),
        (Size(1040, 800), 1.0, Brightness.light),
      ]) {
        final label =
            '${size.width.toInt()}×${size.height.toInt()}、$scale 倍、${brightness.name}';
        testWidgets('送出後的清單、提示條與失敗說明在 $label 不溢出', (tester) async {
          final store = await _open(
            tester,
            _lot,
            size: size,
            scale: scale,
            brightness: brightness,
          );
          await _sendName(tester);
          expect(tester.takeException(), isNull);
          await _sendZone(tester);
          expect(tester.takeException(), isNull);
          expect(find.text('已送出 2 項建議'), findsOneWidget);
          expect(find.byType(SentTag), findsNWidgets(2));

          // The mark and the banner keep to the colours of 審核中.
          final (back, ink) = brightness == Brightness.dark
              ? (const Color(0xff16343c), const Color(0xff9fe0ec))
              : (const Color(0xffe3f0f2), const Color(0xff0f4e5c));
          final tag = tester.widget<DecoratedBox>(
            find
                .descendant(
                  of: find.byType(SentTag).first,
                  matching: find.byType(DecoratedBox),
                )
                .first,
          );
          expect((tag.decoration as BoxDecoration).color, back);
          expect(
            tester.widget<Text>(find.text('已送出，審核中').first).style!.color,
            ink,
          );

          // Large text stacks the map's value under the title (S6d ②).
          final name = _row('名稱');
          final title = tester.getRect(
            find.descendant(of: name, matching: find.text('名稱')),
          );
          final value = tester.getRect(
            find.descendant(of: name, matching: find.text(_lot.name)),
          );
          expect(value.top >= title.bottom, scale > 1.25);

          // 完成 keeps its touch target and stays on screen.
          final done = find.widgetWithText(AdaptiveButton, '完成');
          expect(tester.getSize(done).height, greaterThanOrEqualTo(48));
          expect(tester.getRect(done).bottom, lessThanOrEqualTo(size.height));

          // A failure on a page and on a form.
          store.refuse = const FunctionsFetchException(details: 'offline');
          await _sendZone(tester);
          expect(find.byType(SendProblemNote), findsOneWidget);
          expect(tester.takeException(), isNull);
          tester
              .state<NavigatorState>(
                find.descendant(
                  of: find.byType(FormFlow),
                  matching: find.byType(Navigator),
                ),
              )
              .popUntil((route) => route.isFirst);
          await tester.pumpAndSettle();
          await _sendNote(tester);
          expect(find.byType(SendProblemNote), findsOneWidget);
          expect(tester.takeException(), isNull);
          // Leaves the form; its 取消 is further down a long form.
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
          expect(find.text('提出修改建議'), findsOneWidget);

          await _tap(tester, done);
          expect(find.byType(FormFlow), findsNothing);
          _expectToast(tester, size);
          expect(tester.takeException(), isNull);
          await _closeToast(tester);
        }, variant: TargetPlatformVariant({platform}));
      }
    });
  }
}

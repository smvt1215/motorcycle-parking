import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:motorcycle_parking/data/app_store.dart';
import 'package:motorcycle_parking/data/repositories.dart';
import 'package:motorcycle_parking/models/parking.dart';
import 'package:motorcycle_parking/models/spot_history.dart';
import 'package:motorcycle_parking/ui/adaptive/adaptive.dart';

import 'spot_details_test.dart'
    show detailScroll, facility, openDetails, showField, usePhone;

/// Answers `spot_history` with fixed rows, as the backend would.
class _HistoryRepository extends ParkingRepository {
  _HistoryRepository(this.rows) : super(null);
  final List<Map<String, dynamic>> rows;
  final asked = <String>[];

  @override
  Future<List<HistoryEntry>> history(String spotId) async {
    asked.add(spotId);
    return HistoryEntry.list(rows);
  }
}

final _rows = <Map<String, dynamic>>[
  {
    'at': '2026-10-27T01:12:00Z',
    'kind': 'report',
    'created': false,
    'changes': [
      {'field': 'fee', 'after': null},
      {'field': 'fee_note', 'after': '大型重機每次 40 元，隔日另計'},
    ],
  },
  {
    'at': '2026-10-20T07:40:00Z',
    'kind': 'import',
    'created': false,
    'changes': [
      {'field': 'address', 'after': '忠孝東路五段 1 號'},
      {'field': 'scooter_total', 'after': 150},
    ],
  },
  {
    'at': '2026-10-12T00:05:00Z',
    'kind': 'report',
    'created': false,
    // The spot no longer holds this text: only the kind is named.
    'changes': [
      {'field': 'entrance_note'},
    ],
  },
  {
    'at': '2026-09-30T02:00:00Z',
    'kind': 'import',
    'created': true,
    'changes': <Object>[],
  },
];

Future<AppStore> _store(ParkingRepository parking) async {
  SharedPreferences.setMockInitialValues({});
  return AppStore(
    LocalRepository(await SharedPreferences.getInstance()),
    null,
    parkingRepository: parking,
  );
}

void main() {
  test(
    'app entries: kinds as one title, values the spot still holds, no names',
    () {
      final entries = HistoryEntry.list([..._rows, 'not an entry']);
      expect(entries, hasLength(4));
      expect(entries[0].title(app: true), '費率');
      expect(entries[0].title(), '收費');
      expect(historySummary(entries[0]), '大型重機每次 40 元，隔日另計');
      expect(historySourceText(entries[0], official: true), '車友建議，管理員已確認');
      expect(entries[1].title(app: true), '地址、總格數');
      expect(historySummary(entries[1]), '地址改為「忠孝東路五段 1 號」；機車格改為 150 格');
      expect(historySourceText(entries[1], official: true), '政府公開資料更新');
      expect(historySummary(entries[2]), isEmpty);
      expect(entries[3].title(app: true), '建立點位');
    },
  );

  for (final (width, height) in [
    (320.0, 640.0),
    (390.0, 844.0),
    (402.0, 874.0),
  ]) {
    testWidgets('最近更新與更新紀錄面板（寬 $width）', (tester) async {
      usePhone(tester, width: width);
      tester.view.physicalSize = Size(width, height);
      final repo = _HistoryRepository(_rows);
      final store = (await tester.runAsync(() => _store(repo)))!;
      addTearDown(store.dispose);
      await openDetails(tester, store, facility());
      await showField(tester, '最近更新');
      expect(repo.asked, ['detail-facility']);
      expect(find.text('費率，2026-10-27'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('看更新紀錄'),
        80,
        scrollable: detailScroll,
      );
      final link = tester.getSize(
        find.byKey(const ValueKey('spot-history-open')),
      );
      expect(link.height, greaterThanOrEqualTo(40));
      await tester.tap(find.text('看更新紀錄'));
      await tester.pumpAndSettle();
      expect(find.text('更新紀錄'), findsOneWidget);
      expect(find.text('大型重機每次 40 元，隔日另計'), findsOneWidget);
      expect(find.text('2026-10-20・政府公開資料更新'), findsOneWidget);
      expect(find.text('入口與停車指引'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('只列最近 10 筆，不顯示回報者名稱。'),
        120,
        scrollable: find
            .descendant(
              of: find.byType(ContentPage),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(find.text('建立點位'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('沒有紀錄時最近更新沿用點位更新時間，不顯示連結', (tester) async {
    usePhone(tester);
    final store = (await tester.runAsync(
      () => _store(_HistoryRepository([])),
    ))!;
    addTearDown(store.dispose);
    await openDetails(tester, store, facility());
    await showField(tester, '最近更新');
    expect(find.textContaining('2026-10-12'), findsWidgets);
    expect(find.text('看更新紀錄'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('確認狀態只顯示最新一筆，其餘收進「還有 N 項」（決定 52）', (tester) async {
    usePhone(tester, width: 320);
    final store = (await tester.runAsync(
      () => _store(_HistoryRepository([])),
    ))!;
    addTearDown(store.dispose);
    final now = DateTime.now();
    final spot = ParkingSpot.fromJson({
      ...facility().toJson(),
      'source': 'community',
      'scooter_allowed': true,
      'heavy_allowed': false,
      'scooter_verified_at': now
          .subtract(const Duration(days: 3))
          .toIso8601String(),
      'heavy_verified_at': now
          .subtract(const Duration(days: 1))
          .toIso8601String(),
    });
    await openDetails(tester, store, spot);
    await showField(tester, '確認狀態');
    expect(find.textContaining('停放車種（大型重機）'), findsOneWidget);
    expect(find.textContaining('停放車種（普通機車）'), findsNothing);
    await tester.scrollUntilVisible(
      find.text('還有 1 項'),
      80,
      scrollable: detailScroll,
    );
    await tester.tap(find.text('還有 1 項'));
    await tester.pumpAndSettle();
    expect(find.textContaining('停放車種（普通機車）'), findsOneWidget);
    expect(find.text('收起'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

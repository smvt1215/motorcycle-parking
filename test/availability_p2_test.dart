import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:motorcycle_parking/data/app_store.dart';
import 'package:motorcycle_parking/data/availability_repository.dart';
import 'package:motorcycle_parking/data/repositories.dart';
import 'package:motorcycle_parking/domain/availability_display.dart';
import 'package:motorcycle_parking/domain/eligibility.dart';
import 'package:motorcycle_parking/domain/parking_decision.dart';
import 'package:motorcycle_parking/domain/map_viewport.dart';
import 'package:motorcycle_parking/models/availability.dart';
import 'package:motorcycle_parking/models/parking.dart';

import 'availability_fixtures.dart';

/// Counts the test hands out one read at a time.
class ScriptedSource extends AvailabilitySource {
  final reads = <Completer<Map<String, SpotAvailability>>>[];
  @override
  bool get enabled => true;
  @override
  Future<Map<String, SpotAvailability>> forSpots(List<ParkingSpot> spots) {
    final read = Completer<Map<String, SpotAvailability>>();
    reads.add(read);
    return read.future;
  }
}

/// Spots the test changes between loads.
class MovingParking extends ParkingRepository {
  MovingParking(this.current) : super(null);
  List<ParkingSpot> current;
  @override
  Future<ParkingResult> inViewport(MapViewport bounds) async =>
      ParkingResult(current);
}

Map<String, SpotAvailability> scooter(String spot, int available) => {
  spot: SpotAvailability([
    count(spot, AvailabilityVehicle.scooter, available: available),
  ]),
};

int? scooterCount(AppStore store, ParkingSpot spot) =>
    store.availabilityOf(spot).of(AvailabilityVehicle.scooter)?.available;

Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  final a = lotAt('official:aaaaaaaa-0000-4000-8000-000000000001', 0, 0);
  final b = lotAt('official:aaaaaaaa-0000-4000-8000-000000000002', 10, 10);
  final community = lotAt(
    '10000000-0000-4000-8000-000000000009',
    20,
    20,
    source: 'community',
  );

  group('viewport_availability', () {
    Map<String, dynamic> row(
      String spot,
      String vehicle,
      String status, {
      int? available,
      int? total = 80,
      DateTime? at,
    }) => {
      'spot_id': spot,
      'vehicle': vehicle,
      'total': total,
      'available': available,
      'status': status,
      'source_updated_at': (at ?? availabilityNow).toUtc().toIso8601String(),
      'fetched_at': availabilityNow.toUtc().toIso8601String(),
      'zero_since': null,
      'provider': '臺北市停管處',
      'fresh_seconds': 600,
      'delayed_seconds': 1200,
    };

    Future<(List<Object?>, Map<String, SpotAvailability>)> read(
      List<ParkingSpot> spots,
      List<Map<String, dynamic>> rows,
    ) async {
      final sent = <Object?>[];
      final client = SupabaseClient(
        'https://example.supabase.co',
        'anon',
        httpClient: MockClient((request) async {
          expect(request.url.path, endsWith('/rpc/viewport_availability'));
          sent.add(jsonDecode(request.body));
          return http.Response(
            jsonEncode(rows),
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }),
      );
      final result = await SupabaseAvailabilitySource(client).forSpots(spots);
      return (sent, result);
    }

    test('只送官方點；社群點永遠不會有官方「剩 N」', () async {
      final (sent, _) = await read([a, community, b], []);
      expect(sent, [
        {
          'p_spot_ids': [a.id, b.id],
        },
      ]);
      final (none, result) = await read([community], []);
      expect(none, isEmpty, reason: '沒有官方點就不呼叫');
      expect(result, isEmpty);
    });

    test('分批讀取，每批 300 點，不超過 API 1,000 列上限', () async {
      final many = [
        for (var i = 0; i < 350; i++)
          lotAt(
            'official:aaaaaaaa-0000-4000-8000-${i.toString().padLeft(12, '0')}',
            0,
            0,
          ),
      ];
      final (sent, _) = await read(many, []);
      expect(
        [
          for (final body in sent.cast<Map<String, dynamic>>())
            (body['p_spot_ids'] as List).length,
        ],
        [300, 50],
      );
    });

    test('0＝已滿；-9／缺值＝無即時資料；跨車種各自判斷', () async {
      final (_, result) = await read(
        [a, b],
        [
          row(a.id, 'scooter', 'fresh', available: 12),
          row(a.id, 'heavy', 'unavailable', total: 6),
          row(b.id, 'scooter', 'fresh', available: 0),
        ],
      );
      final lotA = result[a.id]!;
      expect(lotA.of(AvailabilityVehicle.scooter)!.available, 12);
      expect(
        lotA.of(AvailabilityVehicle.scooter)!.status(availabilityNow),
        AvailabilityStatus.fresh,
      );
      expect(
        lotA.of(AvailabilityVehicle.heavy)!.status(availabilityNow),
        AvailabilityStatus.unavailable,
      );
      final heavy = availabilityFact(
        a,
        lotA,
        VehicleType.heavy,
        decideParking(a, VehicleType.heavy, const [], now: availabilityNow),
        availabilityNow,
      );
      expect(heavy.count, isNull, reason: '機車 12 不能變成重機的數字');
      expect(heavy.headline, '無即時資料');
      final full = availabilityFact(
        b,
        result[b.id]!,
        VehicleType.scooter,
        decideParking(b, VehicleType.scooter, const [], now: availabilityNow),
        availabilityNow,
      );
      expect(full.count, 0);
      expect(full.headline, '剩餘，已滿');
    });

    test('後端判為異常時不顯示數字，也不算已滿', () async {
      final (_, result) = await read(
        [a],
        [row(a.id, 'scooter', 'invalid', available: 30, total: 20)],
      );
      final snap = result[a.id]!.of(AvailabilityVehicle.scooter)!;
      expect(snap.available, isNull);
      expect(snap.status(availabilityNow), AvailabilityStatus.invalid);
      final fact = availabilityFact(
        a,
        result[a.id]!,
        VehicleType.scooter,
        decideParking(a, VehicleType.scooter, const [], now: availabilityNow),
        availabilityNow,
      );
      expect(fact.count, isNull);
      expect(fact.headline, '空位未知');
    });

    test('30 分鐘沒有來源更新，剛抓到也不算新鮮', () async {
      final (_, result) = await read(
        [a],
        [
          row(
            a.id,
            'scooter',
            'stale',
            available: 12,
            at: availabilityNow.subtract(const Duration(minutes: 30)),
          ),
        ],
      );
      final snap = result[a.id]!.of(AvailabilityVehicle.scooter)!;
      expect(snap.fetchedAt!.isAtSameMomentAs(availabilityNow), isTrue);
      expect(snap.status(availabilityNow), AvailabilityStatus.stale);
      expect(
        availabilityExclusion(
          AvailabilityFilter.available,
          a,
          result[a.id]!,
          VehicleType.scooter,
          EligibilityStatus.allowed,
          availabilityNow,
        ),
        AvailabilityExclusion.stale,
        reason: '「目前有位」排除過期',
      );
    });

    test('看不懂的列不採用；來源時窗缺少時用臺北的', () {
      expect(availabilitySnapshotFromRow({'spot_id': a.id}), isNull);
      expect(
        availabilitySnapshotFromRow({
          ...row(a.id, 'bus', 'fresh', available: 1),
        }),
        isNull,
      );
      final snap = availabilitySnapshotFromRow({
        ...row(a.id, 'scooter', 'fresh', available: 1),
        'fresh_seconds': null,
      })!;
      expect(snap.window.fresh, AvailabilityWindow.taipei.fresh);
    });
  });

  group('AppStore 輪詢', () {
    Future<(AppStore, ScriptedSource, MovingParking)> make() async {
      SharedPreferences.setMockInitialValues({});
      final source = ScriptedSource();
      final parking = MovingParking([a]);
      final store = AppStore(
        LocalRepository(await SharedPreferences.getInstance()),
        null,
        parkingRepository: parking,
        availabilitySource: source,
        availabilityPoll: const Duration(minutes: 2),
        clock: () => availabilityNow,
      );
      return (store, source, parking);
    }

    test('只重讀剩餘數，不重載停車點；資料更新後通知畫面', () async {
      final (store, source, _) = await make();
      final loading = store.refresh();
      await settle();
      source.reads.last.complete(scooter(a.id, 12));
      await loading;
      final spots = store.spots;
      var notified = 0;
      store.addListener(() => notified++);
      final poll = store.pollAvailability();
      await settle();
      source.reads.last.complete(scooter(a.id, 9));
      await poll;
      expect(identical(store.spots, spots), isTrue, reason: '靜態點位沒有重載');
      expect(scooterCount(store, a), 9);
      expect(notified, 1);
      store.dispose();
    });

    test('地圖範圍改變後，舊的輪詢結果不覆蓋新結果', () async {
      final (store, source, parking) = await make();
      final first = store.refresh();
      await settle();
      source.reads.last.complete(scooter(a.id, 12));
      await first;
      final poll = store.pollAvailability();
      await settle();
      final stale = source.reads.last;
      parking.current = [b];
      final moved = store.refresh();
      await settle();
      source.reads.last.complete(scooter(b.id, 5));
      await moved;
      stale.complete(scooter(a.id, 1));
      await poll;
      expect(store.availability.keys, [b.id]);
      expect(scooterCount(store, b), 5);
      store.dispose();
    });

    test('讀取失敗保留上一筆並退避，成功後恢復', () async {
      final (store, source, _) = await make();
      final loading = store.refresh();
      await settle();
      source.reads.last.complete(scooter(a.id, 12));
      await loading;
      expect(store.availabilityDelay, const Duration(minutes: 2));
      for (final expected in [4, 8, 16, 20, 20]) {
        final poll = store.pollAvailability();
        await settle();
        source.reads.last.completeError(Exception('offline'));
        await poll;
        expect(scooterCount(store, a), 12, reason: '無網路仍顯示上一筆與靜態資料');
        expect(store.availabilityDelay, Duration(minutes: expected));
      }
      final poll = store.pollAvailability();
      await settle();
      source.reads.last.complete(scooter(a.id, 3));
      await poll;
      expect(store.availabilityDelay, const Duration(minutes: 2));
      store.dispose();
    });

    test('地圖範圍載入時剩餘數讀取失敗，留下仍在範圍內的上一筆', () async {
      final (store, source, parking) = await make();
      parking.current = [a, b];
      final first = store.refresh();
      await settle();
      source.reads.last.complete({...scooter(a.id, 12), ...scooter(b.id, 4)});
      await first;
      parking.current = [a];
      final moved = store.refresh();
      await settle();
      source.reads.last.completeError(Exception('offline'));
      await moved;
      expect(store.spots, [a]);
      expect(store.availability.keys, [a.id]);
      expect(store.error, isNull, reason: '靜態資料照常顯示');
      store.dispose();
    });

    test('背景與其他分頁不輪詢，回來時才補讀', () async {
      final (store, source, _) = await make();
      final loading = store.refresh();
      await settle();
      source.reads.last.complete(scooter(a.id, 12));
      await loading;
      final reads = source.reads.length;
      store.didChangeAppLifecycleState(AppLifecycleState.paused);
      store.setMapShown(false);
      store.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await settle();
      expect(source.reads.length, reads, reason: '地圖被其他分頁蓋住');
      store.setMapShown(true);
      await settle();
      expect(source.reads.length, reads, reason: '上次讀取未滿一個週期，等剩下的時間');
      store.dispose();
    });

    test('輪詢趕在範圍載入的讀取之前完成時，較舊的範圍讀取不覆蓋它', () async {
      final (store, source, _) = await make();
      final loading = store.refresh();
      await settle();
      final viewportRead = source.reads.last;
      final poll = store.pollAvailability();
      await settle();
      source.reads.last.complete(scooter(a.id, 9));
      await poll;
      viewportRead.complete(scooter(a.id, 12));
      await loading;
      expect(scooterCount(store, a), 9);
      store.dispose();
    });

    testWidgets('讀取退避時，地圖仍每分鐘重算新鮮度', (tester) async {
      final (store, source, _) = (await tester.runAsync(make))!;
      var reads = 0;
      final loading = store.refresh();
      await tester.pump();
      source.reads.last.complete(scooter(a.id, 12));
      await tester.pump();
      await loading;
      reads = source.reads.length;
      var notified = 0;
      store.addListener(() => notified++);
      await tester.pump(const Duration(minutes: 1, seconds: 1));
      expect(notified, 1, reason: '沒有網路讀取也重畫');
      expect(source.reads.length, reads);
      store.didChangeAppLifecycleState(AppLifecycleState.paused);
      await tester.pump(const Duration(minutes: 5));
      expect(notified, 1, reason: '背景不重畫也不讀取');
      expect(source.reads.length, reads);
      store.dispose();
    });

    test('連上後端預設用後端資料源與 2 分鐘輪詢；範例模式用固定資料不輪詢', () async {
      SharedPreferences.setMockInitialValues({});
      final local = LocalRepository(await SharedPreferences.getInstance());
      final connected = AppStore(
        local,
        SupabaseClient('https://example.supabase.co', 'anon'),
      );
      expect(connected.availabilitySource, isA<SupabaseAvailabilitySource>());
      expect(connected.availabilityPoll, AppStore.defaultAvailabilityPoll);
      final demo = AppStore(local, null);
      expect(demo.availabilitySource, isA<FakeAvailabilitySource>());
      expect(demo.availabilityPoll, isNull);
      connected.dispose();
      demo.dispose();
    });
  });
}

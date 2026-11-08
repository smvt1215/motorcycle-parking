import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:motorcycle_parking/api/v1/api_v1.g.dart' as v1 show SpotClosure;
import 'package:motorcycle_parking/api/v1/api_v1.g.dart' show SpotSighting;
import 'package:motorcycle_parking/core/app_check.dart';
import 'package:motorcycle_parking/data/account_suspended.dart';
import 'package:motorcycle_parking/data/app_store.dart';
import 'package:motorcycle_parking/data/availability_repository.dart';
import 'package:motorcycle_parking/data/repositories.dart';
import 'package:motorcycle_parking/data/sightings_repository.dart';
import 'package:motorcycle_parking/domain/availability_beta_display.dart';
import 'package:motorcycle_parking/domain/availability_display.dart';
import 'package:motorcycle_parking/domain/eligibility.dart';
import 'package:motorcycle_parking/domain/four_sign.dart';
import 'package:motorcycle_parking/domain/four_sign_display.dart';
import 'package:motorcycle_parking/domain/parking_decision.dart';
import 'package:motorcycle_parking/domain/rider_meter_display.dart';
import 'package:motorcycle_parking/domain/sighting_display.dart';
import 'package:motorcycle_parking/domain/spot_detail_display.dart';
import 'package:motorcycle_parking/features/account/suspended_sheet.dart';
import 'package:motorcycle_parking/features/auth/sign_in.dart';
import 'package:motorcycle_parking/features/favorites/favorite_card.dart';
import 'package:motorcycle_parking/features/map/availability_capsule.dart';
import 'package:motorcycle_parking/features/map/spot_detail.dart';
import 'package:motorcycle_parking/features/map/spot_preview.dart';
import 'package:motorcycle_parking/features/report/report_sheet.dart'
    show SignInPrompt;
import 'package:motorcycle_parking/models/availability.dart';
import 'package:motorcycle_parking/models/parking.dart';
import 'package:motorcycle_parking/models/sighting.dart';
import 'package:motorcycle_parking/ui/adaptive/adaptive.dart';
import 'package:motorcycle_parking/ui/four_sign_plates.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'spot_detail_fixtures.dart';
import 't280_harness.dart' show layouts, platforms, setUpView, testWidgetsOn;

const lotId = 'official:11111111-1111-4111-8111-111111111111';
const streetId = '22222222-2222-4222-8222-222222222222';

final lot = ParkingSpot.fromJson({...detailLotJson, 'id': lotId});
final street = ParkingSpot.fromJson({...detailStreetJson, 'id': streetId});

SpotSighting row(
  String spot, {
  String? zone,
  String? segment,
  String vehicle = 'heavy',
  int level = 1,
  int count = 2,
  int? low,
  int? high,
  int lowRiders = 2,
  int highRiders = 0,
  required DateTime at,
  bool conflicting = false,
}) => SpotSighting(
  spotId: spot,
  zoneId: zone,
  segmentId: segment,
  vehicle: vehicle,
  level: level,
  count: count,
  low: low ?? level,
  high: high ?? level,
  lowRiders: lowRiders,
  highRiders: highRiders,
  latestAt: at.toIso8601String(),
  conflicting: conflicting,
);

v1.SpotClosure closure(
  String spot, {
  String? zone,
  String? segment,
  int riders = 1,
  bool? confirmed,
  bool derived = false,
  required DateTime at,
}) => v1.SpotClosure(
  spotId: spot,
  zoneId: zone,
  segmentId: segment,
  riders: riders,
  confirmed: confirmed ?? riders >= 2,
  latestAt: at.toIso8601String(),
  derived: derived,
);

class FakeSightings extends SightingsSource {
  FakeSightings(this.rows);
  List<SpotSighting> rows;

  /// What riders reported closed (A7d), returned with every read.
  List<v1.SpotClosure> closures = const [];
  final windows = <int>[];
  final sent = <SightingReport>[];
  Object? failure;

  @override
  bool get enabled => true;

  @override
  Future<Map<String, List<SpotSighting>>> forSpots(
    List<ParkingSpot> spots, {
    required int windowMinutes,
  }) async {
    windows.add(windowMinutes);
    final ids = {for (final s in spots) s.id.toLowerCase()};
    return sightingsBySpot([
      for (final r in rows)
        if (ids.contains(r.spotId)) r,
    ]);
  }

  @override
  Future<SightingsRead> read(
    List<ParkingSpot> spots, {
    required int windowMinutes,
  }) async {
    final sightings = await forSpots(spots, windowMinutes: windowMinutes);
    final ids = {for (final s in spots) s.id.toLowerCase()};
    return SightingsRead(
      sightings,
      closuresBySpot([
        for (final c in closures)
          if (ids.contains(c.spotId)) c,
      ]),
    );
  }

  @override
  Future<void> submit(SightingReport report) async {
    if (failure case final error?) throw error;
    sent.add(report);
  }
}

/// Reads fail, as offline; what is already on the map stays.
class FailingReads extends FakeSightings {
  FailingReads(super.rows);
  @override
  Future<Map<String, List<SpotSighting>>> forSpots(
    List<ParkingSpot> spots, {
    required int windowMinutes,
  }) => Future.error(Exception('offline'));
}

/// Records the ids asked for; [fail] makes reads fail.
class RecordingSightings extends FakeSightings {
  RecordingSightings(this.seen, super.rows);
  final Set<String> seen;
  bool fail = false;
  @override
  Future<Map<String, List<SpotSighting>>> forSpots(
    List<ParkingSpot> spots, {
    required int windowMinutes,
  }) {
    if (fail) return Future.error(Exception('offline'));
    seen.addAll(spots.map((s) => s.id));
    return super.forSpots(spots, windowMinutes: windowMinutes);
  }
}

/// A session the backend stopped accepting, then a sign-in.
class ExpiredStore extends AppStore {
  ExpiredStore(super.local, super.client, {super.sightingsSource, super.clock});
  bool session = true;
  int ended = 0;
  @override
  bool get canReport => session;
  @override
  Future<void> endExpiredSession() async {
    ended++;
    session = false;
    notifyListeners();
  }

  void signedInAgain() {
    session = true;
    notifyListeners();
  }
}

/// Records the ids each read asks for.
class RecordingCounts extends AvailabilitySource {
  RecordingCounts(this.reads);
  final List<List<String>> reads;
  @override
  bool get enabled => true;
  @override
  Future<Map<String, SpotAvailability>> forSpots(
    List<ParkingSpot> spots,
  ) async {
    reads.add([for (final s in spots) s.id]);
    return const {};
  }
}

/// Counts that answer (with none), once [gate] completes while it is set.
class GatedCounts extends AvailabilitySource {
  Completer<void>? gate;
  @override
  bool get enabled => true;
  @override
  Future<Map<String, SpotAvailability>> forSpots(
    List<ParkingSpot> spots,
  ) async {
    await gate?.future;
    return const {};
  }
}

/// Once [stalled], reads never answer, as on a stalled connection.
class StalledReads extends FakeSightings {
  StalledReads(super.rows);
  bool stalled = false;
  @override
  Future<Map<String, List<SpotSighting>>> forSpots(
    List<ParkingSpot> spots, {
    required int windowMinutes,
  }) => stalled
      ? Completer<Map<String, List<SpotSighting>>>().future
      : super.forSpots(spots, windowMinutes: windowMinutes);
}

class GuestStore extends AppStore {
  GuestStore(super.local, super.client, {super.sightingsSource, super.clock});
  @override
  bool get canReport => false;
}

class Seats implements RiderSeats {
  const Seats(this.seats);
  final List<RiderSeat> seats;
  @override
  List<RiderSeat> of(String spotId) => seats;
}

Future<AppStore> sightedStore(
  WidgetTester tester,
  FakeSightings source, {
  DateTime? now,
  VehicleType vehicle = VehicleType.heavy,
  bool guest = false,
  AvailabilitySource? counts,
}) async {
  final at = now ?? detailDay;
  final store = (await tester.runAsync(() async {
    SharedPreferences.setMockInitialValues({'vehicle': vehicle.name});
    final local = LocalRepository(await SharedPreferences.getInstance());
    final s = guest
        ? GuestStore(local, null, sightingsSource: source, clock: () => at)
        : AppStore(
            local,
            null,
            sightingsSource: source,
            availabilitySource: counts,
            clock: () => at,
          );
    await s.init();
    return s;
  }))!;
  store.vehicle = vehicle;
  addTearDown(store.dispose);
  return store;
}

AvailabilitySnapshot count(
  AvailabilityVehicle vehicle, {
  required int available,
  int? total = 20,
  required DateTime at,
}) => AvailabilitySnapshot(
  spotId: lotId,
  vehicle: vehicle,
  provider: '官方',
  window: AvailabilityWindow.taipei,
  total: total,
  available: available,
  sourceUpdatedAt: at,
  fetchedAt: at,
);

Iterable<Size> sizesOf(WidgetTester tester, Finder finder) =>
    finder.evaluate().map((e) => tester.getSize(find.byWidget(e.widget)));

void main() {
  group('刻度轉換', () {
    test('後端 0 很多空位…3 已停滿，App 反過來，來回一致', () {
      expect([0, 1, 2, 3].map(riderLevelFromBackend), [3, 2, 1, 0]);
      expect([0, 1, 2, 3].map(backendLevelFromRider), [3, 2, 1, 0]);
      for (final level in [0, 1, 2, 3]) {
        expect(backendLevelFromRider(riderLevelFromBackend(level)), level);
      }
      // 後端 0 是很多空位，量表滿格。
      expect(riderLevelLabel(riderLevelFromBackend(0)), '很多空位');
      expect(riderLevelLabel(riderLevelFromBackend(3)), '已停滿');
    });

    test('一致的回報：用 level，帶人數、區與時間', () {
      final at = DateTime.utc(2026, 11, 3, 6, 12);
      final seat = riderSeatOf(row(lotId, zone: 'b2', level: 1, at: at))!;
      expect(seat.level, 2);
      expect(riderLabel(seat), '還有一些');
      expect(seat.conflict, isFalse);
      expect(seat.riders, 2);
      expect(seat.areaId, 'b2');
      expect(seat.at, at);
    });

    test('路段回報的區位是 segment_id，整點回報是 null', () {
      final at = DateTime.utc(2026, 11, 3);
      expect(riderSeatOf(row(lotId, segment: 's1', at: at))!.areaId, 's1');
      expect(riderSeatOf(row(lotId, at: at))!.areaId, isNull);
    });

    test('說法不一：不用中位數，low 是較空的一端，人數對應', () {
      final seat = riderSeatOf(
        row(
          lotId,
          level: 1,
          low: 0,
          high: 3,
          lowRiders: 2,
          highRiders: 1,
          count: 4,
          conflicting: true,
          at: DateTime.utc(2026, 11, 3),
        ),
      )!;
      expect(seat.conflict, isTrue);
      expect(riderMeters(seat), [3, 0]);
      expect(riderSplit(seat), '2 人說很多・1 人說滿');
      expect(
        riderMeterOf(seat),
        const RiderMeter.conflict(RiderLevel.plenty, RiderLevel.full),
      );
      expect(riderLabel(seat), '說法不一');
    });

    test('讀不懂的一筆不顯示，不猜', () {
      final at = DateTime.utc(2026, 11, 3);
      expect(riderSeatOf(row(lotId, level: 4, at: at)), isNull);
      expect(
        riderSeatOf(
          SpotSighting(
            spotId: lotId,
            vehicle: 'heavy',
            level: 1,
            count: 1,
            low: 1,
            high: 1,
            lowRiders: 1,
            highRiders: 1,
            latestAt: 'not a time',
            conflicting: false,
          ),
        ),
        isNull,
      );
    });

    test('送出時轉回後端刻度；無法停車不帶區與 level', () {
      expect(
        const SightingReport.level(
          spotId: lotId,
          vehicle: VehicleType.heavy,
          level: 3,
          zoneId: 'b2',
        ).toJson(),
        {
          'spot_id': lotId,
          'kind': 'level',
          'level': 0,
          'zone_id': 'b2',
          'segment_id': null,
          'vehicle': 'heavy',
        },
      );
      expect(
        const SightingReport.closed(
          spotId: streetId,
          vehicle: VehicleType.scooter,
        ).toJson(),
        {
          'spot_id': streetId,
          'kind': 'closed',
          'level': null,
          'zone_id': null,
          'segment_id': null,
          'vehicle': 'scooter',
        },
      );
    });
  });

  group('SupabaseSightingsSource', () {
    SupabaseClient client(http.Response Function(http.Request) answer) =>
        SupabaseClient(
          'https://example.supabase.co',
          'anon',
          httpClient: MockClient((request) async {
            final r = answer(request);
            return http.Response.bytes(
              r.bodyBytes,
              r.statusCode,
              headers: {'content-type': 'application/json'},
              request: request,
            );
          }),
        );

    ParkingSpot spotNumbered(int i) => ParkingSpot.fromJson({
      ...detailBayJson,
      'id': 'official:00000000-0000-4000-8000-${'$i'.padLeft(12, '0')}',
    });

    test('每批最多 600 個 id，全部送出；時窗照傳；略過不是 uuid 的 id', () async {
      final sent = <Map<String, dynamic>>[];
      final source = SupabaseSightingsSource(
        client((request) {
          expect(request.url.path, endsWith('/rpc/spot_sightings'));
          sent.add(jsonDecode(request.body) as Map<String, dynamic>);
          return http.Response('{"sightings":[],"closures":[]}', 200);
        }),
      );
      await source.forSpots([
        for (var i = 0; i < 1250; i++) spotNumbered(i),
        ParkingSpot.fromJson({...detailBayJson, 'id': 'tdx:1'}),
      ], windowMinutes: sightingMapWindow);
      final batches = [for (final b in sent) (b['p_spot_ids'] as List).length];
      expect(batches, [600, 600, 50]);
      expect(sent.map((b) => b['p_window_minutes']).toSet(), {15});
      expect(
        sent.expand((b) => b['p_spot_ids'] as List),
        isNot(contains('tdx:1')),
      );
    });

    test('沒有 id 就不呼叫；id 依小寫歸組', () async {
      var calls = 0;
      final source = SupabaseSightingsSource(
        client((_) {
          calls++;
          return http.Response(
            jsonEncode({
              'sightings': [row(lotId, at: DateTime.utc(2026, 11, 3)).toJson()],
              'closures': [
                closure(
                  lotId.toUpperCase(),
                  zone: 'b2',
                  at: detailDay,
                ).toJson(),
              ],
            }),
            200,
          );
        }),
      );
      expect(
        await source.forSpots(const [], windowMinutes: sightingDetailWindow),
        isEmpty,
      );
      expect(calls, 0);
      final read = await source.forSpots([
        lot,
      ], windowMinutes: sightingDetailWindow);
      expect(read[lotId], hasLength(1));
      final both = await source.read([lot], windowMinutes: sightingMapWindow);
      expect(both.sightings[lotId], hasLength(1));
      expect(both.closures[lotId]!.single.zoneId, 'b2');
    });

    group('寫入', () {
      SightingReport report() => const SightingReport.level(
        spotId: lotId,
        vehicle: VehicleType.heavy,
        level: 2,
        zoneId: 'b2',
      );

      SupabaseSightingsSource answering(
        int status,
        Object body, {
        void Function(http.Request)? seen,
      }) => SupabaseSightingsSource(
        client((request) {
          seen?.call(request);
          return http.Response(jsonEncode(body), status);
        }),
        appCheckToken: () async => 'token',
      );

      setUp(() => SharedPreferences.setMockInitialValues({'device_id': 'd1'}));

      test('帶 App Check header 與裝置 id', () async {
        late http.Request request;
        await answering(200, {
          'accepted': true,
        }, seen: (r) => request = r).submit(report());
        expect(request.url.path, endsWith('/functions/v1/submit-sighting'));
        expect(request.headers[appCheckHeader], 'token');
        expect(jsonDecode(request.body), {
          ...report().toJson(),
          'device_id': 'd1',
        });
      });

      test('403 account.suspended 變成 AccountSuspended', () {
        expect(
          answering(403, {
            'error': 'account.suspended',
            'until': '2026-12-01T00:00:00Z',
          }).submit(report()),
          throwsA(isA<AccountSuspended>()),
        );
      });

      for (final (message, status, reason) in [
        ('sighting too soon', 429, SightingRefusal.tooSoon),
        ('daily sighting limit reached', 429, SightingRefusal.dailyLimit),
        ('area not found', 404, SightingRefusal.spotGone),
        ('Google or Apple sign-in required', 401, SightingRefusal.signIn),
      ]) {
        test('$status $message', () {
          expect(
            answering(status, {'error': message}).submit(report()),
            throwsA(
              isA<SightingRefused>().having((e) => e.reason, 'reason', reason),
            ),
          );
        });
      }
    });
  });

  group('AppStore', () {
    testWidgets('地圖讀 15 分鐘；打開詳情再讀 15、30；只看目前車種與時窗內', (tester) async {
      final now = detailDay;
      final source = FakeSightings([
        row(lotId, zone: 'b2', at: now.subtract(const Duration(minutes: 8))),
        row(lotId, zone: 'b3', at: now.subtract(const Duration(minutes: 20))),
        row(
          lotId,
          zone: 'b1',
          vehicle: 'scooter',
          at: now.subtract(const Duration(minutes: 8)),
        ),
      ]);
      final store = await sightedStore(tester, source);
      expect(source.windows.toSet(), {sightingMapWindow});
      source.windows.clear();
      await tester.runAsync(() => store.followSightings(lot));
      expect(source.windows, unorderedEquals([15, 30]));
      expect(
        store.riderSeats(sightingMapWindow).of(lotId).map((s) => s.areaId),
        ['b2'],
      );
      expect(
        store.riderSeats(sightingDetailWindow).of(lotId).map((s) => s.areaId),
        ['b2', 'b3'],
      );
      store.vehicle = VehicleType.scooter;
      expect(
        store.riderSeats(sightingMapWindow).of(lotId).map((s) => s.areaId),
        ['b1'],
      );
      store.unfollowSightings(lot);
      // Closed: the map keeps the 15-minute answer the sheet read.
      expect(
        store.riderSeats(sightingMapWindow).of(lotId).map((s) => s.areaId),
        ['b1'],
      );
    });

    testWidgets('送出後重讀；讀取失敗保留舊的', (tester) async {
      final source = FakeSightings(const []);
      final store = await sightedStore(tester, source);
      await tester.runAsync(() => store.followSightings(lot));
      expect(store.riderSeats(30).of(lotId), isEmpty);
      source.rows = [row(lotId, zone: 'b2', at: detailDay)];
      await tester.runAsync(() async {
        await store.submitSighting(
          const SightingReport.level(
            spotId: lotId,
            vehicle: VehicleType.heavy,
            level: 2,
            zoneId: 'b2',
          ),
        );
        await store.readFollowedSightings();
      });
      expect(source.sent, hasLength(1));
      expect(store.riderSeats(30).of(lotId), hasLength(1));
      expect(store.riderMeter(lot), const RiderMeter(RiderLevel.some));
    });

    testWidgets('寫入成功後讀取卡住或失敗：送出照樣完成，自己的回報照樣顯示', (tester) async {
      const report = SightingReport.level(
        spotId: lotId,
        vehicle: VehicleType.heavy,
        level: 2,
        zoneId: 'b2',
      );
      for (final source in [StalledReads(const []), FailingReads(const [])]) {
        final store = await sightedStore(tester, source);
        if (source is StalledReads) source.stalled = true;
        unawaited(store.followSightings(lot));
        final done = await tester.runAsync(
          () => store
              .submitSighting(report)
              .then((_) => true)
              .timeout(const Duration(seconds: 2), onTimeout: () => false),
        );
        expect(done, isTrue);
        expect(source.sent, hasLength(1));
        expect(store.riderSeats(15).of(lotId), hasLength(1));
      }
    });

    testWidgets('蓋在上面的卡片關閉：交還給下面那張，重新讀取', (tester) async {
      final source = FakeSightings(const []);
      final store = await sightedStore(tester, source);
      await tester.runAsync(() async {
        await store.followSightings(lot);
        await store.followSightings(street);
      });
      // Only in the details' window: what the card below reads again.
      source.rows = [
        row(
          lotId,
          zone: 'b2',
          at: detailDay.subtract(const Duration(minutes: 20)),
        ),
      ];
      expect(store.riderSeats(30).of(lotId), isEmpty);
      await tester.runAsync(() async {
        store.unfollowSightings(street);
        await store.readFollowedSightings();
      });
      expect(store.riderSeats(30).of(lotId), hasLength(1));
      // The same spot twice: closing one keeps the other's data.
      await tester.runAsync(() => store.followSightings(lot));
      store.unfollowSightings(lot);
      expect(store.riderSeats(30).of(lotId), hasLength(1));
    });

    testWidgets('關閉卡片：地圖留著卡片讀到的最新回報，讀到沒有回報就清掉舊的', (tester) async {
      final source = FakeSightings(const []);
      final store = await sightedStore(tester, source);
      final older = detailDay.subtract(const Duration(minutes: 5));
      store.sightings = {
        lotId: [row(lotId, zone: 'b2', level: 0, at: older)],
        streetId: [row(streetId, zone: 'b1', at: detailDay)],
      };
      source.rows = [row(lotId, zone: 'b2', level: 3, at: detailDay)];
      await tester.runAsync(() => store.followSightings(lot));
      store.unfollowSightings(lot);
      expect(
        store.riderSeats(sightingMapWindow).of(lotId).map((s) => s.level),
        [riderLevelFromBackend(3)],
      );
      expect(store.sightings[streetId], hasLength(1));

      source.rows = const [];
      await tester.runAsync(() => store.followSightings(lot));
      store.unfollowSightings(lot);
      expect(store.riderSeats(sightingMapWindow).of(lotId), isEmpty);
      expect(store.sightings.containsKey(lotId), isFalse);
      expect(store.sightings[streetId], hasLength(1));
    });

    testWidgets('詳情讀取失敗：地圖讀到的回報照常顯示，不寫成沒有回報', (tester) async {
      final source = FailingReads(const []);
      final store = await sightedStore(tester, source);
      store.sightings = {
        lotId: [row(lotId, zone: 'b2', at: detailDay)],
      };
      await tester.runAsync(() => store.followSightings(lot));
      expect(store.riderSeats(30).of(lotId), hasLength(1));
    });

    testWidgets('範例建置沒有後端：不讀，送出不報錯', (tester) async {
      final store = await detailStore(tester, VehicleType.heavy);
      expect(store.sightingsSource.enabled, isFalse);
      await tester.runAsync(() => store.followSightings(lot));
      expect(store.riderSeats(30).of(lotId), isEmpty);
    });
  });

  group('有沒有位的合併', () {
    final now = detailDay;
    final ago8 = now.subtract(const Duration(minutes: 8));
    RiderSeat b2(int level, {DateTime? at, int riders = 3}) =>
        RiderSeat(level: level, at: at ?? ago8, areaId: 'b2', riders: riders);
    FourSign sign(
      List<RiderSeat> seats, {
      List<AvailabilitySnapshot> counts = const [],
      ParkingSpot? spot,
      VehicleType vehicle = VehicleType.heavy,
    }) => fourSign(
      spot ?? lot,
      vehicle,
      const [],
      now: now,
      availability: SpotAvailability(counts),
      riders: Seats(seats),
    );

    test('官方新鮮：官方優先，車友回報只列在旁邊', () {
      final s = sign(
        [b2(2)],
        counts: [
          count(
            AvailabilityVehicle.heavy,
            available: 4,
            at: now.subtract(const Duration(minutes: 2)),
          ),
        ],
      );
      expect(s.seat.kind, SeatKind.live);
      expect(s.seat.available, 4);
      expect(s.seat.rider, isNull);
      expect(s.seat.beside?.level, 2);
      expect(s.seat.disagrees, isFalse);
      final row = seatBesideRow(s, now)!;
      expect(row.text, '車友 8 分鐘前：還有一些（3 人）');
      expect(row.tag, '車友回報');
      expect(row.meters, [2]);
    });

    test('矛盾：差兩級以上才提示，官方數字不動', () {
      final s = sign(
        [b2(0)],
        counts: [
          count(
            AvailabilityVehicle.heavy,
            available: 12,
            at: now.subtract(const Duration(minutes: 3)),
          ),
        ],
      );
      expect(s.seat.kind, SeatKind.live);
      expect(s.seat.available, 12);
      expect(s.seat.disagrees, isTrue);
      // ±1 級算相符：剩 12/20 是很多空位，說還有一些不提示。
      final near = sign(
        [b2(2)],
        counts: [
          count(
            AvailabilityVehicle.heavy,
            available: 12,
            at: now.subtract(const Duration(minutes: 3)),
          ),
        ],
      );
      expect(near.seat.disagrees, isFalse);
    });

    test('沒有總格數、說法不一、官方延遲：都不提示矛盾', () {
      final fresh = now.subtract(const Duration(minutes: 3));
      expect(
        sign(
          [b2(0)],
          counts: [
            count(
              AvailabilityVehicle.heavy,
              available: 12,
              total: null,
              at: fresh,
            ),
          ],
        ).seat.disagrees,
        isFalse,
      );
      expect(
        sign(
          [
            RiderSeat(
              level: 3,
              otherLevel: 0,
              highCount: 1,
              lowCount: 1,
              at: ago8,
              areaId: 'b2',
            ),
          ],
          counts: [count(AvailabilityVehicle.heavy, available: 12, at: fresh)],
        ).seat.disagrees,
        isFalse,
      );
      final delayed = sign(
        [b2(0)],
        counts: [
          count(
            AvailabilityVehicle.heavy,
            available: 12,
            at: now.subtract(const Duration(minutes: 15)),
          ),
        ],
      );
      expect(delayed.seat.kind, SeatKind.delayed);
      expect(delayed.seat.disagrees, isFalse);
    });

    test('官方過期：改用車友回報，旁邊列最後一筆', () {
      final s = sign(
        [b2(2)],
        counts: [
          count(
            AvailabilityVehicle.heavy,
            available: 6,
            at: now.subtract(const Duration(hours: 3)),
          ),
        ],
      );
      expect(s.seat.kind, SeatKind.rider);
      expect(s.seat.rider?.level, 2);
      final row = seatBesideRow(s, now)!;
      expect(row.official, isTrue);
      expect(row.tag, '官方');
      expect(row.text, startsWith('官方資料過期，最後一筆 '));
      expect(row.text, endsWith('剩 6 格'));
    });

    test('沒有官方也沒有回報：空位未知', () {
      final s = sign(const []);
      expect(s.seat.rider, isNull);
      expect(seatBesideRow(s, now), isNull);
    });

    test('說法不一：路牌兩個量表、兩端人數', () {
      final s = sign([
        RiderSeat(
          level: 3,
          otherLevel: 0,
          highCount: 2,
          lowCount: 1,
          at: ago8,
          areaId: 'b2',
        ),
      ]);
      final plate = fourSignPlates(
        s,
        now,
      ).firstWhere((p) => p.face == FourSignFace.seat);
      expect(plate.main, '說法不一');
      expect(plate.meters, [3, 0]);
      expect(plate.note, contains('2 人說很多・1 人說滿'));
    });

    test('說法不一的區不算「另 N 區有位」的最佳，也不排在有共識的區前面', () {
      final seats = [
        RiderSeat(
          level: 3,
          otherLevel: 0,
          highCount: 1,
          lowCount: 1,
          at: ago8,
          areaId: 'b3',
        ),
        b2(1),
      ];
      final s = fourSign(
        lot,
        VehicleType.heavy,
        const [],
        now: detailNight,
        riders: Seats(seats),
      );
      expect(s.seat.rider?.areaId, 'b2');
      expect(s.seat.more, 0);
    });

    test('回報的區現在不能停：不顯示', () {
      final s = sign([RiderSeat(level: 3, at: ago8, areaId: 'b3')]);
      expect(s.seat.rider, isNull);
    });

    test('能回報的地方：只列現在能停的；不能停或現在都沒開就沒有', () {
      expect(sightingPlaces(sign(const []))?.map((a) => a.id), ['b2']);
      expect(
        sightingPlaces(
          fourSign(lot, VehicleType.heavy, const [], now: detailNight),
        )?.map((a) => a.id),
        ['b2', 'b3'],
      );
      expect(
        sightingPlaces(
          fourSign(detailBay, VehicleType.scooter, const [], now: now),
        ),
        isEmpty,
      );
    });
  });

  group('地圖角標', () {
    final now = detailDay;
    final decision = decideParking(lot, VehicleType.heavy, const [], now: now);
    const meter = RiderMeter(RiderLevel.some);

    test('沒有官方膠囊時掛角標；路邊點也掛', () {
      final capsules = markerCapsules(
        lot,
        SpotAvailability.none,
        VehicleType.heavy,
        decision,
        now,
        rider: meter,
      );
      expect(capsules.single.style, CapsuleStyle.rider);
      expect(capsules.single.meter, meter);
      expect(capsules.single.semantics, '車友回報：還有一些');
      expect(capsules.any(officialCapsule), isFalse);
      expect(
        markerCapsules(
          street,
          SpotAvailability.none,
          VehicleType.heavy,
          decideParking(street, VehicleType.heavy, const [], now: now),
          now,
          rider: meter,
        ).single.meter,
        meter,
      );
    });

    test('有官方膠囊（即時、延遲）不掛', () {
      for (final minutes in [2, 15]) {
        final capsules = markerCapsules(
          lot,
          SpotAvailability([
            count(
              AvailabilityVehicle.heavy,
              available: 4,
              at: now.subtract(Duration(minutes: minutes)),
            ),
          ]),
          VehicleType.heavy,
          decision,
          now,
          rider: meter,
        );
        expect(capsules.single.meter, isNull);
        expect(capsules.any(officialCapsule), isTrue);
      }
    });

    test('不能停：不掛', () {
      expect(
        markerCapsules(
          lot,
          SpotAvailability.none,
          VehicleType.heavy,
          const ParkingDecision(EligibilityStatus.notAllowed, '不能停'),
          now,
          rider: meter,
        ),
        isEmpty,
      );
    });

    test('擁擠時留下角標；膠囊的等值含量表', () {
      final one = AvailabilityCapsule.rider(meter);
      expect(primaryCapsules(lot, VehicleType.heavy, decision, [one]), [one]);
      expect(one, AvailabilityCapsule.rider(meter));
      expect(
        one == AvailabilityCapsule.rider(const RiderMeter(RiderLevel.full)),
        isFalse,
      );
    });

    testWidgets('Flutter 地圖：量表格數與膠囊寬度和畫布一致', (tester) async {
      for (final m in const [
        RiderMeter(RiderLevel.plenty),
        RiderMeter.conflict(RiderLevel.plenty, RiderLevel.full),
      ]) {
        final capsule = AvailabilityCapsule.rider(m);
        await tester.pumpWidget(
          MaterialApp(
            home: Center(child: AvailabilityCapsuleView(capsule: capsule)),
          ),
        );
        expect(find.byType(RiderMeterBadge), findsOneWidget);
        expect(
          tester.getSize(find.byType(RiderMeterBadge)).width,
          moreOrLessEquals(capsuleWidth(capsule), epsilon: 1.5),
        );
      }
      expect(find.byKey(const ValueKey('rider-bar-2-filled')), findsOneWidget);
    });

    test('Google 地圖：角標畫得進點陣圖', () async {
      for (final m in const [
        RiderMeter(RiderLevel.almostFull),
        RiderMeter.conflict(RiderLevel.some, RiderLevel.full),
      ]) {
        final capsule = AvailabilityCapsule.rider(m);
        final recorder = ui.PictureRecorder();
        paintCapsuleRow(ui.Canvas(recorder), Offset.zero, [capsule]);
        final picture = recorder.endRecording();
        final image = await picture.toImage(capsuleWidth(capsule).ceil(), 24);
        final bytes = (await image.toByteData())!;
        // The ground is drawn: the pill's middle is not transparent.
        final w = image.width;
        expect(bytes.getUint8((12 * w + w ~/ 2) * 4 + 3), greaterThan(0));
        image.dispose();
        picture.dispose();
      }
    });

    testWidgets('store：多區取路牌選出的那一區；有官方就沒有', (tester) async {
      final source = FakeSightings([
        row(
          lotId,
          zone: 'b2',
          level: 2,
          at: detailDay.subtract(const Duration(minutes: 5)),
        ),
      ]);
      final store = await sightedStore(tester, source);
      expect(store.riderMeter(lot), isNull);
      await tester.runAsync(() => store.followSightings(lot));
      expect(store.riderMeter(lot), const RiderMeter(RiderLevel.almostFull));
      store.availability = {
        lotId: SpotAvailability([
          count(
            AvailabilityVehicle.heavy,
            available: 4,
            at: detailDay.subtract(const Duration(minutes: 1)),
          ),
        ]),
      };
      expect(store.riderMeter(lot), isNull);
    });
  });

  group('回報面板', () {
    final ago = detailDay.subtract(const Duration(minutes: 8));

    Future<void> openPanel(
      WidgetTester tester,
      AppStore store,
      ParkingSpot spot, {
      Size size = const Size(390, 844),
      double scale = 1,
      bool dark = false,
    }) async {
      await openDetail(
        tester,
        store,
        spot,
        size: size,
        scale: scale,
        dark: dark,
        full: false,
      );
      final report = find.byKey(const ValueKey('spot-report'));
      await tester.ensureVisible(report);
      await tester.pumpAndSettle();
      await tester.tap(report);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('sighting-sheet')), findsOneWidget);
    }

    AdaptiveButton submit(WidgetTester tester) =>
        tester.widget(find.byKey(const ValueKey('sighting-submit')));

    Future<void> send(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('sighting-submit')));
      await tester.pumpAndSettle();
    }

    for (final platform in platforms) {
      for (final (name, size) in layouts) {
        for (final (scale, dark) in [(1.0, false), (2.0, false), (1.0, true)]) {
          testWidgetsOn(
            '${platform.name} $name ${scale}x ${dark ? '深色' : '淺色'}：不溢出，觸控尺寸足夠，'
            '選了才能送',
            (tester) async {
              setUpView(tester, platform, size);
              final source = FakeSightings(const []);
              final store = await sightedStore(
                tester,
                source,
                now: detailNight,
              );
              await openPanel(
                tester,
                store,
                lot,
                size: size,
                scale: scale,
                dark: dark,
              );
              expect(tester.takeException(), isNull);
              final min = platform == TargetPlatform.iOS ? 44.0 : 48.0;
              for (final key in [
                'sighting-place-0',
                'sighting-place-1',
                'sighting-level-plenty',
                'sighting-level-full',
                'sighting-closed',
                'sighting-cancel',
                'sighting-submit',
              ]) {
                final finder = find.byKey(ValueKey(key));
                await tester.ensureVisible(finder);
                await tester.pumpAndSettle();
                expect(
                  tester.getSize(finder).height,
                  greaterThanOrEqualTo(min),
                  reason: key,
                );
              }
              expect(submit(tester).onPressed, isNull);
              Future<void> choose(String key) async {
                final finder = find.byKey(ValueKey(key));
                await tester.ensureVisible(finder);
                await tester.pumpAndSettle();
                await tester.tap(finder);
                await tester.pumpAndSettle();
              }

              await choose('sighting-level-some');
              // Two places open at 21:00: the rider says which.
              expect(submit(tester).onPressed, isNull);
              await choose('sighting-place-1');
              expect(submit(tester).onPressed, isNotNull);
              expect(tester.takeException(), isNull);
            },
          );
        }
      }
    }

    testWidgetsOn('路外：選區與等級，送出後關閉並提示，車友回報列更新', (tester) async {
      final source = FakeSightings(const []);
      final store = await sightedStore(tester, source);
      await openPanel(tester, store, lot);
      expect(find.text('只列你現在能停的區', findRichText: true), findsNothing);
      expect(
        find.textContaining('只列你現在能停的區', findRichText: true),
        findsOneWidget,
      );
      expect(find.text('B2 重機專區'), findsWidgets);
      expect(find.text('B1 機車區'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('sighting-level-almostFull')));
      await tester.pumpAndSettle();
      source.rows = [row(lotId, zone: 'b2', level: 2, at: detailDay)];
      await send(tester);
      expect(find.byKey(const ValueKey('sighting-sheet')), findsNothing);
      expect(find.text(sightingSent), findsOneWidget);
      final sent = source.sent.single;
      expect(sent.level, 1);
      expect(sent.zoneId, 'b2');
      expect(sent.segmentId, isNull);
      expect(sent.vehicle, VehicleType.heavy);
      expect(sent.toJson()['level'], 2);
    });

    testWidgetsOn('iOS：取消鈕、送出後關閉並提示', (tester) async {
      setUpView(tester, TargetPlatform.iOS, const Size(390, 844));
      final source = FakeSightings(const []);
      final store = await sightedStore(tester, source);
      await openPanel(tester, store, lot);
      expect(find.text(sightingCancel), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('sighting-level-some')));
      await tester.pumpAndSettle();
      await send(tester);
      expect(find.byKey(const ValueKey('sighting-sheet')), findsNothing);
      expect(find.text(sightingSent), findsOneWidget);
      expect(source.sent.single.level, 2);
    });

    testWidgetsOn('路邊：送 segment_id', (tester) async {
      final source = FakeSightings(const []);
      final store = await sightedStore(tester, source);
      await openPanel(tester, store, street);
      expect(
        find.textContaining('只列你現在能停的段', findRichText: true),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('sighting-place-0')));
      await tester.tap(find.byKey(const ValueKey('sighting-level-full')));
      await tester.pumpAndSettle();
      await send(tester);
      expect(source.sent.single.segmentId, isNotNull);
      expect(source.sent.single.zoneId, isNull);
      expect(source.sent.single.level, 0);
    });

    testWidgetsOn('無法停車／施工中：一次選一區，送 zone_id（A7d）', (tester) async {
      final source = FakeSightings(const []);
      final store = await sightedStore(tester, source, now: detailNight);
      await openPanel(tester, store, lot);
      await tester.ensureVisible(find.byKey(const ValueKey('sighting-closed')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('sighting-closed')));
      await tester.pumpAndSettle();
      expect(find.text('整區都停不了，例如施工、封閉'), findsOneWidget);
      // B2 and B3 are both open at night: no place, no report.
      expect(submit(tester).onPressed, isNull);
      await tester.tap(find.byKey(const ValueKey('sighting-place-1')));
      await tester.pumpAndSettle();
      await send(tester);
      expect(source.sent.single.closed, isTrue);
      expect(source.sent.single.toJson(), {
        'spot_id': lotId,
        'kind': 'closed',
        'level': null,
        'zone_id': 'b3',
        'segment_id': null,
        'vehicle': 'heavy',
      });
    });

    testWidgetsOn('無法停車／施工中：路邊送 segment_id', (tester) async {
      final source = FakeSightings(const []);
      final store = await sightedStore(tester, source);
      await openPanel(tester, store, street);
      await tester.tap(find.byKey(const ValueKey('sighting-place-0')));
      await tester.ensureVisible(find.byKey(const ValueKey('sighting-closed')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('sighting-closed')));
      await tester.pumpAndSettle();
      expect(find.text('整段都停不了，例如施工、封路'), findsOneWidget);
      await send(tester);
      expect(source.sent.single.closed, isTrue);
      expect(source.sent.single.segmentId, isNotNull);
      expect(source.sent.single.zoneId, isNull);
    });

    testWidgetsOn('失敗：留在面板、內容還在、可以再送', (tester) async {
      final source = FakeSightings(const [])..failure = Exception('offline');
      final store = await sightedStore(tester, source);
      await openPanel(tester, store, lot);
      await tester.tap(find.byKey(const ValueKey('sighting-level-some')));
      await tester.pumpAndSettle();
      await send(tester);
      expect(find.byKey(const ValueKey('sighting-sheet')), findsOneWidget);
      expect(find.text(sightingFailed), findsOneWidget);
      expect(submit(tester).onPressed, isNotNull);
      source.failure = const SightingRefused(SightingRefusal.tooSoon);
      await send(tester);
      expect(find.text('這一區 10 分鐘內回報過了，請稍後再回報。'), findsOneWidget);
      source.failure = null;
      await send(tester);
      expect(source.sent, hasLength(1));
      expect(find.byKey(const ValueKey('sighting-sheet')), findsNothing);
    });

    testWidgetsOn('訊息放在送出按鈕正上方，朗讀會唸出', (tester) async {
      final source = FakeSightings(const [])..failure = Exception('offline');
      final store = await sightedStore(tester, source);
      await openPanel(tester, store, lot);
      await tester.tap(find.byKey(const ValueKey('sighting-level-some')));
      await tester.pumpAndSettle();
      await send(tester);
      final alert = find.byKey(const ValueKey('sighting-error'));
      final button = find.byKey(const ValueKey('sighting-submit'));
      expect(
        tester.getRect(alert).bottom,
        lessThan(tester.getRect(button).top),
      );
      expect(
        tester.getRect(button).top - tester.getRect(alert).bottom,
        lessThanOrEqualTo(16),
      );
      final semantics = tester.widget<Semantics>(
        find.ancestor(of: alert, matching: find.byType(Semantics)).first,
      );
      expect(semantics.properties.liveRegion, isTrue);
    });

    for (final (reason, text) in const [
      (SightingRefusal.dailyLimit, '今天的回報次數已達上限，明天再回報。'),
      (SightingRefusal.spotGone, '這個地點的資料已更新，請重新打開後再回報。'),
    ]) {
      testWidgetsOn('$text 面板不關，按鈕保留', (tester) async {
        final source = FakeSightings(const [])
          ..failure = SightingRefused(reason);
        final store = await sightedStore(tester, source);
        await openPanel(tester, store, lot);
        await tester.tap(find.byKey(const ValueKey('sighting-level-some')));
        await tester.pumpAndSettle();
        await send(tester);
        expect(find.text(text), findsOneWidget);
        expect(submit(tester).onPressed, isNotNull);
      });
    }

    test('10 分鐘內回報過：依地點寫這一段、這一區、這裡', () {
      String text({required bool street, required bool whole}) =>
          sightingRefusalText(
            SightingRefusal.tooSoon,
            street: street,
            whole: whole,
          );
      expect(text(street: true, whole: false), startsWith('這一段 10 分鐘內'));
      expect(text(street: false, whole: false), startsWith('這一區 10 分鐘內'));
      expect(text(street: true, whole: true), startsWith('這裡 10 分鐘內'));
    });

    group('登入失效', () {
      Future<ExpiredStore> expiredStore(
        WidgetTester tester,
        FakeSightings source,
      ) async {
        final store = (await tester.runAsync(() async {
          SharedPreferences.setMockInitialValues({'vehicle': 'heavy'});
          final s = ExpiredStore(
            LocalRepository(await SharedPreferences.getInstance()),
            null,
            sightingsSource: source,
            clock: () => detailNight,
          );
          await s.init();
          return s;
        }))!;
        store.vehicle = VehicleType.heavy;
        addTearDown(store.dispose);
        return store;
      }

      final signIn = find.byKey(const ValueKey('sighting-sign-in'));

      Future<(ExpiredStore, FakeSightings)> refused(WidgetTester tester) async {
        final source = FakeSightings(const [])
          ..failure = const SightingRefused(SightingRefusal.signIn);
        final store = await expiredStore(tester, source);
        await openPanel(tester, store, lot);
        await tester.tap(find.byKey(const ValueKey('sighting-place-1')));
        await tester.tap(find.byKey(const ValueKey('sighting-level-some')));
        await tester.pumpAndSettle();
        await send(tester);
        return (store, source);
      }

      for (final platform in platforms) {
        testWidgetsOn('${platform.name}：按鈕改成重新登入，登入後回到面板，內容保留', (tester) async {
          setUpView(tester, platform, const Size(390, 844));
          final (store, source) = await refused(tester);
          expect(find.text('登入已失效，請重新登入後再回報。'), findsOneWidget);
          expect(signIn, findsOneWidget);
          expect(find.text(sightingSignInAgain), findsWidgets);
          expect(find.byKey(const ValueKey('sighting-submit')), findsNothing);
          // No second sign-in prompt beside the message.
          expect(find.byType(SignInPrompt), findsNothing);
          await tester.tap(signIn);
          await tester.pumpAndSettle();
          expect(store.ended, 1);
          expect(find.byType(SignInSheet), findsOneWidget);
          source.failure = null;
          store.signedInAgain();
          await tester.pumpAndSettle();
          expect(find.byType(SignInSheet), findsNothing);
          expect(find.byKey(const ValueKey('sighting-sheet')), findsOneWidget);
          expect(find.byKey(const ValueKey('sighting-error')), findsNothing);
          // What was chosen is still there: it goes without choosing again.
          await send(tester);
          expect(source.sent.single.zoneId, 'b3');
          expect(source.sent.single.level, 2);
        });
      }

      testWidgetsOn('取消登入：訊息和重新登入按鈕都留著', (tester) async {
        final (store, _) = await refused(tester);
        await tester.tap(signIn);
        await tester.pumpAndSettle();
        await tester.tapAt(const Offset(195, 20));
        await tester.pumpAndSettle();
        expect(store.canReport, isFalse);
        expect(find.byKey(const ValueKey('sighting-sheet')), findsOneWidget);
        expect(signIn, findsOneWidget);
        expect(find.byKey(const ValueKey('sighting-error')), findsOneWidget);
      });
    });

    testWidgetsOn('成功：回報立刻出現在卡片上，即使彙整沒有列入', (tester) async {
      final source = FakeSightings(const []);
      final store = await sightedStore(tester, source);
      await openPanel(tester, store, lot);
      await tester.tap(find.byKey(const ValueKey('sighting-level-some')));
      await tester.pumpAndSettle();
      await send(tester);
      expect(find.text(sightingSent), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('four-sign-seat')),
          matching: find.text('還有一些'),
        ),
        findsOneWidget,
      );
      expect(store.riderMeter(lot), const RiderMeter(RiderLevel.some));
    });

    testWidgets('自己的回報：彙整有那一區就用彙整，換車種不顯示，時窗過了消失', (tester) async {
      var now = detailDay;
      final source = FakeSightings(const []);
      final store = (await tester.runAsync(() async {
        SharedPreferences.setMockInitialValues({'vehicle': 'heavy'});
        final s = AppStore(
          LocalRepository(await SharedPreferences.getInstance()),
          null,
          sightingsSource: source,
          clock: () => now,
        );
        await s.init();
        return s;
      }))!;
      addTearDown(store.dispose);
      store.vehicle = VehicleType.heavy;
      await tester.runAsync(() => store.followSightings(lot));
      const report = SightingReport.level(
        spotId: lotId,
        vehicle: VehicleType.heavy,
        level: 2,
        zoneId: 'b2',
      );
      await tester.runAsync(() async {
        await store.submitSighting(report);
        await store.readFollowedSightings();
      });
      expect(store.riderSeats(15).of(lotId).single.level, 2);
      store.vehicle = VehicleType.scooter;
      expect(store.riderSeats(15).of(lotId), isEmpty);
      store.vehicle = VehicleType.heavy;
      source.rows = [row(lotId, zone: 'b2', level: 3, count: 4, at: now)];
      await tester.runAsync(store.readFollowedSightings);
      final seats = store.riderSeats(15).of(lotId);
      expect(seats.single.level, 0);
      expect(seats.single.riders, 4);
      source.rows = const [];
      await tester.runAsync(store.readFollowedSightings);
      now = now.add(const Duration(minutes: 16));
      expect(store.riderSeats(15).of(lotId), isEmpty);
      expect(store.riderSeats(30).of(lotId), hasLength(1));
      now = now.add(const Duration(minutes: 15));
      expect(store.riderSeats(30).of(lotId), isEmpty);
    });

    testWidgets('無法停車不算空位回報，卡片不顯示', (tester) async {
      final source = FakeSightings(const []);
      final store = await sightedStore(tester, source);
      await tester.runAsync(
        () => store.submitSighting(
          const SightingReport.closed(
            spotId: lotId,
            vehicle: VehicleType.heavy,
          ),
        ),
      );
      expect(store.riderSeats(15).of(lotId), isEmpty);
    });

    testWidgetsOn('停權：跳停權面板，回報內容保留', (tester) async {
      final source = FakeSightings(const [])
        ..failure = AccountSuspended(DateTime.utc(2026, 12, 1));
      final store = await sightedStore(tester, source);
      await openPanel(tester, store, lot);
      await tester.tap(find.byKey(const ValueKey('sighting-level-some')));
      await tester.pumpAndSettle();
      await send(tester);
      expect(find.byType(SuspendedPanel), findsOneWidget);
      await tester.tapAt(const Offset(195, 20));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('sighting-sheet')), findsOneWidget);
      expect(submit(tester).onPressed, isNotNull);
      expect(source.sent, isEmpty);
    });

    testWidgetsOn('未登入：顯示登入提示，不能送', (tester) async {
      final source = FakeSightings(const []);
      final store = await sightedStore(tester, source, guest: true);
      await openPanel(tester, store, lot);
      expect(find.byType(SignInPrompt), findsOneWidget);
      expect(find.text(sightingSignIn), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('sighting-level-some')));
      await tester.pumpAndSettle();
      expect(submit(tester).onPressed, isNull);
    });

    testWidgetsOn('不能回報的點沒有按鈕：不是 uuid 的 id、不能停', (tester) async {
      final store = await sightedStore(tester, FakeSightings(const []));
      await openDetail(tester, store, detailLot, full: false);
      expect(find.byKey(const ValueKey('spot-report')), findsNothing);
      expect(find.byKey(const ValueKey('spot-suggest')), findsWidgets);
    });

    testWidgetsOn('預覽：官方旁列車友回報與矛盾提示', (tester) async {
      final source = FakeSightings([
        row(lotId, zone: 'b2', level: 3, count: 3, at: ago),
      ]);
      final store = await sightedStore(tester, source);
      store.availability = {
        lotId: SpotAvailability([
          count(
            AvailabilityVehicle.heavy,
            available: 12,
            at: detailDay.subtract(const Duration(minutes: 3)),
          ),
        ]),
      };
      await openDetail(tester, store, lot, full: false);
      expect(find.byType(SeatBesideLine), findsOneWidget);
      expect(find.text('車友 8 分鐘前：已停滿（3 人）'), findsOneWidget);
      expect(find.text(riderDisagreesNote), findsOneWidget);
    });
  });

  group('收藏卡', () {
    final ago = detailDay.subtract(const Duration(minutes: 8));
    final fresh = detailDay.subtract(const Duration(minutes: 2));

    Future<void> pumpCard(
      WidgetTester tester,
      AppStore store, {
      Size size = const Size(390, 844),
      double scale = 1,
      bool dark = false,
    }) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            brightness: dark ? Brightness.dark : Brightness.light,
          ),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Scaffold(
            body: ListView(
              children: [
                for (final e in favoritesByDistance(store))
                  FavoriteCard(store: store, entry: e, detailed: true),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
    }

    Finder onSeatPlate(Finder matching) => find.descendant(
      of: find.byKey(const ValueKey('four-sign-seat')),
      matching: matching,
    );

    for (final platform in platforms) {
      for (final (name, size) in layouts) {
        for (final (scale, dark) in [(1.0, false), (2.0, false), (1.0, true)]) {
          testWidgetsOn(
            '${platform.name} $name ${scale}x ${dark ? '深色' : '淺色'}：'
            '畫面外的收藏點也有車友回報',
            (tester) async {
              setUpView(tester, platform, size);
              final source = FakeSightings([
                row(lotId, zone: 'b2', level: 1, at: ago),
              ]);
              final store = await sightedStore(tester, source);
              store.favorites = [lot];
              await tester.runAsync(store.refresh);
              await pumpCard(
                tester,
                store,
                size: size,
                scale: scale,
                dark: dark,
              );
              expect(onSeatPlate(find.text('還有一些')), findsOneWidget);
              expect(onSeatPlate(find.byType(RiderMeters)), findsOneWidget);
              expect(tester.takeException(), isNull);
            },
          );
        }
      }
    }

    testWidgets('官方優先：畫面外的收藏點也讀官方數字，不被車友回報蓋過', (tester) async {
      final source = FakeSightings([row(lotId, zone: 'b2', at: ago)]);
      final store = await sightedStore(
        tester,
        source,
        counts: FakeAvailabilitySource(
          () => [count(AvailabilityVehicle.heavy, available: 4, at: fresh)],
        ),
      );
      store.favorites = [lot];
      await tester.runAsync(store.refresh);
      expect(store.spots.map((s) => s.id), isNot(contains(lotId)));
      await pumpCard(tester, store);
      expect(onSeatPlate(find.text('剩 4 格')), findsOneWidget);
      expect(onSeatPlate(find.byType(RiderMeters)), findsNothing);
    });

    testWidgets('讀取涵蓋收藏點，官方與車友都是；失敗時保留收藏點的舊資料', (tester) async {
      final seen = <String>{};
      final source = RecordingSightings(seen, [
        row(lotId, zone: 'b2', at: ago),
      ]);
      final store = await sightedStore(tester, source);
      store.favorites = [lot];
      seen.clear();
      await tester.runAsync(store.refresh);
      expect(seen, contains(lotId));
      expect(store.sightings, contains(lotId));
      source.fail = true;
      await tester.runAsync(store.refresh);
      expect(store.sightings, contains(lotId));
      store.favorites = [];
      await tester.runAsync(store.refresh);
      expect(store.sightings, isNot(contains(lotId)));
    });

    group('地圖被蓋住時', () {
      ParkingSpot other(int i) => ParkingSpot.fromJson({
        ...detailLotJson,
        'id': 'official:33333333-3333-4333-8333-33333333333$i',
      });

      Future<(AppStore, RecordingSightings, List<List<String>>)> covered(
        WidgetTester tester, {
        Duration? poll,
      }) async {
        final seen = <String>{};
        final source = RecordingSightings(seen, const []);
        final reads = <List<String>>[];
        final counts = RecordingCounts(reads);
        final store = (await tester.runAsync(() async {
          SharedPreferences.setMockInitialValues({'vehicle': 'heavy'});
          final s = AppStore(
            LocalRepository(await SharedPreferences.getInstance()),
            null,
            sightingsSource: source,
            availabilitySource: counts,
            availabilityPoll: poll,
            clock: () => detailDay,
          );
          await s.init();
          return s;
        }))!;
        if (poll == null) addTearDown(store.dispose);
        store.vehicle = VehicleType.heavy;
        store.spots = [other(1)];
        store.availability = {
          other(1).id: SpotAvailability([
            count(AvailabilityVehicle.heavy, available: 3, at: detailDay),
          ]),
        };
        return (store, source, reads);
      }

      testWidgets('收藏點照常更新，只讀收藏點，畫面上其他點的資料留著', (tester) async {
        final (store, source, reads) = await covered(tester);
        store.favorites = [lot];
        store.setMapShown(false);
        reads.clear();
        source.seen.clear();
        source.rows = [row(lotId, zone: 'b2', at: ago)];
        await tester.runAsync(store.pollAvailability);
        expect(reads.single, [lotId]);
        expect(source.seen, {lotId});
        expect(store.riderSeats(15).of(lotId), hasLength(1));
        expect(store.availability, contains(other(1).id));
      });

      testWidgets('開啟中的詳情照常更新，即使不是收藏', (tester) async {
        final (store, source, reads) = await covered(tester);
        store.setMapShown(false);
        await tester.runAsync(() => store.followSightings(lot));
        reads.clear();
        source.rows = [row(lotId, zone: 'b2', at: ago)];
        await tester.runAsync(store.pollAvailability);
        expect(reads.single, [lotId]);
        await tester.runAsync(store.readFollowedSightings);
        expect(store.riderSeats(30).of(lotId), hasLength(1));
      });

      testWidgets('沒有收藏也沒有開詳情：不讀', (tester) async {
        final (store, _, reads) = await covered(tester);
        store.setMapShown(false);
        reads.clear();
        await tester.runAsync(store.pollAvailability);
        expect(reads, isEmpty);
      });

      testWidgets('輪詢不會停：收藏點到時間就再讀一次', (tester) async {
        final (store, _, reads) = await covered(
          tester,
          poll: const Duration(milliseconds: 20),
        );
        store.favorites = [lot];
        await tester.runAsync(() async {
          store.setMapShown(false);
          reads.clear();
          await Future<void>.delayed(const Duration(milliseconds: 200));
          expect(reads.length, greaterThanOrEqualTo(2));
          expect(reads.expand((r) => r).toSet(), {lotId});
          store.setMapShown(true);
          store.dispose();
        });
      });
    });

    testWidgets('超過 15 分鐘：卡片和地圖一樣不顯示', (tester) async {
      final source = FakeSightings([
        row(
          lotId,
          zone: 'b2',
          at: detailDay.subtract(const Duration(minutes: 20)),
        ),
      ]);
      final store = await sightedStore(tester, source);
      store.favorites = [lot];
      await tester.runAsync(store.refresh);
      await pumpCard(tester, store);
      expect(onSeatPlate(find.byType(RiderMeters)), findsNothing);
    });
  });

  group('詳情車友回報列', () {
    final ago = detailDay.subtract(const Duration(minutes: 8));

    for (final platform in platforms) {
      for (final (name, size) in layouts) {
        for (final (scale, dark) in [(1.0, false), (2.0, false), (1.0, true)]) {
          testWidgetsOn(
            '${platform.name} $name ${scale}x ${dark ? '深色' : '淺色'}：列出回報與沒有回報',
            (tester) async {
              setUpView(tester, platform, size);
              final source = FakeSightings(const []);
              final store = await sightedStore(tester, source);
              final segments = street.segments.map((s) => s.id).toList();
              source.rows = [
                row(
                  streetId,
                  segment: segments.first,
                  level: 1,
                  count: 2,
                  at: ago,
                ),
              ];
              await openDetail(
                tester,
                store,
                street,
                size: size,
                scale: scale,
                dark: dark,
              );
              expect(tester.takeException(), isNull);
              expect(find.text('8 分鐘前・2 人'), findsOneWidget);
              expect(find.text('還有一些'), findsWidgets);
              expect(find.text('近 30 分鐘沒有人回報'), findsWidgets);
              expect(
                find.bySemanticsLabel(RegExp('車友回報：還有一些')),
                findsOneWidget,
              );
            },
          );
        }
      }
    }

    testWidgetsOn('說法不一：兩端與人數；20 分鐘前的回報只在詳情', (tester) async {
      final old = detailDay.subtract(const Duration(minutes: 20));
      final source = FakeSightings([
        row(
          lotId,
          zone: 'b2',
          level: 1,
          low: 0,
          high: 3,
          lowRiders: 2,
          highRiders: 1,
          count: 3,
          conflicting: true,
          at: old,
        ),
      ]);
      final store = await sightedStore(tester, source);
      await openDetail(tester, store, lot, full: false);
      // Preview: 15 minutes, nothing.
      final plate = find.byKey(const ValueKey('four-sign-seat'));
      expect(
        find.descendant(of: plate, matching: find.text('說法不一')),
        findsNothing,
      );
      await pullUp(tester);
      expect(find.text('說法不一'), findsWidgets);
      expect(find.textContaining('2 人說很多・1 人說滿'), findsWidgets);
    });

    test('一列多區共用官方數字：取最空的區並帶區名', () {
      final at = detailDay.subtract(const Duration(minutes: 3));
      final sign = fourSign(lot, VehicleType.heavy, const [], now: detailNight);
      final [b2, b3] = sign.where.areas;
      final row = SeatRow(
        area: b2,
        areas: [b2, b3],
        name: 'x',
        sub: '',
        official: '剩 3 格',
      );
      final line = seatRiderLine(row, [
        RiderSeat(level: 1, at: at, areaId: 'b2', riders: 1),
        RiderSeat(level: 2, at: at, areaId: 'b3', riders: 2),
      ], detailNight);
      expect(line.main, '還有一些');
      expect(line.note, startsWith('B3'));
    });

    test('Beta 文案指向回報按鈕（A13、A14）', () {
      expect(betaIntroCaution, endsWith('看到不一樣，可以在詳情按「回報現場狀況」。'));
      expect(betaDetailNote(['臺北市']), endsWith('數字跟現場不一樣，請按下方「回報現場狀況」。'));
    });

    test('Beta 城市：只有車友回報時不是官方數字，不帶 Beta', () {
      final sign = fourSign(lot, VehicleType.heavy, const [], now: detailDay);
      final rows = seatRows(sign, SpotAvailability.none, detailDay);
      expect(rows.any((r) => r.counted), isFalse);
      expect(
        officialCapsule(
          AvailabilityCapsule.rider(const RiderMeter(RiderLevel.some)),
        ),
        isFalse,
      );
    });

    testWidgetsOn('Beta 城市：有官方數字才有 Beta 說明，車友列照常', (tester) async {
      Future<AppStore> open({required bool official}) async {
        final source = FakeSightings([row(lotId, zone: 'b2', at: ago)]);
        final store = await sightedStore(tester, source);
        if (official) {
          store.availability = {
            lotId: SpotAvailability([
              count(
                AvailabilityVehicle.heavy,
                available: 4,
                at: detailDay.subtract(const Duration(minutes: 2)),
              ),
            ]),
          };
        }
        await openDetail(tester, store, lot);
        return store;
      }

      await open(official: false);
      final note = find.byKey(const ValueKey('availability-beta-note'));
      expect(note, findsNothing);
      expect(find.byType(SeatRiderBox), findsWidgets);
      await tester.pumpWidget(const SizedBox());
      await open(official: true);
      expect(note, findsOneWidget);
      expect(find.byType(SeatRiderBox), findsWidgets);
    });
  });

  group('車友回報無法停車（A7d）', () {
    final ago = detailDay.subtract(const Duration(minutes: 20));
    final nightAgo = detailNight.subtract(const Duration(minutes: 20));

    RiderClosure rc({
      String? area,
      int riders = 1,
      bool? confirmed,
      DateTime? at,
    }) => RiderClosure(
      areaId: area,
      riders: riders,
      confirmed: confirmed ?? riders >= 2,
      at: at ?? ago,
    );

    FourSign signOf(
      ParkingSpot spot,
      List<RiderClosure> closures, {
      VehicleType vehicle = VehicleType.heavy,
      DateTime? now,
    }) => fourSign(
      spot,
      vehicle,
      const [],
      now: now ?? detailDay,
      closures: closures,
    );

    List<String> lines(FourSign s, DateTime now, {bool details = false}) => [
      for (final l in closureLines(s, now, details: details)) l.text,
    ];

    test('riderClosureOf：區或段、整點；時間讀不懂、區段都帶的不顯示', () {
      final c = riderClosureOf(
        closure(lotId, zone: 'b2', riders: 3, at: ago, derived: false),
      )!;
      expect(c.areaId, 'b2');
      expect(c.riders, 3);
      expect(c.confirmed, isTrue);
      expect(c.at, ago);
      expect(
        riderClosureOf(closure(lotId, segment: 'n1', at: ago))!.areaId,
        'n1',
      );
      expect(riderClosureOf(closure(lotId, at: ago))!.areaId, isNull);
      expect(
        riderClosureOf(closure(lotId, zone: 'b2', segment: 'n1', at: ago)),
        isNull,
      );
      expect(
        riderClosureOf(
          const v1.SpotClosure(
            spotId: lotId,
            riders: 1,
            confirmed: false,
            latestAt: 'not a time',
            derived: false,
          ),
        ),
        isNull,
      );
    });

    test('1 位，整點：能不能停不變，下方一行到場請再確認（①③）', () {
      final plain = signOf(lot, const []);
      final s = signOf(lot, [rc()]);
      expect(s.verdict.status, plain.verdict.status);
      expect(s.verdict.riderClosed, isNull);
      expect(
        fourSignPlates(s, detailDay).first.main,
        fourSignPlates(plain, detailDay).first.main,
      );
      final l = closureLines(s, detailDay, details: false).single;
      expect(l.text, '有車友回報無法停車・20 分鐘前，到場請再確認');
      expect(l.tone, ClosureLineTone.report);
      expect(l.semantics, '有車友回報無法停車，20 分鐘前，到場請再確認');
      expect(lines(s, detailDay, details: true), [l.text]);
      expect([
        for (final c in whereCards(s, lot, detailDay)) c.riderClosed,
      ], everyElement(''));
    });

    test('2 位，整點：現在不能停，其他路牌照常；停哪裡每區寫車友回報（②④）', () {
      final plain = signOf(lot, const []);
      final s = signOf(lot, [rc(riders: 2)]);
      expect(s.verdict.status, EligibilityStatus.notAllowed);
      expect(s.verdict.riderClosed!.riders, 2);
      // Not the data's 不能停: the plates stay, and riders may report it
      // open again.
      expect(s.denied, isFalse);
      expect(sightingPlaces(s), isNotNull);
      final plates = fourSignPlates(s, detailDay);
      expect(plates, hasLength(4));
      expect(plates.first.main, '不能停');
      expect(plates.first.note, '車友回報');
      expect(plates.first.tone, PlateTone.denied);
      expect(plates.first.semantics, '能不能停：現在不能停，2 位車友回報，非官方資訊');
      expect(plates[2].main, fourSignPlates(plain, detailDay)[2].main);
      expect(plates[3].main, fourSignPlates(plain, detailDay)[3].main);
      expect(verdictHeadline(s), '現在不能停');
      final preview = closureLines(s, detailDay, details: false).single;
      expect(preview.text, '2 位車友回報無法停車・20 分鐘前。非官方資訊');
      expect(preview.tone, ClosureLineTone.closed);
      final details = closureLines(s, detailDay, details: true).single;
      expect(details.text, riderClosedLift);
      expect(details.tone, ClosureLineTone.info);
      final cards = whereCards(s, lot, detailDay);
      expect(cards, isNotEmpty);
      expect([for (final c in cards) c.riderClosed], everyElement('車友回報無法停車'));
      expect(
        fourSignVerdict(
          lot,
          VehicleType.heavy,
          const [],
          now: detailDay,
          closures: [rc(riders: 2)],
        ).openNow,
        isFalse,
      );
    });

    test('2 位，一區：能不能停看其他區，該區紅字、不算可停的區（⑤）', () {
      final s = signOf(lot, [
        rc(area: 'b2', riders: 2, at: nightAgo),
      ], now: detailNight);
      expect(s.verdict.riderClosed, isNull);
      expect(s.verdict.openNow, isTrue);
      expect([for (final a in s.where.areas) a.id], ['b3']);
      final cards = {
        for (final c in whereCards(s, lot, detailNight))
          c.area.id: c.riderClosed,
      };
      expect(cards['b2'], '2 位車友回報無法停車・20 分鐘前。非官方資訊');
      expect(cards['b3'], '');
      expect(lines(s, detailNight), ['B2 重機專區：2 位車友回報無法停車・20 分鐘前']);
      expect(lines(s, detailNight, details: true), [
        'B2 重機專區：2 位車友回報無法停車・20 分鐘前',
      ]);
      // Still offered, so a rider on site can report it open again.
      expect([for (final a in sightingPlaces(s)!) a.id], ['b2', 'b3']);
    });

    test('1 位，一區：只寫一行，該區照常算', () {
      final s = signOf(lot, [rc(area: 'b2', at: nightAgo)], now: detailNight);
      expect([for (final a in s.where.areas) a.id], ['b2', 'b3']);
      expect(lines(s, detailNight), ['B2 重機專區：有車友回報無法停車・20 分鐘前，到場請再確認']);
      expect([
        for (final c in whereCards(s, lot, detailNight)) c.riderClosed,
      ], everyElement(''));
    });

    test('目前車種能停的區全被關閉：等同整點（伺服器沒有合成整點列也一樣）', () {
      final s = signOf(lot, [
        rc(area: 'b2', riders: 2, at: nightAgo),
        rc(area: 'b3', riders: 3, at: nightAgo.add(const Duration(minutes: 5))),
      ], now: detailNight);
      expect(s.verdict.status, EligibilityStatus.notAllowed);
      expect(s.verdict.riderClosed!.riders, 3);
      expect(lines(s, detailNight), ['3 位車友回報無法停車・15 分鐘前。非官方資訊']);
    });

    test('2 位整點：官方空位照常顯示，不變成空位未知', () {
      final s = fourSign(
        lot,
        VehicleType.heavy,
        const [],
        now: detailDay,
        availability: SpotAvailability([
          count(
            AvailabilityVehicle.heavy,
            available: 4,
            at: detailDay.subtract(const Duration(minutes: 1)),
          ),
        ]),
        closures: [rc(riders: 2)],
      );
      expect(s.verdict.riderClosed, isNotNull);
      expect(s.seat.kind, SeatKind.live);
      expect(s.seat.available, 4);
    });

    test('2 位整點、路段沒有自己的列：選定的路段也寫不能停', () {
      final s = signOf(street, [rc(riders: 2)]);
      expect(s.verdict.riderClosed, isNotNull);
      final open = s.areas.firstWhere((a) => a.open && a.window.now);
      expect(open.riderClosed, isTrue);
      expect(selectedVerdictPlate(s, open).main, '不能停');
      expect(verdictHeadline(s, selected: open), '大型重機現在不能停');
      // One rider about the whole spot closes no segment.
      final unsure = signOf(street, [rc()]);
      expect(unsure.areas.where((a) => a.riderClosed), isEmpty);
    });

    test('關閉不分車種：B1 只有普通機車能停，大型重機不受影響', () {
      final closed = [rc(area: 'b1', riders: 2)];
      final heavy = signOf(lot, closed);
      expect(heavy.verdict.riderClosed, isNull);
      expect(lines(heavy, detailDay), isEmpty);
      final scooter = signOf(lot, closed, vehicle: VehicleType.scooter);
      expect(scooter.verdict.riderClosed, isNotNull);
      expect(scooter.verdict.status, EligibilityStatus.notAllowed);
    });

    test('資料本來就不能停：維持原本的不能停，不寫車友回報', () {
      final s = signOf(detailCarLot, [rc(riders: 2)]);
      expect(s.denied, isTrue);
      expect(s.verdict.riderClosed, isNull);
      expect(lines(s, detailDay), isEmpty);
    });

    test('選定的路段被關閉（A10）：路牌與標題都寫不能停', () {
      final plain = signOf(street, const []);
      final open = plain.areas.firstWhere((a) => a.open && a.window.now);
      final s = signOf(street, [rc(area: open.id, riders: 2)]);
      final selected = s.areas.firstWhere((a) => a.id == open.id);
      expect(selected.riderClosed, isTrue);
      expect(selectedVerdictPlate(s, selected).main, '不能停');
      expect(verdictHeadline(s, selected: selected), '大型重機現在不能停');
      expect(selectedNote(s, selected), startsWith('選定的'));
      expect(selectedNote(s, selected), contains('車友回報無法停車'));
    });

    testWidgets('AppStore：讀到 closures，2 小時後消失；2 位才改地圖標記', (tester) async {
      var now = detailDay;
      final source = FakeSightings(const [])
        ..closures = [closure(lotId, at: ago)];
      final store = (await tester.runAsync(() async {
        SharedPreferences.setMockInitialValues({'vehicle': 'heavy'});
        final s = AppStore(
          LocalRepository(await SharedPreferences.getInstance()),
          null,
          sightingsSource: source,
          clock: () => now,
        );
        await s.init();
        return s;
      }))!;
      store.vehicle = VehicleType.heavy;
      addTearDown(store.dispose);
      final plain = store.eligible(lot).status;
      await tester.runAsync(() => store.followSightings(lot));
      expect(store.riderClosures(lot).single.riders, 1);
      expect(store.eligible(lot).status, plain);
      source.closures = [closure(lotId, riders: 2, at: ago)];
      await tester.runAsync(store.readFollowedSightings);
      expect(store.eligible(lot).status, EligibilityStatus.notAllowed);
      expect(store.eligible(lot).reason, '車友回報無法停車');
      now = ago.add(const Duration(hours: 2, minutes: 1));
      expect(store.riderClosures(lot), isEmpty);
      expect(store.eligible(lot).status, isNot(EligibilityStatus.notAllowed));
    });

    testWidgets('較早開始的輪詢晚到：不覆蓋詳情剛讀到的關閉', (tester) async {
      final counts = GatedCounts();
      final source = FakeSightings(const []);
      final store = (await tester.runAsync(() async {
        SharedPreferences.setMockInitialValues({'vehicle': 'heavy'});
        final s = AppStore(
          LocalRepository(await SharedPreferences.getInstance()),
          null,
          sightingsSource: source,
          availabilitySource: counts,
          clock: () => detailDay,
        );
        await s.init();
        return s;
      }))!;
      addTearDown(store.dispose);
      store.vehicle = VehicleType.heavy;
      store.spots = [lot];
      await tester.runAsync(() async {
        // The poll reads no closure, then waits on the counts.
        final gate = counts.gate = Completer<void>();
        final poll = store.pollAvailability();
        await Future<void>.delayed(Duration.zero);
        source.closures = [closure(lotId, riders: 2, at: ago)];
        await store.followSightings(lot);
        expect(store.riderClosures(lot).single.confirmed, isTrue);
        gate.complete();
        await poll;
      });
      expect(store.riderClosures(lot).single.confirmed, isTrue);
      expect(store.eligible(lot).status, EligibilityStatus.notAllowed);
    });

    for (final platform in platforms) {
      for (final (name, size) in layouts) {
        for (final dark in [false, true]) {
          testWidgetsOn(
            '${platform.name} $name ${dark ? '深色' : '淺色'}：預覽與詳情（②④）',
            (tester) async {
              setUpView(tester, platform, size);
              final source = FakeSightings(const [])
                ..closures = [closure(lotId, riders: 2, at: ago)];
              final store = await sightedStore(tester, source);
              await openDetail(
                tester,
                store,
                lot,
                size: size,
                dark: dark,
                full: false,
              );
              expect(tester.takeException(), isNull);
              // The preview's line; the details below say it in the card.
              expect(
                find.descendant(
                  of: find.byKey(const ValueKey('closure-line-0')),
                  matching: find.text('2 位車友回報無法停車・20 分鐘前。非官方資訊'),
                ),
                findsOneWidget,
              );
              expect(
                find.byKey(const ValueKey('spot-decision-explanation')),
                findsOneWidget,
              );
              expect(
                find.bySemanticsLabel('能不能停：現在不能停，2 位車友回報，非官方資訊'),
                findsOneWidget,
              );
              expect(find.byKey(const ValueKey('spot-report')), findsOneWidget);
              await pullUp(tester);
              expect(tester.takeException(), isNull);
              expect(find.text('現在不能停'), findsOneWidget);
              expect(find.text(riderClosedLift), findsOneWidget);
              expect(find.text('車友回報無法停車'), findsNWidgets(2));
            },
          );
          testWidgetsOn(
            '${platform.name} $name ${dark ? '深色' : '淺色'}：1 位只加一行（①③）',
            (tester) async {
              setUpView(tester, platform, size);
              final source = FakeSightings(const [])
                ..closures = [closure(lotId, at: ago)];
              final store = await sightedStore(tester, source);
              await openDetail(tester, store, lot, size: size, dark: dark);
              expect(tester.takeException(), isNull);
              expect(find.text('有車友回報無法停車・20 分鐘前，到場請再確認'), findsOneWidget);
              expect(
                find.bySemanticsLabel('有車友回報無法停車，20 分鐘前，到場請再確認'),
                findsOneWidget,
              );
              expect(find.text('現在不能停'), findsNothing);
            },
          );
        }
      }
    }
  });
}

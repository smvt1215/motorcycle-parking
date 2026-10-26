import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:motorcycle_parking/data/app_store.dart';
import 'package:motorcycle_parking/data/data_updates.dart';
import 'package:motorcycle_parking/data/repositories.dart';
import 'package:motorcycle_parking/domain/map_viewport.dart';
import 'package:motorcycle_parking/models/parking.dart';

/// Stands in for the backend: [push] is a Realtime message, [remote] is
/// what a direct read returns.
class FakeUpdates extends DataUpdates {
  FakeUpdates() : super(null);
  final _stream = StreamController<DataVersion>.broadcast();
  var remote = <DataVersion>[];
  var reads = 0;
  void push(DataSet set, int version) =>
      _stream.add((set: set, version: version));
  @override
  Stream<DataVersion> watch() => _stream.stream;
  @override
  Future<List<DataVersion>> current() async {
    reads++;
    return remote;
  }
}

class CountingParking extends ParkingRepository {
  CountingParking() : super(null);
  final loads = <MapViewport>[];
  @override
  Future<ParkingResult> inViewport(MapViewport bounds) async {
    loads.add(bounds);
    return const ParkingResult([]);
  }
}

class CountingRules extends RulesRepository {
  CountingRules() : super(null);
  var loads = 0;
  @override
  Future<List<CityRule>> load() async {
    loads++;
    return [];
  }
}

Future<void> settle() =>
    Future<void>.delayed(const Duration(milliseconds: 1300));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeUpdates updates;
  late CountingParking parking;
  late CountingRules rules;
  late AppStore store;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    updates = FakeUpdates();
    parking = CountingParking();
    rules = CountingRules();
    store = AppStore(
      LocalRepository(await SharedPreferences.getInstance()),
      null,
      parkingRepository: parking,
      rulesRepository: rules,
      dataUpdates: updates,
    )..listenForUpdates();
    addTearDown(store.dispose);
  });

  test('data_versions 列解析為資料集與版本，未知鍵忽略', () {
    expect(dataVersionFromRow({'key': 'spots', 'version': 7}), (
      set: DataSet.spots,
      version: 7,
    ));
    expect(dataVersionFromRow({'key': 'rules', 'version': 2}), (
      set: DataSet.rules,
      version: 2,
    ));
    expect(dataVersionFromRow({'key': 'photos', 'version': 1}), isNull);
    expect(dataVersionFromRow({'key': 'spots'}), isNull);
  });

  test('沒有後端時不訂閱也沒有版本可讀', () async {
    final none = DataUpdates(null);
    expect(await none.watch().toList(), isEmpty);
    expect(await none.current(), isEmpty);
  });

  test('重複呼叫 listenForUpdates 只訂閱一次', () async {
    store.listenForUpdates();
    updates.push(DataSet.spots, 2);
    await settle();
    expect(parking.loads, hasLength(1));
  });

  test('後端點位版本更新後，一秒內的連續更新只重新載入目前範圍一次', () async {
    updates
      ..push(DataSet.spots, 2)
      ..push(DataSet.spots, 3);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    updates.push(DataSet.spots, 4);
    expect(parking.loads, isEmpty);
    await settle();
    expect(parking.loads, [store.viewport]);
    expect(rules.loads, 0);
  });

  test('規則版本更新只重新讀規則，不重載點位；重複的舊版本不處理', () async {
    updates.push(DataSet.rules, 2);
    await settle();
    expect(rules.loads, 1);
    expect(parking.loads, isEmpty);
    updates
      ..push(DataSet.rules, 2)
      ..push(DataSet.rules, 1);
    await settle();
    expect(rules.loads, 1);
  });

  test('回到前景時比對版本，和已載入的不同才重新載入', () async {
    updates.remote = [
      (set: DataSet.spots, version: 1),
      (set: DataSet.rules, version: 1),
    ];
    await store.checkForUpdates();
    await settle();
    // A first read is the baseline, not a change.
    expect(parking.loads, isEmpty);
    expect(rules.loads, 0);

    store.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await settle();
    expect(updates.reads, 2);
    expect(parking.loads, isEmpty);

    updates.remote = [
      (set: DataSet.spots, version: 2),
      (set: DataSet.rules, version: 1),
    ];
    store.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await settle();
    expect(parking.loads, hasLength(1));
    expect(rules.loads, 0);

    store.didChangeAppLifecycleState(AppLifecycleState.paused);
    await settle();
    expect(updates.reads, 3);
  });

  test('Realtime 已送達的版本，回到前景時不再重載', () async {
    updates.push(DataSet.spots, 5);
    await settle();
    expect(parking.loads, hasLength(1));
    updates.remote = [(set: DataSet.spots, version: 5)];
    store.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await settle();
    expect(parking.loads, hasLength(1));
  });

  test('版本讀取失敗時安靜略過', () async {
    final failing = _FailingUpdates();
    SharedPreferences.setMockInitialValues({});
    final other = AppStore(
      LocalRepository(await SharedPreferences.getInstance()),
      null,
      parkingRepository: parking,
      dataUpdates: failing,
    );
    addTearDown(other.dispose);
    await other.checkForUpdates();
    expect(parking.loads, isEmpty);
  });

  test('釋放後不再處理更新', () async {
    SharedPreferences.setMockInitialValues({});
    final ownUpdates = FakeUpdates();
    final ownParking = CountingParking();
    final other = AppStore(
      LocalRepository(await SharedPreferences.getInstance()),
      null,
      parkingRepository: ownParking,
      dataUpdates: ownUpdates,
    )..listenForUpdates();
    other.dispose();
    ownUpdates.push(DataSet.spots, 9);
    await settle();
    expect(ownParking.loads, isEmpty);
  });
}

class _FailingUpdates extends DataUpdates {
  _FailingUpdates() : super(null);
  @override
  Future<List<DataVersion>> current() => Future.error(StateError('offline'));
}

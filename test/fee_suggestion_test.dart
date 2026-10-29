import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:motorcycle_parking/features/report/condition_fields.dart';
import 'package:motorcycle_parking/features/report/fee_suggestion.dart';
import 'package:motorcycle_parking/models/fee.dart';
import 'package:motorcycle_parking/models/parking.dart';
import 'package:motorcycle_parking/models/parking_condition.dart';
import 'package:motorcycle_parking/models/space_kind.dart';
import 'package:motorcycle_parking/ui/fee_editor.dart';

const current = Fee(
  scooter: Rate(FeeMode.hourly, amount: 10, perMinutes: 60),
  heavy: Rate(FeeMode.hourly, amount: 20, perMinutes: 60),
  car: Rate(FeeMode.hourly, amount: 40, perMinutes: 60),
);

void main() {
  test('a suggestion sends only what changes; a cleared vehicle is null', () {
    final edits = <FeeVehicle, Rate?>{
      FeeVehicle.scooter: current.scooter, // the same: no change
      FeeVehicle.heavy: const Rate(FeeMode.perVisit, amount: 40),
      FeeVehicle.car: null,
    };
    expect(proposedFee(current, edits), {
      'heavy': {'mode': 'per_visit', 'amount': 40},
      'car': null,
    });
    // Clearing what is not there is no change either.
    expect(proposedFee(const Fee(), {FeeVehicle.car: null}), isEmpty);
    expect(feeChangeLines(current, edits), [
      '大型重機費率：每小時 20 元 → 每次 40 元（隔日是否另計未確認）',
      '汽車費率：每小時 40 元 → $unconfirmedFeeText',
    ]);
    expect(feeKeptLine(current, edits), '普通機車維持目前');
    expect(feeKeptLine(current, const {}), isNull);
    expect(incompleteEdits({FeeVehicle.heavy: const Rate(FeeMode.perVisit)}), [
      FeeVehicle.heavy,
    ]);
  });

  test('a 汽機共用 period keeps the weekdays it was stored with', () {
    final stored = ParkingCondition.fromJson({
      'bay': 'car',
      'use': 'share',
      'share': 'car_motorcycle',
      'schedule': [
        {
          'days': ['mon', 'wed'],
          'from': '20:00',
          'to': '07:00',
          'vehicles': ['scooter'],
        },
      ],
    });
    final draft = ConditionDraft.of(stored, SpaceType.flexShared)
      ..setCharge(SpaceKind.shared, Charge.toll);
    final sent = draft.conditionFor(SpaceKind.shared)!;
    expect(sent.schedule.single.days, ['mon', 'wed']);
    expect(conditionSummary(sent), '收費、共用時段 週一、週三 20:00–隔日 07:00 普通機車');
  });

  test(
    'limits and a 普大共用 use the form cannot show stay while the kind does',
    () {
      final stored = ParkingCondition.fromJson({
        'bay': 'motorcycle',
        'limits': [
          {'kind': 'time_limit', 'max_minutes': 20},
          {'kind': 'ev_only'},
        ],
        'use': 'share',
        'share': 'scooter_heavy',
      });
      final draft = ConditionDraft.of(stored, SpaceType.evMotorcycle);
      expect(draft.conditionFor(SpaceKind.evMotorcycle), stored);
      // A heavy bay that only takes EVs keeps its bay.
      final heavyEv = ParkingCondition.fromJson({
        'bay': 'heavy',
        'limits': [
          {'kind': 'ev_only'},
        ],
      });
      expect(
        ConditionDraft.of(
          heavyEv,
          SpaceType.evMotorcycle,
        ).conditionFor(SpaceKind.evMotorcycle),
        heavyEv,
      );
    },
  );

  test(
    'added conditions convert to the space type sent (§1.3, decision 62)',
    () {
      final draft = ConditionDraft()..charge = Charge.toll;
      expect(draft.conditionFor(SpaceKind.motorcycle)!.toJson(), {
        'bay': 'motorcycle',
        'use': 'usual',
        'charge': 'toll',
      });
      expect(draft.typeFor(SpaceKind.motorcycle), SpaceType.paidMotorcycle);
      // 一般機車格＋限時 is still stored as timedMotorcycle.
      draft
        ..timed = true
        ..maxMinutes.text = '30';
      expect(draft.typeFor(SpaceKind.motorcycle), SpaceType.timedMotorcycle);
      // 普大共用 is stored as the toll or free bay it is, without periods
      // (decision 64).
      draft
        ..timed = false
        ..charge = Charge.free
        ..share = ShareKind.scooterHeavy
        ..slots.add(SlotDraft()..vehicles = {SlotVehicle.scooter});
      expect(draft.typeFor(SpaceKind.shared), SpaceType.freeMotorcycle);
      expect(draft.conditionFor(SpaceKind.shared)!.toJson(), {
        'bay': 'motorcycle',
        'use': 'share',
        'share': 'scooter_heavy',
        'charge': 'free',
      });
      // 汽車＆機車 carries its periods.
      draft.share = ShareKind.carMotorcycle;
      expect(draft.typeFor(SpaceKind.shared), SpaceType.flexShared);
      expect(draft.conditionFor(SpaceKind.shared)!.schedule, hasLength(1));
      // 時段性禁停 does not change the space type.
      draft
        ..banned = true
        ..bans.add(SlotDraft(allDay: false));
      draft.bans.single
        ..days = 'weekday'
        ..from.text = '07:00'
        ..to.text = '09:00';
      final heavy = draft.conditionFor(SpaceKind.heavyOnly)!;
      expect(heavy.toJson()['limits'], [
        {
          'kind': 'no_parking',
          'periods': [
            {'days': 'weekday', 'from': '07:00', 'to': '09:00'},
          ],
        },
      ]);
      expect(draft.typeFor(SpaceKind.heavyOnly), SpaceType.heavyOnly);
      expect(draft.summary(SpaceKind.heavyOnly), '大型重機專用格・免費・時段性禁停');
    },
  );

  test('an untouched condition compares equal whatever its limits order', () {
    // Built directly, not read through fromJson (which sorts them).
    const stored = ParkingCondition(
      bay: Bay.motorcycle,
      use: BayUse.usual,
      charge: Charge.toll,
      limits: [
        ParkingLimit(LimitKind.evOnly),
        ParkingLimit(LimitKind.timeLimit, maxMinutes: 30),
      ],
    );
    final draft = ConditionDraft.of(stored, SpaceType.evMotorcycle);
    expect(draft.conditionFor(SpaceKind.evMotorcycle), stored);
  });

  test('every kind and tick sends a condition validate.ts accepts', () {
    for (final kind in SpaceKind.painted) {
      for (final share in [...ShareKind.values, null]) {
        if ((kind == SpaceKind.shared) != (share != null)) continue;
        for (final charge in [Charge.toll, Charge.free, null]) {
          for (var mask = 0; mask < 4; mask++) {
            final draft = ConditionDraft()
              ..charge = charge
              ..share = share
              ..timed = mask & 1 != 0
              ..banned = mask & 2 != 0
              ..maxMinutes.text = '20'
              ..bans.add(SlotDraft(allDay: false));
            draft.bans.single
              ..from.text = '07:00'
              ..to.text = '09:00';
            final c = draft.conditionFor(kind)!;
            final why = '$kind $share $charge $mask';
            // The form asks 收費嗎 where the space type needs it.
            if (draft.needsCharge(kind) && charge == null) {
              expect(validCondition(c.toJson()), isFalse, reason: why);
              continue;
            }
            expect(validCondition(c.toJson()), isTrue, reason: why);
            expect(
              legacySpaceType(c, offStreet: false),
              draft.typeFor(kind),
              reason: why,
            );
          }
        }
      }
    }
  });

  test('periods of another kind stay while the kind does', () {
    final stored = ParkingCondition.fromJson({
      'bay': 'heavy',
      'use': 'usual',
      'schedule': [
        {
          'days': 'weekday',
          'from': '08:00',
          'to': '18:00',
          'vehicles': ['heavy'],
        },
      ],
    });
    final draft = ConditionDraft.of(stored, SpaceType.heavyOnly);
    expect(draft.conditionFor(SpaceKind.heavyOnly), stored);
    // Another kind starts without them.
    expect(draft.conditionFor(SpaceKind.car)!.schedule, isEmpty);
  });

  test('a follow reads with the suggested rates, worked out (#140)', () {
    final edits = <FeeVehicle, Rate?>{
      FeeVehicle.heavy: const Rate(FeeMode.sameAsCar),
    };
    expect(feeChangeLines(current, edits), ['大型重機費率：每小時 20 元 → 每小時 40 元']);
  });

  Future<void> pump(
    WidgetTester tester,
    double width,
    Widget child, {
    double scale = 1,
    bool dark = false,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 1400);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: dark ? Brightness.dark : Brightness.light),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
          body: Form(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [child],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final (width, scale, dark) in [
    (320.0, 1.6, true),
    (390.0, 1.0, false),
    (700.0, 1.0, false),
    (1280.0, 1.0, true),
  ]) {
    testWidgets('收費建議在 ${width.toInt()} px、$scale 倍不溢出，按鈕 ≥ 48', (
      tester,
    ) async {
      var edits = <FeeVehicle, Rate?>{};
      await pump(
        tester,
        width,
        StatefulBuilder(
          builder: (context, setState) => FeeSuggestionEditor(
            current: current,
            edits: edits,
            errors: const {
              FeeVehicle.heavy: '大型重機比照汽車費率，但還沒填汽車費率。請填汽車費率，或改選其他收費方式。',
            },
            onChanged: (v) => setState(() => edits = v),
          ),
        ),
        scale: scale,
        dark: dark,
      );
      await tester.tap(find.byKey(const ValueKey('suggest-clear-car')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('suggest-edit-heavy')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('fee-mode-heavy-per_visit')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      for (final key in [
        'suggest-edit-scooter',
        'suggest-edit-heavy',
        'suggest-clear-scooter',
        'suggest-keep-car',
      ]) {
        final size = tester.getSize(find.byKey(ValueKey(key)));
        expect(size.height, greaterThanOrEqualTo(48), reason: key);
        expect(
          tester.getRect(find.byKey(ValueKey(key))).right,
          lessThanOrEqualTo(width),
          reason: key,
        );
      }
      expect(find.text('改成：$unconfirmedFeeText'), findsOneWidget);
      expect(find.byKey(const ValueKey('suggest-error-heavy')), findsOneWidget);
    });

    testWidgets('停放條件欄位在 ${width.toInt()} px、$scale 倍不溢出', (tester) async {
      final draft = ConditionDraft()
        ..share = ShareKind.carMotorcycle
        ..banned = true
        ..timed = true
        ..bans.add(SlotDraft(allDay: false))
        ..slots.add(SlotDraft()..allDay = false);
      draft.slots.single.from.text = '20:00';
      draft.slots.single.to.text = '07:00';
      await pump(
        tester,
        width,
        StatefulBuilder(
          builder: (context, setState) => ConditionFields(
            kind: SpaceKind.shared,
            draft: draft,
            holdHint: '普大共用的免費格較少見，請附上公告連結，審核會比較快。',
            onChanged: () => setState(() {}),
          ),
        ),
        scale: scale,
        dark: dark,
      );
      expect(tester.takeException(), isNull);
      expect(
        tester.getSize(find.byKey(const ValueKey('condition-slot-add'))).height,
        greaterThanOrEqualTo(48),
      );
      for (final segment
          in find.byKey(const ValueKey('condition-charge')).evaluate()) {
        expect(segment.size!.width, lessThanOrEqualTo(width));
      }
    });
  }
}

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:motorcycle_parking/admin/admin_app.dart';
import 'package:motorcycle_parking/admin/admin_controller.dart';
import 'package:motorcycle_parking/admin/review/review_controller.dart';
import 'package:motorcycle_parking/admin/review/review_models.dart';
import 'package:motorcycle_parking/admin/review/review_page.dart';
import 'package:motorcycle_parking/admin/spots/spot_models.dart';
import 'package:motorcycle_parking/admin/spots/spots_controller.dart';
import 'package:motorcycle_parking/models/fee.dart';

import 'fake_admin_gateway.dart';
import 'fold_helpers.dart';

import '../fee_editor_steps.dart';

/// Structured fees in the admin spot form and the review queue.
void main() {
  const hourly = Fee(
    scooter: Rate(FeeMode.hourly, amount: 20, perMinutes: 60),
    heavy: Rate(FeeMode.sameAsScooter),
  );
  const hourlyJson = {
    'scooter': {'mode': 'hourly', 'amount': 20, 'per_minutes': 60},
    'heavy': {'mode': 'same_as_scooter'},
  };
  const hourlyNote = '機車每小時 20 元；大型重機每小時 20 元';

  test('費率文字與資料庫 fee_note_of 的 pgTAP 案例一致', () {
    // supabase/tests/admin_spot_fee_test.sql pins the same sentences.
    String note(Map<String, Object> json) => feeNoteOf(Fee.tryParse(json));
    expect(note(const {}), '請依現場公告');
    expect(note(hourlyJson), hourlyNote);
    expect(
      note({
        'scooter': {'mode': 'free'},
        'heavy': {
          'mode': 'hourly',
          'amount': 20,
          'per_minutes': 60,
          'daily_cap': 100,
        },
      }),
      '機車免費；大型重機每小時 20 元，當日上限 100 元',
    );
    expect(
      note({
        'scooter': {'mode': 'hourly', 'amount': 10, 'per_minutes': 30},
      }),
      '機車每 30 分鐘 10 元；大型重機費率未提供',
    );
    expect(
      note({
        'scooter': {'mode': 'hourly', 'amount': 40, 'per_minutes': 120},
      }),
      '機車每 2 小時 40 元；大型重機費率未提供',
    );
    expect(
      note({
        'heavy': {'mode': 'per_visit', 'amount': 50},
      }),
      '大型重機每次 50 元',
    );
    expect(
      note({
        'scooter': {'mode': 'per_visit', 'amount': 20, 'renew': 'none'},
        'heavy': {'mode': 'same_as_car'},
      }),
      '機車每次 20 元，停多久都只收一次；大型重機費率未提供',
    );
    expect(
      note({
        'scooter': {'mode': 'not_applicable'},
        'heavy': {'mode': 'not_applicable'},
      }),
      '請依現場公告',
    );
  });

  test('Fee.tryParse 整筆接受或拒絕', () {
    expect(Fee.tryParse(hourlyJson), hourly);
    expect(Fee.tryParse({'car': <String, Object>{}}), isNull);
    expect(
      Fee.tryParse({
        'scooter': {'mode': 'same_as_car'},
      }),
      isNull,
    );
    expect(Fee.tryParse({'scooter': null}), isNull);
    expect(Fee.tryParse('免費'), isNull);
    expect(
      const Fee(
        scooter: Rate(FeeMode.perVisit, amount: 10001, renew: Renew.midnight),
      ).valid,
      isFalse,
    );
    expect(hourly.valid, isTrue);
  });

  group('點位表單的費率', () {
    late FakeAdminGateway gateway;
    late SpotsController spots;

    setUp(() async {
      gateway = FakeAdminGateway(access: adminAal2);
      spots = SpotsController(gateway);
      await spots.search();
    });
    tearDown(() => gateway.dispose());

    test('設定費率時一起送出 fee 與由它產生的 fee_note', () async {
      await spots.open(communityId);
      expect(spots.draft['fee'], isNull);
      expect(spots.feeStructured, isFalse);
      spots.setFee(hourly);
      expect(spots.feeStructured, isTrue);
      expect(spots.changes, {'fee': hourlyJson, 'fee_note': hourlyNote});
      expect(await spots.save('依公告牌'), isTrue);
      expect(gateway.spotUpdates.single.$2, {
        'fee': hourlyJson,
        'fee_note': hourlyNote,
      });
      // Reloaded from the saved row, the form is clean again.
      expect(spots.draft['fee'], hourly);
      expect(spots.dirty, isFalse);
    });

    test('舊資料只有文字：不猜價格，改回未確認時文字還原', () async {
      await spots.open(communityId);
      final legacy = spots.draft['fee_note'];
      spots.setFee(const Fee());
      expect(spots.dirty, isFalse);
      spots.setFee(const Fee(scooter: Rate(FeeMode.free)));
      expect(spots.draft['fee_note'], '機車免費；大型重機費率未提供');
      spots.setFee(const Fee());
      expect(spots.draft['fee_note'], legacy);
      expect(spots.changes, isEmpty);
    });

    test('已有費率：內容相同不算修改，清除後文字回到預設', () async {
      gateway.spotRows[communityId]!
        ..['fee'] = hourlyJson
        ..['fee_note'] = hourlyNote;
      await spots.open(communityId);
      expect(spots.draft['fee'], hourly);
      spots.setFee(
        const Fee(
          scooter: Rate(FeeMode.hourly, amount: 20, perMinutes: 60),
          heavy: Rate(FeeMode.sameAsScooter),
        ),
      );
      expect(spots.dirty, isFalse);
      spots.setFee(const Fee());
      expect(spots.changes, {'fee': null, 'fee_note': '請依現場公告'});
    });

    test('金額未填完或超出範圍時不能儲存', () async {
      await spots.open(communityId);
      final before = spots.draft['fee_note'];
      spots.setFee(const Fee(scooter: Rate(FeeMode.hourly, perMinutes: 60)));
      expect(spots.draft['fee_note'], before);
      expect(spots.errors['fee'], contains('請填完收費金額'));
      expect(await spots.save(''), isFalse);
      spots.setFee(
        const Fee(
          scooter: Rate(FeeMode.perVisit, amount: 20000, renew: Renew.midnight),
        ),
      );
      expect(spots.errors['fee'], contains('0 到 10000'));
      expect(gateway.spotUpdates, isEmpty);
    });

    test('隱藏點位時保留尚未儲存的費率', () async {
      await spots.open(communityId);
      spots.setFee(hourly);
      expect(await spots.setHidden(true), isTrue);
      expect(spots.draft['fee'], hourly);
      expect(spots.changes['fee'], hourlyJson);
    });

    test('新增點位可帶費率', () async {
      spots.startNew(SpotKind.community, 25.05, 121.52);
      spots.setFee(const Fee(scooter: Rate(FeeMode.free)));
      expect(spots.changes['fee'], {
        'scooter': {'mode': 'free'},
      });
      expect(spots.changes['fee_note'], '機車免費；大型重機費率未提供');
    });
  });

  group('超過 200 字的費率句子（設計 §2.5）', () {
    final longFee = Fee.fromJson({
      'car': {
        'mode': 'by_time',
        'periods': [
          for (final d in ['mon', 'tue', 'wed', 'thu', 'fri', 'sat'])
            {
              'days': [d],
              'from': '23:00',
              'to': '22:00',
              'rate': {
                'mode': 'per_visit',
                'amount': 9999,
                'renew': 'midnight',
                'extension_amount': 9999,
              },
            },
        ],
      },
    });
    final longNote = feeNoteOf(longFee);
    final community = sampleSpots()[communityId]!;

    test('句子本身可超過 200 字，自由文字維持 200', () {
      expect(longNote.length, greaterThan(200));
      expect(feeNoteFits(longNote, longFee), isTrue);
      expect(feeNoteFits('$longNote。', longFee), isFalse);
      expect(feeNoteFits(longNote, null), isFalse);
      expect(feeNoteFits('元' * 200, null), isTrue);
      expect(feeNoteFits('元' * 201, null), isFalse);
    });

    test('審核頁可採納超過 200 字的費率句子', () {
      expect(
        validatePatch({
          'fee': longFee.toJson(),
          'fee_note': longNote,
        }, community),
        isNull,
      );
      expect(
        validatePatch({'fee_note': '元' * 201}, community),
        contains('200 個字以內'),
      );
    });

    test('點位表單可儲存超過 200 字的費率句子', () {
      final field = spotField('fee_note');
      expect(validateSpotField(field, longNote, fee: longFee), isNull);
      expect(validateSpotField(field, longNote), contains('200 個字以內'));
      expect(
        validateSpotField(field, '元' * 201, fee: longFee),
        contains('200 個字以內'),
      );
    });
  });

  group('費率建議逐車種合併（設計 §5.4）', () {
    final community = sampleSpots()[communityId]!;
    const car = {'mode': 'hourly', 'amount': 40, 'per_minutes': 60};
    final spot = ReviewSpot(
      sourceId: communityId,
      official: false,
      values: {
        ...community.values,
        'fee': const {
          'car': car,
          'scooter': {'mode': 'free'},
        },
        'fee_note': '機車免費；汽車每小時 40 元；大型重機費率未提供',
      },
    );
    ReviewReport report(Map<String, Object?> fee) => ReviewReport(
      id: 'r-merge',
      sourceId: communityId,
      reason: '收費資訊',
      field: 'fee_note',
      proposed: {'fee': fee},
      createdAt: reportTime,
    );

    test('只送有改的車種，其他車種保留現值', () {
      final proposal = initialProposal(
        report({
          'heavy': {'mode': 'same_as_car'},
        }),
        spot,
      );
      expect(proposal['fee'], {
        'car': car,
        'scooter': {'mode': 'free'},
        'heavy': {'mode': 'same_as_car'},
      });
      expect(proposal['fee_note'], '機車免費；大型重機每小時 40 元；汽車每小時 40 元');
      expect(validatePatch(applicablePatch(proposal, spot), spot), isNull);
    });

    test('車種送 null 才清除', () {
      final proposal = initialProposal(report({'scooter': null}), spot);
      expect(proposal['fee'], {'car': car});
      expect(proposal['fee_note'], '汽車每小時 40 元；大型重機費率未提供');
      final cleared = initialProposal(
        report({'scooter': null, 'car': null}),
        spot,
      );
      expect(cleared['fee'], isNull);
      expect(cleared['fee_note'], '請依現場公告');
    });
  });

  group('審核頁的費率建議', () {
    final community = sampleSpots()[communityId]!;
    final withFee = ReviewSpot(
      sourceId: communityId,
      official: false,
      values: {...community.values, 'fee': hourlyJson, 'fee_note': hourlyNote},
    );
    final feeReport = ReviewReport(
      id: 'r-fee',
      sourceId: communityId,
      reason: '收費資訊：建議「每次 30 元，隔日另計（大型重機比照機車費率）」',
      field: 'fee_note',
      proposed: const {
        'fee': {
          'scooter': {'mode': 'per_visit', 'amount': 30, 'renew': 'midnight'},
          'heavy': {'mode': 'same_as_scooter'},
        },
        'fee_note': '每次 30 元，隔日另計（大型重機比照機車費率）',
      },
      createdAt: reportTime,
    );

    test('App 的費率建議可直接套用，差異表以內容比較', () {
      final patch = applicablePatch(
        initialProposal(feeReport, community),
        community,
      );
      expect(patch.keys, ['fee', 'fee_note']);
      expect(ignoredKeys(feeReport.proposed!, community), isEmpty);
      expect(validatePatch(patch, community), isNull);
      expect(
        formatValue('fee', patch['fee']),
        '機車每次 30 元，隔日另計；大型重機每次 30 元，隔日另計',
      );
      expect(formatValue('fee', null), '未設定');
      expect(sameValue('fee', {...hourlyJson}, hourly), isTrue);
      expect(sameValue('fee', const <String, Object>{}, null), isTrue);
    });

    test('不合規則的費率建議另列，不進修改內容', () {
      final proposal = {
        'fee': {
          'scooter': {'mode': 'monthly', 'amount': 300},
        },
        'fee_note': '月租 300 元',
      };
      expect(applicablePatch(proposal, community), {'fee_note': '月租 300 元'});
      expect(ignoredKeys(proposal, community), ['fee']);
    });

    test('已有費率的點位，只改收費資訊會被擋下', () {
      expect(
        validatePatch({'fee_note': '每次 30 元'}, withFee),
        contains('加入「費率」'),
      );
      expect(
        validatePatch({'fee': hourlyJson, 'fee_note': '每小時 20 元'}, withFee),
        contains('一致'),
      );
      expect(
        validatePatch({'fee': null, 'fee_note': '每次 30 元'}, withFee),
        isNull,
      );
      expect(validatePatch({'fee_note': '每次 30 元'}, community), isNull);
      expect(
        validatePatch({
          'fee': const Fee(scooter: Rate(FeeMode.hourly, perMinutes: 60)),
        }, community),
        contains('請填完收費金額'),
      );
    });

    test('修改費率時收費資訊跟著更新，送出為 JSON', () async {
      final gateway = FakeAdminGateway(access: adminAal2)
        ..reports = [feeReport];
      addTearDown(gateway.dispose);
      final review = ReviewController(gateway);
      await review.load();
      final report = review.queue.single;
      review.startEdit(report);
      review.setDraft('fee', hourly);
      expect(review.draft['fee_note'], hourlyNote);
      final (patch, problem) = review.patchFor(
        report,
        ReviewDecision.acceptEdited,
      );
      expect(problem, isNull);
      expect(patch, {'fee': hourlyJson, 'fee_note': hourlyNote});
    });
  });

  group('費率畫面', () {
    late FakeAdminGateway gateway;
    late AdminController controller;

    setUp(() => gateway = FakeAdminGateway(access: adminAal2));
    tearDown(() async {
      controller.dispose();
      await gateway.dispose();
    });

    Future<void> show(
      WidgetTester tester,
      String path,
      Size size, {
      double textScale = 1,
      ThemeMode mode = ThemeMode.light,
    }) async {
      controller = AdminController(gateway);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = textScale;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await controller.refresh();
      await tester.pumpWidget(
        AdminApp(
          controller: controller,
          initialLocation: path,
          themeMode: mode,
          reviewMapBuilder: (_, _) => const SizedBox(),
          locationMapBuilder: (_, _) => const SizedBox(),
          // The spots page map is a Google map; tests stand in for it.
          spotMapBuilder: (_, _) => const SizedBox(),
        ),
      );
      await tester.pumpAndSettle();
      // The spot form opens at its name; the rates fold below (decision 57).
      if (path.startsWith('/spots/')) await openFold(tester, '費率');
    }

    Finder scrollable(String prefix) => find
        .descendant(
          of: find.byWidgetPredicate(
            (w) =>
                w.key is ValueKey<String> &&
                (w.key! as ValueKey<String>).value.startsWith(prefix),
          ),
          matching: find.byType(Scrollable),
        )
        .first;

    /// Brings [target] into view in the spot form, built or not.
    Future<void> reach(WidgetTester tester, Finder target) async {
      if (target.evaluate().isEmpty) {
        await tester.scrollUntilVisible(
          target,
          200,
          scrollable: scrollable('spot-form-'),
        );
      }
      // Mid-screen: the form's action bar covers its bottom edge.
      await Scrollable.ensureVisible(
        tester.element(target.first),
        alignment: .3,
      );
      await tester.pumpAndSettle();
    }

    Future<void> choose(
      WidgetTester tester,
      String vehicle,
      String mode,
    ) async {
      if (find.byKey(ValueKey('fee-open-$vehicle')).evaluate().isEmpty) {
        final row = find.byKey(ValueKey('fee-row-$vehicle'));
        await reach(tester, row);
        await tester.tap(row);
        await tester.pumpAndSettle();
      }
      final pill = find.byKey(ValueKey('fee-mode-$vehicle-$mode'));
      await reach(tester, pill);
      await tester.tap(pill);
      await tester.pumpAndSettle();
    }

    for (final (size, scale, mode) in const [
      (Size(320, 640), 1.0, ThemeMode.light),
      (Size(320, 640), 1.6, ThemeMode.dark),
      (Size(390, 844), 1.0, ThemeMode.dark),
      (Size(700, 900), 1.0, ThemeMode.light),
      (Size(1280, 900), 1.0, ThemeMode.light),
    ]) {
      testWidgets('點位表單的費率在 ${size.width.round()} px、${scale}x 可編輯且不溢出', (
        tester,
      ) async {
        await show(
          tester,
          '/spots/$communityId',
          size,
          textScale: scale,
          mode: mode,
        );
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('fee-legacy')),
          200,
          scrollable: scrollable('spot-form-'),
        );
        expect(find.byKey(const ValueKey('fee-legacy')), findsOneWidget);
        expect(find.byKey(const ValueKey('fee-note-plate')), findsNothing);
        await choose(tester, 'scooter', 'hourly');
        final amount = feeField('amount', 'scooter');
        await tester.ensureVisible(amount);
        await tester.enterText(amount, '20');
        await tester.pumpAndSettle();
        // Stacked on phones and in the narrow two-pane column.
        if (size.width <= 700) {
          final period = find.text('計費時間');
          expect(
            tester.getRect(period).top >= tester.getRect(amount).bottom,
            isTrue,
          );
        }
        await choose(tester, 'heavy', 'same_as');
        final plate = find.byKey(const ValueKey('fee-note-plate'));
        await reach(tester, plate);
        // The app's notice board: the follow's amount worked out (#140).
        expect(
          find.descendant(of: plate, matching: find.text('每小時 20 元')),
          findsNWidgets(2),
        );
        expect(
          find.descendant(of: plate, matching: find.textContaining('比照')),
          findsNothing,
        );
        final save = find.text('儲存並關閉').hitTestable();
        expect(save, findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(save);
        await tester.pumpAndSettle();
        expect(gateway.spotUpdates.single.$2, {
          'fee': hourlyJson,
          'fee_note': hourlyNote,
        });
        // The list shown after saving overflows at 320 px and 1.6x on main
        // too; that is outside this form and not asserted here.
        tester.takeException();
      });
    }

    for (final size in const [
      Size(320, 640),
      Size(390, 844),
      Size(1280, 900),
    ]) {
      testWidgets('審核頁修改費率在 ${size.width.round()} px 不溢出', (tester) async {
        gateway.reports = [
          ReviewReport(
            id: 'r-fee',
            sourceId: communityId,
            reason: '收費資訊',
            field: 'fee_note',
            proposed: const {
              'fee': {
                'scooter': {
                  'mode': 'per_visit',
                  'amount': 30,
                  'renew': 'midnight',
                },
              },
              'fee_note': '機車每次 30 元，隔日另計；大型重機費率未提供',
            },
            createdAt: reportTime,
          ),
        ];
        await show(tester, '/review/r-fee', size);
        await tester.scrollUntilVisible(
          find.text('建議變更'),
          200,
          scrollable: find.byType(Scrollable).last,
        );
        await tester.drag(find.text('建議變更'), const Offset(0, -200));
        await tester.pumpAndSettle();
        expect(
          find.widgetWithText(ChangeBand, '機車每次 30 元，隔日另計；大型重機費率未提供'),
          findsWidgets,
        );
        await tester.tap(find.text('修改後套用'));
        await tester.pumpAndSettle();
        await chooseFeeMode(tester, 'heavy', 'free');
        await tester.ensureVisible(find.text('套用修改'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('套用修改'));
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 7));
        await tester.pumpAndSettle();
        expect(gateway.resolved.single.$3, {
          'fee': {
            'scooter': {'mode': 'per_visit', 'amount': 30, 'renew': 'midnight'},
            'heavy': {'mode': 'free'},
          },
          'fee_note': '機車每次 30 元，隔日另計；大型重機免費',
        });
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('無法讀成整數的當日上限擋下儲存，不會被當成未填', (tester) async {
      gateway.spotRows[communityId]!
        ..['fee'] = {
          'scooter': {
            'mode': 'hourly',
            'amount': 20,
            'per_minutes': 60,
            'daily_cap': 100,
          },
        }
        ..['fee_note'] = '每小時 20 元，當日上限 100 元（大型重機費率未提供）';
      await show(tester, '/spots/$communityId', const Size(390, 844));
      final more = find.byKey(const ValueKey('fee-more-scooter'));
      await reach(tester, more);
      await tester.tap(more);
      await tester.pumpAndSettle();
      final cap = feeField('cap', 'scooter');
      await reach(tester, cap);
      await tester.enterText(cap, '100.5');
      await tester.pumpAndSettle();
      expect(find.text('金額請填 0 到 10000 的整數'), findsOneWidget);
      // The plate keeps the stored text instead of a broken sentence.
      expect(find.text('每小時 20 元，當日上限 100 元（大型重機費率未提供）'), findsOneWidget);
      await tester.tap(find.text('儲存並關閉').hitTestable());
      await tester.pumpAndSettle();
      expect(gateway.spotUpdates, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('不在選單內的合法時間照樣顯示為目前選項', (tester) async {
      gateway.spotRows[communityId]!
        ..['fee'] = {
          'scooter': {'mode': 'hourly', 'amount': 15, 'per_minutes': 90},
          'heavy': {'mode': 'per_visit', 'amount': 50, 'renew': 'none'},
        }
        ..['fee_note'] = '機車每 90 分鐘 15 元；大型重機每次 50 元，停多久都只收一次';
      await show(tester, '/spots/$communityId', const Size(1280, 900));
      final period = find.text('每 90 分鐘');
      await tester.scrollUntilVisible(
        period,
        200,
        scrollable: scrollable('spot-form-'),
      );
      expect(period, findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('編輯 fee={} 點位的費率文字可儲存', (tester) async {
      // A stored {} names no vehicle: no structured fee, as the server's
      // fee_note_matches reads it (202610270021_empty_fee_semantics.sql).
      gateway.spotRows[communityId]!
        ..['fee'] = <String, Object>{}
        ..['fee_note'] = '請依現場公告';
      await show(tester, '/spots/$communityId', const Size(390, 844));
      // Read as a spot with text only, so the text is an input.
      final legacy = find.byKey(const ValueKey('fee-legacy'));
      await tester.scrollUntilVisible(
        legacy,
        200,
        scrollable: scrollable('spot-form-'),
      );
      final note = find.widgetWithText(TextFormField, '費率說明文字');
      await tester.scrollUntilVisible(
        note,
        200,
        scrollable: scrollable('spot-form-'),
      );
      await tester.enterText(note, '每小時 20 元');
      await tester.pumpAndSettle();
      await tester.tap(find.text('儲存並關閉').hitTestable());
      await tester.pumpAndSettle();
      // Only the text is sent; the stored {} is not rewritten.
      expect(gateway.spotUpdates.single.$2, {'fee_note': '每小時 20 元'});
      expect(tester.takeException(), isNull);
    });

    testWidgets('審核頁改費率時，收費資訊直接顯示依費率產生的文字', (tester) async {
      gateway.reports = [
        ReviewReport(
          id: 'r-fee2',
          sourceId: communityId,
          reason: '收費資訊',
          field: 'fee_note',
          proposed: const {
            'fee': {
              'scooter': {
                'mode': 'per_visit',
                'amount': 30,
                'renew': 'midnight',
              },
            },
            'fee_note': '機車每次 30 元，隔日另計；大型重機費率未提供',
          },
          createdAt: reportTime,
        ),
      ];
      await show(tester, '/review/r-fee2', const Size(1280, 900));
      await tester.tap(find.text('修改後套用'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('edit-r-fee2-fee_note')), findsNothing);
      final amount = find.widgetWithText(TextFormField, '首次多少錢');
      await tester.ensureVisible(amount);
      await tester.enterText(amount, '40');
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('derived-r-fee2-fee_note')),
          matching: find.text('機車每次 40 元，隔日另計；大型重機費率未提供'),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('格位建議帶停放條件（C5a）', () {
    final community = sampleSpots()[communityId]!;
    final spot = ReviewSpot(
      sourceId: communityId,
      official: false,
      values: {...community.values, 'space_type': 'paidMotorcycle'},
    );
    const timed = {
      'bay': 'motorcycle',
      'use': 'usual',
      'charge': 'toll',
      'limits': [
        {'kind': 'time_limit', 'max_minutes': 20},
      ],
    };

    test('條件隨格位類型一起套用，並以一句話顯示', () {
      final patch = applicablePatch({
        'space_type': 'timedMotorcycle',
        'condition': timed,
      }, spot);
      expect(patch, {'space_type': 'timedMotorcycle', 'condition': timed});
      expect(validatePatch(patch, spot), isNull);
      expect(formatValue('condition', timed), '收費、限停 20 分鐘');
      expect(formatValue('condition', null), '未提供');
      expect(sameValue('condition', {...timed}, {...timed}), isTrue);
    });

    test('條件與格位類型不一致、或格式不對時不送出', () {
      expect(validatePatch({'condition': timed}, spot), contains('格位類型不一致'));
      expect(
        ignoredKeys({
          'condition': {'bay': 'bus'},
        }, spot),
        ['condition'],
      );
      // Dropping a stored condition needs no space type.
      expect(validatePatch({'condition': null}, spot), isNull);
    });
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:motorcycle_parking/models/fee.dart';

/// The fee cases every side runs (parking_contract_cases.json): the shape
/// valid_fee() and validFee in _shared/fee.ts accept, and the sentences
/// fee_note_of() and feeNoteOf there write.
void main() {
  final cases = jsonDecode(
    File('supabase/functions/_shared/parking_contract_cases.json')
        .readAsStringSync(),
  ) as Map<String, Object?>;
  final limit = jsonDecode(
    File('supabase/functions/_shared/fee_note_limit.json').readAsStringSync(),
  ) as Map<String, Object?>;

  test('validFee accepts exactly the valid shared cases', () {
    final fees = (cases['fees']! as List).cast<Map<String, Object?>>();
    expect(fees, isNotEmpty);
    for (final c in fees) {
      expect(validFee(c['fee']), c['valid'], reason: c['name'] as String);
      // A valid fee also parses whole; an invalid one does not.
      expect(
        Fee.tryParse(c['fee']) != null,
        c['valid'],
        reason: c['name'] as String,
      );
    }
  });

  test('feeNoteOf writes the shared sentences', () {
    final notes = (cases['fee_notes']! as List).cast<Map<String, Object?>>();
    expect(notes, isNotEmpty);
    for (final c in notes) {
      final name = c['name'] as String;
      expect(validFee(c['fee']), isTrue, reason: name);
      expect(feeNoteOfJson(c['fee']), c['note'], reason: name);
      // Parsing and writing back keeps the sentence: no key is lost.
      expect(feeNoteOf(Fee.fromJson(c['fee'])), c['note'], reason: name);
    }
  });

  test('the longest sentence is the generated bound', () {
    expect(feeNoteMaxLength, limit['max_length']);
    expect(feeNoteMaxLength, greaterThan(freeFeeNoteMaxLength));
    final longest = limit['longest_fee'];
    expect(validFee(longest), isTrue);
    expect(feeNoteOfJson(longest).length, feeNoteMaxLength);
  });

  test('a fee round-trips through its JSON', () {
    for (final c in (cases['fees']! as List).cast<Map<String, Object?>>()) {
      if (c['valid'] != true) continue;
      final fee = Fee.tryParse(c['fee'])!;
      expect(Fee.tryParse(fee.toJson()), fee, reason: c['name'] as String);
    }
  });

  test('posted reads as unconfirmed but is accepted', () {
    final fee = Fee.tryParse({
      'scooter': {'mode': 'posted'},
      'heavy': {'mode': 'hourly', 'amount': 20, 'per_minutes': 60},
    })!;
    expect(fee.scooter, isNull);
    expect(feeNoteOf(fee), '大型重機每小時 20 元');
  });

  test('a heavy follow reads with its amounts worked out (#140)', () {
    final fee = Fee.fromJson({
      'scooter': {'mode': 'hourly', 'amount': 10, 'per_minutes': 60},
      'heavy': {'mode': 'same_as_scooter', 'factor_pct': 200},
    });
    expect(fee.textOf('heavy'), '每小時 20 元');
    expect(fee.heavy!.text, '比照機車費率');
    expect(
      Fee.fromJson({
        'heavy': {'mode': 'same_as_car'},
      }).textOf('heavy'),
      isNull,
    );
  });

  test('copyWith keeps the car rate the editor does not show', () {
    final fee = Fee.fromJson({
      'car': {'mode': 'hourly', 'amount': 40, 'per_minutes': 60},
    });
    final edited = fee.copyWith(scooter: () => const Rate(FeeMode.free));
    expect(edited.car, fee.car);
    expect(edited.scooter, const Rate(FeeMode.free));
    expect(edited.copyWith(scooter: () => null).scooter, isNull);
  });
}

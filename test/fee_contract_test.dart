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

  test('the largest fee the contract allows fits the size bound', () {
    expect(validFee(limit['largest_fee']), isTrue);
  });

  test('a fee round-trips through its JSON', () {
    for (final c in (cases['fees']! as List).cast<Map<String, Object?>>()) {
      if (c['valid'] != true) continue;
      final fee = Fee.tryParse(c['fee'])!;
      expect(Fee.tryParse(fee.toJson()), fee, reason: c['name'] as String);
    }
  });

  test('an old posted or daily rate reads as unconfirmed (#188 layer 2)', () {
    final fee = Fee.fromJson({
      'scooter': {'mode': 'posted'},
      'car': {'mode': 'daily', 'amount': 30},
      'heavy': {'mode': 'hourly', 'amount': 20, 'per_minutes': 60},
    });
    expect(fee.scooter, isNull);
    expect(fee.car, isNull);
    expect(feeNoteOf(fee), '大型重機每小時 20 元');
  });

  test('a heavy follow reads with the amounts it follows (#140)', () {
    final fee = Fee.fromJson({
      'scooter': {'mode': 'hourly', 'amount': 10, 'per_minutes': 60},
      'heavy': {'mode': 'same_as_scooter'},
    });
    expect(fee.textOf('heavy'), '每小時 10 元');
    expect(fee.heavy!.text, '比照機車費率');
    expect(
      Fee.fromJson({
        'heavy': {'mode': 'same_as_car'},
      }).textOf('heavy'),
      isNull,
    );
  });

  test('new writes: feeWriteComplete as the shared cases expect', () {
    final all = (cases['fee_writes']! as List).cast<Map<String, Object?>>();
    expect(all, isNotEmpty);
    for (final c in all) {
      final name = c['name'] as String;
      expect(validFee(c['fee']), isTrue, reason: name);
      expect(feeWriteComplete(c['fee']), c['complete'], reason: name);
      expect(Fee.fromJson(c['fee']).writeComplete, c['complete'], reason: name);
    }
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

  test('a suggestion clears only what the rider cleared (design §5.4)', () {
    final current = Fee.fromJson({
      'scooter': {'mode': 'free'},
      'heavy': {'mode': 'hourly', 'amount': 20, 'per_minutes': 60},
    });
    final edited = current.copyWith(heavy: () => null);
    expect(feeSuggestion(current, edited), {
      'scooter': {'mode': 'free'},
      'heavy': null,
    });
    // A vehicle the spot never had is left out, not cleared.
    expect(feeSuggestion(null, edited), {
      'scooter': {'mode': 'free'},
    });
    expect(mergeFeeJson(current.toJson(), feeSuggestion(current, edited)), {
      'scooter': {'mode': 'free'},
    });
  });
}

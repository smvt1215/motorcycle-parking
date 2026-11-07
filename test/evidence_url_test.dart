import 'package:flutter_test/flutter_test.dart';
import 'package:motorcycle_parking/features/report/report_sheet.dart';
import 'package:motorcycle_parking/models/parking_condition.dart';
import 'package:motorcycle_parking/ui/fee_board.dart';
import 'package:motorcycle_parking/models/fee.dart';
import 'package:motorcycle_parking/ui/vehicle_marks.dart';

void main() {
  const notUrl = '這看起來不是網址，請貼上公告頁的網址';

  group('normalizeEvidenceUrl', () {
    for (final (input, url) in const [
      ('  ', ''),
      ('a.gov.tw/x', 'https://a.gov.tw/x'),
      ('www.example.gov.tw/notice', 'https://www.example.gov.tw/notice'),
      (' https://a.gov.tw/x ', 'https://a.gov.tw/x'),
      ('HTTPS://a.gov.tw/X', 'https://a.gov.tw/X'),
      ('Https://a.gov.tw', 'https://a.gov.tw'),
      ('a.gov.tw/x。', 'https://a.gov.tw/x'),
      ('a.gov.tw/x，', 'https://a.gov.tw/x'),
      ('a.gov.tw/x、', 'https://a.gov.tw/x'),
      ('a.gov.tw/x）', 'https://a.gov.tw/x'),
      ('a.gov.tw/x）。 ', 'https://a.gov.tw/x'),
      ('example.gov.tw:8080/x', 'https://example.gov.tw:8080/x'),
      ('example.gov.tw:8080', 'https://example.gov.tw:8080'),
      ('https://example.gov.tw:8080/x', 'https://example.gov.tw:8080/x'),
      ('medium.com/@user', 'https://medium.com/@user'),
    ]) {
      test('收 "$input"', () {
        final r = normalizeEvidenceUrl(input);
        expect(r.url, url);
        expect(r.issue, isNull);
        expect(evidenceUrlHint(input), isNull);
      });
    }

    for (final input in const [
      'user@example.com',
      'https://user@example.com',
      '松壽路公告',
      'https://松壽路公告',
      'a gov.tw/x',
      'https://a.gov.tw/a b',
      'javascript:alert(1)',
      'data:text/html,x',
      'mailto:a@b.tw',
      'tel:0912345678',
      'ftp://a.gov.tw/x',
      'a.b:evil',
      'localhost',
      'https://',
      'https://.tw',
      'example.',
    ]) {
      test('擋 "$input"', () {
        expect(normalizeEvidenceUrl(input).issue, EvidenceUrlIssue.notUrl);
        expect(evidenceUrlHint(input), notUrl);
      });
    }

    test('http 開頭請改 https', () {
      for (final input in const ['http://a.gov.tw', 'HTTP://a.gov.tw/x']) {
        expect(normalizeEvidenceUrl(input).issue, EvidenceUrlIssue.http);
        expect(evidenceUrlHint(input), '請改用 https:// 開頭的網址');
      }
    });

    test('長度以補完後為準，邊界 2048', () {
      const head = 'a.gov.tw/';
      final fits = head + 'x' * (sourceUrlMaxLength - head.length - 8);
      expect(normalizeEvidenceUrl(fits).url!.length, sourceUrlMaxLength);
      final over = '${fits}x';
      expect(normalizeEvidenceUrl(over).issue, EvidenceUrlIssue.tooLong);
      expect(evidenceUrlHint(over), '網址太長，請貼上公告頁的網址');
    });

    test('通過的都符合 contract 的 pattern', () {
      expect(
        RegExp(sourceUrlPattern).hasMatch(evidenceUrlOf('a.gov.tw/x')),
        isTrue,
      );
    });
  });

  group('公告牌的不適用', () {
    const na = Rate(FeeMode.notApplicable);

    test('不適用不算未確認，沒有未確認的結尾', () {
      final boards = feeBoardOf(
        const Fee(
          scooter: Rate(FeeMode.free),
          heavy: Rate(FeeMode.free),
          car: na,
        ),
        vehicles: FeeVehicle.values,
      );
      expect(boards.last.headline!.text, '不適用');
      expect(boards.last.headline!.tone, isNot(FeeTone.unconfirmed));
      expect(feeBoardHasUnconfirmed(boards), isFalse);
    });

    test('比照不適用的車種時寫不適用，不寫費率未提供', () {
      for (final fee in const [
        Fee(
          scooter: na,
          heavy: Rate(FeeMode.sameAsScooter),
          car: Rate(FeeMode.free),
        ),
        Fee(
          scooter: Rate(FeeMode.free),
          heavy: Rate(FeeMode.sameAsCar),
          car: na,
        ),
      ]) {
        final board = feeBoardOf(
          fee,
          vehicles: const [FeeVehicle.heavy],
        ).single;
        expect(board.headline!.text, '不適用');
        expect(feeBoardHasUnconfirmed([board]), isFalse);
      }
    });

    test('三種車都不適用時列出不適用，不寫未確認', () {
      final boards = feeBoardOf(const Fee(scooter: na, heavy: na, car: na));
      expect(boards.map((b) => b.headline!.text).toSet(), {'不適用'});
      expect(feeBoardHasUnconfirmed(boards), isFalse);
    });
  });
}

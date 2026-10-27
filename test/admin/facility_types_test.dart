import 'package:flutter_test/flutter_test.dart';
import 'package:motorcycle_parking/admin/spots/spot_models.dart';

void main() {
  test('沒有 facility_types 的舊資料，表單以單一型式顯示（決定 58）', () {
    expect(spotRowValues({'facility_type': 'underground'})['facility_types'], [
      'underground',
    ]);
    expect(
      spotRowValues({
        'facility_type': 'underground',
        'facility_types': ['underground', 'surface'],
      })['facility_types'],
      ['underground', 'surface'],
    );
    expect(spotRowValues({'facility_type': null})['facility_types'], isNull);
    final field = spotField('facility_types');
    expect(validateSpotField(field, ['surface', 'underground']), isNull);
    expect(validateSpotField(field, null), isNull);
    expect(validateSpotField(field, ['surface', 'surface']), isNotNull);
    expect(validateSpotField(field, ['rooftop']), isNotNull);
  });
}

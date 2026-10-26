import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'package:motorcycle_parking/domain/capsule_layout.dart';

CapsuleItem at(
  String id,
  double x,
  double y, {
  double full = 110,
  double primary = 50,
}) => CapsuleItem(
  id: id,
  center: Offset(x, y),
  fullWidth: full,
  primaryWidth: primary,
);

void main() {
  test('膠囊在標記正上方置中，下緣距標記上緣 10', () {
    final rect = capsuleRect(at('a', 100, 200), 60)!;
    expect(rect, const Rect.fromLTWH(70, 200 - 19 - 10 - 24, 60, 24));
    expect(capsuleRect(at('a', 100, 200), 0), isNull);
  });

  test('疏落的標記顯示完整一組', () {
    final layout = layoutCapsules([at('a', 50, 300), at('b', 300, 300)]);
    expect(layout, {'a': CapsuleShow.full, 'b': CapsuleShow.full});
  });

  test('密集時每點只留主要膠囊（MapDensity 未選取）', () {
    // A row 70 apart: full sets (110 wide) touch, own counts (50) do not.
    final row = [for (var i = 0; i < 5; i++) at('r$i', 49.0 + 70 * i, 249)];
    final layout = layoutCapsules(row);
    expect(layout.values.toSet(), {CapsuleShow.primary});
  });

  test('選取的點顯示完整一組，碰到它的鄰近膠囊隱藏，較遠的照常', () {
    final row = [for (var i = 0; i < 5; i++) at('r$i', 49.0 + 70 * i, 249)];
    final far = at('far', 192, 600);
    final layout = layoutCapsules([...row, far], selected: 'r1');
    expect(layout['r1'], CapsuleShow.full);
    // r1's 110-wide set spans 64–174: r0 (24–74) and r2 (164–214) touch it.
    expect(layout['r0'], CapsuleShow.none);
    expect(layout['r2'], CapsuleShow.none);
    expect(layout['r3'], CapsuleShow.primary);
    expect(layout['r4'], CapsuleShow.primary);
    expect(layout['far'], CapsuleShow.full);
  });

  test('鄰點的膠囊壓到選取標記本身也隱藏', () {
    // b sits right below the selected a: its pills cover a's marker.
    final layout = layoutCapsules([
      at('a', 100, 200, full: 50),
      at('b', 100, 245, full: 50),
    ], selected: 'a');
    expect(layout['a'], CapsuleShow.full);
    expect(layout['b'], CapsuleShow.none);
  });

  test('沒有膠囊的點不影響判斷，取消選取後恢復', () {
    final items = [at('a', 100, 200, full: 0, primary: 0), at('b', 300, 200)];
    expect(layoutCapsules(items, selected: 'a')['b'], CapsuleShow.full);
    final row = [for (var i = 0; i < 3; i++) at('r$i', 49.0 + 70 * i, 249)];
    expect(layoutCapsules(row, selected: 'r1')['r0'], CapsuleShow.none);
    expect(layoutCapsules(row)['r0'], CapsuleShow.primary);
  });
}

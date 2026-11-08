import 'package:flutter_test/flutter_test.dart';
import 'package:poker_klub/format.dart';

void main() {
  test('formatira žetone sa tačkom za hiljade', () {
    expect(chips(0), '0');
    expect(chips(999), '999');
    expect(chips(1000), '1.000');
    expect(chips(1234567), '1.234.567');
    expect(chips(-2500), '-2.500');
  });

  test('nazivi igara', () {
    expect(variantName('HOLDEM'), "Hold'em");
    expect(variantName('OMAHA'), 'Omaha');
  });

  test('prikaz u BB', () {
    const m = Money(20, true);
    expect(m(400), '20 BB');
    expect(m(50), '2,5 BB');
    expect(m(25000), '1.250 BB');
    expect(const Money(20, false)(400), '400 RSD');
    expect(rsd(5342), '5.342 RSD');
  });
}

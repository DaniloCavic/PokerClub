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
}

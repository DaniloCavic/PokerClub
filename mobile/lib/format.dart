/// 12500 → "12.500"
String chips(num? n) {
  final v = (n ?? 0).round();
  final s = v.abs().toString();
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write('.');
    buf.write(s[i]);
  }
  return v < 0 ? '-$buf' : buf.toString();
}

String variantName(String v) => v == 'OMAHA' ? 'Omaha' : "Hold'em";
String variantLong(String v) => v == 'OMAHA' ? 'Omaha · pot-limit' : "Texas Hold'em · no-limit";

String two(int n) => n.toString().padLeft(2, '0');

String dateTime(String iso) {
  final d = DateTime.parse(iso).toLocal();
  return '${two(d.day)}.${two(d.month)}.${d.year}. ${two(d.hour)}:${two(d.minute)}';
}

const txLabels = {
  'DEPOSIT': 'Uplata',
  'WITHDRAWAL': 'Isplata',
  'BUY_IN': 'Ulaz za sto',
  'CASH_OUT': 'Povratak sa stola',
};

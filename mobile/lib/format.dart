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

/// Iznos u dinarima: 12500 → "12.500 RSD"
String rsd(num? n) => '${chips(n)} RSD';

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

/// Iznos u žetonima ili u velikim blajndovima (BB), po izboru igrača.
class Money {
  final int bb;
  final bool inBB;
  const Money(this.bb, this.inBB);

  String call(num? v) {
    final n = (v ?? 0);
    if (!inBB || bb <= 0) return rsd(n);
    return '${bbNumber(n / bb)} BB';
  }
}

/// 12.5 → "12,5", 40.0 → "40" (najviše jedna decimala).
String bbNumber(double x) {
  final r = (x * 10).round() / 10;
  if (r == r.roundToDouble()) return chips(r.round());
  final whole = r.truncate();
  final dec = ((r - whole).abs() * 10).round();
  return '${chips(whole)},$dec';
}

const _days = ['ponedeljak', 'utorak', 'sreda', 'četvrtak', 'petak', 'subota', 'nedelja'];

/// "četvrtak 12.11. u 18:00" (danas/sutra se pišu rečima).
String opensLabel(DateTime d) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(d.year, d.month, d.day);
  final diff = day.difference(today).inDays;
  final time = '${two(d.hour)}:${two(d.minute)}';
  if (diff == 0) return 'danas u $time';
  if (diff == 1) return 'sutra u $time';
  return '${_days[d.weekday - 1]} ${d.day}.${d.month}. u $time';
}

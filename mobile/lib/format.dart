import 'i18n.dart';

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

/// Iznos na nalogu (van stola): 12500 → "12.500 RSD". Za stolom se piše samo broj (vidi Money).
String rsd(num? n) => '${chips(n)} RSD';

String variantName(String v) => v == 'OMAHA' ? 'Omaha' : "Hold'em";
String variantLong(String v) => v == 'OMAHA' ? 'Omaha · pot-limit' : "Texas Hold'em · no-limit";

String two(int n) => n.toString().padLeft(2, '0');

String dateTime(String iso) {
  final d = DateTime.parse(iso).toLocal();
  return '${two(d.day)}.${two(d.month)}.${d.year}. ${two(d.hour)}:${two(d.minute)}';
}

/// Nazivi vrsta transakcija.
Map<String, String> get txLabels => {
      'DEPOSIT': tr('Deposit', 'Uplata'),
      'WITHDRAWAL': tr('Withdrawal', 'Isplata'),
      'BUY_IN': tr('Table buy-in', 'Ulaz za sto'),
      'CASH_OUT': tr('Cash-out', 'Povratak sa stola'),
      'TOURNAMENT_BUY_IN': tr('Tournament buy-in', 'Ulaz na turnir'),
      'TOURNAMENT_PRIZE': tr('Tournament prize', 'Nagrada sa turnira'),
      'TOURNAMENT_REFUND': tr('Tournament refund', 'Povraćaj (turnir)'),
      'TOURNAMENT_BOUNTY': tr('Bounty', 'Bounty'),
    };

/// Iznos u žetonima ili u velikim blajndovima (BB), po izboru igrača.
class Money {
  final int bb;
  final bool inBB;
  const Money(this.bb, this.inBB);

  String call(num? v) {
    final n = (v ?? 0);
    // Za stolom: samo broj (bez RSD), ili u BB.
    if (!inBB || bb <= 0) return chips(n);
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

List<String> get _days => Lang.sr
    ? ['ponedeljak', 'utorak', 'sreda', 'četvrtak', 'petak', 'subota', 'nedelja']
    : ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];

/// "Thursday 12.11. at 18:00" (danas/sutra: "today/tomorrow at 18:00").
String opensLabel(DateTime d) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(d.year, d.month, d.day);
  final diff = day.difference(today).inDays;
  final time = '${two(d.hour)}:${two(d.minute)}';
  if (diff == 0) return tr('today at $time', 'danas u $time');
  if (diff == 1) return tr('tomorrow at $time', 'sutra u $time');
  return '${_days[d.weekday - 1]} ${d.day}.${d.month}. ${tr('at', 'u')} $time';
}

/// Koliko je ostalo do otvaranja: "in 2 d 4 h", "in 3 h 15 min", "in 5 min", "in less than a minute".
String countdown(DateTime d) {
  final left = d.difference(DateTime.now());
  final za = tr('in', 'za');
  if (left.inMinutes < 1) return tr('in less than a minute', 'za manje od minuta');
  if (left.inDays >= 1) return '$za ${left.inDays} d ${left.inHours % 24} h';
  if (left.inHours >= 1) return '$za ${left.inHours} h ${left.inMinutes % 60} min';
  return '$za ${left.inMinutes} min';
}

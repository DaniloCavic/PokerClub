import 'package:flutter/material.dart';

const _suits = {'s': '♠', 'h': '♥', 'd': '♦', 'c': '♣'};

/// Izgled karata: klasične bele (crveno/crno) ili u boji, gde je cela karta obojena
/// po znaku (pik crna, herc crvena, karo plava, tref zelena), kao na ClubGG. Bira se u profilu.
class CardStyle {
  static bool fourColor = false;
}

// Karte u boji: pozadina cele karte po znaku (svetlija gore, tamnija dole).
const _fullColors = {
  's': [Color(0xFF4A4A4F), Color(0xFF1E1E22)],
  'h': [Color(0xFFE0303F), Color(0xFFA30F1F)],
  'd': [Color(0xFF2F7FE0), Color(0xFF14509E)],
  'c': [Color(0xFF2FA352), Color(0xFF16692F)],
};
const _twoColors = {'s': Color(0xFF151515), 'h': Color(0xFFC8102E), 'd': Color(0xFFC8102E), 'c': Color(0xFF151515)};

/// Karta "As" / "Td" / "7h"; null = poleđina.
class PlayingCard extends StatelessWidget {
  final String? code;
  final double width;
  final bool highlight;
  final bool dim;

  /// Stil za ovu kartu (pregled u izboru); null = podešavanje igrača.
  final bool? colored;

  const PlayingCard({super.key, this.code, this.width = 40, this.highlight = false, this.dim = false, this.colored});

  @override
  Widget build(BuildContext context) {
    final h = width * 1.4;
    final radius = BorderRadius.circular(width * 0.1);
    if (code == null) {
      // Poleđina: bordo sa zlatnim okvirom i pikom
      return Container(
        width: width,
        height: h,
        decoration: BoxDecoration(
          borderRadius: radius,
          border: Border.all(color: Colors.white, width: width * 0.05),
          gradient: const LinearGradient(
              colors: [Color(0xFFB3122A), Color(0xFF5E0A16)], begin: Alignment.topLeft, end: Alignment.bottomRight),
          boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 3, offset: Offset(0, 1))],
        ),
        child: Container(
          margin: EdgeInsets.all(width * 0.07),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(width * 0.06),
            border: Border.all(color: const Color(0xFFD4AF37).withOpacity(0.7), width: width * 0.03),
          ),
          alignment: Alignment.center,
          child: Text('♠', style: TextStyle(color: const Color(0xFFD4AF37).withOpacity(0.8), fontSize: width * 0.38, height: 1)),
        ),
      );
    }
    final rank = code![0] == 'T' ? '10' : code![0];
    final suit = code![1];
    final full = colored ?? CardStyle.fourColor;
    final color = full ? Colors.white : _twoColors[suit]!;
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 200),
      opacity: dim ? 0.4 : 1,
      child: Container(
        width: width,
        height: h,
        decoration: BoxDecoration(
          gradient: LinearGradient(
              colors: full ? _fullColors[suit]! : const [Colors.white, Color(0xFFEDEAE3)],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter),
          borderRadius: radius,
          border: Border.all(
              color: highlight ? const Color(0xFFD4AF37) : (full ? Colors.white70 : Colors.black26),
              width: highlight ? width * 0.07 : (full ? 1.0 : 0.8)),
          boxShadow: [
            const BoxShadow(color: Colors.black54, blurRadius: 3, offset: Offset(0, 1)),
            if (highlight) const BoxShadow(color: Color(0xAAF6E27A), blurRadius: 10),
          ],
        ),
        child: Stack(children: [
          // Rang i boja u gornjem levom uglu
          Positioned(
            left: width * 0.07,
            top: width * 0.03,
            child: Column(crossAxisAlignment: CrossAxisAlignment.center, children: [
              Text(rank,
                  style: TextStyle(
                      color: color,
                      fontWeight: FontWeight.w800,
                      fontSize: width * (rank.length > 1 ? 0.36 : 0.42),
                      height: 1,
                      letterSpacing: -1)),
              Text(_suits[suit]!, style: TextStyle(color: color, fontSize: width * 0.3, height: 1)),
            ]),
          ),
          // Velika boja dole desno
          Positioned(
            right: width * 0.06,
            bottom: width * 0.02,
            child: Text(_suits[suit]!, style: TextStyle(color: color, fontSize: width * 0.62, height: 1)),
          ),
        ]),
      ),
    );
  }
}

import 'package:flutter/material.dart';

const _suits = {'s': '♠', 'h': '♥', 'd': '♦', 'c': '♣'};
// Karte u četiri boje: pik tamno siva, herc crvena, karo plava, tref zelena.
const _suitColors = {
  's': [Color(0xFF3A3D45), Color(0xFF1E2026)],
  'h': [Color(0xFFE53945), Color(0xFFB0202C)],
  'd': [Color(0xFF2F7BEA), Color(0xFF1B54B0)],
  'c': [Color(0xFF2EAE5B), Color(0xFF1D7E3F)],
};

/// Karta "As" / "Td" / "7h"; null = poleđina.
class PlayingCard extends StatelessWidget {
  final String? code;
  final double width;
  final bool highlight;
  final bool dim;

  const PlayingCard({super.key, this.code, this.width = 40, this.highlight = false, this.dim = false});

  @override
  Widget build(BuildContext context) {
    final h = width * 1.4;
    final radius = BorderRadius.circular(width * 0.12);
    if (code == null) {
      return Container(
        width: width,
        height: h,
        decoration: BoxDecoration(
          borderRadius: radius,
          border: Border.all(color: Colors.white70, width: width * 0.04),
          gradient: const LinearGradient(
            colors: [Color(0xFFB0121F), Color(0xFF6E0A14)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 3, offset: Offset(0, 1))],
        ),
        child: Center(
          child: Container(
            width: width * 0.55,
            height: width * 0.55,
            decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Colors.white30, width: width * 0.04)),
            alignment: Alignment.center,
            child: Text('♠', style: TextStyle(color: Colors.white38, fontSize: width * 0.3, height: 1)),
          ),
        ),
      );
    }
    final rank = code![0] == 'T' ? '10' : code![0];
    final suit = code![1];
    final colors = _suitColors[suit]!;
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 200),
      opacity: dim ? 0.4 : 1,
      child: Container(
        width: width,
        height: h,
        decoration: BoxDecoration(
          borderRadius: radius,
          gradient: LinearGradient(colors: colors, begin: Alignment.topCenter, end: Alignment.bottomCenter),
          border: Border.all(color: highlight ? const Color(0xFFF2C14E) : Colors.white24, width: highlight ? width * 0.07 : 1),
          boxShadow: [
            const BoxShadow(color: Colors.black54, blurRadius: 3, offset: Offset(0, 1)),
            if (highlight) const BoxShadow(color: Color(0x99F2C14E), blurRadius: 10),
          ],
        ),
        child: Stack(
          children: [
            Positioned(
              left: width * 0.08,
              top: width * 0.04,
              child: Text(_suits[suit]!, style: TextStyle(color: Colors.white, fontSize: width * 0.3, height: 1.1)),
            ),
            Positioned.fill(
              top: width * 0.25,
              child: Center(
                child: Text(
                  rank,
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: width * (rank.length > 1 ? 0.62 : 0.78),
                    height: 1,
                    letterSpacing: -2,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

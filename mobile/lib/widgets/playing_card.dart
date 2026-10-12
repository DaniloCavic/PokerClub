import 'package:flutter/material.dart';

const _suits = {'s': '♠', 'h': '♥', 'd': '♦', 'c': '♣'};
// Četiri boje radi lakšeg čitanja na malom ekranu: pik crn, herc crven, karo plav, tref zelen.
const _suitColors = {
  's': Color(0xFF1B1B1B),
  'h': Color(0xFFD32F2F),
  'd': Color(0xFF1565C0),
  'c': Color(0xFF2E7D32),
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
          border: Border.all(color: Colors.white, width: width * 0.05),
          gradient: const LinearGradient(colors: [Color(0xFF8E1B1B), Color(0xFFB71C1C)], begin: Alignment.topLeft, end: Alignment.bottomRight),
          boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 2, offset: Offset(0, 1))],
        ),
        child: Center(child: Text('♠', style: TextStyle(color: Colors.white24, fontSize: width * 0.5))),
      );
    }
    final rank = code![0] == 'T' ? '10' : code![0];
    final suit = code![1];
    final color = _suitColors[suit]!;
    return Opacity(
      opacity: dim ? 0.45 : 1,
      child: Container(
        width: width,
        height: h,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: radius,
          border: highlight ? Border.all(color: const Color(0xFFD4A62A), width: width * 0.07) : null,
          boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 2, offset: Offset(0, 1))],
        ),
        padding: EdgeInsets.all(width * 0.06),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(rank,
                style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: width * 0.42, height: 1, letterSpacing: -1)),
            Align(
              alignment: Alignment.bottomRight,
              child: Text(_suits[suit]!, style: TextStyle(color: color, fontSize: width * 0.5, height: 1)),
            ),
          ],
        ),
      ),
    );
  }
}

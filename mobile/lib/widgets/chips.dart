import 'dart:math';
import 'package:flutter/material.dart';

/// Boje kazino žetona po vrednosti (u velikim blajndovima), kao u pravim klubovima.
class _Denom {
  final double bb;
  final Color color;
  final Color edge;
  const _Denom(this.bb, this.color, this.edge);
}

const _denoms = [
  _Denom(100, Color(0xFF5B2A86), Colors.white), // ljubičasti
  _Denom(25, Color(0xFF1C1C1C), Color(0xFFE8E2D0)), // crni
  _Denom(5, Color(0xFF1E7B3A), Colors.white), // zeleni
  _Denom(1, Color(0xFFC0182E), Colors.white), // crveni
  _Denom(0.5, Color(0xFF1F5FB8), Colors.white), // plavi
  _Denom(0.2, Color(0xFFEDE6D6), Color(0xFFC0182E)), // beli (ante)
];

/// Iznos razložen na gomile žetona (do 3 gomile, najviše 7 žetona u gomili).
List<List<_Denom>> _stacks(int amount, int bigBlind) {
  if (amount <= 0) return [];
  final bb = bigBlind <= 0 ? 1 : bigBlind;
  var left = amount / bb;
  final counts = <_Denom, int>{};
  for (final d in _denoms) {
    final n = (left / d.bb + 1e-9).floor();
    if (n > 0) {
      counts[d] = n;
      left -= n * d.bb;
    }
  }
  if (counts.isEmpty) counts[_denoms.last] = 1;
  // Mali ulog izgleda bolje kao gomilica: razbij krupne žetone na sitnije dok ih nema bar 4.
  int total() => counts.values.fold(0, (a, b) => a + b);
  for (var guard = 0; guard < 10 && total() < 4; guard++) {
    final big = _denoms.indexWhere((d) => (counts[d] ?? 0) > 0 && d != _denoms.last);
    if (big < 0) break;
    final d = _denoms[big], next = _denoms[big + 1];
    final pieces = (d.bb / next.bb).round();
    counts[d] = counts[d]! - 1;
    if (counts[d] == 0) counts.remove(d);
    counts[next] = (counts[next] ?? 0) + pieces;
  }
  final ordered = _denoms.where(counts.containsKey).toList();
  final out = <List<_Denom>>[];
  for (final d in ordered) {
    out.add(List.filled(min(counts[d]!, 8), d));
    if (out.length == 3) break;
  }
  return out;
}

/// Gomile pravih kazino žetona (pogled iskosa).
class ChipStacks extends StatelessWidget {
  final int amount;
  final int bigBlind;
  final double chipSize;
  const ChipStacks({super.key, required this.amount, required this.bigBlind, this.chipSize = 18});

  @override
  Widget build(BuildContext context) {
    final stacks = _stacks(amount, bigBlind);
    final d = chipSize;
    final t = d * 0.2; // debljina žetona
    final maxH = stacks.fold<int>(0, (m, s) => max(m, s.length));
    final w = stacks.isEmpty ? d : d + (stacks.length - 1) * d * 0.78;
    final h = d * 0.62 + maxH * t + 3;
    return SizedBox(
      width: w,
      height: h,
      child: CustomPaint(painter: _StacksPainter(stacks, d, t)),
    );
  }
}

class _StacksPainter extends CustomPainter {
  final List<List<_Denom>> stacks;
  final double d;
  final double t;
  _StacksPainter(this.stacks, this.d, this.t);

  @override
  void paint(Canvas canvas, Size size) {
    final ry = d * 0.3; // poluprečnik elipse po visini (perspektiva)
    for (var s = 0; s < stacks.length; s++) {
      // Srednja gomila malo napred, za dubinu
      final cx = d / 2 + s * d * 0.78;
      final baseY = size.height - ry - 1 - (s == 1 ? 0 : 1.5);
      // Senka ispod gomile
      canvas.drawOval(
        Rect.fromCenter(center: Offset(cx + 1, baseY + 2), width: d * 1.05, height: ry * 2.1),
        Paint()
          ..color = Colors.black.withOpacity(0.45)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2),
      );
      final stack = stacks[s];
      for (var i = 0; i < stack.length; i++) {
        _chip(canvas, Offset(cx, baseY - i * t), stack[i], top: i == stack.length - 1, ry: ry);
      }
    }
  }

  void _chip(Canvas canvas, Offset c, _Denom den, {required bool top, required double ry}) {
    final r = d / 2;
    final base = den.color;
    final dark = Color.lerp(base, Colors.black, 0.45)!;
    // Bočna strana žetona (traka između donje i gornje elipse)
    final side = Path()
      ..moveTo(c.dx - r, c.dy - t)
      ..lineTo(c.dx - r, c.dy)
      ..arcTo(Rect.fromCenter(center: c, width: d, height: ry * 2), pi, -pi, false)
      ..lineTo(c.dx + r, c.dy - t)
      ..arcTo(Rect.fromCenter(center: Offset(c.dx, c.dy - t), width: d, height: ry * 2), 0, pi, false)
      ..close();
    canvas.drawPath(
      side,
      Paint()
        ..shader = LinearGradient(colors: [dark, base, dark], stops: const [0, 0.45, 1])
            .createShader(Rect.fromLTWH(c.dx - r, c.dy - t, d, t + ry)),
    );
    // Bele šare na boku (vidljive spreda)
    final stripe = Paint()..color = den.edge.withOpacity(0.95);
    for (final a in [0.18, 0.5, 0.82]) {
      final x = c.dx - r + d * a;
      final dx = d * 0.07;
      final yOff = ry * sqrt(max(0, 1 - pow((x - c.dx) / r, 2)));
      canvas.drawRect(Rect.fromLTWH(x - dx / 2, c.dy - t + yOff * 0.98, dx, t * 0.95), stripe);
    }
    // Gornja površina
    final face = Rect.fromCenter(center: Offset(c.dx, c.dy - t), width: d, height: ry * 2);
    canvas.drawOval(face, Paint()..color = base);
    if (!top) {
      canvas.drawOval(face, Paint()
        ..color = Colors.black.withOpacity(0.25)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.6);
      return;
    }
    // Šare po obodu (kao na pravim žetonima)
    final edgePaint = Paint()
      ..color = den.edge
      ..style = PaintingStyle.stroke
      ..strokeWidth = ry * 0.36;
    final rim = face.deflate(ry * 0.18);
    for (var k = 0; k < 6; k++) {
      canvas.drawArc(rim, k * pi / 3 + 0.25, pi / 3 * 0.5, false, edgePaint);
    }
    // Unutrašnji prsten i sredina
    final inner = Rect.fromCenter(center: face.center, width: face.width * 0.58, height: face.height * 0.58);
    canvas.drawOval(inner, Paint()..color = Color.lerp(base, Colors.white, 0.18)!);
    canvas.drawOval(
      inner,
      Paint()
        ..color = den.edge.withOpacity(0.8)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8,
    );
    // Odsjaj
    canvas.drawOval(
      face,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.4, -0.6),
          radius: 0.9,
          colors: [Colors.white.withOpacity(0.35), Colors.transparent],
        ).createShader(face),
    );
    canvas.drawOval(face, Paint()
      ..color = Colors.black.withOpacity(0.35)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.7);
  }

  @override
  bool shouldRepaint(covariant _StacksPainter old) => old.stacks.length != stacks.length || old.d != d || true;
}

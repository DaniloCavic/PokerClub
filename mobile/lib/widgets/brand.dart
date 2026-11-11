import 'package:flutter/material.dart';
import '../theme.dart';

/// Tekst prelivan zlatom.
class GoldText extends StatelessWidget {
  final String text;
  final TextStyle style;
  final TextAlign? align;
  const GoldText(this.text, {super.key, required this.style, this.align});

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      blendMode: BlendMode.srcIn,
      shaderCallback: (r) => goldGradient.createShader(Rect.fromLTWH(0, 0, r.width, r.height)),
      child: Text(text, style: style, textAlign: align),
    );
  }
}

/// Logo kluba: zlatni pik i natpis POKER KLUB / TRILING.
class TrilingLogo extends StatelessWidget {
  final double size;
  final bool horizontal;
  final bool icon;
  const TrilingLogo({super.key, this.size = 34, this.horizontal = true, this.icon = true});

  @override
  Widget build(BuildContext context) {
    final words = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: horizontal ? CrossAxisAlignment.start : CrossAxisAlignment.center,
      children: [
        GoldText('POKER KLUB',
            style: TextStyle(
                fontFamily: 'Cinzel', fontWeight: FontWeight.w600, fontSize: size * 0.36, letterSpacing: size * 0.08, height: 1)),
        GoldText('TRILING',
            style: TextStyle(
                fontFamily: 'Cinzel', fontWeight: FontWeight.w800, fontSize: size, letterSpacing: size * 0.04, height: 1.05)),
      ],
    );
    // U trakama (vodoravno) samo naziv kluba, bez pika; na prijavi pik stoji iznad naziva.
    if (!icon || horizontal) return words;
    final spade = GoldText('♠', style: TextStyle(fontSize: size * 1.35, height: 1));
    return Column(mainAxisSize: MainAxisSize.min, children: [spade, words]);
  }
}

/// Tamni panel sa tankim zlatnim okvirom.
class LuxPanel extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  const LuxPanel({super.key, required this.child, this.padding = const EdgeInsets.all(12), this.radius = 16});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
            colors: [Color(0xFF1C1814), Color(0xFF100E0C)], begin: Alignment.topLeft, end: Alignment.bottomRight),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: gold.withOpacity(0.28)),
        boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 12)],
      ),
      child: child,
    );
  }
}

/// Dugme sa prelivom (zlatno ili crveno), kao u dizajnu.
class LuxButton extends StatelessWidget {
  final String title;
  final String? subtitle;
  final IconData? icon;
  final Gradient gradient;
  final Color textColor;
  final VoidCallback? onTap;
  final double height;
  const LuxButton({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.gradient = buttonGoldGradient,
    this.textColor = const Color(0xFF2A1A05),
    this.onTap,
    this.height = 54,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Ink(
            height: height,
            decoration: BoxDecoration(
              gradient: gradient,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.white.withOpacity(0.25)),
              boxShadow: const [BoxShadow(color: Colors.black87, blurRadius: 8, offset: Offset(0, 3))],
            ),
            child: Center(
              child: FittedBox(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    if (icon != null) ...[Icon(icon, color: textColor, size: 20), const SizedBox(width: 6)],
                    Column(mainAxisSize: MainAxisSize.min, children: [
                      Text(title, style: TextStyle(color: textColor, fontWeight: FontWeight.w800, fontSize: 16, height: 1.1)),
                      if (subtitle != null)
                        Text(subtitle!,
                            style: TextStyle(color: textColor, fontWeight: FontWeight.w700, fontSize: 12.5, height: 1.1)),
                    ]),
                  ]),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Pozadina ekrana: tamna sa toplim sjajem (kao osvetljen salon).
class LuxBackground extends StatelessWidget {
  final Widget child;
  const LuxBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(0, -0.6),
          radius: 1.3,
          colors: [Color(0xFF3A1A12), Color(0xFF160C09), Color(0xFF070605)],
          stops: [0, 0.55, 1],
        ),
      ),
      child: child,
    );
  }
}

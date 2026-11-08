import 'package:flutter/material.dart';
import '../config.dart';
import '../theme.dart';

/// Okrugla slika igrača; bez slike — početno slovo imena na obojenoj pozadini.
class Avatar extends StatelessWidget {
  final String name;
  final String? url;
  final double size;
  final Color? borderColor;
  final double borderWidth;
  final List<BoxShadow>? shadow;

  const Avatar({
    super.key,
    required this.name,
    this.url,
    this.size = 50,
    this.borderColor,
    this.borderWidth = 2,
    this.shadow,
  });

  @override
  Widget build(BuildContext context) {
    final color = avatarColor(name);
    final letter = Text(
      name.isEmpty ? '?' : name.characters.first.toUpperCase(),
      style: TextStyle(fontSize: size * 0.42, fontWeight: FontWeight.w800, color: Colors.white),
    );
    final src = absoluteUrl(url);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          colors: [color, Color.lerp(color, Colors.black, 0.5)!],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(color: borderColor ?? Colors.white24, width: borderWidth),
        boxShadow: shadow ?? const [BoxShadow(color: Colors.black54, blurRadius: 4)],
      ),
      clipBehavior: Clip.antiAlias,
      alignment: Alignment.center,
      child: src == null
          ? letter
          : Image.network(
              src,
              width: size,
              height: size,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => letter,
            ),
    );
  }
}

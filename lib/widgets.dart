import 'package:flutter/material.dart';

import 'theme.dart';
import 'xtream.dart';

String abbr(String n) {
  final s = n
      .split(RegExp(r'[\s&|:\-]+'))
      .where((w) => w.isNotEmpty)
      .map((w) => RegExp(r'^\d+$').hasMatch(w) ? w : w[0])
      .join()
      .toUpperCase();
  return s.length > 4 ? s.substring(0, 4) : s;
}

Color hueColor(int hue, double s, double l, [double a = 1]) =>
    HSLColor.fromAHSL(a, (hue % 360).toDouble(), s, l).toColor();

/// Channel logo, or colored initials when there is no logo.
class ChannelBadge extends StatelessWidget {
  final Channel ch;
  final double w, h, fontSize;
  const ChannelBadge({super.key, required this.ch, this.w = 54, this.h = 36, this.fontSize = 14});

  @override
  Widget build(BuildContext context) {
    final initials = Container(
      alignment: Alignment.center,
      color: hueColor(ch.hue, .5, .3),
      child: Text(abbr(ch.name), style: ts(fontSize, w: FontWeight.w800, c: Colors.white)),
    );
    final icon = ch.icon;
    return ClipRRect(
      borderRadius: BorderRadius.circular(h * 0.2),
      child: SizedBox(
        width: w,
        height: h,
        child: icon == null
            ? initials
            : Container(
                color: const Color(0xFF0A1220),
                padding: const EdgeInsets.all(2),
                child: Image.network(icon, fit: BoxFit.contain, errorBuilder: (ctx, err, st) => initials),
              ),
      ),
    );
  }
}

/// The moving channel-colored stripes shown while a channel loads or can't play.
class StripesPainter extends CustomPainter {
  final double t;
  final int hue;
  final String title, sub;
  StripesPainter(this.t, this.hue, this.title, this.sub);

  @override
  void paint(Canvas c, Size s) {
    final rect = Offset.zero & s;
    final g = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [hueColor(hue, .55, .24), hueColor(hue + 40, .65, .09)],
    );
    c.drawRect(rect, Paint()..shader = g.createShader(rect));
    final k = s.width / 960;
    final p = Paint()..color = hueColor(hue, .8, .7, .07);
    final span = s.width + 300 * k;
    for (var i = 0; i < 7; i++) {
      final x = ((t * span + i * 170 * k) % span) - 150 * k;
      final path = Path()
        ..moveTo(x, 0)
        ..lineTo(x + 90 * k, 0)
        ..lineTo(x - 60 * k, s.height)
        ..lineTo(x - 150 * k, s.height)
        ..close();
      c.drawPath(path, p);
    }
    void text(String str, double size, FontWeight w, Color col, double dy) {
      final tp = TextPainter(
        text: TextSpan(text: str, style: TextStyle(fontSize: size * k, fontWeight: w, color: col)),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.center,
        maxLines: 2,
        ellipsis: '…',
      )..layout(maxWidth: s.width * 0.9);
      tp.paint(c, Offset((s.width - tp.width) / 2, s.height / 2 + dy * k - tp.height / 2));
    }

    text(title, 64, FontWeight.w800, Colors.white, -24);
    if (sub.isNotEmpty) text(sub, 30, FontWeight.w500, const Color(0xFFCFD8E3), 44);
  }

  @override
  bool shouldRepaint(covariant StripesPainter o) => o.t != t || o.title != title || o.sub != sub || o.hue != hue;
}

/// A small key cap used in the hint bar.
class Kbd extends StatelessWidget {
  final String k, label;
  const Kbd(this.k, this.label, {super.key});
  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
          decoration: BoxDecoration(color: TP.kbd, borderRadius: BorderRadius.circular(4)),
          child: Text(k, style: ts(12, w: FontWeight.w700)),
        ),
        const SizedBox(width: 6),
        Text(label, style: ts(14, c: TP.dim)),
      ]);
}

/// A progress bar (orange on dark).
Widget progressBar(double width, double value) => Container(
      width: width,
      height: 6,
      decoration: BoxDecoration(color: const Color(0xFF3B5675), borderRadius: BorderRadius.circular(3)),
      alignment: Alignment.centerLeft,
      child: FractionallySizedBox(
        widthFactor: value < 0 ? 0.0 : (value > 1 ? 1.0 : value),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(3),
            gradient: const LinearGradient(colors: [TP.orange, TP.orangeLight]),
          ),
        ),
      ),
    );

/// A focusable-looking row (silver + lift when selected), used in menus and settings.
class LiftItem extends StatelessWidget {
  final bool focused;
  final String fx;
  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsets padding;
  const LiftItem({
    super.key,
    required this.focused,
    required this.fx,
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
  });

  @override
  Widget build(BuildContext context) {
    final lift = focused && fx != 'off';
    final r = BorderRadius.circular(focused ? 10 : 0);
    return GestureDetector(
      onTap: onTap,
      child: AnimatedScale(
        scale: lift ? 1.03 : 1,
        duration: const Duration(milliseconds: 150),
        child: Container(
          margin: EdgeInsets.symmetric(horizontal: focused ? 8 : 0),
          decoration: BoxDecoration(
            gradient: focused ? TP.silver : null,
            borderRadius: r,
            boxShadow: lift ? const [BoxShadow(color: Color(0x73000000), blurRadius: 26, offset: Offset(0, 12))] : null,
          ),
          child: ClipRRect(
            borderRadius: r,
            child: Stack(children: [
              if (lift)
                Positioned.fill(
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          stops: const [0, 0.55],
                          colors: [Colors.white.withAlpha(100), Colors.white.withAlpha(0)],
                        ),
                      ),
                    ),
                  ),
                ),
              Padding(
                padding: padding,
                child: DefaultTextStyle(
                  style: ts(18, w: focused ? FontWeight.w700 : FontWeight.w400, c: focused ? const Color(0xFF050B14) : TP.text),
                  child: child,
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';

/// Tame Player colors (taken from the logo: navy, silver, orange).
class TP {
  static const bgTop = Color(0xFF3A6EA3);
  static const bgMid = Color(0xFF24476F);
  static const bgBot = Color(0xFF1A3555);
  static const panel = Color(0xFF1D3758);
  static const chCell = Color(0xFF20395A);
  static const chCellCur = Color(0xFF2C4C74);
  static const cell = Color(0xFF24426A);
  static const cellNow = Color(0xFF2F5683);
  static const line = Color(0xFF18304E);
  static const hintBar = Color(0xFF1A3352);
  static const kbd = Color(0xFF35577F);
  static const orange = Color(0xFFE08A2C);
  static const orangeLight = Color(0xFFF3B064);
  static const red = Color(0xFFE04848);
  static const text = Color(0xFFE7EDF4);
  static const dim = Color(0xFFB3C3D4);
  static const dim2 = Color(0xFFBCCBDA);
  static const silverTop = Color(0xFFF1F4F8);
  static const silverBot = Color(0xFFC3CDD8);
  static const ink = Color(0xFF0A1422);

  static const background = BoxDecoration(
    gradient: RadialGradient(
      center: Alignment(0.7, -1.0),
      radius: 1.4,
      colors: [bgTop, bgMid, bgBot],
      stops: [0, 0.45, 1],
    ),
  );

  static const silver = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [silverTop, silverBot],
  );

  static const sheen = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    stops: [0, 0.38, 0.6],
    colors: [Color(0x8CFFFFFF), Color(0x1FFFFFFF), Color(0x00FFFFFF)],
  );
}

TextStyle ts(double size, {FontWeight w = FontWeight.w400, Color c = TP.text, double? h}) =>
    TextStyle(fontSize: size, fontWeight: w, color: c, height: h, decoration: TextDecoration.none);

/// Blue taken from the logo's shield, brightened so it reads on the dark background.
const tameBlue = LinearGradient(
  begin: Alignment.topCenter,
  end: Alignment.bottomCenter,
  colors: [Color(0xFF9AD2FF), Color(0xFF3D8FE0)],
);

const goldOrange = LinearGradient(
  begin: Alignment.topCenter,
  end: Alignment.bottomCenter,
  colors: [Color(0xFFFFD08A), Color(0xFFE08A2C)],
);

/// Paints its child (usually text) with a gradient.
class GradientText extends StatelessWidget {
  final Widget child;
  final Gradient gradient;
  const GradientText(this.child, this.gradient, {super.key});
  @override
  Widget build(BuildContext context) => ShaderMask(
        blendMode: BlendMode.srcIn,
        shaderCallback: (r) => gradient.createShader(r),
        child: child,
      );
}

/// "Tame" in logo blue + "Player" in orange.
class BrandName extends StatelessWidget {
  final double size;
  const BrandName({super.key, this.size = 42});
  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        GradientText(Text('Tame ', style: ts(size, w: FontWeight.w800, c: Colors.white)), tameBlue),
        Text('Player', style: ts(size, w: FontWeight.w800, c: TP.orange)),
      ]);
}

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'live_screen.dart';
import 'login_screen.dart';
import 'state.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  final app = AppState();
  runApp(TameApp(app: app));
  await app.load();
}

class TameApp extends StatelessWidget {
  final AppState app;
  const TameApp({super.key, required this.app});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Tame Player',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: const ColorScheme.dark(primary: TP.orange, surface: TP.panel),
        scaffoldBackgroundColor: TP.bgBot,
      ),
      home: IntroGate(
        app: app,
        child: ListenableBuilder(
        listenable: app,
        builder: (context, _) {
          if (!app.ready) {
            return Container(
              decoration: TP.background,
              alignment: Alignment.center,
              child: Image.asset('assets/logo.png', width: 140),
            );
          }
          return app.acc == null ? LoginScreen(app: app) : LiveScreen(app: app);
        },
        ),
      ),
    );
  }
}

/// Becomes true when the intro has finished (the guide waits for it before playing a channel).
final introDone = ValueNotifier<bool>(false);

double _c01(double v) => v < 0 ? 0 : (v > 1 ? 1 : v);

/// The opening: soft orange and blue lights drift behind the logo, the logo pops in,
/// the name fades in, it waits until the channels are ready, then the logo grows and fades away.
class IntroGate extends StatefulWidget {
  final Widget child;
  final AppState app;
  const IntroGate({super.key, required this.child, required this.app});

  @override
  State<IntroGate> createState() => _IntroGateState();
}

class _IntroGateState extends State<IntroGate> with TickerProviderStateMixin {
  // 0 → 0.7 : lights, logo pop, name (about 3.5 s)   ·   0.7 → 1 : logo grows and fades (about 1.5 s)
  late final AnimationController c;
  late final AnimationController lights;
  bool done = false;
  Player? _sound;

  @override
  void initState() {
    super.initState();
    c = AnimationController(vsync: this, duration: const Duration(milliseconds: 10000));
    lights = AnimationController(vsync: this, duration: const Duration(seconds: 6))..repeat();
    _run();
    _playSound();
  }

  Future<void> _run() async {
    await c.animateTo(0.86);
    // hold on the logo until the channels have loaded (up to 12 more seconds)
    final until = DateTime.now().add(const Duration(seconds: 12));
    while (mounted && (!widget.app.ready || widget.app.loading) && DateTime.now().isBefore(until)) {
      await Future.delayed(const Duration(milliseconds: 150));
    }
    if (!mounted) return;
    await c.animateTo(1);
    introDone.value = true;
    if (mounted) setState(() => done = true);
    lights.stop();
  }

  Future<void> _playSound() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      var which = prefs.getString('opt_introsound') ?? 'cinematic';
      if (which == 'off') return;
      if (which != 'streaming') which = 'cinematic';
      final p = Player();
      _sound = p;
      await p.setVolume(80);
      await p.open(Media('asset:///assets/intro_$which.wav'));
      Future.delayed(const Duration(seconds: 6), () {
        p.dispose();
        if (identical(_sound, p)) _sound = null;
      });
    } catch (_) {}
  }

  @override
  void dispose() {
    c.dispose();
    lights.dispose();
    super.dispose();
  }

  Widget _glow(Color color, double size, Offset at, double strength) => Positioned(
        left: at.dx - size / 2,
        top: at.dy - size / 2,
        width: size,
        height: size,
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(colors: [
              color.withAlpha((strength * 150).round()),
              color.withAlpha((strength * 55).round()),
              color.withAlpha(0),
            ], stops: const [0, 0.45, 1]),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Stack(children: [
      widget.child,
      if (!done)
        Positioned.fill(
          child: AnimatedBuilder(
            animation: Listenable.merge([c, lights]),
            builder: (context, _) {
              final t = c.value;
              final l = lights.value * 2 * math.pi;
              // 0–0.1 lights · 0.05–0.2 logo pops · 0.22–0.3 name · hold · 0.82–1 logo grows, then everything fades
              // 10 s: lights 0–0.8 s · logo pops 0.4–1.4 s · name 1.6–2.2 s · hold · logo grows 8.6–10 s · fades in the last 0.5 s
              final inT = _c01(t / 0.08);
              final pop = Curves.easeOutBack.transform(_c01((t - 0.04) / 0.1));
              final nameIn = _c01((t - 0.16) / 0.06);
              final grow = Curves.easeIn.transform(_c01((t - 0.86) / 0.14));
              final out = Curves.easeIn.transform(_c01((t - 0.95) / 0.05)); // the screen only uncovers at the very end
              final scale = (0.35 + 0.65 * pop) * (1 + 0.04 * math.sin(l * 2) * (1 - grow)) + 1.6 * grow;
              return IgnorePointer(
                child: Opacity(
                  opacity: 1 - out,
                  child: LayoutBuilder(builder: (context, box) {
                    final cx = box.maxWidth / 2, cy = box.maxHeight / 2 - 30;
                    final r = math.min(box.maxWidth, box.maxHeight);
                    final strength = inT * (0.75 + 0.25 * math.sin(l * 3));
                    return Container(
                      color: TP.bgBot,
                      child: Stack(children: [
                        Positioned.fill(child: Container(decoration: TP.background)),
                        // subtle drifting lights behind the logo
                        _glow(TP.orange, r * 0.85, Offset(cx + r * 0.16 * math.cos(l), cy + r * 0.08 * math.sin(l)), strength * 0.9),
                        _glow(const Color(0xFF3A8DFF), r * 0.95, Offset(cx - r * 0.18 * math.cos(l + 1), cy - r * 0.09 * math.sin(l + 1)),
                            strength),
                        _glow(const Color(0xFFFFB347), r * 0.35, Offset(cx + r * 0.05 * math.sin(l * 2), cy), strength * 0.6),
                        Center(
                          child: Column(mainAxisSize: MainAxisSize.min, children: [
                            Transform.scale(scale: scale, child: Image.asset('assets/logo.png', width: 210)),
                            const SizedBox(height: 28),
                            Opacity(
                              opacity: nameIn * (1 - _c01(grow * 2.5)),
                              child: Transform.translate(
                                offset: Offset(0, 12 * (1 - nameIn)),
                                child: const BrandName(size: 44),
                              ),
                            ),
                          ]),
                        ),
                      ]),
                    );
                  }),
                ),
              );
            },
          ),
        ),
    ]);
  }
}

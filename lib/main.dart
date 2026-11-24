import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';

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

double _c01(double v) => v < 0 ? 0 : (v > 1 ? 1 : v);

/// The opening: the logo pops in, the name fades in, then the logo grows and fades away.
class IntroGate extends StatefulWidget {
  final Widget child;
  const IntroGate({super.key, required this.child});

  @override
  State<IntroGate> createState() => _IntroGateState();
}

class _IntroGateState extends State<IntroGate> with SingleTickerProviderStateMixin {
  late final AnimationController c;
  bool done = false;

  @override
  void initState() {
    super.initState();
    c = AnimationController(vsync: this, duration: const Duration(milliseconds: 2400));
    c.addStatusListener((s) {
      if (s == AnimationStatus.completed && mounted) setState(() => done = true);
    });
    c.forward();
  }

  @override
  void dispose() {
    c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(children: [
      widget.child,
      if (!done)
        Positioned.fill(
          child: AnimatedBuilder(
            animation: c,
            builder: (context, _) {
              final t = c.value;
              final pop = Curves.easeOutBack.transform(_c01(t / 0.5));
              final out = Curves.easeIn.transform(_c01((t - 0.72) / 0.28));
              final scale = 0.35 + 0.65 * pop + 1.6 * out;
              final nameOpacity = _c01((t - 0.3) / 0.2) * (1 - _c01(out * 3));
              return IgnorePointer(
                child: Opacity(
                  opacity: 1 - out,
                  child: Container(
                    decoration: TP.background,
                    alignment: Alignment.center,
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Transform.scale(
                        scale: scale,
                        child: Image.asset('assets/logo.png', width: 200),
                      ),
                      const SizedBox(height: 26),
                      Opacity(
                        opacity: nameOpacity,
                        child: Text.rich(TextSpan(children: [
                          TextSpan(text: 'Tame ', style: ts(42, w: FontWeight.w800)),
                          TextSpan(text: 'Player', style: ts(42, w: FontWeight.w800, c: TP.orange)),
                        ])),
                      ),
                    ]),
                  ),
                ),
              );
            },
          ),
        ),
    ]);
  }
}

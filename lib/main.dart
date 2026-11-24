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
      home: ListenableBuilder(
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
    );
  }
}

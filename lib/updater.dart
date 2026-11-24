import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Build number baked in by GitHub when it builds the app (0 = built by hand).
const int kBuild = int.fromEnvironment('BUILD', defaultValue: 0);

const _latestUrl = 'https://api.github.com/repos/majettet4888/tame-player/releases/latest';

class UpdateInfo {
  final int build;
  final String url;
  const UpdateInfo(this.build, this.url);
}

/// Asks GitHub for the newest build. Returns it if it's newer than this one.
Future<UpdateInfo?> checkForUpdate() async {
  if (kBuild == 0) return null;
  try {
    final r = await http.get(
      Uri.parse(_latestUrl),
      headers: const {'Accept': 'application/vnd.github+json', 'User-Agent': 'TamePlayer'},
    ).timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) return null;
    final j = jsonDecode(r.body);
    if (j is! Map) return null;
    final n = int.tryParse('${j['tag_name']}'.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
    if (n <= kBuild) return null;
    final want = Platform.isWindows ? 'TamePlayer-Windows.zip' : 'TamePlayer.apk';
    final assets = j['assets'];
    if (assets is! List) return null;
    for (final a in assets) {
      if (a is Map && a['name'] == want) return UpdateInfo(n, '${a['browser_download_url']}');
    }
  } catch (_) {}
  return null;
}

bool get canInstallUpdates => Platform.isWindows;

/// Windows: downloads the new build, then a small script swaps the files and reopens the app.
Future<void> installWindowsUpdate(UpdateInfo u, void Function(double progress) onProgress) async {
  final tmp = await Directory.systemTemp.createTemp('tameplayer_update');
  final zip = File('${tmp.path}\\update.zip');
  final client = http.Client();
  try {
    final res = await client.send(http.Request('GET', Uri.parse(u.url)));
    if (res.statusCode != 200) throw Exception('Download failed (${res.statusCode})');
    final total = res.contentLength ?? 0;
    var got = 0;
    final sink = zip.openWrite();
    await for (final chunk in res.stream) {
      sink.add(chunk);
      got += chunk.length;
      if (total > 0) onProgress(got / total);
    }
    await sink.close();
  } finally {
    client.close();
  }

  final exe = Platform.resolvedExecutable;
  final appDir = File(exe).parent.path;
  final unzipTo = '${tmp.path}\\new';
  final ps = "Expand-Archive -LiteralPath '${zip.path}' -DestinationPath '$unzipTo' -Force; "
      "Copy-Item -Path '$unzipTo\\*' -Destination '$appDir' -Recurse -Force";
  final script = File('${tmp.path}\\update.cmd');
  await script.writeAsString([
    '@echo off',
    'timeout /t 2 /nobreak >nul',
    'powershell -NoProfile -ExecutionPolicy Bypass -Command "$ps"',
    'start "" "$exe"',
    '',
  ].join('\r\n'));
  await Process.start('cmd', ['/c', script.path], mode: ProcessStartMode.detached, runInShell: false);
  exit(0);
}

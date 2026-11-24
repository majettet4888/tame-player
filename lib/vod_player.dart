import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'state.dart';
import 'theme.dart';
import 'widgets.dart';

/// Full-screen player for a movie or an episode, with a progress bar and resume.
class VodPlayer extends StatefulWidget {
  final AppState app;
  final String url, title, subtitle, resumeKey;
  final int startAt; // seconds
  const VodPlayer({
    super.key,
    required this.app,
    required this.url,
    required this.title,
    required this.subtitle,
    required this.resumeKey,
    this.startAt = 0,
  });

  @override
  State<VodPlayer> createState() => _VodPlayerState();
}

String hms(Duration d) {
  final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
  final mm = m.toString().padLeft(h > 0 ? 2 : 1, '0'), ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
}

class _VodPlayerState extends State<VodPlayer> {
  late final Player player;
  late final VideoController vc;
  final FocusNode _focus = FocusNode();
  final List<StreamSubscription> _subs = [];
  Duration pos = Duration.zero, total = Duration.zero;
  bool playing = true, buffering = true, osd = true, _seeked = false;
  String? error;
  Timer? _osdTimer, _saveTimer;
  DateTime _lastBack = DateTime(2000);

  @override
  void initState() {
    super.initState();
    player = Player(configuration: const PlayerConfiguration(bufferSize: 64 * 1024 * 1024));
    vc = VideoController(player);
    _subs.add(player.stream.position.listen((p) {
      if (mounted) setState(() => pos = p);
    }));
    _subs.add(player.stream.duration.listen((d) {
      if (!mounted) return;
      setState(() => total = d);
      if (!_seeked && d > Duration.zero && widget.startAt > 5) {
        _seeked = true;
        player.seek(Duration(seconds: widget.startAt));
      }
    }));
    _subs.add(player.stream.playing.listen((p) {
      if (mounted) setState(() => playing = p);
    }));
    _subs.add(player.stream.buffering.listen((b) {
      if (mounted) setState(() => buffering = b);
    }));
    _subs.add(player.stream.error.listen((e) {
      if (mounted && pos == Duration.zero) setState(() => error = 'This title won\'t play right now. Try again later.');
    }));
    _subs.add(player.stream.completed.listen((done) {
      if (done) {
        widget.app.setVodPos(widget.resumeKey, 0);
        if (mounted) Navigator.of(context).maybePop();
      }
    }));
    player.open(Media(widget.url));
    _saveTimer = Timer.periodic(const Duration(seconds: 10), (_) => _save());
    _showOsd();
  }

  void _save() {
    final t = total.inSeconds, p = pos.inSeconds;
    if (t <= 0) return;
    // finished (last 3%) → start over next time
    widget.app.setVodPos(widget.resumeKey, p > t * 0.97 ? 0 : p);
  }

  @override
  void dispose() {
    _save();
    for (final s in _subs) {
      s.cancel();
    }
    _osdTimer?.cancel();
    _saveTimer?.cancel();
    _focus.dispose();
    player.dispose();
    super.dispose();
  }

  void _showOsd() {
    setState(() => osd = true);
    _osdTimer?.cancel();
    _osdTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && playing) setState(() => osd = false);
    });
  }

  void _seekBy(int seconds) {
    var t = pos + Duration(seconds: seconds);
    if (t < Duration.zero) t = Duration.zero;
    if (total > Duration.zero && t > total) t = total - const Duration(seconds: 1);
    player.seek(t);
    setState(() => pos = t);
    _showOsd();
  }

  KeyEventResult _onKey(FocusNode n, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.arrowLeft) {
      _seekBy(-10);
    } else if (k == LogicalKeyboardKey.arrowRight) {
      _seekBy(10);
    } else if (k == LogicalKeyboardKey.mediaRewind || k == LogicalKeyboardKey.comma) {
      _seekBy(-30);
    } else if (k == LogicalKeyboardKey.mediaFastForward || k == LogicalKeyboardKey.period) {
      _seekBy(30);
    } else if (e is KeyRepeatEvent) {
      return KeyEventResult.handled;
    } else if (k == LogicalKeyboardKey.select ||
        k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.numpadEnter ||
        k == LogicalKeyboardKey.space ||
        k == LogicalKeyboardKey.mediaPlayPause ||
        k == LogicalKeyboardKey.mediaPlay ||
        k == LogicalKeyboardKey.mediaPause ||
        k == LogicalKeyboardKey.keyP) {
      player.playOrPause();
      _showOsd();
    } else if (k == LogicalKeyboardKey.arrowUp || k == LogicalKeyboardKey.arrowDown) {
      _showOsd();
    } else if (k == LogicalKeyboardKey.escape ||
        k == LogicalKeyboardKey.goBack ||
        k == LogicalKeyboardKey.browserBack ||
        k == LogicalKeyboardKey.backspace) {
      _back();
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  void _back() {
    final now = DateTime.now();
    if (now.difference(_lastBack).inMilliseconds < 300) return;
    _lastBack = now;
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final frac = total.inMilliseconds > 0 ? pos.inMilliseconds / total.inMilliseconds : 0.0;
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: GestureDetector(
          onTap: () {
            player.playOrPause();
            _showOsd();
          },
          child: Stack(fit: StackFit.expand, children: [
            Video(controller: vc, controls: NoVideoControls, fill: Colors.black),
            if (buffering && error == null)
              const Center(child: SizedBox(width: 48, height: 48, child: CircularProgressIndicator(color: TP.orange, strokeWidth: 3))),
            if (error != null)
              Center(child: Text(error!, textAlign: TextAlign.center, style: ts(22, w: FontWeight.w700))),
            if (!playing && error == null)
              Center(
                child: Container(
                  width: 110,
                  height: 110,
                  alignment: Alignment.center,
                  decoration: const BoxDecoration(color: Color(0xA6050C16), shape: BoxShape.circle),
                  child: Text('❚❚', style: ts(44, c: Colors.white)),
                ),
              ),
            AnimatedOpacity(
              opacity: osd || !playing ? 1 : 0,
              duration: const Duration(milliseconds: 250),
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(48, 80, 48, 36),
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [Color(0xF503080F), Color(0x0003080F)],
                    ),
                  ),
                  child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                    if (widget.subtitle.isNotEmpty) Text(widget.subtitle, style: ts(18, c: TP.dim2)),
                    Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: ts(32, w: FontWeight.w800)),
                    const SizedBox(height: 14),
                    LayoutBuilder(
                      builder: (context, c) => GestureDetector(
                        onTapDown: (d) {
                          if (total > Duration.zero) {
                            player.seek(total * (d.localPosition.dx / c.maxWidth).clamp(0.0, 1.0).toDouble());
                          }
                        },
                        child: Container(color: Colors.transparent, padding: const EdgeInsets.symmetric(vertical: 6), child: progressBar(c.maxWidth, frac)),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(children: [
                      Text(hms(pos), style: ts(16, c: TP.text)),
                      const Spacer(),
                      Text('◀ ▶ 10 sec · ⏪ ⏩ 30 sec · OK pause · BACK saves your spot', style: ts(14, c: TP.dim)),
                      const Spacer(),
                      Text(total > Duration.zero ? '-${hms(total - pos)}' : '', style: ts(16, c: TP.text)),
                    ]),
                  ]),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

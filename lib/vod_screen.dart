import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'state.dart';
import 'theme.dart';
import 'vod_player.dart';
import 'widgets.dart';
import 'xtream.dart';

int _cl(int v, int lo, int hi) => v < lo ? lo : (v > hi ? hi : v);

/// Browse and play Movies or TV Shows from the provider.
class VodScreen extends StatefulWidget {
  final AppState app;
  final bool series;
  const VodScreen({super.key, required this.app, required this.series});

  @override
  State<VodScreen> createState() => _VodScreenState();
}

class _VodScreenState extends State<VodScreen> {
  AppState get app => widget.app;
  bool get series => widget.series;
  XtreamClient? get client => app.client;

  final FocusNode _focus = FocusNode();
  final ScrollController _catScroll = ScrollController();
  double sw = 1280, sh = 720;

  List<ChannelGroup> cats = [];
  bool loadingCats = true, loadingItems = false;
  String? error;
  int catIdx = 0;
  final Map<String, List<VodItem>> _cache = {};
  List<VodItem> items = [];

  String zone = 'cats'; // cats | grid | detail
  int gridIdx = 0, gridTop = 0;

  // detail
  VodItem? sel;
  Map<String, dynamic> info = {};
  bool loadingInfo = false;
  int btnIdx = 0;
  List<int> seasons = [];
  Map<int, List<Episode>> episodes = {};
  int seasonIdx = 0, epIdx = 0, epTop = 0;
  String dzone = 'btn'; // btn | season | eps
  DateTime _lastBack = DateTime(2000);

  static const double cardW = 150, posterH = 225, cellW = 172, cellH = 300;

  int get cols => ((sw - 360) / cellW).floor().clamp(1, 20).toInt();
  int get visRows => ((sh - 130) / cellH).floor().clamp(1, 10).toInt();

  @override
  void initState() {
    super.initState();
    _loadCats();
  }

  @override
  void dispose() {
    _focus.dispose();
    _catScroll.dispose();
    super.dispose();
  }

  Future<void> _loadCats() async {
    final c = client;
    if (c == null) return;
    try {
      final l = await c.vodCategories(series: series);
      if (!mounted) return;
      setState(() {
        cats = l;
        loadingCats = false;
      });
      if (l.isNotEmpty) _loadItems(0);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        loadingCats = false;
        error = friendlyError(e);
      });
    }
  }

  Future<void> _loadItems(int i) async {
    if (i < 0 || i >= cats.length) return;
    final id = cats[i].id;
    setState(() {
      catIdx = i;
      gridIdx = 0;
      gridTop = 0;
    });
    final cached = _cache[id];
    if (cached != null) {
      setState(() => items = cached);
      return;
    }
    setState(() {
      items = [];
      loadingItems = true;
    });
    try {
      final l = await client!.vodList(id, series: series);
      _cache[id] = l;
      if (!mounted || catIdx != i) return;
      setState(() {
        items = l;
        loadingItems = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => loadingItems = false);
    }
  }

  // ---------------------------------------------------------------- details

  Future<void> _openDetail(VodItem v) async {
    setState(() {
      sel = v;
      zone = 'detail';
      info = {};
      loadingInfo = true;
      btnIdx = 0;
      seasons = [];
      episodes = {};
      seasonIdx = 0;
      epIdx = 0;
      epTop = 0;
      dzone = series ? 'eps' : 'btn';
    });
    try {
      final j = series ? await client!.seriesInfo(v.id) : await client!.vodInfo(v.id);
      if (!mounted || sel != v) return;
      final eps = <int, List<Episode>>{};
      if (series) {
        final raw = j['episodes'];
        void addList(dynamic l) {
          if (l is! List) return;
          for (final e in l) {
            if (e is! Map) continue;
            final inf = e['info'] is Map ? e['info'] as Map : const {};
            final season = int.tryParse('${e['season'] ?? 0}') ?? 0;
            final ep = Episode(
              '${e['id']}',
              '${e['title'] ?? ''}'.trim(),
              '${e['container_extension'] ?? 'mp4'}',
              '${inf['plot'] ?? ''}'.trim(),
              season,
              int.tryParse('${e['episode_num'] ?? 0}') ?? 0,
              int.tryParse('${inf['duration_secs'] ?? 0}') ?? 0,
              (inf['movie_image'] is String && (inf['movie_image'] as String).isNotEmpty) ? inf['movie_image'] as String : null,
            );
            (eps[season] ??= []).add(ep);
          }
        }

        if (raw is Map) {
          raw.forEach((k, l) => addList(l));
        } else if (raw is List) {
          for (final l in raw) {
            addList(l);
          }
        }
        for (final l in eps.values) {
          l.sort((a, b) => a.number.compareTo(b.number));
        }
      }
      setState(() {
        info = j;
        loadingInfo = false;
        episodes = eps;
        seasons = eps.keys.toList()..sort();
      });
    } catch (_) {
      if (mounted) setState(() => loadingInfo = false);
    }
  }

  Map get _inf => info['info'] is Map ? info['info'] as Map : const {};

  String get _plot {
    final p = '${_inf['plot'] ?? _inf['description'] ?? ''}'.trim();
    return p.isNotEmpty ? p : (sel?.plot ?? '');
  }

  String get _meta {
    final parts = <String>[];
    final year = '${_inf['releasedate'] ?? _inf['releaseDate'] ?? _inf['release_date'] ?? sel?.year ?? ''}'.trim();
    if (year.isNotEmpty) parts.add(year.length >= 4 ? year.substring(0, 4) : year);
    final secs = int.tryParse('${_inf['duration_secs'] ?? ''}');
    if (secs != null && secs > 0) parts.add('${secs ~/ 3600 > 0 ? '${secs ~/ 3600}h ' : ''}${(secs % 3600) ~/ 60}m');
    final rating = '${_inf['rating'] ?? sel?.rating ?? ''}'.trim();
    if (rating.isNotEmpty && rating != '0' && rating != 'null') parts.add('★ $rating');
    final genre = '${_inf['genre'] ?? ''}'.trim();
    if (genre.isNotEmpty) parts.add(genre);
    if (series && seasons.isNotEmpty) parts.add('${seasons.length} season${seasons.length == 1 ? '' : 's'}');
    return parts.join('  ·  ');
  }

  void _playMovie({required bool resume}) {
    final v = sel;
    if (v == null) return;
    final md = info['movie_data'] is Map ? info['movie_data'] as Map : const {};
    final ext = '${md['container_extension'] ?? v.ext}';
    final key = 'm${v.id}';
    Navigator.of(context)
        .push(MaterialPageRoute(
          builder: (_) => VodPlayer(
            app: app,
            url: client!.movieUrl(v.id, ext),
            title: v.name,
            subtitle: 'Movie',
            resumeKey: key,
            startAt: resume ? app.vodPos(key) : 0,
          ),
        ))
        .then((_) => _back2me());
  }

  void _playEpisode(Episode e) {
    final v = sel;
    if (v == null) return;
    final key = 'e${e.id}';
    Navigator.of(context)
        .push(MaterialPageRoute(
          builder: (_) => VodPlayer(
            app: app,
            url: client!.episodeUrl(e.id, e.ext),
            title: e.title.isEmpty ? 'Episode ${e.number}' : e.title,
            subtitle: '${v.name}  ·  S${e.season} E${e.number}',
            resumeKey: key,
            startAt: app.vodPos(key),
          ),
        ))
        .then((_) => _back2me());
  }

  void _back2me() {
    if (!mounted) return;
    setState(() {});
    _focus.requestFocus();
  }

  List<Episode> get _eps => seasons.isEmpty ? const [] : (episodes[seasons[_cl(seasonIdx, 0, seasons.length - 1)]] ?? const []);

  // ---------------------------------------------------------------- input

  KeyEventResult _onKey(FocusNode n, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    String? a;
    if (k == LogicalKeyboardKey.arrowUp) {
      a = 'up';
    } else if (k == LogicalKeyboardKey.arrowDown) {
      a = 'down';
    } else if (k == LogicalKeyboardKey.arrowLeft) {
      a = 'left';
    } else if (k == LogicalKeyboardKey.arrowRight) {
      a = 'right';
    } else if (e is KeyRepeatEvent) {
      return KeyEventResult.handled;
    } else if (k == LogicalKeyboardKey.select ||
        k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.numpadEnter ||
        k == LogicalKeyboardKey.gameButtonA ||
        k == LogicalKeyboardKey.space) {
      a = 'ok';
    } else if (k == LogicalKeyboardKey.escape ||
        k == LogicalKeyboardKey.goBack ||
        k == LogicalKeyboardKey.browserBack ||
        k == LogicalKeyboardKey.backspace ||
        k == LogicalKeyboardKey.gameButtonB) {
      a = 'back';
    } else if (k == LogicalKeyboardKey.pageUp || k == LogicalKeyboardKey.channelUp || k == LogicalKeyboardKey.mediaRewind) {
      a = 'pgup';
    } else if (k == LogicalKeyboardKey.pageDown || k == LogicalKeyboardKey.channelDown || k == LogicalKeyboardKey.mediaFastForward) {
      a = 'pgdn';
    }
    if (a == null) return KeyEventResult.ignored;
    _act(a);
    return KeyEventResult.handled;
  }

  void _act(String a) {
    if (a == 'back') {
      final now = DateTime.now();
      if (now.difference(_lastBack).inMilliseconds < 250) return;
      _lastBack = now;
    }
    switch (zone) {
      case 'cats':
        switch (a) {
          case 'up':
          case 'down':
            if (cats.isEmpty) return;
            _loadItems((catIdx + (a == 'up' ? -1 : 1) + cats.length) % cats.length);
            _scrollCats();
          case 'pgup':
          case 'pgdn':
            if (cats.isEmpty) return;
            _loadItems(_cl(catIdx + (a == 'pgup' ? -8 : 8), 0, cats.length - 1));
            _scrollCats();
          case 'right':
          case 'ok':
            if (items.isNotEmpty) setState(() => zone = 'grid');
          case 'back':
          case 'left':
            Navigator.of(context).maybePop();
        }
      case 'grid':
        {
          final n = items.length;
          if (n == 0) {
            if (a == 'back' || a == 'left') setState(() => zone = 'cats');
            return;
          }
          var i = gridIdx;
          switch (a) {
            case 'left':
              if (i % cols == 0) {
                setState(() => zone = 'cats');
                return;
              }
              i--;
            case 'right':
              if (i + 1 < n && (i + 1) % cols != 0) i++;
            case 'up':
              if (i - cols >= 0) i -= cols;
            case 'down':
              if (i + cols < n) {
                i += cols;
              } else if ((i ~/ cols) < ((n - 1) ~/ cols)) {
                i = n - 1;
              }
            case 'pgup':
              i = _cl(i - cols * visRows, 0, n - 1);
            case 'pgdn':
              i = _cl(i + cols * visRows, 0, n - 1);
            case 'ok':
              _openDetail(items[i]);
              return;
            case 'back':
              setState(() => zone = 'cats');
              return;
          }
          final r = i ~/ cols;
          setState(() {
            gridIdx = i;
            if (r < gridTop) gridTop = r;
            if (r >= gridTop + visRows) gridTop = r - visRows + 1;
          });
        }
      case 'detail':
        _detailAct(a);
    }
  }

  void _detailAct(String a) {
    if (a == 'back') {
      setState(() => zone = 'grid');
      return;
    }
    if (!series) {
      final hasResume = sel != null && app.vodPos('m${sel!.id}') > 30;
      final nb = hasResume ? 2 : 1;
      switch (a) {
        case 'left':
        case 'right':
          setState(() => btnIdx = (btnIdx + 1) % nb);
        case 'ok':
          _playMovie(resume: hasResume && btnIdx == 0);
      }
      return;
    }
    final eps = _eps;
    switch (dzone) {
      case 'season':
        switch (a) {
          case 'left':
          case 'right':
            if (seasons.isEmpty) return;
            setState(() {
              seasonIdx = _cl(seasonIdx + (a == 'left' ? -1 : 1), 0, seasons.length - 1);
              epIdx = 0;
              epTop = 0;
            });
          case 'down':
          case 'ok':
            if (eps.isNotEmpty) setState(() => dzone = 'eps');
        }
      case 'eps':
        switch (a) {
          case 'up':
            if (epIdx == 0) {
              setState(() => dzone = 'season');
            } else {
              setState(() {
                epIdx--;
                if (epIdx < epTop) epTop = epIdx;
              });
            }
          case 'down':
            if (epIdx + 1 < eps.length) {
              setState(() {
                epIdx++;
                if (epIdx >= epTop + 5) epTop = epIdx - 4;
              });
            }
          case 'left':
          case 'right':
            if (seasons.length > 1) {
              setState(() {
                seasonIdx = _cl(seasonIdx + (a == 'left' ? -1 : 1), 0, seasons.length - 1);
                epIdx = 0;
                epTop = 0;
              });
            }
          case 'ok':
            if (eps.isNotEmpty) _playEpisode(eps[_cl(epIdx, 0, eps.length - 1)]);
        }
    }
  }

  void _scrollCats() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_catScroll.hasClients) return;
      final t = (catIdx * 48.0 - 240).clamp(0.0, _catScroll.position.maxScrollExtent).toDouble();
      _catScroll.animateTo(t, duration: const Duration(milliseconds: 140), curve: Curves.easeOut);
    });
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: zone == 'cats',
      onPopInvokedWithResult: (didPop, r) {
        if (!didPop) _act('back');
      },
      child: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: Scaffold(
          backgroundColor: TP.bgBot,
          body: Container(
            decoration: TP.background,
            child: LayoutBuilder(builder: (context, c) {
              final w = c.maxWidth, h = c.maxHeight;
              if (w > 0 && h > 0) {
                final aspect = w / h;
                if (aspect >= 16 / 9) {
                  sh = 720;
                  sw = 720 * aspect;
                } else {
                  sw = 1280;
                  sh = 1280 / aspect;
                }
              }
              return SizedBox(
                width: w,
                height: h,
                child: FittedBox(
                  fit: BoxFit.fill,
                  child: SizedBox(
                    width: sw,
                    height: sh,
                    child: DefaultTextStyle(style: ts(16), child: _stage()),
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }

  Widget _stage() {
    return Stack(children: [
      // title
      Positioned(
        left: 28,
        top: 22,
        child: Row(children: [
          Icon(series ? Icons.video_library_rounded : Icons.movie_creation_rounded, color: TP.orange, size: 34),
          const SizedBox(width: 12),
          Text(series ? 'TV Shows' : 'Movies', style: ts(32, w: FontWeight.w800)),
          const SizedBox(width: 18),
          if (cats.isNotEmpty)
            Text('${cats[_cl(catIdx, 0, cats.length - 1)].name}  ·  ${loadingItems ? '…' : '${items.length}'}',
                style: ts(18, c: TP.dim2)),
        ]),
      ),
      Positioned(right: 26, top: 18, child: Image.asset('assets/logo.png', width: 52)),
      // categories
      Positioned(
        left: 0,
        top: 84,
        bottom: 40,
        width: 310,
        child: loadingCats
            ? const Center(child: CircularProgressIndicator(color: TP.orange))
            : (error != null
                ? Padding(padding: const EdgeInsets.all(24), child: Text(error!, style: ts(16, c: TP.dim2)))
                : ListView.builder(
                    controller: _catScroll,
                    itemCount: cats.length,
                    itemExtent: 48,
                    itemBuilder: (context, i) {
                      final f = i == catIdx;
                      return LiftItem(
                        focused: f && zone == 'cats',
                        fx: app.fx,
                        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 11),
                        onTap: () {
                          _loadItems(i);
                          setState(() => zone = 'cats');
                        },
                        child: Row(children: [
                          Container(
                            width: 8,
                            height: 8,
                            margin: const EdgeInsets.only(right: 12),
                            decoration: BoxDecoration(shape: BoxShape.circle, color: f ? TP.orange : Colors.transparent),
                          ),
                          Expanded(
                            child: Text(cats[i].name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: ts(17, w: f ? FontWeight.w700 : FontWeight.w400, c: f && zone == 'cats' ? const Color(0xFF050B14) : TP.text)),
                          ),
                        ]),
                      );
                    },
                  )),
      ),
      // grid
      Positioned(left: 330, top: 84, right: 20, bottom: 40, child: _grid()),
      // hints
      Positioned(
        left: 0,
        right: 0,
        bottom: 0,
        height: 32,
        child: Container(
          color: TP.hintBar,
          padding: const EdgeInsets.symmetric(horizontal: 22),
          child: const Row(children: [
            Kbd('▲▼◀▶', 'Browse'),
            SizedBox(width: 26),
            Kbd('OK', 'Open'),
            SizedBox(width: 26),
            Kbd('⏪ ⏩', 'Page'),
            SizedBox(width: 26),
            Kbd('BACK', 'Back to Live TV'),
          ]),
        ),
      ),
      if (zone == 'detail' && sel != null) _detail(),
    ]);
  }

  Widget _grid() {
    if (loadingItems) return const Center(child: CircularProgressIndicator(color: TP.orange));
    if (items.isEmpty) {
      return Center(child: Text(cats.isEmpty ? '' : 'Nothing in this category.', style: ts(18, c: TP.dim2)));
    }
    final first = gridTop * cols, last = (first + cols * visRows).clamp(0, items.length).toInt();
    return Listener(
      onPointerSignal: (e) {
        if (e is PointerScrollEvent) {
          setState(() {
            zone = 'grid';
            gridTop = _cl(gridTop + (e.scrollDelta.dy > 0 ? 1 : -1), 0, ((items.length - 1) ~/ cols));
            gridIdx = _cl(gridTop * cols, 0, items.length - 1);
          });
        }
      },
      child: Stack(clipBehavior: Clip.none, children: [
        for (var i = first; i < last; i++)
          if (i != gridIdx || zone != 'grid') _card(i, first),
        if (zone == 'grid' && gridIdx >= first && gridIdx < last) _card(gridIdx, first),
      ]),
    );
  }

  Widget _card(int i, int first) {
    final v = items[i];
    final r = (i - first) ~/ cols, c = (i - first) % cols;
    final f = zone == 'grid' && i == gridIdx;
    final lift = f && app.fx != 'off';
    final resume = app.vodPos(series ? 's${v.id}' : 'm${v.id}');
    return Positioned(
      left: c * cellW,
      top: r * cellH,
      width: cardW,
      height: cellH - 12,
      child: GestureDetector(
        onTap: () {
          if (f) {
            _openDetail(v);
          } else {
            setState(() {
              zone = 'grid';
              gridIdx = i;
            });
          }
        },
        child: AnimatedScale(
          scale: lift ? (app.fx == 'full' ? 1.1 : 1.06) : 1,
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: cardW,
              height: posterH,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                color: TP.cell,
                border: f ? Border.all(color: TP.orange, width: 3) : null,
                boxShadow: lift ? const [BoxShadow(color: Color(0x99000000), blurRadius: 24, offset: Offset(0, 12))] : null,
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(f ? 7 : 10),
                child: Stack(fit: StackFit.expand, children: [
                  _poster(v),
                  if (lift) const DecoratedBox(decoration: BoxDecoration(gradient: TP.sheen)),
                  if (resume > 30 && !series)
                    Positioned(left: 0, right: 0, bottom: 0, height: 5, child: Container(color: const Color(0xAA000000))),
                ]),
              ),
            ),
            const SizedBox(height: 8),
            Text(v.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: ts(14, w: f ? FontWeight.w700 : FontWeight.w500, c: f ? Colors.white : TP.dim2, h: 1.2)),
          ]),
        ),
      ),
    );
  }

  Widget _poster(VodItem v, {double fontSize = 16}) {
    final fallback = Container(
      color: hueColor(v.id * 37, .45, .28),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(10),
      child: Text(v.name, textAlign: TextAlign.center, maxLines: 4, overflow: TextOverflow.ellipsis, style: ts(fontSize, w: FontWeight.w700)),
    );
    final p = v.poster;
    if (p == null) return fallback;
    return Image.network(p, fit: BoxFit.cover, errorBuilder: (ctx, err, st) => fallback);
  }

  Widget _detail() {
    final v = sel!;
    final hasResume = !series && app.vodPos('m${v.id}') > 30;
    final eps = _eps;
    Widget btn(String label, IconData icon, int i) {
      final f = dzone == 'btn' && btnIdx == i;
      return GestureDetector(
        onTap: () {
          setState(() => btnIdx = i);
          _detailAct('ok');
        },
        child: AnimatedScale(
          scale: f && app.fx != 'off' ? 1.06 : 1,
          duration: const Duration(milliseconds: 150),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 14),
            decoration: BoxDecoration(
              gradient: f ? TP.silver : null,
              color: f ? null : TP.kbd,
              borderRadius: BorderRadius.circular(12),
              boxShadow: f ? const [BoxShadow(color: Color(0x73000000), blurRadius: 24, offset: Offset(0, 12))] : null,
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, color: f ? TP.ink : Colors.white, size: 24),
              const SizedBox(width: 10),
              Text(label, style: ts(18, w: FontWeight.w700, c: f ? TP.ink : Colors.white)),
            ]),
          ),
        ),
      );
    }

    return Positioned.fill(
      child: Container(
        color: TP.bgBot,
        child: Stack(children: [
          // soft blurred poster behind everything
          if (v.poster != null)
            Positioned.fill(
              child: Opacity(
                opacity: 0.35,
                child: ImageFiltered(
                  imageFilter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
                  child: Image.network(v.poster!, fit: BoxFit.cover, errorBuilder: (ctx, err, st) => const SizedBox()),
                ),
              ),
            ),
          Positioned.fill(
            child: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(colors: [Color(0xF0152B47), Color(0xB31D3758)]),
              ),
            ),
          ),
          Positioned(
            left: 60,
            top: 60,
            width: 300,
            height: 450,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: _poster(v, fontSize: 24),
            ),
          ),
          Positioned(
            left: 400,
            top: 60,
            right: 60,
            bottom: 50,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(v.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: ts(40, w: FontWeight.w800, h: 1.1)),
              const SizedBox(height: 10),
              Text(loadingInfo ? 'Loading…' : _meta, style: ts(18, c: TP.orangeLight, w: FontWeight.w600)),
              const SizedBox(height: 14),
              Text(_plot, maxLines: series ? 3 : 7, overflow: TextOverflow.ellipsis, style: ts(17, c: TP.dim2, h: 1.45)),
              const SizedBox(height: 24),
              if (!series)
                Row(children: [
                  if (hasResume) btn('Resume from ${hms(Duration(seconds: app.vodPos('m${v.id}')))}', Icons.play_arrow_rounded, 0),
                  if (hasResume) const SizedBox(width: 16),
                  btn(hasResume ? 'Start over' : 'Play', hasResume ? Icons.replay_rounded : Icons.play_arrow_rounded, hasResume ? 1 : 0),
                ]),
              if (series && !loadingInfo && seasons.isEmpty) Text('No episodes available.', style: ts(17, c: TP.dim2)),
              if (series && seasons.isNotEmpty) ...[
                SizedBox(
                  height: 46,
                  child: ListView(scrollDirection: Axis.horizontal, children: [
                    for (var i = 0; i < seasons.length; i++)
                      GestureDetector(
                        onTap: () => setState(() {
                          seasonIdx = i;
                          epIdx = 0;
                          epTop = 0;
                          dzone = 'season';
                        }),
                        child: Container(
                          margin: const EdgeInsets.only(right: 10),
                          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                          decoration: BoxDecoration(
                            gradient: i == seasonIdx && dzone == 'season' ? TP.silver : null,
                            color: i == seasonIdx ? (dzone == 'season' ? null : TP.orange) : TP.kbd,
                            borderRadius: BorderRadius.circular(22),
                          ),
                          child: Text('Season ${seasons[i]}',
                              style: ts(16,
                                  w: FontWeight.w700,
                                  c: i == seasonIdx ? (dzone == 'season' ? TP.ink : const Color(0xFF111111)) : TP.text)),
                        ),
                      ),
                  ]),
                ),
                const SizedBox(height: 14),
                for (var i = epTop; i < eps.length && i < epTop + 5; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: LiftItem(
                      focused: dzone == 'eps' && i == epIdx,
                      fx: app.fx,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      onTap: () => _playEpisode(eps[i]),
                      child: Row(children: [
                        SizedBox(
                          width: 54,
                          child: Text('E${eps[i].number}',
                              style: ts(16, w: FontWeight.w800, c: dzone == 'eps' && i == epIdx ? TP.ink : TP.orangeLight)),
                        ),
                        Expanded(
                          child: Text(eps[i].title.isEmpty ? 'Episode ${eps[i].number}' : eps[i].title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: ts(17, w: FontWeight.w600, c: dzone == 'eps' && i == epIdx ? const Color(0xFF050B14) : TP.text)),
                        ),
                        if (app.vodPos('e${eps[i].id}') > 30)
                          Text('  resume ${hms(Duration(seconds: app.vodPos('e${eps[i].id}')))}',
                              style: ts(14, c: dzone == 'eps' && i == epIdx ? const Color(0xFF1B2B3D) : TP.orangeLight)),
                        if (eps[i].seconds > 0)
                          Text('  ${eps[i].seconds ~/ 60}m',
                              style: ts(14, c: dzone == 'eps' && i == epIdx ? const Color(0xFF1B2B3D) : TP.dim2)),
                      ]),
                    ),
                  ),
                if (eps.length > 5)
                  Text('${epIdx + 1} of ${eps.length}  ·  ▲▼ more episodes  ·  ◀ ▶ seasons', style: ts(14, c: TP.dim)),
              ],
            ]),
          ),
          Positioned(left: 60, bottom: 18, child: Text('OK play  ·  BACK to the list', style: ts(14, c: TP.dim))),
        ]),
      ),
    );
  }
}

import 'dart:async';
import 'dart:io' show Platform, exit;
import 'dart:ui' show ImageFilter;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'login_screen.dart';
import 'main.dart' show introDone;
import 'state.dart';
import 'theme.dart';
import 'updater.dart';
import 'vod_screen.dart';
import 'widgets.dart';
import 'xtream.dart';

enum Area { guide, menu, full, settings, dialog, input, side }

const double kRowH = 58, kChW = 300;
const double kPxPerMin = 980 / 150; // 30 minutes = 196 px

int clampI(int v, int lo, int hi) => v < lo ? lo : (v > hi ? hi : v);

class _SetItem {
  final String label, value;
  final void Function(int dir)? change;
  final bool button, header, note;
  _SetItem(this.label, this.value, this.change, {this.button = false})
      : header = false,
        note = false;
  _SetItem.header(this.label)
      : value = '',
        change = null,
        button = false,
        header = true,
        note = false;
  _SetItem.note(this.label)
      : value = '',
        change = null,
        button = false,
        header = true,
        note = true;
}

class _Result {
  final Channel ch;
  final Program? p;
  final String title, sub;
  _Result(this.ch, this.p, this.title, this.sub);
}

class _MenuItem {
  final String kind, label;
  final int cat, count;
  final IconData? icon;
  _MenuItem(this.kind, this.label, {this.cat = -1, this.count = 0, this.icon});
}

class LiveScreen extends StatefulWidget {
  final AppState app;
  const LiveScreen({super.key, required this.app});

  @override
  State<LiveScreen> createState() => _LiveScreenState();
}

class _LiveScreenState extends State<LiveScreen> with SingleTickerProviderStateMixin {
  AppState get app => widget.app;

  late final Player player;
  late final VideoController vc;
  late final AnimationController stripes;
  final FocusNode _focus = FocusNode();
  final ScrollController _menuScroll = ScrollController();
  final List<StreamSubscription> _subs = [];
  Timer? _tick, _osdTimer, _toastTimer;

  Area area = Area.guide;
  int catIdx = 0, menuIdx = 0, row = 0, top = 0, setIdx = 1, dlgIdx = 0;
  String _dlgTitle = '', _dlgSub = '', _dlgNo = 'Stay', _dlgYes = 'Exit';
  VoidCallback? _dlgYesAct;
  Area _dlgFrom = Area.guide;
  Program? _optProg;
  int? _prevId;
  int sideIdx = 0;
  String setPage = 'main';
  double sw = 1280, sh = 720; // stage size: always fills the window exactly
  int get rows => clampI(((sh - 300 - 36 - 30) / kRowH).floor(), 3, 30);
  int get winMin => ((sw - kChW) / kPxPerMin).floor();
  String _catId = '__all';
  Area _panelFrom = Area.guide;
  Channel? _optCh;
  String _inputMode = 'search';
  final TextEditingController _inputCtl = TextEditingController();
  late final FocusNode _inputFocus = FocusNode(onKeyEvent: _onInputKey);
  List<_Result> _results = [];
  int resIdx = 0;
  bool _unlocked = false;
  VoidCallback? _afterPin;
  int _retries = 0;
  Timer? _retryTimer;
  DateTime? _okDown;
  bool _longFired = false;
  UpdateInfo? _upd;
  double? _updProg;
  final GlobalKey _setFocusKey = GlobalKey();
  List<Channel> list = [];
  DateTime cursor = DateTime.now();
  DateTime win = floor30(DateTime.now());
  int? playingId;
  bool osd = false, buffering = false, hasVideo = false, paused = false, _triedAlt = false;
  String? playError, toast;
  DateTime _backAt = DateTime(2000), _lastBack = DateTime(2000);
  List<Channel>? _seen;

  // ---------------------------------------------------------------- lifecycle

  @override
  void initState() {
    super.initState();
    const bufMb = {'normal': 32, 'large': 64, 'xl': 128};
    player = Player(configuration: PlayerConfiguration(bufferSize: (bufMb[app.opt('buf', 'normal')] ?? 32) * 1024 * 1024));
    vc = VideoController(player,
        configuration: VideoControllerConfiguration(enableHardwareAcceleration: app.opt('hw', 'on') == 'on'));
    stripes = AnimationController(vsync: this, duration: const Duration(seconds: 7))..repeat();
    _subs.add(player.stream.buffering.listen((b) {
      if (mounted) setState(() => buffering = b);
    }));
    _subs.add(player.stream.width.listen((w) {
      if (!mounted) return;
      setState(() {
        hasVideo = (w ?? 0) > 0;
        if (hasVideo) {
          _retries = 0;
          playError = null;
        }
      });
    }));
    _subs.add(player.stream.completed.listen((done) {
      if (done) _scheduleReconnect(); // a live channel should never "finish": the stream dropped
    }));
    _applyPlayerProps();
    _subs.add(player.stream.error.listen(_onPlayError));
    _tick = Timer.periodic(const Duration(seconds: 15), (_) {
      if (!mounted) return;
      final now = DateTime.now();
      if (now.isAfter(app.rangeEnd.subtract(const Duration(hours: 6)))) app.resetRange();
      if (cursor.isBefore(now)) cursor = now;
      final minT = floor30(now);
      if (win.isBefore(minT)) win = minT;
      setState(() {});
      _checkReminders();
    });
    app.addListener(_onApp);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onApp());
    Future.delayed(const Duration(seconds: 5), () => _checkUpdate(manual: false));
  }

  @override
  void dispose() {
    app.removeListener(_onApp);
    for (final s in _subs) {
      s.cancel();
    }
    _tick?.cancel();
    _osdTimer?.cancel();
    _toastTimer?.cancel();
    _retryTimer?.cancel();
    _inputCtl.dispose();
    _inputFocus.dispose();
    stripes.dispose();
    _menuScroll.dispose();
    _focus.dispose();
    player.dispose();
    super.dispose();
  }

  bool _hadFullGuide = false;

  void _onApp() {
    if (!mounted) return;
    if (app.fullGuideLoaded != _hadFullGuide) {
      _hadFullGuide = app.fullGuideLoaded;
      if (area == Area.input && _inputMode == 'search') {
        WidgetsBinding.instance.addPostFrameCallback((_) => _onInputChanged(_inputCtl.text));
      }
    }
    if (!identical(app.channels, _seen)) {
      _seen = app.channels;
      if (app.channels.isEmpty) {
        list = [];
        playingId = null;
        player.stop();
      } else {
        _setCategory(0);
        Channel? last;
        for (final c in app.channels) {
          if (c.id == app.lastChannelId) last = c;
        }
        last ??= app.channels.first;
        if (app.opt('start', 'last') == 'last') {
          final ch = last;
          if (introDone.value) {
            _tune(ch);
          } else {
            // wait until the intro has finished before the channel (and its sound) starts
            void go() {
              introDone.removeListener(go);
              if (mounted && playingId == null) _tune(ch);
            }
            introDone.addListener(go);
          }
        }
        final i = list.indexOf(last);
        if (i >= 0) {
          row = i;
          top = i - 2;
          _fixTop();
        }
      }
    }
    setState(() {});
  }

  void _onPlayError(String e) {
    if (playingId == null || !mounted) return;
    if (!_triedAlt && app.opt('fmt', 'auto') == 'auto') {
      _triedAlt = true;
      _open(alt: true);
      return;
    }
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (!mounted || playingId == null || paused) return;
    if (app.opt('reconnect', 'on') != 'on' || _retries >= 5) {
      setState(() => playError = 'This channel isn\'t playing right now');
      return;
    }
    _retries++;
    setState(() => playError = 'Reconnecting… ($_retries of 5)');
    _retryTimer?.cancel();
    _retryTimer = Timer(Duration(seconds: 2 * _retries), () {
      if (mounted && playingId != null) _open();
    });
  }

  /// Sends the playback settings to the video engine (mpv).
  Future<void> _applyPlayerProps() async {
    final pl = player.platform;
    if (pl == null) return;
    final d = pl as dynamic;
    final ahead = app.opt('ahead', '30');
    final props = <String, String>{
      'cache': 'yes',
      'cache-secs': ahead,
      'demuxer-readahead-secs': ahead,
      'network-timeout': app.opt('timeout', '20'),
      'deinterlace': app.opt('deint', 'no'),
      'alang': app.opt('alang', 'eng,en'),
      'slang': app.opt('alang', 'eng,en'),
      'sid': app.opt('subs', 'no') == 'auto' ? 'auto' : 'no',
      'user-agent': app.opt('ua', 'tame') == 'vlc' ? 'VLC/3.0.20 LibVLC/3.0.20' : 'TamePlayer/0.1',
    };
    for (final e in props.entries) {
      try {
        await d.setProperty(e.key, e.value);
      } catch (_) {}
    }
  }

  // ---------------------------------------------------------------- helpers

  List<ChannelGroup> get allCats => [
        const ChannelGroup('__all', 'All Channels'),
        const ChannelGroup('__fav', 'Favorites'),
        const ChannelGroup('__recent', 'Recently watched'),
        ...app.visibleCats,
      ];

  bool get _isFull =>
      area == Area.full ||
      area == Area.side ||
      ((area == Area.settings || area == Area.input) && _panelFrom == Area.full) ||
      (area == Area.dialog && _dlgFrom == Area.full);

  Channel? get cur => (row >= 0 && row < list.length) ? list[row] : null;
  Channel? get playing => playingId == null ? null : app.byId[playingId];

  String fmt(DateTime t) {
    final m = t.minute.toString().padLeft(2, '0');
    if (app.use24) return '${t.hour.toString().padLeft(2, '0')}:$m';
    final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
    return '$h:$m ${t.hour < 12 ? 'AM' : 'PM'}';
  }

  String dur(Duration d) {
    final m = d.inMinutes, h = m ~/ 60;
    return h > 0 ? '${h}h ${m % 60}m' : '${m}m';
  }

  int minsLeft(Program p, DateTime now) {
    final s = p.end.difference(now).inSeconds;
    return s <= 0 ? 0 : (s / 60).ceil();
  }

  double progress(Program p, DateTime now) {
    final total = p.end.difference(p.start).inSeconds;
    if (total <= 0 || !p.isLiveAt(now)) return 0;
    return now.difference(p.start).inSeconds / total;
  }

  void _fixTop() {
    if (row < top) top = row;
    if (row >= top + rows) top = row - rows + 1;
    final maxTop = list.length - rows;
    top = clampI(top, 0, maxTop < 0 ? 0 : maxTop);
  }

  void _setCategory(int i) {
    final cats = allCats;
    catIdx = clampI(i, 0, cats.length - 1);
    _catId = cats[catIdx].id;
    list = app.listFor(cats[catIdx]);
    final p = list.indexWhere((c) => c.id == playingId);
    row = p >= 0 ? p : 0;
    top = row - 2;
    _fixTop();
    cursor = DateTime.now();
    win = floor30(cursor);
  }

  void _ensureVis() {
    final minT = floor30(DateTime.now());
    final we = win.add(Duration(minutes: winMin));
    if (!cursor.isBefore(we.subtract(const Duration(minutes: 30)))) {
      win = floor30(cursor).subtract(const Duration(minutes: 30));
    }
    if (cursor.isBefore(win)) win = floor30(cursor);
    if (win.isBefore(minT)) win = minT;
  }

  void _toast(String m) {
    if (area == Area.full && RegExp(r'^(▶|●)').hasMatch(m)) return; // the info bar already says it
    setState(() => toast = m);
    _toastTimer?.cancel();
    _toastTimer = Timer(const Duration(milliseconds: 1900), () {
      if (mounted) setState(() => toast = null);
    });
  }

  // ---------------------------------------------------------------- playback

  void _tune(Channel ch) {
    if (app.isLocked(ch) && !_unlocked) {
      _askPin(() => _tune(ch));
      return;
    }
    _retries = 0;
    _retryTimer?.cancel();
    if (playingId != null && playingId != ch.id) _prevId = playingId;
    setState(() {
      playingId = ch.id;
      playError = null;
      hasVideo = false;
      buffering = true;
      paused = false;
      _triedAlt = false;
    });
    app.setLast(ch.id);
    _open();
  }

  void _open({bool alt = false}) {
    final ch = playing;
    final c = app.client;
    if (ch == null || c == null) return;
    final fmt = app.opt('fmt', 'auto');
    final ext = fmt == 'hls' ? 'm3u8' : (fmt == 'ts' ? 'ts' : (alt ? 'm3u8' : 'ts'));
    player.open(Media(c.liveUrl(ch.id, ext: ext)));
  }

  void _togglePause() {
    if (playingId == null) return;
    player.playOrPause();
    setState(() => paused = !paused);
    if (area == Area.full) _showOsd();
  }

  void _goFull() {
    if (playingId == null) return;
    setState(() {
      area = Area.full;
      toast = null;
    });
    _showOsd();
  }

  void _exitFull() {
    setState(() {
      area = Area.guide;
      osd = false;
      final i = list.indexWhere((c) => c.id == playingId);
      if (i >= 0) {
        row = i;
        cursor = DateTime.now();
        win = floor30(cursor);
        _fixTop();
      }
    });
  }

  void _showOsd() {
    setState(() => osd = true);
    _osdTimer?.cancel();
    _osdTimer = Timer(Duration(seconds: int.tryParse(app.opt('osd', '5')) ?? 5), () {
      if (mounted && !paused) setState(() => osd = false);
    });
  }

  void _toggleFav(Channel? ch) {
    if (ch == null) return;
    final adding = !app.favs.contains(ch.id);
    app.toggleFav(ch.id);
    _toast(adding ? '♥ Added to Favorites' : '♡ Removed from Favorites');
    if (allCats[catIdx].id == '__fav') {
      final id = cur?.id;
      list = app.listFor(allCats[catIdx]);
      row = clampI(list.indexWhere((c) => c.id == id), 0, list.isEmpty ? 0 : list.length - 1);
      _fixTop();
    }
  }

  void _quit() {
    player.stop();
    if (Platform.isAndroid || Platform.isIOS) {
      SystemNavigator.pop();
    } else {
      exit(0);
    }
  }

  Future<void> _checkUpdate({required bool manual}) async {
    final u = await checkForUpdate();
    if (!mounted) return;
    setState(() => _upd = u);
    if (u != null) {
      _toast('★ Update available: open Settings to install');
    } else if (manual) {
      _toast(kBuild == 0 ? 'This copy can\'t check for updates' : 'You have the newest version');
    }
  }

  void _startUpdate() {
    final u = _upd;
    if (u == null || _updProg != null) return;
    setState(() => _updProg = 0);
    installWindowsUpdate(u, (p) {
      if (!mounted) return;
      setState(() => _updProg = p);
      if (p >= 1) _toast('Installing the update. Tame Player will reopen in a few seconds');
    }).catchError((Object e) {
      if (!mounted) return;
      setState(() => _updProg = null);
      _toast('The update didn\'t finish. Try again later.');
    });
  }

  void _openVod(bool series) {
    final wasPlaying = playingId != null && !paused;
    if (wasPlaying) player.pause();
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => VodScreen(app: app, series: series))).then((_) {
      if (!mounted) return;
      if (wasPlaying) player.play();
      _focus.requestFocus();
    });
  }

  void _addAccount() {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => LoginScreen(app: app, addMode: true)))
        .then((_) => _focus.requestFocus());
  }

  // ---------------------------------------------------------------- menus

  List<_MenuItem> get _menuItems {
    final cats = allCats;
    return [
      _MenuItem('movies', 'Movies', icon: Icons.movie_creation_rounded),
      _MenuItem('series', 'TV Shows', icon: Icons.video_library_rounded),
      for (var i = 0; i < cats.length; i++) _MenuItem('cat', cats[i].name, cat: i, count: app.countFor(cats[i])),
      _MenuItem('search', 'Search', icon: Icons.search_rounded),
      _MenuItem('settings', 'Settings', icon: Icons.settings_rounded),
      _MenuItem('add', 'Add a subscription', icon: Icons.add_circle_outline_rounded),
    ];
  }

  void _cycle(String key, String def, List<String> opts, int d) {
    final i = opts.indexOf(app.opt(key, def));
    final n = opts[((i < 0 ? 0 : i) + (d < 0 ? opts.length - 1 : 1)) % opts.length];
    app.setOpt(key, n);
  }

  _SetItem _choice(String label, String key, String def, Map<String, String> opts, {String note = '', bool engine = false}) {
    final v = opts[app.opt(key, def)] ?? opts.values.first;
    return _SetItem(label, note.isEmpty ? v : '$v  ($note)', (d) {
      _cycle(key, def, opts.keys.toList(), d);
      if (engine) _applyPlayerProps();
    });
  }

  String _trackName(dynamic t, int n) {
    final title = (t.title as String?)?.trim();
    final lang = (t.language as String?)?.trim();
    if (title != null && title.isNotEmpty) return lang != null && lang.isNotEmpty ? '$title ($lang)' : title;
    if (lang != null && lang.isNotEmpty) return lang.toUpperCase();
    return 'Track $n';
  }

  List<_SetItem> _pageItems() {
    final ch = _optCh;
    switch (setPage) {
      case 'show':
        {
          final p = _optProg;
          if (ch == null || p == null) return [_SetItem.header('Show')];
          final now = DateTime.now();
          final live = app.progAt(ch, now);
          final has = app.hasReminder(ch, p);
          return [
            _SetItem.header(p.start.isAfter(now) ? 'Coming up' : 'On now'),
            _SetItem.note('${p.title}\n${_dayName(p.start)} ${fmt(p.start)} – ${fmt(p.end)}  ·  ${ch.num} ${app.nameOf(ch)}'),
            if (p.desc.isNotEmpty) _SetItem.note(p.desc),
            _SetItem(has ? 'Cancel the reminder' : 'Remind me when it starts', has ? '⏰ set' : 'Starts in ${dur(p.start.difference(now))}',
                (d) {
              app.toggleReminder(ch, p);
              _closeSettings();
              _toast(has ? 'Reminder cancelled' : '★ I\'ll remind you at ${fmt(p.start)}');
            }, button: true),
            _SetItem('Watch this channel now', live.placeholder ? '' : 'On now: ${live.title}', (d) {
              _closeSettings();
              _tune(ch);
            }, button: true),
            _SetItem('Channel options', '›', (d) => setState(() {
                  setPage = 'channel';
                  setIdx = 1;
                }), button: true),
          ];
        }
      case 'channel':
        if (ch == null) return [_SetItem.header('Channel')];
        final fav = app.favs.contains(ch.id);
        final pin = app.opt('pin', '').isNotEmpty;
        final locked = app.lockedGroups.contains(ch.catId);
        return [
          _SetItem.header('${ch.num} · ${app.nameOf(ch)}'),
          _SetItem('Watch now', '', (d) {
            _closeSettings();
            _tune(ch);
          }, button: true),
          _SetItem(fav ? 'Remove from Favorites' : 'Add to Favorites', fav ? '♥' : '♡', (d) => _toggleFav(ch), button: true),
          _SetItem('Rename this channel', app.renames.containsKey(ch.id) ? 'renamed' : '', (d) {
            setState(() => area = Area.guide);
            _openInput('rename', initial: app.nameOf(ch));
          }, button: true),
          _SetItem('Hide this channel', 'Settings › Hidden channels to undo', (d) {
            app.toggleHiddenCh(ch.id);
            _closeSettings();
            _toast('Channel hidden');
          }, button: true),
          _SetItem(locked ? 'Unlock this channel\'s group' : 'Lock this channel\'s group', pin ? '' : 'set a PIN first', (d) {
            if (!pin) {
              _closeSettings();
              _openInput('setpin');
              return;
            }
            void doIt() => app.toggleLock(ch.catId);
            if (_unlocked) {
              doIt();
            } else {
              _askPin(doIt);
            }
          }, button: true),
        ];
      case 'player':
        {
          final tracks = player.state.tracks;
          final audio = tracks.audio.where((t) => t.id != 'auto' && t.id != 'no').toList();
          final subs = tracks.subtitle.where((t) => t.id != 'auto' && t.id != 'no').toList();
          final curA = player.state.track.audio;
          final curS = player.state.track.subtitle;
          final ai = audio.indexWhere((t) => t.id == curA.id);
          final si = subs.indexWhere((t) => t.id == curS.id);
          return [
            _SetItem.header(ch == null ? 'Player' : 'Now playing · ${app.nameOf(ch)}'),
            _SetItem('Audio', audio.isEmpty ? 'Default' : (ai < 0 ? 'Automatic' : _trackName(audio[ai], ai + 1)), (d) {
              if (audio.isEmpty) return;
              final n = ((ai < 0 ? 0 : ai) + (d < 0 ? audio.length - 1 : 1)) % audio.length;
              player.setAudioTrack(audio[n]);
              setState(() {});
            }),
            _SetItem('Subtitles', si < 0 ? 'Off' : _trackName(subs[si], si + 1), (d) {
              if (subs.isEmpty) return _toast('No subtitles on this channel');
              final n = si + (d < 0 ? -1 : 1); // -1 = off
              if (n < 0 || n >= subs.length) {
                player.setSubtitleTrack(SubtitleTrack.no());
              } else {
                player.setSubtitleTrack(subs[n]);
              }
              setState(() {});
            }),
            _choice('Picture', 'fsfit', 'fit', const {'fit': 'Fit', 'fill': 'Zoom', 'stretch': 'Stretch'}),
            if (ch != null)
              _SetItem(app.favs.contains(ch.id) ? 'Remove from Favorites' : 'Add to Favorites', '', (d) => _toggleFav(ch), button: true),
            if (ch != null)
              _SetItem('Channel options', '›', (d) => setState(() {
                    setPage = 'channel';
                    setIdx = 1;
                  }), button: true),
            _SetItem('Reconnect this channel', '', (d) {
              _closeSettings();
              _retries = 0;
              _open();
            }, button: true),
          ];
        }
      case 'reminders':
        return [
          _SetItem.header(app.reminders.isEmpty ? 'No reminders set' : 'OK to cancel a reminder'),
          for (var i = 0; i < app.reminders.length; i++)
            _SetItem(
              '${app.reminders[i]['title']}',
              () {
                final t = DateTime.fromMillisecondsSinceEpoch(app.reminders[i]['start'] as int);
                final c = app.byId[app.reminders[i]['ch']];
                return '${_dayName(t)} ${fmt(t)}${c == null ? '' : ' · ${app.nameOf(c)}'}';
              }(),
              (d) {
                app.removeReminderAt(i);
                _toast('Reminder cancelled');
              },
              button: true,
            ),
        ];
      case 'hiddench':
        {
          final hidden = [for (final id in app.hiddenCh) if (app.byId[id] != null) app.byId[id]!];
          return [
            _SetItem.header(hidden.isEmpty ? 'No hidden channels' : 'OK to show a channel again'),
            for (final c in hidden) _SetItem('${c.num} · ${app.nameOf(c)}', 'Hidden', (d) => app.toggleHiddenCh(c.id), button: true),
          ];
        }
      case 'locks':
        return [
          _SetItem.header('Locked groups need the PIN to watch'),
          for (final c in app.cats)
            _SetItem(c.name, app.lockedGroups.contains(c.id) ? '🔒 Locked' : 'Open', (d) => app.toggleLock(c.id), button: true),
        ];
    }
    return [];
  }

  List<_SetItem> get _settings {
    if (setPage != 'main' && setPage != 'groups') return _pageItems();
    if (setPage == 'groups') {
      return [
        _SetItem.header('Show or hide groups  ·  hidden groups also leave All Channels'),
        for (final c in app.cats)
          _SetItem(c.name, app.hiddenGroups.contains(c.id) ? 'Hidden' : 'Shown', (d) => app.toggleHidden(c.id)),
      ];
    }
    const fxs = ['subtle', 'full', 'off'];
    const fxNames = {'subtle': 'Subtle', 'full': 'Full', 'off': 'Off'};
    final info = app.info;
    final sh = app.shiftHours;
    final exp = info?.expires;
    return [
      _SetItem.header('General'),
      _choice('When the app opens', 'start', 'last', const {'last': 'Last channel', 'guide': 'Guide only'}),
      _SetItem('Intro sound', const {'streaming': 'Streaming', 'off': 'Off'}[app.opt('introsound', 'cinematic')] ?? 'Cinematic', (d) {
        _cycle('introsound', 'cinematic', const ['cinematic', 'streaming', 'off'], d);
        final w = app.opt('introsound', 'cinematic');
        if (w != 'off') {
          final p = Player();
          p.open(Media('asset:///assets/intro_$w.wav'));
          Future.delayed(const Duration(seconds: 4), p.dispose);
        }
      }),
      _SetItem('Time format', app.use24 ? '24-hour' : '12-hour', (d) => app.setUse24(!app.use24)),
      _SetItem.header('Appearance'),
      _SetItem('Focus effect', fxNames[app.fx] ?? 'Subtle', (d) => app.setFx(fxs[(fxs.indexOf(app.fx) + (d < 0 ? 2 : 1)) % 3])),
      _choice('Channel numbers', 'nums', 'on', const {'on': 'Shown', 'off': 'Hidden'}),
      _choice('Channel logos', 'logos', 'on', const {'on': 'Shown', 'off': 'Hidden'}),
      _choice('Preview picture', 'pvfit', 'fill', const {'fill': 'Fill', 'fit': 'Fit'}),
      _SetItem.header('TV guide'),
      _SetItem('Guide time shift', sh == 0 ? 'None' : '${sh > 0 ? '+' : ''}$sh h', (d) {
        final n = clampI(sh + (d < 0 ? -1 : 1), -12, 12);
        app.setOpt('shift', '$n');
      }),
      _SetItem('Show or hide groups', '${app.hiddenGroups.length} hidden  ›', (d) {
        setState(() {
          setPage = 'groups';
          setIdx = 1;
        });
      }, button: true),
      _choice('Guide shows', 'days', '1', const {'1': '1 day', '2': '2 days', '3': '3 days'}),
      _SetItem('Reload the TV guide', '', (d) {
        app.refreshGuide();
        _toast('TV guide reloading');
      }, button: true),
      _SetItem.header('Channels'),
      _SetItem('Hidden channels', '${app.hiddenCh.length} hidden  ›', (d) => setState(() {
            setPage = 'hiddench';
            setIdx = 1;
          }), button: true),
      _SetItem.note('Tip: hold OK (or right-click) on a channel to favorite, rename, hide or lock it.'),
      _SetItem.header('Player'),
      _choice('Buffer ahead', 'ahead', '30',
          const {'10': '10 sec', '30': '30 sec', '60': '60 sec', '120': '2 min'},
          engine: true),
      _choice('Auto-reconnect', 'reconnect', 'on', const {'on': 'On', 'off': 'Off'}),
      _choice('Slow-server timeout', 'timeout', '20', const {'10': '10 sec', '20': '20 sec', '40': '40 sec'}, engine: true),
      _choice('Stream format', 'fmt', 'auto', const {'auto': 'Auto', 'ts': 'TS', 'hls': 'HLS'}),
      _choice('Full-screen picture', 'fsfit', 'fit', const {'fit': 'Fit', 'fill': 'Fill (zoom)', 'stretch': 'Stretch'}),
      _choice('Info bar stays for', 'osd', '5', const {'3': '3 sec', '5': '5 sec', '8': '8 sec', '15': '15 sec'}),
      _choice('Buffer size', 'buf', 'normal', const {'normal': 'Normal', 'large': 'Large', 'xl': 'Extra large'}, note: 'restart'),
      _choice('Hardware decoding', 'hw', 'on', const {'on': 'On', 'off': 'Off'}, note: 'after restart'),
      _choice('Deinterlace', 'deint', 'no', const {'no': 'Off', 'yes': 'On'}, engine: true),
      _choice('Audio language', 'alang', 'eng,en',
          const {'eng,en': 'English', 'spa,es': 'Spanish', 'fre,fra,fr': 'French', 'por,pt': 'Portuguese', '': 'Default'},
          engine: true),
      _choice('Subtitles', 'subs', 'no', const {'no': 'Off', 'auto': 'On'}, engine: true),
      _choice('Identify as', 'ua', 'tame', const {'tame': 'Tame Player', 'vlc': 'VLC'}, engine: true),
      _SetItem.note('Tip: while watching, press ☰ / M (or hold OK) for audio, subtitles and picture.'),
      _SetItem.header('Subscriptions'),
      for (var i = 0; i < app.accounts.length; i++)
        _SetItem(
          i == app.active ? '● ${app.accounts[i].name}' : app.accounts[i].name,
          i == app.active
              ? (info != null && info.maxConnections > 0 ? '${info.activeConnections}/${info.maxConnections} screens' : 'Active')
              : 'Switch to this',
          (d) {
            if (i != app.active) {
              _closeSettings();
              app.openAccount(i);
            }
          },
          button: true,
        ),
      _SetItem('Add a subscription', '', (d) {
        _closeSettings();
        _addAccount();
      }, button: true),
      _SetItem('Reload channels', '', (d) {
        _closeSettings();
        app.openAccount(app.active);
      }, button: true),
      _SetItem('Sign out of ${app.acc?.name ?? ''}', '', (d) {
        _closeSettings();
        player.stop();
        app.removeActive();
      }, button: true),
      _SetItem.header('Parental control'),
      _SetItem(app.opt('pin', '').isEmpty ? 'Set a 4-digit PIN' : 'Change the PIN', '', (d) {
        void go() {
          setState(() => area = Area.guide);
          _openInput('setpin');
        }
        if (app.opt('pin', '').isEmpty || _unlocked) {
          go();
        } else {
          _askPin(go);
        }
      }, button: true),
      if (app.opt('pin', '').isNotEmpty)
        _SetItem('Locked groups', '${app.lockedGroups.length} locked  ›', (d) {
          void go() => setState(() {
                area = Area.settings;
                setPage = 'locks';
                setIdx = 1;
              });
          if (_unlocked) {
            go();
          } else {
            _askPin(go);
          }
        }, button: true),
      if (app.opt('pin', '').isNotEmpty)
        _SetItem('Remove the PIN', '', (d) {
          void go() {
            app.setOpt('pin', '');
            _toast('PIN removed');
          }
          if (_unlocked) {
            go();
          } else {
            _askPin(go);
          }
        }, button: true),
      _SetItem.header('Reminders'),
      _choice('Remind me', 'remindlead', '1',
          const {'1': 'At start', '2': '2 min early', '5': '5 min early', '10': '10 min early'}),
      _SetItem('Upcoming reminders', '${app.reminders.length}  ›', (d) => setState(() {
            setPage = 'reminders';
            setIdx = 1;
          }), button: true),
      _SetItem('Clear recently watched', '${app.recent.length} channels', (d) {
        app.clearRecent();
        _toast('Recently watched cleared');
      }, button: true),
      _SetItem.header('Favorites'),
      _SetItem('Clear favorites', '${app.favs.length} saved', (d) {
        app.clearFavs();
        _toast('Favorites cleared');
      }, button: true),
      _SetItem.header('About'),
      if (_upd != null)
        _SetItem(
          canInstallUpdates ? 'Install the update (build ${_upd!.build})' : 'Update available (build ${_upd!.build})',
          _updProg != null
              ? (_updProg! >= 1 ? 'Installing… reopening' : 'Downloading ${(100 * _updProg!).round()}%')
              : (canInstallUpdates ? 'The app restarts by itself' : 'Install the new TamePlayer.apk'),
          canInstallUpdates ? (d) => _startUpdate() : null,
          button: true,
        ),
      _SetItem('Check for updates', '', (d) => _checkUpdate(manual: true), button: true),
      _SetItem('Tame Player 0.1 · build $kBuild', exp == null ? '' : 'Subscription ends ${exp.month}/${exp.day}/${exp.year}', null,
          button: true),
    ];
  }

  void _openMenu() => setState(() {
        area = Area.menu;
        menuIdx = catIdx + 2; // Movies and TV Shows sit above the groups
        _scrollMenu();
      });

  void _closeMenu() => setState(() => area = Area.guide);

  void _scrollMenu() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_menuScroll.hasClients) return;
      final target = (menuIdx * 48.0 - 220).clamp(0.0, _menuScroll.position.maxScrollExtent).toDouble();
      _menuScroll.animateTo(target, duration: const Duration(milliseconds: 150), curve: Curves.easeOut);
    });
  }

  void _openSettings() => setState(() {
        _panelFrom = Area.guide;
        area = Area.settings;
        setPage = 'main';
        setIdx = 1;
      });

  void _openPanel(String page, {Channel? ch}) => setState(() {
        _panelFrom = area == Area.full ? Area.full : Area.guide;
        _optCh = ch;
        area = Area.settings;
        setPage = page;
        final items = _settings;
        final first = items.indexWhere((x) => !x.header);
        setIdx = first < 0 ? 0 : first;
      });

  // ---------------------------------------------------------------- search / rename / PIN

  void _openInput(String mode, {String initial = ''}) {
    if (mode == 'search') app.loadFullGuide();
    setState(() {
      if (area != Area.input) _panelFrom = area == Area.full ? Area.full : Area.guide;
      area = Area.input;
      _inputMode = mode;
      _inputCtl.text = initial;
      _results = [];
      resIdx = 0;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _inputFocus.requestFocus());
  }

  void _closeInput() {
    _inputFocus.unfocus();
    setState(() => area = _panelFrom == Area.full && playingId != null ? Area.full : Area.guide);
    _panelFrom = Area.guide;
    _focus.requestFocus();
  }

  void _askPin(VoidCallback then) {
    _afterPin = then;
    _openInput('pin');
  }

  KeyEventResult _onInputKey(FocusNode n, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.arrowDown || k == LogicalKeyboardKey.arrowUp) {
      if (_results.isNotEmpty) {
        setState(() => resIdx = (resIdx + (k == LogicalKeyboardKey.arrowUp ? -1 : 1) + _results.length) % _results.length);
        _scrollSettings();
      }
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.escape || k == LogicalKeyboardKey.goBack || k == LogicalKeyboardKey.browserBack) {
      _closeInput();
      return KeyEventResult.handled;
    }
    if (_isOkKey(k)) {
      _submitInput();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _onInputChanged(String q) {
    if (_inputMode != 'search') return;
    final t = q.trim().toLowerCase();
    final out = <_Result>[];
    if (t.length >= 2) {
      for (final c in app.channels) {
        if (app.hiddenCh.contains(c.id) || app.hiddenGroups.contains(c.catId)) continue;
        if (app.nameOf(c).toLowerCase().contains(t)) out.add(_Result(c, null, app.nameOf(c), 'Channel ${c.num}'));
        if (out.length >= 40) break;
      }
      final now = DateTime.now();
      final shows = <_Result>[];
      app.searchableGuide.forEach((id, progs) {
        final c = app.byId[id];
        if (c == null || app.hiddenCh.contains(id)) return;
        for (final p in progs) {
          if (p.placeholder || !p.end.isAfter(now)) continue;
          if (p.title.toLowerCase().contains(t)) {
            final when = p.isLiveAt(now) ? 'On now' : '${_dayName(p.start)} ${fmt(p.start)}';
            shows.add(_Result(c, p, p.title, '$when · ${app.nameOf(c)}'));
          }
        }
      });
      shows.sort((a, b) => a.p!.start.compareTo(b.p!.start));
      out.addAll(shows.take(60));
    }
    setState(() {
      _results = out;
      resIdx = 0;
    });
  }

  String _dayName(DateTime t) {
    final n = DateTime.now();
    if (t.year == n.year && t.month == n.month && t.day == n.day) return 'Today';
    final tm = n.add(const Duration(days: 1));
    if (t.year == tm.year && t.month == tm.month && t.day == tm.day) return 'Tomorrow';
    const d = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return d[t.weekday - 1];
  }

  void _submitInput() {
    final text = _inputCtl.text.trim();
    switch (_inputMode) {
      case 'search':
        if (_results.isNotEmpty) _openResult(_results[clampI(resIdx, 0, _results.length - 1)]);
      case 'rename':
        {
          final ch = _optCh;
          if (ch != null) app.rename(ch.id, text);
          _closeInput();
          _toast(text.isEmpty ? 'Original name restored' : 'Renamed');
        }
      case 'pin':
        if (text == app.opt('pin', '')) {
          _unlocked = true;
          final then = _afterPin;
          _afterPin = null;
          _closeInput();
          then?.call();
        } else {
          _inputCtl.clear();
          _toast('Wrong PIN');
        }
      case 'setpin':
        if (RegExp(r'^\d{4}$').hasMatch(text)) {
          app.setOpt('pin', text);
          _unlocked = true;
          _closeInput();
          _toast('★ PIN saved');
        } else {
          _toast('The PIN needs 4 numbers');
        }
    }
  }

  void _openResult(_Result r) {
    _closeInput();
    // show it in All Channels so it's always in the list
    _setCategory(0);
    final i = list.indexWhere((c) => c.id == r.ch.id);
    final now = DateTime.now();
    setState(() {
      if (i >= 0) {
        row = i;
        top = i - 2;
        _fixTop();
      }
      final p = r.p;
      if (p != null && p.start.isAfter(now)) {
        cursor = p.start;
        _ensureVis();
      } else {
        cursor = now;
      }
    });
    final p = r.p;
    if (p == null || !p.start.isAfter(now)) _tune(r.ch);
  }

  void _closeSettings() => setState(() {
        if (_panelFrom == Area.full && playingId != null) {
          area = Area.full;
          setPage = 'main';
          _panelFrom = Area.guide;
          return;
        }
        area = Area.guide;
        setPage = 'main';
        // groups may have been hidden: stay on the same group if it still exists
        final keepRow = row;
        final i = allCats.indexWhere((c) => c.id == _catId);
        _setCategory(i < 0 ? 0 : i);
        if (i >= 0 && keepRow < list.length) {
          row = keepRow;
          _fixTop();
        }
      });

  void _scrollSettings() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _setFocusKey.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(ctx, alignment: 0.5, duration: const Duration(milliseconds: 150));
      }
    });
  }

  // ---------------------------------------------------------------- input

  bool _isOkKey(LogicalKeyboardKey k) =>
      k == LogicalKeyboardKey.select ||
      k == LogicalKeyboardKey.enter ||
      k == LogicalKeyboardKey.numpadEnter ||
      k == LogicalKeyboardKey.gameButtonA;

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (area == Area.input) return KeyEventResult.ignored; // the text box handles its own keys
    final k = e.logicalKey;
    // OK: a short press acts on release; holding it opens the options (like TiviMate)
    if (_isOkKey(k)) {
      if (e is KeyDownEvent) {
        _okDown = DateTime.now();
        _longFired = false;
      } else if (e is KeyRepeatEvent) {
        if (!_longFired && _okDown != null && DateTime.now().difference(_okDown!).inMilliseconds > 550) {
          _longFired = true;
          _act('long');
        }
      } else if (e is KeyUpEvent) {
        if (!_longFired && _okDown != null) _act('ok');
        _okDown = null;
      }
      return KeyEventResult.handled;
    }
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
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
      return KeyEventResult.handled; // only arrows repeat
    } else if (k == LogicalKeyboardKey.space) {
      a = 'ok';
    } else if (k == LogicalKeyboardKey.keyS || k == LogicalKeyboardKey.slash || k == LogicalKeyboardKey.find) {
      a = 'search';
    } else if (k == LogicalKeyboardKey.keyO) {
      a = 'long';
    } else if (k == LogicalKeyboardKey.escape ||
        k == LogicalKeyboardKey.goBack ||
        k == LogicalKeyboardKey.browserBack ||
        k == LogicalKeyboardKey.backspace ||
        k == LogicalKeyboardKey.gameButtonB) {
      a = 'back';
    } else if (k == LogicalKeyboardKey.contextMenu || k == LogicalKeyboardKey.keyM || k == LogicalKeyboardKey.info) {
      a = 'menu';
    } else if (k == LogicalKeyboardKey.keyF) {
      a = 'fav';
    } else if (k == LogicalKeyboardKey.mediaRewind || k == LogicalKeyboardKey.comma) {
      a = 'rw';
    } else if (k == LogicalKeyboardKey.mediaFastForward || k == LogicalKeyboardKey.period) {
      a = 'ff';
    } else if (k == LogicalKeyboardKey.pageUp || k == LogicalKeyboardKey.channelUp) {
      a = 'pgup';
    } else if (k == LogicalKeyboardKey.pageDown || k == LogicalKeyboardKey.channelDown) {
      a = 'pgdn';
    } else if (k == LogicalKeyboardKey.mediaPlayPause ||
        k == LogicalKeyboardKey.mediaPlay ||
        k == LogicalKeyboardKey.mediaPause ||
        k == LogicalKeyboardKey.keyP) {
      a = 'pp';
    }
    if (a == null) return KeyEventResult.ignored;
    _act(a);
    return KeyEventResult.handled;
  }

  void _act(String a) {
    if (a == 'back') {
      final now = DateTime.now();
      if (now.difference(_lastBack).inMilliseconds < 250) return; // same press reported twice
      _lastBack = now;
    }

    // Not loaded yet / couldn't load
    if (list.isEmpty && area == Area.guide && (app.loading || app.error != null)) {
      if (a == 'ok' && app.error != null) app.openAccount(app.active);
      if (a == 'menu' || a == 'left') _openSettings();
      if (a == 'back') _backOrExit();
      return;
    }

    switch (area) {
      case Area.guide:
        _guideAct(a);
      case Area.menu:
        _menuAct(a);
      case Area.full:
        _fullAct(a);
      case Area.settings:
        _settingsAct(a);
      case Area.dialog:
        _dialogAct(a);
      case Area.input:
        if (a == 'back') _closeInput();
      case Area.side:
        _sideAct(a);
    }
  }

  void _backOrExit() {
    final now = DateTime.now();
    if (now.difference(_backAt).inMilliseconds < 2000) {
      _showDialog('Exit Tame Player?', 'Playback will stop.', 'Stay', 'Exit', _quit);
    } else {
      _backAt = now;
      _toast('Press back again to exit');
    }
  }

  void _guideAct(String a) {
    final ch = cur;
    final now = DateTime.now();
    if (cursor.isBefore(now)) cursor = now;
    switch (a) {
      case 'up':
      case 'down':
        if (list.isEmpty) return;
        row = (row + (a == 'up' ? -1 : 1) + list.length) % list.length;
        _fixTop();
      case 'pgup':
      case 'pgdn':
        if (list.isEmpty) return;
        row = clampI(row + (a == 'pgup' ? -rows : rows), 0, list.length - 1);
        _fixTop();
      case 'right':
        {
          if (ch == null) return;
          final p = app.progAt(ch, cursor);
          if (!p.end.isBefore(app.rangeEnd)) return;
          cursor = p.end;
          _ensureVis();
        }
      case 'rw':
      case 'ff':
        if (list.isEmpty) return;
        row = clampI(row + (a == 'rw' ? -rows : rows), 0, list.length - 1);
        _fixTop();
      case 'left':
        {
          if (ch == null) return _openMenu();
          if (win.isAfter(floor30(now).add(const Duration(minutes: 30)))) {
            // far ahead in the guide: one press brings you straight back to now
            cursor = now;
            win = floor30(now);
            break;
          }
          final p = app.progAt(ch, cursor);
          if (!p.start.isAfter(now)) return _openMenu(); // already on the show that's on now
          final pr = app.progAt(ch, p.start.subtract(const Duration(seconds: 1)));
          cursor = pr.start.isAfter(now) ? pr.start : now;
          _ensureVis();
        }
      case 'ok':
        if (ch == null) return;
        {
          final p = app.progAt(ch, cursor);
          if (!p.placeholder && p.start.isAfter(now)) return _openShow(ch, p);
        }
        if (ch.id == playingId) return _goFull();
        _tune(ch);
        _toast('▶ ${app.nameOf(ch)}');
        return;
      case 'menu':
        return _openMenu();
      case 'long':
        if (ch != null) _openPanel('channel', ch: ch);
        return;
      case 'search':
        return _openInput('search');
      case 'fav':
        _toggleFav(ch);
      case 'pp':
        _togglePause();
      case 'back':
        return _backOrExit();
    }
    setState(() {});
  }

  void _menuAct(String a) {
    final items = _menuItems;
    switch (a) {
      case 'up':
      case 'down':
        {
          menuIdx = (menuIdx + (a == 'up' ? -1 : 1) + items.length) % items.length;
          final m = items[menuIdx];
          if (m.kind == 'cat') _setCategory(m.cat); // the guide follows as you scroll
          _scrollMenu();
          setState(() {});
        }
      case 'ok':
        {
          final m = items[clampI(menuIdx, 0, items.length - 1)];
          if (m.kind == 'cat') {
            _setCategory(m.cat);
            _closeMenu();
          } else if (m.kind == 'settings') {
            _openSettings();
          } else if (m.kind == 'search') {
            _closeMenu();
            _openInput('search');
          } else if (m.kind == 'movies' || m.kind == 'series') {
            _closeMenu();
            _openVod(m.kind == 'series');
          } else {
            _closeMenu();
            _addAccount();
          }
        }
      case 'right':
      case 'back':
      case 'menu':
        _closeMenu();
    }
  }

  void _fullAct(String a) {
    switch (a) {
      case 'up':
      case 'down':
      case 'pgup':
      case 'pgdn':
        {
          if (list.isEmpty) return;
          var i = list.indexWhere((c) => c.id == playingId);
          final d = (a == 'up' || a == 'pgup') ? -1 : 1;
          i = (i + d + list.length) % list.length;
          row = i;
          _tune(list[i]);
          _showOsd();
        }
      case 'ok':
        if (osd) {
          setState(() => osd = false);
        } else {
          _showOsd();
        }
      case 'back':
        _exitFull();
      case 'fav':
        _toggleFav(playing);
        _showOsd();
      case 'pp':
        _togglePause();
      case 'menu':
      case 'long':
        _openPanel('player', ch: playing);
      case 'right':
        {
          final prev = _prevId == null ? null : app.byId[_prevId];
          if (prev == null) {
            _toast('No previous channel yet');
            return;
          }
          _tune(prev);
          final i = list.indexWhere((c) => c.id == prev.id);
          if (i >= 0) row = i;
          _showOsd();
        }
      case 'left':
        {
          final i = list.indexWhere((c) => c.id == playingId);
          setState(() {
            sideIdx = i < 0 ? 0 : i;
            area = Area.side;
            osd = false;
          });
        }
      default:
        _showOsd();
    }
  }

  void _sideAct(String a) {
    if (list.isEmpty) {
      setState(() => area = Area.full);
      return;
    }
    switch (a) {
      case 'up':
      case 'down':
        setState(() => sideIdx = (sideIdx + (a == 'up' ? -1 : 1) + list.length) % list.length);
      case 'pgup':
      case 'pgdn':
      case 'rw':
      case 'ff':
        setState(() => sideIdx = clampI(sideIdx + ((a == 'pgup' || a == 'rw') ? -8 : 8), 0, list.length - 1));
      case 'ok':
        {
          final ch = list[clampI(sideIdx, 0, list.length - 1)];
          if (ch.id == playingId) {
            setState(() => area = Area.full);
            _showOsd();
          } else {
            _tune(ch);
            row = sideIdx;
          }
        }
      case 'fav':
        _toggleFav(list[clampI(sideIdx, 0, list.length - 1)]);
      case 'right':
      case 'back':
        setState(() => area = Area.full);
      case 'long':
      case 'menu':
        _openPanel('channel', ch: list[clampI(sideIdx, 0, list.length - 1)]);
    }
  }

  Widget _sideGuide() {
    final now = DateTime.now();
    const rh = 66.0;
    final visible = ((sh - 110) / rh).floor();
    final maxStart = list.length - visible;
    final start = clampI(sideIdx - visible ~/ 2, 0, maxStart < 0 ? 0 : maxStart);
    final cats = allCats;
    return Positioned(
      left: 0,
      top: 0,
      bottom: 0,
      width: 520,
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 1, end: 0),
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
        builder: (context, v, child) => Transform.translate(offset: Offset(-520 * v, 0), child: child),
        child: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(colors: [Color(0xF2152B47), Color(0xE61D3758), Color(0x001D3758)], stops: [0, 0.82, 1]),
          ),
          padding: const EdgeInsets.fromLTRB(0, 24, 40, 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(26, 0, 0, 12),
              child: Text(cats[clampI(catIdx, 0, cats.length - 1)].name.toUpperCase(),
                  style: ts(15, w: FontWeight.w800, c: TP.orange).copyWith(letterSpacing: 1.1)),
            ),
            for (var i = start; i < list.length && i < start + visible; i++)
              SizedBox(
                height: rh,
                child: Builder(builder: (context) {
                  final ch = list[i];
                  final p = app.progAt(ch, now);
                  final f = i == sideIdx;
                  return LiftItem(
                    focused: f,
                    fx: app.fx,
                    padding: const EdgeInsets.fromLTRB(14, 8, 16, 8),
                    onTap: () {
                      setState(() => sideIdx = i);
                      _sideAct('ok');
                    },
                    child: Row(children: [
                      Container(width: 4, height: 40, color: ch.id == playingId ? TP.orange : Colors.transparent),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 44,
                        child: Text('${ch.num}',
                            textAlign: TextAlign.right, style: ts(15, w: FontWeight.w600, c: f ? const Color(0xFF33475C) : TP.dim)),
                      ),
                      const SizedBox(width: 10),
                      ChannelBadge(ch: ch, w: 50, h: 34, fontSize: 12),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
                          Text(app.nameOf(ch),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: ts(17, w: FontWeight.w700, c: f ? const Color(0xFF050B14) : TP.text)),
                          Text(p.title,
                              maxLines: 1, overflow: TextOverflow.ellipsis, style: ts(14, c: f ? const Color(0xFF1B2B3D) : TP.dim2)),
                          const SizedBox(height: 4),
                          progressBar(180, progress(p, now)),
                        ]),
                      ),
                      if (app.favs.contains(ch.id)) const FavHeart(on: true, size: 16),
                    ]),
                  );
                }),
              ),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.only(left: 26),
              child: Text('▲▼ browse · OK watch · ▶ or BACK close · hold OK for options', style: ts(13, c: TP.dim)),
            ),
          ]),
        ),
      ),
    );
  }

  void _settingsAct(String a) {
    final items = _settings;
    if (items.isEmpty) return;
    switch (a) {
      case 'up':
      case 'down':
        {
          final d = a == 'up' ? -1 : 1;
          var i = clampI(setIdx, 0, items.length - 1);
          for (var n = 0; n < items.length; n++) {
            i = (i + d + items.length) % items.length;
            if (!items[i].header) break;
          }
          setState(() => setIdx = i);
          _scrollSettings();
        }
      case 'left':
      case 'right':
      case 'ok':
        {
          final s = items[clampI(setIdx, 0, items.length - 1)];
          if (s.header || s.change == null) return;
          if (s.button && a != 'ok') return;
          s.change!(a == 'left' ? -1 : 1);
          setState(() {});
        }
      case 'back':
      case 'menu':
        if (setPage == 'groups' || setPage == 'hiddench' || setPage == 'locks' || setPage == 'reminders') {
          setState(() {
            setPage = 'main';
            setIdx = 1;
          });
        } else {
          _closeSettings();
        }
    }
  }

  void _showDialog(String title, String sub, String no, String yes, VoidCallback yesAct, {int start = 0}) {
    setState(() {
      _dlgFrom = area == Area.full ? Area.full : Area.guide;
      _dlgTitle = title;
      _dlgSub = sub;
      _dlgNo = no;
      _dlgYes = yes;
      _dlgYesAct = yesAct;
      area = Area.dialog;
      dlgIdx = start;
    });
  }

  void _dialogAct(String a) {
    void close() => setState(() => area = _dlgFrom == Area.full && playingId != null ? Area.full : Area.guide);
    switch (a) {
      case 'left':
      case 'right':
        setState(() => dlgIdx = 1 - dlgIdx);
      case 'ok':
        close();
        if (dlgIdx == 1) _dlgYesAct?.call();
      case 'back':
        close();
    }
  }

  void _checkReminders() {
    if (area != Area.guide && area != Area.full) return;
    final due = app.dueReminders(leadMinutes: int.tryParse(app.opt('remindlead', '1')) ?? 1);
    if (due.isEmpty) return;
    final r = due.first;
    final ch = app.byId[r['ch']];
    if (ch == null) return;
    _showDialog('Starting now: ${r['title']}', 'on ${ch.num} · ${app.nameOf(ch)}', 'Not now', 'Watch', () {
      _tune(ch);
      final i = list.indexWhere((c) => c.id == ch.id);
      if (i >= 0) {
        row = i;
        _fixTop();
      }
      _goFull();
    }, start: 1);
  }

  void _openShow(Channel ch, Program p) {
    _optProg = p;
    _openPanel('show', ch: ch);
  }

  void _tapCell(int r, Program p) {
    if (area == Area.menu) return _closeMenu();
    if (area != Area.guide || r >= list.length) return;
    final focused = r == row ? app.progAt(list[r], cursor) : null;
    if (identical(focused, p)) return _act('ok');
    final now = DateTime.now();
    setState(() {
      row = r;
      cursor = p.start.isAfter(now) ? p.start : now;
    });
  }

  void _tapChannel(int i) {
    if (area == Area.menu) return _closeMenu();
    if (area != Area.guide || i >= list.length) return;
    final ch = list[i];
    setState(() {
      row = i;
      cursor = DateTime.now();
    });
    if (ch.id == playingId) {
      _goFull();
    } else {
      _tune(ch);
    }
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _act('back');
      },
      child: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: Container(
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
              child: FittedBox(fit: BoxFit.fill, child: SizedBox(width: sw, height: sh, child: _stage())),
            );
          }),
        ),
      ),
    );
  }

  Widget _stage() {
    return DefaultTextStyle(
      style: ts(16),
      child: Container(
        decoration: TP.background,
        child: Stack(clipBehavior: Clip.hardEdge, children: [
          _info(),
          _brand(),
          _guide(),
          _hints(),
          _video(),
          _menu(),
          if (area == Area.settings) _settingsPanel(),
          if (area == Area.dialog) _dialog(),
          if (area == Area.input) _inputPanel(),
          if (area == Area.side) _sideGuide(),
          if (list.isEmpty && (app.loading || app.error != null)) _loadingPanel(),
          _toastWidget(),
        ]),
      ),
    );
  }

  Widget _info() {
    final ch = cur ?? playing;
    if (ch == null) return const SizedBox.shrink();
    final now = DateTime.now();
    final p = app.progAt(ch, cur != null ? cursor : now);
    final live = p.isLiveAt(now);
    final nx = app.progAt(ch, p.end);
    final meta = live
        ? '${minsLeft(p, now)}m left'
        : (p.start.isAfter(now) ? 'Starts in ${dur(p.start.difference(now))}' : 'Ended');
    return Positioned(
      left: 504,
      top: 28,
      width: 600,
      height: 252,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 2),
            decoration: BoxDecoration(color: TP.kbd, borderRadius: BorderRadius.circular(6)),
            child: Text('${ch.num}', style: ts(18, w: FontWeight.w700)),
          ),
          const SizedBox(width: 10),
          Flexible(child: Text(app.nameOf(ch), maxLines: 1, overflow: TextOverflow.ellipsis, style: ts(18, c: const Color(0xFFB8C8D8)))),
          if (ch.catchup) Text('  ⟲ Catch-up', style: ts(14, c: const Color(0xFF9FD3FF))),
          if (app.favs.contains(ch.id)) const Padding(padding: EdgeInsets.only(left: 10), child: FavHeart(on: true, size: 20)),
          if (ch.id == playingId) Text('  ▶ Playing', style: ts(14, c: TP.orange)),
        ]),
        const SizedBox(height: 10),
        Text(p.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: ts(34, w: FontWeight.w800)),
        const SizedBox(height: 6),
        Row(children: [
          if (live) _liveBadge(),
          if (live) const SizedBox(width: 10),
          Text('${fmt(p.start)} – ${fmt(p.end)} · $meta', style: ts(17, c: const Color(0xFFC9D2DC))),
        ]),
        if (live) Padding(padding: const EdgeInsets.only(top: 12), child: progressBar(420, progress(p, now))),
        if (!identical(nx, p))
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text.rich(
              TextSpan(children: [
                TextSpan(text: 'NEXT: ', style: ts(17, w: FontWeight.w700, c: TP.red)),
                TextSpan(text: '${fmt(nx.start)} ${nx.title}', style: ts(17, c: const Color(0xFFCFCFCF))),
              ]),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        const SizedBox(height: 10),
        Text(p.desc, maxLines: 3, overflow: TextOverflow.ellipsis, style: ts(16, c: const Color(0xFFAEBCCB), h: 1.45)),
      ]),
    );
  }

  Widget _liveBadge() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: TP.red,
          borderRadius: BorderRadius.circular(6),
          boxShadow: const [BoxShadow(color: Color(0x73E04848), blurRadius: 12, offset: Offset(0, 4))],
        ),
        child: Text('LIVE', style: ts(12, w: FontWeight.w800, c: Colors.white)),
      );

  Widget _brand() {
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final n = DateTime.now();
    return Positioned(
      right: 26,
      top: 22,
      width: 150,
      child: Column(children: [
        Image.asset('assets/logo.png', width: 64),
        const SizedBox(height: 4),
        Text(fmt(n), style: ts(24, w: FontWeight.w700)),
        Text('${days[n.weekday - 1]}, ${months[n.month - 1]} ${n.day}', style: ts(13, c: TP.dim2)),
      ]),
    );
  }

  Widget _guide() {
    final now = DateTime.now();
    final we = win.add(Duration(minutes: winMin));
    final cats = allCats;
    final catName = cats[clampI(catIdx, 0, cats.length - 1)].name;

    final rowW = <Widget>[];
    final nRows = rows;
    Widget? focusedRow;
    for (var i = top; i < list.length && i < top + nRows; i++) {
      final w = Positioned(left: 0, top: (i - top) * kRowH, width: sw, height: kRowH, child: _row(i, now, we));
      if (i == row) {
        focusedRow = w;
      } else {
        rowW.add(w);
      }
    }
    final showNowLine = !now.isBefore(win) && now.isBefore(we);
    if (showNowLine) {
      final x = kChW + now.difference(win).inSeconds / 60 * kPxPerMin - 1;
      rowW.add(Positioned(
        left: x,
        top: 0,
        width: 2,
        height: kRowH * nRows,
        child: IgnorePointer(
          child: Container(
            decoration: const BoxDecoration(
              color: Color(0xFFF0962F),
              boxShadow: [BoxShadow(color: Color(0xFFF0962F), blurRadius: 10)],
            ),
          ),
        ),
      ));
    }
    if (focusedRow != null) rowW.add(focusedRow);
    if (list.isNotEmpty) app.ensureEpg(list.skip(top).take(nRows * 2));

    final showNow = !now.isBefore(win) && now.isBefore(we);
    final nowX = kChW + now.difference(win).inSeconds / 60 * kPxPerMin - 1;

    return Positioned(
      left: 0,
      top: 300,
      width: sw,
      height: sh - 330,
      child: Container(
        decoration: const BoxDecoration(
          color: Color(0x73142A44),
          border: Border(top: BorderSide(color: Color(0x1FC9D2DC))),
        ),
        child: Stack(clipBehavior: Clip.none, children: [
          // header
          Positioned(
            left: 0,
            top: 0,
            width: sw,
            height: 36,
            child: Container(
              decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0x1FC9D2DC)))),
              child: Stack(children: [
                Positioned(
                  left: 0,
                  top: 0,
                  width: kChW,
                  height: 36,
                  child: GestureDetector(
                    onTap: () {
                      if (area == Area.guide) _openMenu();
                    },
                    child: Container(
                      color: Colors.transparent,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(children: [
                        Text('☰', style: ts(20, c: const Color(0xFFC9D2DC))),
                        const SizedBox(width: 10),
                        Flexible(
                          child: Text(catName.toUpperCase(),
                              maxLines: 1, overflow: TextOverflow.ellipsis, style: ts(15, w: FontWeight.w700, c: TP.orange)),
                        ),
                      ]),
                    ),
                  ),
                ),
                for (var i = 0; i <= winMin ~/ 30; i++)
                  Positioned(
                    left: kChW + i * 30 * kPxPerMin,
                    top: 0,
                    width: 30 * kPxPerMin,
                    height: 36,
                    child: Container(
                      padding: const EdgeInsets.only(left: 10),
                      alignment: Alignment.centerLeft,
                      decoration: const BoxDecoration(border: Border(left: BorderSide(color: Color(0x40C9D2DC)))),
                      child: Text(fmt(win.add(Duration(minutes: 30 * i))), style: ts(15, c: const Color(0xFFB8C8D8))),
                    ),
                  ),
              ]),
            ),
          ),
          // rows
          Positioned(
            left: 0,
            top: 36,
            width: sw,
            height: kRowH * nRows,
            child: Listener(
              onPointerSignal: (e) {
                if (e is PointerScrollEvent && area == Area.guide) _act(e.scrollDelta.dy > 0 ? 'down' : 'up');
              },
              child: GestureDetector(
                onVerticalDragEnd: (d) {
                  final v = d.primaryVelocity ?? 0;
                  if (v.abs() < 150 || list.isEmpty || area != Area.guide) return;
                  final steps = clampI((v.abs() / 500).ceil(), 1, nRows);
                  setState(() {
                    row = clampI(row + (v < 0 ? steps : -steps), 0, list.length - 1);
                    _fixTop();
                  });
                },
                onHorizontalDragEnd: (d) {
                  final v = d.primaryVelocity ?? 0;
                  if (v.abs() < 150 || area != Area.guide) return;
                  final minT = floor30(DateTime.now());
                  setState(() {
                    win = win.add(Duration(minutes: v < 0 ? 60 : -60));
                    if (win.isBefore(minT)) win = minT;
                    cursor = win == minT ? DateTime.now() : win;
                  });
                },
                child: Stack(clipBehavior: Clip.none, children: rowW),
              ),
            ),
          ),
          if (showNow)
            Positioned(
              left: nowX - 4,
              top: 32,
              width: 10,
              height: 10,
              child: IgnorePointer(
                child: Container(decoration: const BoxDecoration(color: Color(0xFFF0962F), shape: BoxShape.circle)),
              ),
            ),
          if (list.isEmpty && !app.loading && app.error == null)
            Positioned(
              left: kChW,
              right: 0,
              top: 140,
              child: Text(
                allCats[clampI(catIdx, 0, allCats.length - 1)].id == '__fav'
                    ? 'No favorites yet. Hold OK on a channel (or press F) to add one ♥'
                    : 'No channels in this group.',
                textAlign: TextAlign.center,
                style: ts(18, c: TP.dim2),
              ),
            ),
        ]),
      ),
    );
  }

  Widget _row(int i, DateTime now, DateTime we) {
    final ch = list[i];
    final isCur = i == row;
    final fp = isCur ? app.progAt(ch, cursor) : null;
    final cells = <Widget>[];
    Widget? fcell;
    for (final p in app.epgFor(ch)) {
      if (!p.end.isAfter(win) || !p.start.isBefore(we)) continue;
      final f = identical(fp, p);
      final w = _cell(p, i, f, p.isLiveAt(now), we);
      if (f) {
        fcell = w;
      } else {
        cells.add(w);
      }
    }
    if (fcell != null) cells.add(fcell);
    return Stack(clipBehavior: Clip.none, children: [
      Positioned(left: 0, top: 0, width: kChW, height: kRowH, child: _chCell(ch, i, isCur)),
      Positioned(left: kChW, top: 0, width: sw - kChW, height: kRowH, child: Stack(clipBehavior: Clip.none, children: cells)),
      Positioned(left: 0, right: 0, bottom: 0, height: 1, child: IgnorePointer(child: Container(color: const Color(0x2E000000)))),
    ]);
  }

  Widget _chCell(Channel ch, int i, bool isCur) {
    return GestureDetector(
      onTap: () => _tapChannel(i),
      onSecondaryTap: () => _openPanel('channel', ch: ch),
      onLongPress: () => _openPanel('channel', ch: ch),
      child: Container(
        decoration: BoxDecoration(
          color: isCur ? TP.chCellCur : TP.chCell,
          border: Border(
            left: BorderSide(color: ch.id == playingId ? TP.orange : Colors.transparent, width: 4),
            right: const BorderSide(color: TP.line, width: 2),
          ),
        ),
        padding: const EdgeInsets.only(left: 4, right: 12),
        child: Row(children: [
          if (app.opt('nums', 'on') == 'on') ...[
            SizedBox(
              width: 40,
              child: Text('${ch.num}', textAlign: TextAlign.right, style: ts(15, w: FontWeight.w600, c: const Color(0xFFB3C3D4))),
            ),
            const SizedBox(width: 10),
          ] else
            const SizedBox(width: 10),
          if (app.opt('logos', 'on') == 'on') ...[
            ChannelBadge(ch: ch),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Text(app.nameOf(ch), maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis, style: ts(17, w: FontWeight.w600)),
          ),
          if (ch.catchup) Text(' ⟲', style: ts(14, c: const Color(0xFF9FD3FF))),
          if (app.favs.contains(ch.id)) const Padding(padding: EdgeInsets.only(left: 6), child: FavHeart(on: true, size: 18)),
        ]),
      ),
    );
  }

  Widget _cell(Program p, int r, bool f, bool isNow, DateTime we) {
    final a = p.start.isBefore(win) ? win : p.start;
    final b = p.end.isAfter(we) ? we : p.end;
    final x = a.difference(win).inSeconds / 60 * kPxPerMin;
    final w = b.difference(a).inSeconds / 60 * kPxPerMin;
    final focus = f && area == Area.guide;
    final sel = f && area != Area.guide;
    final fx = app.fx;
    final lift = focus && fx != 'off';
    final radius = BorderRadius.circular(lift ? (fx == 'full' ? 9 : 7) : 0);
    final cut = p.start.isBefore(win);
    return Positioned(
      left: x,
      top: 0,
      width: w,
      height: kRowH,
      child: GestureDetector(
        onTap: () => _tapCell(r, p),
        onSecondaryTap: () {
          if (r < list.length) _openPanel('channel', ch: list[r]);
        },
        onLongPress: () {
          if (r < list.length) _openPanel('channel', ch: list[r]);
        },
        child: AnimatedScale(
          scale: lift ? (fx == 'full' ? 1.06 : 1.03) : 1,
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
          child: Container(
            margin: const EdgeInsets.only(right: 2),
            decoration: BoxDecoration(
              color: focus ? null : (isNow ? TP.cellNow : TP.cell),
              gradient: focus ? TP.silver : null,
              borderRadius: radius,
              border: sel ? Border.all(color: const Color(0xB3E08A2C), width: 2) : null,
              boxShadow: lift
                  ? [BoxShadow(color: const Color(0x80000000), blurRadius: fx == 'full' ? 32 : 14, offset: Offset(0, fx == 'full' ? 16 : 7))]
                  : null,
            ),
            child: ClipRRect(
              borderRadius: radius,
              child: Stack(children: [
                if (lift)
                  const Positioned.fill(
                    child: IgnorePointer(child: DecoratedBox(decoration: BoxDecoration(gradient: TP.sheen))),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 7, 10, 0),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(
                      '${cut ? '‹ ' : ''}${app.hasReminder(list[r], p) ? '⏰ ' : ''}${p.title}',
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                      style: ts(16, w: focus ? FontWeight.w800 : FontWeight.w600, c: focus ? const Color(0xFF050B14) : (p.placeholder ? const Color(0xFF9DB0C4) : TP.text)),
                    ),
                    if (w > 110 && !p.placeholder)
                      Text(
                        '${fmt(p.start)} – ${fmt(p.end)}',
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.clip,
                        style: ts(13, w: focus ? FontWeight.w600 : FontWeight.w400, c: focus ? const Color(0xFF1B2B3D) : TP.dim2),
                      ),
                  ]),
                ),
                if (focus) Positioned(left: 0, top: 0, bottom: 0, width: 5, child: Container(color: TP.orange)),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  Widget _hints() {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      height: 30,
      child: Container(
        color: TP.hintBar,
        padding: const EdgeInsets.symmetric(horizontal: 22),
        child: const FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
          Kbd('◀', 'Groups'),
          SizedBox(width: 26),
          Kbd('▲▼', 'Channels'),
          SizedBox(width: 26),
          Kbd('▶', 'Later shows'),
          SizedBox(width: 26),
          Kbd('OK', 'Watch / Full screen'),
          SizedBox(width: 26),
          Kbd('♥', 'Favorite (F)'),
          SizedBox(width: 26),
          Kbd('☰', 'Menu (M)'),
          SizedBox(width: 26),
          Kbd('S', 'Search'),
          SizedBox(width: 26),
          Kbd('Hold OK', 'Options'),
          SizedBox(width: 26),
          SizedBox(width: 26),
          Kbd('BACK', 'Exit'),
        ]),
        ),
      ),
    );
  }

  Widget _video() {
    final full = _isFull;
    final ch = playing;
    final showStripes = ch != null && (!hasVideo || buffering || playError != null);
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      left: full ? 0 : 28,
      top: full ? 0 : 26,
      width: full ? sw : 448,
      height: full ? sh : 252,
      child: GestureDetector(
        onTap: () {
          if (area == Area.guide) {
            _goFull();
          } else if (area == Area.full) {
            _act('ok');
          } else if (area == Area.menu) {
            _closeMenu();
          }
        },
        child: Container(
          decoration: BoxDecoration(
            color: Colors.black,
            borderRadius: BorderRadius.circular(full ? 0 : 14),
            border: full ? null : Border.all(color: const Color(0x2EC9D2DC), width: 2),
            boxShadow: full ? null : const [BoxShadow(color: Color(0x80000000), blurRadius: 30, offset: Offset(0, 10))],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(full ? 0 : 12),
            child: Stack(fit: StackFit.expand, children: [
              Video(
                controller: vc,
                controls: NoVideoControls,
                fill: Colors.black,
                fit: full
                    ? const {'fill': BoxFit.cover, 'stretch': BoxFit.fill}[app.opt('fsfit', 'fit')] ?? BoxFit.contain
                    : (app.opt('pvfit', 'fill') == 'fill' ? BoxFit.cover : BoxFit.contain),
              ),
              if (ch == null)
                Center(
                  child: Text('Press OK on a show to start watching',
                      textAlign: TextAlign.center, style: ts(18, c: const Color(0xFF8DA0B5))),
                ),
              if (showStripes)
                AnimatedBuilder(
                  animation: stripes,
                  builder: (context, _) => CustomPaint(
                    painter: StripesPainter(
                      stripes.value,
                      ch!.hue,
                      app.nameOf(ch),
                      playError ?? (paused ? 'Paused' : 'Tuning in…'),
                    ),
                  ),
                ),
              if (paused)
                Center(
                  child: Container(
                    width: full ? 120 : 70,
                    height: full ? 120 : 70,
                    alignment: Alignment.center,
                    decoration: const BoxDecoration(color: Color(0xA6050C16), shape: BoxShape.circle),
                    child: Text('❚❚', style: ts(full ? 48 : 26, c: Colors.white)),
                  ),
                ),
              if (full && osd) _osd(),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _osd() {
    final ch = playing;
    if (ch == null) return const SizedBox.shrink();
    final now = DateTime.now();
    final p = app.progAt(ch, now);
    final nx = app.progAt(ch, p.end);
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        padding: const EdgeInsets.fromLTRB(44, 70, 44, 38),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            stops: [0, 0.65, 1],
            colors: [Color(0xF503080F), Color(0xBF03080F), Color(0x0003080F)],
          ),
        ),
        child: Row(children: [
          ChannelBadge(ch: ch, w: 110, h: 72, fontSize: 26),
          const SizedBox(width: 26),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text('${ch.num} · ${app.nameOf(ch)}${app.favs.contains(ch.id) ? '  ♥' : ''}', style: ts(19, c: const Color(0xFFB8C8D8))),
              const SizedBox(height: 4),
              Text(p.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: ts(34, w: FontWeight.w800)),
              const SizedBox(height: 6),
              Text(
                p.placeholder ? 'No guide information' : '${fmt(p.start)} – ${fmt(p.end)} · ${minsLeft(p, now)}m left',
                style: ts(17, c: const Color(0xFFC9D2DC)),
              ),
              const SizedBox(height: 10),
              progressBar(640, progress(p, now)),
              if (!identical(nx, p))
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text.rich(TextSpan(children: [
                    TextSpan(text: 'NEXT: ', style: ts(17, w: FontWeight.w700, c: TP.red)),
                    TextSpan(text: '${fmt(nx.start)} ${nx.title}', style: ts(17, c: const Color(0xFFCFCFCF))),
                  ])),
                ),
              if (paused)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text('❚❚ Paused — press ⏯ or P to play', style: ts(17, w: FontWeight.w700, c: TP.orangeLight)),
                ),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _menu() {
    final items = _menuItems;
    final open = area == Area.menu;
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
      left: open ? 0 : -400,
      top: 0,
      bottom: 0,
      width: 370,
      child: Container(
        decoration: const BoxDecoration(
          color: TP.panel,
          boxShadow: [BoxShadow(color: Color(0xB3000000), blurRadius: 40, offset: Offset(12, 0))],
        ),
        padding: const EdgeInsets.only(top: 22, bottom: 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
            child: Row(children: [
              Image.asset('assets/logo.png', width: 44),
              const SizedBox(width: 12),
              Expanded(
                child: Text(app.acc?.name ?? 'Groups',
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: ts(22, w: FontWeight.w800)),
              ),
            ]),
          ),
          Expanded(
            child: ListView.builder(
              controller: _menuScroll,
              itemCount: items.length,
              itemExtent: 48,
              itemBuilder: (context, k) {
                final m = items[k];
                final focused = open && k == menuIdx;
                return LiftItem(
                  focused: focused,
                  fx: app.fx,
                  padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 11),
                  onTap: () {
                    setState(() => menuIdx = k);
                    _act('ok');
                  },
                  child: Row(children: [
                    if (m.icon != null)
                      Padding(
                        padding: const EdgeInsets.only(right: 12),
                        child: Icon(m.icon, size: 22, color: focused ? TP.ink : (m.kind == 'movies' || m.kind == 'series' ? TP.orange : TP.dim)),
                      ),
                    if (m.kind == 'cat')
                      Container(
                        width: 9,
                        height: 9,
                        margin: const EdgeInsets.only(right: 12),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: m.cat == catIdx ? TP.orange : Colors.transparent,
                        ),
                      ),
                    Expanded(child: Text(m.label, maxLines: 1, overflow: TextOverflow.ellipsis)),
                    if (m.kind == 'cat')
                      Text('${m.count}', style: ts(15, c: focused ? const Color(0xFF33475C) : const Color(0xFFA5B6C8))),
                  ]),
                );
              },
            ),
          ),
        ]),
      ),
    );
  }

  Widget _settingsPanel() {
    final items = _settings;
    final idx = clampI(setIdx, 0, items.isEmpty ? 0 : items.length - 1);
    return Positioned.fill(
      child: Stack(children: [
        // tap the uncovered part of the screen to close
        Positioned.fill(
          child: GestureDetector(onTap: _closeSettings, child: Container(color: const Color(0x330A1626))),
        ),
        Positioned(
          right: 0,
          top: 0,
          bottom: 0,
          width: 460,
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 1, end: 0),
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            builder: (context, v, child) => Transform.translate(offset: Offset(460 * v, 0), child: child),
            child: Container(
              padding: const EdgeInsets.only(top: 26, bottom: 14),
              decoration: const BoxDecoration(
                color: Color(0xFF1F3A5D),
                border: Border(left: BorderSide(color: Color(0x29C9D2DC))),
                boxShadow: [BoxShadow(color: Color(0xB3000000), blurRadius: 50, offset: Offset(-14, 0))],
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(30, 0, 30, 10),
                  child: Text(
                    const {
                          'groups': 'Settings › Groups',
                          'hiddench': 'Settings › Hidden channels',
                          'locks': 'Settings › Locked groups',
                          'channel': 'Channel options',
                          'player': 'Player options',
                          'show': 'Show details',
                          'reminders': 'Settings › Reminders',
                        }[setPage] ??
                        'Settings',
                    style: ts(26, w: FontWeight.w800),
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      for (var i = 0; i < items.length; i++)
                        if (items[i].note)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(30, 4, 30, 8),
                            child: Text(items[i].label, maxLines: 6, overflow: TextOverflow.ellipsis, style: ts(16, c: TP.dim2, h: 1.4)),
                          )
                        else if (items[i].header)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(30, 16, 30, 6),
                            child: Text(items[i].label.toUpperCase(),
                                style: ts(13, w: FontWeight.w800, c: TP.orange).copyWith(letterSpacing: 1.2)),
                          )
                        else
                          LiftItem(
                            key: i == idx ? _setFocusKey : null,
                            focused: i == idx,
                            fx: app.fx,
                            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 13),
                            onTap: () {
                              setState(() => setIdx = i);
                              _act('ok');
                            },
                            child: Row(children: [
                              Expanded(
                                flex: 3,
                                child: Text(items[i].label,
                                    maxLines: 1, overflow: TextOverflow.ellipsis, style: ts(17, c: i == idx ? const Color(0xFF050B14) : TP.text)),
                              ),
                              const SizedBox(width: 10),
                              Flexible(
                                flex: 2,
                                child: Text(
                                  items[i].button || items[i].value.isEmpty ? items[i].value : '‹ ${items[i].value} ›',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.right,
                                  style: ts(15, w: i == idx ? FontWeight.w600 : FontWeight.w400, c: i == idx ? const Color(0xFF1B2B3D) : const Color(0xFFB8C8D8)),
                                ),
                              ),
                            ]),
                          ),
                    ]),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(30, 10, 30, 0),
                  child: Text(
                    (setPage == 'groups' || setPage == 'hiddench' || setPage == 'locks' || setPage == 'reminders')
                        ? 'OK to change · BACK to go back'
                        : '▲▼ move · ◀ ▶ or OK to change · BACK to close',
                    style: ts(14, c: const Color(0xFFA5B6C8)),
                  ),
                ),
              ]),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _inputPanel() {
    const titles = {
      'search': 'Search',
      'rename': 'Rename channel',
      'pin': 'Enter your PIN',
      'setpin': 'Choose a 4-digit PIN',
    };
    final isPin = _inputMode == 'pin' || _inputMode == 'setpin';
    final hint = const {
          'search': 'Channel or show name',
          'rename': 'New name (leave empty to restore)',
        }[_inputMode] ??
        '••••';
    return Positioned.fill(
      child: Stack(children: [
        Positioned.fill(child: GestureDetector(onTap: _closeInput, child: Container(color: const Color(0x330A1626)))),
        Positioned(
          right: 0,
          top: 0,
          bottom: 0,
          width: 480,
          child: Container(
            padding: const EdgeInsets.fromLTRB(0, 26, 0, 14),
            decoration: const BoxDecoration(
              color: Color(0xFF1F3A5D),
              border: Border(left: BorderSide(color: Color(0x29C9D2DC))),
              boxShadow: [BoxShadow(color: Color(0xB3000000), blurRadius: 50, offset: Offset(-14, 0))],
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(30, 0, 30, 14),
                child: Text(titles[_inputMode] ?? '', style: ts(26, w: FontWeight.w800)),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 30),
                child: TextField(
                  controller: _inputCtl,
                  focusNode: _inputFocus,
                  autofocus: true,
                  obscureText: isPin,
                  maxLength: isPin ? 4 : null,
                  keyboardType: isPin ? TextInputType.number : TextInputType.text,
                  textInputAction: TextInputAction.done,
                  style: ts(20),
                  cursorColor: TP.orange,
                  onChanged: _onInputChanged,
                  onSubmitted: (_) => _submitInput(),
                  decoration: InputDecoration(
                    hintText: hint,
                    hintStyle: ts(18, c: const Color(0xFF8FA3B8)),
                    counterText: '',
                    prefixIcon: _inputMode == 'search' ? const Icon(Icons.search, color: TP.dim) : null,
                    filled: true,
                    fillColor: const Color(0xFF20395A),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: Color(0xFF3A5C85), width: 2),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: TP.orange, width: 2),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Expanded(
                child: _inputMode != 'search'
                    ? const SizedBox.shrink()
                    : (_results.isEmpty
                        ? Padding(
                            padding: const EdgeInsets.fromLTRB(30, 10, 30, 0),
                            child: Text(
                              _inputCtl.text.trim().length < 2
                                  ? 'Type at least 2 letters. Searches channel names and shows on every channel.'
                                  : (app.fullGuideLoading ? 'Still loading the full TV guide… results will appear in a moment.' : 'Nothing found.'),
                              style: ts(16, c: TP.dim2, h: 1.4),
                            ),
                          )
                        : SingleChildScrollView(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                              for (var i = 0; i < _results.length; i++)
                                LiftItem(
                                  key: i == resIdx ? _setFocusKey : null,
                                  focused: i == resIdx,
                                  fx: app.fx,
                                  padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 10),
                                  onTap: () => _openResult(_results[i]),
                                  child: Row(children: [
                                    ChannelBadge(ch: _results[i].ch, w: 48, h: 32, fontSize: 12),
                                    const SizedBox(width: 14),
                                    Expanded(
                                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                        Text(_results[i].title,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: ts(18, w: FontWeight.w600, c: i == resIdx ? const Color(0xFF050B14) : TP.text)),
                                        Text(_results[i].sub,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: ts(14, c: i == resIdx ? const Color(0xFF1B2B3D) : TP.dim2)),
                                      ]),
                                    ),
                                  ]),
                                ),
                            ]),
                          )),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(30, 10, 30, 0),
                child: Text(
                  _inputMode == 'search' ? 'Type to search · ▲▼ pick · OK to go · BACK to close' : 'OK to save · BACK to cancel',
                  style: ts(14, c: const Color(0xFFA5B6C8)),
                ),
              ),
            ]),
          ),
        ),
      ]),
    );
  }

  Widget _dialog() {
    Widget btn(String label, int i) => Expanded(
          child: GestureDetector(
            onTap: () {
              setState(() => dlgIdx = i);
              _act('ok');
            },
            child: AnimatedScale(
              scale: dlgIdx == i && app.fx != 'off' ? 1.05 : 1,
              duration: const Duration(milliseconds: 150),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 14),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  gradient: dlgIdx == i ? TP.silver : null,
                  color: dlgIdx == i ? null : TP.kbd,
                  borderRadius: BorderRadius.circular(10),
                  boxShadow: dlgIdx == i && app.fx != 'off'
                      ? const [BoxShadow(color: Color(0x73000000), blurRadius: 28, offset: Offset(0, 14))]
                      : null,
                ),
                child: Text(label, style: ts(18, w: FontWeight.w700, c: dlgIdx == i ? TP.ink : TP.text)),
              ),
            ),
          ),
        );
    return Positioned.fill(
      child: Container(
        color: const Color(0x8C0A1626),
        alignment: Alignment.center,
        child: Container(
          width: 560,
          padding: const EdgeInsets.all(30),
          decoration: BoxDecoration(
            color: const Color(0xFF1F3A5D),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: const Color(0x29C9D2DC)),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(_dlgTitle, textAlign: TextAlign.center, style: ts(26, w: FontWeight.w800)),
            const SizedBox(height: 8),
            Text(_dlgSub, textAlign: TextAlign.center, style: ts(16, c: TP.dim2)),
            const SizedBox(height: 22),
            Row(children: [btn(_dlgNo, 0), const SizedBox(width: 14), btn(_dlgYes, 1)]),
          ]),
        ),
      ),
    );
  }

  Widget _loadingPanel() {
    final err = app.error;
    return Positioned.fill(
      child: Container(
        decoration: TP.background,
        alignment: Alignment.center,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Image.asset('assets/logo.png', width: 120),
          const SizedBox(height: 24),
          if (err == null) ...[
            const SizedBox(width: 36, height: 36, child: CircularProgressIndicator(color: TP.orange, strokeWidth: 3)),
            const SizedBox(height: 18),
            Text('Loading your channels…', style: ts(22, w: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(app.acc?.name ?? '', style: ts(16, c: TP.dim2)),
          ] else ...[
            Text('Couldn\'t load ${app.acc?.name ?? 'your channels'}', style: ts(24, w: FontWeight.w800)),
            const SizedBox(height: 10),
            SizedBox(width: 640, child: Text(err, textAlign: TextAlign.center, style: ts(17, c: TP.dim2, h: 1.4))),
            const SizedBox(height: 22),
            Row(mainAxisSize: MainAxisSize.min, children: [
              GestureDetector(
                onTap: () => app.openAccount(app.active),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
                  decoration: BoxDecoration(color: TP.orange, borderRadius: BorderRadius.circular(10)),
                  child: Text('OK  Try again', style: ts(17, w: FontWeight.w700, c: const Color(0xFF111111))),
                ),
              ),
              const SizedBox(width: 14),
              GestureDetector(
                onTap: _openSettings,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
                  decoration: BoxDecoration(color: TP.kbd, borderRadius: BorderRadius.circular(10)),
                  child: Text('☰  Settings', style: ts(17, w: FontWeight.w700)),
                ),
              ),
            ]),
          ],
        ]),
      ),
    );
  }

  Widget _toastWidget() {
    final m = toast;
    final full = _isFull;
    Widget card = const SizedBox.shrink();
    if (m != null) {
      final match = RegExp(r'^(●|▶|★|❚❚|♥|♡)\s*').firstMatch(m);
      final icon = match?.group(1) ?? 'ℹ';
      final text = match == null ? m : m.substring(match.end);
      final red = icon == '●';
      final heart = icon == '♥' || icon == '♡';
      card = ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 12, 22, 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0x59FFFFFF)),
              gradient: const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0x42FFFFFF), Color(0x1AFFFFFF)],
              ),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Container(
                width: 38,
                height: 38,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: heart
                        ? const [Color(0xFFFFFFFF), Color(0xFFE9EEF4)]
                        : (red ? const [Color(0xFFFF6B6B), Color(0xFFD93636)] : const [TP.orangeLight, TP.orange]),
                  ),
                ),
                child: icon == '♥'
                    ? FavHeart(key: ValueKey(m), on: true, size: 24)
                    : icon == '♡'
                        ? const Icon(Icons.favorite_border, size: 24, color: kHeart)
                        : Text(icon, style: ts(18, c: red ? Colors.white : const Color(0xFF111111))),
              ),
              const SizedBox(width: 14),
              Text(text, style: ts(19, w: FontWeight.w700, c: Colors.white)),
            ]),
          ),
        ),
      );
    }
    return Positioned(
      left: 0,
      right: 0,
      top: full ? 30 : null,
      bottom: full ? null : 52,
      child: IgnorePointer(
        child: Center(
          child: AnimatedOpacity(
            opacity: m == null ? 0 : 1,
            duration: const Duration(milliseconds: 220),
            child: card,
          ),
        ),
      ),
    );
  }
}

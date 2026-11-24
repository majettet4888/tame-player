import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'xtream.dart';

DateTime floor30(DateTime t) => DateTime(t.year, t.month, t.day, t.hour, t.minute < 30 ? 0 : 30);

String friendlyError(Object e) {
  if (e is XtreamException) return e.message;
  if (e is TimeoutException) return 'The server took too long to answer. Check the server address and your internet, then try again.';
  if (e is SocketException || e is http.ClientException || e is HandshakeException) {
    return 'Couldn\'t reach the server. Check the server address (including the :port) and that you\'re online.';
  }
  if (e is FormatException) return 'That server didn\'t answer like an Xtream Codes server. Check the address.';
  return 'Something went wrong: $e';
}

/// Everything the app knows: subscriptions, channels, guide, favorites and settings.
class AppState extends ChangeNotifier {
  static const _secure = FlutterSecureStorage();
  late SharedPreferences _prefs;

  bool ready = false, loading = false;
  String? error;

  List<Account> accounts = [];
  int active = -1;
  XtreamClient? client;
  AccountInfo? info;

  List<ChannelGroup> cats = [];
  List<Channel> channels = [];
  Map<int, Channel> byId = {};
  Map<String, int> catCounts = {};
  final Map<int, List<Program>> _epg = {};
  final Map<int, List<Program>> _placeholders = {};
  final Set<int> _pending = {};
  int _inFlight = 0;
  final List<int> _queue = [];

  Set<int> favs = {};
  Set<String> hiddenGroups = {};
  Set<int> hiddenCh = {};
  Map<int, String> renames = {};
  Set<String> lockedGroups = {};
  List<Map<String, dynamic>> reminders = []; // {ch, start, title}
  List<int> recent = [];
  int? lastChannelId;
  bool use24 = false;
  String fx = 'subtle';

  DateTime rangeStart = DateTime.now(), rangeEnd = DateTime.now();

  Account? get acc => (active >= 0 && active < accounts.length) ? accounts[active] : null;

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    use24 = _prefs.getBool('use24') ?? false;
    fx = _prefs.getString('fx') ?? 'subtle';
    try {
      final raw = await _secure.read(key: 'accounts');
      if (raw != null) {
        accounts = [
          for (final e in jsonDecode(raw) as List) Account.fromJson(Map<String, dynamic>.from(e as Map)),
        ];
      }
    } catch (_) {}
    active = _prefs.getInt('active') ?? 0;
    if (active >= accounts.length) active = accounts.isEmpty ? -1 : 0;
    ready = true;
    notifyListeners();
    if (acc != null) await openAccount(active);
  }

  Future<void> _saveAccounts() async {
    await _secure.write(key: 'accounts', value: jsonEncode([for (final a in accounts) a.toJson()]));
  }

  void resetRange() {
    final n = floor30(DateTime.now());
    rangeStart = n.subtract(const Duration(hours: 4));
    final days = int.tryParse(_prefs.getString('opt_days') ?? '1') ?? 1;
    rangeEnd = n.add(Duration(hours: 24 * days));
    _epg.clear();
    _placeholders.clear();
  }

  /// Signs in to subscription [i] and loads its groups and channels.
  Future<void> openAccount(int i) async {
    if (i < 0 || i >= accounts.length) return;
    active = i;
    await _prefs.setInt('active', i);
    final a = accounts[i];
    client = XtreamClient(a);
    loading = true;
    error = null;
    cats = [];
    channels = [];
    byId = {};
    catCounts = {};
    _pending.clear();
    _queue.clear();
    resetRange();
    notifyListeners();
    try {
      info = await client!.login();
      final results = await Future.wait([client!.categories(), client!.channels()]);
      cats = results[0] as List<ChannelGroup>;
      final ch = results[1] as List<Channel>;
      byId = {for (final c in ch) c.id: c};
      final counts = <String, int>{};
      for (final c in ch) {
        counts[c.catId] = (counts[c.catId] ?? 0) + 1;
      }
      catCounts = counts;
      favs = {for (final s in _prefs.getStringList('favs_${a.key}') ?? const <String>[]) int.tryParse(s) ?? -1}..remove(-1);
      lastChannelId = _prefs.getInt('last_${a.key}');
      recent = [for (final x in _prefs.getStringList('recent_${a.key}') ?? const <String>[]) int.tryParse(x) ?? -1]..remove(-1);
      hiddenGroups = (_prefs.getStringList('hidden_${a.key}') ?? const <String>[]).toSet();
      hiddenCh = {for (final x in _prefs.getStringList('hiddench_${a.key}') ?? const <String>[]) int.tryParse(x) ?? -1}..remove(-1);
      lockedGroups = (_prefs.getStringList('locks_${a.key}') ?? const <String>[]).toSet();
      try {
        reminders = [
          for (final r in jsonDecode(_prefs.getString('reminders_${a.key}') ?? '[]') as List) Map<String, dynamic>.from(r as Map),
        ];
      } catch (_) {
        reminders = [];
      }
      renames = {};
      try {
        final raw = _prefs.getString('renames_${a.key}');
        if (raw != null) {
          (jsonDecode(raw) as Map).forEach((k, v) {
            final id = int.tryParse('$k');
            if (id != null) renames[id] = '$v';
          });
        }
      } catch (_) {}
      channels = ch;
    } catch (e) {
      error = friendlyError(e);
    }
    loading = false;
    notifyListeners();
  }

  /// Tests a new subscription and adds it. Returns an error message, or null if it worked.
  Future<String?> addAccount(Account a) async {
    try {
      await XtreamClient(a).login();
    } catch (e) {
      return friendlyError(e);
    }
    accounts.removeWhere((x) => x.key == a.key);
    accounts.add(a);
    await _saveAccounts();
    await openAccount(accounts.length - 1);
    return null;
  }

  Future<void> removeActive() async {
    if (acc == null) return;
    accounts.removeAt(active);
    await _saveAccounts();
    if (accounts.isEmpty) {
      active = -1;
      client = null;
      channels = [];
      cats = [];
      notifyListeners();
    } else {
      await openAccount(0);
    }
  }

  // ---------------- simple saved options ----------------
  String opt(String key, String def) => _prefs.getString('opt_$key') ?? def;
  void setOpt(String key, String v) {
    _prefs.setString('opt_$key', v);
    if (key == 'shift' || key == 'days') {
      resetRange();
      _pending.clear();
      _queue.clear();
    }
    notifyListeners();
  }

  int get shiftHours => int.tryParse(opt('shift', '0')) ?? 0;

  void refreshGuide() {
    resetRange();
    _pending.clear();
    _queue.clear();
    notifyListeners();
  }

  void clearFavs() {
    favs.clear();
    final a = acc;
    if (a != null) _prefs.setStringList('favs_${a.key}', const []);
    notifyListeners();
  }

  String nameOf(Channel c) => renames[c.id] ?? c.name;

  void rename(int id, String name) {
    final n = name.trim();
    if (n.isEmpty) {
      renames.remove(id);
    } else {
      renames[id] = n;
    }
    final a = acc;
    if (a != null) _prefs.setString('renames_${a.key}', jsonEncode({for (final e in renames.entries) '${e.key}': e.value}));
    notifyListeners();
  }

  void toggleHiddenCh(int id) {
    if (!hiddenCh.remove(id)) hiddenCh.add(id);
    final a = acc;
    if (a != null) _prefs.setStringList('hiddench_${a.key}', [for (final x in hiddenCh) '$x']);
    notifyListeners();
  }

  void toggleLock(String groupId) {
    if (!lockedGroups.remove(groupId)) lockedGroups.add(groupId);
    final a = acc;
    if (a != null) _prefs.setStringList('locks_${a.key}', lockedGroups.toList());
    notifyListeners();
  }

  bool hasReminder(Channel c, Program p) =>
      reminders.any((r) => r['ch'] == c.id && r['start'] == p.start.millisecondsSinceEpoch);

  void toggleReminder(Channel c, Program p) {
    final ms = p.start.millisecondsSinceEpoch;
    final before = reminders.length;
    reminders.removeWhere((r) => r['ch'] == c.id && r['start'] == ms);
    if (reminders.length == before) reminders.add({'ch': c.id, 'start': ms, 'title': p.title});
    _saveReminders();
  }

  /// Reminders whose show starts within a minute (removed once handed out).
  List<Map<String, dynamic>> dueReminders({int leadMinutes = 1}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final lead = leadMinutes * 60000;
    final due = reminders.where((r) => (r['start'] as int) <= now + lead).toList();
    if (due.isNotEmpty) {
      reminders.removeWhere((r) => (r['start'] as int) <= now + lead);
      _saveReminders();
    }
    return due.where((r) => (r['start'] as int) > now - 10 * 60000).toList(); // skip very old ones
  }

  void removeReminderAt(int i) {
    if (i >= 0 && i < reminders.length) reminders.removeAt(i);
    _saveReminders();
  }

  void _saveReminders() {
    final a = acc;
    if (a != null) _prefs.setString('reminders_${a.key}', jsonEncode(reminders));
    notifyListeners();
  }

  bool isLocked(Channel c) => opt('pin', '').isNotEmpty && lockedGroups.contains(c.catId);

  Map<int, List<Program>> get loadedEpg => _epg;

  List<ChannelGroup> get visibleCats => cats.where((c) => !hiddenGroups.contains(c.id)).toList();

  void toggleHidden(String groupId) {
    if (!hiddenGroups.remove(groupId)) hiddenGroups.add(groupId);
    final a = acc;
    if (a != null) _prefs.setStringList('hidden_${a.key}', hiddenGroups.toList());
    notifyListeners();
  }

  int countFor(ChannelGroup c) {
    if (c.id == '__all') {
      if (hiddenGroups.isEmpty) return channels.length;
      return channels.where((x) => !hiddenGroups.contains(x.catId)).length;
    }
    if (c.id == '__fav') return channels.where((x) => favs.contains(x.id)).length;
    if (c.id == '__recent') return recent.where((id) => byId.containsKey(id)).length;
    return catCounts[c.id] ?? 0;
  }

  List<Channel> listFor(ChannelGroup c) {
    if (c.id == '__all') {
      if (hiddenGroups.isEmpty && hiddenCh.isEmpty) return channels;
      return channels.where((x) => !hiddenGroups.contains(x.catId) && !hiddenCh.contains(x.id)).toList();
    }
    if (c.id == '__fav') return channels.where((x) => favs.contains(x.id)).toList();
    if (c.id == '__recent') return [for (final id in recent) if (byId[id] != null && !hiddenCh.contains(id)) byId[id]!];
    return channels.where((x) => x.catId == c.id && !hiddenCh.contains(x.id)).toList();
  }

  void toggleFav(int id) {
    if (!favs.remove(id)) favs.add(id);
    final a = acc;
    if (a != null) _prefs.setStringList('favs_${a.key}', [for (final f in favs) '$f']);
    notifyListeners();
  }

  void setLast(int id) {
    lastChannelId = id;
    recent.remove(id);
    recent.insert(0, id);
    if (recent.length > 15) recent = recent.sublist(0, 15);
    final a = acc;
    if (a != null) {
      _prefs.setInt('last_${a.key}', id);
      _prefs.setStringList('recent_${a.key}', [for (final x in recent) '$x']);
    }
  }

  void clearRecent() {
    recent = [];
    final a = acc;
    if (a != null) _prefs.setStringList('recent_${a.key}', const []);
    notifyListeners();
  }

  void setUse24(bool v) {
    use24 = v;
    _prefs.setBool('use24', v);
    notifyListeners();
  }

  void setFx(String v) {
    fx = v;
    _prefs.setString('fx', v);
    notifyListeners();
  }

  // ---------------- TV guide ----------------

  List<Program> _fillGaps(List<Program> list) {
    final out = <Program>[];
    var t = rangeStart;
    void gap(DateTime a, DateTime b) {
      while (a.isBefore(b)) {
        var e = DateTime(a.year, a.month, a.day, a.hour).add(const Duration(hours: 1));
        if (e.isAfter(b)) e = b;
        out.add(Program(a, e, 'No program information', '', placeholder: true));
        a = e;
      }
    }

    for (final p in list) {
      if (!p.end.isAfter(t) || !p.start.isBefore(rangeEnd)) continue;
      if (p.start.isBefore(t.subtract(const Duration(minutes: 1)))) continue; // overlapping duplicate
      if (p.start.isAfter(t)) {
        final g = p.start.difference(t);
        if (g.inMinutes < 15 && out.isNotEmpty && !out.last.placeholder) {
          final last = out.removeLast();
          out.add(Program(last.start, p.start, last.title, last.desc)); // stretch over the short gap
        } else {
          gap(t, p.start);
        }
      }
      out.add(p);
      t = p.end.isAfter(t) ? p.end : t;
    }
    gap(t, rangeEnd);
    return out;
  }

  List<Program> epgFor(Channel ch) =>
      _epg[ch.id] ??
      (_placeholders[ch.id] ??= [Program(rangeStart, rangeEnd, 'Loading guide…', '', placeholder: true)]);

  bool hasEpg(Channel ch) => _epg.containsKey(ch.id);

  Program progAt(Channel ch, DateTime t) {
    final l = epgFor(ch);
    for (final p in l) {
      if (p.isLiveAt(t)) return p;
    }
    return t.isBefore(l.first.start) ? l.first : l.last;
  }

  /// Loads the guide for these channels in the background (a few at a time).
  void ensureEpg(Iterable<Channel> chs) {
    if (client == null) return;
    for (final c in chs) {
      if (_epg.containsKey(c.id) || _pending.contains(c.id)) continue;
      _pending.add(c.id);
      _queue.add(c.id);
    }
    _pump();
  }

  void _pump() {
    while (_inFlight < 4 && _queue.isNotEmpty) {
      final id = _queue.removeAt(0);
      _inFlight++;
      _fetch(id);
    }
  }

  Future<void> _fetch(int id) async {
    final c = client;
    try {
      var l = c == null ? <Program>[] : await c.epg(id);
      final sh = shiftHours;
      if (sh != 0) {
        final d = Duration(hours: sh);
        l = [for (final p in l) Program(p.start.add(d), p.end.add(d), p.title, p.desc)];
      }
      if (identical(c, client)) _epg[id] = _fillGaps(l);
    } catch (_) {
      if (identical(c, client)) _epg[id] = _fillGaps(const []);
    } finally {
      _inFlight--;
      _pending.remove(id);
      notifyListeners();
      _pump();
    }
  }
}

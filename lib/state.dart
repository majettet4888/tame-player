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

  List<Category> cats = [];
  List<Channel> channels = [];
  Map<int, Channel> byId = {};
  Map<String, int> catCounts = {};
  final Map<int, List<Program>> _epg = {};
  final Map<int, List<Program>> _placeholders = {};
  final Set<int> _pending = {};
  int _inFlight = 0;
  final List<int> _queue = [];

  Set<int> favs = {};
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
    rangeEnd = n.add(const Duration(hours: 24));
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
      cats = results[0] as List<Category>;
      final ch = results[1] as List<Channel>;
      byId = {for (final c in ch) c.id: c};
      final counts = <String, int>{};
      for (final c in ch) {
        counts[c.catId] = (counts[c.catId] ?? 0) + 1;
      }
      catCounts = counts;
      favs = {for (final s in _prefs.getStringList('favs_${a.key}') ?? const <String>[]) int.tryParse(s) ?? -1}..remove(-1);
      lastChannelId = _prefs.getInt('last_${a.key}');
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

  int countFor(Category c) {
    if (c.id == '__all') return channels.length;
    if (c.id == '__fav') return channels.where((x) => favs.contains(x.id)).length;
    return catCounts[c.id] ?? 0;
  }

  List<Channel> listFor(Category c) {
    if (c.id == '__all') return channels;
    if (c.id == '__fav') return channels.where((x) => favs.contains(x.id)).toList();
    return channels.where((x) => x.catId == c.id).toList();
  }

  void toggleFav(int id) {
    if (!favs.remove(id)) favs.add(id);
    final a = acc;
    if (a != null) _prefs.setStringList('favs_${a.key}', [for (final f in favs) '$f']);
    notifyListeners();
  }

  void setLast(int id) {
    lastChannelId = id;
    final a = acc;
    if (a != null) _prefs.setInt('last_${a.key}', id);
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
      if (p.start.isAfter(t)) gap(t, p.start);
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
      final l = c == null ? <Program>[] : await c.epg(id);
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

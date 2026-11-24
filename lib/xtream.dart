import 'dart:convert';

import 'package:http/http.dart' as http;

/// One Xtream Codes subscription.
class Account {
  final String name, server, user, pass;

  /// Stays the same when the login is edited, so favorites, hidden channels,
  /// reminders etc. carry over to the new server/username/password.
  final String id;
  Account({required this.name, required this.server, required this.user, required this.pass, String? id})
      : id = id ?? '$server|$user';

  String get key => id;

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'server': server, 'user': user, 'pass': pass};

  factory Account.fromJson(Map<String, dynamic> j) => Account(
        id: j['id'] == null ? null : '${j['id']}',
        name: '${j['name'] ?? ''}',
        server: '${j['server'] ?? ''}',
        user: '${j['user'] ?? ''}',
        pass: '${j['pass'] ?? ''}',
      );
}

class ChannelGroup {
  final String id, name;
  const ChannelGroup(this.id, this.name);
}

class Channel {
  final int id, num, hue;
  final String name, catId;
  final String? icon;
  final bool catchup;
  final String epgId;
  const Channel({
    this.epgId = '',
    required this.id,
    required this.num,
    required this.name,
    required this.catId,
    required this.hue,
    this.icon,
    this.catchup = false,
  });
}

class Program {
  final DateTime start, end;
  final String title, desc;
  final bool placeholder;
  const Program(this.start, this.end, this.title, this.desc, {this.placeholder = false});

  bool isLiveAt(DateTime t) => !start.isAfter(t) && end.isAfter(t);
}

class VodItem {
  final int id;
  final String name, rating, year, ext, plot;
  final String? poster;
  final bool series;
  const VodItem({
    required this.id,
    required this.name,
    required this.rating,
    required this.year,
    required this.ext,
    required this.series,
    this.poster,
    this.plot = '',
  });
}

class Episode {
  final String id, title, ext, plot;
  final int season, number, seconds;
  final String? image;
  const Episode(this.id, this.title, this.ext, this.plot, this.season, this.number, this.seconds, this.image);
}

class AccountInfo {
  final int maxConnections, activeConnections;
  final DateTime? expires;
  const AccountInfo(this.maxConnections, this.activeConnections, this.expires);
}

class XtreamException implements Exception {
  final String message;
  XtreamException(this.message);
  @override
  String toString() => message;
}

/// Base64 text from the guide (titles and descriptions). Falls back to the raw text.
String b64(String? s) {
  if (s == null || s.isEmpty) return '';
  try {
    return utf8.decode(base64.decode(base64.normalize(s.trim())), allowMalformed: true);
  } catch (_) {
    return s;
  }
}

int _toInt(dynamic v) => int.tryParse('${v ?? ''}') ?? 0;

class XtreamClient {
  final Account acc;
  final http.Client _http = http.Client();
  XtreamClient(this.acc);

  Uri _uri(Map<String, String> q) => Uri.parse('${acc.server}/player_api.php')
      .replace(queryParameters: {'username': acc.user, 'password': acc.pass, ...q});

  Future<dynamic> _get(Map<String, String> q, {int seconds = 30}) async {
    final r = await _http
        .get(_uri(q), headers: const {'User-Agent': 'TamePlayer/0.1'})
        .timeout(Duration(seconds: seconds));
    if (r.statusCode != 200) {
      throw XtreamException('The server answered with an error (${r.statusCode}).');
    }
    return jsonDecode(utf8.decode(r.bodyBytes, allowMalformed: true));
  }

  Future<AccountInfo> login() async {
    final j = await _get({}, seconds: 20);
    final ui = j is Map ? j['user_info'] : null;
    if (ui is! Map || '${ui['auth']}' != '1') {
      throw XtreamException('The provider said the username or password is wrong.');
    }
    final exp = _toInt(ui['exp_date']);
    return AccountInfo(
      _toInt(ui['max_connections']),
      _toInt(ui['active_cons']),
      exp > 0 ? DateTime.fromMillisecondsSinceEpoch(exp * 1000) : null,
    );
  }

  Future<List<ChannelGroup>> categories() async {
    final j = await _get({'action': 'get_live_categories'});
    if (j is! List) return [];
    return [
      for (final c in j)
        if (c is Map) ChannelGroup('${c['category_id']}', '${c['category_name'] ?? ''}'.trim()),
    ];
  }

  Future<List<Channel>> channels() async {
    final j = await _get({'action': 'get_live_streams'}, seconds: 60);
    if (j is! List) return [];
    final out = <Channel>[];
    var i = 0;
    for (final s in j) {
      if (s is! Map) continue;
      final id = int.tryParse('${s['stream_id']}');
      if (id == null) continue;
      i++;
      final icon = s['stream_icon'];
      out.add(Channel(
        id: id,
        num: int.tryParse('${s['num']}') ?? i,
        name: '${s['name'] ?? ''}'.trim(),
        catId: '${s['category_id'] ?? ''}',
        icon: (icon is String && icon.trim().isNotEmpty) ? icon.trim() : null,
        catchup: '${s['tv_archive']}' == '1',
        epgId: '${s['epg_channel_id'] ?? ''}'.trim(),
        hue: (id * 37) % 360,
      ));
    }
    out.sort((a, b) => a.num.compareTo(b.num));
    return out;
  }

  /// Full guide for one channel (usually a few days).
  Future<List<Program>> epg(int streamId) async {
    final j = await _get({'action': 'get_simple_data_table', 'stream_id': '$streamId'});
    final l = j is Map ? j['epg_listings'] : null;
    if (l is! List) return [];
    final out = <Program>[];
    for (final e in l) {
      if (e is! Map) continue;
      final s = int.tryParse('${e['start_timestamp']}');
      final t = int.tryParse('${e['stop_timestamp']}');
      if (s == null || t == null || t <= s) continue;
      final title = b64(e['title']?.toString());
      out.add(Program(
        DateTime.fromMillisecondsSinceEpoch(s * 1000),
        DateTime.fromMillisecondsSinceEpoch(t * 1000),
        title.isEmpty ? '—' : title,
        b64(e['description']?.toString()),
      ));
    }
    out.sort((a, b) => a.start.compareTo(b.start));
    return out;
  }

  // ---------------- Movies and TV shows (VOD) ----------------

  Future<List<ChannelGroup>> vodCategories({bool series = false}) async {
    final j = await _get({'action': series ? 'get_series_categories' : 'get_vod_categories'});
    if (j is! List) return [];
    return [
      for (final c in j)
        if (c is Map) ChannelGroup('${c['category_id']}', '${c['category_name'] ?? ''}'.trim()),
    ];
  }

  Future<List<VodItem>> vodList(String catId, {bool series = false}) async {
    final j = await _get({'action': series ? 'get_series' : 'get_vod_streams', 'category_id': catId}, seconds: 60);
    if (j is! List) return [];
    final out = <VodItem>[];
    for (final v in j) {
      if (v is! Map) continue;
      final id = int.tryParse('${series ? v['series_id'] : v['stream_id']}');
      if (id == null) continue;
      final img = '${(series ? v['cover'] : v['stream_icon']) ?? ''}'.trim();
      out.add(VodItem(
        id: id,
        name: '${v['name'] ?? ''}'.trim(),
        poster: img.isEmpty ? null : img,
        rating: '${v['rating'] ?? ''}'.trim(),
        year: '${v['year'] ?? v['releaseDate'] ?? v['release_date'] ?? ''}'.trim(),
        ext: '${v['container_extension'] ?? 'mp4'}',
        series: series,
        plot: '${v['plot'] ?? ''}'.trim(),
      ));
    }
    return out;
  }

  Future<Map<String, dynamic>> vodInfo(int id) async {
    final j = await _get({'action': 'get_vod_info', 'vod_id': '$id'});
    return j is Map ? Map<String, dynamic>.from(j) : {};
  }

  Future<Map<String, dynamic>> seriesInfo(int id) async {
    final j = await _get({'action': 'get_series_info', 'series_id': '$id'});
    return j is Map ? Map<String, dynamic>.from(j) : {};
  }

  String movieUrl(int id, String ext) =>
      '${acc.server}/movie/${Uri.encodeComponent(acc.user)}/${Uri.encodeComponent(acc.pass)}/$id.$ext';

  String episodeUrl(String id, String ext) =>
      '${acc.server}/series/${Uri.encodeComponent(acc.user)}/${Uri.encodeComponent(acc.pass)}/$id.$ext';

  String get xmltvUrl =>
      '${acc.server}/xmltv.php?username=${Uri.encodeQueryComponent(acc.user)}&password=${Uri.encodeQueryComponent(acc.pass)}';

  String liveUrl(int id, {String ext = 'ts'}) =>
      '${acc.server}/live/${Uri.encodeComponent(acc.user)}/${Uri.encodeComponent(acc.pass)}/$id.$ext';
}


String _unescape(String v) => v
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&#39;', "'")
    .replaceAll('&amp;', '&')
    .trim();

DateTime? _xmltvTime(String v) {
  final m = RegExp(r'^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})\s*([+-])?(\d{2})?(\d{2})?').firstMatch(v.trim());
  if (m == null) return null;
  var t = DateTime.utc(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!), int.parse(m[4]!), int.parse(m[5]!), int.parse(m[6]!));
  if (m[7] != null && m[8] != null) {
    final off = Duration(hours: int.parse(m[8]!), minutes: int.parse(m[9] ?? '0'));
    t = m[7] == '+' ? t.subtract(off) : t.add(off);
  }
  return t.toLocal();
}

/// Downloads the provider's whole guide (XMLTV) and keeps shows between [fromMs] and [toMs].
/// Runs in a background isolate. Returns epg channel id -> [[startMs, endMs, title, desc], ...].
Future<Map<String, List<List<Object>>>> downloadFullGuide(String url, int fromMs, int toMs) async {
  final out = <String, List<List<Object>>>{};
  final client = http.Client();
  try {
    final res = await client.send(http.Request('GET', Uri.parse(url))..headers['User-Agent'] = 'TamePlayer/0.1');
    if (res.statusCode != 200) return out;
    final progRe = RegExp(r'<programme\b([^>]*)>([\s\S]*?)</programme>');
    final attrRe = RegExp(r'(\w+)="([^"]*)"');
    final titleRe = RegExp(r'<title[^>]*>([\s\S]*?)</title>');
    final descRe = RegExp(r'<desc[^>]*>([\s\S]*?)</desc>');
    var buf = StringBuffer();
    await for (final chunk in res.stream.transform(utf8.decoder)) {
      buf.write(chunk);
      final text = buf.toString();
      final last = text.lastIndexOf('</programme>');
      if (last < 0) continue;
      final head = text.substring(0, last + 12);
      buf = StringBuffer(text.substring(last + 12));
      for (final m in progRe.allMatches(head)) {
        final attrs = {for (final a in attrRe.allMatches(m[1]!)) a[1]!: a[2]!};
        final start = _xmltvTime(attrs['start'] ?? '');
        final stop = _xmltvTime(attrs['stop'] ?? '');
        final ch = attrs['channel'];
        if (start == null || stop == null || ch == null) continue;
        final s = start.millisecondsSinceEpoch, e = stop.millisecondsSinceEpoch;
        if (e <= fromMs || s >= toMs || e <= s) continue;
        final title = _unescape(titleRe.firstMatch(m[2]!)?[1] ?? '');
        var desc = _unescape(descRe.firstMatch(m[2]!)?[1] ?? '');
        if (desc.length > 400) desc = '${desc.substring(0, 400)}…';
        (out[ch] ??= []).add([s, e, title.isEmpty ? '—' : title, desc]);
      }
    }
  } finally {
    client.close();
  }
  return out;
}

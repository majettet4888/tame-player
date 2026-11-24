import 'dart:convert';

import 'package:http/http.dart' as http;

/// One Xtream Codes subscription.
class Account {
  final String name, server, user, pass;
  Account({required this.name, required this.server, required this.user, required this.pass});

  String get key => '$server|$user';

  Map<String, dynamic> toJson() => {'name': name, 'server': server, 'user': user, 'pass': pass};

  factory Account.fromJson(Map<String, dynamic> j) => Account(
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
  const Channel({
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

  String liveUrl(int id, {String ext = 'ts'}) =>
      '${acc.server}/live/${Uri.encodeComponent(acc.user)}/${Uri.encodeComponent(acc.pass)}/$id.$ext';
}

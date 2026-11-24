import 'package:flutter/material.dart';

import 'state.dart';
import 'theme.dart';
import 'xtream.dart';

class LoginScreen extends StatefulWidget {
  final AppState app;
  final bool addMode;
  const LoginScreen({super.key, required this.app, this.addMode = false});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _name = TextEditingController();
  final _server = TextEditingController();
  final _user = TextEditingController();
  final _pass = TextEditingController();
  bool _busy = false;
  String? _err;

  @override
  void dispose() {
    _name.dispose();
    _server.dispose();
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    var server = _server.text.trim();
    final user = _user.text.trim();
    final pass = _pass.text;
    if (server.isEmpty || user.isEmpty || pass.isEmpty) {
      setState(() => _err = 'Fill in the server, username and password.');
      return;
    }
    if (!RegExp(r'^https?://', caseSensitive: false).hasMatch(server)) server = 'http://$server';
    while (server.endsWith('/')) {
      server = server.substring(0, server.length - 1);
    }
    final name = _name.text.trim().isEmpty ? 'Subscription ${widget.app.accounts.length + 1}' : _name.text.trim();
    setState(() {
      _busy = true;
      _err = null;
    });
    final err = await widget.app.addAccount(Account(name: name, server: server, user: user, pass: pass));
    if (!mounted) return;
    if (err != null) {
      setState(() {
        _busy = false;
        _err = err;
      });
      return;
    }
    if (widget.addMode) Navigator.of(context).pop();
  }

  InputDecoration _dec(String hint) => InputDecoration(
        hintText: hint,
        hintStyle: ts(16, c: const Color(0xFF8FA3B8)),
        filled: true,
        fillColor: const Color(0xFF20395A),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: Color(0xFF3A5C85), width: 2),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: TP.orange, width: 2),
        ),
      );

  Widget _field(String label, TextEditingController c,
      {String hint = '', bool obscure = false, bool autofocus = false, TextInputAction action = TextInputAction.next, VoidCallback? onDone}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: ts(13, c: const Color(0xFFB8C8D8))),
        const SizedBox(height: 6),
        TextField(
          controller: c,
          obscureText: obscure,
          autofocus: autofocus,
          autocorrect: false,
          enableSuggestions: false,
          textInputAction: action,
          keyboardType: obscure ? TextInputType.visiblePassword : TextInputType.url,
          style: ts(16),
          cursorColor: TP.orange,
          decoration: _dec(hint),
          onSubmitted: (_) => onDone != null ? onDone() : FocusScope.of(context).nextFocus(),
        ),
      ]),
    );
  }

  ButtonStyle _btn(Color bg, Color fg) => ButtonStyle(
        backgroundColor: WidgetStatePropertyAll(bg),
        foregroundColor: WidgetStatePropertyAll(fg),
        padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: 16)),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
        side: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.focused) ? const BorderSide(color: Colors.white, width: 2) : BorderSide.none,
        ),
        textStyle: WidgetStatePropertyAll(ts(16, w: FontWeight.w700)),
      );

  @override
  Widget build(BuildContext context) {
    final form = Container(
      width: 420,
      padding: const EdgeInsets.all(26),
      decoration: BoxDecoration(
        color: const Color(0xD91D3758),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0x24C9D2DC)),
      ),
      child: FocusTraversalGroup(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          Text(widget.addMode ? 'Add a subscription' : 'Sign in with Xtream Codes', style: ts(20, w: FontWeight.w700)),
          const SizedBox(height: 16),
          _field('Server URL', _server, hint: 'http://provider.com:8080', autofocus: true),
          _field('Username', _user),
          _field('Password', _pass, obscure: true, action: TextInputAction.next),
          _field('Name (optional)', _name, hint: 'e.g. Main 4-screen', action: TextInputAction.done, onDone: _submit),
          const SizedBox(height: 4),
          Row(children: [
            if (widget.addMode) ...[
              Expanded(
                child: FilledButton(
                  style: _btn(const Color(0xFF35577F), Colors.white),
                  onPressed: _busy ? null : () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: FilledButton(
                style: _btn(TP.orange, const Color(0xFF111111)),
                onPressed: _busy ? null : _submit,
                child: _busy
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5, color: Color(0xFF111111)))
                    : Text(widget.addMode ? 'Add' : 'Sign in'),
              ),
            ),
          ]),
          if (_err != null) ...[
            const SizedBox(height: 12),
            Text(_err!, style: ts(14, c: const Color(0xFFF3B064), h: 1.4)),
          ],
          const SizedBox(height: 10),
          Text('Your login is saved only on this device.', style: ts(12.5, c: const Color(0xFF9FB2C7))),
        ]),
      ),
    );

    final brand = Column(mainAxisSize: MainAxisSize.min, children: [
      Image.asset('assets/logo.png', width: 170),
      const SizedBox(height: 8),
      Text.rich(TextSpan(children: [
        TextSpan(text: 'Tame ', style: ts(40, w: FontWeight.w800)),
        TextSpan(text: 'Player', style: ts(40, w: FontWeight.w800, c: TP.orange)),
      ])),
      const SizedBox(height: 4),
      Text('Live TV · Full TV Guide · Xtream Codes', style: ts(15, c: TP.dim2)),
    ]);

    return Scaffold(
      backgroundColor: TP.bgBot,
      body: Container(
        decoration: TP.background,
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Wrap(
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 56,
                runSpacing: 28,
                children: [brand, form],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

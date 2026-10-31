/// Signing in (email, then a 6-digit code) and setting up a profile.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/errors.dart';
import '../data/models.dart';
import '../state/club_controller.dart';
import 'theme.dart';
import 'widgets.dart';

class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key, required this.controller, this.demo = false});
  final ClubController controller;
  final bool demo;
  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  final _email = TextEditingController(), _code = TextEditingController();
  bool _busy = false;
  String? _error;
  int _cooldown = 0;
  Timer? _timer;
  String _submitted = '';

  ClubController get c => widget.controller;

  @override
  void dispose() {
    _timer?.cancel();
    _email.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final email = _email.text.trim();
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email)) {
      setState(() => _error = 'Please enter a valid email address.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await c.sendCode(email);
      _startCooldown();
    } on ClubException catch (e) {
      if (mounted) setState(() => _error = friendly(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _startCooldown() {
    _cooldown = 60;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      setState(() => _cooldown = (_cooldown - 1).clamp(0, 60));
      if (_cooldown == 0) t.cancel();
    });
  }

  Future<void> _verify() async {
    final code = _code.text.trim();
    if (code.length != 6 || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await c.verifyCode(code);
    } on ClubException catch (e) {
      if (mounted) {
        setState(() => _error = friendly(e));
        _code.clear();
        _submitted = '';
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: c,
        builder: (context, _) {
          final waitingForCode = c.pendingEmail != null;
          return Scaffold(
            body: SafeArea(
              child: PageBody(
                child: ListView(padding: const EdgeInsets.fromLTRB(24, 36, 24, 24), children: [
                  const Center(child: LogoMark(size: 112)),
                  const SizedBox(height: 22),
                  Center(child: Text('Gilbert Flex Club', style: displayStyle(42), textAlign: TextAlign.center)),
                  const SizedBox(height: 8),
                  Center(child: Text('Check in, earn badges and cheer each other on.', style: bodyStyle(color: Brand.inkSoft), textAlign: TextAlign.center)),
                  const SizedBox(height: 34),
                  if (!waitingForCode) ...[
                    Text('YOUR EMAIL', style: labelStyle()),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _email, keyboardType: TextInputType.emailAddress, textInputAction: TextInputAction.done,
                      autofillHints: const [AutofillHints.email], autocorrect: false, enableSuggestions: false,
                      onSubmitted: (_) => _send(), decoration: const InputDecoration(hintText: 'you@example.com'),
                    ),
                    if (_error != null) _ErrorText(_error!),
                    const SizedBox(height: 16),
                    PrimaryButton('Email me a code', onPressed: _send, busy: _busy),
                    const SizedBox(height: 14),
                    Text("We'll email you a 6-digit code. No password to remember.", style: bodyStyle(size: 13, color: Brand.inkSoft), textAlign: TextAlign.center),
                  ] else ...[
                    Text('We sent a 6-digit code to', style: bodyStyle(color: Brand.inkSoft), textAlign: TextAlign.center),
                    Text(c.pendingEmail!, style: bodyStyle(weight: 600), textAlign: TextAlign.center),
                    const SizedBox(height: 20),
                    TextField(
                      controller: _code, keyboardType: TextInputType.number, textAlign: TextAlign.center, maxLength: 6,
                      autofillHints: const [AutofillHints.oneTimeCode], autofocus: true,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      style: displayStyle(40, italic: false, weight: 600).copyWith(letterSpacing: 10),
                      decoration: const InputDecoration(counterText: '', hintText: '······'),
                      onChanged: (v) {
                        if (v.length == 6 && v != _submitted) {
                          _submitted = v;
                          _verify();
                        }
                      },
                    ),
                    if (_error != null) _ErrorText(_error!),
                    const SizedBox(height: 16),
                    PrimaryButton('Sign in', onPressed: _verify, busy: _busy),
                    const SizedBox(height: 8),
                    Center(child: QuietButton(_cooldown > 0 ? 'Send a new code in ${_cooldown}s' : 'Send a new code', onPressed: _cooldown > 0 || _busy ? null : _send)),
                    Center(child: QuietButton('Use a different email', onPressed: _busy ? null : c.backToEmail)),
                  ],
                  if (widget.demo) ...[
                    const SizedBox(height: 28),
                    Paper(
                      color: Brand.gold.withValues(alpha: .35),
                      child: Text('Demo mode: sample data on this device only. Use any email, and the code 123456. Add "staff" to the email to try the front-desk tools.', style: bodyStyle(size: 13, color: Brand.brown)),
                    ),
                  ],
                ]),
              ),
            ),
          );
        },
      );
}

class _ErrorText extends StatelessWidget {
  const _ErrorText(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Semantics(
        liveRegion: true,
        child: Padding(padding: const EdgeInsets.only(top: 10), child: Text(text, style: bodyStyle(size: 13.5, color: Brand.danger, weight: 500))),
      );
}

/// First-time setup, and editing from the Me tab.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key, required this.controller, this.editing = false});
  final ClubController controller;
  final bool editing;
  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  late final TextEditingController _name;
  late String _avatar;
  String? _favorite;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final p = widget.controller.stats?.profile;
    _name = TextEditingController(text: p?.displayName ?? '');
    _avatar = p?.avatar ?? 'sage';
    _favorite = p?.favoriteClass;
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Please add the name you would like on the wall.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.controller.saveProfile(name: name, favoriteClass: _favorite, avatar: _avatar);
      if (mounted && widget.editing) Navigator.of(context).pop();
    } on ClubException catch (e) {
      if (mounted) setState(() => _error = friendly(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final types = widget.controller.catalog.classTypes;
    return Scaffold(
      appBar: widget.editing ? AppBar(title: Text('Your profile', style: displayStyle(26, italic: false, weight: 600))) : null,
      body: SafeArea(
        child: PageBody(
          child: ListView(padding: const EdgeInsets.fromLTRB(24, 24, 24, 32), children: [
            if (!widget.editing) ...[
              Text('Welcome', style: displayStyle(44)),
              const SizedBox(height: 6),
              Text('Tell us what to call you. This is the name other members see on the wall.', style: bodyStyle(color: Brand.inkSoft)),
              const SizedBox(height: 28),
            ],
            Text('YOUR NAME', style: labelStyle()),
            const SizedBox(height: 8),
            TextField(controller: _name, maxLength: 30, textCapitalization: TextCapitalization.words, autofillHints: const [AutofillHints.givenName], decoration: const InputDecoration(hintText: 'First name or nickname', counterText: '')),
            const SizedBox(height: 22),
            Text('YOUR COLOUR', style: labelStyle()),
            const SizedBox(height: 10),
            Wrap(spacing: 12, children: [
              for (final a in avatars)
                Semantics(
                  button: true, selected: _avatar == a, label: a,
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () => setState(() => _avatar = a),
                    child: Container(
                      width: 52, height: 52, alignment: Alignment.center,
                      decoration: BoxDecoration(shape: BoxShape.circle, color: Brand.avatarColors[a], border: Border.all(color: _avatar == a ? Brand.sageDeep : Colors.transparent, width: 3)),
                      child: _avatar == a ? const Icon(Icons.check, color: Brand.brown) : null,
                    ),
                  ),
                ),
            ]),
            if (types.isNotEmpty) ...[
              const SizedBox(height: 24),
              Text('YOUR FAVOURITE CLASS (OPTIONAL)', style: labelStyle()),
              const SizedBox(height: 10),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final t in types)
                  ChoiceChip(
                    label: Text(t.name), selected: _favorite == t.name,
                    onSelected: (on) => setState(() => _favorite = on ? t.name : null),
                    selectedColor: Brand.sage, backgroundColor: Brand.paper, side: const BorderSide(color: Brand.line),
                    labelStyle: bodyStyle(size: 13, weight: 500),
                  ),
              ]),
            ],
            if (_error != null) _ErrorText(_error!),
            const SizedBox(height: 28),
            PrimaryButton(widget.editing ? 'Save' : 'Join the club', onPressed: _save, busy: _busy),
          ]),
        ),
      ),
    );
  }
}

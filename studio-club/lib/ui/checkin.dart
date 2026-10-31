/// Check in: type the code from the front desk.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/errors.dart';
import '../data/models.dart';
import '../state/club_controller.dart';
import 'theme.dart';
import 'widgets.dart';

class CheckInScreen extends StatefulWidget {
  const CheckInScreen({super.key, required this.controller});
  final ClubController controller;
  @override
  State<CheckInScreen> createState() => _CheckInScreenState();
}

class _CheckInScreenState extends State<CheckInScreen> {
  final _code = TextEditingController();
  bool _busy = false;
  CheckInResult? _result;
  String? _error;

  ClubController get c => widget.controller;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final code = _code.text.trim();
    if (code.length < 6 || _busy) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _result = null;
      _error = null;
    });
    try {
      final r = await c.checkIn(code);
      if (!mounted) return;
      setState(() => _result = r);
      if (r.counted) {
        _code.clear();
        HapticFeedback.mediumImpact();
      }
    } on ClubException catch (e) {
      if (mounted) setState(() => _error = friendly(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _message(CheckInStatus s) => switch (s) {
        CheckInStatus.invalid => "That code doesn't match a class. Please check it at the front desk.",
        CheckInStatus.closed => 'Check-in opens 45 minutes before class and closes 30 minutes after it ends.',
        CheckInStatus.limit => "You've already checked in to 2 classes today. Enjoy your day!",
        CheckInStatus.throttled => "That's a few wrong codes in a row. Please wait a few minutes and try again.",
        CheckInStatus.noProfile => 'Please finish setting up your profile first.',
        _ => '',
      };

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: c,
        builder: (context, _) {
          final r = _result;
          return PageBody(
            child: ListView(padding: const EdgeInsets.fromLTRB(20, 16, 20, 32), keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag, children: [
              if (c.offline) OfflineBanner(onRetry: c.refreshAll, lastSynced: c.lastSynced),
              Text('Check in', style: displayStyle(40)),
              const SizedBox(height: 6),
              Text('Type the 6-character code shown at the front desk.', style: bodyStyle(color: Brand.inkSoft)),
              const SizedBox(height: 26),
              Semantics(
                label: 'Check-in code',
                child: TextField(
                  controller: _code, maxLength: 6, textAlign: TextAlign.center, textCapitalization: TextCapitalization.characters,
                  autocorrect: false, enableSuggestions: false, textInputAction: TextInputAction.done,
                  inputFormatters: [FilteringTextInputFormatter.allow(RegExp('[A-Za-z0-9]')), _UpperCase()],
                  style: displayStyle(42, italic: false, weight: 600).copyWith(letterSpacing: 8),
                  decoration: const InputDecoration(counterText: '', hintText: '······'),
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) => _submit(),
                ),
              ),
              const SizedBox(height: 16),
              PrimaryButton('Check in', icon: Icons.check_circle_outline, busy: _busy, onPressed: _code.text.trim().length >= 6 ? _submit : null),
              const SizedBox(height: 18),
              if (_error != null) Semantics(liveRegion: true, child: Paper(color: Brand.clay.withValues(alpha: .6), child: Text(_error!, style: bodyStyle(size: 14, color: Brand.brown)))),
              if (r != null && !r.counted) Semantics(liveRegion: true, child: Paper(color: Brand.clay.withValues(alpha: .6), child: Text(_message(r.status), style: bodyStyle(size: 14, color: Brand.brown)))),
              if (r != null && r.counted) _Celebration(result: r, catalog: c.catalog),
              const SectionTitle('Around now'),
              _Nearby(classes: c.schedule, catalog: c.catalog),
            ]),
          );
        },
      );
}

class _UpperCase extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue old, TextEditingValue value) => value.copyWith(text: value.text.toUpperCase());
}

class _Celebration extends StatelessWidget {
  const _Celebration({required this.result, required this.catalog});
  final CheckInResult result;
  final Catalog catalog;
  @override
  Widget build(BuildContext context) {
    final cls = result.studioClass;
    final again = result.status == CheckInStatus.already;
    return Semantics(
      liveRegion: true,
      child: Paper(
        color: Brand.sage.withValues(alpha: .45),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.spa_outlined, color: Brand.sageDeep, size: 30),
            const SizedBox(width: 12),
            Expanded(child: Text(again ? "You're already checked in" : "You're in!", style: displayStyle(30))),
          ]),
          const SizedBox(height: 8),
          if (cls != null) Text('${catalog.className(cls.classType)} with ${cls.instructor}, ${clockLabel(cls.startsAt)}', style: bodyStyle(weight: 600)),
          const SizedBox(height: 4),
          Text(
            again ? 'This class is already counted, so there is nothing more to do.' : '${plural(result.totalClasses, 'class', 'classes')} so far${result.currentStreak > 1 ? ', ${result.currentStreak} weeks in a row' : ''}.',
            style: bodyStyle(size: 14),
          ),
          for (final b in result.newBadges)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Row(children: [
                const Icon(Icons.emoji_events_outlined, color: Brand.brown),
                const SizedBox(width: 10),
                Expanded(child: Text('New badge: ${catalog.badge(b)?.title ?? b}', style: bodyStyle(weight: 700, color: Brand.brown))),
              ]),
            ),
          for (final p in result.newPerks)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Row(children: [
                const Icon(Icons.card_giftcard_outlined, color: Brand.brown),
                const SizedBox(width: 10),
                Expanded(child: Text('You earned: ${catalog.perk(p)?.title ?? p}. Ask at the front desk to use it.', style: bodyStyle(weight: 700, color: Brand.brown))),
              ]),
            ),
        ]),
      ),
    );
  }
}

class _Nearby extends StatelessWidget {
  const _Nearby({required this.classes, required this.catalog});
  final List<StudioClass> classes;
  final Catalog catalog;
  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final open = classes.where((c) => now.isAfter(c.startsAt.subtract(const Duration(minutes: 45))) && now.isBefore(c.endsAt.add(const Duration(minutes: 30)))).toList();
    if (open.isEmpty) return const EmptyNote('No class is open for check-in right now. Check-in opens 45 minutes before a class starts.');
    return Paper(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
      child: Column(children: [
        for (final (i, c) in open.indexed) ...[
          if (i > 0) const Divider(),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Row(children: [
              Expanded(child: Text(catalog.className(c.classType), style: bodyStyle(weight: 600))),
              Text('${clockLabel(c.startsAt)} · ${c.instructor}', style: bodyStyle(size: 13, color: Brand.inkSoft)),
            ]),
          ),
        ],
      ]),
    );
  }
}

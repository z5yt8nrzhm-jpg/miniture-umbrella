/// Front-desk tools, shown only to staff: today's check-in codes, members and
/// their perks, and posts members have reported. The database refuses these
/// calls from anyone who isn't staff, so hiding the tab is a convenience, not
/// the lock.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/errors.dart';
import '../data/models.dart';
import '../state/club_controller.dart';
import 'theme.dart';
import 'widgets.dart';

class StaffScreen extends StatefulWidget {
  const StaffScreen({super.key, required this.controller});
  final ClubController controller;
  @override
  State<StaffScreen> createState() => _StaffScreenState();
}

class _StaffScreenState extends State<StaffScreen> {
  int _tab = 0;
  @override
  Widget build(BuildContext context) => PageBody(
        child: ListView(padding: const EdgeInsets.fromLTRB(20, 16, 20, 32), children: [
          Text('Front desk', style: displayStyle(40)),
          const SizedBox(height: 14),
          SegmentedButton<int>(
            showSelectedIcon: false,
            style: SegmentedButton.styleFrom(selectedBackgroundColor: Brand.sage, foregroundColor: Brand.sageDeep, textStyle: bodyStyle(size: 13, weight: 600)),
            segments: const [ButtonSegment(value: 0, label: Text('Today')), ButtonSegment(value: 1, label: Text('Members')), ButtonSegment(value: 2, label: Text('Posts'))],
            selected: {_tab},
            onSelectionChanged: (s) => setState(() => _tab = s.first),
          ),
          const SizedBox(height: 18),
          switch (_tab) {
            0 => _TodayTab(controller: widget.controller),
            1 => _MembersTab(controller: widget.controller),
            _ => _PostsTab(controller: widget.controller),
          },
        ]),
      );
}

/// Runs a staff call, turning failures into a message for the screen.
mixin _StaffCalls<T extends StatefulWidget> on State<T> {
  ClubController get c;
  String? error;
  bool loading = false;

  Future<R?> run<R>(Future<R> Function() op) async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      return await op();
    } on ClubException catch (e) {
      if (e.kind == Failure.authExpired) c.refreshAll(); // signs out if the sign-in is really gone
      if (mounted) setState(() => error = e.kind == Failure.notAllowed ? 'This account is not set up as staff.' : friendly(e));
      return null;
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }
}

class _ErrorNote extends StatelessWidget {
  const _ErrorNote(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(padding: const EdgeInsets.only(bottom: 12), child: Semantics(liveRegion: true, child: Paper(color: Brand.clay.withValues(alpha: .6), child: Text(text, style: bodyStyle(size: 14, color: Brand.brown)))));
}

// ── today ──────────────────────────────────────────────────────────────────
class _TodayTab extends StatefulWidget {
  const _TodayTab({required this.controller});
  final ClubController controller;
  @override
  State<_TodayTab> createState() => _TodayTabState();
}

class _TodayTabState extends State<_TodayTab> with _StaffCalls<_TodayTab> {
  @override
  ClubController get c => widget.controller;
  List<StaffClass>? _classes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await run(() => c.backend.staffClasses());
    if (r != null && mounted) setState(() => _classes = r);
  }

  Future<void> _add() async {
    final created = await showModalBottomSheet<bool>(
      context: context, isScrollControlled: true, backgroundColor: Brand.cream,
      builder: (context) => _AddClass(controller: c),
    );
    if (created == true) _load();
  }

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (error != null) _ErrorNote(error!),
        PrimaryButton('Add a class', icon: Icons.add, onPressed: _add),
        const SizedBox(height: 14),
        if (loading && _classes == null) const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator(color: Brand.sageDeep))),
        if (_classes != null && _classes!.isEmpty) const EmptyNote('No classes today. Add one to get its check-in code.'),
        for (final k in _classes ?? const <StaffClass>[])
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Paper(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${clockLabel(k.studioClass.startsAt)} · ${c.catalog.className(k.studioClass.classType)}', style: bodyStyle(weight: 600)),
                Text('with ${k.studioClass.instructor} · ${plural(k.checkins, 'check-in')}${k.studioClass.capacity == null ? '' : ' of ${k.studioClass.capacity}'}', style: bodyStyle(size: 13, color: Brand.inkSoft)),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(child: Semantics(label: 'Check-in code ${k.code.split('').join(' ')}', child: SelectableText(k.code, style: displayStyle(46, italic: false, weight: 700, color: Brand.brown).copyWith(letterSpacing: 10)))),
                  IconButton(
                    tooltip: 'Copy code', icon: const Icon(Icons.copy_outlined, color: Brand.sageDeep),
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: k.code));
                      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Code copied')));
                    },
                  ),
                ]),
              ]),
            ),
          ),
        Center(child: QuietButton('Refresh', onPressed: loading ? null : _load)),
      ]);
}

class _AddClass extends StatefulWidget {
  const _AddClass({required this.controller});
  final ClubController controller;
  @override
  State<_AddClass> createState() => _AddClassState();
}

class _AddClassState extends State<_AddClass> {
  String? _type;
  late DateTime _day; // a studio date, held as UTC midnight
  TimeOfDay _time = const TimeOfDay(hour: 9, minute: 0);
  int _minutes = 50;
  final _who = TextEditingController(), _cap = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final s = studioTime(DateTime.now());
    _day = DateTime.utc(s.year, s.month, s.day);
    final types = widget.controller.catalog.classTypes;
    if (types.isNotEmpty) _type = types.first.code;
  }

  @override
  void dispose() {
    _who.dispose();
    _cap.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_type == null || _who.text.trim().isEmpty) {
      setState(() => _error = 'Please choose a class type and add the instructor.');
      return;
    }
    // The date and time are in studio time (Phoenix), whatever the phone's own zone is.
    final startsAt = DateTime.utc(_day.year, _day.month, _day.day, _time.hour, _time.minute).subtract(studioUtcOffset);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.controller.backend.staffCreateClass(
        classType: _type!, startsAt: startsAt, durationMin: _minutes, instructor: _who.text.trim(), capacity: int.tryParse(_cap.text.trim()),
      );
      if (mounted) Navigator.pop(context, true);
    } on ClubException catch (e) {
      // Creating a class is never retried automatically, so the list may or may not have it.
      if (mounted) {
        setState(() => _error = e.isConnection || e.kind == Failure.server
            ? "We couldn't confirm that. Close this and check today's list before trying again, in case it went through."
            : friendly(e));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final types = widget.controller.catalog.classTypes;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          Text('Add a class', style: displayStyle(32)),
          const SizedBox(height: 14),
          DropdownButtonFormField<String>(
            initialValue: _type, decoration: const InputDecoration(labelText: 'Class'),
            items: [for (final t in types) DropdownMenuItem(value: t.code, child: Text(t.name))],
            onChanged: (v) => setState(() => _type = v),
          ),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.event_outlined), label: Text(dayLabel(DateTime.utc(_day.year, _day.month, _day.day, 12).subtract(studioUtcOffset))),
                onPressed: () async {
                  final d = await showDatePicker(context: context, initialDate: _day, firstDate: _day.subtract(const Duration(days: 1)), lastDate: _day.add(const Duration(days: 120)));
                  if (d != null) setState(() => _day = DateTime.utc(d.year, d.month, d.day));
                },
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.schedule), label: Text(_time.format(context)),
                onPressed: () async {
                  final t = await showTimePicker(context: context, initialTime: _time);
                  if (t != null) setState(() => _time = t);
                },
              ),
            ),
          ]),
          const SizedBox(height: 6),
          Text('Times are studio time (Arizona).', style: bodyStyle(size: 12, color: Brand.inkSoft)),
          const SizedBox(height: 12),
          DropdownButtonFormField<int>(
            initialValue: _minutes, decoration: const InputDecoration(labelText: 'Length'),
            items: [for (final m in const [30, 45, 50, 60, 75, 90]) DropdownMenuItem(value: m, child: Text('$m minutes'))],
            onChanged: (v) => setState(() => _minutes = v ?? 50),
          ),
          const SizedBox(height: 12),
          TextField(controller: _who, maxLength: 40, textCapitalization: TextCapitalization.words, decoration: const InputDecoration(labelText: 'Instructor', counterText: '')),
          const SizedBox(height: 12),
          TextField(controller: _cap, keyboardType: TextInputType.number, inputFormatters: [FilteringTextInputFormatter.digitsOnly], decoration: const InputDecoration(labelText: 'Spots (optional)')),
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: _ErrorNote(_error!)),
          const SizedBox(height: 16),
          PrimaryButton('Create class and code', onPressed: _save, busy: _busy),
        ]),
      ),
    );
  }
}

// ── members ────────────────────────────────────────────────────────────────
class _MembersTab extends StatefulWidget {
  const _MembersTab({required this.controller});
  final ClubController controller;
  @override
  State<_MembersTab> createState() => _MembersTabState();
}

class _MembersTabState extends State<_MembersTab> with _StaffCalls<_MembersTab> {
  @override
  ClubController get c => widget.controller;
  final _number = TextEditingController();
  MemberLookup? _member;
  String? _notFound;

  @override
  void dispose() {
    _number.dispose();
    super.dispose();
  }

  Future<void> _find() async {
    final n = int.tryParse(_number.text.trim());
    if (n == null) return;
    FocusScope.of(context).unfocus();
    final r = await run(() => c.backend.staffLookup(n));
    if (r != null && mounted) {
      setState(() {
        _member = r.found ? r : null;
        _notFound = r.found ? null : 'No member has the number $n.';
      });
    }
  }

  Future<void> _redeem(LookupPerk p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Brand.paper,
        title: Text('Redeem "${p.title}"?', style: displayStyle(26, italic: false, weight: 600)),
        content: Text('This marks it as used for ${_member!.displayName}. It can\'t be undone.', style: bodyStyle(size: 14)),
        actions: [QuietButton('Cancel', onPressed: () => Navigator.pop(context, false)), QuietButton('Redeem', onPressed: () => Navigator.pop(context, true))],
      ),
    );
    if (ok != true) return;
    final status = await run(() => c.backend.staffRedeem(p.id));
    if (status == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(switch (status) {
      'ok' => 'Redeemed.',
      'already_redeemed' => 'That perk was already redeemed.',
      _ => 'That perk was not found.',
    })));
    _find();
  }

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: TextField(controller: _number, keyboardType: TextInputType.number, inputFormatters: [FilteringTextInputFormatter.digitsOnly], onSubmitted: (_) => _find(), decoration: const InputDecoration(labelText: 'Member number'))),
          const SizedBox(width: 10),
          SizedBox(height: 56, child: FilledButton(onPressed: loading ? null : _find, style: FilledButton.styleFrom(backgroundColor: Brand.sageDeep, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))), child: const Text('Find'))),
        ]),
        const SizedBox(height: 14),
        if (error != null) _ErrorNote(error!),
        if (_notFound != null) EmptyNote(_notFound!),
        if (_member != null)
          Paper(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_member!.displayName, style: displayStyle(30)),
              Text('No. ${_member!.memberNumber} · ${plural(_member!.totalClasses, 'class', 'classes')} · ${_member!.currentStreak}-week streak', style: bodyStyle(size: 13, color: Brand.inkSoft)),
              const SizedBox(height: 14),
              if (_member!.perks.isEmpty) Text('No perks earned yet.', style: bodyStyle(size: 14, color: Brand.inkSoft)),
              for (final p in _member!.perks)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(children: [
                    Expanded(child: Text(p.title, style: bodyStyle(weight: 600))),
                    if (p.redeemed) Text('Redeemed ${dayLabel(p.redeemedAt!)}', style: bodyStyle(size: 13, color: Brand.inkSoft)) else FilledButton(onPressed: loading ? null : () => _redeem(p), style: FilledButton.styleFrom(backgroundColor: Brand.terracottaText, minimumSize: const Size(48, 44)), child: const Text('Redeem')),
                  ]),
                ),
            ]),
          ),
      ]);
}

// ── posts ──────────────────────────────────────────────────────────────────
class _PostsTab extends StatefulWidget {
  const _PostsTab({required this.controller});
  final ClubController controller;
  @override
  State<_PostsTab> createState() => _PostsTabState();
}

class _PostsTabState extends State<_PostsTab> with _StaffCalls<_PostsTab> {
  @override
  ClubController get c => widget.controller;
  List<FlaggedPost>? _posts;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await run(() => c.backend.staffFlagged());
    if (r != null && mounted) setState(() => _posts = r);
  }

  Future<void> _set(FlaggedPost p, bool hidden) async {
    await run(() => c.backend.staffSetHidden(p.id, hidden));
    await _load();
  }

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (error != null) _ErrorNote(error!),
        if (loading && _posts == null) const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator(color: Brand.sageDeep))),
        if (_posts != null && _posts!.isEmpty) const EmptyNote('Nothing reported. All quiet on the wall.'),
        for (final p in _posts ?? const <FlaggedPost>[])
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Paper(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: Text(p.authorName, style: bodyStyle(weight: 600))),
                  Text('${plural(p.reports, 'report')}${p.hidden ? ' · hidden' : ''}', style: bodyStyle(size: 12.5, color: Brand.terracottaText, weight: 600)),
                ]),
                const SizedBox(height: 8),
                Text(p.body, style: bodyStyle()),
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerRight,
                  child: p.hidden ? OutlinedButton(onPressed: loading ? null : () => _set(p, false), child: const Text('Put back')) : FilledButton(onPressed: loading ? null : () => _set(p, true), style: FilledButton.styleFrom(backgroundColor: Brand.danger), child: const Text('Hide')),
                ),
              ]),
            ),
          ),
        Center(child: QuietButton('Refresh', onPressed: loading ? null : _load)),
      ]);
}

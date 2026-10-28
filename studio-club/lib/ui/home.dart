/// Home: the member card, progress, badges, perks and what's coming up.
library;

import 'package:flutter/material.dart';

import '../data/models.dart';
import '../links.dart';
import '../state/club_controller.dart';
import 'theme.dart';
import 'widgets.dart';

IconData badgeIcon(BadgeDef b) => b.isStreak ? Icons.local_fire_department_outlined : (b.threshold == 1 ? Icons.spa_outlined : Icons.local_florist_outlined);

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.controller});
  final ClubController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller, stats = c.stats;
    if (stats?.profile == null) return const Center(child: CircularProgressIndicator(color: Brand.sageDeep));
    final profile = stats!.profile!;
    final now = DateTime.now();
    return RefreshIndicator(
      color: Brand.sageDeep,
      onRefresh: c.refreshAll,
      child: PageBody(
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
          children: [
            if (c.offline) OfflineBanner(onRetry: c.refreshAll, lastSynced: c.lastSynced),
            const SizedBox(height: 8),
            Text('${greeting(now)},', style: bodyStyle(color: Brand.inkSoft)),
            Text(profile.displayName, style: displayStyle(40)),
            const SizedBox(height: 18),
            _MemberCard(profile: profile),
            const SectionTitle('Your progress'),
            _Progress(stats: stats, catalog: c.catalog),
            const SectionTitle('Badges'),
            _Badges(stats: stats, catalog: c.catalog),
            const SectionTitle('Perks'),
            _Perks(stats: stats, catalog: c.catalog),
            const SectionTitle('Coming up'),
            _Schedule(classes: c.schedule, catalog: c.catalog),
            const SizedBox(height: 12),
            PrimaryButton('Book a class', icon: Icons.event_available_outlined, onPressed: () => openSchedule(context)),
            if (c.history.isNotEmpty) ...[
              const SectionTitle('Recent classes'),
              Paper(
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
                child: Column(children: [
                  for (final (i, h) in c.history.take(6).indexed) ...[
                    if (i > 0) const Divider(),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Row(children: [
                        Expanded(child: Text(c.catalog.className(h.classType), style: bodyStyle(weight: 600))),
                        Text('${dayLabel(h.startsAt)} · ${h.instructor}', style: bodyStyle(size: 13, color: Brand.inkSoft)),
                      ]),
                    ),
                  ],
                ]),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _MemberCard extends StatelessWidget {
  const _MemberCard({required this.profile});
  final Profile profile;
  @override
  Widget build(BuildContext context) => Semantics(
        container: true,
        label: 'Member card. ${profile.displayName}. Member number ${profile.memberNumber}.',
        child: Container(
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            gradient: const LinearGradient(colors: [Brand.sage, Color(0xFFD8DFD2)], begin: Alignment.topLeft, end: Alignment.bottomRight),
          ),
          child: ExcludeSemantics(
            child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('MEMBER', style: labelStyle(color: Brand.brown.withValues(alpha: .8))),
                  const SizedBox(height: 22),
                  Text(profile.displayName, style: displayStyle(32, color: Brand.brown), maxLines: 1, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 4),
                  Text('No. ${profile.memberNumber}${profile.memberSince == null ? '' : '  ·  Since ${monthYear(profile.memberSince!)}'}', style: bodyStyle(size: 13, color: Brand.brown, weight: 500)),
                ]),
              ),
              const LogoMark(size: 68),
            ]),
          ),
        ),
      );
}

class _Progress extends StatelessWidget {
  const _Progress({required this.stats, required this.catalog});
  final MemberStats stats;
  final Catalog catalog;

  @override
  Widget build(BuildContext context) {
    final next = catalog.badges.where((b) => !b.isStreak && b.threshold > stats.totalClasses).toList();
    final target = next.isEmpty ? null : next.first;
    return Paper(
      child: Column(children: [
        Row(children: [
          _Stat(value: '${stats.totalClasses}', label: stats.totalClasses == 1 ? 'class' : 'classes'),
          _Stat(value: '${stats.currentStreak}', label: stats.currentStreak == 1 ? 'week streak' : 'week streak', highlight: stats.currentStreak > 0),
          _Stat(value: '${stats.classesThisWeek}', label: 'this week'),
        ]),
        if (target != null) ...[
          const SizedBox(height: 18),
          Builder(builder: (context) {
            final prev = catalog.badges.where((b) => !b.isStreak && b.threshold <= stats.totalClasses).fold<int>(0, (m, b) => b.threshold > m ? b.threshold : m);
            final span = target.threshold - prev, done = stats.totalClasses - prev;
            return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${plural(target.threshold - stats.totalClasses, 'class', 'classes')} to ${target.title}', style: bodyStyle(size: 13.5, weight: 600)),
              const SizedBox(height: 8),
              Semantics(
                label: 'Progress to ${target.title}: ${stats.totalClasses} of ${target.threshold} classes',
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(value: span <= 0 ? 0 : (done / span).clamp(0.0, 1.0), minHeight: 10, backgroundColor: Brand.line, color: Brand.sageMid),
                ),
              ),
            ]);
          }),
        ],
        if (stats.currentStreak > 0 || stats.longestStreak > 0) ...[
          const SizedBox(height: 14),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              stats.currentStreak == 0
                  ? 'Your best streak was ${plural(stats.longestStreak, 'week')}. Come to a class this week to start a new one.'
                  : 'Your best streak is ${plural(stats.longestStreak, 'week')}. Any one class a week keeps it going.',
              style: bodyStyle(size: 13, color: Brand.inkSoft),
            ),
          ),
        ],
      ]),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label, this.highlight = false});
  final String value, label;
  final bool highlight;
  @override
  Widget build(BuildContext context) => Expanded(
        child: Semantics(
          label: '$value $label', excludeSemantics: true,
          child: Column(children: [
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              if (highlight) const Padding(padding: EdgeInsets.only(right: 4), child: Icon(Icons.local_fire_department, size: 22, color: Brand.terracotta)),
              Text(value, style: displayStyle(40, italic: false, weight: 600)),
            ]),
            Text(label, style: bodyStyle(size: 12.5, color: Brand.inkSoft)),
          ]),
        ),
      );
}

class _Badges extends StatelessWidget {
  const _Badges({required this.stats, required this.catalog});
  final MemberStats stats;
  final Catalog catalog;
  @override
  Widget build(BuildContext context) {
    if (catalog.badges.isEmpty) return const EmptyNote('Badges will appear here.');
    return Wrap(spacing: 10, runSpacing: 10, children: [
      for (final b in catalog.badges)
        () {
          final earned = stats.hasBadge(b.code);
          return Semantics(
            label: '${b.title}. ${earned ? 'Earned.' : 'Locked.'} ${b.blurb}', excludeSemantics: true,
            child: Container(
              width: 104, padding: const EdgeInsets.fromLTRB(8, 14, 8, 12),
              decoration: BoxDecoration(color: earned ? Brand.gold.withValues(alpha: .45) : Brand.paper, borderRadius: BorderRadius.circular(18), border: Border.all(color: earned ? Brand.gold : Brand.line)),
              child: Column(children: [
                Icon(badgeIcon(b), size: 30, color: earned ? Brand.brown : Brand.inkSoft.withValues(alpha: .6)),
                const SizedBox(height: 8),
                Text(b.title, textAlign: TextAlign.center, style: bodyStyle(size: 12, weight: 600, color: earned ? Brand.brown : Brand.inkSoft), maxLines: 2),
                const SizedBox(height: 2),
                Text(earned ? 'Earned' : (b.isStreak ? '${b.threshold} weeks' : '${b.threshold} ${b.threshold == 1 ? 'class' : 'classes'}'), style: bodyStyle(size: 11, color: Brand.inkSoft)),
              ]),
            ),
          );
        }(),
    ]);
  }
}

class _Perks extends StatelessWidget {
  const _Perks({required this.stats, required this.catalog});
  final MemberStats stats;
  final Catalog catalog;
  @override
  Widget build(BuildContext context) {
    if (catalog.perks.isEmpty) return const EmptyNote('Rewards will appear here.');
    return Column(children: [
      for (final p in catalog.perks)
        () {
          final got = stats.perks.where((x) => x.code == p.code).firstOrNull;
          final status = got == null
              ? 'Unlocks at ${p.requiredClasses} classes (${plural((p.requiredClasses - stats.totalClasses).clamp(0, 9999), 'to go', 'to go')})'
              : (got.redeemed ? 'Redeemed ${dayLabel(got.redeemedAt!)}' : 'Earned. Show this screen at the front desk.');
          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Paper(
              color: got != null && !got.redeemed ? Brand.sage.withValues(alpha: .35) : Brand.paper,
              child: Row(children: [
                Icon(got == null ? Icons.lock_outline : (got.redeemed ? Icons.check_circle_outline : Icons.card_giftcard_outlined), color: got == null ? Brand.inkSoft : Brand.sageDeep),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(p.title, style: bodyStyle(weight: 600)),
                    Text(p.blurb, style: bodyStyle(size: 13, color: Brand.inkSoft)),
                    const SizedBox(height: 4),
                    Text(status, style: bodyStyle(size: 12.5, weight: 600, color: got != null && !got.redeemed ? Brand.sageDeep : Brand.terracottaText)),
                  ]),
                ),
              ]),
            ),
          );
        }(),
    ]);
  }
}

class _Schedule extends StatelessWidget {
  const _Schedule({required this.classes, required this.catalog});
  final List<StudioClass> classes;
  final Catalog catalog;
  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final upcoming = classes.where((c) => c.endsAt.isAfter(now)).take(6).toList();
    if (upcoming.isEmpty) return const EmptyNote('No classes are scheduled yet. Check back soon.');
    return Paper(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
      child: Column(children: [
        for (final (i, c) in upcoming.indexed) ...[
          if (i > 0) const Divider(),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Row(children: [
              SizedBox(
                width: 92,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(dayLabel(c.startsAt), style: bodyStyle(size: 12, color: Brand.terracottaText, weight: 600)),
                  Text(clockLabel(c.startsAt), style: bodyStyle(weight: 600)),
                ]),
              ),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(catalog.className(c.classType), style: bodyStyle(weight: 600)),
                  Text('with ${c.instructor}', style: bodyStyle(size: 13, color: Brand.inkSoft)),
                ]),
              ),
            ]),
          ),
        ],
      ]),
    );
  }
}

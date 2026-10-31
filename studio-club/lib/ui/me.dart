/// Me: your profile, what the club keeps, and signing out.
library;

import 'package:flutter/material.dart';

import '../data/errors.dart';
import '../state/club_controller.dart';
import 'sign_in.dart';
import 'theme.dart';
import 'widgets.dart';

class MeScreen extends StatefulWidget {
  const MeScreen({super.key, required this.controller, this.demo = false});
  final ClubController controller;
  final bool demo;
  @override
  State<MeScreen> createState() => _MeScreenState();
}

class _MeScreenState extends State<MeScreen> {
  bool _deleting = false;
  ClubController get c => widget.controller;

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Brand.paper,
        title: Text('Delete your account?', style: displayStyle(26, italic: false, weight: 600)),
        content: Text('This permanently removes your sign-in, your classes, badges, perks and everything you shared on the wall. It can\'t be undone.', style: bodyStyle(size: 14)),
        actions: [
          QuietButton('Keep my account', onPressed: () => Navigator.pop(context, false)),
          QuietButton('Delete everything', danger: true, onPressed: () => Navigator.pop(context, true)),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _deleting = true);
    try {
      await c.deleteAccount();
    } on ClubException catch (e) {
      if (mounted) {
        setState(() => _deleting = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${friendly(e)} Your account was not deleted.')));
      }
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: c,
        builder: (context, _) {
          final p = c.stats?.profile;
          return PageBody(
            child: ListView(padding: const EdgeInsets.fromLTRB(20, 16, 20, 32), children: [
              if (c.offline) OfflineBanner(onRetry: c.refreshAll, lastSynced: c.lastSynced),
              Text('Me', style: displayStyle(40)),
              const SizedBox(height: 16),
              if (p != null)
                Paper(
                  child: Row(children: [
                    AvatarDot(p.displayName, avatar: p.avatar, size: 52),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(p.displayName, style: bodyStyle(size: 17, weight: 600)),
                        Text('Member No. ${p.memberNumber}', style: bodyStyle(size: 13, color: Brand.inkSoft)),
                        if (p.favoriteClass != null) Text('Favourite: ${p.favoriteClass}', style: bodyStyle(size: 13, color: Brand.inkSoft)),
                      ]),
                    ),
                    QuietButton('Edit', onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ProfileScreen(controller: c, editing: true)))),
                  ]),
                ),
              const SectionTitle('Your privacy'),
              Paper(
                child: Text(
                  'The club keeps your email, your name, the classes you check in to, and what you share on the wall. Other members see only your name and colour next to your posts. Never your email, member number or class history. You can delete your account and everything with it at any time.',
                  style: bodyStyle(size: 14),
                ),
              ),
              if (widget.demo) ...[
                const SizedBox(height: 14),
                Paper(color: Brand.gold.withValues(alpha: .35), child: Text('Demo mode: sample data on this device only.', style: bodyStyle(size: 13, color: Brand.brown))),
              ],
              const SizedBox(height: 28),
              PrimaryButton('Sign out', onPressed: c.signOut),
              const SizedBox(height: 8),
              Center(child: QuietButton(_deleting ? 'Deleting…' : 'Delete my account', danger: true, onPressed: _deleting ? null : _delete)),
              const SizedBox(height: 16),
              Center(child: Text('Gilbert Flex Studio', style: displayStyle(18, color: Brand.inkSoft))),
            ]),
          );
        },
      );
}

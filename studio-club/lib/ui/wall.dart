/// The community wall: share a win, cheer someone on.
library;

import 'package:flutter/material.dart';

import '../data/models.dart';
import '../state/club_controller.dart';
import 'theme.dart';
import 'widgets.dart';

String timeAgo(DateTime t, DateTime now) {
  final d = now.difference(t);
  if (d.inSeconds < 60) return 'Just now';
  if (d.inMinutes < 60) return '${d.inMinutes}m ago';
  if (d.inHours < 24) return '${d.inHours}h ago';
  return '${dayLabel(t, now: now)}, ${clockLabel(t)}';
}

class WallScreen extends StatefulWidget {
  const WallScreen({super.key, required this.controller});
  final ClubController controller;
  @override
  State<WallScreen> createState() => _WallScreenState();
}

class _WallScreenState extends State<WallScreen> {
  final _text = TextEditingController();
  final _scroll = ScrollController();

  ClubController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 600) c.loadMoreWall();
    });
  }

  @override
  void dispose() {
    _text.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _share() async {
    final body = _text.text;
    if (body.trim().isEmpty) return;
    _text.clear();
    FocusScope.of(context).unfocus();
    await c.post(body);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: c,
        builder: (context, _) {
          final now = DateTime.now();
          return RefreshIndicator(
            color: Brand.sageDeep,
            onRefresh: () async {
              await c.refreshWall();
              await c.flushPending();
            },
            child: PageBody(
              child: ListView.builder(
                controller: _scroll,
                physics: const AlwaysScrollableScrollPhysics(),
                keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
                itemCount: 2 + c.pending.length + c.wall.length + 1,
                itemBuilder: (context, i) {
                  if (i == 0) {
                    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      if (c.offline) OfflineBanner(onRetry: c.refreshAll, lastSynced: c.lastSynced),
                      Semantics(container: true, header: true, child: Text('The wall', style: displayStyle(40))),
                      const SizedBox(height: 6),
                      Semantics(container: true, child: Text('Share a win or a kind word. Please keep it friendly, and leave out health details and anyone else\'s private information.', style: bodyStyle(color: Brand.inkSoft, size: 14))),
                      const SizedBox(height: 16),
                      Semantics(container: true, child: _Composer(controller: _text, onShare: _share)),
                      const SizedBox(height: 18),
                    ]);
                  }
                  var k = i - 1;
                  if (k < c.pending.length) return _PendingCard(post: c.pending[k], offline: c.offline);
                  k -= c.pending.length;
                  if (k < c.wall.length) {
                    final p = c.wall[k];
                    return _PostCard(key: ValueKey(p.id), post: p, now: now, onCheer: () => c.cheer(p), onReport: () => _confirmReport(p));
                  }
                  // the last row
                  if (c.wallLoading) return const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator(color: Brand.sageDeep, strokeWidth: 2.6)));
                  if (!c.wallLoaded && c.wall.isEmpty) return const EmptyNote("Can't load the wall right now. Pull down to try again.");
                  if (c.wall.isEmpty && c.pending.isEmpty) return const EmptyNote('Nothing here yet. Be the first to share something.');
                  if (c.wallHasMore) return Center(child: QuietButton('Show older posts', onPressed: c.loadMoreWall));
                  return const SizedBox(height: 8);
                },
              ),
            ),
          );
        },
      );

  Future<void> _confirmReport(WallPost p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Brand.paper,
        title: Text('Report this post?', style: displayStyle(26, italic: false, weight: 600)),
        content: Text('It will be hidden for you right away, and the studio team will take a look.', style: bodyStyle(size: 14)),
        actions: [
          QuietButton('Cancel', onPressed: () => Navigator.pop(context, false)),
          QuietButton('Report', danger: true, onPressed: () => Navigator.pop(context, true)),
        ],
      ),
    );
    if (ok == true) await c.report(p);
  }
}

class _Composer extends StatelessWidget {
  const _Composer({required this.controller, required this.onShare});
  final TextEditingController controller;
  final VoidCallback onShare;
  @override
  Widget build(BuildContext context) => Paper(
        child: ValueListenableBuilder<TextEditingValue>(
          valueListenable: controller,
          builder: (context, v, _) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            TextField(
              controller: controller, minLines: 2, maxLines: 6, maxLength: 500, textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(hintText: 'What went well today?', counterText: '', filled: false, border: InputBorder.none, enabledBorder: InputBorder.none, focusedBorder: InputBorder.none, contentPadding: EdgeInsets.zero),
            ),
            const SizedBox(height: 10),
            Row(children: [
              Text('${v.text.length}/500', style: bodyStyle(size: 12, color: v.text.length > 470 ? Brand.danger : Brand.inkSoft)),
              const Spacer(),
              SizedBox(
                height: 44,
                child: FilledButton(
                  onPressed: v.text.trim().isEmpty ? null : onShare,
                  style: FilledButton.styleFrom(backgroundColor: Brand.sageDeep, foregroundColor: Brand.cream, disabledBackgroundColor: Brand.sage.withValues(alpha: .6), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)), padding: const EdgeInsets.symmetric(horizontal: 22)),
                  child: Text('Share', style: bodyStyle(weight: 600, color: Brand.cream)),
                ),
              ),
            ]),
          ]),
        ),
      );
}

class _PendingCard extends StatelessWidget {
  const _PendingCard({required this.post, required this.offline});
  final PendingPost post;
  final bool offline;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Paper(
          color: Brand.gold.withValues(alpha: .25),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(post.body, style: bodyStyle()),
            const SizedBox(height: 10),
            Row(children: [
              if (!offline) const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Brand.brown)) else const Icon(Icons.schedule, size: 16, color: Brand.brown),
              const SizedBox(width: 8),
              Expanded(child: Text(offline ? "Saved on your phone. We'll share it when you're back online." : 'Sending…', style: bodyStyle(size: 12.5, color: Brand.brown, weight: 500))),
            ]),
          ]),
        ),
      );
}

class _PostCard extends StatelessWidget {
  const _PostCard({super.key, required this.post, required this.now, required this.onCheer, required this.onReport});
  final WallPost post;
  final DateTime now;
  final VoidCallback onCheer, onReport;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Semantics(
         container: true,
         child: Paper(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              AvatarDot(post.authorName, avatar: post.authorAvatar),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(post.isMine ? '${post.authorName} (you)' : post.authorName, style: bodyStyle(weight: 600)),
                  Text(timeAgo(post.createdAt, now), style: bodyStyle(size: 12.5, color: Brand.inkSoft)),
                ]),
              ),
              if (!post.isMine)
                PopupMenuButton<String>(
                  tooltip: 'More options', icon: const Icon(Icons.more_horiz, color: Brand.inkSoft), color: Brand.paper,
                  onSelected: (_) => onReport(),
                  itemBuilder: (context) => [PopupMenuItem(value: 'report', child: Text('Report this post', style: bodyStyle(size: 14)))],
                ),
            ]),
            const SizedBox(height: 12),
            Text(post.body, style: bodyStyle()),
            const SizedBox(height: 8),
            Semantics(
              container: true, button: true, toggled: post.cheeredByMe, label: post.cheeredByMe ? 'Cheered. ${plural(post.cheers, 'cheer')}. Tap to take back.' : 'Cheer. ${plural(post.cheers, 'cheer')}',
              excludeSemantics: true,
              child: InkWell(
                borderRadius: BorderRadius.circular(24),
                onTap: onCheer,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(post.cheeredByMe ? Icons.favorite : Icons.favorite_border, size: 22, color: post.cheeredByMe ? Brand.terracotta : Brand.inkSoft),
                      const SizedBox(width: 8),
                      Text(post.cheers == 0 ? 'Cheer' : plural(post.cheers, 'cheer'), style: bodyStyle(size: 13.5, weight: 600, color: post.cheeredByMe ? Brand.terracottaText : Brand.inkSoft)),
                    ]),
                  ),
                ),
              ),
            ),
          ]),
        ),
         ),
      );
}

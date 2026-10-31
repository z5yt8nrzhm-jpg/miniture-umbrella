/// Small pieces used on every screen.
library;

import 'package:flutter/material.dart';

import '../data/models.dart';
import 'theme.dart';

/// The studio logo, clipped to its circle so the square background never shows.
class LogoMark extends StatelessWidget {
  const LogoMark({super.key, this.size = 96});
  final double size;
  @override
  Widget build(BuildContext context) => Semantics(
        label: 'Gilbert Flex Studio',
        image: true,
        child: ClipOval(child: Image.asset('assets/images/logo.png', width: size, height: size, fit: BoxFit.cover, filterQuality: FilterQuality.medium)),
      );
}

/// A soft cream card.
class Paper extends StatelessWidget {
  const Paper({super.key, required this.child, this.padding = const EdgeInsets.all(18), this.color = Brand.paper, this.onTap});
  final Widget child;
  final EdgeInsets padding;
  final Color color;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final box = Container(
      padding: padding,
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(20), border: Border.all(color: Brand.line)),
      child: child,
    );
    return onTap == null ? box : InkWell(borderRadius: BorderRadius.circular(20), onTap: onTap, child: box);
  }
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.label, {super.key, this.trailing});
  final String label;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 28, 4, 10),
        child: Row(children: [
          Expanded(child: Semantics(header: true, child: Text(label.toUpperCase(), style: labelStyle()))),
          ?trailing,
        ]),
      );
}

class PrimaryButton extends StatelessWidget {
  const PrimaryButton(this.label, {super.key, required this.onPressed, this.busy = false, this.icon});
  final String label;
  final VoidCallback? onPressed;
  final bool busy;
  final IconData? icon;
  @override
  Widget build(BuildContext context) => SizedBox(
        width: double.infinity,
        height: 54,
        child: FilledButton(
          onPressed: busy ? null : onPressed,
          style: FilledButton.styleFrom(
            backgroundColor: Brand.sageDeep, foregroundColor: Brand.cream, disabledBackgroundColor: Brand.sage, disabledForegroundColor: Brand.sageDeep,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            textStyle: bodyStyle(size: 15, weight: 600),
          ),
          child: busy
              ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4, color: Brand.sageDeep))
              : Row(mainAxisAlignment: MainAxisAlignment.center, mainAxisSize: MainAxisSize.min, children: [
                  if (icon != null) ...[Icon(icon, size: 20), const SizedBox(width: 8)],
                  Text(label),
                ]),
        ),
      );
}

class QuietButton extends StatelessWidget {
  const QuietButton(this.label, {super.key, required this.onPressed, this.danger = false});
  final String label;
  final VoidCallback? onPressed;
  final bool danger;
  @override
  Widget build(BuildContext context) => TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(minimumSize: const Size(48, 48), foregroundColor: danger ? Brand.danger : Brand.sageDeep, textStyle: bodyStyle(weight: 600, size: 14)),
        child: Text(label),
      );
}

class AvatarDot extends StatelessWidget {
  const AvatarDot(this.name, {super.key, this.avatar = 'sage', this.size = 40});
  final String name, avatar;
  final double size;
  @override
  Widget build(BuildContext context) => ExcludeSemantics(
        child: Container(
          width: size, height: size, alignment: Alignment.center,
          decoration: BoxDecoration(color: Brand.avatarColors[avatar] ?? Brand.sage, shape: BoxShape.circle),
          child: Text(name.isEmpty ? '?' : name.characters.first.toUpperCase(), style: displayStyle(size * .55, color: Brand.brown, italic: false, weight: 600)),
        ),
      );
}

/// Shown at the top of a screen when the club can't be reached.
class OfflineBanner extends StatelessWidget {
  const OfflineBanner({super.key, required this.onRetry, this.lastSynced});
  final VoidCallback onRetry;
  final DateTime? lastSynced;
  @override
  Widget build(BuildContext context) => Semantics(
        liveRegion: true,
        child: Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.fromLTRB(16, 10, 6, 10),
          decoration: BoxDecoration(color: Brand.clay, borderRadius: BorderRadius.circular(14)),
          child: Row(children: [
            const Icon(Icons.cloud_off_outlined, size: 20, color: Brand.brown),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                lastSynced == null ? "Can't reach the club. We'll keep trying." : "Can't reach the club. Showing what we saved at ${clockLabel(lastSynced!)}.",
                style: bodyStyle(size: 13, color: Brand.brown, weight: 500),
              ),
            ),
            TextButton(onPressed: onRetry, style: TextButton.styleFrom(minimumSize: const Size(48, 48)), child: Text('Retry', style: bodyStyle(size: 13, weight: 700, color: Brand.brown))),
          ]),
        ),
      );
}

class EmptyNote extends StatelessWidget {
  const EmptyNote(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Padding(padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 4), child: Text(text, style: bodyStyle(color: Brand.inkSoft, size: 14)));
}

/// A page body that stays a comfortable width on tablets and in a browser.
class PageBody extends StatelessWidget {
  const PageBody({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Align(alignment: Alignment.topCenter, child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 560), child: child));
}

String greeting(DateTime now) {
  final h = studioTime(now).hour;
  return h < 12 ? 'Good morning' : (h < 17 ? 'Good afternoon' : 'Good evening');
}

String plural(int n, String one, [String? many]) => '$n ${n == 1 ? one : (many ?? '${one}s')}';

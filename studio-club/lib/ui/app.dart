/// The app itself: which screen to show, and notices.
library;

import 'package:flutter/material.dart';

import '../state/club_controller.dart';
import 'shell.dart';
import 'sign_in.dart';
import 'theme.dart';
import 'widgets.dart';

class ClubApp extends StatefulWidget {
  const ClubApp({super.key, required this.controller, this.demo = false});
  final ClubController controller;
  final bool demo;
  @override
  State<ClubApp> createState() => _ClubAppState();
}

class _ClubAppState extends State<ClubApp> with WidgetsBindingObserver {
  final _messenger = GlobalKey<ScaffoldMessengerState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.controller.addListener(_showNotice);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_showNotice);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// The phone came back to the front: catch up.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) widget.controller.onResume();
  }

  void _showNotice() {
    final text = widget.controller.notice;
    if (text == null) return;
    widget.controller.clearNotice();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _messenger.currentState
        ?..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 5)));
    });
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Gilbert Flex Club',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        scaffoldMessengerKey: _messenger,
        home: ListenableBuilder(
          listenable: widget.controller,
          builder: (context, _) => switch (widget.controller.phase) {
            Phase.booting => const _Splash(),
            Phase.signedOut => SignInScreen(controller: widget.controller, demo: widget.demo),
            Phase.unreachable => _Unreachable(controller: widget.controller),
            Phase.needsProfile => ProfileScreen(controller: widget.controller),
            Phase.ready => ClubShell(controller: widget.controller, demo: widget.demo),
          },
        ),
      );
}

class _Splash extends StatelessWidget {
  const _Splash();
  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const LogoMark(size: 104),
            const SizedBox(height: 24),
            const SizedBox(width: 26, height: 26, child: CircularProgressIndicator(strokeWidth: 2.6, color: Brand.sageDeep)),
          ]),
        ),
      );
}

/// Signed in, but the club can't be reached and nothing is saved yet.
class _Unreachable extends StatelessWidget {
  const _Unreachable({required this.controller});
  final ClubController controller;
  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: PageBody(
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const LogoMark(size: 92),
                const SizedBox(height: 24),
                Text("Can't reach the club", style: displayStyle(36), textAlign: TextAlign.center),
                const SizedBox(height: 10),
                Text("Check your connection. You're still signed in, and we'll keep trying.", style: bodyStyle(color: Brand.inkSoft), textAlign: TextAlign.center),
                const SizedBox(height: 28),
                PrimaryButton('Try again', onPressed: controller.refreshAll),
                const SizedBox(height: 8),
                QuietButton('Sign out', onPressed: controller.signOut),
              ]),
            ),
          ),
        ),
      );
}

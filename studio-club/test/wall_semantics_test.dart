// What a screen reader gets on the wall: the post text and a Cheer button.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gilbert_flex_club/ui/wall.dart';

import 'controller_test.dart' show start;

void main() {
  testWidgets('wall posts can be read and cheered by a screen reader', (tester) async {
    final handle = tester.ensureSemantics();
    tester.view.physicalSize = const Size(412 * 2, 915 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final rig = await tester.runAsync(() => start());
    final c = rig!.c;
    await tester.runAsync(() => c.post('hello from the test'));
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: WallScreen(controller: c))));
    await tester.pump();

    expect(find.bySemanticsLabel(RegExp('hello from the test')), findsWidgets);
    expect(find.bySemanticsLabel(RegExp('The wall')), findsWidgets);
    expect(find.semantics.byLabel(RegExp(r'^Cheer')), findsWidgets);
    handle.dispose();
  });
}

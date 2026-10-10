import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hyouka_cast/main.dart';

void main() {
  testWidgets('phone UI only offers casting to a TV', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const HyoukaCastApp());
    await tester.pumpAndSettle();

    expect(find.text('Hyouka Cast'), findsOneWidget);
    expect(find.text('Mirror your phone'), findsOneWidget);
    expect(find.text('CONNECT & SHARE'), findsOneWidget);
    expect(find.text('TV RECEIVER'), findsNothing);
    expect(find.text('PHONE  →  TV'), findsNothing);

    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
    final theme = Theme.of(tester.element(find.byType(Scaffold).first));
    expect(scaffold.backgroundColor ?? theme.scaffoldBackgroundColor,
        const Color(0xFF000000));
  });
}

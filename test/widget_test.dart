import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hyouka_cast/main.dart';

void main() {
  testWidgets('renders pure-black Hyouka Cast UI', (tester) async {
    await tester.pumpWidget(const HyoukaCastApp());
    await tester.pump();
    expect(find.text('Hyouka Cast'), findsOneWidget);
    expect(find.text('PHONE  →  TV'), findsOneWidget);
    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
    expect(scaffold.backgroundColor, const Color(0xFF000000));
  });
}

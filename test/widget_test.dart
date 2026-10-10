import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hyouka_cast/main.dart';

const _castPlatform = MethodChannel('cast_android');

void _mockDeviceRole({required bool isTv}) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_castPlatform, (call) async {
    if (call.method == 'isTvDevice') return isTv;
    throw MissingPluginException('No handler for ${call.method}');
  });
}

void _setScreenSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_castPlatform, null);
  });

  testWidgets('phone UI offers phone-to-TV casting only', (tester) async {
    _mockDeviceRole(isTv: false);
    _setScreenSize(tester, const Size(320, 640));

    await tester.pumpWidget(const HyoukaCastApp());
    await tester.pumpAndSettle();

    expect(find.text('Hyouka Cast'), findsOneWidget);
    expect(find.text('Mirror your phone'), findsOneWidget);
    expect(find.text('CONNECT & SHARE'), findsOneWidget);
    expect(find.text('Up to 1280 × 720 / 60 fps, hardware permitting'), findsOneWidget);
    expect(find.text('Live video stats'), findsOneWidget);
    expect(find.text('Waiting for stream stats…'), findsOneWidget);
    expect(find.text('START TV RECEIVER'), findsNothing);
    expect(find.text('TV receiver'), findsNothing);
    expect(find.text('PHONE  →  TV'), findsNothing);

    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
    final theme = Theme.of(tester.element(find.byType(Scaffold).first));
    expect(scaffold.backgroundColor ?? theme.scaffoldBackgroundColor,
        const Color(0xFF000000));
    expect(tester.takeException(), isNull);
  });

  testWidgets('TV UI exposes receiver controls without phone sender controls',
      (tester) async {
    _mockDeviceRole(isTv: true);
    _setScreenSize(tester, const Size(1280, 720));

    await tester.pumpWidget(const HyoukaCastApp());
    await tester.pumpAndSettle();

    expect(find.text('TV receiver'), findsOneWidget);
    expect(find.text('START TV RECEIVER'), findsOneWidget);
    expect(find.text('Mirror your phone'), findsNothing);
    expect(find.text('CONNECT & SHARE'), findsNothing);
    expect(find.byType(TextField), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('rejects a public IPv4 address before trying to connect',
      (tester) async {
    _mockDeviceRole(isTv: false);
    _setScreenSize(tester, const Size(400, 800));

    await tester.pumpWidget(const HyoukaCastApp());
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).at(0), '8.8.8.8');
    await tester.enterText(find.byType(TextField).at(1), '123456');
    await tester.ensureVisible(find.text('CONNECT & SHARE'));
    await tester.tap(find.text('CONNECT & SHARE'));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Enter the TV private Wi-Fi IPv4 address, for example 192.168.1.50.',
      ),
      findsOneWidget,
    );
    expect(find.text('CONNECT & SHARE'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('rejects a pairing code that is not six digits', (tester) async {
    _mockDeviceRole(isTv: false);
    _setScreenSize(tester, const Size(400, 800));

    await tester.pumpWidget(const HyoukaCastApp());
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).at(0), '192.168.1.50');
    await tester.enterText(find.byType(TextField).at(1), '12345');
    await tester.ensureVisible(find.text('CONNECT & SHARE'));
    await tester.tap(find.text('CONNECT & SHARE'));
    await tester.pumpAndSettle();

    expect(
      find.text('Enter the six-digit code shown on the TV.'),
      findsOneWidget,
    );
    expect(find.text('CONNECT & SHARE'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

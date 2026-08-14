import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:vnt_app/main.dart';
import 'package:vnt_app/src/rust/frb_generated.dart';

void main() {
  setUpAll(() async => await RustLib.init());
  testWidgets('应用主界面可以渲染', (WidgetTester tester) async {
    await tester.pumpWidget(const VntApp());
    expect(find.byType(MaterialApp), findsOneWidget);
  });
}

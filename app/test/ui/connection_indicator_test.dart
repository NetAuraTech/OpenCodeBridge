import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/client/connection_monitor.dart';
import 'package:opencodebridge/ui/connection_indicator.dart';

void main() {
  Future<void> pumpIndicator(WidgetTester tester, LinkState state) =>
      tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ConnectionIndicator(state: state)),
        ),
      );

  BoxDecoration getDot(WidgetTester tester) =>
      tester
              .widget<Container>(
                find.byKey(const Key('connection-indicator-dot')),
              )
              .decoration!
          as BoxDecoration;

  testWidgets('connected shows a green dot', (tester) async {
    await pumpIndicator(tester, LinkState.connected);
    expect(getDot(tester).color, Colors.green);
  });

  testWidgets('disconnected shows a red dot', (tester) async {
    await pumpIndicator(tester, LinkState.disconnected);
    expect(getDot(tester).color, Colors.red);
  });

  testWidgets('connecting shows a grey dot', (tester) async {
    await pumpIndicator(tester, LinkState.connecting);
    expect(getDot(tester).color, Colors.grey);
  });
}

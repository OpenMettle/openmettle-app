import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:openmettle_app/conversations/history_choice.dart';

const _createdAt = '2026-01-01T01:15:00.000000Z';
const _label = 'Branch 00000000-0000-4000-8000-000000000003';

void main() {
  testWidgets('shows the local creation date, time and UTC offset', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(alwaysUse24HourFormat: true),
          child: Scaffold(
            body: HistoryChoice(
              label: _label,
              createdAt: _createdAt,
              onPressed: () {},
            ),
          ),
        ),
      ),
    );

    const expected = String.fromEnvironment('EXPECTED_HISTORY_LABEL');
    if (expected.isNotEmpty) {
      expect(find.text(expected), findsOneWidget);
    } else {
      expect(
        find.textContaining(
          RegExp(
            r'^Created .+ at [0-9]{2}:[0-9]{2} \(UTC(?:[+-][0-9]{2}:[0-9]{2})?\)$',
          ),
        ),
        findsOneWidget,
      );
    }
  });

  testWidgets('has an accessible button, keyboard activation and row note', (
    tester,
  ) async {
    final focus = FocusNode();
    addTearDown(focus.dispose);
    final semantics = tester.ensureSemantics();
    var presses = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: Scaffold(
            body: SizedBox(
              width: 280,
              child: HistoryChoice(
                label: _label,
                createdAt: _createdAt,
                note: 'History unavailable',
                focusNode: focus,
                onPressed: () => presses++,
              ),
            ),
          ),
        ),
      ),
    );

    final button = find.widgetWithText(TextButton, _label);
    expect(
      tester.getSemantics(button),
      isSemantics(
        label: _label,
        isButton: true,
        hasTapAction: true,
        hasFocusAction: true,
        isFocusable: true,
      ),
    );
    expect(find.textContaining('\nHistory unavailable'), findsOneWidget);

    focus.requestFocus();
    await tester.pump();
    expect(focus.hasPrimaryFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(presses, 1);
    semantics.dispose();
  });
}

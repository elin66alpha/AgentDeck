import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay/features/chat/chat_content.dart';

// Collects every span the widget tree paints, so a test can assert which slice
// of text carries the search-hit background.
List<TextSpan> _spans(WidgetTester tester) {
  final List<TextSpan> found = <TextSpan>[];
  void walk(InlineSpan span) {
    if (span is TextSpan) {
      if (span.text != null) found.add(span);
      for (final InlineSpan child in span.children ?? const <InlineSpan>[]) {
        walk(child);
      }
    }
  }

  for (final RichText text in tester.widgetList<RichText>(find.byType(RichText))) {
    walk(text.text);
  }
  return found;
}

Iterable<String> _markedText(WidgetTester tester) => _spans(tester)
    .where((TextSpan span) => span.style?.backgroundColor != null)
    .map((TextSpan span) => span.text!);

Future<void> _pump(WidgetTester tester, Widget child) {
  return tester.pumpWidget(
    MaterialApp(home: Scaffold(body: Center(child: child))),
  );
}

void main() {
  group('MessageText search highlight', () {
    testWidgets('marks the term in the plain-text path', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        const MessageText(
          text: 'deploy the Relay backend today',
          color: Colors.black,
          formatInlineEmphasis: false,
          highlightQuery: 'relay',
        ),
      );

      expect(_markedText(tester), <String>['Relay']);
      expect(
        _spans(tester).map((TextSpan span) => span.text).join(),
        'deploy the Relay backend today',
      );
    });

    testWidgets('marks every occurrence, case-insensitively', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        const MessageText(
          text: 'Relay, then relay again',
          color: Colors.black,
          formatInlineEmphasis: false,
          highlightQuery: 'RELAY',
        ),
      );

      expect(_markedText(tester), <String>['Relay', 'relay']);
    });

    testWidgets('marks the term inside rendered markdown', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        const MessageText(
          text: 'The **deploy** step restarts the backend service.',
          color: Colors.black,
          formatInlineEmphasis: true,
          highlightQuery: 'backend',
        ),
      );

      expect(_markedText(tester), <String>['backend']);
      // The surrounding markdown still renders: "deploy" stays bold and the
      // literal asterisks are gone.
      final Iterable<TextSpan> bold = _spans(tester).where(
        (TextSpan span) => span.style?.fontWeight == FontWeight.w700,
      );
      expect(bold.map((TextSpan span) => span.text), contains('deploy'));
      expect(
        _spans(tester).map((TextSpan span) => span.text).join(),
        isNot(contains('**')),
      );
    });

    testWidgets('renders unmarked when no query is set', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        const MessageText(
          text: 'The **deploy** step restarts the backend service.',
          color: Colors.black,
          formatInlineEmphasis: true,
        ),
      );

      expect(_markedText(tester), isEmpty);
    });
  });
}

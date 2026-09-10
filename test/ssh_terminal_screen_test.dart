import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay/core/backend/backend_client.dart';
import 'package:relay/core/i18n/app_strings.dart';
import 'package:relay/core/platform/platform_capabilities.dart';
import 'package:relay/core/settings/app_settings_controller.dart';
import 'package:relay/core/theme/app_theme.dart';
import 'package:relay/features/ssh/ssh_terminal_controller.dart';
import 'package:relay/features/ssh/ssh_terminal_screen.dart';
import 'package:xterm/xterm.dart';

void main() {
  testWidgets('SSH terminal uses a mono font stack and follows app themes', (
    WidgetTester tester,
  ) async {
    final SshTerminalController controller = SshTerminalController(
      backend: _FailingBackendClient(),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      AppScope(
        controller: AppSettingsController(),
        child: MaterialApp(
          theme: AppTheme.light(),
          home: SshTerminalScreen(
            controller: controller,
            machineId: 'machine-1',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    TerminalView terminalView = tester.widget<TerminalView>(
      find.byType(TerminalView),
    );
    expect(
      terminalView.theme.background,
      AppTheme.light().scaffoldBackgroundColor,
    );
    expect(terminalView.theme.foreground, const Color(0xFF101923));
    expect(terminalView.textStyle.fontFamily, 'RelayTerminalMono');
    expect(
      terminalView.textStyle.fontFamilyFallback,
      containsAll(<String>['Cascadia Mono', 'Consolas', 'Menlo', 'monospace']),
    );
    expect(terminalView.textStyle.height, 1.2);

    await tester.pumpWidget(
      AppScope(
        controller: AppSettingsController(),
        child: MaterialApp(
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          themeMode: ThemeMode.dark,
          home: SshTerminalScreen(
            controller: controller,
            machineId: 'machine-1',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    terminalView = tester.widget<TerminalView>(find.byType(TerminalView));
    expect(
      terminalView.theme.background,
      AppTheme.dark().scaffoldBackgroundColor,
    );
    expect(terminalView.theme.foreground, const Color(0xFFEAF6FF));
    expect(terminalView.textStyle.fontFamily, 'RelayTerminalMono');
  });

  testWidgets(
    'SSH terminal shows the modifier key bar only on mobile',
    (WidgetTester tester) async {
      final SshTerminalController controller = SshTerminalController(
        backend: _FailingBackendClient(),
      );
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        AppScope(
          controller: AppSettingsController(),
          child: MaterialApp(
            theme: AppTheme.light(),
            home: SshTerminalScreen(
              controller: controller,
              machineId: 'machine-1',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      if (usesHardwareKeyboard) {
        expect(find.text('Ctrl'), findsNothing);
        return;
      }
      for (final String label in <String>['Ctrl', 'Shift', 'Esc', 'Tab']) {
        expect(find.text(label), findsOneWidget);
      }
      await tester.tap(find.text('Ctrl'));
      await tester.pump();
      expect(controller.ctrlLatched, isTrue);
      await tester.tap(find.text('Ctrl'));
      await tester.pump();
      expect(controller.ctrlLatched, isFalse);
    },
    variant: const TargetPlatformVariant(
      <TargetPlatform>{TargetPlatform.android, TargetPlatform.linux},
    ),
  );
}

class _FailingBackendClient extends BackendClient {
  @override
  Future<Uri> terminalWebSocketUri({required int cols, required int rows}) {
    throw BackendException('terminal offline');
  }
}

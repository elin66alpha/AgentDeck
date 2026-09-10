import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay/core/backend/backend_client.dart';
import 'package:relay/core/i18n/app_strings.dart';
import 'package:relay/core/models/cli_agent.dart';
import 'package:relay/core/models/machine_credential.dart';
import 'package:relay/core/settings/app_settings_controller.dart';
import 'package:relay/features/chat/bot_chat_controller.dart';
import 'package:relay/features/cli_agents/cli_agents_controller.dart';
import 'package:relay/features/machines/machine_details_screen.dart';
import 'package:xterm/xterm.dart';

const MachineCredential _machine = MachineCredential(
  id: 'machine-1',
  name: 'Test machine',
  baseUrl: 'https://relay.example.com',
  token: 'device-token',
  createdAt: '2026-07-13T00:00:00.000Z',
);

Future<void> _pumpDetails(
  WidgetTester tester,
  CliAgentsController agentsController,
) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final BotChatController chatController = BotChatController(
    backendClient: _OfflineBackendClient(),
  );
  addTearDown(chatController.disposeController);

  await tester.pumpWidget(
    AppScope(
      controller: AppSettingsController(),
      child: MaterialApp(
        home: MachineDetailsScreen(
          machine: _machine,
          chatController: chatController,
          agentsController: agentsController,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('sections run SSH, agents, tokens, status; SSH reuses a terminal', (
    WidgetTester tester,
  ) async {
    await _pumpDetails(tester, CliAgentsController());

    final double ssh = tester.getTopLeft(find.text('Enter SSH')).dy;
    final double agents = tester.getTopLeft(find.text('CLI agents')).dy;
    final double tokens = tester.getTopLeft(find.text('Device tokens')).dy;
    final double status = tester.getTopLeft(find.text('Test machine')).dy;
    expect(ssh < agents && agents < tokens && tokens < status, isTrue);
    expect(
      tester.getSize(find.widgetWithText(FilledButton, 'Enter SSH')).width,
      lessThan(360),
    );

    await tester.tap(find.text('Enter SSH'));
    await tester.pumpAndSettle();
    expect(find.text('SSH terminal'), findsOneWidget);
    final Terminal firstTerminal =
        tester.widget<TerminalView>(find.byType(TerminalView)).terminal;

    await tester.tap(find.byTooltip('Back to machine details'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Enter SSH'));
    await tester.pumpAndSettle();
    final Terminal secondTerminal =
        tester.widget<TerminalView>(find.byType(TerminalView)).terminal;
    expect(identical(firstTerminal, secondTerminal), isTrue);
  });

  testWidgets('agent credentials report only real login deadlines', (
    WidgetTester tester,
  ) async {
    final DateTime now = DateTime.now();
    final CliAgentsController agentsController = CliAgentsController()
      ..syncAgents(<CliAgent>[
        CliAgent(
          key: 'claude',
          label: 'Claude Code',
          description: 'Anthropic Claude Code CLI',
          authKind: 'oauth',
          credentialExpiresAt: now.add(const Duration(days: 12, hours: 1)),
        ),
        CliAgent(
          key: 'codex',
          label: 'Codex',
          description: 'OpenAI Codex CLI',
          authKind: 'oauth',
          credentialExpiresAt: now.subtract(const Duration(days: 2, hours: 1)),
        ),
      ]);

    await _pumpDetails(tester, agentsController);

    expect(find.text('Log in again in 12 days'), findsOneWidget);
    expect(find.text('Ready'), findsOneWidget);
    expect(find.textContaining('Expired 2 days ago'), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Log in'), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Log in again'), findsNothing);
  });
}

class _OfflineBackendClient extends BackendClient {
  @override
  Future<Uri> terminalWebSocketUri({required int cols, required int rows}) {
    throw BackendException('terminal offline');
  }

  @override
  Future<BackendDiagnostics> diagnostics({
    Duration timeout = const Duration(seconds: 8),
  }) {
    throw BackendException('offline');
  }

  @override
  Future<List<DeviceToken>> deviceTokens() async => const <DeviceToken>[];

  @override
  Future<void> close() async {}
}

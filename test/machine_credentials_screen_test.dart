import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay/core/backend/backend_client.dart';
import 'package:relay/core/i18n/app_strings.dart';
import 'package:relay/core/models/cli_agent.dart';
import 'package:relay/core/models/machine_credential.dart';
import 'package:relay/core/settings/app_settings_controller.dart';
import 'package:relay/core/storage/machine_credentials_store.dart';
import 'package:relay/features/cli_agents/cli_agents_controller.dart';
import 'package:relay/features/machines/machine_credentials_controller.dart';
import 'package:relay/features/machines/machine_credentials_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';

void main() {
  testWidgets('initial connection screen language toggle drives the guide', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    MachineCredentialsStore.resetCacheForTest();

    final AppSettingsController settingsController = AppSettingsController();
    await settingsController.load();
    final MachineCredentialsController machinesController =
        MachineCredentialsController(store: _EmptyMachineCredentialsStore());
    await machinesController.load();

    await tester.pumpWidget(
      AppScope(
        controller: settingsController,
        child: MaterialApp(
          home: MachineCredentialsScreen(
            machinesController: machinesController,
            settingsController: settingsController,
            requireCredential: true,
          ),
        ),
      ),
    );

    expect(settingsController.language, AppLanguage.en);
    expect(find.text('中/En'), findsOneWidget);
    expect(find.text('Import machine credential'), findsOneWidget);

    await tester.tap(find.text('中/En'));
    await tester.pumpAndSettle();

    expect(settingsController.language, AppLanguage.zh);
    expect(find.text('导入机器凭证'), findsOneWidget);
    expect(find.text('如何部署后端？'), findsOneWidget);

    await tester.tap(find.text('如何部署后端？'));
    await tester.pumpAndSettle();

    expect(find.text('在自己的机器上部署后端'), findsOneWidget);
  });

  testWidgets('SSH action precedes machine test and reopens one terminal', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    MachineCredentialsStore.resetCacheForTest();
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const MachineCredential credential = MachineCredential(
      id: 'machine-1',
      name: 'Test machine',
      baseUrl: 'https://relay.example.com',
      token: 'device-token',
      createdAt: '2026-07-13T00:00:00.000Z',
    );
    final MachineCredentialsController machinesController =
        MachineCredentialsController(
      store: _MemoryMachineCredentialsStore(credential),
    );
    await machinesController.load();

    await tester.pumpWidget(
      AppScope(
        controller: AppSettingsController(),
        child: MaterialApp(
          home: MachineCredentialsScreen(
            machinesController: machinesController,
            backendClient: _FailingTerminalBackendClient(),
          ),
        ),
      ),
    );

    final Offset ssh = tester.getTopLeft(find.text('Enter SSH'));
    final Offset test = tester.getTopLeft(find.text('Test current machine'));
    expect(ssh.dy < test.dy || (ssh.dy == test.dy && ssh.dx < test.dx), isTrue);

    await tester.tap(find.text('Enter SSH'));
    await tester.pumpAndSettle();
    expect(find.text('SSH terminal'), findsOneWidget);
    expect(find.text('Password'), findsNothing);
    final Terminal firstTerminal =
        tester.widget<TerminalView>(find.byType(TerminalView)).terminal;

    await tester.tap(find.byTooltip('Back to machine credentials'));
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
    SharedPreferences.setMockInitialValues(<String, Object>{});
    MachineCredentialsStore.resetCacheForTest();
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const MachineCredential credential = MachineCredential(
      id: 'machine-1',
      name: 'Test machine',
      baseUrl: 'https://relay.example.com',
      token: 'device-token',
      createdAt: '2026-07-13T00:00:00.000Z',
    );
    final MachineCredentialsController machinesController =
        MachineCredentialsController(
      store: _MemoryMachineCredentialsStore(credential),
    );
    await machinesController.load();

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

    await tester.pumpWidget(
      AppScope(
        controller: AppSettingsController(),
        child: MaterialApp(
          home: MachineCredentialsScreen(
            machinesController: machinesController,
            agentsController: agentsController,
            backendClient: _FailingTerminalBackendClient(),
          ),
        ),
      ),
    );

    expect(find.text('Log in again in 12 days'), findsOneWidget);
    expect(find.text('Ready'), findsOneWidget);
    expect(find.textContaining('Expired 2 days ago'), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Log in'), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Log in again'), findsNothing);
  });
}

class _FailingTerminalBackendClient extends BackendClient {
  @override
  Future<Uri> terminalWebSocketUri({required int cols, required int rows}) {
    throw BackendException('terminal offline');
  }

  @override
  Future<void> close() async {}
}

class _MemoryMachineCredentialsStore extends MachineCredentialsStore {
  _MemoryMachineCredentialsStore(this.credential);

  final MachineCredential credential;

  @override
  Future<List<MachineCredential>> readAll() async => <MachineCredential>[
        credential,
      ];

  @override
  Future<String?> readActiveId() async => credential.id;

  @override
  Future<void> setActive(String id) async {}

  @override
  Future<void> upsert(
    MachineCredential credential, {
    bool makeActive = true,
  }) async {}

  @override
  Future<void> delete(String id) async {}
}

class _EmptyMachineCredentialsStore extends MachineCredentialsStore {
  @override
  Future<List<MachineCredential>> readAll() async {
    return const <MachineCredential>[];
  }

  @override
  Future<String?> readActiveId() async {
    return null;
  }

  @override
  Future<void> setActive(String id) async {}

  @override
  Future<void> upsert(
    MachineCredential credential, {
    bool makeActive = true,
  }) async {}

  @override
  Future<void> delete(String id) async {}
}

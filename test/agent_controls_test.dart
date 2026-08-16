import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay/core/backend/backend_client.dart';
import 'package:relay/core/i18n/app_strings.dart';
import 'package:relay/core/models/agent_options.dart';
import 'package:relay/core/settings/app_settings_controller.dart';
import 'package:relay/features/chat/agent_controls.dart';

void main() {
  // The catalog cache outlives a widget on purpose, so each test starts from a
  // cold one instead of inheriting the previous test's fetch.
  setUp(clearAgentOptionsCache);

  Future<void> pumpControls(
    WidgetTester tester,
    _OptionsBackendClient backend, {
    bool settle = true,
  }) async {
    final AppSettingsController settings = AppSettingsController();
    addTearDown(settings.dispose);
    addTearDown(backend.close);
    await tester.pumpWidget(
      AppScope(
        controller: settings,
        child: MaterialApp(
          home: Scaffold(
            body: AgentControlsButtons(
              backend: backend,
              agentKey: 'codex',
            ),
          ),
        ),
      ),
    );
    if (settle) await tester.pumpAndSettle();
  }

  testWidgets('effort page filters choices by the selected model', (
    WidgetTester tester,
  ) async {
    final _OptionsBackendClient backend = _OptionsBackendClient();
    await pumpControls(tester, backend);

    await tester.tap(find.text('Effort'));
    await tester.pumpAndSettle();

    expect(find.text('Extra high'), findsOneWidget);
    expect(find.text('Medium'), findsNothing);
    expect(find.text('Update CLI'), findsOneWidget);
    expect(find.byIcon(Icons.radio_button_checked_rounded), findsOneWidget);
  });

  testWidgets('CLI update refreshes catalog and settings on effort page', (
    WidgetTester tester,
  ) async {
    final _OptionsBackendClient backend = _OptionsBackendClient();
    await pumpControls(tester, backend);
    await tester.tap(find.text('Effort'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Update CLI'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Update CLI').last);
    await tester.pumpAndSettle();

    expect(find.text('Max'), findsOneWidget);
    expect(find.text('Extra high'), findsNothing);
    expect(find.byIcon(Icons.radio_button_checked_rounded), findsOneWidget);
    expect(backend.optionsFetches, 2);
    expect(backend.settingsFetches, 2);
  });

  testWidgets('failed CLI update is reported as a failure', (
    WidgetTester tester,
  ) async {
    final _OptionsBackendClient backend = _OptionsBackendClient(
      updateSucceeds: false,
    );
    await pumpControls(tester, backend);
    await tester.tap(find.text('Effort'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Update CLI'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Update CLI').last);
    await tester.pumpAndSettle();

    expect(find.textContaining('Update failed: denied'), findsOneWidget);
    expect(find.text('Already up to date'), findsNothing);
    expect(backend.optionsFetches, 1);
    expect(backend.settingsFetches, 1);
  });

  testWidgets('returning from an option page adopts the saved selection', (
    WidgetTester tester,
  ) async {
    final _OptionsBackendClient backend = _OptionsBackendClient();
    await pumpControls(tester, backend);

    await tester.tap(find.text('Model'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('GPT Lite'));
    await tester.pumpAndSettle();

    // The page already returned the saved settings, so the controls take them
    // as-is instead of refetching the catalog and the settings again.
    expect(backend.settingUpdates, 1);
    expect(backend.optionsFetches, 1);
    expect(backend.settingsFetches, 1);

    // Reopening shows the new selection, which is what the refetch was for.
    await tester.tap(find.text('Model'));
    await tester.pumpAndSettle();
    final ListTile lite = tester.widget<ListTile>(
      find.widgetWithText(ListTile, 'GPT Lite'),
    );
    expect((lite.leading! as Icon).icon, Icons.radio_button_checked_rounded);
  });

  testWidgets('a cached catalog renders the controls without a spinner', (
    WidgetTester tester,
  ) async {
    await pumpControls(tester, _OptionsBackendClient());
    // Unmount, then mount again: what happens every time the composer's action
    // panel closes and reopens.
    await tester.pumpWidget(const SizedBox.shrink());
    await pumpControls(tester, _OptionsBackendClient(), settle: false);

    // First frame, before the refresh lands: buttons already at final size.
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Model'), findsOneWidget);
    await tester.pumpAndSettle();
  });

  testWidgets('fast switch updates the Codex fast setting', (
    WidgetTester tester,
  ) async {
    final _OptionsBackendClient backend = _OptionsBackendClient();
    await pumpControls(tester, backend);

    await tester.tap(find.text('Model'));
    await tester.pumpAndSettle();

    expect(find.text('Fast mode'), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    expect(backend.lastUpdatedGroup, 'fast');
    expect(backend.lastUpdatedOption, 'on');
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
  });
}

class _OptionsBackendClient extends BackendClient {
  _OptionsBackendClient({this.updateSucceeds = true});

  final bool updateSucceeds;
  bool updated = false;
  int optionsFetches = 0;
  int settingsFetches = 0;
  int settingUpdates = 0;
  String? lastUpdatedGroup;
  String? lastUpdatedOption;
  bool fast = false;

  AgentOptionsCatalog get _catalog =>
      AgentOptionsCatalog.fromJson(<String, Object?>{
        'agent': 'codex',
        'supports': <String, Object?>{
          'model': true,
          'effort': true,
          'permission': false,
          'fast': true,
        },
        'model': <Object?>[
          <String, Object?>{'id': 'gpt-new', 'label': 'GPT New'},
          <String, Object?>{'id': 'gpt-lite', 'label': 'GPT Lite'},
        ],
        'effort': <Object?>[
          <String, Object?>{'id': 'medium', 'label': 'Medium'},
        ],
        'effortByModel': <String, Object?>{
          'gpt-new': <Object?>[
            <String, Object?>{
              'id': updated ? 'max' : 'xhigh',
              'label': updated ? 'Max' : 'Extra high',
            },
          ],
          'gpt-lite': <Object?>[
            <String, Object?>{'id': 'low', 'label': 'Low'},
          ],
        },
        'defaults': <String, Object?>{
          'model': 'gpt-new',
          'effort': 'medium',
        },
        'defaultEffortByModel': <String, Object?>{
          'gpt-new': updated ? 'max' : 'xhigh',
          'gpt-lite': 'low',
        },
      });

  AgentSettings get _settings => AgentSettings(<String, String>{
        'model': 'gpt-new',
        'effort': updated ? 'max' : 'xhigh',
        'fast': fast ? 'on' : 'off',
      });

  @override
  Future<AgentOptionsCatalog> fetchAgentOptions(String agentKey) async {
    optionsFetches += 1;
    return _catalog;
  }

  @override
  Future<AgentSettings> fetchAgentSettings(String agentKey) async {
    settingsFetches += 1;
    return _settings;
  }

  @override
  Future<String> fetchAgentVersion(String agentKey) async {
    return updated ? '2.0.0' : '1.0.0';
  }

  @override
  Future<AgentSettings> updateAgentSetting(
    String agentKey,
    String group,
    String optionId,
  ) async {
    settingUpdates += 1;
    lastUpdatedGroup = group;
    lastUpdatedOption = optionId;
    if (group == 'fast') fast = optionId == 'on';
    return _settings.copyWith(group, optionId);
  }

  @override
  Future<AgentUpdateResult> updateAgentCli(String agentKey) async {
    if (!updateSucceeds) {
      return const AgentUpdateResult(
        ok: false,
        before: '1.0.0',
        after: '1.0.0',
        changed: false,
        timedOut: false,
        output: 'denied',
      );
    }
    updated = true;
    return const AgentUpdateResult(
      ok: true,
      before: '1.0.0',
      after: '2.0.0',
      changed: true,
      timedOut: false,
      output: '',
    );
  }

  @override
  Future<void> close() async {}
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay/core/i18n/app_strings.dart';
import 'package:relay/core/models/machine_credential.dart';
import 'package:relay/core/settings/app_settings_controller.dart';
import 'package:relay/core/storage/machine_credentials_store.dart';
import 'package:relay/features/machines/machine_credentials_controller.dart';
import 'package:relay/features/machines/machine_credentials_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

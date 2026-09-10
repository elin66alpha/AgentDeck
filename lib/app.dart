import 'package:flutter/material.dart';

import 'core/backend/backend_client.dart';
import 'core/i18n/app_strings.dart';
import 'core/models/machine_credential.dart';
import 'core/settings/app_settings_controller.dart';
import 'core/theme/app_theme.dart';
import 'features/chat/bot_chat_controller.dart';
import 'features/chat/bot_chat_screen.dart';
import 'features/cli_agents/cli_agents_controller.dart';
import 'features/machines/machine_credentials_controller.dart';
import 'features/machines/machine_credentials_screen.dart';

class BotApp extends StatefulWidget {
  const BotApp({
    required this.agentsController,
    required this.chatController,
    required this.machinesController,
    required this.settingsController,
    super.key,
  });

  final CliAgentsController agentsController;
  final BotChatController chatController;
  final MachineCredentialsController machinesController;
  final AppSettingsController settingsController;

  @override
  State<BotApp> createState() => _BotAppState();
}

class _BotAppState extends State<BotApp> {
  bool _isStarting = true;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      await widget.machinesController.load();
      await widget.agentsController.load();
      final MachineCredential? activeMachine =
          widget.machinesController.activeMachine;
      if (activeMachine != null) {
        await _activeMachineIsAuthorized(activeMachine);
      }
    } catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'relay startup',
          context: ErrorDescription('loading agents'),
        ),
      );
    }
    if (!mounted) return;
    setState(() => _isStarting = false);
  }

  Future<bool> _activeMachineIsAuthorized(MachineCredential machine) async {
    final BackendClient client = BackendClient();
    try {
      return await client.health(timeout: const Duration(seconds: 5));
    } on BackendException catch (error) {
      if (error.status == 401) {
        await widget.machinesController.delete(machine.id);
        return false;
      }
      return true;
    } catch (_) {
      // Offline or unreachable machines should not trap startup on a splash
      // screen or delete credentials. The chat surface will show connection
      // errors when the user tries to use the backend.
      return true;
    } finally {
      await client.close();
    }
  }

  @override
  void dispose() {
    widget.chatController.disposeController();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppScope(
      controller: widget.settingsController,
      child: AnimatedBuilder(
        animation: widget.settingsController,
        builder: (BuildContext context, Widget? _) {
          final AppStrings strings = AppStrings(
            widget.settingsController.language,
          );
          return MaterialApp(
            debugShowCheckedModeBanner: false,
            title: strings.appName,
            theme: AppTheme.light(),
            darkTheme: AppTheme.dark(),
            themeMode: widget.settingsController.themeMode,
            builder: (BuildContext context, Widget? child) {
              final MediaQueryData mediaQuery = MediaQuery.of(context);
              final double systemScale = mediaQuery.textScaler.scale(1);
              return MediaQuery(
                data: mediaQuery.copyWith(
                  textScaler: TextScaler.linear(
                    systemScale * widget.settingsController.fontScale,
                  ),
                ),
                child: child ?? const SizedBox.shrink(),
              );
            },
            home: _isStarting
                ? const _Splash()
                : AnimatedBuilder(
                    animation: widget.machinesController,
                    builder: (BuildContext context, Widget? _) {
                      if (widget.machinesController.activeMachine == null) {
                        return MachineCredentialsScreen(
                          machinesController: widget.machinesController,
                          settingsController: widget.settingsController,
                          requireCredential: true,
                        );
                      }
                      return BotChatScreen(
                        agentsController: widget.agentsController,
                        chatController: widget.chatController,
                        machinesController: widget.machinesController,
                        settingsController: widget.settingsController,
                      );
                    },
                  ),
          );
        },
      ),
    );
  }
}

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: SizedBox.shrink());
  }
}

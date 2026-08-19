// ignore_for_file: use_build_context_synchronously

import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/backend/backend_client.dart';
import '../../core/credentials/qr_image_decoder.dart';
import '../../core/credentials/qr_image_pixels.dart';
import '../../core/credentials/qr_pixels.dart';
import '../../core/i18n/app_strings.dart';
import '../../core/models/cli_agent.dart';
import '../../core/models/machine_credential.dart';
import '../../core/settings/app_settings_controller.dart';
import '../cli_agents/agent_status_lights.dart';
import '../cli_agents/cli_agents_controller.dart';
import '../ssh/ssh_terminal_controller.dart';
import '../ssh/ssh_terminal_screen.dart';
import 'deploy_backend_screen.dart';
import 'machine_credentials_controller.dart';

class MachineCredentialsScreen extends StatefulWidget {
  const MachineCredentialsScreen({
    required this.machinesController,
    this.agentsController,
    this.settingsController,
    this.backendClient,
    this.requireCredential = false,
    super.key,
  });

  final MachineCredentialsController machinesController;
  final CliAgentsController? agentsController;
  final AppSettingsController? settingsController;
  final BackendClient? backendClient;
  final bool requireCredential;

  @override
  State<MachineCredentialsScreen> createState() =>
      _MachineCredentialsScreenState();
}

class _MachineCredentialsScreenState extends State<MachineCredentialsScreen> {
  bool _isImporting = false;
  bool _isTesting = false;
  late final BackendClient _backendClient;
  late final bool _ownsBackendClient;
  late final SshTerminalController _sshController;

  @override
  void initState() {
    super.initState();
    _ownsBackendClient = widget.backendClient == null;
    _backendClient = widget.backendClient ?? BackendClient();
    _sshController = SshTerminalController(backend: _backendClient);
  }

  @override
  void dispose() {
    _sshController.dispose();
    if (_ownsBackendClient) {
      unawaited(_backendClient.close());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.machinesController,
      builder: (BuildContext context, Widget? _) {
        final List<MachineCredential> credentials =
            widget.machinesController.credentials;
        final MachineCredential? active =
            widget.machinesController.activeMachine;
        // Camera QR scanning only exists on mobile. Desktop (and web) have no
        // mobile_scanner implementation, so they import via image upload or
        // paste instead.
        final bool showCameraScan = !kIsWeb &&
            (defaultTargetPlatform == TargetPlatform.android ||
                defaultTargetPlatform == TargetPlatform.iOS);
        return Scaffold(
          appBar: widget.requireCredential
              ? null
              : AppBar(title: Text(context.l10n.credentialTitle)),
          body: SafeArea(
            child: credentials.isEmpty
                ? _EmptyCredentialState(
                    isImporting: _isImporting,
                    showCameraScan: showCameraScan,
                    onScan: _scanCredential,
                    onPaste: _pasteCredential,
                    onUpload: _uploadCredentialQr,
                    settingsController: widget.requireCredential
                        ? widget.settingsController
                        : null,
                  )
                : ListView(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                    children: <Widget>[
                      Align(
                        alignment: Alignment.topCenter,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 720),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Padding(
                                padding: const EdgeInsets.fromLTRB(4, 4, 4, 12),
                                child: Text(
                                  context.l10n.currentMachine,
                                  style: TextStyle(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.outline,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              for (final MachineCredential credential
                                  in credentials)
                                _MachineTile(
                                  credential: credential,
                                  active: credential.id == active?.id,
                                  onSelect: () => widget.machinesController
                                      .setActive(credential.id),
                                  onDelete: () => _confirmDelete(credential),
                                ),
                              const SizedBox(height: 16),
                              _CredentialActionButtons(
                                active: active,
                                isImporting: _isImporting,
                                isTesting: _isTesting,
                                showCameraScan: showCameraScan,
                                onScan: _scanCredential,
                                onPaste: _pasteCredential,
                                onUpload: _uploadCredentialQr,
                                onSsh: _enterSsh,
                                onTest: _testActive,
                              ),
                              if (widget.agentsController != null) ...<Widget>[
                                const SizedBox(height: 18),
                                _AgentCredentialStatusSection(
                                  agentsController: widget.agentsController!,
                                  onRefresh: _refreshAgents,
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
          ),
        );
      },
    );
  }

  Future<void> _scanCredential() async {
    setState(() => _isImporting = true);
    try {
      final String? raw = await Navigator.of(context).push<String>(
        MaterialPageRoute<String>(
          builder: (_) => const _CredentialQrScannerScreen(),
        ),
      );
      if (raw == null || raw.trim().isEmpty) return;
      await _finishImportPayload(raw);
    } catch (err) {
      await _showImportError(err);
    } finally {
      if (mounted) setState(() => _isImporting = false);
    }
  }

  Future<void> _pasteCredential() async {
    final String? raw = await _askCredentialPayload();
    if (raw == null || raw.trim().isEmpty) return;
    setState(() => _isImporting = true);
    try {
      await _finishImportPayload(raw);
    } catch (err) {
      await _showImportError(err);
    } finally {
      if (mounted) setState(() => _isImporting = false);
    }
  }

  Future<void> _uploadCredentialQr() async {
    setState(() => _isImporting = true);
    try {
      final FilePickerResult? result = await FilePicker.pickFiles(
        type: FileType.image,
        allowMultiple: false,
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;
      final Uint8List? bytes = result.files.single.bytes;
      if (bytes == null || bytes.isEmpty) {
        throw MachineCredentialException(context.l10n.fileUnreadable);
      }
      // Prefer the platform's own decoder (the browser's, on Web) and fall back
      // to the pure-Dart pipeline on a background isolate. Doing the Dart decode
      // on Web would block the only thread there is, freezing the tab past the
      // point where this timeout could still fire.
      final QrPixels? pixels = await decodeImageToRgba(bytes).timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw MachineCredentialException(
          context.l10n.credentialQrDecodeTimedOut,
        ),
      );
      final String raw = pixels != null
          ? decodeQrFromRgba(pixels.width, pixels.height, pixels.rgba)
          : await compute<Uint8List, String>(
              decodeCredentialQrImage,
              bytes,
            ).timeout(
              const Duration(seconds: 10),
              onTimeout: () => throw MachineCredentialException(
                context.l10n.credentialQrDecodeTimedOut,
              ),
            );
      if (raw.trim().isEmpty) {
        throw MachineCredentialException(context.l10n.invalidQr);
      }
      await _finishImportPayload(raw);
    } catch (err) {
      await _showImportError(err);
    } finally {
      if (mounted) setState(() => _isImporting = false);
    }
  }

  Future<void> _finishImportPayload(String raw) {
    return _finishImport(Uint8List.fromList(utf8.encode(raw.trim())));
  }

  Future<void> _finishImport(Uint8List bytes) async {
    if (!mounted) return;
    final String? passphrase = await _askPassphrase();
    if (passphrase == null) return;

    late final MachineCredential credential;
    try {
      credential = await widget.machinesController
          .decryptEncryptedBytes(bytes, passphrase: passphrase)
          .timeout(const Duration(seconds: 15));
    } on TimeoutException {
      throw MachineCredentialException(context.l10n.credentialDecryptTimedOut);
    } on MachineCredentialException catch (err) {
      if (err.message.contains('decryption failed')) {
        throw MachineCredentialException(context.l10n.credentialDecryptFailed);
      }
      rethrow;
    }
    if (_usesPlainHttp(credential)) {
      final bool continueImport = await _confirmPlainHttpCredential(credential);
      if (!continueImport) return;
    }
    final BackendClient client = BackendClient();
    try {
      final bool ok = await client.healthFor(
        credential,
        timeout: const Duration(seconds: 8),
      );
      if (!ok) {
        throw MachineCredentialException(
          context.l10n.credentialBackendNotOk(credential.hostLabel),
        );
      }
    } on BackendException catch (err) {
      throw MachineCredentialException(
        _credentialConnectionMessage(credential, err),
      );
    } finally {
      await client.close();
    }
    await widget.machinesController.saveCredential(credential);
    if (!mounted) return;
    if (!widget.requireCredential) {
      _showMessage(context.l10n.imported(credential.displayName));
    }
  }

  bool _usesPlainHttp(MachineCredential credential) {
    return Uri.tryParse(credential.baseUrl)?.scheme.toLowerCase() == 'http';
  }

  Future<bool> _confirmPlainHttpCredential(MachineCredential credential) async {
    if (!mounted) return false;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(context.l10n.plaintextCredentialTitle),
        content: Text(
          context.l10n.plaintextCredentialBody(credential.hostLabel),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(context.l10n.continueImport),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  String _credentialConnectionMessage(
    MachineCredential credential,
    BackendException err,
  ) {
    final String host = credential.hostLabel;
    if (err.status == 401) {
      return context.l10n.credentialTokenRejected(host);
    }
    return switch (err.code) {
      'NETWORK_HOST_LOOKUP' => context.l10n.credentialHostLookupFailed(host),
      'NETWORK_CONNECTION_REFUSED' => context.l10n.credentialConnectionRefused(
          host,
        ),
      'NETWORK_UNREACHABLE' => context.l10n.credentialNetworkUnreachable(host),
      'NETWORK_TIMEOUT' => context.l10n.credentialConnectionTimedOut(host),
      _ => context.l10n.credentialConnectionFailed(host, err.message),
    };
  }

  Future<String?> _askCredentialPayload() async {
    final TextEditingController controller = TextEditingController();
    try {
      return showDialog<String>(
        context: context,
        builder: (BuildContext ctx) => AlertDialog(
          title: Text(context.l10n.pasteCredential),
          content: SizedBox(
            width: 460,
            child: TextField(
              controller: controller,
              autofocus: true,
              minLines: 5,
              maxLines: 10,
              decoration: InputDecoration(
                labelText: context.l10n.credentialPayload,
                hintText: context.l10n.credentialPayloadHint,
              ),
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(context.l10n.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
              child: Text(context.l10n.importCredential),
            ),
          ],
        ),
      );
    } finally {
      controller.dispose();
    }
  }

  Future<String?> _askPassphrase() async {
    String passphrase = '';
    return showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(context.l10n.credentialPassword),
        content: TextField(
          obscureText: true,
          autofocus: true,
          enableSuggestions: false,
          autocorrect: false,
          decoration: InputDecoration(
            labelText: context.l10n.password,
            hintText: context.l10n.passwordHint,
          ),
          onChanged: (String value) => passphrase = value,
          onSubmitted: (_) => Navigator.of(ctx).pop(passphrase.trim()),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(passphrase.trim()),
            child: Text(context.l10n.decrypt),
          ),
        ],
      ),
    );
  }

  Future<void> _testActive() async {
    final MachineCredential? active = widget.machinesController.activeMachine;
    setState(() => _isTesting = true);
    final BackendClient client = BackendClient();
    try {
      final bool ok = await client.health();
      _showMessage(
        ok ? context.l10n.connectionOk : context.l10n.backendNotOk,
        error: !ok,
      );
    } on BackendException catch (err) {
      _showMessage(
        active != null
            ? _credentialConnectionMessage(active, err)
            : context.l10n.connectionFailed(err.message),
        error: true,
      );
    } catch (err) {
      _showMessage(context.l10n.connectionFailed(err), error: true);
    } finally {
      await client.close();
      if (mounted) setState(() => _isTesting = false);
    }
  }

  void _enterSsh() {
    final MachineCredential? active = widget.machinesController.activeMachine;
    if (active == null) return;
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => SshTerminalScreen(
          controller: _sshController,
          machineId: active.id,
        ),
      ),
    );
  }

  Future<void> _refreshAgents() async {
    final CliAgentsController? controller = widget.agentsController;
    if (controller == null) return;
    try {
      final List<CliAgent> agents = await _backendClient.fetchAgents();
      if (!mounted) return;
      controller.syncAgents(agents);
    } catch (err) {
      _showMessage(context.l10n.agentStatusRefreshFailed(err), error: true);
    }
  }

  Future<void> _confirmDelete(MachineCredential credential) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(context.l10n.deleteMachine(credential.displayName)),
        content: Text(context.l10n.deleteMachineBody),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(context.l10n.delete),
          ),
        ],
      ),
    );
    if (ok == true) {
      await widget.machinesController.delete(credential.id);
    }
  }

  void _showMessage(String message, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error ? Theme.of(context).colorScheme.error : null,
      ),
    );
  }

  Future<void> _showImportError(Object err) async {
    if (!mounted) return;
    final String message = err is MachineCredentialException
        ? err.message
        : err is BackendException
            ? err.message
            : err.toString();
    await showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(context.l10n.importFailedTitle),
        content: Text(message),
        actions: <Widget>[
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(context.l10n.ok),
          ),
        ],
      ),
    );
  }
}

class _AgentCredentialStatusSection extends StatelessWidget {
  const _AgentCredentialStatusSection({
    required this.agentsController,
    required this.onRefresh,
  });

  final CliAgentsController agentsController;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return AnimatedBuilder(
      animation: agentsController,
      builder: (BuildContext context, Widget? _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      context.l10n.cliAgents,
                      style: TextStyle(
                        color: theme.colorScheme.outline,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: context.l10n.recheck,
                    onPressed: () => unawaited(onRefresh()),
                    icon: const Icon(Icons.refresh_rounded),
                  ),
                ],
              ),
            ),
            Card(
              elevation: 0,
              color: theme.colorScheme.surfaceContainerLow,
              margin: EdgeInsets.zero,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                children: <Widget>[
                  for (int index = 0;
                      index < agentsController.agents.length;
                      index += 1)
                    _AgentCredentialStatusTile(
                      agent: agentsController.agents[index],
                      showDivider: index > 0,
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _AgentCredentialStatusTile extends StatelessWidget {
  const _AgentCredentialStatusTile({
    required this.agent,
    required this.showDivider,
  });

  final CliAgent agent;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppStrings strings = context.l10n;
    final bool usable = isCliAgentSelectable(agent);
    final Color? textColor = usable ? null : theme.colorScheme.onSurfaceVariant;
    final CredentialExpiry? expiry = cliAgentCredentialExpiry(agent);
    final String? subtitle = usable
        ? (agentCredentialExpiryMessage(strings, agent) ??
            _readySubtitle(strings, agent))
        : agentUnavailableMessage(strings, agent);
    return Column(
      children: <Widget>[
        if (showDivider) const Divider(height: 1),
        ListTile(
          dense: true,
          title: Text(agent.label, style: TextStyle(color: textColor)),
          subtitle: subtitle == null
              ? null
              : Text(
                  subtitle,
                  style: TextStyle(
                    color: expiry?.expired == true
                        ? theme.colorScheme.error
                        : theme.colorScheme.outline,
                  ),
                ),
          trailing: Wrap(
            spacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              AgentStatusLights(agent: agent),
              _AgentCredentialAction(agent: agent),
            ],
          ),
        ),
      ],
    );
  }

  String? _readySubtitle(AppStrings strings, CliAgent agent) {
    if (agent.key == 'opencode') return strings.optionalApiKey;
    if (agent.authKind == 'apiKey') return strings.agentReady;
    if (agent.authKind == 'oauth') return strings.agentReady;
    return null;
  }
}

class _AgentCredentialAction extends StatelessWidget {
  const _AgentCredentialAction({required this.agent});

  final CliAgent agent;

  @override
  Widget build(BuildContext context) {
    final AppStrings strings = context.l10n;
    if (!agent.installed) {
      return OutlinedButton(
        onPressed: null,
        child: Text(strings.unavailable),
      );
    }
    // Every agent's credential is created on the backend host: claude/codex with
    // their own `login` command, hermes/opencode with a provider key. Relay only
    // reports the state it can read there.
    if (agent.key == 'opencode' || agent.key == 'hermes') {
      return OutlinedButton(
        onPressed: null,
        child: Text(strings.keyManagedOnHost),
      );
    }
    return const SizedBox.shrink();
  }
}

class _EmptyCredentialState extends StatelessWidget {
  const _EmptyCredentialState({
    required this.isImporting,
    required this.showCameraScan,
    required this.onScan,
    required this.onPaste,
    required this.onUpload,
    required this.settingsController,
  });

  final bool isImporting;
  final bool showCameraScan;
  final VoidCallback onScan;
  final VoidCallback onPaste;
  final VoidCallback onUpload;
  final AppSettingsController? settingsController;

  @override
  Widget build(BuildContext context) {
    // Stay centered when the viewport is tall enough, but scroll instead of
    // overflowing on short viewports (landscape, split-screen, large fonts).
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      if (settingsController != null) ...<Widget>[
                        Align(
                          alignment: Alignment.centerRight,
                          child: _InitialLanguageToggle(
                            settingsController: settingsController!,
                          ),
                        ),
                        const SizedBox(height: 8),
                      ],
                      Icon(
                        Icons.vpn_key_outlined,
                        size: 48,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(height: 18),
                      Text(
                        context.l10n.importMachineCredential,
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        context.l10n.emptyCredentialText,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.outline,
                          height: 1.45,
                        ),
                      ),
                      const SizedBox(height: 22),
                      _CredentialActionButtons(
                        active: null,
                        isImporting: isImporting,
                        isTesting: false,
                        showCameraScan: showCameraScan,
                        onScan: onScan,
                        onPaste: onPaste,
                        onUpload: onUpload,
                        onSsh: null,
                        onTest: null,
                      ),
                      const SizedBox(height: 18),
                      const Divider(height: 1),
                      const SizedBox(height: 10),
                      TextButton.icon(
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const DeployBackendScreen(),
                          ),
                        ),
                        icon: const Icon(Icons.menu_book_outlined, size: 18),
                        label: Text(context.l10n.deployBackendGuide),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _InitialLanguageToggle extends StatelessWidget {
  const _InitialLanguageToggle({required this.settingsController});

  final AppSettingsController settingsController;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: settingsController,
      builder: (BuildContext context, Widget? _) {
        final AppLanguage current = settingsController.language;
        final AppLanguage next =
            current == AppLanguage.zh ? AppLanguage.en : AppLanguage.zh;
        return TextButton(
          onPressed: () {
            settingsController.setLanguage(next);
          },
          child: const Text('中/En'),
        );
      },
    );
  }
}

class _CredentialActionButtons extends StatelessWidget {
  const _CredentialActionButtons({
    required this.active,
    required this.isImporting,
    required this.isTesting,
    required this.showCameraScan,
    required this.onScan,
    required this.onPaste,
    required this.onUpload,
    required this.onSsh,
    required this.onTest,
  });

  final MachineCredential? active;
  final bool isImporting;
  final bool isTesting;
  final bool showCameraScan;
  final VoidCallback onScan;
  final VoidCallback onPaste;
  final VoidCallback onUpload;
  final VoidCallback? onSsh;
  final VoidCallback? onTest;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: <Widget>[
        if (showCameraScan)
          FilledButton.icon(
            onPressed: isImporting ? null : onScan,
            icon: isImporting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.qr_code_scanner_rounded),
            label: Text(context.l10n.scanQr),
          ),
        OutlinedButton.icon(
          onPressed: isImporting ? null : onPaste,
          icon: const Icon(Icons.content_paste_rounded),
          label: Text(context.l10n.pasteCredential),
        ),
        OutlinedButton.icon(
          onPressed: isImporting ? null : onUpload,
          icon: const Icon(Icons.image_search_rounded),
          label: Text(context.l10n.uploadQrImage),
        ),
        if (onSsh != null)
          FilledButton.icon(
            onPressed: active == null ? null : onSsh,
            icon: const Icon(Icons.terminal_rounded),
            label: Text(context.l10n.enterSsh),
          ),
        if (onTest != null)
          OutlinedButton.icon(
            onPressed: active == null || isTesting ? null : onTest,
            icon: isTesting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.lan_outlined),
            label: Text(context.l10n.testMachine),
          ),
        if (isImporting)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 10),
                Text(context.l10n.testingCredentialConnection),
              ],
            ),
          ),
      ],
    );
  }
}

class _CredentialQrScannerScreen extends StatefulWidget {
  const _CredentialQrScannerScreen();

  @override
  State<_CredentialQrScannerScreen> createState() =>
      _CredentialQrScannerScreenState();
}

class _CredentialQrScannerScreenState
    extends State<_CredentialQrScannerScreen> {
  bool _handled = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.scanQrTitle)),
      body: Stack(
        children: <Widget>[
          MobileScanner(
            onDetect: (BarcodeCapture capture) {
              if (_handled) return;
              String? value;
              for (final Barcode barcode in capture.barcodes) {
                if (barcode.rawValue != null) {
                  value = barcode.rawValue;
                  break;
                }
              }
              if (value == null || value.trim().isEmpty) return;
              _handled = true;
              Navigator.of(context).pop(value);
            },
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.surface.withValues(alpha: 0.92),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(context.l10n.scanQrHint),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MachineTile extends StatelessWidget {
  const _MachineTile({
    required this.credential,
    required this.active,
    required this.onSelect,
    required this.onDelete,
  });

  final MachineCredential credential;
  final bool active;
  final VoidCallback onSelect;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      leading: Icon(
        active ? Icons.radio_button_checked : Icons.radio_button_unchecked,
        color: active ? Theme.of(context).colorScheme.primary : null,
      ),
      title: Text(
        credential.displayName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        credential.hostLabel,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline),
        tooltip: context.l10n.delete,
        onPressed: onDelete,
      ),
      selected: active,
      onTap: onSelect,
    );
  }
}

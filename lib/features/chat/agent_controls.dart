import 'package:flutter/material.dart';

import '../../core/backend/backend_client.dart';
import '../../core/i18n/app_strings.dart';
import '../../core/models/agent_options.dart';

/// Per-agent Model / Effort / Permission / Fast controls shown in the composer's
/// "+" drawer. Capability-aware: only groups the agent supports are rendered
/// for the current workdir+agent scope, so every device in that scope shares
/// them.

const List<String> _groupOrder = <String>['model', 'effort', 'permission'];

/// Option catalogs describe what the installed CLI ships, not what the current
/// scope selected, so one fetch serves every workdir on a machine. They are kept
/// across opens because the composer rebuilds this widget every time its "+"
/// drawer opens: without a cache each open showed a spinner and then jumped to
/// its real height while the panel was still animating.
final Map<String, AgentOptionsCatalog> _catalogCache =
    <String, AgentOptionsCatalog>{};

/// Drop the cached catalogs. Call this when the app switches machines: another
/// backend host can have different CLIs, and different versions of them.
void clearAgentOptionsCache() => _catalogCache.clear();

IconData _groupIcon(String group) {
  switch (group) {
    case 'model':
      return Icons.auto_awesome_outlined;
    case 'effort':
      return Icons.psychology_outlined;
    case 'permission':
      return Icons.shield_outlined;
    default:
      return Icons.tune_rounded;
  }
}

String _groupLabel(AppStrings l10n, String group) {
  switch (group) {
    case 'model':
      return l10n.agentModel;
    case 'effort':
      return l10n.agentEffort;
    case 'permission':
      return l10n.agentPermission;
    default:
      return group;
  }
}

String _groupTitle(AppStrings l10n, String group) {
  switch (group) {
    case 'model':
      return l10n.agentModelTitle;
    case 'effort':
      return l10n.agentEffortTitle;
    case 'permission':
      return l10n.agentPermissionTitle;
    default:
      return group;
  }
}

String _optionLabel(AppStrings l10n, String group, AgentOption option) {
  if (group != 'effort') return option.label;
  switch (option.id) {
    case 'minimal':
      return l10n.agentEffortMinimal;
    case 'low':
      return l10n.agentEffortLow;
    case 'medium':
      return l10n.agentEffortMedium;
    case 'high':
      return l10n.agentEffortHigh;
    case 'xhigh':
      return l10n.agentEffortExtraHigh;
    case 'max':
      return l10n.agentEffortMax;
    case 'ultra':
      return l10n.agentEffortUltra;
    default:
      return option.label;
  }
}

class AgentControlsButtons extends StatefulWidget {
  const AgentControlsButtons({
    required this.backend,
    required this.agentKey,
    this.onOpenPage,
    super.key,
  });

  final BackendClient backend;
  final String agentKey;
  final VoidCallback? onOpenPage;

  @override
  State<AgentControlsButtons> createState() => _AgentControlsButtonsState();
}

class _AgentControlsButtonsState extends State<AgentControlsButtons> {
  AgentOptionsCatalog? _catalog;
  AgentSettings _settings = AgentSettings.empty;
  // Settings are per workdir+agent, so unlike the catalog they are always
  // fetched. Held as a future too: the buttons now render from the cached
  // catalog before this lands, so a quick tap must wait for the real selection
  // instead of opening a page on the defaults.
  Future<AgentSettings> _settingsReady =
      Future<AgentSettings>.value(AgentSettings.empty);
  bool _loading = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(AgentControlsButtons oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.agentKey != widget.agentKey) {
      _load();
    }
  }

  void _adoptSettings(AgentSettings settings) {
    _settings = settings;
    _settingsReady = Future<AgentSettings>.value(settings);
  }

  Future<void> _load() async {
    final String agentKey = widget.agentKey;
    final AgentOptionsCatalog? cached = _catalogCache[agentKey];
    final Future<AgentSettings> pending =
        widget.backend.fetchAgentSettings(agentKey);
    setState(() {
      _catalog = cached;
      _settingsReady = pending;
      // A cached catalog already says which buttons exist, so the panel opens at
      // its final size and this fetch only corrects it.
      _loading = cached == null;
      _failed = false;
    });
    try {
      final List<Object> results = await Future.wait(<Future<Object>>[
        widget.backend.fetchAgentOptions(agentKey),
        pending,
      ]);
      if (!mounted || agentKey != widget.agentKey) return;
      final AgentOptionsCatalog catalog = results[0] as AgentOptionsCatalog;
      _catalogCache[agentKey] = catalog;
      setState(() {
        _catalog = catalog;
        _adoptSettings(results[1] as AgentSettings);
        _loading = false;
      });
    } catch (_) {
      if (!mounted || agentKey != widget.agentKey) return;
      setState(() {
        _loading = false;
        // A cached catalog is still worth showing; only a cold failure is fatal.
        _failed = _catalog == null;
      });
    }
  }

  Future<AgentSettings> _resolvedSettings() async {
    try {
      return await _settingsReady;
    } catch (_) {
      return _settings;
    }
  }

  Future<void> _openGroup(String group) async {
    final AgentOptionsCatalog? catalog = _catalog;
    if (catalog == null) return;
    final AgentSettings settings = await _resolvedSettings();
    if (!mounted) return;
    final String? modelId =
        catalog.resolveSelection('model', settings['model']);
    final String current = catalog.resolveSelection(
          group,
          settings[group],
          modelId: modelId,
        ) ??
        '';
    final NavigatorState navigator = Navigator.of(context);
    widget.onOpenPage?.call();
    final AgentSettings? result = await navigator.push<AgentSettings>(
      MaterialPageRoute<AgentSettings>(
        builder: (BuildContext ctx) => _AgentOptionPage(
          backend: widget.backend,
          agentKey: widget.agentKey,
          group: group,
          catalog: catalog,
          current: current,
          modelId: modelId,
          fastEnabled: settings['fast'] == 'on',
        ),
      ),
    );
    if (!mounted || result == null) return;
    // The page saved the selection and, if it updated the CLI, refreshed the
    // cached catalog. Adopting both is what a reload would have fetched.
    setState(() {
      _catalog = _catalogCache[widget.agentKey] ?? catalog;
      _adoptSettings(result);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 18),
        child: SizedBox(
          height: 18,
          width: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_failed) {
      return Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: _load,
          icon: const Icon(Icons.refresh_rounded, size: 18),
          label: Text(context.l10n.agentControlsLoadFailed),
        ),
      );
    }
    final AgentOptionsCatalog? catalog = _catalog;
    if (catalog == null) return const SizedBox.shrink();
    final String? modelId = catalog.resolveSelection(
      'model',
      _settings['model'],
    );
    final List<String> groups = _groupOrder
        .where(
          (String group) =>
              catalog.supportsGroup(group) &&
              catalog.optionsFor(group, modelId: modelId).isNotEmpty,
        )
        .toList(growable: false);
    if (groups.isEmpty) return const SizedBox.shrink();

    return Wrap(
      spacing: 14,
      runSpacing: 14,
      children: <Widget>[
        for (final String group in groups)
          ComposerActionButton(
            icon: _groupIcon(group),
            label: _groupLabel(context.l10n, group),
            onPressed: () => _openGroup(group),
          ),
      ],
    );
  }
}

class ComposerActionButton extends StatelessWidget {
  const ComposerActionButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return SizedBox(
      width: 92,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: colors.surface,
                  border: Border.all(color: colors.outlineVariant),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, color: colors.onSurfaceVariant),
              ),
              const SizedBox(height: 7),
              Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: colors.onSurfaceVariant,
                  fontSize: 12,
                  height: 1.15,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Page listing the choices for one control group. Model and effort pages also
/// expose the installed CLI version and updater because both catalogs can change
/// with a CLI release. Saves on selection and pops with the new AgentSettings.
class _AgentOptionPage extends StatefulWidget {
  const _AgentOptionPage({
    required this.backend,
    required this.agentKey,
    required this.group,
    required this.catalog,
    required this.current,
    required this.modelId,
    required this.fastEnabled,
  });

  final BackendClient backend;
  final String agentKey;
  final String group;
  final AgentOptionsCatalog catalog;
  final String current;
  final String? modelId;
  final bool fastEnabled;

  @override
  State<_AgentOptionPage> createState() => _AgentOptionPageState();
}

class _AgentOptionPageState extends State<_AgentOptionPage> {
  late AgentOptionsCatalog _catalog;
  late String _current;
  String? _modelId;
  bool _saving = false;
  bool _savingFast = false;
  late bool _fastEnabled;
  bool _updating = false;
  String _version = '';

  bool get _isModel => widget.group == 'model';
  bool get _canUpdateCli => _isModel || widget.group == 'effort';

  @override
  void initState() {
    super.initState();
    _catalog = widget.catalog;
    _fastEnabled = widget.fastEnabled;
    _modelId = _catalog.resolveSelection('model', widget.modelId);
    _current = _catalog.resolveSelection(
          widget.group,
          widget.current,
          modelId: _modelId,
        ) ??
        '';
    if (_canUpdateCli) _loadVersion();
  }

  Future<void> _loadVersion() async {
    try {
      final String version =
          await widget.backend.fetchAgentVersion(widget.agentKey);
      if (!mounted) return;
      setState(() => _version = version);
    } catch (_) {
      // Version label is best-effort.
    }
  }

  Future<void> _select(String id) async {
    if (_saving || _updating) return;
    setState(() {
      _saving = true;
      _current = id;
    });
    try {
      final AgentSettings settings = await widget.backend
          .updateAgentSetting(widget.agentKey, widget.group, id);
      if (!mounted) return;
      Navigator.of(context).pop(settings);
    } catch (err) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.agentSettingSaveFailed(err))),
      );
    }
  }

  Future<void> _toggleFast(bool enabled) async {
    if (_savingFast || _saving || _updating) return;
    setState(() => _savingFast = true);
    try {
      await widget.backend.updateAgentSetting(
        widget.agentKey,
        'fast',
        enabled ? 'on' : 'off',
      );
      if (!mounted) return;
      setState(() => _fastEnabled = enabled);
    } catch (err) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.agentSettingSaveFailed(err))),
      );
    } finally {
      if (mounted) setState(() => _savingFast = false);
    }
  }

  Future<void> _update() async {
    final AppStrings l10n = context.l10n;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(l10n.agentUpdateConfirmTitle(widget.agentKey)),
        content: Text(l10n.agentUpdateConfirmBody),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.agentUpdateCli),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _updating = true);
    try {
      final AgentUpdateResult result =
          await widget.backend.updateAgentCli(widget.agentKey);
      if (!result.ok) {
        if (!mounted) return;
        setState(() => _updating = false);
        final String detail = result.timedOut
            ? l10n.agentUpdateTimedOut
            : result.output.isNotEmpty
                ? result.output
                : l10n.agentUpdateCommandFailed;
        final String visibleDetail =
            detail.length > 400 ? '${detail.substring(0, 400)}...' : detail;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.agentUpdateFailed(visibleDetail))),
        );
        return;
      }
      final List<Object> refreshed = await Future.wait(<Future<Object>>[
        widget.backend.fetchAgentOptions(widget.agentKey),
        widget.backend.fetchAgentSettings(widget.agentKey),
      ]);
      if (!mounted) return;
      final AgentOptionsCatalog options = refreshed[0] as AgentOptionsCatalog;
      final AgentSettings settings = refreshed[1] as AgentSettings;
      // The new binary can ship different models, so replace what the composer
      // will draw from next time it opens.
      _catalogCache[widget.agentKey] = options;
      final String? modelId = options.resolveSelection(
        'model',
        settings['model'],
      );
      final String current = options.resolveSelection(
            widget.group,
            settings[widget.group],
            modelId: modelId,
          ) ??
          '';
      setState(() {
        _catalog = options;
        _modelId = modelId;
        _current = current;
        _version = result.after.isNotEmpty ? result.after : _version;
        _updating = false;
      });
      final String message = result.changed
          ? l10n.agentUpdateDone(result.before, result.after)
          : l10n.agentUpdateNoChange;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    } catch (err) {
      if (!mounted) return;
      setState(() => _updating = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.agentUpdateFailed(err))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppStrings l10n = context.l10n;
    final ColorScheme colors = Theme.of(context).colorScheme;
    final List<AgentOption> options = _catalog.optionsFor(
      widget.group,
      modelId: _modelId,
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(_groupTitle(l10n, widget.group)),
      ),
      body: SafeArea(
        child: Column(
          children: <Widget>[
            Expanded(
              child: ListView.separated(
                itemCount: options.length +
                    (_isModel && _catalog.supportsGroup('fast') ? 1 : 0),
                separatorBuilder: (BuildContext context, int index) =>
                    Divider(height: 1, color: colors.outlineVariant),
                itemBuilder: (BuildContext ctx, int index) {
                  if (_isModel &&
                      _catalog.supportsGroup('fast') &&
                      index == 0) {
                    return SwitchListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 4,
                      ),
                      secondary: const Icon(Icons.bolt_rounded),
                      title: Text(l10n.agentFastMode),
                      subtitle: Text(l10n.agentFastModeHint),
                      value: _fastEnabled,
                      onChanged: _savingFast || _saving || _updating
                          ? null
                          : _toggleFast,
                    );
                  }
                  final int optionIndex = index -
                      (_isModel && _catalog.supportsGroup('fast') ? 1 : 0);
                  final AgentOption option = options[optionIndex];
                  final bool selected = option.id == _current;
                  return ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 4,
                    ),
                    onTap:
                        _saving || _updating ? null : () => _select(option.id),
                    leading: Icon(
                      selected
                          ? Icons.radio_button_checked_rounded
                          : Icons.radio_button_unchecked_rounded,
                      color:
                          selected ? colors.primary : colors.onSurfaceVariant,
                    ),
                    title: Text(_optionLabel(l10n, widget.group, option)),
                    subtitle: option.description == null
                        ? null
                        : Text(option.description!),
                  );
                },
              ),
            ),
            if (_canUpdateCli) _buildUpdateFooter(l10n, colors),
          ],
        ),
      ),
    );
  }

  Widget _buildUpdateFooter(AppStrings l10n, ColorScheme colors) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(top: BorderSide(color: colors.outlineVariant)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (_isModel) ...<Widget>[
            Text(
              l10n.agentUpdateMissingModel,
              style: TextStyle(color: colors.onSurfaceVariant, fontSize: 13),
            ),
            const SizedBox(height: 8),
          ],
          Row(
            children: <Widget>[
              FilledButton.tonalIcon(
                onPressed: _updating ? null : _update,
                icon: _updating
                    ? const SizedBox(
                        height: 16,
                        width: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.system_update_alt_rounded, size: 18),
                label:
                    Text(_updating ? l10n.agentUpdating : l10n.agentUpdateCli),
              ),
              const SizedBox(width: 12),
              if (_version.isNotEmpty)
                Expanded(
                  child: Text(
                    l10n.agentCliVersion(_version),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

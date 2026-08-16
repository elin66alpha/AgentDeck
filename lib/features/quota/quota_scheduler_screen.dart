import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/backend/backend_client.dart';
import '../../core/i18n/app_strings.dart';
import '../../core/util/time_format.dart';
import '../chat/bot_chat_controller.dart';

class QuotaSchedulerScreen extends StatefulWidget {
  const QuotaSchedulerScreen({
    required this.chatController,
    super.key,
  });

  final BotChatController chatController;

  @override
  State<QuotaSchedulerScreen> createState() => _QuotaSchedulerScreenState();
}

class _QuotaSchedulerScreenState extends State<QuotaSchedulerScreen> {
  final Map<String, TextEditingController> _controllers =
      <String, TextEditingController>{};
  final Map<String, String> _serverPrompts = <String, String>{};
  final Set<String> _savingAgents = <String>{};

  UsageReport? _usage;
  List<QuotaSchedule> _schedules = const <QuotaSchedule>[];
  bool _loading = true;
  String? _error;
  late int _seenScheduleRevision;

  @override
  void initState() {
    super.initState();
    _seenScheduleRevision = widget.chatController.quotaScheduleRevision;
    // Show the last known quota straight away; _load replaces it once the fresh
    // report arrives from the usage APIs.
    _usage = widget.chatController.lastUsageReport;
    widget.chatController.addListener(_onControllerChanged);
    unawaited(_load());
  }

  @override
  void dispose() {
    widget.chatController.removeListener(_onControllerChanged);
    for (final TextEditingController controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _onControllerChanged() {
    final int revision = widget.chatController.quotaScheduleRevision;
    if (revision == _seenScheduleRevision) return;
    _seenScheduleRevision = revision;
    // A schedule event (created/sent/failed/cancelled — here or on another
    // device in this workspace) only changes the schedule list, never the usage
    // percentages, so refetch just the schedules and skip the costly usage call.
    unawaited(_reloadSchedules());
  }

  // Refetch only the schedules and re-sync the inputs against them, reusing the
  // usage snapshot already loaded. Cheaper than [_load], which also hits the
  // external usage API even though schedule changes never affect quota numbers.
  Future<void> _reloadSchedules() async {
    try {
      final List<QuotaSchedule> schedules =
          await widget.chatController.quotaSchedules();
      if (!mounted) return;
      final UsageReport? usage = _usage;
      if (usage != null) _syncControllers(usage, schedules);
      setState(() => _schedules = schedules);
    } catch (_) {
      // Keep the last snapshot; manual refresh or the next event recovers.
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final List<Object> results = await Future.wait<Object>(<Future<Object>>[
        widget.chatController.usageReport(),
        widget.chatController.quotaSchedules(),
      ]);
      final UsageReport usage = results[0] as UsageReport;
      final List<QuotaSchedule> schedules = results[1] as List<QuotaSchedule>;
      if (!mounted) return;
      _syncControllers(usage, schedules);
      setState(() {
        _usage = usage;
        _schedules = schedules;
        _loading = false;
      });
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _error = err.toString();
        _loading = false;
      });
    }
  }

  void _syncControllers(UsageReport usage, List<QuotaSchedule> schedules) {
    final Set<String> supported =
        _supportedAgents(usage).map((UsageAgent agent) => agent.key).toSet();
    final Map<String, QuotaSchedule> pendingBySource =
        <String, QuotaSchedule>{};
    for (final QuotaSchedule schedule in schedules) {
      if (schedule.status != 'pending' && schedule.status != 'running') {
        continue;
      }
      pendingBySource[schedule.sourceKey] = schedule;
    }

    for (final String key in supported) {
      final TextEditingController controller = _controllers.putIfAbsent(
        key,
        () => TextEditingController(),
      );
      final String nextPrompt = pendingBySource[key]?.prompt ?? '';
      final bool firstSync = !_serverPrompts.containsKey(key);
      final String previousPrompt = _serverPrompts[key] ?? '';
      if (firstSync || controller.text == previousPrompt) {
        controller.text = nextPrompt;
      }
      _serverPrompts[key] = nextPrompt;
    }

    final List<String> staleKeys = _controllers.keys
        .where((String key) => !supported.contains(key))
        .toList(growable: false);
    for (final String key in staleKeys) {
      _controllers.remove(key)?.dispose();
      _serverPrompts.remove(key);
    }
  }

  Future<void> _save(UsageAgent agent) async {
    final TextEditingController? controller = _controllers[agent.key];
    final String prompt = controller?.text.trim() ?? '';
    if (prompt.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.messageRequired)),
      );
      return;
    }
    setState(() => _savingAgents.add(agent.key));
    try {
      final UsageQuota? quota = _fiveHourQuota(agent);
      final QuotaSchedule schedule =
          await widget.chatController.createQuotaSchedule(
        sourceKey: agent.key,
        agentKey: agent.key,
        prompt: prompt,
        targetResetsAt: quota?.resetsAt,
        replaceExisting: true,
      );
      controller?.text = schedule.prompt;
      _serverPrompts[agent.key] = schedule.prompt;
      await _reloadSchedules();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.scheduleUpdated(agent.label))),
      );
    } catch (err) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.scheduleFailed(err))),
      );
    } finally {
      if (mounted) {
        setState(() => _savingAgents.remove(agent.key));
      }
    }
  }

  // Cancel the pending/running schedule for this agent and clear its input.
  Future<void> _clear(UsageAgent agent, QuotaSchedule schedule) async {
    setState(() => _savingAgents.add(agent.key));
    try {
      await widget.chatController.cancelQuotaSchedule(schedule.id);
      _controllers[agent.key]?.clear();
      _serverPrompts[agent.key] = '';
      await _reloadSchedules();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.scheduleCleared(agent.label))),
      );
    } catch (err) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.scheduleFailed(err))),
      );
    } finally {
      if (mounted) {
        setState(() => _savingAgents.remove(agent.key));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final UsageReport? usage = _usage;
    final List<UsageAgent> agents =
        usage == null ? const <UsageAgent>[] : _supportedAgents(usage);
    return Scaffold(
      appBar: AppBar(
        title: Text(context.l10n.quotaScheduler),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: context.l10n.refresh,
            onPressed: _loading ? null : () => unawaited(_load()),
          ),
        ],
      ),
      body: SafeArea(
        child: _buildBody(context, agents),
      ),
    );
  }

  Widget _buildBody(BuildContext context, List<UsageAgent> agents) {
    if (_loading && _usage == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _usage == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _error!,
            textAlign: TextAlign.center,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: agents.length,
      separatorBuilder: (_, __) => Divider(
        height: 28,
        color: Theme.of(context).colorScheme.outlineVariant,
      ),
      itemBuilder: (BuildContext context, int index) {
        final UsageAgent agent = agents[index];
        final UsageQuota? quota = _fiveHourQuota(agent);
        final QuotaSchedule? schedule = _activeScheduleFor(agent.key);
        final TextEditingController controller = _controllers.putIfAbsent(
          agent.key,
          () => TextEditingController(text: schedule?.prompt ?? ''),
        );
        return Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 880),
            child: _QuotaSchedulerRow(
              agentName: agent.label,
              refreshTime: formatShortTime(
                context,
                quota?.resetsAt ?? schedule?.targetResetsAt,
              ),
              controller: controller,
              saving: _savingAgents.contains(agent.key),
              onSend: () => _save(agent),
              onClear: schedule == null ? null : () => _clear(agent, schedule),
            ),
          ),
        );
      },
    );
  }

  QuotaSchedule? _activeScheduleFor(String sourceKey) {
    for (final QuotaSchedule schedule in _schedules) {
      if (schedule.sourceKey == sourceKey &&
          (schedule.status == 'pending' || schedule.status == 'running')) {
        return schedule;
      }
    }
    return null;
  }
}

class _QuotaSchedulerRow extends StatelessWidget {
  const _QuotaSchedulerRow({
    required this.agentName,
    required this.refreshTime,
    required this.controller,
    required this.saving,
    required this.onSend,
    required this.onClear,
  });

  final String agentName;
  final String refreshTime;
  final TextEditingController controller;
  final bool saving;
  final VoidCallback onSend;

  /// Cancels the pending schedule for this agent. Null when none is scheduled,
  /// which hides the clear button.
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final Widget title = Text(
      agentName,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w700,
      ),
    );
    final Widget refresh = Text(
      '${context.l10n.refreshAt}: $refreshTime',
      style: TextStyle(color: colors.outline, fontSize: 13),
    );
    final Widget promptField = TextField(
      controller: controller,
      minLines: 2,
      maxLines: 5,
      decoration: InputDecoration(
        labelText: context.l10n.prompt,
        border: const OutlineInputBorder(),
      ),
    );
    final Widget sendButton = FilledButton.icon(
      onPressed: saving ? null : onSend,
      icon: saving
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.send_rounded),
      label: Text(context.l10n.send),
    );
    final Widget? clearButton = onClear == null
        ? null
        : TextButton.icon(
            onPressed: saving ? null : onClear,
            icon: const Icon(Icons.delete_outline_rounded, size: 18),
            label: Text(context.l10n.clearSchedule),
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
            ),
          );
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool compact = constraints.maxWidth < 680;
        if (compact) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              title,
              const SizedBox(height: 4),
              refresh,
              const SizedBox(height: 10),
              promptField,
              const SizedBox(height: 10),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  if (clearButton != null) clearButton,
                  sendButton,
                ],
              ),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(child: title),
                const SizedBox(width: 12),
                refresh,
                if (clearButton != null) ...<Widget>[
                  const SizedBox(width: 4),
                  clearButton,
                ],
              ],
            ),
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(child: promptField),
                const SizedBox(width: 10),
                SizedBox(
                  height: 56,
                  child: sendButton,
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

List<UsageAgent> _supportedAgents(UsageReport usage) {
  return usage.agents
      .where(
        (UsageAgent agent) => agent.key == 'claude' || agent.key == 'codex',
      )
      .toList(growable: false);
}

UsageQuota? _fiveHourQuota(UsageAgent agent) {
  for (final UsageQuota quota in agent.quotas) {
    if (quota.key == 'five_hour') return quota;
  }
  return null;
}

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/backend/backend_client.dart';
import '../../core/i18n/app_strings.dart';
import '../../core/util/time_format.dart';
import '../chat/bot_chat_controller.dart';

class QuotaUsageScreen extends StatefulWidget {
  const QuotaUsageScreen({
    required this.chatController,
    super.key,
  });

  final BotChatController chatController;

  @override
  State<QuotaUsageScreen> createState() => _QuotaUsageScreenState();
}

// The quota sources the backend reports, in display order, with the label shown
// until each one's first report arrives.
const Map<String, String> _usageSources = <String, String>{
  'claude': 'Claude Code',
  'codex': 'Codex',
};

class _QuotaUsageScreenState extends State<QuotaUsageScreen> {
  // Seeded from the last report the app fetched, so reopening the screen shows
  // the previous numbers at once. Each source is then refreshed on its own and
  // lands as soon as it answers: Codex's probe can take seconds, Claude's not.
  UsageReport? _report;
  final Map<String, String> _errors = <String, String>{};
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _report = widget.chatController.lastUsageReport;
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _errors.clear();
    });
    await Future.wait(_usageSources.keys.map(_refreshSource));
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _refreshSource(String source) async {
    try {
      final UsageReport report =
          await widget.chatController.usageReport(source: source);
      if (!mounted) return;
      setState(() => _report = report);
    } catch (err) {
      if (!mounted) return;
      setState(() => _errors[source] = err.toString());
      // With numbers already on screen the failure would otherwise be silent.
      if (_agent(source) != null) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(err.toString())));
      }
    }
  }

  UsageAgent? _agent(String source) {
    for (final UsageAgent agent in _report?.agents ?? const <UsageAgent>[]) {
      if (agent.key == source) return agent;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(context.l10n.usageQuery),
        bottom: _loading
            ? const PreferredSize(
                preferredSize: Size.fromHeight(2),
                child: LinearProgressIndicator(minHeight: 2),
              )
            : null,
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: context.l10n.refresh,
            onPressed: _loading ? null : () => unawaited(_refresh()),
          ),
        ],
      ),
      body: SafeArea(child: _buildBody(context)),
    );
  }

  Widget _buildBody(BuildContext context) {
    final List<String> sources = _usageSources.keys.toList(growable: false);
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: sources.length,
        separatorBuilder: (_, __) => const SizedBox(height: 12),
        itemBuilder: (BuildContext context, int index) {
          final String source = sources[index];
          return Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: _UsageAgentPanel(
                label: _usageSources[source]!,
                agent: _agent(source),
                error: _errors[source],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _UsageAgentPanel extends StatelessWidget {
  const _UsageAgentPanel({required this.label, this.agent, this.error});

  final String label;
  // Null until the source's first report arrives.
  final UsageAgent? agent;
  // Only drawn while [agent] is null; with numbers on screen a failed refresh
  // is reported by a snackbar instead.
  final String? error;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final UsageAgent? agent = this.agent;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(color: colors.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                flex: 2,
                child: Text(
                  agent?.label ?? label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  softWrap: false,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                  ),
                ),
              ),
              if (agent != null && agent.detail.isNotEmpty) ...<Widget>[
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    agent.detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    softWrap: false,
                    textAlign: TextAlign.end,
                    style: TextStyle(color: colors.outline, fontSize: 12),
                  ),
                ),
              ],
            ],
          ),
          if (agent != null && (agent.asOf != null || agent.stale)) ...<Widget>[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                if (agent.asOf != null)
                  Text(
                    context.l10n.usageAsOf(
                      formatShortTime(context, agent.asOf),
                    ),
                    style: TextStyle(color: colors.outline, fontSize: 12),
                  ),
                if (agent.stale)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: colors.tertiaryContainer,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      context.l10n.usageStale,
                      style: TextStyle(
                        color: colors.onTertiaryContainer,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          if (agent == null)
            Text(
              error ?? context.l10n.loadingUsage,
              style: TextStyle(
                color: error == null ? colors.outline : colors.error,
              ),
            )
          else if (!agent.available)
            Text(
              context.l10n.unavailable,
              style: TextStyle(color: colors.outline),
            )
          else if (agent.error != null)
            Text(
              agent.error!,
              style: TextStyle(color: colors.error),
            )
          else if (agent.quotas.isEmpty)
            Text(
              context.l10n.unknown,
              style: TextStyle(color: colors.outline),
            )
          else
            for (final UsageQuota quota in agent.quotas)
              _UsageQuotaRow(quota: quota),
        ],
      ),
    );
  }
}

class _UsageQuotaRow extends StatelessWidget {
  const _UsageQuotaRow({required this.quota});

  final UsageQuota quota;

  String _formatPercent(BuildContext context, double? percent) {
    if (percent == null) return context.l10n.unknown;
    final double clamped = percent.clamp(0, 100).toDouble();
    if ((clamped - clamped.round()).abs() < 0.05) {
      return '${clamped.round()}%';
    }
    return '${clamped.toStringAsFixed(1)}%';
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final String label = switch (quota.key) {
      'five_hour' => context.l10n.fiveHourQuota,
      'seven_day' => context.l10n.weeklyQuota,
      _ => quota.label,
    };
    // An expired bucket's cached percentage is meaningless (its window already
    // reset while the source was unreachable), so drop the number and let the
    // bar fall to its indeterminate "awaiting fresh data" state.
    final double? percent = quota.expired ? null : quota.remainingPercent;
    final String percentText = _formatPercent(context, percent);
    final double? value =
        percent == null ? null : (percent / 100).clamp(0.0, 1.0).toDouble();
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              SizedBox(
                width: 84,
                child: Text(
                  label,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      quota.expired
                          ? context.l10n.quotaWindowReset
                          : '$percentText ${context.l10n.remaining}',
                      style: quota.expired
                          ? TextStyle(color: colors.tertiary)
                          : null,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${context.l10n.refreshAt}: ${formatShortTime(context, quota.resetsAt)}',
                      style: TextStyle(color: colors.outline, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: value,
            minHeight: 6,
            borderRadius: BorderRadius.circular(999),
          ),
        ],
      ),
    );
  }
}

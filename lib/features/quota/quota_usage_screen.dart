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

class _QuotaUsageScreenState extends State<QuotaUsageScreen> {
  // Seeded from the last report the app fetched, so reopening the screen shows
  // the previous numbers at once. The refresh below then replaces them; a query
  // that reaches Anthropic and OpenAI is too slow to hold an empty screen for.
  UsageReport? _report;
  String? _error;
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
      _error = null;
    });
    try {
      final UsageReport report = await widget.chatController.usageReport();
      if (!mounted) return;
      setState(() {
        _report = report;
        _loading = false;
      });
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _error = err.toString();
        _loading = false;
      });
      // With numbers already on screen the failure would otherwise be silent.
      if (_report != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_error!)),
        );
      }
    }
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
    final UsageReport? report = _report;
    if (report == null) {
      if (_error != null) {
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
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const CircularProgressIndicator(),
            const SizedBox(height: 12),
            Text(context.l10n.loadingUsage),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: report.agents.length,
        separatorBuilder: (_, __) => const SizedBox(height: 12),
        itemBuilder: (BuildContext context, int index) {
          return Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: _UsageAgentPanel(agent: report.agents[index]),
            ),
          );
        },
      ),
    );
  }
}

class _UsageAgentPanel extends StatelessWidget {
  const _UsageAgentPanel({required this.agent});

  final UsageAgent agent;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
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
                  agent.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  softWrap: false,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                  ),
                ),
              ),
              if (agent.detail.isNotEmpty) ...<Widget>[
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
          if (agent.asOf != null || agent.stale) ...<Widget>[
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
          if (!agent.available)
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

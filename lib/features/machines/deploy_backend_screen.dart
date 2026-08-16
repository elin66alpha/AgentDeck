import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/i18n/app_strings.dart';

/// A short, self-contained tutorial that walks a first-time user through
/// deploying the Relay backend on their own machine and then connecting the
/// app to it. Reached from the empty-credential state on the first screen.
class DeployBackendScreen extends StatelessWidget {
  const DeployBackendScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final AppStrings strings = context.l10n;
    final bool zh = strings.isZh;
    final List<_DeployStep> steps = zh ? _zhSteps : _enSteps;
    return Scaffold(
      appBar: AppBar(title: Text(strings.deployBackendGuide)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          children: <Widget>[
            Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Text(
                      zh
                          ? '在自己的机器上部署后端'
                          : 'Deploy the backend on your own machine',
                      style: Theme.of(context)
                          .textTheme
                          .headlineSmall
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      zh
                          ? 'Relay 的智能体跑在你自己的电脑或服务器上，应用只是它的入口。下面五步带你部署后端，并把这个应用连上去。'
                          : 'Relay agents run on a computer or server you own — the app is just the door to them. These five steps deploy the backend and connect this app to it.',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                            height: 1.45,
                          ),
                    ),
                    const SizedBox(height: 20),
                    for (int index = 0; index < steps.length; index += 1)
                      _DeployStepTile(index: index + 1, step: steps[index]),
                    const SizedBox(height: 4),
                    _TipCard(
                      text: zh
                          ? '想要长期稳定、加固的部署（开机自启、HTTPS、反向代理等），参考仓库里的 docs/handbook.md。'
                          : 'For a stable, hardened deployment (auto-start, HTTPS, reverse proxy, …), see docs/handbook.md in the repository.',
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DeployStepTile extends StatelessWidget {
  const _DeployStepTile({required this.index, required this.step});

  final int index;
  final _DeployStep step;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerLow,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            CircleAvatar(
              radius: 16,
              backgroundColor: theme.colorScheme.primaryContainer,
              foregroundColor: theme.colorScheme.onPrimaryContainer,
              child: Text(
                '$index',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    step.title,
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    step.body,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      height: 1.45,
                    ),
                  ),
                  if (step.commands.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 12),
                    for (final _Command command in step.commands)
                      _CommandBlock(command: command),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CommandBlock extends StatelessWidget {
  const _CommandBlock({required this.command});

  final _Command command;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            command.label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.outline,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: SelectableText(
                    command.code,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 13,
                      height: 1.4,
                    ),
                  ),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  iconSize: 18,
                  tooltip: context.l10n.copy,
                  icon: const Icon(Icons.copy_rounded),
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: command.code));
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(context.l10n.copied)),
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TipCard extends StatelessWidget {
  const _TipCard({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(
            Icons.lightbulb_outline_rounded,
            size: 20,
            color: theme.colorScheme.onSecondaryContainer,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSecondaryContainer,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Command {
  const _Command({required this.label, required this.code});

  final String label;
  final String code;
}

class _DeployStep {
  const _DeployStep({
    required this.title,
    required this.body,
    this.commands = const <_Command>[],
  });

  final String title;
  final String body;
  final List<_Command> commands;
}

const List<_Command> _setupCommands = <_Command>[
  _Command(label: 'Linux', code: './backends/linux/setup.sh'),
  _Command(label: 'macOS', code: './backends/macos/setup.sh'),
  _Command(
    label: 'Windows (PowerShell)',
    code: r'.\backends\windows\setup.ps1',
  ),
];

const List<_DeployStep> _zhSteps = <_DeployStep>[
  _DeployStep(
    title: '准备一台后端机器',
    body: '一台你自己的电脑或服务器都行：家里的 PC、Mac，或一台云服务器。'
        '先装好 Node.js 18+ 和至少一个 CLI 智能体（Claude Code、Codex、OpenCode 等）。'
        '可在主机上登录，兼容的 OAuth agent 也可稍后在 Relay 中登录。',
  ),
  _DeployStep(
    title: '下载 Relay，运行安装脚本',
    body: '把 Relay 仓库放到这台机器上，在仓库根目录按操作系统运行对应脚本。脚本会装好依赖并准备后端。',
    commands: _setupCommands,
  ),
  _DeployStep(
    title: '选择应用连接后端的方式',
    body: '脚本会问应用要怎么访问后端，三选一：\n'
        '· 直连模式：服务器有公网 IP 或域名时最简单。\n'
        '· Cloudflare 隧道：用你自己的域名拿到稳定的 HTTPS 地址。\n'
        '· Cloudflare 快速隧道：最快试用，不需要域名，但地址可能会变。',
  ),
  _DeployStep(
    title: '拿到加密凭证',
    body: '脚本会启动后端，并打印一个加密的凭证二维码，同时在硬盘上生成对应的 JSON 文件。'
        '这个二维码（或 JSON）就是把应用连上后端的钥匙，请用你设置的密码保护好它。',
  ),
  _DeployStep(
    title: '回到本页，连接前端',
    body: '回到这个页面，三种方式任选其一：扫描二维码、上传二维码图片，或粘贴 JSON 内容。'
        '然后输入你生成凭证时设置的密码。连接成功后，就能在应用里直接指挥后端的智能体了。',
  ),
];

const List<_DeployStep> _enSteps = <_DeployStep>[
  _DeployStep(
    title: 'Prepare a backend machine',
    body: 'Any computer you own works: a home PC, a Mac, or a cloud server. '
        'Install Node.js 18+ and at least one CLI agent (Claude Code, Codex, '
        'OpenCode, …). Log in on the host, or use Relay later for a '
        'compatible OAuth agent.',
  ),
  _DeployStep(
    title: 'Download Relay and run the setup script',
    body: 'Put the Relay repository on that machine and, from the repo root, '
        'run the script for its operating system. It installs the '
        'dependencies and prepares the backend.',
    commands: _setupCommands,
  ),
  _DeployStep(
    title: 'Choose how the app reaches the backend',
    body: 'The script asks how the app should connect — pick one:\n'
        '· Direct mode: simplest when the server has a public IP or domain.\n'
        '· Cloudflare Tunnel: a stable HTTPS address under your own domain.\n'
        '· Cloudflare Quick Tunnel: the fastest trial, no domain needed, but '
        'the URL may change.',
  ),
  _DeployStep(
    title: 'Get the encrypted credential',
    body: 'The script starts the backend and prints an encrypted credential QR '
        'code, plus a matching JSON file on disk. That QR (or JSON) is the key '
        'that links the app to your backend — protect it with the password you set.',
  ),
  _DeployStep(
    title: 'Come back here and connect',
    body: 'Return to this screen and use any one option: scan the QR code, '
        'upload the QR image, or paste the JSON. Then enter the password you '
        'chose. Once connected, you can drive the backend agents right from the app.',
  ),
];

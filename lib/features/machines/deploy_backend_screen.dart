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
                          ? 'Relay 的智能体跑在你自己的电脑或服务器上，应用只是它的入口。按下面的步骤准备主机、部署后端、导入凭证，并检查首次连接。'
                          : 'Relay agents run on a computer or server you own — the app is just the door to them. Follow these steps to prepare the host, deploy the backend, import a credential, and check your first connection.',
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

const List<_Command> _statusCommands = <_Command>[
  _Command(label: 'Linux', code: './backends/linux/status.sh'),
  _Command(label: 'macOS', code: './backends/macos/status.sh'),
  _Command(
    label: 'Windows (PowerShell)',
    code: r'.\backends\windows\status.ps1',
  ),
];

const List<_DeployStep> _zhSteps = <_DeployStep>[
  _DeployStep(
    title: '准备一台后端机器',
    body: '一台你自己的电脑或服务器都行：家里的 PC、Mac，或一台云服务器。'
        '先装好 Node.js 18+ 和至少一个 CLI 智能体（Claude Code、Codex、OpenCode 或 Hermes），'
        '并直接在主机上完成登录或 provider 配置；Relay 不代办 CLI 登录。\n先在主机终端确认选定的 CLI 可以使用。Linux 还需 PM2、Python 3、make 和 C++ 编译器；Unix 下载文件夹需要 zip。使用 Cloudflare 隧道前需安装 cloudflared。',
  ),
  _DeployStep(
    title: '下载 Relay，运行安装脚本',
    body:
        '把 Relay 仓库放到这台机器上，在仓库根目录按操作系统运行对应脚本。脚本会安装后端依赖、准备 server/.env，并配置对应的启动服务。安装过程中保持终端打开，按提示选择端口、网络方式和凭证密码。',
    commands: _setupCommands,
  ),
  _DeployStep(
    title: '选择应用连接后端的方式',
    body: '脚本会问应用要怎么访问后端，三选一：\n'
        '· 直连模式：填写应用所在设备实际能访问的地址；公开到互联网前应配置 HTTPS。其他设备不能用 localhost 访问你的主机。\n'
        '· Cloudflare 隧道：需要自己的 Cloudflare 域名，配置稳定的 HTTPS 地址。\n'
        '· Cloudflare 快速隧道：不需要域名，适合试用。重启后地址可能变化，届时需要用新地址重新生成并导入凭证。',
  ),
  _DeployStep(
    title: '拿到加密凭证',
    body:
        '脚本会启动后端，并打印一个加密的凭证二维码，同时在 server/credentials/ 下生成 .relay.png 和 .relay.json 文件。'
        '这个二维码（或 JSON）就是把应用连上后端的钥匙，请保存好生成时设置的密码，并为每个设备单独生成凭证，便于以后撤销。',
  ),
  _DeployStep(
    title: '返回凭证页面，连接应用',
    body: '返回凭证导入页面：移动端可扫描二维码；所有平台都可上传二维码图片或粘贴 JSON 内容。'
        '然后输入你生成凭证时设置的密码。连接后，在首页点击机器打开“机器详情”，重新检查 CLI 状态，再进入“文件系统”选择项目目录并设为工作路径。最后选择可用智能体，发送一条简单任务验证。',
  ),
  _DeployStep(
    title: '连接失败时按顺序检查',
    body:
        '先区分错误：解密失败请核对密码和凭证文件；连接失败请检查后端服务、端口、防火墙和地址是否仍有效。HTTPS 网页客户端也应连接 HTTPS 后端。\n在仓库根目录运行对应的状态命令，查看服务是否启动；Windows 日志在 %LOCALAPPDATA%\\Relay\\logs，macOS 在 ~/Library/Logs/Relay，Linux 可用 pm2 logs relay-server 查看。若应用已连通但智能体不可用，请到主机检查 CLI 安装与认证，再在机器详情重新检查。',
    commands: _statusCommands,
  ),
];

const List<_DeployStep> _enSteps = <_DeployStep>[
  _DeployStep(
    title: 'Prepare a backend machine',
    body: 'Any computer you own works: a home PC, a Mac, or a cloud server. '
        'Install Node.js 18+ and at least one CLI agent (Claude Code, Codex, '
        'OpenCode, or Hermes), then complete its login or provider setup on '
        'that host. Relay does not perform CLI login.\nFirst confirm the chosen CLI works in a host terminal. Linux also needs PM2, Python 3, make, and a C++ compiler; Unix folder downloads need zip. Install cloudflared before choosing either Cloudflare tunnel mode.',
  ),
  _DeployStep(
    title: 'Download Relay and run the setup script',
    body: 'Put the Relay repository on that machine and, from the repo root, '
        'run the script for its operating system. It installs the '
        'dependencies, prepares server/.env, and configures the startup service. Keep the terminal open and follow its prompts for the port, network mode, and credential passphrase.',
    commands: _setupCommands,
  ),
  _DeployStep(
    title: 'Choose how the app reaches the backend',
    body: 'The script asks how the app should connect — pick one:\n'
        '· Direct mode: enter an address reachable from the client device and configure HTTPS before public exposure. Other devices cannot use localhost to reach your host.\n'
        '· Cloudflare Tunnel: a stable HTTPS address under your own Cloudflare domain.\n'
        '· Cloudflare Quick Tunnel: the fastest trial, no domain needed, but '
        'the URL may change after restart. If it does, generate and import a credential with the new URL.',
  ),
  _DeployStep(
    title: 'Get the encrypted credential',
    body: 'The script starts the backend and prints an encrypted credential QR '
        'code and .relay.png / .relay.json files under server/credentials/. That QR (or JSON) is the key '
        'that links the app to your backend. Keep its passphrase and generate a separate credential for each device so access can be revoked individually.',
  ),
  _DeployStep(
    title: 'Return to credential import and connect',
    body:
        'Return to credential import. Mobile can scan the QR code; every platform '
        'can upload its QR image or paste the JSON. Then enter the password you '
        'chose. Once connected, tap the machine on Home to recheck CLI status in Machine details. Open File system, choose your project, and select Set as work path. Then choose an available agent and send a simple task to verify it.',
  ),
  _DeployStep(
    title: 'Troubleshoot the first connection',
    body:
        'Separate decryption errors from connection errors: check the passphrase and credential file for the former; check the backend service, port, firewall, and current URL for the latter. An HTTPS Web client should also use an HTTPS backend.\nRun the status command for your OS from the repository root. Windows logs are in %LOCALAPPDATA%\\Relay\\logs, macOS logs in ~/Library/Logs/Relay, and Linux logs are available with pm2 logs relay-server. If Relay connects but an agent is unavailable, check CLI installation and authentication on the host, then recheck Machine details.',
    commands: _statusCommands,
  ),
];

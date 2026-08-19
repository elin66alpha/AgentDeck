import 'package:flutter/material.dart';

/// The asset for an agent's brand icon. Only Codex flips to an inverse asset in
/// dark mode (its mark is near-black); the others read fine on both themes and
/// keep their single asset. Returns null for unknown keys so the caller can fall
/// back to a generic glyph.
String? agentIconAssetPath(String key, Brightness brightness) {
  final bool dark = brightness == Brightness.dark;
  return switch (key) {
    'claude' => 'assets/agent_icons/claude.png',
    'codex' => dark
        ? 'assets/agent_icons/codex_inverse.png'
        : 'assets/agent_icons/codex.png',
    'opencode' => 'assets/agent_icons/opencode.png',
    'hermes' => 'assets/agent_icons/hermes.png',
    _ => null,
  };
}

/// An agent's brand icon, shared by the agents drawer and the swarm transcript so
/// a member's avatar in a group chat matches its solo-chat icon. Theme-aware via
/// [agentIconAssetPath]; unknown keys render a generic code glyph.
class AgentIcon extends StatelessWidget {
  const AgentIcon({required this.agentKey, this.size = 28, super.key});

  final String agentKey;
  final double size;

  @override
  Widget build(BuildContext context) {
    final String? assetPath =
        agentIconAssetPath(agentKey, Theme.of(context).brightness);
    if (assetPath == null) {
      return Icon(Icons.code_rounded, size: size);
    }
    return SizedBox.square(
      dimension: size,
      child: Image.asset(
        assetPath,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.high,
        excludeFromSemantics: true,
      ),
    );
  }
}

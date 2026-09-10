import 'package:flutter/material.dart';

import '../../core/i18n/app_strings.dart';
import '../../core/settings/app_settings_controller.dart';
import 'getting_started_screen.dart';

// Shown on the settings screen; keep in step with pubspec.yaml on every release.
const String _applicationVersion = '0.1.7';
const int _fontScaleDivisions = 9;

class AppSettingsScreen extends StatelessWidget {
  const AppSettingsScreen({
    required this.settingsController,
    super.key,
  });

  final AppSettingsController settingsController;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: settingsController,
      builder: (BuildContext context, Widget? _) {
        final AppLanguage currentLanguage = settingsController.language;
        final ThemeMode currentThemeMode = settingsController.themeMode;
        final double currentFontScale = settingsController.fontScale;

        return Scaffold(
          appBar: AppBar(
            title: Text(context.l10n.settings),
          ),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
              children: <Widget>[
                Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 720),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        _buildSectionTitle(context, context.l10n.appearance),
                        Card(
                          elevation: 0,
                          color:
                              Theme.of(context).colorScheme.surfaceContainerLow,
                          margin: const EdgeInsets.only(bottom: 24),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(16.0),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: <Widget>[
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: SingleChildScrollView(
                                    scrollDirection: Axis.horizontal,
                                    child: SegmentedButton<ThemeMode>(
                                      segments: <ButtonSegment<ThemeMode>>[
                                        ButtonSegment<ThemeMode>(
                                          value: ThemeMode.system,
                                          icon: const Icon(
                                            Icons.settings_suggest_outlined,
                                          ),
                                          label: Text(context.l10n.systemTheme),
                                        ),
                                        ButtonSegment<ThemeMode>(
                                          value: ThemeMode.light,
                                          icon: const Icon(
                                            Icons.light_mode_outlined,
                                          ),
                                          label: Text(context.l10n.lightTheme),
                                        ),
                                        ButtonSegment<ThemeMode>(
                                          value: ThemeMode.dark,
                                          icon: const Icon(
                                            Icons.dark_mode_outlined,
                                          ),
                                          label: Text(context.l10n.darkTheme),
                                        ),
                                      ],
                                      selected: <ThemeMode>{currentThemeMode},
                                      onSelectionChanged:
                                          (Set<ThemeMode> selected) {
                                        settingsController
                                            .setThemeMode(selected.first);
                                      },
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 16),
                                const Divider(height: 1),
                                const SizedBox(height: 16),
                                _buildFontScaleSlider(
                                  context,
                                  currentFontScale,
                                ),
                              ],
                            ),
                          ),
                        ),
                        _buildSectionTitle(context, context.l10n.language),
                        Card(
                          elevation: 0,
                          color:
                              Theme.of(context).colorScheme.surfaceContainerLow,
                          margin: const EdgeInsets.only(bottom: 24),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(16.0),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: SingleChildScrollView(
                                scrollDirection: Axis.horizontal,
                                child: SegmentedButton<AppLanguage>(
                                  segments: <ButtonSegment<AppLanguage>>[
                                    ButtonSegment<AppLanguage>(
                                      value: AppLanguage.en,
                                      label: Text(context.l10n.english),
                                    ),
                                    ButtonSegment<AppLanguage>(
                                      value: AppLanguage.zh,
                                      label: Text(context.l10n.chinese),
                                    ),
                                  ],
                                  selected: <AppLanguage>{currentLanguage},
                                  onSelectionChanged:
                                      (Set<AppLanguage> selected) {
                                    settingsController
                                        .setLanguage(selected.first);
                                  },
                                ),
                              ),
                            ),
                          ),
                        ),
                        _buildSectionTitle(
                          context,
                          context.l10n.notifications,
                        ),
                        Card(
                          elevation: 0,
                          color:
                              Theme.of(context).colorScheme.surfaceContainerLow,
                          margin: const EdgeInsets.only(bottom: 24),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Column(
                            children: <Widget>[
                              SwitchListTile(
                                title: Text(context.l10n.quotaAlerts),
                                value: settingsController.quotaPushEnabled,
                                onChanged: (bool value) {
                                  settingsController.setQuotaPushEnabled(value);
                                },
                              ),
                              const Divider(
                                height: 1,
                                indent: 16,
                                endIndent: 16,
                              ),
                              SwitchListTile(
                                title: Text(context.l10n.taskAlerts),
                                value: settingsController.taskPushEnabled,
                                onChanged: (bool value) {
                                  settingsController.setTaskPushEnabled(value);
                                },
                              ),
                            ],
                          ),
                        ),
                        _buildSectionTitle(context, context.l10n.tutorial),
                        Card(
                          elevation: 0,
                          color:
                              Theme.of(context).colorScheme.surfaceContainerLow,
                          margin: const EdgeInsets.only(bottom: 24),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: ListTile(
                            leading: const Icon(Icons.school_outlined),
                            title: Text(context.l10n.gettingStarted),
                            subtitle: Text(context.l10n.gettingStartedHomeHint),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () {
                              Navigator.of(context).push<void>(
                                MaterialPageRoute<void>(
                                  builder: (_) => const GettingStartedScreen(),
                                ),
                              );
                            },
                          ),
                        ),
                        _buildSectionTitle(context, context.l10n.about),
                        Card(
                          elevation: 0,
                          color:
                              Theme.of(context).colorScheme.surfaceContainerLow,
                          margin: const EdgeInsets.only(bottom: 24),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: ListTile(
                            leading: const Icon(Icons.info_outline),
                            title: Text(context.l10n.aboutApp),
                            subtitle: Text(
                              '${context.l10n.version} $_applicationVersion',
                            ),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => _showAbout(context),
                          ),
                        ),
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

  Widget _buildFontScaleSlider(BuildContext context, double value) {
    final ThemeData theme = Theme.of(context);
    final int percent = (value * 100).round();
    final bool canReset =
        (value - AppSettingsController.defaultFontScale).abs() > 0.001;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Padding(
              padding: EdgeInsets.only(top: 2),
              child: Icon(Icons.format_size_outlined),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    context.l10n.fontSize,
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${context.l10n.fontSizeDescription} · '
                    '${context.l10n.fontScalePercent(percent)}',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: context.l10n.resetFontSize,
              onPressed: canReset
                  ? () {
                      settingsController.setFontScale(
                        AppSettingsController.defaultFontScale,
                      );
                    }
                  : null,
              icon: const Icon(Icons.restart_alt),
            ),
          ],
        ),
        Slider(
          value: value,
          min: AppSettingsController.minFontScale,
          max: AppSettingsController.maxFontScale,
          divisions: _fontScaleDivisions,
          label: context.l10n.fontScalePercent(percent),
          onChanged: settingsController.setFontScale,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: <Widget>[
              Text(
                context.l10n.fontScalePercent(
                  (AppSettingsController.minFontScale * 100).round(),
                ),
                style: theme.textTheme.labelSmall,
              ),
              Text(
                context.l10n.fontScalePercent(
                  (AppSettingsController.defaultFontScale * 100).round(),
                ),
                style: theme.textTheme.labelSmall,
              ),
              Text(
                context.l10n.fontScalePercent(
                  (AppSettingsController.maxFontScale * 100).round(),
                ),
                style: theme.textTheme.labelSmall,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSectionTitle(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
      child: Text(
        title,
        style: TextStyle(
          color: Theme.of(context).colorScheme.primary,
          fontSize: 13,
          fontWeight: FontWeight.bold,
          letterSpacing: 0,
        ),
      ),
    );
  }

  void _showAbout(BuildContext context) {
    showAboutDialog(
      context: context,
      applicationName: context.l10n.appName,
      applicationVersion: _applicationVersion,
      applicationLegalese: context.l10n.copyright,
      children: <Widget>[
        const SizedBox(height: 8),
        Text(
          context.l10n.aboutDescription,
          style: const TextStyle(height: 1.45),
        ),
        const SizedBox(height: 12),
        Text('${context.l10n.license}: ${context.l10n.licenseText}'),
      ],
    );
  }
}

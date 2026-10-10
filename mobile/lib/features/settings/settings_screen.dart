import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:tdlib_ex/td_api.dart' as td;
import 'package:url_launcher/url_launcher.dart';

import '../../core/config.dart';
import '../../core/formatters.dart';
import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../../state/settings.dart';
import '../../widgets/common.dart';
import '../chat/media_viewers.dart';
import 'folders_screen.dart';
import 'privacy_screen.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  void _push(BuildContext context, Widget screen) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(meProvider);
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);
    final account = ref.watch(accountProvider);
    final s = context.s;
    final username = me?.usernames?.activeUsernames.firstOrNull;
    return Scaffold(
      appBar: AppBar(title: Text(s.t('settings'))),
      body: ListView(
        children: [
          if (me != null)
            ListTile(
              contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              leading: GestureDetector(
                onTap: me.profilePhoto == null ? null : () => openPhotoViewer(context, me.profilePhoto!.big, me.profilePhoto!.minithumbnail),
                child: UserAvatar(userId: me.id, size: 64, showOnline: false),
              ),
              title: Text('${me.firstName} ${me.lastName}'.trim(), style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w600)),
              subtitle: Text(['+${me.phoneNumber}', if (username != null) '@$username'].join('  •  ')),
              trailing: const Icon(Icons.edit_rounded),
              onTap: () => _push(context, const EditProfileScreen()),
            ),
          const Divider(),
          SectionHeader(s.t('sado_features')),
          SwitchListTile(
            secondary: const Icon(Icons.visibility_off_rounded),
            title: Text(s.t('ghost_mode')),
            subtitle: Text(s.t('ghost_mode_hint')),
            value: settings.ghostMode,
            onChanged: (value) {
              notifier.setGhostMode(value);
              account.setOnline(!value);
            },
          ),
          ListTile(
            leading: const Icon(Icons.translate_rounded),
            title: Text(s.t('translate_to')),
            subtitle: Text(Strings.languageNames[settings.translateTo] ?? settings.translateTo),
            onTap: () async {
              final code = await _pickLanguage(context, settings.translateTo);
              if (code != null) notifier.setTranslateTo(code);
            },
          ),
          ListTile(
            leading: const Icon(Icons.favorite_rounded),
            title: Text(s.t('quick_reaction')),
            trailing: Text(settings.quickReaction, style: const TextStyle(fontSize: 24)),
            onTap: () async {
              final emoji = await showDialog<String>(
                context: context,
                builder: (context) => SimpleDialog(
                  title: Text(s.t('quick_reaction')),
                  children: [
                    Wrap(
                      alignment: WrapAlignment.center,
                      children: [
                        for (final e in const ['👍', '❤', '🔥', '😁', '🙏', '👏', '🎉', '🤩', '😢', '👌', '💯', '🤝'])
                          InkWell(
                            onTap: () => Navigator.pop(context, e),
                            child: Padding(padding: const EdgeInsets.all(10), child: Text(e, style: const TextStyle(fontSize: 28))),
                          ),
                      ],
                    ),
                  ],
                ),
              );
              if (emoji != null) notifier.setQuickReaction(emoji);
            },
          ),
          SwitchListTile(
            secondary: const Icon(Icons.keyboard_return_rounded),
            title: Text(s.t('send_by_enter')),
            value: settings.sendByEnter,
            onChanged: notifier.setSendByEnter,
          ),
          const Divider(),
          SectionHeader(s.t('settings')),
          ListTile(
            leading: const Icon(Icons.folder_rounded),
            title: Text(s.t('chat_folders')),
            onTap: () => _push(context, const FoldersScreen()),
          ),
          ListTile(
            leading: const Icon(Icons.lock_rounded),
            title: Text(s.t('privacy')),
            onTap: () => _push(context, const PrivacyScreen()),
          ),
          ListTile(
            leading: const Icon(Icons.devices_rounded),
            title: Text(s.t('devices')),
            onTap: () => _push(context, const SessionsScreen()),
          ),
          ListTile(
            leading: const Icon(Icons.palette_rounded),
            title: Text(s.t('appearance')),
            onTap: () => _push(context, const AppearanceScreen()),
          ),
          ListTile(
            leading: const Icon(Icons.language_rounded),
            title: Text(s.t('language')),
            subtitle: Text(Strings.languageNames[settings.localeCode] ?? settings.localeCode),
            onTap: () async {
              final code = await _pickLanguage(context, settings.localeCode, only: Strings.supported);
              if (code != null) notifier.setLocale(code);
            },
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.help_outline_rounded),
            title: Text(s.t('telegram_faq')),
            onTap: () => launchUrl(Uri.parse('https://telegram.org/faq'), mode: LaunchMode.externalApplication),
          ),
          ListTile(
            leading: Icon(Icons.logout_rounded, color: Theme.of(context).colorScheme.error),
            title: Text(s.t('log_out'), style: TextStyle(color: Theme.of(context).colorScheme.error)),
            onTap: () async {
              final ok = await confirm(context, title: s.t('log_out'), message: s.t('log_out_confirm'), destructive: true);
              if (!ok || !context.mounted) return;
              Navigator.of(context).popUntil((route) => route.isFirst);
              await guard(context, account.logOut);
            },
          ),
          Padding(
            padding: const EdgeInsets.all(20),
            child: Text(
              '${AppConfig.appName} ${AppConfig.appVersion} • TDLib ${switch (account.options['version']) { td.OptionValueString(:final value) => value, _ => '' }}',
              textAlign: TextAlign.center,
              style: TextStyle(color: Theme.of(context).hintColor, fontSize: 12.5),
            ),
          ),
        ],
      ),
    );
  }
}

const _translationLanguages = {
  'uz': "O'zbekcha",
  'ru': 'Русский',
  'en': 'English',
  'tr': 'Türkçe',
  'kk': 'Қазақша',
  'ky': 'Кыргызча',
  'tg': 'Тоҷикӣ',
  'ar': 'العربية',
  'de': 'Deutsch',
  'fr': 'Français',
  'es': 'Español',
  'zh': '中文',
  'ko': '한국어',
  'ja': '日本語',
};

Future<String?> _pickLanguage(BuildContext context, String current, {List<String>? only}) {
  final entries = _translationLanguages.entries.where((e) => only == null || only.contains(e.key));
  return showDialog<String>(
    context: context,
    builder: (context) => SimpleDialog(
      children: [
        RadioGroup<String>(
          groupValue: current,
          onChanged: (value) => Navigator.pop(context, value),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [for (final e in entries) RadioListTile<String>(value: e.key, title: Text(e.value))],
          ),
        ),
      ],
    ),
  );
}

// ------------------------------------------------------------------ profile

class EditProfileScreen extends ConsumerStatefulWidget {
  const EditProfileScreen({super.key});

  @override
  ConsumerState<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends ConsumerState<EditProfileScreen> {
  late final td.User? _me = ref.read(meProvider);
  late final _first = TextEditingController(text: _me?.firstName ?? '');
  late final _last = TextEditingController(text: _me?.lastName ?? '');
  late final _username = TextEditingController(text: _me?.usernames?.editableUsername ?? '');
  final _bio = TextEditingController();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final me = _me;
    if (me != null) {
      ref.read(accountProvider).send<td.UserFullInfo>(td.GetUserFullInfo(userId: me.id)).then((info) {
        if (mounted) _bio.text = info.bio?.text ?? '';
      }, onError: (Object _) {});
    }
  }

  @override
  void dispose() {
    _first.dispose();
    _last.dispose();
    _username.dispose();
    _bio.dispose();
    super.dispose();
  }

  Future<void> _changePhoto() async {
    final file = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 92, maxWidth: 1280);
    if (file == null || !mounted) return;
    await guard(context, () => ref.read(accountProvider).send<td.ChatPhoto>(td.SetProfilePhoto(
          photo: td.InputChatPhotoStatic(photo: td.InputFileLocal(path: file.path)),
          isPublic: false,
        )));
  }

  Future<void> _save() async {
    final me = _me;
    if (me == null || _first.text.trim().isEmpty) return;
    setState(() => _saving = true);
    final account = ref.read(accountProvider);
    final ok = await guard(context, () async {
      if (_first.text.trim() != me.firstName || _last.text.trim() != me.lastName) {
        await account.send<td.Ok>(td.SetName(firstName: _first.text.trim(), lastName: _last.text.trim()));
      }
      final username = _username.text.trim();
      if (username != (me.usernames?.editableUsername ?? '')) {
        await account.send<td.Ok>(td.SetUsername(username: username));
      }
      await account.send<td.Ok>(td.SetBio(bio: _bio.text.trim()));
      return true;
    });
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok == true) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final me = ref.watch(meProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text(s.t('edit_profile')),
        actions: [IconButton(icon: const Icon(Icons.check_rounded), onPressed: _saving ? null : _save)],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (me != null)
            Center(
              child: GestureDetector(
                onTap: _changePhoto,
                child: Stack(children: [
                  UserAvatar(userId: me.id, size: 100, showOnline: false),
                  const Positioned(right: 0, bottom: 0, child: CircleAvatar(radius: 17, child: Icon(Icons.camera_alt_rounded, size: 18))),
                ]),
              ),
            ),
          const SizedBox(height: 20),
          TextField(controller: _first, decoration: InputDecoration(labelText: s.t('first_name'))),
          const SizedBox(height: 14),
          TextField(controller: _last, decoration: InputDecoration(labelText: s.t('last_name'))),
          const SizedBox(height: 14),
          TextField(
            controller: _bio,
            maxLength: 70,
            decoration: InputDecoration(labelText: s.t('bio'), helperText: s.t('bio_hint')),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _username,
            decoration: InputDecoration(labelText: s.t('username'), prefixText: '@', helperText: s.t('username_hint')),
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------ sessions

final _sessionsProvider = FutureProvider.autoDispose<td.Sessions>((ref) {
  return ref.watch(accountProvider).send<td.Sessions>(const td.GetActiveSessions());
});

class SessionsScreen extends ConsumerWidget {
  const SessionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessions = ref.watch(_sessionsProvider);
    final account = ref.watch(accountProvider);
    final s = context.s;
    return Scaffold(
      appBar: AppBar(title: Text(s.t('devices'))),
      body: sessions.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text(errorText(context, error))),
        data: (data) {
          final current = data.sessions.where((x) => x.isCurrent).toList();
          final others = data.sessions.where((x) => !x.isCurrent).toList();
          return ListView(
            children: [
              SectionHeader(s.t('this_device')),
              for (final session in current) _SessionTile(session: session),
              if (others.isNotEmpty) ...[
                ListTile(
                  leading: Icon(Icons.front_hand_rounded, color: Theme.of(context).colorScheme.error),
                  title: Text(s.t('terminate_others'), style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  onTap: () async {
                    final ok = await confirm(context, title: s.t('terminate_others'), message: s.t('terminate_others_confirm'), destructive: true);
                    if (!ok || !context.mounted) return;
                    await guard(context, () => account.send<td.Ok>(const td.TerminateAllOtherSessions()));
                    ref.invalidate(_sessionsProvider);
                  },
                ),
                SectionHeader(s.t('active_sessions')),
                for (final session in others)
                  _SessionTile(
                    session: session,
                    onTerminate: () async {
                      await guard(context, () => account.send<td.Ok>(td.TerminateSession(sessionId: session.id)));
                      ref.invalidate(_sessionsProvider);
                    },
                  ),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _SessionTile extends StatelessWidget {
  const _SessionTile({required this.session, this.onTerminate});

  final td.Session session;
  final VoidCallback? onTerminate;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    return ListTile(
      leading: CircleAvatar(child: Icon(session.platform.toLowerCase().contains('ios') ? Icons.phone_iphone_rounded : Icons.devices_other_rounded)),
      title: Text('${session.applicationName} ${session.applicationVersion}'),
      subtitle: Text(
        '${session.deviceModel}, ${session.platform} ${session.systemVersion}\n${session.ipAddress} ${session.location} • ${formatChatTime(session.lastActiveDate, s.locale)}',
      ),
      isThreeLine: true,
      trailing: onTerminate == null
          ? null
          : IconButton(icon: const Icon(Icons.logout_rounded), tooltip: s.t('terminate'), onPressed: onTerminate),
    );
  }
}

// ------------------------------------------------------------------ appearance

class AppearanceScreen extends ConsumerWidget {
  const AppearanceScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);
    final s = context.s;
    return Scaffold(
      appBar: AppBar(title: Text(s.t('appearance'))),
      body: ListView(
        children: [
          SectionHeader(s.t('theme')),
          RadioGroup<ThemeMode>(
            groupValue: settings.themeMode,
            onChanged: (mode) => notifier.setThemeMode(mode ?? ThemeMode.system),
            child: Column(children: [
              RadioListTile(value: ThemeMode.system, title: Text(s.t('theme_system'))),
              RadioListTile(value: ThemeMode.light, title: Text(s.t('theme_light'))),
              RadioListTile(value: ThemeMode.dark, title: Text(s.t('theme_dark'))),
            ]),
          ),
          SectionHeader(s.t('accent_color')),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (var i = 0; i < accentPalette.length; i++)
                  GestureDetector(
                    onTap: () => notifier.setAccent(i),
                    child: CircleAvatar(
                      radius: 20,
                      backgroundColor: accentPalette[i],
                      child: settings.accentIndex == i ? const Icon(Icons.check_rounded, color: Colors.white) : null,
                    ),
                  ),
              ],
            ),
          ),
          SectionHeader(s.t('text_size')),
          Slider(
            value: settings.textScale,
            min: 0.85,
            max: 1.4,
            divisions: 11,
            label: '${(settings.textScale * 100).round()}%',
            onChanged: notifier.setTextScale,
          ),
          SectionHeader(s.t('bubble_radius')),
          Slider(
            value: settings.bubbleRadius,
            min: 4,
            max: 24,
            divisions: 10,
            label: '${settings.bubbleRadius.round()}',
            onChanged: notifier.setBubbleRadius,
          ),
        ],
      ),
    );
  }
}

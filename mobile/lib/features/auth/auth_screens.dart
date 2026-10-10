import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:tdlib_ex/td_api.dart' as td;
import 'package:url_launcher/url_launcher.dart';

import '../../core/config.dart';
import '../../core/tdlib/td_client.dart';
import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';

/// Shared scaffold for the login steps.
class _AuthScaffold extends ConsumerWidget {
  const _AuthScaffold({
    required this.title,
    required this.subtitle,
    required this.children,
    this.icon = Icons.send_rounded,
    this.onSubmit,
    this.busy = false,
    this.showBack = false,
    this.logo = false,
  });

  final String title;
  final String subtitle;
  final List<Widget> children;
  final IconData icon;
  final VoidCallback? onSubmit;
  final bool busy;
  final bool showBack;

  /// Show the Sado logo instead of the step icon (first screens of the flow).
  final bool logo;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final slots = ref.watch(accountSlotsProvider);
    final canCancelAdding = slots.slots.length > 1;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: theme.colorScheme.onSurface,
        iconTheme: IconThemeData(color: theme.colorScheme.onSurface),
        automaticallyImplyLeading: false,
        leading: showBack
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => guard(context, () => ref.read(accountProvider).logOut()),
              )
            : null,
        actions: [
          if (canCancelAdding)
            TextButton(
              onPressed: () => ref.read(accountSlotsProvider.notifier).removeSlot(slots.active),
              child: Text(context.t('cancel')),
            ),
        ],
      ),
      floatingActionButton: onSubmit == null
          ? null
          : FloatingActionButton(
              onPressed: busy ? null : onSubmit,
              child: busy
                  ? const SizedBox.square(
                      dimension: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                  : const Icon(Icons.arrow_forward_rounded),
            ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 96),
          children: [
            Center(
              child: logo
                  ? Image.asset('assets/logo.png', width: 120, height: 120)
                  : Container(
                      width: 96,
                      height: 96,
                      decoration: BoxDecoration(color: theme.colorScheme.primary, shape: BoxShape.circle),
                      child: Icon(icon, color: Colors.white, size: 44),
                    ),
            ),
            const SizedBox(height: 24),
            Text(title, textAlign: TextAlign.center, style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            Text(subtitle, textAlign: TextAlign.center, style: theme.textTheme.bodyMedium?.copyWith(color: theme.hintColor)),
            const SizedBox(height: 28),
            ...children,
          ],
        ),
      ),
    );
  }
}

mixin _Submitting<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  bool busy = false;
  String? errorMessage;

  Future<void> submit(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      errorMessage = null;
    });
    try {
      await action();
    } on TdException catch (error) {
      if (mounted) setState(() => errorMessage = errorText(context, error));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }
}

// ------------------------------------------------------------------ API credentials

class CredentialsScreen extends ConsumerStatefulWidget {
  const CredentialsScreen({super.key});

  @override
  ConsumerState<CredentialsScreen> createState() => _CredentialsScreenState();
}

class _CredentialsScreenState extends ConsumerState<CredentialsScreen> {
  final _id = TextEditingController();
  final _hash = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _id.dispose();
    _hash.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final credentials = TelegramCredentials(int.tryParse(_id.text.trim()) ?? 0, _hash.text.trim().toLowerCase());
    if (!credentials.isValid) {
      setState(() => _error = context.t('api_keys_invalid'));
      return;
    }
    await ref.read(credentialsProvider.notifier).save(credentials);
  }

  @override
  Widget build(BuildContext context) {
    return _AuthScaffold(
      title: context.t('api_keys_title'),
      subtitle: context.t('api_keys_subtitle'),
      icon: Icons.key_rounded,
      logo: true,
      onSubmit: _save,
      children: [
        OutlinedButton.icon(
          onPressed: () => launchUrl(Uri.parse('https://my.telegram.org/apps'), mode: LaunchMode.externalApplication),
          icon: const Icon(Icons.open_in_new_rounded),
          label: const Text('my.telegram.org/apps'),
        ),
        const SizedBox(height: 20),
        TextField(
          controller: _id,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(labelText: 'api_id'),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _hash,
          autocorrect: false,
          decoration: InputDecoration(labelText: 'api_hash', errorText: _error),
          onSubmitted: (_) => _save(),
        ),
      ],
    );
  }
}

// ------------------------------------------------------------------ phone number

class PhoneScreen extends ConsumerStatefulWidget {
  const PhoneScreen({super.key});

  @override
  ConsumerState<PhoneScreen> createState() => _PhoneScreenState();
}

class _PhoneScreenState extends ConsumerState<PhoneScreen> with _Submitting {
  final _phone = TextEditingController(text: '+998 ');

  @override
  void initState() {
    super.initState();
    unawaited(_guessCountryCode());
  }

  Future<void> _guessCountryCode() async {
    try {
      final country = await ref.read(accountProvider).send<td.Text>(const td.GetCountryCode());
      if (!mounted || _phone.text.trim() != '+998') return;
      const prefixes = {'UZ': '+998', 'RU': '+7', 'KZ': '+7', 'KG': '+996', 'TJ': '+992', 'TM': '+993', 'TR': '+90', 'US': '+1'};
      final prefix = prefixes[country.text];
      if (prefix != null) _phone.text = '$prefix ';
    } on TdException {
      // Keep the default prefix.
    }
  }

  @override
  void dispose() {
    _phone.dispose();
    super.dispose();
  }

  Future<void> _send() => submit(() async {
        final digits = _phone.text.replaceAll(RegExp(r'[^\d+]'), '');
        await ref.read(accountProvider).send<td.Ok>(td.SetAuthenticationPhoneNumber(
              phoneNumber: digits,
              settings: const td.PhoneNumberAuthenticationSettings(
                allowFlashCall: false,
                allowMissedCall: false,
                isCurrentPhoneNumber: false,
                hasUnknownPhoneNumber: false,
                allowSmsRetrieverApi: false,
                firebaseAuthenticationSettings: null,
                authenticationTokens: [],
              ),
            ));
      });

  @override
  Widget build(BuildContext context) {
    return _AuthScaffold(
      title: context.t('your_phone'),
      subtitle: context.t('phone_hint'),
      logo: true,
      onSubmit: _send,
      busy: busy,
      children: [
        TextField(
          controller: _phone,
          autofocus: true,
          keyboardType: TextInputType.phone,
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d+ \-()]'))],
          style: const TextStyle(fontSize: 22, letterSpacing: 1),
          decoration: InputDecoration(labelText: context.t('phone_number'), errorText: errorMessage),
          onSubmitted: (_) => _send(),
        ),
        const SizedBox(height: 24),
        TextButton.icon(
          onPressed: busy
              ? null
              : () => submit(() => ref
                  .read(accountProvider)
                  .send<td.Ok>(const td.RequestQrCodeAuthentication(otherUserIds: []))),
          icon: const Icon(Icons.qr_code_2_rounded),
          label: Text(context.t('login_qr')),
        ),
      ],
    );
  }
}

// ------------------------------------------------------------------ QR login

class QrLoginScreen extends ConsumerWidget {
  const QrLoginScreen({super.key, required this.link});

  final String link;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _AuthScaffold(
      title: context.t('login_qr'),
      subtitle: context.t('login_qr_hint'),
      icon: Icons.qr_code_2_rounded,
      showBack: true,
      children: [
        Center(
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20)),
            child: QrImageView(data: link, size: 240, backgroundColor: Colors.white),
          ),
        ),
      ],
    );
  }
}

// ------------------------------------------------------------------ code

class CodeScreen extends ConsumerStatefulWidget {
  const CodeScreen({super.key, required this.info});

  final td.AuthenticationCodeInfo info;

  @override
  ConsumerState<CodeScreen> createState() => _CodeScreenState();
}

class _CodeScreenState extends ConsumerState<CodeScreen> with _Submitting {
  final _code = TextEditingController();
  Timer? _timer;
  late int _secondsLeft = widget.info.timeout;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_secondsLeft <= 0) return;
      setState(() => _secondsLeft--);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _code.dispose();
    super.dispose();
  }

  int get _length => switch (widget.info.type) {
        td.AuthenticationCodeTypeSms(:final length) => length,
        td.AuthenticationCodeTypeTelegramMessage(:final length) => length,
        td.AuthenticationCodeTypeCall(:final length) => length,
        td.AuthenticationCodeTypeFragment(:final length) => length,
        td.AuthenticationCodeTypeMissedCall(:final length) => length,
        _ => 5,
      };

  String _subtitle(Strings s) {
    final phone = widget.info.phoneNumber;
    return switch (widget.info.type) {
      td.AuthenticationCodeTypeTelegramMessage() => s.t('code_sent_telegram'),
      td.AuthenticationCodeTypeSms() => s.t('code_sent_sms', {'phone': phone}),
      td.AuthenticationCodeTypeCall() => s.t('code_sent_call', {'phone': phone}),
      td.AuthenticationCodeTypeFragment() => s.t('code_sent_fragment'),
      td.AuthenticationCodeTypeMissedCall(:final phoneNumberPrefix) =>
        s.t('code_missed_call', {'prefix': phoneNumberPrefix}),
      _ => s.t('code_sent_sms', {'phone': phone}),
    };
  }

  Future<void> _check() => submit(() => ref.read(accountProvider).send<td.Ok>(td.CheckAuthenticationCode(code: _code.text.trim())));

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    return _AuthScaffold(
      title: widget.info.phoneNumber,
      subtitle: _subtitle(s),
      icon: Icons.sms_rounded,
      onSubmit: _check,
      busy: busy,
      showBack: true,
      children: [
        TextField(
          controller: _code,
          autofocus: true,
          keyboardType: TextInputType.number,
          textAlign: TextAlign.center,
          maxLength: _length,
          style: const TextStyle(fontSize: 28, letterSpacing: 12, fontWeight: FontWeight.w600),
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: InputDecoration(counterText: '', hintText: '•' * _length, errorText: errorMessage),
          onChanged: (value) {
            if (value.length == _length) _check();
          },
        ),
        const SizedBox(height: 18),
        if (widget.info.nextType != null)
          Center(
            child: _secondsLeft > 0
                ? Text(s.t('resend_in', {'n': '$_secondsLeft'}), style: TextStyle(color: Theme.of(context).hintColor))
                : TextButton(
                    onPressed: () => submit(() => ref.read(accountProvider).send<td.Ok>(const td.ResendAuthenticationCode(reason: null))),
                    child: Text(s.t('resend_code')),
                  ),
          ),
      ],
    );
  }
}

// ------------------------------------------------------------------ two-step verification

class PasswordScreen extends ConsumerStatefulWidget {
  const PasswordScreen({super.key, required this.state});

  final td.AuthorizationStateWaitPassword state;

  @override
  ConsumerState<PasswordScreen> createState() => _PasswordScreenState();
}

class _PasswordScreenState extends ConsumerState<PasswordScreen> with _Submitting {
  final _password = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _check() =>
      submit(() => ref.read(accountProvider).send<td.Ok>(td.CheckAuthenticationPassword(password: _password.text)));

  Future<void> _recover() async {
    final s = context.s;
    final account = ref.read(accountProvider);
    await submit(() => account.send<td.Ok>(const td.RequestAuthenticationPasswordRecovery()));
    if (!mounted || errorMessage != null) return;
    final code = await _prompt(s.t('recovery_code_sent', {'email': widget.state.recoveryEmailAddressPattern}));
    if (code == null || code.isEmpty || !mounted) return;
    await submit(() => account.send<td.Ok>(td.RecoverAuthenticationPassword(recoveryCode: code, newPassword: '', newHint: '')));
  }

  Future<String?> _prompt(String message) {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(message),
          TextField(controller: controller, autofocus: true, keyboardType: TextInputType.number),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(context.t('cancel'))),
          TextButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: Text(context.t('ok'))),
        ],
      ),
    ).whenComplete(controller.dispose);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    return _AuthScaffold(
      title: s.t('two_step'),
      subtitle: s.t('two_step_hint'),
      icon: Icons.lock_rounded,
      onSubmit: _check,
      busy: busy,
      showBack: true,
      children: [
        TextField(
          controller: _password,
          autofocus: true,
          obscureText: _obscure,
          decoration: InputDecoration(
            labelText: s.t('password'),
            helperText: widget.state.passwordHint.isEmpty ? null : s.t('hint', {'hint': widget.state.passwordHint}),
            errorText: errorMessage,
            suffixIcon: IconButton(
              icon: Icon(_obscure ? Icons.visibility_rounded : Icons.visibility_off_rounded),
              onPressed: () => setState(() => _obscure = !_obscure),
            ),
          ),
          onSubmitted: (_) => _check(),
        ),
        if (widget.state.hasRecoveryEmailAddress)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(onPressed: busy ? null : _recover, child: Text(s.t('forgot_password'))),
          ),
      ],
    );
  }
}

// ------------------------------------------------------------------ registration

class RegistrationScreen extends ConsumerStatefulWidget {
  const RegistrationScreen({super.key, required this.terms});

  final td.TermsOfService terms;

  @override
  ConsumerState<RegistrationScreen> createState() => _RegistrationScreenState();
}

class _RegistrationScreenState extends ConsumerState<RegistrationScreen> with _Submitting {
  final _first = TextEditingController();
  final _last = TextEditingController();

  @override
  void dispose() {
    _first.dispose();
    _last.dispose();
    super.dispose();
  }

  Future<void> _register() async {
    if (_first.text.trim().isEmpty) {
      setState(() => errorMessage = context.t('first_name_required'));
      return;
    }
    if (widget.terms.showPopup) {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(context.t('terms_of_service')),
          content: SingleChildScrollView(child: Text(widget.terms.text.text)),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(context.t('decline'))),
            TextButton(onPressed: () => Navigator.pop(context, true), child: Text(context.t('accept'))),
          ],
        ),
      );
      if (accepted != true) return;
    }
    await submit(() => ref.read(accountProvider).send<td.Ok>(td.RegisterUser(
          firstName: _first.text.trim(),
          lastName: _last.text.trim(),
          disableNotification: false,
        )));
  }

  @override
  Widget build(BuildContext context) {
    return _AuthScaffold(
      title: context.t('your_name'),
      subtitle: context.t('your_name_hint'),
      icon: Icons.person_rounded,
      onSubmit: _register,
      busy: busy,
      showBack: true,
      children: [
        TextField(
          controller: _first,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(labelText: context.t('first_name'), errorText: errorMessage),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _last,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(labelText: context.t('last_name')),
          onSubmitted: (_) => _register(),
        ),
      ],
    );
  }
}

// ------------------------------------------------------------------ email (required for some new accounts)

class EmailScreen extends ConsumerStatefulWidget {
  const EmailScreen({super.key, this.codeInfo});

  /// Null while asking for the address, set while waiting for the emailed code.
  final td.EmailAddressAuthenticationCodeInfo? codeInfo;

  @override
  ConsumerState<EmailScreen> createState() => _EmailScreenState();
}

class _EmailScreenState extends ConsumerState<EmailScreen> with _Submitting {
  final _input = TextEditingController();

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _submit() {
    final account = ref.read(accountProvider);
    final value = _input.text.trim();
    if (widget.codeInfo == null) {
      return submit(() => account.send<td.Ok>(td.SetAuthenticationEmailAddress(emailAddress: value)));
    }
    return submit(() => account.send<td.Ok>(
          td.CheckAuthenticationEmailCode(code: td.EmailAddressAuthenticationCode(code: value)),
        ));
  }

  @override
  Widget build(BuildContext context) {
    final waitingCode = widget.codeInfo != null;
    return _AuthScaffold(
      title: context.t(waitingCode ? 'email_code' : 'email_address'),
      subtitle: waitingCode
          ? context.t('email_code_hint', {'email': widget.codeInfo!.emailAddressPattern})
          : context.t('email_address_hint'),
      icon: Icons.alternate_email_rounded,
      onSubmit: _submit,
      busy: busy,
      showBack: true,
      children: [
        TextField(
          controller: _input,
          autofocus: true,
          keyboardType: waitingCode ? TextInputType.number : TextInputType.emailAddress,
          decoration: InputDecoration(errorText: errorMessage),
          onSubmitted: (_) => _submit(),
        ),
      ],
    );
  }
}

class UnsupportedAuthScreen extends StatelessWidget {
  const UnsupportedAuthScreen({super.key});

  @override
  Widget build(BuildContext context) => _AuthScaffold(
        title: context.t('login_unavailable'),
        subtitle: context.t('login_unavailable_hint'),
        icon: Icons.info_outline_rounded,
        showBack: true,
        children: const [],
      );
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/api_client.dart';
import '../core/app_scope.dart';
import '../role_switch.dart';
import '../theme/app_theme.dart';
import '../ui/components.dart';

/// Passenger mobile-number + OTP login — the same real, generic auth flow
/// driver/login_screen.dart uses (auth.service.ts's OTP state machine doesn't
/// distinguish passenger from driver; only the identifier field name differs on
/// the wire, `phone` here vs `driverId` there). Same honesty note applies: no
/// SMS gateway exists, so the demo-mode code is shown on screen rather than
/// pretending one was texted, and there's no session token afterward — entering
/// a phone number here is really "start using the app as this number", not a
/// real account system (there is no passenger table anywhere in this schema).
class PassengerLoginScreen extends StatefulWidget {
  const PassengerLoginScreen({super.key});

  @override
  State<PassengerLoginScreen> createState() => _PassengerLoginScreenState();
}

enum _Step { phone, otp }

class _PassengerLoginScreenState extends State<PassengerLoginScreen> {
  final _phoneController = TextEditingController();
  final _otpController = TextEditingController();

  _Step _step = _Step.phone;
  String? _error;
  bool _busy = false;
  String? _demoCode;

  /// Bumped on every `_requestOtp()` so a stale [_revealDemoCode] loop (e.g.
  /// the passenger went back to "Use a different number" and requested a new
  /// code before the old reveal finished) can tell it's been superseded and
  /// stop instead of racing the new one for control of [_otpController].
  int _revealToken = 0;

  late final ApiClient _api;
  bool _apiReady = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_apiReady) return;
    _apiReady = true;
    _api = ApiScope.of(context);
  }

  @override
  void dispose() {
    _phoneController.dispose();
    _otpController.dispose();
    super.dispose();
  }

  Future<void> _requestOtp() async {
    final phone = _phoneController.text.trim();
    if (phone.isEmpty) {
      setState(() => _error = 'Enter your mobile number');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await _api.requestOtp(phone: phone);
      if (!mounted) return;
      final code = result['code'] as String?;
      setState(() {
        _demoCode = code;
        _otpController.clear();
        _step = _Step.otp;
        _busy = false;
      });
      // Landing on this step with the code already sitting in the field reads as
      // "it was here the whole time", not "a code just arrived" — reveal it a
      // beat after arrival instead, same idea as an SMS autofill animation.
      if (code != null) unawaited(_revealDemoCode(code));
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _busy = false;
      });
    }
  }

  /// Fills [_otpController] with [code] in one shot, a beat after landing on
  /// the OTP step — every box in `_OtpBoxRow` reads the same controller, so
  /// this single update is what makes all six pop in together, same instant,
  /// rather than one appearing before the next exists. Aborts if superseded by
  /// a newer `_requestOtp()` call or the widget is gone before it fires.
  Future<void> _revealDemoCode(String code) async {
    final token = ++_revealToken;
    await Future.delayed(const Duration(milliseconds: 350));
    if (!mounted || token != _revealToken) return;
    _otpController.value = TextEditingValue(text: code, selection: TextSelection.collapsed(offset: code.length));
  }

  Future<void> _verifyOtp() async {
    final phone = _phoneController.text.trim();
    final code = _otpController.text.trim();
    if (code.isEmpty) {
      setState(() => _error = 'Enter the code');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _api.verifyOtp(phone: phone, code: code);
      if (!mounted) return;
      Navigator.pushReplacementNamed(context, '/passenger/home', arguments: {'phone': phone});
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Passenger Login',
      subtitle: _step == _Step.phone ? 'Enter your mobile number to get a code' : 'Enter the code to verify',
      actions: [
        CircleIconButton(
          icon: Icons.swap_horiz_rounded,
          tooltip: 'Switch role',
          onPressed: () => switchRole(context),
        ),
      ],
      child: Center(
        child: SingleChildScrollView(
          child: SoftCard(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_step == _Step.phone) ..._phoneStep(),
                if (_step == _Step.otp) ..._otpStep(),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!, style: const TextStyle(color: AppTheme.crowded, fontWeight: FontWeight.w600)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _phoneStep() {
    return [
      Text('Mobile number', style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: 8),
      SoftTextField(
        controller: _phoneController,
        hint: '10-digit mobile number',
        icon: Icons.smartphone_rounded,
        keyboardType: TextInputType.phone,
        autofocus: true,
        onSubmitted: (_) => _requestOtp(),
      ),
      const SizedBox(height: 20),
      PillButton(label: 'Send code', icon: Icons.sms_outlined, loading: _busy, onPressed: _requestOtp),
    ];
  }

  List<Widget> _otpStep() {
    return [
      Text('Verification code', style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: 8),
      if (_demoCode != null) ...[
        MetaRow(
          icon: Icons.info_outline_rounded,
          text: 'Demo mode — no SMS is sent. Your code is $_demoCode.',
        ),
        const SizedBox(height: 10),
      ],
      _OtpBoxRow(controller: _otpController, length: 6, onSubmitted: _verifyOtp),
      const SizedBox(height: 12),
      SecondaryPillButton(label: 'Use a different number', onPressed: () => setState(() => _step = _Step.phone)),
      const SizedBox(height: 12),
      PillButton(label: 'Continue', icon: Icons.check_rounded, loading: _busy, onPressed: _verifyOtp),
    ];
  }
}

/// Six boxes, one digit each, backed by a single real (but invisible)
/// [TextField] so keyboard entry, paste, and SMS autofill all still just work
/// — the boxes are purely a display of [controller]'s current text. Rebuilding
/// from the same controller on every change (autofill included) is what makes
/// all six pop in on the same frame when a demo code lands in one shot,
/// instead of staggering as if typed digit by digit.
class _OtpBoxRow extends StatelessWidget {
  const _OtpBoxRow({required this.controller, required this.length, required this.onSubmitted});

  final TextEditingController controller;
  final int length;
  final VoidCallback onSubmitted;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 60,
      child: Stack(
        alignment: Alignment.center,
        children: [
          AnimatedBuilder(
            animation: controller,
            builder: (context, _) {
              final text = controller.text;
              return Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  for (var i = 0; i < length; i++)
                    _OtpDigitBox(char: i < text.length ? text[i] : null),
                ],
              );
            },
          ),
          // The real input target: sized over the whole row and fully
          // transparent, so every tap in the row focuses it and the system
          // keyboard (and SMS autofill, on a real device) writes straight into
          // `controller` — the boxes above just mirror whatever it holds.
          Opacity(
            opacity: 0,
            child: TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(length)],
              decoration: const InputDecoration(counterText: '', border: InputBorder.none),
              style: const TextStyle(color: Colors.transparent),
              cursorColor: Colors.transparent,
              onSubmitted: (_) => onSubmitted(),
            ),
          ),
        ],
      ),
    );
  }
}

class _OtpDigitBox extends StatelessWidget {
  const _OtpDigitBox({required this.char});

  /// This position's digit, or null while still empty.
  final String? char;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final filled = char != null;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: 44,
      height: 56,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: isDark ? AppTheme.cardNestedDark : AppTheme.cardNestedLight,
        borderRadius: BorderRadius.circular(AppTheme.radiusField),
        border: Border.all(color: filled ? scheme.primary : (isDark ? AppTheme.borderDark : AppTheme.borderLight)),
      ),
      // Keyed on the character itself so every box's AnimatedSwitcher fires
      // its transition the instant that position goes from empty to filled —
      // when a whole code lands in one `controller` update, every box's key
      // changes on the same frame, so all six pop together.
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 320),
        switchInCurve: Curves.easeOutBack,
        switchOutCurve: Curves.easeIn,
        transitionBuilder: (child, animation) =>
            ScaleTransition(scale: animation, child: FadeTransition(opacity: animation, child: child)),
        child: Text(
          char ?? '',
          key: ValueKey(char ?? ''),
          style: theme.textTheme.headlineSmall,
        ),
      ),
    );
  }
}

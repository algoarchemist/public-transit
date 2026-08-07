import 'package:flutter/material.dart';

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
      setState(() {
        _demoCode = result['code'] as String?;
        _otpController.text = _demoCode ?? '';
        _step = _Step.otp;
        _busy = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _busy = false;
      });
    }
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
      SoftTextField(
        controller: _otpController,
        hint: '6-digit code',
        icon: Icons.pin_outlined,
        keyboardType: TextInputType.number,
        autofocus: true,
        onSubmitted: (_) => _verifyOtp(),
      ),
      const SizedBox(height: 12),
      SecondaryPillButton(label: 'Use a different number', onPressed: () => setState(() => _step = _Step.phone)),
      const SizedBox(height: 12),
      PillButton(label: 'Continue', icon: Icons.check_rounded, loading: _busy, onPressed: _verifyOtp),
    ];
  }
}

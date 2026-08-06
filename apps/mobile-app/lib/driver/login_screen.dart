import 'package:flutter/material.dart';

import '../core/api_client.dart';
import '../core/app_scope.dart';
import '../role_switch.dart';
import '../theme/app_theme.dart';
import '../ui/components.dart';

/// Driver ID + OTP login, then bus registration to feed the real trip lifecycle
/// (`POST /api/trips`'s `busId`/`driverId` — see trips.service.ts and
/// route_selection_screen.dart).
///
/// The OTP itself is real end to end — server-generated, expiring, single-use,
/// rate-limited (auth.service.ts) — but there is no SMS gateway wired up, so the
/// request-OTP response carries the code back directly (`demoMode: true`) and
/// this screen shows it instead of pretending a text was sent. Verifying returns
/// no session token (nothing downstream checks one yet), so successful
/// verification just unlocks bus entry rather than gating a protected route.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

enum _Step { driverId, otp, bus }

class _LoginScreenState extends State<LoginScreen> {
  final _driverIdController = TextEditingController();
  final _otpController = TextEditingController();
  final _busIdController = TextEditingController();

  _Step _step = _Step.driverId;
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
    _driverIdController.dispose();
    _otpController.dispose();
    _busIdController.dispose();
    super.dispose();
  }

  Future<void> _requestOtp() async {
    final driverId = _driverIdController.text.trim();
    if (driverId.isEmpty) {
      setState(() => _error = 'Enter your driver ID');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await _api.requestDriverOtp(driverId);
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
    final driverId = _driverIdController.text.trim();
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
      await _api.verifyDriverOtp(driverId, code);
      if (!mounted) return;
      setState(() {
        _step = _Step.bus;
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

  void _continueToRoutes() {
    final busId = _busIdController.text.trim();
    if (busId.isEmpty) {
      setState(() => _error = 'Enter the bus registration number');
      return;
    }
    Navigator.pushReplacementNamed(
      context,
      '/driver/route-selection',
      arguments: {
        'busId': busId,
        'driverId': _driverIdController.text.trim(),
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Driver Login',
      subtitle: switch (_step) {
        _Step.driverId => 'Enter your driver ID to get a code',
        _Step.otp => 'Enter the code to verify',
        _Step.bus => 'Enter your bus to start a shift',
      },
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
                if (_step == _Step.driverId) ..._driverIdStep(),
                if (_step == _Step.otp) ..._otpStep(),
                if (_step == _Step.bus) ..._busStep(),
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

  List<Widget> _driverIdStep() {
    return [
      Text('Driver ID', style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: 8),
      SoftTextField(
        controller: _driverIdController,
        hint: 'Depot-issued driver ID or phone',
        icon: Icons.badge_outlined,
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
      SecondaryPillButton(label: 'Use a different driver ID', onPressed: () => setState(() => _step = _Step.driverId)),
      const SizedBox(height: 12),
      PillButton(label: 'Verify', icon: Icons.check_rounded, loading: _busy, onPressed: _verifyOtp),
    ];
  }

  List<Widget> _busStep() {
    return [
      Text('Bus registration', style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: 8),
      SoftTextField(
        controller: _busIdController,
        hint: 'e.g. PB-65-A-1234',
        icon: Icons.directions_bus_filled_rounded,
        textCapitalization: TextCapitalization.characters,
        autofocus: true,
        onSubmitted: (_) => _continueToRoutes(),
      ),
      const SizedBox(height: 20),
      PillButton(label: 'Continue', icon: Icons.arrow_forward_rounded, onPressed: _continueToRoutes),
    ];
  }
}

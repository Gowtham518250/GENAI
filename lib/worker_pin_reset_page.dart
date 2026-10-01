import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'models.dart';
import 'otp_service.dart';

class WorkerPinResetPage extends StatefulWidget {
  final Worker worker;
  const WorkerPinResetPage({super.key, required this.worker});

  @override
  State<WorkerPinResetPage> createState() => _WorkerPinResetPageState();
}

class _WorkerPinResetPageState extends State<WorkerPinResetPage> {
  static const _primary = Color(0xFF6366F1);
  static const _bg = Color(0xFFF7F8FC);

  final _emailController = TextEditingController();
  final _otpController = TextEditingController();
  final _pinController = TextEditingController();
  final _confirmPinController = TextEditingController();

  bool _loading = false;
  bool _otpSent = false;
  bool _showPin = false;
  int _remaining = 0;
  Timer? _timer;
  String? _error;

  @override
  void dispose() {
    _timer?.cancel();
    _emailController.dispose();
    _otpController.dispose();
    _pinController.dispose();
    _confirmPinController.dispose();
    super.dispose();
  }

  void _startTimer() {
    _timer?.cancel();
    setState(() => _remaining = 60);
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      if (_remaining <= 1) {
        timer.cancel();
        setState(() => _remaining = 0);
      } else {
        setState(() => _remaining--);
      }
    });
  }

  Future<void> _sendOtp() async {
    final email = _emailController.text.trim();
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email)) {
      setState(() => _error = 'Enter the owner email registered with this shop.');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    final result = await OTPService.sendOwnerVerificationOTP(
      email,
      title: 'Worker Attendance PIN Reset',
      bodyText: 'Use this OTP to authorize a worker attendance PIN reset.',
    );

    if (!mounted) return;
    setState(() => _loading = false);

    if (result['success'] == true) {
      setState(() => _otpSent = true);
      _startTimer();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('OTP sent to the owner email.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } else {
      setState(() => _error = result['message']?.toString());
    }
  }

  Future<void> _resetPin() async {
    final otp = _otpController.text.trim();
    final pin = _pinController.text.trim();
    final confirm = _confirmPinController.text.trim();

    if (!RegExp(r'^\d{6}$').hasMatch(otp)) {
      setState(() => _error = 'Enter the 6-digit OTP.');
      return;
    }
    if (!RegExp(r'^\d{4}$').hasMatch(pin)) {
      setState(() => _error = 'Attendance PIN must be exactly 4 digits.');
      return;
    }
    if (pin != confirm) {
      setState(() => _error = 'PINs do not match.');
      return;
    }

    final workerId = int.tryParse(widget.worker.id);
    if (workerId == null || workerId <= 0) {
      setState(() => _error = 'Invalid worker ID.');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    final result = await OTPService.resetWorkerPin(
      email: _emailController.text.trim(),
      otp: otp,
      workerId: workerId,
      newPin: pin,
    );

    if (!mounted) return;
    setState(() => _loading = false);

    if (result['success'] == true) {
      HapticFeedback.mediumImpact();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Worker attendance PIN reset successfully.'),
          backgroundColor: Color(0xFF16A34A),
          behavior: SnackBarBehavior.floating,
        ),
      );
      Navigator.pop(context, true);
    } else {
      setState(() => _error = result['message']?.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final worker = widget.worker;

    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _primary,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text(
          'Reset Attendance PIN',
          style: GoogleFonts.poppins(fontWeight: FontWeight.w700, fontSize: 18),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(18, 22, 18, 30),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _workerCard(worker),
              const SizedBox(height: 20),
              _securityBanner(),
              const SizedBox(height: 20),
              _sectionTitle('Owner verification', Icons.verified_user_rounded),
              const SizedBox(height: 10),
              Text(
                'An OTP will be sent to the shop owner’s registered email before the worker PIN can be changed.',
                style: GoogleFonts.poppins(fontSize: 12, color: Colors.grey.shade600, height: 1.45),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _emailController,
                enabled: !_loading && !_otpSent,
                keyboardType: TextInputType.emailAddress,
                decoration: _inputDecoration(
                  'Owner email',
                  Icons.email_outlined,
                  'Enter registered owner email',
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton.icon(
                  onPressed: _loading || _otpSent ? null : _sendOtp,
                  icon: const Icon(Icons.mark_email_read_outlined, size: 19),
                  label: Text(
                    _loading && !_otpSent ? 'Sending OTP…' : 'Send verification OTP',
                    style: GoogleFonts.poppins(fontWeight: FontWeight.w700),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _primary,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)),
                  ),
                ),
              ),
              if (_otpSent) ...[
                const SizedBox(height: 22),
                _sectionTitle('Create new PIN', Icons.lock_reset_rounded),
                const SizedBox(height: 10),
                TextField(
                  controller: _otpController,
                  enabled: !_loading,
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                  decoration: _inputDecoration('Email OTP', Icons.pin_outlined, '6-digit verification code')
                      .copyWith(counterText: ''),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _pinController,
                  enabled: !_loading,
                  keyboardType: TextInputType.number,
                  maxLength: 4,
                  obscureText: !_showPin,
                  decoration: _inputDecoration('New attendance PIN', Icons.lock_outline, '4 digits')
                      .copyWith(
                    counterText: '',
                    suffixIcon: IconButton(
                      onPressed: () => setState(() => _showPin = !_showPin),
                      icon: Icon(_showPin ? Icons.visibility_off : Icons.visibility),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _confirmPinController,
                  enabled: !_loading,
                  keyboardType: TextInputType.number,
                  maxLength: 4,
                  obscureText: !_showPin,
                  decoration: _inputDecoration('Confirm new PIN', Icons.lock_rounded, 'Repeat 4 digits')
                      .copyWith(counterText: ''),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: ElevatedButton.icon(
                    onPressed: _loading ? null : _resetPin,
                    icon: _loading
                        ? const SizedBox(
                            width: 19,
                            height: 19,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : const Icon(Icons.check_circle_outline_rounded),
                    label: Text(
                      _loading ? 'Resetting PIN…' : 'Reset worker PIN',
                      style: GoogleFonts.poppins(fontWeight: FontWeight.w700),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF16A34A),
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Center(
                  child: TextButton(
                    onPressed: _loading || _remaining > 0 ? null : _sendOtp,
                    child: Text(
                      _remaining > 0 ? 'Resend OTP in \${_remaining}s' : 'Resend OTP',
                      style: GoogleFonts.poppins(fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 14),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFEF2F2),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFFFECACA)),
                  ),
                  child: Text(
                    _error!,
                    style: GoogleFonts.poppins(
                      color: const Color(0xFFB91C1C),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _workerCard(Worker worker) {
    final initial = worker.name.trim().isEmpty ? '?' : worker.name.trim()[0].toUpperCase();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE6E8F0)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 14,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 25,
            backgroundColor: _primary.withValues(alpha: 0.10),
            child: Text(initial, style: GoogleFonts.poppins(color: _primary, fontWeight: FontWeight.w800, fontSize: 19)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(worker.name, style: GoogleFonts.poppins(fontSize: 15, fontWeight: FontWeight.w700)),
                Text(
                  '\${worker.position} • Attendance access',
                  style: GoogleFonts.poppins(fontSize: 11, color: Colors.grey.shade600),
                ),
              ],
            ),
          ),
          const Icon(Icons.key_rounded, color: _primary),
        ],
      ),
    );
  }

  Widget _securityBanner() {
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: _primary.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _primary.withValues(alpha: 0.16)),
      ),
      child: Row(
        children: [
          const Icon(Icons.shield_outlined, color: _primary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'The PIN is changed on the server only after the owner OTP is validated.',
              style: GoogleFonts.poppins(fontSize: 11, color: const Color(0xFF4B5563), height: 1.4),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String title, IconData icon) {
    return Row(
      children: [
        Icon(icon, size: 20, color: _primary),
        const SizedBox(width: 8),
        Text(title, style: GoogleFonts.poppins(fontSize: 16, fontWeight: FontWeight.w800)),
      ],
    );
  }

  InputDecoration _inputDecoration(String label, IconData icon, String hint) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      prefixIcon: Icon(icon, color: _primary),
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(13),
        borderSide: const BorderSide(color: Color(0xFFE1E4EC)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(13),
        borderSide: const BorderSide(color: Color(0xFFE1E4EC)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(13),
        borderSide: const BorderSide(color: _primary, width: 1.5),
      ),
    );
  }
}

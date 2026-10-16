import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../api_client.dart';
import '../../secure_token_storage.dart';
import '../../session_logout_service.dart';
import 'customer_marketplace_page.dart';

class CustomerLoginPage extends StatefulWidget {
  const CustomerLoginPage({super.key});

  @override
  State<CustomerLoginPage> createState() => _CustomerLoginPageState();
}

class _CustomerLoginPageState extends State<CustomerLoginPage> {
  bool _isLogin = true;
  bool _isLoading = false;
  
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _phoneController = TextEditingController();
  final _passwordController = TextEditingController();

  Future<void> _submit() async {
    setState(() => _isLoading = true);
    
    try {
      final endpoint = _isLogin ? '/store/customer/login' : '/store/customer/register';
      
      final body = _isLogin 
        ? {
            'email': _emailController.text.trim(),
            'password': _passwordController.text,
          }
        : {
            'name': _nameController.text.trim(),
            'email': _emailController.text.trim(),
            'phone': _phoneController.text.trim(),
            'password': _passwordController.text,
          };

      // Both use JSON payload
      final response = await ApiClient.postJson(endpoint, body);
      
      if (response.statusCode == 200 || response.statusCode == 201) {
        final data = json.decode(response.body);
        if (_isLogin) {
          final tokenValue = data['access_token'] ?? data['token'];
          final refreshTokenValue = data['refresh_token'];
          final customerId = int.tryParse(data['customer_id']?.toString() ?? '');
          if (tokenValue == null || tokenValue.toString().trim().isEmpty ||
              customerId == null || customerId <= 0) {
            throw Exception('Customer login returned an invalid session.');
          }

          // Switch through the shared isolation path before saving the
          // customer credentials. This clears owner tokens/preferences without
          // deleting other users' scoped offline business data.
          await SessionLogoutService.enterCustomerMode(
            customerName: (data['name'] ?? data['user_name'] ?? '').toString(),
            customerPhone: (data['phone'] ?? _phoneController.text).toString(),
          );

          // Keep customer credentials separate from the owner's JWT. Offline
          // customer orders are synced later by SyncService, so they must use
          // the customer role token when calling /store/order.
          await SecureTokenStorage.saveUserId(customerId);
          await SecureTokenStorage.saveCustomerToken(tokenValue.toString());

          final prefs = await SharedPreferences.getInstance();
          // Keep legacy values for older screens, but also set the canonical
          // role/profile keys consumed by cart and background listeners.
          await prefs.setString('auth_token', tokenValue.toString());
          // Older customer dashboard/profile widgets still read this key.
          await prefs.setString('customer_token', tokenValue.toString());
          if (refreshTokenValue != null) {
            await prefs.setString('refresh_token', refreshTokenValue.toString());
          }
          await prefs.setString('user_id', customerId.toString());
          await prefs.setString('customer_id', customerId.toString());
          await prefs.setString('role', 'customer');
          await prefs.setString('user_type', 'CUSTOMER');
          await prefs.setString('user_role', 'CUSTOMER');
          await prefs.setString('user_name', data['name'] ?? data['user_name'] ?? '');
          await prefs.setString('customer_name', data['name'] ?? data['user_name'] ?? '');
          await prefs.setString('user_email', data['email'] ?? _emailController.text.trim());
          await prefs.setString('customer_email', data['email'] ?? _emailController.text.trim());
          if (data['phone'] != null) {
            await prefs.setString('customer_phone', data['phone'].toString());
          }
          
          if (mounted) {
            Navigator.pushReplacement(
              context, 
              MaterialPageRoute(builder: (_) => const CustomerMarketplacePage())
            );
          }
        } else {
          // Registered successfully, now login
          setState(() => _isLogin = true);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Registration successful! Please login.'), backgroundColor: Colors.green),
          );
        }
      } else {
        throw Exception(json.decode(response.body)['detail'] ?? 'Authentication failed');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString().replaceAll('Exception: ', '')), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _showForgotPasswordFlow() async {
    final emailController = TextEditingController(
      text: _emailController.text.trim(),
    );
    final email = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Reset customer password'),
        content: TextField(
          controller: emailController,
          keyboardType: TextInputType.emailAddress,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Account email'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(
              dialogContext,
              emailController.text.trim().toLowerCase(),
            ),
            child: const Text('Send OTP'),
          ),
        ],
      ),
    );
    emailController.dispose();
    if (email == null || email.isEmpty || !mounted) return;

    try {
      final request = await ApiClient.postJson(
        '/store/customer/request-password-reset-otp',
        {'email': email},
      );
      final requestBody = json.decode(request.body);
      if (request.statusCode != 200 ||
          requestBody is! Map ||
          requestBody['success'] != true) {
        throw Exception(
          requestBody is Map
              ? (requestBody['detail'] ??
                      requestBody['message'] ??
                      'If this account exists, a reset code may be sent. Please check your email.')
                  .toString()
              : 'Unable to request a password reset right now.',
        );
      }

      final otpController = TextEditingController();
      final otp = await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Enter verification code'),
          content: TextField(
            controller: otpController,
            keyboardType: TextInputType.number,
            maxLength: 6,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: '6-digit OTP',
              counterText: '',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(
                dialogContext,
                otpController.text.trim(),
              ),
              child: const Text('Verify'),
            ),
          ],
        ),
      );
      otpController.dispose();
      if (otp == null || !mounted) return;
      if (!RegExp(r'^\d{6}$').hasMatch(otp)) {
        throw Exception('Enter the 6-digit OTP sent to your email.');
      }

      final verification = await ApiClient.postJson(
        '/store/customer/verify-password-reset-otp',
        {'email': email, 'otp': otp},
      );
      final verificationBody = json.decode(verification.body);
      if (verification.statusCode != 200 ||
          verificationBody is! Map ||
          verificationBody['reset_token'] == null) {
        throw Exception(
          verificationBody is Map
              ? (verificationBody['detail'] ?? 'Invalid or expired OTP.').toString()
              : 'Unable to verify the OTP.',
        );
      }

      final passwordController = TextEditingController();
      final newPassword = await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Choose a new password'),
          content: TextField(
            controller: passwordController,
            obscureText: true,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'New password (at least 8 characters)',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(
                dialogContext,
                passwordController.text,
              ),
              child: const Text('Update password'),
            ),
          ],
        ),
      );
      passwordController.dispose();
      if (newPassword == null || !mounted) return;
      if (newPassword.length < 8) {
        throw Exception('Your new password must contain at least 8 characters.');
      }

      final reset = await ApiClient.postJson(
        '/store/customer/reset-password',
        {
          'reset_token': verificationBody['reset_token'].toString(),
          'new_password': newPassword,
        },
      );
      final resetBody = json.decode(reset.body);
      if (reset.statusCode != 200 ||
          resetBody is! Map ||
          resetBody['success'] == false) {
        throw Exception(
          resetBody is Map
              ? (resetBody['detail'] ?? 'Password reset failed. Request a new OTP.')
                  .toString()
              : 'Password reset failed. Request a new OTP.',
        );
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Password updated. Please log in with your new password.'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.toString().replaceFirst('Exception: ', '')),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.teal.shade50,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.shopping_bag_rounded, size: 80, color: Colors.teal.shade600),
                const SizedBox(height: 16),
                Text('Retail Mind Market', style: GoogleFonts.poppins(fontSize: 28, fontWeight: FontWeight.bold, color: Colors.teal.shade900)),
                Text(_isLogin ? 'Welcome back, shopper!' : 'Create your account', style: GoogleFonts.poppins(color: Colors.teal.shade700)),
                const SizedBox(height: 40),
                
                Card(
                  elevation: 4,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  child: Padding(
                    padding: const EdgeInsets.all(20.0),
                    child: Column(
                      children: [
                        if (!_isLogin) ...[
                          TextField(
                            controller: _nameController,
                            decoration: const InputDecoration(labelText: 'Full Name', prefixIcon: Icon(Icons.person_outline)),
                          ),
                          const SizedBox(height: 16),
                          TextField(
                            controller: _phoneController,
                            keyboardType: TextInputType.phone,
                            decoration: const InputDecoration(labelText: 'Phone (10 digits)', prefixIcon: Icon(Icons.phone_outlined)),
                          ),
                          const SizedBox(height: 16),
                        ],
                        TextField(
                          controller: _emailController,
                          keyboardType: TextInputType.emailAddress,
                          decoration: const InputDecoration(labelText: 'Email Address', prefixIcon: Icon(Icons.email_outlined)),
                        ),
                        const SizedBox(height: 16),
                        TextField(
                          controller: _passwordController,
                          obscureText: true,
                          decoration: const InputDecoration(labelText: 'Password', prefixIcon: Icon(Icons.lock_outline)),
                        ),
                        const SizedBox(height: 24),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.teal.shade600,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            ),
                            onPressed: _isLoading ? null : _submit,
                            child: _isLoading 
                              ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(color: Colors.white))
                              : Text(_isLogin ? 'Login' : 'Register', style: GoogleFonts.poppins(fontSize: 16, fontWeight: FontWeight.bold)),
                          ),
                        ),
                        if (_isLogin)
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton(
                              onPressed: _isLoading ? null : _showForgotPasswordFlow,
                              child: const Text('Forgot password?'),
                            ),
                          ),
                        const SizedBox(height: 16),
                        TextButton(
                          onPressed: () => setState(() => _isLogin = !_isLogin),
                          child: Text(_isLogin ? 'Need an account? Register' : 'Already have an account? Login', style: TextStyle(color: Colors.teal.shade700)),
                        ),
                        const SizedBox(height: 8),
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: Text('Back to Home', style: TextStyle(color: Colors.grey.shade600)),
                        )
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
).hasMatch(otp)) {
        throw Exception('Enter the 6-digit OTP sent to your email.');
      }

      final verification = await ApiClient.postJson(
        '/store/customer/verify-password-reset-otp',
        {'email': email, 'otp': otp},
      );
      final verificationBody = json.decode(verification.body);
      if (verification.statusCode != 200 ||
          verificationBody is! Map ||
          verificationBody['reset_token'] == null) {
        throw Exception(
          verificationBody is Map
              ? (verificationBody['detail'] ?? 'Invalid or expired OTP.').toString()
              : 'Unable to verify the OTP.',
        );
      }

      final passwordController = TextEditingController();
      final newPassword = await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Choose a new password'),
          content: TextField(
            controller: passwordController,
            obscureText: true,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'New password (at least 8 characters)',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(
                dialogContext,
                passwordController.text,
              ),
              child: const Text('Update password'),
            ),
          ],
        ),
      );
      passwordController.dispose();
      if (newPassword == null || !mounted) return;
      if (newPassword.length < 8) {
        throw Exception('Your new password must contain at least 8 characters.');
      }

      final reset = await ApiClient.postJson(
        '/store/customer/reset-password',
        {
          'reset_token': verificationBody['reset_token'].toString(),
          'new_password': newPassword,
        },
      );
      final resetBody = json.decode(reset.body);
      if (reset.statusCode != 200 ||
          resetBody is! Map ||
          resetBody['success'] == false) {
        throw Exception(
          resetBody is Map
              ? (resetBody['detail'] ?? 'Password reset failed. Request a new OTP.')
                  .toString()
              : 'Password reset failed. Request a new OTP.',
        );
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Password updated. Please log in with your new password.'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.toString().replaceFirst('Exception: ', '')),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.teal.shade50,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.shopping_bag_rounded, size: 80, color: Colors.teal.shade600),
                const SizedBox(height: 16),
                Text('Retail Mind Market', style: GoogleFonts.poppins(fontSize: 28, fontWeight: FontWeight.bold, color: Colors.teal.shade900)),
                Text(_isLogin ? 'Welcome back, shopper!' : 'Create your account', style: GoogleFonts.poppins(color: Colors.teal.shade700)),
                const SizedBox(height: 40),
                
                Card(
                  elevation: 4,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  child: Padding(
                    padding: const EdgeInsets.all(20.0),
                    child: Column(
                      children: [
                        if (!_isLogin) ...[
                          TextField(
                            controller: _nameController,
                            decoration: const InputDecoration(labelText: 'Full Name', prefixIcon: Icon(Icons.person_outline)),
                          ),
                          const SizedBox(height: 16),
                          TextField(
                            controller: _phoneController,
                            keyboardType: TextInputType.phone,
                            decoration: const InputDecoration(labelText: 'Phone (10 digits)', prefixIcon: Icon(Icons.phone_outlined)),
                          ),
                          const SizedBox(height: 16),
                        ],
                        TextField(
                          controller: _emailController,
                          keyboardType: TextInputType.emailAddress,
                          decoration: const InputDecoration(labelText: 'Email Address', prefixIcon: Icon(Icons.email_outlined)),
                        ),
                        const SizedBox(height: 16),
                        TextField(
                          controller: _passwordController,
                          obscureText: true,
                          decoration: const InputDecoration(labelText: 'Password', prefixIcon: Icon(Icons.lock_outline)),
                        ),
                        const SizedBox(height: 24),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.teal.shade600,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            ),
                            onPressed: _isLoading ? null : _submit,
                            child: _isLoading 
                              ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(color: Colors.white))
                              : Text(_isLogin ? 'Login' : 'Register', style: GoogleFonts.poppins(fontSize: 16, fontWeight: FontWeight.bold)),
                          ),
                        ),
                        const SizedBox(height: 16),
                        TextButton(
                          onPressed: () => setState(() => _isLogin = !_isLogin),
                          child: Text(_isLogin ? 'Need an account? Register' : 'Already have an account? Login', style: TextStyle(color: Colors.teal.shade700)),
                        ),
                        const SizedBox(height: 8),
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: Text('Back to Home', style: TextStyle(color: Colors.grey.shade600)),
                        )
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

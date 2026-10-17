import '../../live_translated_text.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:record/record.dart';
import 'controllers/sales_entry_provider.dart';
import 'widgets/compact_total_card.dart';
import 'widgets/premium_product_entry.dart';
import 'widgets/smart_payment_section.dart';
import 'widgets/bill_preview_dialog.dart';

class SalesEntryScreen extends StatelessWidget {
  const SalesEntryScreen({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => SalesEntryProvider(),
      child: const _SalesEntryView(),
    );
  }
}

class _SalesEntryView extends StatefulWidget {
  const _SalesEntryView({Key? key}) : super(key: key);

  @override
  State<_SalesEntryView> createState() => _SalesEntryViewState();
}

class _SalesEntryViewState extends State<_SalesEntryView> {
  final Record _audioRecorder = Record();
  bool _isListening = false;
  int _recordSeconds = 0;
  Timer? _recordTimer;
  bool _finalizingVoice = false;
  
  Future<void> _startListening(BuildContext context) async {
    if (_finalizingVoice || context.read<SalesEntryProvider>().isVoiceProcessing) return;

    try {
      final hasPermission = await _audioRecorder.hasPermission();
      if (!mounted) return;
      if (!hasPermission) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: LiveTranslatedText('Microphone permission is required for voice billing.')),
        );
        return;
      }

      final directory = await getTemporaryDirectory();
      final audioPath = '${directory.path}${Platform.pathSeparator}retail_mind_billing_${DateTime.now().microsecondsSinceEpoch}.wav';
      await _audioRecorder.start(
        path: audioPath,
        encoder: AudioEncoder.wav,
        samplingRate: 16000,
      );
      if (!mounted) {
        await _audioRecorder.stop();
        return;
      }

      setState(() {
        _isListening = true;
        _recordSeconds = 0;
      });
      _recordTimer?.cancel();
      _recordTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!mounted || !_isListening) {
          timer.cancel();
          return;
        }
        if (_recordSeconds >= 59) {
          unawaited(_stopListening(context));
          return;
        }
        setState(() => _recordSeconds++);
      });
    } catch (error) {
      _recordTimer?.cancel();
      if (!mounted) return;
      setState(() => _isListening = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: LiveTranslatedText('Could not start recording. Check microphone permission and try again.')),
      );
    }
  }

  Future<void> _stopListening(BuildContext context) async {
    if (!_isListening || _finalizingVoice) return;
    _finalizingVoice = true;
    _recordTimer?.cancel();
    _recordTimer = null;
    String? audioPath;

    try {
      audioPath = await _audioRecorder.stop();
      if (!mounted) return;
      setState(() => _isListening = false);

      if (audioPath == null || audioPath.trim().isEmpty || !await File(audioPath).exists()) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: LiveTranslatedText('No audio was recorded. Please try again.')),
        );
        return;
      }

      final provider = context.read<SalesEntryProvider>();
      await provider.processVoiceRecording(audioPath, languageCode: 'auto');
      if (!mounted) return;

      final message = provider.lastVoiceMessage;
      if (message != null && message.trim().isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: LiveTranslatedText(message),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 6),
          ),
        );
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: LiveTranslatedText('Voice billing failed. Please retry or enter items manually.')),
      );
    } finally {
      if (audioPath != null) {
        try {
          final recordingFile = File(audioPath);
          if (await recordingFile.exists()) await recordingFile.delete();
        } catch (_) {
          // Temporary audio cleanup must not hide the billing result.
        }
      }
      _finalizingVoice = false;
    }
  }

  @override
  void dispose() {
    _recordTimer?.cancel();
    unawaited(_audioRecorder.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<SalesEntryProvider>();

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        elevation: 0,
        backgroundColor: Colors.white,
        centerTitle: true,
        title: LiveTranslatedText(
          'New Sale',
          style: GoogleFonts.poppins(
            color: const Color(0xFF1E293B),
            fontWeight: FontWeight.w700,
            fontSize: 18,
          ),
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.settings_outlined, color: const Color(0xFF64748B)),
            onPressed: () {},
          )
        ],
      ),
      body: Stack(
        children: [
          SingleChildScrollView(
            padding: const EdgeInsets.only(left: 16, right: 16, top: 16, bottom: 200),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Large Search Bar with Barcode Support
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.05),
                        blurRadius: 10,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.search, color: Color(0xFF64748B), size: 24),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          decoration: InputDecoration(
                            hint: LiveTranslatedText('Search products or scan barcode...'),
                            hintStyle: GoogleFonts.poppins(
                              fontSize: 14,
                              color: const Color(0xFF94A3B8),
                            ),
                            border: InputBorder.none,
                          ),
                          style: GoogleFonts.poppins(fontSize: 14),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: const Color(0xFF6366F1).withOpacity(0.1),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Icon(Icons.qr_code_scanner, color: Color(0xFF6366F1), size: 24),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                
                // Voice Command Section
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFF4F46E5), Color(0xFF6366F1)],
                    ),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            LiveTranslatedText(
                              'Smart Voice Input',
                              style: GoogleFonts.poppins(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                                fontSize: 16,
                              ),
                            ),
                            const SizedBox(height: 4),
                            LiveTranslatedText(
                              context.watch<SalesEntryProvider>().isVoiceProcessing
                                  ? 'Groq is transcribing and matching your inventory…'
                                  : _isListening
                                      ? 'Recording… $_recordSeconds s. Tap the mic to finish.'
                                      : 'Speak product names, quantities and optional prices.',
                              style: GoogleFonts.poppins(
                                color: Colors.white70,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      GestureDetector(
                        onTap: () => context.read<SalesEntryProvider>().isVoiceProcessing || _finalizingVoice ? null : _isListening ? _stopListening(context) : _startListening(context),
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(color: Colors.black12, blurRadius: 10),
                            ],
                          ),
                          child: Icon(
                            _isListening ? Icons.mic : Icons.mic_none,
                            color: _isListening ? const Color(0xFFEF4444) : const Color(0xFF4F46E5),
                            size: 32,
                          ),
                        ),
                      )
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                
                // Customer Section
                LiveTranslatedText(
                  'CUSTOMER DETAILS',
                  style: GoogleFonts.poppins(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: const Color(0xFF64748B),
                    letterSpacing: 1.0,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: _CustomerField(
                        controller: provider.customerPhoneController,
                        hint: 'Phone Number',
                        icon: Icons.phone,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 3,
                      child: _CustomerField(
                        controller: provider.customerNameController,
                        hint: 'Customer Name',
                        icon: Icons.person,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                
                // Product Entry List
                const PremiumProductEntryList(),
                
                const SizedBox(height: 12),
                Center(
                  child: OutlinedButton.icon(
                    onPressed: provider.addEntry,
                    icon: const Icon(Icons.add_rounded, size: 18),
                    label: const LiveTranslatedText('Add Product Row'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF4F46E5),
                      side: const BorderSide(color: Color(0xFF4F46E5)),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                    ),
                  ),
                ),
                
                const SizedBox(height: 24),
                const SmartPaymentSection(),
              ],
            ),
          ),
          
          // Sticky Bottom Action Bar
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                boxShadow: [
                  BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 10, offset: const Offset(0, -4)),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Grand Total Display
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            LiveTranslatedText('Grand Total', style: GoogleFonts.poppins(fontSize: 11, color: const Color(0xFF64748B))),
                            LiveTranslatedText('₹${provider.totalAmount.toStringAsFixed(2)}', style: GoogleFonts.spaceMono(fontSize: 24, fontWeight: FontWeight.w800)),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  // 🚨 NEW: Premium Action Buttons Layout
                  
                  // TOP ROW: Generate Bill + Save Sale
                  Row(
                    children: [
                      Expanded(
                        child: _buildPremiumActionButton(
                          icon: Icons.receipt_long_rounded,
                          label: 'Generate Bill',
                          gradient: const LinearGradient(
                            colors: [Color(0xFF6366F1), Color(0xFF8B5CF6)],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          isLoading: false,
                          onPressed: () async {
                            HapticFeedback.lightImpact();
                            // Preview and saved invoice must use the same stable bill number.
                            final invoiceNumber = await provider.ensureDraftBillNumber();
                            if (!mounted) return;
                            showDialog(
                              context: context,
                              builder: (_) => ChangeNotifierProvider.value(
                                value: provider,
                                child: BillPreviewDialog(invoiceNumber: invoiceNumber),
                              ),
                            );
                          },
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _buildPremiumActionButton(
                          icon: Icons.check_circle_rounded,
                          label: 'Save Sale',
                          gradient: const LinearGradient(
                            colors: [Color(0xFF10B981), Color(0xFF34D399)],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          isLoading: false,
                          onPressed: () async {
                            HapticFeedback.mediumImpact();
                            // Save Sale: Persists invoice + updates dashboard instantly
                            // Show loading indicator
                            if (mounted) {
                              showDialog(
                                context: context,
                                barrierDismissible: false,
                                builder: (ctx) => const Center(
                                  child: CircularProgressIndicator(color: Color(0xFF10B981)),
                                ),
                              );
                            }
                            
                            final success = await provider.submitSale();

                            // Remove loading indicator
                            if (mounted) {
                              Navigator.of(context).pop();
                            }

                            if (success && mounted) {
                              HapticFeedback.heavyImpact();
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: const Row(
                                    children: [
                                      Icon(Icons.check_circle, color: Colors.white),
                                      SizedBox(width: 8),
                                      LiveTranslatedText('Sale saved successfully'),
                                    ],
                                  ),
                                  backgroundColor: const Color(0xFF10B981),
                                  duration: const Duration(seconds: 2),
                                  behavior: SnackBarBehavior.floating,
                                ),
                              );
                              Navigator.pop(context);
                            } else if (mounted) {
                              HapticFeedback.vibrate();
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: const Row(
                                    children: [
                                      Icon(Icons.error_outline, color: Colors.white),
                                      SizedBox(width: 8),
                                      LiveTranslatedText('Failed to save sale. Please try again.'),
                                    ],
                                  ),
                                  backgroundColor: const Color(0xFFEF4444),
                                  duration: const Duration(seconds: 3),
                                  behavior: SnackBarBehavior.floating,
                                ),
                              );
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                  
                  const SizedBox(height: 12),
                  
                  // BOTTOM ROW: Payment Methods
                  Row(
                    children: [
                      Expanded(
                        child: _buildPaymentMethodButton(
                          icon: Icons.payments_rounded,
                          label: 'Cash',
                          color: const Color(0xFF10B981),
                          onTap: () {
                            HapticFeedback.lightImpact();
                            provider.setPaymentMethod('Cash');
                          },
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _buildPaymentMethodButton(
                          icon: Icons.qr_code_scanner_rounded,
                          label: 'UPI',
                          color: const Color(0xFF6366F1),
                          onTap: () {
                            HapticFeedback.lightImpact();
                            provider.setPaymentMethod('UPI');
                          },
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _buildPaymentMethodButton(
                          icon: Icons.account_balance_wallet_rounded,
                          label: 'Credit',
                          color: const Color(0xFFF59E0B),
                          onTap: () async {
                            HapticFeedback.mediumImpact();
                            // Borrow/Credit: Save as credit sale
                            // Show loading indicator
                            if (mounted) {
                              showDialog(
                                context: context,
                                barrierDismissible: false,
                                builder: (ctx) => const Center(
                                  child: CircularProgressIndicator(color: Color(0xFFF59E0B)),
                                ),
                              );
                            }
                            
                            final success = await provider.saveAsCredit();
                            
                            // Remove loading indicator
                            if (mounted) {
                              Navigator.of(context).pop();
                            }
                            
                            if (success && mounted) {
                              HapticFeedback.heavyImpact();
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: const Row(
                                    children: [
                                      Icon(Icons.check_circle, color: Colors.white),
                                      SizedBox(width: 8),
                                      LiveTranslatedText('Credit sale saved successfully'),
                                    ],
                                  ),
                                  backgroundColor: const Color(0xFFF59E0B),
                                  duration: const Duration(seconds: 2),
                                  behavior: SnackBarBehavior.floating,
                                ),
                              );
                              Navigator.pop(context);
                            } else if (mounted) {
                              HapticFeedback.vibrate();
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: const Row(
                                    children: [
                                      Icon(Icons.error_outline, color: Colors.white),
                                      SizedBox(width: 8),
                                      LiveTranslatedText('Failed to save credit sale. Please try again.'),
                                    ],
                                  ),
                                  backgroundColor: const Color(0xFFEF4444),
                                  duration: const Duration(seconds: 3),
                                  behavior: SnackBarBehavior.floating,
                                ),
                              );
                            }
                          },
                        ),
                      ),
                      Expanded(
                        child: ElevatedButton(
                          onPressed: () async {
                            final invoiceNumber = await provider.ensureDraftBillNumber();
                            if (!mounted) return;
                            showDialog(
                              context: context,
                              builder: (_) => ChangeNotifierProvider.value(
                                value: provider,
                                child: BillPreviewDialog(invoiceNumber: invoiceNumber),
                              ),
                            );
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF10B981),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            elevation: 0,
                          ),
                          child: LiveTranslatedText('GENERATE BILL', style: GoogleFonts.poppins(fontWeight: FontWeight.bold, fontSize: 12, letterSpacing: 0.5)),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: ElevatedButton(
                          onPressed: () async {
                            // Show loading indicator
                            if (context.mounted) {
                              showDialog(
                                context: context,
                                barrierDismissible: false,
                                builder: (ctx) => const Center(
                                  child: CircularProgressIndicator(),
                                ),
                              );
                            }
                            
                            final success = await provider.submitSale();
                            
                            // Remove loading indicator
                            if (context.mounted) {
                              Navigator.of(context).pop();
                            }
                            
                            if (success && context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: LiveTranslatedText('Sale saved successfully'),
                                  backgroundColor: Color(0xFF10B981),
                                  duration: Duration(seconds: 2),
                                ),
                              );
                              Navigator.pop(context);
                            } else if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: LiveTranslatedText('Failed to save sale. Please try again.'),
                                  backgroundColor: Color(0xFFEF4444),
                                  duration: Duration(seconds: 3),
                                ),
                              );
                            }
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF6366F1),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            elevation: 0,
                          ),
                          child: LiveTranslatedText('SAVE SALE', style: GoogleFonts.poppins(fontWeight: FontWeight.bold, fontSize: 12, letterSpacing: 0.5)),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: ElevatedButton(
                          onPressed: () async {
                            // Show loading indicator
                            if (context.mounted) {
                              showDialog(
                                context: context,
                                barrierDismissible: false,
                                builder: (ctx) => const Center(
                                  child: CircularProgressIndicator(),
                                ),
                              );
                            }
                            
                            final success = await provider.saveAsCredit();
                            
                            // Remove loading indicator
                            if (context.mounted) {
                              Navigator.of(context).pop();
                            }
                            
                            if (success && context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: LiveTranslatedText('Credit sale saved successfully'),
                                  backgroundColor: Color(0xFF10B981),
                                  duration: Duration(seconds: 2),
                                ),
                              );
                              Navigator.pop(context);
                            } else if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: LiveTranslatedText('Failed to save credit sale. Please try again.'),
                                  backgroundColor: Color(0xFFEF4444),
                                  duration: Duration(seconds: 3),
                                ),
                              );
                            }
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFF59E0B),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            elevation: 0,
                          ),
                          child: LiveTranslatedText('SAVE AS CREDIT', style: GoogleFonts.poppins(fontWeight: FontWeight.bold, fontSize: 12, letterSpacing: 0.5)),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          )
        ],
      ),
    );
  }

  // 🚨 NEW: Premium Action Button Widget
  Widget _buildPremiumActionButton({
    required IconData icon,
    required String label,
    required Gradient gradient,
    required VoidCallback onPressed,
    bool isLoading = false,
  }) {
    return AnimatedScale(
      scale: isLoading ? 0.95 : 1.0,
      duration: const Duration(milliseconds: 200),
      child: Container(
        height: 56,
        decoration: BoxDecoration(
          gradient: gradient,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
              color: gradient.colors.first.withValues(alpha: 0.3),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: isLoading ? null : onPressed,
            borderRadius: BorderRadius.circular(14),
            splashColor: Colors.white.withValues(alpha: 0.2),
            child: Center(
              child: isLoading
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                      ),
                    )
                  : Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(icon, color: Colors.white, size: 20),
                        const SizedBox(width: 8),
                        LiveTranslatedText(
                          label,
                          style: GoogleFonts.poppins(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }

  // 🚨 NEW: Payment Method Button Widget
  Widget _buildPaymentMethodButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return AnimatedScale(
      scale: 1.0,
      duration: const Duration(milliseconds: 200),
      child: Container(
        height: 52,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.3), width: 1.5),
          boxShadow: [
            BoxShadow(
              color: color.withValues(alpha: 0.1),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(12),
            splashColor: color.withValues(alpha: 0.1),
            child: Center(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, color: color, size: 18),
                  const SizedBox(width: 6),
                  LiveTranslatedText(
                    label,
                    style: GoogleFonts.poppins(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: color,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CustomerField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final IconData icon;

  const _CustomerField({required this.controller, required this.hint, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: TextField(
        controller: controller,
        style: GoogleFonts.poppins(fontSize: 13),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: GoogleFonts.poppins(fontSize: 13, color: const Color(0xFF94A3B8)),
          prefixIcon: Icon(icon, size: 18, color: const Color(0xFF94A3B8)),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        ),
      ),
    );
  }
}

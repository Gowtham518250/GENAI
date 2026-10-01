import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'analytics_dashboard.dart';
import 'gst_compliance.dart';
import 'notification_service_client.dart';

class EnterpriseControlPanel extends StatefulWidget {
  const EnterpriseControlPanel({super.key});

  @override
  State<EnterpriseControlPanel> createState() => _EnterpriseControlPanelState();
}

class _EnterpriseControlPanelState extends State<EnterpriseControlPanel>
    with SingleTickerProviderStateMixin {
  static const Color _primary = Color(0xFF5B5FEF);
  static const Color _primaryDark = Color(0xFF4548C9);
  static const Color _bg = Color(0xFFF6F7FB);
  static const Color _text = Color(0xFF182033);
  static const Color _muted = Color(0xFF747B8F);
  static const Color _border = Color(0xFFE7E9F0);

  late TabController _tabController;
  String _shopGSTIN = '';
  bool _gstVerified = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  TextStyle get _sectionStyle => GoogleFonts.poppins(
        fontSize: 20,
        fontWeight: FontWeight.w800,
        color: _text,
        letterSpacing: -0.3,
      );

  TextStyle get _bodyStyle => GoogleFonts.poppins(
        fontSize: 13,
        color: _muted,
        height: 1.45,
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(132),
        child: _buildHeader(),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          const AnalyticsDashboard(),
          _buildComplianceTab(),
          _buildNotificationsTab(),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [_primary, _primaryDark],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Column(
          children: [
            SizedBox(
              height: 68,
              child: Row(
                children: [
                  IconButton(
                    tooltip: 'Back',
                    onPressed: () => Navigator.maybePop(context),
                    icon: const Icon(Icons.arrow_back_ios_new_rounded,
                        color: Colors.white, size: 21),
                  ),
                  Expanded(
                    child: Text(
                      'Enterprise Control Panel',
                      style: GoogleFonts.poppins(
                        color: Colors.white,
                        fontSize: 21,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.4,
                      ),
                    ),
                  ),
                  Container(
                    margin: const EdgeInsets.only(right: 16),
                    padding: const EdgeInsets.all(9),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.tune_rounded,
                        color: Colors.white, size: 20),
                  ),
                ],
              ),
            ),
            TabBar(
              controller: _tabController,
              indicatorColor: Colors.white,
              indicatorWeight: 3,
              indicatorSize: TabBarIndicatorSize.label,
              dividerColor: Colors.transparent,
              labelColor: Colors.white,
              unselectedLabelColor: Colors.white.withValues(alpha: 0.62),
              labelStyle: GoogleFonts.poppins(
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
              unselectedLabelStyle: GoogleFonts.poppins(
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
              tabs: const [
                Tab(icon: Icon(Icons.insights_rounded, size: 19), text: 'Analytics'),
                Tab(icon: Icon(Icons.verified_rounded, size: 19), text: 'Compliance'),
                Tab(icon: Icon(Icons.notifications_active_rounded, size: 19), text: 'Notifications'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildComplianceTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(18, 20, 18, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildPageIntro(
            icon: Icons.verified_user_rounded,
            title: 'GST & Compliance',
            subtitle: 'Keep your shop billing and tax configuration organized.',
          ),
          const SizedBox(height: 18),
          _buildGSTCard(),
          const SizedBox(height: 22),
          Text('Applicable GST rates', style: _sectionStyle),
          const SizedBox(height: 10),
          Text(
            'Reference rates used by the current billing configuration.',
            style: _bodyStyle,
          ),
          const SizedBox(height: 12),
          ..._buildGSTRatesTable(),
          const SizedBox(height: 24),
          Text('Compliance features', style: _sectionStyle),
          const SizedBox(height: 12),
          _buildComplianceGrid(),
        ],
      ),
    );
  }

  Widget _buildPageIntro({
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            color: _primary.withValues(alpha: 0.11),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Icon(icon, color: _primary, size: 24),
        ),
        const SizedBox(width: 13),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: _sectionStyle),
              const SizedBox(height: 2),
              Text(subtitle, style: _bodyStyle),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildGSTCard() {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _border),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.045),
            blurRadius: 18,
            offset: const Offset(0, 7),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.receipt_long_rounded, color: _primary),
              const SizedBox(width: 9),
              Text(
                'GST registration',
                style: GoogleFonts.poppins(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: _text,
                ),
              ),
              const Spacer(),
              if (_gstVerified)
                _statusPill('Verified', const Color(0xFF16A34A)),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Add your 15-digit GSTIN to validate the shop configuration.',
            style: _bodyStyle,
          ),
          const SizedBox(height: 16),
          TextField(
            onChanged: (val) => setState(() => _shopGSTIN = val.trim()),
            keyboardType: TextInputType.text,
            textCapitalization: TextCapitalization.characters,
            style: GoogleFonts.poppins(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: _text,
            ),
            decoration: InputDecoration(
              hintText: 'Enter Shop GSTIN',
              hintStyle: GoogleFonts.poppins(color: _muted, fontSize: 14),
              prefixIcon: const Icon(Icons.badge_outlined, color: _muted),
              filled: true,
              fillColor: _bg,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 15),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(13),
                borderSide: const BorderSide(color: _border),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(13),
                borderSide: const BorderSide(color: _primary, width: 1.5),
              ),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            height: 48,
            child: ElevatedButton.icon(
              onPressed: _verifyGSTIN,
              icon: const Icon(Icons.verified_rounded, size: 19),
              label: Text(
                _gstVerified ? 'GSTIN Verified' : 'Verify GSTIN',
                style: GoogleFonts.poppins(fontWeight: FontWeight.w700),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: _primary,
                foregroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(13),
                ),
              ),
            ),
          ),
          if (_gstVerified) ...[
            const SizedBox(height: 12),
            _buildVerifiedBanner(),
          ],
        ],
      ),
    );
  }

  void _verifyGSTIN() {
    final isValid = GSTCompliance.isValidGSTIN(_shopGSTIN);
    setState(() => _gstVerified = isValid);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          isValid ? 'GSTIN verified successfully' : 'Invalid GSTIN format',
        ),
        backgroundColor: isValid ? const Color(0xFF16A34A) : Colors.red,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  Widget _buildVerifiedBanner() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFECFDF3),
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: const Color(0xFFBBF7D0)),
      ),
      child: Row(
        children: [
          const Icon(Icons.check_circle_rounded,
              color: Color(0xFF16A34A), size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'GST configuration is ready for invoicing.',
              style: GoogleFonts.poppins(
                color: const Color(0xFF166534),
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusPill(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(30),
      ),
      child: Text(
        label,
        style: GoogleFonts.poppins(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  List<Widget> _buildGSTRatesTable() {
    const rates = [
      ('Essentials', 'Food, Medicine', '5%', Icons.medication_outlined),
      ('Textiles & Fabrics', 'Clothing and fabric', '5%', Icons.checkroom_rounded),
      ('Electronics', 'Devices & accessories', '12%', Icons.devices_other_rounded),
      ('General Services', 'Standard services', '18%', Icons.miscellaneous_services_rounded),
      ('Luxury & Premium', 'Premium category', '28%', Icons.diamond_outlined),
    ];

    return rates.map((item) {
      return Container(
        margin: const EdgeInsets.only(bottom: 9),
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: _border),
        ),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: _primary.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(11),
              ),
              child: Icon(item.$4, color: _primary, size: 20),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.$1,
                    style: GoogleFonts.poppins(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: _text,
                    ),
                  ),
                  Text(item.$2, style: GoogleFonts.poppins(
                    fontSize: 10.5,
                    color: _muted,
                  )),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                color: _primary.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                item.$3,
                style: GoogleFonts.poppins(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: _primary,
                ),
              ),
            ),
          ],
        ),
      );
    }).toList();
  }

  Widget _buildComplianceGrid() {
    const features = [
      (
        'GST Invoice',
        'GSTIN and applicable rates on invoices',
        Icons.receipt_long_rounded,
      ),
      (
        'Audit Trail',
        'Track invoice and billing changes',
        Icons.history_rounded,
      ),
      (
        'HSN / SAC',
        'Product and service classification',
        Icons.category_outlined,
      ),
      (
        'ITC Tracking',
        'Manage input tax credit records',
        Icons.account_balance_wallet_outlined,
      ),
    ];

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: features.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
        childAspectRatio: 1.35,
      ),
      itemBuilder: (context, index) {
        final item = features[index];
        return Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: _border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(item.$3, color: _primary, size: 23),
              const Spacer(),
              Text(
                item.$1,
                style: GoogleFonts.poppins(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: _text,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                item.$2,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.poppins(fontSize: 9.5, color: _muted),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildNotificationsTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(18, 20, 18, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildPageIntro(
            icon: Icons.notifications_active_rounded,
            title: 'Notifications',
            subtitle: 'Configure automated customer and shop alerts.',
          ),
          const SizedBox(height: 18),
          _buildNotificationCard(
            'Bill Reminders',
            'SMS reminders for pending invoices',
            Icons.sms_rounded,
            const Color(0xFF2563EB),
            _showBillReminderDialog,
          ),
          _buildNotificationCard(
            'Order Updates',
            'SMS / WhatsApp order and delivery updates',
            Icons.local_shipping_rounded,
            const Color(0xFFF59E0B),
            _showOrderUpdateDialog,
          ),
          _buildNotificationCard(
            'Daily Reports',
            'Closing summaries for the shop owner',
            Icons.assessment_rounded,
            const Color(0xFF7C3AED),
            _showDailyReportDialog,
          ),
          _buildNotificationCard(
            'Loyalty Rewards',
            'Points, milestones and reward notifications',
            Icons.card_giftcard_rounded,
            const Color(0xFFDB2777),
            _showLoyaltyDialog,
          ),
          _buildNotificationCard(
            'Payment Alerts',
            'Payment activity and collection alerts',
            Icons.payments_rounded,
            const Color(0xFF16A34A),
            _showPaymentAlertDialog,
          ),
        ],
      ),
    );
  }

  Widget _buildNotificationCard(
    String title,
    String desc,
    IconData icon,
    Color color,
    VoidCallback onTap,
  ) {
    return Container(
      margin: const EdgeInsets.only(bottom: 11),
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(17),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(17),
          child: Container(
            padding: const EdgeInsets.all(15),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(17),
              border: Border.all(color: _border),
            ),
            child: Row(
              children: [
                Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(icon, color: color, size: 23),
                ),
                const SizedBox(width: 13),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: GoogleFonts.poppins(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: _text,
                      )),
                      const SizedBox(height: 2),
                      Text(desc, style: GoogleFonts.poppins(
                        fontSize: 10.5,
                        color: _muted,
                      )),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right_rounded,
                    color: _muted, size: 23),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showBillReminderDialog() {
    _showActionDialog(
      title: 'Send Bill Reminder',
      body: 'Send SMS reminders to customers with pending invoices.',
      action: 'Send reminders',
      onAction: () => 'Bill reminders queued for delivery',
    );
  }

  void _showOrderUpdateDialog() {
    _showActionDialog(
      title: 'Order Notifications',
      body: 'Enable order confirmation and delivery updates via SMS/WhatsApp.',
      action: 'Enable',
      onAction: () => 'Order notifications enabled',
    );
  }

  void _showDailyReportDialog() {
    _showActionDialog(
      title: 'Daily Closing Report',
      body: 'Configure the daily closing summary for the shop owner.',
      action: 'Enable',
      onAction: () => 'Daily reports enabled',
    );
  }

  void _showLoyaltyDialog() {
    _showActionDialog(
      title: 'Loyalty Notifications',
      body: 'Send birthday discounts, points and milestone updates.',
      action: 'Enable',
      onAction: () => 'Loyalty notifications enabled',
    );
  }

  void _showPaymentAlertDialog() {
    _showActionDialog(
      title: 'Payment Collection Alerts',
      body: 'Notify staff about customer payment activity.',
      action: 'Enable',
      onAction: () => 'Payment alerts enabled',
    );
  }

  void _showActionDialog({
    required String title,
    required String body,
    required String action,
    required String Function() onAction,
  }) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(title, style: GoogleFonts.poppins(
          fontWeight: FontWeight.w700,
          color: _text,
        )),
        content: Text(body, style: _bodyStyle),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel', style: GoogleFonts.poppins(color: _muted)),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(onAction()),
                  behavior: SnackBarBehavior.floating,
                ),
              );
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: _primary,
              foregroundColor: Colors.white,
            ),
            child: Text(action),
          ),
        ],
      ),
    );
  }
}

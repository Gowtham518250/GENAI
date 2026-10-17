import 'live_translated_text.dart';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:share_plus/share_plus.dart';
import 'api_client.dart';

class RetailGrowthSuitePage extends StatefulWidget {
  const RetailGrowthSuitePage({super.key});
  @override State<RetailGrowthSuitePage> createState()=>_RetailGrowthSuitePageState();
}

class _RetailGrowthSuitePageState extends State<RetailGrowthSuitePage> {
  bool loading=true;
  String error='';
  Map<String,dynamic> overview={};
  Map<String,dynamic> analytics={};
  List<dynamic> reorder=[];
  Map<String,dynamic> security={};
  List<dynamic> coupons=[];
  List<dynamic> returns=[];
  List<dynamic> deliveries=[];
  List<dynamic> copilotHistory=[];
  final copilot=TextEditingController();
  String answer='';

  @override void initState(){ super.initState(); _load(); }
  @override void dispose(){ copilot.dispose(); super.dispose(); }

  Future<Map<String,dynamic>> get(String path) async {
    final r=await ApiClient.getJson(path);
    if(r.statusCode!=200) {
      String detail='';
      try {
        final body=jsonDecode(r.body);
        if(body is Map && body['detail'] != null) detail=' — '+body['detail'].toString();
      } catch (_) {}
      throw Exception(path+' → HTTP '+r.statusCode.toString()+detail);
    }
    final d=jsonDecode(r.body);
    return d is Map<String,dynamic>?d:Map<String,dynamic>.from(d as Map);
  }

  Future<void> _load() async {
    setState((){loading=true;error='';});
    final failures=<String>[];

    Future<Map<String,dynamic>> safe(String label,String path,Map<String,dynamic> fallback) async {
      try {
        return await get(path);
      } catch (e) {
        failures.add(label+': '+e.toString());
        return fallback;
      }
    }

    final results=await Future.wait([
      safe('Overview','/growth/overview',{}),
      safe('Analytics','/growth/analytics?days=30',{}),
      safe('Reorder engine','/growth/reorder-suggestions',{'suggestions':[]}),
      safe('Security','/growth/security-center',{}),
      safe('Coupons','/growth/coupons',{'coupons':[]}),
      safe('Returns','/growth/returns?status=REQUESTED',{'returns':[]}),
      safe('Deliveries','/growth/deliveries',{'deliveries':[]}),
      safe('Copilot history','/growth/copilot/history?limit=6',{'history':[]}),
    ]);

    if(!mounted)return;
    setState((){
      overview=results[0];
      analytics=results[1];
      reorder=List<dynamic>.from(results[2]['suggestions']??[]);
      security=results[3];
      coupons=List<dynamic>.from(results[4]['coupons']??[]);
      returns=List<dynamic>.from(results[5]['returns']??[]);
      deliveries=List<dynamic>.from(results[6]['deliveries']??[]);
      copilotHistory=List<dynamic>.from(results[7]['history']??[]);
      error=failures.isEmpty ? '' : failures.join('\n');
      loading=false;
    });
  }
  Future<void> ask([String? preset]) async {
    final q=(preset??copilot.text).trim();
    if(q.isEmpty)return;
    if(preset!=null) copilot.text=preset;
    try{
      final r=await get('/growth/copilot?q='+Uri.encodeQueryComponent(q));
      if(mounted)setState(()=>answer=r['answer']?.toString()??'No answer.');
      final h=await get('/growth/copilot/history?limit=6');
      if(mounted)setState(()=>copilotHistory=List<dynamic>.from(h['history']??[]));
    }catch(_){ if(mounted)setState(()=>answer='Business Copilot is temporarily unavailable.'); }
  }

  Future<void> decideReturn(int id,bool approve) async {
    try{
      final response=await ApiClient.postJson('/growth/returns/'+id.toString()+'/decision',{
        'approve':approve,
        'note':approve?'Approved from Retail Growth Suite.':'Rejected from Retail Growth Suite.',
      });
      if(response.statusCode<200||response.statusCode>=300) throw Exception('Return action failed: '+response.statusCode.toString());
      await _load();
    }catch(e){ if(mounted)setState(()=>error=e.toString()); }
  }

  Future<void> markRefunded(int id) async {
    try{
      final response=await ApiClient.postJson('/growth/returns/'+id.toString()+'/mark-refunded',{
        'note':'Refund settlement completed by owner.',
      });
      if(response.statusCode<200||response.statusCode>=300) throw Exception('Refund action failed: '+response.statusCode.toString());
      await _load();
    }catch(e){ if(mounted)setState(()=>error=e.toString()); }
  }

  Future<void> updateDelivery(int id,String status) async {
    try{
      final response=await ApiClient.postJson('/growth/deliveries/'+id.toString()+'/status',{
        'status':status,
        'notes':'Updated from Retail Growth Suite.',
      });
      if(response.statusCode<200||response.statusCode>=300) throw Exception('Delivery action failed: '+response.statusCode.toString());
      await _load();
    }catch(e){ if(mounted)setState(()=>error=e.toString()); }
  }


  Future<void> _showCreateCouponDialog() async {
    final codeController = TextEditingController();
    final valueController = TextEditingController(text: '10');
    final minimumController = TextEditingController(text: '0');
    final maximumController = TextEditingController();
    final usageController = TextEditingController();
    String discountType = 'PERCENT';
    DateTime? expiryDate;
    bool saving = false;
    String dialogError = '';

    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: !saving,
        builder: (dialogContext) => StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            final isPercent = discountType == 'PERCENT';
            final expiryLabel = expiryDate == null
                ? 'Add expiry date (optional)'
                : 'Expires ' + expiryDate!.day.toString().padLeft(2, '0') + '/' +
                    expiryDate!.month.toString().padLeft(2, '0') + '/' +
                    expiryDate!.year.toString();
            return AlertDialog(
              title: Row(children: [
                Container(
                  width: 40, height: 40,
                  decoration: BoxDecoration(
                    color: const Color(0xFFFCE7F3),
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: const Icon(Icons.local_offer_rounded, color: Color(0xFFDB2777)),
                ),
                const SizedBox(width: 11),
                Expanded(child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    LiveTranslatedText('Create shop coupon', style: GoogleFonts.poppins(fontWeight: FontWeight.w800, fontSize: 17)),
                    LiveTranslatedText('Customers can redeem it at your online shop.', style: GoogleFonts.poppins(fontSize: 10, color: const Color(0xFF64748B))),
                  ],
                )),
              ]),
              content: SizedBox(
                width: 440,
                child: SingleChildScrollView(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    TextField(
                      controller: codeController,
                      textCapitalization: TextCapitalization.characters,
                      maxLength: 50,
                      decoration: InputDecoration(
                        label: LiveTranslatedText('Coupon code'),
                        hint: LiveTranslatedText('e.g. GOWTHAM10'),
                        prefixIcon: const Icon(Icons.confirmation_number_outlined),
                        counterText: '',
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      value: discountType,
                      decoration: InputDecoration(
                        label: LiveTranslatedText('Discount type'),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      items: const [
                        DropdownMenuItem(value: 'PERCENT', child: LiveTranslatedText('Percentage discount')),
                        DropdownMenuItem(value: 'FIXED', child: LiveTranslatedText('Fixed amount discount')),
                      ],
                      onChanged: saving ? null : (value) {
                        if (value != null) setDialogState(() => discountType = value);
                      },
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: valueController,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: InputDecoration(
                        labelText: isPercent ? 'Discount (%)' : 'Discount amount (₹)',
                        prefixIcon: Icon(isPercent ? Icons.percent_rounded : Icons.currency_rupee_rounded),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: minimumController,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: InputDecoration(
                        label: LiveTranslatedText('Minimum order amount (₹)'),
                        helper: LiveTranslatedText('Set this above zero to reward larger orders.'),
                        prefixIcon: const Icon(Icons.shopping_bag_outlined),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                    if (isPercent) ...[
                      const SizedBox(height: 12),
                      TextField(
                        controller: maximumController,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: InputDecoration(
                          label: LiveTranslatedText('Maximum discount (₹, optional)'),
                          prefixIcon: const Icon(Icons.savings_outlined),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    TextField(
                      controller: usageController,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        label: LiveTranslatedText('Maximum redemptions (optional)'),
                        hint: LiveTranslatedText('Unlimited if left blank'),
                        prefixIcon: const Icon(Icons.group_outlined),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: saving ? null : () async {
                        final now = DateTime.now();
                        final selected = await showDatePicker(
                          context: dialogContext,
                          initialDate: expiryDate ?? now.add(const Duration(days: 30)),
                          firstDate: DateTime(now.year, now.month, now.day),
                          lastDate: DateTime(now.year + 5),
                          helpText: 'Last day to use this coupon',
                        );
                        if (selected != null) setDialogState(() => expiryDate = selected);
                      },
                      icon: const Icon(Icons.calendar_month_rounded),
                      label: LiveTranslatedText(expiryLabel),
                    ),
                    if (expiryDate != null)
                      TextButton(
                        onPressed: saving ? null : () => setDialogState(() => expiryDate = null),
                        child: const LiveTranslatedText('Remove expiry date'),
                      ),
                    if (dialogError.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Align(alignment: Alignment.centerLeft, child: LiveTranslatedText(dialogError, style: GoogleFonts.poppins(color: const Color(0xFFBE123C), fontSize: 11))),
                    ],
                  ]),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: saving ? null : () => Navigator.of(dialogContext).pop(),
                  child: const LiveTranslatedText('Cancel'),
                ),
                FilledButton.icon(
                  onPressed: saving ? null : () async {
                    final code = codeController.text.trim().toUpperCase();
                    final value = double.tryParse(valueController.text.trim());
                    final minimum = double.tryParse(minimumController.text.trim());
                    final maximum = double.tryParse(maximumController.text.trim());
                    final usageText = usageController.text.trim();
                    final usage = usageText.isEmpty ? null : int.tryParse(usageText);
                    if (code.length < 3) {
                      setDialogState(() => dialogError = 'Coupon code must contain at least 3 characters.');
                      return;
                    }
                    if (value == null || !value.isFinite || value <= 0 || (isPercent && value > 100)) {
                      setDialogState(() => dialogError = isPercent
                        ? 'Enter a percentage from 0.01 to 100.'
                        : 'Enter a discount amount greater than zero.');
                      return;
                    }
                    if (minimum == null || !minimum.isFinite || minimum < 0) {
                      setDialogState(() => dialogError = 'Minimum order must be zero or higher.');
                      return;
                    }
                    if (maximumController.text.trim().isNotEmpty &&
                        (maximum == null || !maximum.isFinite || maximum <= 0)) {
                      setDialogState(() => dialogError = 'Maximum discount must be greater than zero.');
                      return;
                    }
                    if (usageText.isNotEmpty && (usage == null || usage <= 0)) {
                      setDialogState(() => dialogError = 'Maximum redemptions must be a positive whole number.');
                      return;
                    }

                    setDialogState(() { saving = true; dialogError = ''; });
                    try {
                      final payload = <String, dynamic>{
                        'code': code,
                        'discount_type': discountType,
                        'discount_value': value,
                        'minimum_order_amount': minimum,
                        'maximum_discount': isPercent && maximumController.text.trim().isNotEmpty ? maximum : null,
                        'usage_limit': usage,
                        'expires_at': expiryDate == null
                          ? null
                          : DateTime(expiryDate!.year, expiryDate!.month, expiryDate!.day, 23, 59, 59).toUtc().toIso8601String(),
                      };
                      final response = await ApiClient.postJson('/growth/coupons', payload);
                      if (response.statusCode < 200 || response.statusCode >= 300) {
                        String detail = 'Unable to create coupon (HTTP ' + response.statusCode.toString() + ').';
                        try {
                          final parsed = jsonDecode(response.body);
                          if (parsed is Map && parsed['detail'] != null) detail = parsed['detail'].toString();
                        } catch (_) {}
                        throw Exception(detail);
                      }
                      if (!dialogContext.mounted) return;
                      Navigator.of(dialogContext).pop();
                      await _load();
                      if (!mounted) return;
                      final discountText = isPercent
                        ? value.toStringAsFixed(0) + '% off'
                        : '₹' + value.toStringAsFixed(2) + ' off';
                      final shareText = 'Shop offer: use coupon ' + code + ' at checkout. ' +
                        discountText +
                        (minimum > 0 ? ' on orders of ₹' + minimum.toStringAsFixed(0) + ' or more' : '') +
                        (expiryDate != null
                          ? ' · Valid through ' + expiryDate!.day.toString().padLeft(2, '0') + '/' +
                              expiryDate!.month.toString().padLeft(2, '0') + '/' + expiryDate!.year.toString()
                          : '') + '.';
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: LiveTranslatedText('Coupon ' + code + ' created. Share the code with customers.'),
                          backgroundColor: const Color(0xFF15803D),
                          action: SnackBarAction(
                            label: 'Share',
                            textColor: Colors.white,
                            onPressed: () => Share.share(shareText, subject: 'Retail Mind shop coupon'),
                          ),
                        ),
                      );
                    } catch (error) {
                      if (dialogContext.mounted) {
                        setDialogState(() {
                          saving = false;
                          dialogError = error.toString().replaceFirst('Exception: ', '');
                        });
                      }
                    }
                  },
                  icon: saving
                    ? const SizedBox(width: 15, height: 15, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.add_rounded),
                  label: LiveTranslatedText(saving ? 'Creating…' : 'Create coupon'),
                ),
              ],
            );
          },
        ),
      );
    } finally {
      codeController.dispose();
      valueController.dispose();
      minimumController.dispose();
      maximumController.dispose();
      usageController.dispose();
    }
  }

  Widget _couponsPanel() {
    return Container(
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFFFFFFFF), Color(0xFFFFF8FC)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFF3D5E6)),
        boxShadow: const [BoxShadow(color: Color(0x0BDB2777), blurRadius: 20, offset: Offset(0, 8))],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 44, height: 44,
            decoration: BoxDecoration(color: const Color(0xFFFCE7F3), borderRadius: BorderRadius.circular(14)),
            child: const Icon(Icons.local_offer_rounded, color: Color(0xFFDB2777)),
          ),
          const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            LiveTranslatedText('Reward bigger baskets', style: GoogleFonts.poppins(fontWeight: FontWeight.w800, fontSize: 14, color: const Color(0xFF831843)),
            ),
            const SizedBox(height: 3),
            LiveTranslatedText('Create shop-only discount codes with minimum spend and redemption limits.', style: GoogleFonts.poppins(fontSize: 10, color: const Color(0xFF9D6681), height: 1.35)),
          ])),
        ]),
        const SizedBox(height: 13),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _showCreateCouponDialog,
            icon: const Icon(Icons.add_rounded, size: 18),
            label: const LiveTranslatedText('Create coupon for my shop'),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFBE185D),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 13),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)),
            ),
          ),
        ),
        if (coupons.isEmpty) ...[
          const SizedBox(height: 12),
          _empty('No coupons yet. Create a code and share it with your customers.'),
        ] else ...[
          const SizedBox(height: 13),
          ...coupons.map((raw) {
            final item = Map<String, dynamic>.from(raw as Map);
            final code = item['code']?.toString() ?? '';
            final type = item['discount_type']?.toString().toUpperCase() ?? 'PERCENT';
            final value = d(item['discount_value']);
            final minimum = d(item['minimum_order_amount']);
            final used = n(item['used_count']);
            final limit = item['usage_limit'] == null ? null : n(item['usage_limit']);
            final expired = item['expired'] == true;
            final active = item['is_active'] == true && !expired && (limit == null || used < limit);
            final detail = type == 'FIXED'
              ? '₹' + value.toStringAsFixed(2) + ' off'
              : value.toStringAsFixed(0) + '% off' + (item['maximum_discount'] != null ? ' · max ₹' + d(item['maximum_discount']).toStringAsFixed(0) : '');
            return Container(
              margin: const EdgeInsets.only(top: 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(15),
                border: Border.all(color: const Color(0xFFF0DCE6)),
              ),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Container(
                  width: 38, height: 38,
                  decoration: BoxDecoration(color: const Color(0xFFFFF1F7), borderRadius: BorderRadius.circular(11)),
                  child: const Icon(Icons.confirmation_number_rounded, color: Color(0xFFBE185D), size: 19),
                ),
                const SizedBox(width: 10),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(child: LiveTranslatedText(code, style: GoogleFonts.poppins(fontWeight: FontWeight.w900, letterSpacing: .7, color: const Color(0xFF831843))),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
                      decoration: BoxDecoration(
                        color: active ? const Color(0xFFDCFCE7) : const Color(0xFFF1F5F9),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: LiveTranslatedText(active ? 'ACTIVE' : expired ? 'EXPIRED' : 'INACTIVE',
                        style: GoogleFonts.poppins(fontSize: 8, fontWeight: FontWeight.w900, color: active ? const Color(0xFF166534) : const Color(0xFF64748B))),
                    ),
                  ]),
                  const SizedBox(height: 4),
                  LiveTranslatedText(detail, style: GoogleFonts.poppins(fontSize: 12, fontWeight: FontWeight.w800, color: const Color(0xFF1F2937))),
                  const SizedBox(height: 3),
                  LiveTranslatedText(
                    (minimum > 0 ? 'Min. order ₹' + minimum.toStringAsFixed(0) : 'Any order') +
                    ' · ' + (limit == null ? 'Unlimited uses' : used.toString() + ' / ' + limit.toString() + ' uses'),
                    style: GoogleFonts.poppins(fontSize: 9.5, color: const Color(0xFF64748B)),
                  ),
                ])),
                IconButton(
                  tooltip: 'Share coupon',
                  onPressed: () => Share.share(
                    'Shop offer: use coupon ' + code + ' at checkout. ' + detail +
                    (minimum > 0 ? ' on orders of ₹' + minimum.toStringAsFixed(0) + ' or more' : '') + '.',
                    subject: 'Retail Mind shop coupon',
                  ),
                  icon: const Icon(Icons.share_rounded, color: Color(0xFFBE185D)),
                ),
              ]),
            );
          }),
        ],
      ]),
    );
  }

  int n(dynamic v)=>(v as num?)?.toInt()??0;
  double d(dynamic v)=>(v as num?)?.toDouble()??0;

  @override Widget build(BuildContext context){
    final sales=Map<String,dynamic>.from(overview['sales']??{});
    final online=Map<String,dynamic>.from(overview['online']??{});
    final inv=Map<String,dynamic>.from(overview['inventory']??{});
    final branches=n(overview['branches']);
    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FB),
      appBar: AppBar(title:LiveTranslatedText('Retail Growth',style:GoogleFonts.poppins(fontWeight:FontWeight.w800)),backgroundColor:Colors.white,foregroundColor:const Color(0xFF111827),elevation:0,actions:[IconButton(onPressed:loading?null:_load,icon:const Icon(Icons.refresh_rounded))]),
      body:RefreshIndicator(onRefresh:_load,color:const Color(0xFF5B3DF5),child:ListView(padding:const EdgeInsets.all(16),children:[
        _hero(),
        if(error.isNotEmpty) ...[const SizedBox(height:12),_error(error)],
        const SizedBox(height:18),
        _title('Business pulse','Live owner metrics'),
        const SizedBox(height:10),
        GridView.count(crossAxisCount:2,crossAxisSpacing:10,mainAxisSpacing:10,childAspectRatio:2.2,shrinkWrap:true,physics:const NeverScrollableScrollPhysics(),children:[
          _metric(Icons.currency_rupee_rounded,'Month sales','₹'+d(sales['month']).toStringAsFixed(0),const Color(0xFF4F46E5)),
          _metric(Icons.trending_up_rounded,'Profit est.','₹'+d(sales['month_profit_estimate']).toStringAsFixed(0),const Color(0xFF16A34A)),
          _metric(Icons.shopping_bag_rounded,'Online orders',n(online['total_orders']).toString(),const Color(0xFF0891B2)),
          _metric(Icons.warning_amber_rounded,'Low stock',n(inv['low_stock_products']).toString(),const Color(0xFFF59E0B)),
          _metric(Icons.store_rounded,'Branches',branches.toString(),const Color(0xFF7C3AED)),
          _metric(Icons.local_shipping_rounded,'Deliveries',n(overview['active_deliveries']).toString(),const Color(0xFFDB2777)),
        ]),
        const SizedBox(height:20),
        _title('AI Business Copilot','Ask about stock, profit or online orders'),
        const SizedBox(height:10),
        _copilotCard(),
        const SizedBox(height:20),
        _title('Smart reorder engine',reorder.length.toString()+' priority products'),
        const SizedBox(height:10),
        if(reorder.isEmpty)_empty('No urgent reorder candidates right now.') else ...reorder.take(6).map((raw){final x=Map<String,dynamic>.from(raw as Map); return _reorderRow(x);}),
        const SizedBox(height:20),
        _title('Returns & refunds',returns.length.toString()+' requests waiting for action'),
        const SizedBox(height:10),
        if(returns.isEmpty)_empty('No return requests are waiting for action.') else ...returns.take(6).map((raw){final x=Map<String,dynamic>.from(raw as Map); return _returnRow(x);}),
        const SizedBox(height:20),
        _title('Delivery control',deliveries.length.toString()+' assignments'),
        const SizedBox(height:10),
        if(deliveries.isEmpty)_empty('No online delivery assignments yet.') else ...deliveries.take(6).map((raw){final x=Map<String,dynamic>.from(raw as Map); return _deliveryRow(x);}),
        const SizedBox(height:20),
        _title('Performance','Last 30 days'),
        const SizedBox(height:10),
        _performance(),
        const SizedBox(height:20),
        _title('Security center',n(security['active_sessions']).toString()+' active sessions'),
        const SizedBox(height:10),
        _security(),
        const SizedBox(height:20),
        _title('Shop coupons',coupons.length.toString()+' codes'),
        const SizedBox(height:10),
        _couponsPanel(),
        const SizedBox(height:10),
        _feature(Icons.assignment_return_rounded,'Returns & refunds','Customer return workflow with stock restoration.',const Color(0xFFEF4444)),
        _feature(Icons.card_giftcard_rounded,'Loyalty & rewards','Delivered online orders can earn points.',const Color(0xFF0F766E)),
        _feature(Icons.delivery_dining_rounded,'Delivery management','Assign drivers and track online deliveries.',const Color(0xFF2563EB)),
      ])),
    );
  }

  Widget _hero()=>Container(padding:const EdgeInsets.all(20),decoration:BoxDecoration(gradient:const LinearGradient(colors:[Color(0xFF11183F),Color(0xFF4C1D95),Color(0xFF5B3DF5)]),borderRadius:BorderRadius.circular(26),boxShadow:[BoxShadow(color:Color(0x334C1D95),blurRadius:28,offset:Offset(0,14))]),child:Row(children:[Container(width:52,height:52,decoration:BoxDecoration(color:Colors.white12,borderRadius:BorderRadius.circular(16)),child:const Icon(Icons.auto_awesome_rounded,color:Colors.white,size:27)),const SizedBox(width:12),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[LiveTranslatedText('Retail Growth Suite',style:GoogleFonts.poppins(color:Colors.white,fontSize:20,fontWeight:FontWeight.w800)),const SizedBox(height:3),LiveTranslatedText('AI insights, smart inventory, branches, delivery, loyalty, promotions and security.',style:GoogleFonts.poppins(color:Colors.white70,fontSize:11.5,height:1.4))]))]));
  Widget _title(String a,String b)=>Column(crossAxisAlignment:CrossAxisAlignment.start,children:[LiveTranslatedText(a,style:GoogleFonts.poppins(fontSize:17,fontWeight:FontWeight.w800,color:const Color(0xFF111827))),const SizedBox(height:2),LiveTranslatedText(b,style:GoogleFonts.poppins(fontSize:10.5,color:const Color(0xFF94A3B8)))]);
  Widget _metric(IconData icon,String label,String value,Color color)=>Container(padding:const EdgeInsets.all(11),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(17),border:Border.all(color:color.withValues(alpha:.12))),child:Row(children:[Container(width:38,height:38,decoration:BoxDecoration(color:color.withValues(alpha:.1),borderRadius:BorderRadius.circular(12)),child:Icon(icon,color:color,size:18)),const SizedBox(width:8),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,mainAxisAlignment:MainAxisAlignment.center,children:[LiveTranslatedText(label,maxLines:1,overflow:TextOverflow.ellipsis,style:GoogleFonts.poppins(fontSize:9,color:const Color(0xFF64748B))),const SizedBox(height:2),LiveTranslatedText(value,maxLines:1,overflow:TextOverflow.ellipsis,style:GoogleFonts.poppins(fontSize:14,fontWeight:FontWeight.w800,color:const Color(0xFF172033)))]))]));
  Widget _copilotCard() {
    return Container(
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(21),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Column(
        children: [
          TextField(
            controller: copilot,
            onSubmitted: (_) => ask(),
            decoration: InputDecoration(
              hint: LiveTranslatedText('Ask about stock, profit, returns, delivery or online orders…'),
              prefixIcon: const Icon(
                Icons.psychology_rounded,
                color: Color(0xFF6366F1),
              ),
              suffixIcon: IconButton(
                onPressed: () => ask(),
                icon: const Icon(Icons.send_rounded),
              ),
              filled: true,
              fillColor: const Color(0xFFF8FAFC),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          const SizedBox(height: 9),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              'What should I restock?',
              'How is profit?',
              'Any returns?',
              'Delivery status',
              'Shop summary',
            ].map((question) {
              return ActionChip(
                label: LiveTranslatedText(
                  question,
                  style: GoogleFonts.poppins(
                    fontSize: 9.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                onPressed: () => ask(question),
              );
            }).toList(),
          ),
          if (answer.isNotEmpty) ...[
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFEEF2FF),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: LiveTranslatedText(
                  answer,
                  style: GoogleFonts.poppins(
                    fontSize: 11.5,
                    height: 1.45,
                    color: const Color(0xFF312E81),
                  ),
                ),
              ),
            ),
          ],
          if (copilotHistory.isNotEmpty) ...[
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: LiveTranslatedText(
                'Recent Copilot questions',
                style: GoogleFonts.poppins(
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  color: const Color(0xFF64748B),
                ),
              ),
            ),
            ...copilotHistory.take(3).map((raw) {
              final item = Map<String, dynamic>.from(raw as Map);
              return ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(
                  Icons.history_rounded,
                  size: 17,
                  color: Color(0xFF818CF8),
                ),
                title: LiveTranslatedText(
                  item['question']?.toString() ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.poppins(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                subtitle: LiveTranslatedText(
                  item['answer']?.toString() ?? '',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.poppins(
                    fontSize: 9.5,
                    color: const Color(0xFF64748B),
                  ),
                ),
              );
            }),
          ],
        ],
      ),
    );
  }

  Widget _reorderRow(Map<String,dynamic> x)=>Container(margin:const EdgeInsets.only(bottom:8),padding:const EdgeInsets.all(13),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(16),border:Border.all(color:const Color(0xFFE2E8F0))),child:Row(children:[Icon(x['priority']=='CRITICAL'?Icons.error_rounded:Icons.warning_amber_rounded,color:x['priority']=='CRITICAL'?Colors.red:Colors.orange),const SizedBox(width:9),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[LiveTranslatedText(x['product_name']?.toString()??'Product',style:GoogleFonts.poppins(fontWeight:FontWeight.w800)),LiveTranslatedText('${x['current_stock']} stock · ${x['estimated_days_remaining']??'—'} days cover',style:GoogleFonts.poppins(fontSize:10,color:const Color(0xFF64748B)))])),LiveTranslatedText('Order '+x['suggested_reorder_quantity'].toString(),style:GoogleFonts.poppins(fontSize:10.5,fontWeight:FontWeight.w800,color:const Color(0xFF4F46E5)))]));
  Widget _returnRow(Map<String,dynamic> x){
    final id=n(x['id']);
    final status=x['status']?.toString()??'REQUESTED';
    return Container(
      margin:const EdgeInsets.only(bottom:8),
      padding:const EdgeInsets.all(13),
      decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(16),border:Border.all(color:const Color(0xFFFECACA))),
      child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
        Row(children:[
          const Icon(Icons.assignment_return_rounded,color:Color(0xFFEF4444)),
          const SizedBox(width:8),
          Expanded(child:LiveTranslatedText('Order #${x['order_id']}',style:GoogleFonts.poppins(fontWeight:FontWeight.w800))),
          LiveTranslatedText('₹${d(x['refund_amount']).toStringAsFixed(0)}',style:GoogleFonts.poppins(fontWeight:FontWeight.w800,color:const Color(0xFFB91C1C))),
        ]),
        const SizedBox(height:6),
        LiveTranslatedText(x['reason']?.toString()??'No reason',style:GoogleFonts.poppins(fontSize:10.5,color:const Color(0xFF64748B))),
        const SizedBox(height:10),
        if(status=='REQUESTED') Row(children:[
          Expanded(child:OutlinedButton.icon(onPressed:()=>decideReturn(id,false),icon:const Icon(Icons.close_rounded,size:15),label:const LiveTranslatedText('Reject'))),
          const SizedBox(width:8),
          Expanded(child:FilledButton.icon(onPressed:()=>decideReturn(id,true),icon:const Icon(Icons.check_rounded,size:15),label:const LiveTranslatedText('Approve'))),
        ]) else if(status=='REFUND_PENDING')
          SizedBox(width:double.infinity,child:FilledButton.icon(onPressed:()=>markRefunded(id),icon:const Icon(Icons.payments_rounded,size:15),label:const LiveTranslatedText('Mark refunded'))),
      ]),
    );
  }

  Widget _deliveryRow(Map<String,dynamic> x){
    final id=n(x['id']);
    final status=x['status']?.toString()??'ASSIGNED';
    final next=status=='ASSIGNED'?'PICKED_UP':status=='PICKED_UP'?'OUT_FOR_DELIVERY':status=='OUT_FOR_DELIVERY'?'DELIVERED':null;
    final label=next=='PICKED_UP'?'Pick up':next=='OUT_FOR_DELIVERY'?'Dispatch':next=='DELIVERED'?'Delivered':'';
    return Container(
      margin:const EdgeInsets.only(bottom:8),
      padding:const EdgeInsets.all(13),
      decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(16),border:Border.all(color:const Color(0xFFE2E8F0))),
      child:Row(children:[
        Container(width:42,height:42,decoration:BoxDecoration(color:const Color(0xFFEFF6FF),borderRadius:BorderRadius.circular(13)),child:const Icon(Icons.local_shipping_rounded,color:Color(0xFF2563EB))),
        const SizedBox(width:10),
        Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
          LiveTranslatedText('Order #${x['order_id']}',style:GoogleFonts.poppins(fontWeight:FontWeight.w800)),
          LiveTranslatedText('${x['driver_name']} · ${status.replaceAll('_',' ')}',style:GoogleFonts.poppins(fontSize:9.5,color:const Color(0xFF64748B))),
        ])),
        if(next!=null) FilledButton(onPressed:()=>updateDelivery(id,next),child:LiveTranslatedText(label,style:const TextStyle(fontSize:10))),
      ]),
    );
  }

  Widget _performance()=>Container(
    padding:const EdgeInsets.all(15),
    decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(18),border:Border.all(color:const Color(0xFFE2E8F0))),
    child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      Row(children:[
        Expanded(child:LiveTranslatedText('30-day intelligence',style:GoogleFonts.poppins(fontWeight:FontWeight.w800))),
        LiveTranslatedText('${List<dynamic>.from(analytics['top_products']??[]).length} top products',style:GoogleFonts.poppins(fontSize:10,color:const Color(0xFF64748B))),
      ]),
      const SizedBox(height:10),
      LiveTranslatedText(
        'Revenue ₹${d((analytics['sales']??{})['revenue']).toStringAsFixed(0)} · Online ₹${d((analytics['online']??{})['revenue']).toStringAsFixed(0)} · Profit estimate ₹${d((analytics['sales']??{})['profit_estimate']).toStringAsFixed(0)}',
        style:GoogleFonts.poppins(fontSize:10.5,color:const Color(0xFF475569)),
      ),
    ]),
  );
  Widget _security()=>Container(padding:const EdgeInsets.all(15),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(18),border:Border.all(color:const Color(0xFFE2E8F0))),child:LiveTranslatedText('JWT RBAC · rate limiting · restricted CORS · audit logging\n\nActive sessions: '+n(security['active_sessions']).toString(),style:GoogleFonts.poppins(fontSize:11,color:const Color(0xFF475569),height:1.5)));
  Widget _feature(IconData icon,String title,String subtitle,Color color)=>Container(margin:const EdgeInsets.only(bottom:9),padding:const EdgeInsets.all(14),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(16),border:Border.all(color:const Color(0xFFE2E8F0))),child:Row(children:[Container(width:42,height:42,decoration:BoxDecoration(color:color.withValues(alpha:.1),borderRadius:BorderRadius.circular(13)),child:Icon(icon,color:color)),const SizedBox(width:11),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[LiveTranslatedText(title,style:GoogleFonts.poppins(fontWeight:FontWeight.w800)),const SizedBox(height:3),LiveTranslatedText(subtitle,style:GoogleFonts.poppins(fontSize:10.5,color:const Color(0xFF64748B)))]))]));
  Widget _error(String s)=>Container(padding:const EdgeInsets.all(13),decoration:BoxDecoration(color:const Color(0xFFFFF1F2),borderRadius:BorderRadius.circular(14),border:Border.all(color:const Color(0xFFFECACA))),child:LiveTranslatedText(s,style:GoogleFonts.poppins(fontSize:10.5,color:const Color(0xFFBE123C))));
  Widget _empty(String s)=>Container(width:double.infinity,padding:const EdgeInsets.all(17),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(15),border:Border.all(color:const Color(0xFFE2E8F0))),child:LiveTranslatedText(s,style:GoogleFonts.poppins(fontSize:10.5,color:const Color(0xFF64748B))));
}
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
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
    if(r.statusCode!=200) throw Exception('Request failed: ${r.statusCode}');
    final d=jsonDecode(r.body);
    return d is Map<String,dynamic>?d:Map<String,dynamic>.from(d as Map);
  }

  Future<void> _load() async {
    setState((){loading=true;error='';});
    try{
      final r=await Future.wait([
        get('/growth/overview'),
        get('/growth/analytics?days=30'),
        get('/growth/reorder-suggestions'),
        get('/growth/security-center'),
        get('/growth/coupons'),
        get('/growth/returns?status=REQUESTED'),
        get('/growth/deliveries'),
        get('/growth/copilot/history?limit=6'),
      ]);
      if(!mounted)return;
      setState((){
        overview=r[0]; analytics=r[1]; reorder=List<dynamic>.from(r[2]['suggestions']??[]); security=r[3]; coupons=List<dynamic>.from(r[4]['coupons']??[]); returns=List<dynamic>.from(r[5]['returns']??[]); deliveries=List<dynamic>.from(r[6]['deliveries']??[]); copilotHistory=List<dynamic>.from(r[7]['history']??[]);
      });
    }catch(e){ if(mounted)setState(()=>error=e.toString()); }
    finally{ if(mounted)setState(()=>loading=false); }
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

  int n(dynamic v)=>(v as num?)?.toInt()??0;
  double d(dynamic v)=>(v as num?)?.toDouble()??0;

  @override Widget build(BuildContext context){
    final sales=Map<String,dynamic>.from(overview['sales']??{});
    final online=Map<String,dynamic>.from(overview['online']??{});
    final inv=Map<String,dynamic>.from(overview['inventory']??{});
    final branches=n(overview['branches']);
    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FB),
      appBar: AppBar(title:Text('Retail Growth',style:GoogleFonts.poppins(fontWeight:FontWeight.w800)),backgroundColor:Colors.white,foregroundColor:const Color(0xFF111827),elevation:0,actions:[IconButton(onPressed:loading?null:_load,icon:const Icon(Icons.refresh_rounded))]),
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
        _title('Promotions',coupons.length.toString()+' coupons'),
        const SizedBox(height:10),
        _feature(Icons.local_offer_rounded,'Coupons & promotions','Online checkout discounts are now supported.',const Color(0xFFEC4899)),
        _feature(Icons.assignment_return_rounded,'Returns & refunds','Customer return workflow with stock restoration.',const Color(0xFFEF4444)),
        _feature(Icons.card_giftcard_rounded,'Loyalty & rewards','Delivered online orders can earn points.',const Color(0xFF0F766E)),
        _feature(Icons.delivery_dining_rounded,'Delivery management','Assign drivers and track online deliveries.',const Color(0xFF2563EB)),
      ])),
    );
  }

  Widget _hero()=>Container(padding:const EdgeInsets.all(20),decoration:BoxDecoration(gradient:const LinearGradient(colors:[Color(0xFF11183F),Color(0xFF4C1D95),Color(0xFF5B3DF5)]),borderRadius:BorderRadius.circular(26),boxShadow:[BoxShadow(color:Color(0x334C1D95),blurRadius:28,offset:Offset(0,14))]),child:Row(children:[Container(width:52,height:52,decoration:BoxDecoration(color:Colors.white12,borderRadius:BorderRadius.circular(16)),child:const Icon(Icons.auto_awesome_rounded,color:Colors.white,size:27)),const SizedBox(width:12),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text('Retail Growth Suite',style:GoogleFonts.poppins(color:Colors.white,fontSize:20,fontWeight:FontWeight.w800)),const SizedBox(height:3),Text('AI insights, smart inventory, branches, delivery, loyalty, promotions and security.',style:GoogleFonts.poppins(color:Colors.white70,fontSize:11.5,height:1.4))]))]));
  Widget _title(String a,String b)=>Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(a,style:GoogleFonts.poppins(fontSize:17,fontWeight:FontWeight.w800,color:const Color(0xFF111827))),const SizedBox(height:2),Text(b,style:GoogleFonts.poppins(fontSize:10.5,color:const Color(0xFF94A3B8)))]);
  Widget _metric(IconData icon,String label,String value,Color color)=>Container(padding:const EdgeInsets.all(11),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(17),border:Border.all(color:color.withValues(alpha:.12))),child:Row(children:[Container(width:38,height:38,decoration:BoxDecoration(color:color.withValues(alpha:.1),borderRadius:BorderRadius.circular(12)),child:Icon(icon,color:color,size:18)),const SizedBox(width:8),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,mainAxisAlignment:MainAxisAlignment.center,children:[Text(label,maxLines:1,overflow:TextOverflow.ellipsis,style:GoogleFonts.poppins(fontSize:9,color:const Color(0xFF64748B))),const SizedBox(height:2),Text(value,maxLines:1,overflow:TextOverflow.ellipsis,style:GoogleFonts.poppins(fontSize:14,fontWeight:FontWeight.w800,color:const Color(0xFF172033)))]))]));
  Widget _copilotCard()=>Container(
    padding:const EdgeInsets.all(15),
    decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(21),border:Border.all(color:const Color(0xFFE2E8F0))),
    child:Column(children:[
      TextField(controller:copilot,onSubmitted:(_)=>ask(),decoration:InputDecoration(
        hintText:'Ask about stock, profit, returns, delivery or online orders…',
        prefixIcon:const Icon(Icons.psychology_rounded,color:Color(0xFF6366F1)),
        suffixIcon:IconButton(onPressed:()=>ask(),icon:const Icon(Icons.send_rounded)),
        filled:true,fillColor:const Color(0xFFF8FAFC),
        border:OutlineInputBorder(borderRadius:BorderRadius.circular(14),borderSide:BorderSide.none),
      )),
      const SizedBox(height:9),
      Wrap(spacing:6,runSpacing:6,children:[
        'What should I restock?','How is profit?','Any returns?','Delivery status','Shop summary'
      ].map((q)=>ActionChip(
        label:Text(q,style:GoogleFonts.poppins(fontSize:9.5,fontWeight:FontWeight.w700)),
        onPressed:()=>ask(q),
      )).toList()),
      if(answer.isNotEmpty) ...[
        const SizedBox(height:10),
        Align(alignment:Alignment.centerLeft,child:Container(
          width:double.infinity,
          padding:const EdgeInsets.all(12),
          decoration:BoxDecoration(color:const Color(0xFFEEF2FF),borderRadius:BorderRadius.circular(14)),
          child:Text(answer,style:GoogleFonts.poppins(fontSize:11.5,height:1.45,color:const Color(0xFF312E81))),
        )),
      ],
      if(copilotHistory.isNotEmpty) ...[
        const SizedBox(height:10),
        Align(
          alignment:Alignment.centerLeft,
          child:Text('Recent Copilot questions',style:GoogleFonts.poppins(fontSize:10,fontWeight:FontWeight.w800,color:const Color(0xFF64748B))),
        ),
        ...copilotHistory.take(3).map((raw){
          final item=Map<String,dynamic>.from(raw as Map);
          return ListTile(
            dense:true,
            contentPadding:EdgeInsets.zero,
            leading:const Icon(Icons.history_rounded,size:17,color:Color(0xFF818CF8)),
            title:Text(item['question']?.toString()??'',maxLines:1,overflow:TextOverflow.ellipsis,style:GoogleFonts.poppins(fontSize:10.5,fontWeight:FontWeight.w700)),
            subtitle:Text(item['answer']?.toString()??'',maxLines:2,overflow:TextOverflow.ellipsis,style:GoogleFonts.poppins(fontSize:9.5,color:const Color(0xFF64748B))),
          );
        }),
      ],
    ),
  );
  Widget _reorderRow(Map<String,dynamic> x)=>Container(margin:const EdgeInsets.only(bottom:8),padding:const EdgeInsets.all(13),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(16),border:Border.all(color:const Color(0xFFE2E8F0))),child:Row(children:[Icon(x['priority']=='CRITICAL'?Icons.error_rounded:Icons.warning_amber_rounded,color:x['priority']=='CRITICAL'?Colors.red:Colors.orange),const SizedBox(width:9),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(x['product_name']?.toString()??'Product',style:GoogleFonts.poppins(fontWeight:FontWeight.w800)),Text('${x['current_stock']} stock · ${x['estimated_days_remaining']??'—'} days cover',style:GoogleFonts.poppins(fontSize:10,color:const Color(0xFF64748B)))])),Text('Order '+x['suggested_reorder_quantity'].toString(),style:GoogleFonts.poppins(fontSize:10.5,fontWeight:FontWeight.w800,color:const Color(0xFF4F46E5)))]));
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
          Expanded(child:Text('Order #${x['order_id']}',style:GoogleFonts.poppins(fontWeight:FontWeight.w800))),
          Text('₹${d(x['refund_amount']).toStringAsFixed(0)}',style:GoogleFonts.poppins(fontWeight:FontWeight.w800,color:const Color(0xFFB91C1C))),
        ]),
        const SizedBox(height:6),
        Text(x['reason']?.toString()??'No reason',style:GoogleFonts.poppins(fontSize:10.5,color:const Color(0xFF64748B))),
        const SizedBox(height:10),
        if(status=='REQUESTED') Row(children:[
          Expanded(child:OutlinedButton.icon(onPressed:()=>decideReturn(id,false),icon:const Icon(Icons.close_rounded,size:15),label:const Text('Reject'))),
          const SizedBox(width:8),
          Expanded(child:FilledButton.icon(onPressed:()=>decideReturn(id,true),icon:const Icon(Icons.check_rounded,size:15),label:const Text('Approve'))),
        ]) else if(status=='REFUND_PENDING')
          SizedBox(width:double.infinity,child:FilledButton.icon(onPressed:()=>markRefunded(id),icon:const Icon(Icons.payments_rounded,size:15),label:const Text('Mark refunded'))),
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
          Text('Order #${x['order_id']}',style:GoogleFonts.poppins(fontWeight:FontWeight.w800)),
          Text('${x['driver_name']} · ${status.replaceAll('_',' ')}',style:GoogleFonts.poppins(fontSize:9.5,color:const Color(0xFF64748B))),
        ])),
        if(next!=null) FilledButton(onPressed:()=>updateDelivery(id,next),child:Text(label,style:const TextStyle(fontSize:10))),
      ]),
    );
  }

  Widget _performance()=>Container(
    padding:const EdgeInsets.all(15),
    decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(18),border:Border.all(color:const Color(0xFFE2E8F0))),
    child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      Row(children:[
        Expanded(child:Text('30-day intelligence',style:GoogleFonts.poppins(fontWeight:FontWeight.w800))),
        Text('${List<dynamic>.from(analytics['top_products']??[]).length} top products',style:GoogleFonts.poppins(fontSize:10,color:const Color(0xFF64748B))),
      ]),
      const SizedBox(height:10),
      Text(
        'Revenue ₹${d((analytics['sales']??{})['revenue']).toStringAsFixed(0)} · Online ₹${d((analytics['online']??{})['revenue']).toStringAsFixed(0)} · Profit estimate ₹${d((analytics['sales']??{})['profit_estimate']).toStringAsFixed(0)}',
        style:GoogleFonts.poppins(fontSize:10.5,color:const Color(0xFF475569)),
      ),
    ]),
  );
  Widget _security()=>Container(padding:const EdgeInsets.all(15),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(18),border:Border.all(color:const Color(0xFFE2E8F0))),child:Text('JWT RBAC · rate limiting · restricted CORS · audit logging\n\nActive sessions: '+n(security['active_sessions']).toString(),style:GoogleFonts.poppins(fontSize:11,color:const Color(0xFF475569),height:1.5)));
  Widget _feature(IconData icon,String title,String subtitle,Color color)=>Container(margin:const EdgeInsets.only(bottom:9),padding:const EdgeInsets.all(14),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(16),border:Border.all(color:const Color(0xFFE2E8F0))),child:Row(children:[Container(width:42,height:42,decoration:BoxDecoration(color:color.withValues(alpha:.1),borderRadius:BorderRadius.circular(13)),child:Icon(icon,color:color)),const SizedBox(width:11),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(title,style:GoogleFonts.poppins(fontWeight:FontWeight.w800)),const SizedBox(height:3),Text(subtitle,style:GoogleFonts.poppins(fontSize:10.5,color:const Color(0xFF64748B)))]))]));
  Widget _error(String s)=>Container(padding:const EdgeInsets.all(13),decoration:BoxDecoration(color:const Color(0xFFFFF1F2),borderRadius:BorderRadius.circular(14),border:Border.all(color:const Color(0xFFFECACA))),child:Text(s,style:GoogleFonts.poppins(fontSize:10.5,color:const Color(0xFFBE123C))));
  Widget _empty(String s)=>Container(width:double.infinity,padding:const EdgeInsets.all(17),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(15),border:Border.all(color:const Color(0xFFE2E8F0))),child:Text(s,style:GoogleFonts.poppins(fontSize:10.5,color:const Color(0xFF64748B))));
}
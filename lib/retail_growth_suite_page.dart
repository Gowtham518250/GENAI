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
      ]);
      if(!mounted)return;
      setState((){
        overview=r[0]; analytics=r[1]; reorder=List<dynamic>.from(r[2]['suggestions']??[]); security=r[3]; coupons=List<dynamic>.from(r[4]['coupons']??[]);
      });
    }catch(e){ if(mounted)setState(()=>error=e.toString()); }
    finally{ if(mounted)setState(()=>loading=false); }
  }

  Future<void> ask() async {
    final q=copilot.text.trim();
    if(q.isEmpty)return;
    try{
      final r=await get('/growth/copilot?q='+Uri.encodeQueryComponent(q));
      if(mounted)setState(()=>answer=r['answer']?.toString()??'No answer.');
    }catch(_){ if(mounted)setState(()=>answer='Business Copilot is temporarily unavailable.'); }
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
  Widget _copilotCard()=>Container(padding:const EdgeInsets.all(15),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(21),border:Border.all(color:const Color(0xFFE2E8F0))),child:Column(children:[TextField(controller:copilot,onSubmitted:(_)=>ask(),decoration:InputDecoration(hintText:'What should I restock today?',prefixIcon:const Icon(Icons.psychology_rounded,color:Color(0xFF6366F1)),suffixIcon:IconButton(onPressed:ask,icon:const Icon(Icons.send_rounded)),filled:true,fillColor:const Color(0xFFF8FAFC),border:OutlineInputBorder(borderRadius:BorderRadius.circular(14),borderSide:BorderSide.none))),if(answer.isNotEmpty) ...[const SizedBox(height:10),Align(alignment:Alignment.centerLeft,child:Text(answer,style:GoogleFonts.poppins(fontSize:11.5,height:1.45,color:const Color(0xFF312E81)))]]));
  Widget _reorderRow(Map<String,dynamic> x)=>Container(margin:const EdgeInsets.only(bottom:8),padding:const EdgeInsets.all(13),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(16),border:Border.all(color:const Color(0xFFE2E8F0))),child:Row(children:[Icon(x['priority']=='CRITICAL'?Icons.error_rounded:Icons.warning_amber_rounded,color:x['priority']=='CRITICAL'?Colors.red:Colors.orange),const SizedBox(width:9),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(x['product_name']?.toString()??'Product',style:GoogleFonts.poppins(fontWeight:FontWeight.w800)),Text('${x['current_stock']} stock · ${x['estimated_days_remaining']??'—'} days cover',style:GoogleFonts.poppins(fontSize:10,color:const Color(0xFF64748B)))])),Text('Order '+x['suggested_reorder_quantity'].toString(),style:GoogleFonts.poppins(fontSize:10.5,fontWeight:FontWeight.w800,color:const Color(0xFF4F46E5)))]));
  Widget _performance()=>Container(padding:const EdgeInsets.all(15),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(18),border:Border.all(color:const Color(0xFFE2E8F0))),child:Text('See month revenue, expenses, estimated profit, online revenue and top products from the live backend.',style:GoogleFonts.poppins(fontSize:11,color:const Color(0xFF64748B),height:1.45)));
  Widget _security()=>Container(padding:const EdgeInsets.all(15),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(18),border:Border.all(color:const Color(0xFFE2E8F0))),child:Text('JWT RBAC · rate limiting · restricted CORS · audit logging\n\nActive sessions: '+n(security['active_sessions']).toString(),style:GoogleFonts.poppins(fontSize:11,color:const Color(0xFF475569),height:1.5)));
  Widget _feature(IconData icon,String title,String subtitle,Color color)=>Container(margin:const EdgeInsets.only(bottom:9),padding:const EdgeInsets.all(14),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(16),border:Border.all(color:const Color(0xFFE2E8F0))),child:Row(children:[Container(width:42,height:42,decoration:BoxDecoration(color:color.withValues(alpha:.1),borderRadius:BorderRadius.circular(13)),child:Icon(icon,color:color)),const SizedBox(width:11),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(title,style:GoogleFonts.poppins(fontWeight:FontWeight.w800)),const SizedBox(height:3),Text(subtitle,style:GoogleFonts.poppins(fontSize:10.5,color:const Color(0xFF64748B)))]))]));
  Widget _error(String s)=>Container(padding:const EdgeInsets.all(13),decoration:BoxDecoration(color:const Color(0xFFFFF1F2),borderRadius:BorderRadius.circular(14),border:Border.all(color:const Color(0xFFFECACA))),child:Text(s,style:GoogleFonts.poppins(fontSize:10.5,color:const Color(0xFFBE123C))));
  Widget _empty(String s)=>Container(width:double.infinity,padding:const EdgeInsets.all(17),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(15),border:Border.all(color:const Color(0xFFE2E8F0))),child:Text(s,style:GoogleFonts.poppins(fontSize:10.5,color:const Color(0xFF64748B))));
}
import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
}

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

const AndroidNotificationChannel channel = AndroidNotificationChannel(
  'sirdaba_high_importance', 'SirDaba Notifications',
  description: 'اشعارات SirDaba',
  importance: Importance.max, playSound: true,
);

const String kSiteUrl        = 'https://sirdaba.delivery';
const String kDistributorUrl = 'https://sirdaba.delivery/sirdaba-distributor';
const String kClientUrl      = 'https://sirdaba.delivery/sirdaba-client';
const String kHomeUrl        = 'https://sirdaba.delivery/';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
  await flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(channel);
  await flutterLocalNotificationsPlugin.initialize(
    const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    ),
    onDidReceiveNotificationResponse: (details) {},
  );
  SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(statusBarColor: Colors.transparent));
  runApp(const SirDabaApp());
}

class SirDabaApp extends StatelessWidget {
  const SirDabaApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SirDaba', debugShowCheckedModeBanner: false,
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFE8821A))),
      home: const SplashScreen(),
    );
  }
}

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});
  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _scale, _fade;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(duration: const Duration(milliseconds: 1200), vsync: this);
    _scale = Tween<double>(begin: 0.6, end: 1.0).animate(CurvedAnimation(parent: _ctrl, curve: Curves.elasticOut));
    _fade  = Tween<double>(begin: 0.0, end: 1.0).animate(CurvedAnimation(parent: _ctrl, curve: const Interval(0.0, 0.5, curve: Curves.easeIn)));
    _ctrl.forward();
    Future.wait([Future.delayed(const Duration(seconds: 2)), _checkSession()]).then((r) {
      if (!mounted) return;
      final s = r[1] as _SessionResult;
      Navigator.of(context).pushReplacement(PageRouteBuilder(
        pageBuilder: (_, __, ___) => MainWebViewScreen(initialUrl: s.startUrl),
        transitionsBuilder: (_, a, __, c) => FadeTransition(opacity: a, child: c),
        transitionDuration: const Duration(milliseconds: 400),
      ));
    });
  }

  Future<_SessionResult> _checkSession() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('app_token_backup') ?? '';
    if (token.isNotEmpty) {
      try {
        final res = await http.get(
          Uri.parse('$kSiteUrl/wp-json/sirdaba/v1/mobile/app-status'),
          headers: {
            'Authorization': 'Bearer $token',
            'User-Agent': 'Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36 SirDabaApp/1.0 SirDaba-App-Android-Agent',
          },
        ).timeout(const Duration(seconds: 8));
        if (res.statusCode == 200) {
          final d = jsonDecode(res.body) as Map<String, dynamic>;
          if (d['logged_in'] == true) {
            final t = ((d['sirdaba_user'] as Map?) ?? {})['type'] as String? ?? '';
            return _SessionResult(startUrl: t == 'distributor' ? kDistributorUrl : kClientUrl);
          }
        }
        if (res.statusCode == 401) { await prefs.remove('app_token_backup'); }
      } catch (_) {}
    }
    final em = prefs.getString('saved_email') ?? '';
    return _SessionResult(startUrl: em.isNotEmpty ? kClientUrl : kHomeUrl);
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return Scaffold(backgroundColor: Colors.white, body: Center(
      child: AnimatedBuilder(animation: _ctrl, builder: (_, __) => FadeTransition(opacity: _fade,
        child: ScaleTransition(scale: _scale, child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Image.asset('assets/images/logo.png', width: 260, height: 260, fit: BoxFit.contain),
          const SizedBox(height: 32),
          const Text('SirDaba Delivery', style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: Color(0xFFE8821A))),
          const SizedBox(height: 8),
          const Text('توصيل سريع وموثوق', style: TextStyle(fontSize: 14, color: Color(0xFF555555))),
          const SizedBox(height: 48),
          const CircularProgressIndicator(color: Color(0xFFE8821A), strokeWidth: 2.5),
        ])))),
    ));
  }
}

class _SessionResult {
  final String startUrl;
  const _SessionResult({required this.startUrl});
}

class MainWebViewScreen extends StatefulWidget {
  final String initialUrl;
  const MainWebViewScreen({super.key, this.initialUrl = kHomeUrl});
  @override
  State<MainWebViewScreen> createState() => _MainWebViewScreenState();
}

class _MainWebViewScreenState extends State<MainWebViewScreen> {
  late final WebViewController _wvc;
  bool _loading = true;
  String? _fcmToken;
  bool _tokenRegistered = false;

  static const String _kReadCookieJs = r'''
(function(){var t='';var cs=document.cookie.split(';');for(var i=0;i<cs.length;i++){var c=cs[i].trim();if(c.startsWith('sirdaba_app_token=')){t=c.substring('sirdaba_app_token='.length);break;}}if(t){window.SirDabaFlutter.postMessage(JSON.stringify({type:'app_token',token:decodeURIComponent(t)}));}else{window.SirDabaFlutter.postMessage(JSON.stringify({type:'cookie_missing'}));}})();
''';

  static const String _kInterceptorJs = r'''
(function(){var f=document.querySelector('#sdClientLoginForm');if(!f||f._sd)return;f._sd=true;f.addEventListener('submit',function(){var e=f.querySelector('input[name="email"]');var p=f.querySelector('input[name="password"]');if(e&&p&&e.value&&p.value){window.SirDabaFlutter.postMessage(JSON.stringify({type:'save_credentials',email:e.value,password:p.value}));}},true);})();
''';

  String _fillJs(String email, String pass) {
    final e = email.replaceAll("'", r"\'");
    final p = pass.replaceAll("'", r"\'");
    return """(function(){function f(){var em=document.querySelector('#sdClientLoginForm input[name="email"]');var pw=document.querySelector('#sdClientLoginForm input[name="password"]');if(em&&pw){em.value='$e';pw.value='$p';['input','change'].forEach(function(ev){em.dispatchEvent(new Event(ev,{bubbles:true}));pw.dispatchEvent(new Event(ev,{bubbles:true}));});}}setTimeout(f,500);})();""";
  }

  @override
  void initState() { super.initState(); _initWebView(); _initFCM(); }

  void _initWebView() {
    _wvc = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent('Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36 SirDabaApp/1.0 SirDaba-App-Android-Agent')
      ..addJavaScriptChannel('SirDabaFlutter', onMessageReceived: _onMsg)
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (_) => setState(() => _loading = true),
        onPageFinished: _onFinished,
        onWebResourceError: (_) => setState(() => _loading = false),
        onPermissionRequest: (request) async {
          await request.grant();
        },
        onNavigationRequest: (request) async {
          final url = request.url;
          if (url.startsWith('intent://') ||
              url.startsWith('geo:') ||
              url.startsWith('tel:') ||
              url.startsWith('whatsapp:') ||
              (!url.contains('sirdaba.delivery') && url.contains('google.com/maps'))) {
            String targetUrl = url;
            if (url.startsWith('intent://')) {
              targetUrl = 'https://' + url.substring(9).split(';').first;
            }
            final uri = Uri.parse(targetUrl);
            if (await canLaunchUrl(uri)) {
              await launchUrl(uri, mode: LaunchMode.externalApplication);
            }
            return NavigationDecision.prevent;
          }
          return NavigationDecision.navigate;
        },
      ))
      ..loadRequest(Uri.parse(widget.initialUrl));
  }

  void _onFinished(String url) async {
    setState(() => _loading = false);
    final v = ui.PlatformDispatcher.instance.views.first;
    final dp = v.padding.top / v.devicePixelRatio;
    _wvc.runJavaScript("document.documentElement.style.setProperty('--sd-status-bar-height','${dp.toStringAsFixed(1)}px');");
    _wvc.runJavaScript(_kReadCookieJs);
    if (url.contains('sirdaba-client') || url.contains('sirdaba-distributor')) {
      _wvc.runJavaScript(_kInterceptorJs);
      final p = await SharedPreferences.getInstance();
      final em = p.getString('saved_email') ?? '';
      final pw = p.getString('saved_password') ?? '';
      if (em.isNotEmpty && pw.isNotEmpty) _wvc.runJavaScript(_fillJs(em, pw));
    }
  }

  void _onMsg(JavaScriptMessage msg) async {
    try {
      final d = jsonDecode(msg.message) as Map<String, dynamic>;
      final type = d['type'] as String? ?? '';
      if (type == 'app_token') {
        final t = d['token'] as String? ?? '';
        if (t.isNotEmpty) {
          final p = await SharedPreferences.getInstance();
          await p.setString('app_token_backup', t);
          if (_fcmToken != null && !_tokenRegistered) _registerFcm(_fcmToken!, t);
        }
      } else if (type == 'save_credentials') {
        final em = d['email'] as String? ?? '';
        final pw = d['password'] as String? ?? '';
        if (em.isNotEmpty && pw.isNotEmpty) {
          final p = await SharedPreferences.getInstance();
          await p.setString('saved_email', em);
          await p.setString('saved_password', pw);
        }
      } else if (type == 'cookie_missing') {
        final p = await SharedPreferences.getInstance();
        final t = p.getString('app_token_backup') ?? '';
        if (t.isEmpty) return;
        try {
          final res = await http.post(
            Uri.parse('$kSiteUrl/wp-json/sirdaba/v1/mobile/set-app-token'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'token': t}),
          );
          if (res.statusCode == 200) { _wvc.reload(); } else { await p.remove('app_token_backup'); }
        } catch (_) {}
      }
    } catch (_) {}
  }

  Future<void> _initFCM() async {
    final m = FirebaseMessaging.instance;
    await m.requestPermission(alert: true, badge: true, sound: true);
    await m.setForegroundNotificationPresentationOptions(
      alert: true,
      badge: true,
      sound: true,
    );
    final t = await m.getToken();
    if (t != null) await _newToken(t);
    m.onTokenRefresh.listen(_newToken);
    FirebaseMessaging.onMessage.listen((msg) {
      final n = msg.notification;
      final a = n?.android;
      if (n != null && a != null) {
        flutterLocalNotificationsPlugin.show(
          n.hashCode, n.title, n.body,
          NotificationDetails(android: AndroidNotificationDetails(
            channel.id, channel.name,
            channelDescription: channel.description,
            importance: Importance.max,
            priority: Priority.high,
            icon: '@mipmap/ic_launcher',
          )),
        );
      }
    });
    FirebaseMessaging.onMessageOpenedApp.listen(_tap);
    final init = await m.getInitialMessage();
    if (init != null) _tap(init);
  }

  Future<void> _newToken(String t) async {
    final p = await SharedPreferences.getInstance();
    await p.setString('fcm_token', t);
    _fcmToken = t;
    _tokenRegistered = false;
    try { await _wvc.runJavaScript("localStorage.setItem('fcm_token','$t');"); } catch (_) {}
    try { await _wvc.runJavaScript(_kReadCookieJs); } catch (_) {}
    final authTok = p.getString('app_token_backup') ?? '';
    _registerFcm(t, authTok);
  }

  Future<void> _registerFcm(String fcm, String tok) async {
    try {
      final p = await SharedPreferences.getInstance();
      final old = p.getString('fcm_token_registered') ?? '';
      final headers = <String, String>{'Content-Type': 'application/json'};
      if (tok.isNotEmpty) headers['Authorization'] = 'Bearer $tok';
      final res = await http.post(
        Uri.parse('$kSiteUrl/wp-json/sirdaba/v1/mobile/device-token'),
        headers: headers,
        body: jsonEncode({
          'token': fcm,
          'platform': 'android',
          'app_version': '1.0.0',
          if (old.isNotEmpty && old != fcm) 'old_token': old,
        }),
      );
      if (res.statusCode == 200) {
        _tokenRegistered = true;
        await p.setString('fcm_token_registered', fcm);
      }
    } catch (_) {}
  }

  void _tap(RemoteMessage msg) {
    final url = msg.data['url'] ?? msg.data['link'];
    if (url != null) _wvc.loadRequest(Uri.parse(url));
  }

  Future<bool> _onBack() async {
    if (await _wvc.canGoBack()) { _wvc.goBack(); return false; }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(onWillPop: _onBack, child: Scaffold(
      backgroundColor: Colors.white,
      body: Stack(children: [
        WebViewWidget(controller: _wvc),
        if (_loading) Container(color: Colors.white,
          child: const Center(child: CircularProgressIndicator(color: Color(0xFFE8821A), strokeWidth: 2.5))),
      ]),
    ));
  }
}

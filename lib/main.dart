import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
}

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

const AndroidNotificationChannel channel = AndroidNotificationChannel(
  'sirdaba_high_importance',
  'SirDaba Notifications',
  description: 'اشعارات SirDaba',
  importance: Importance.max,
  playSound: true,
);

const String kSiteUrl = 'https://sirdaba.delivery';
const String kDistributorUrl = '$kSiteUrl/sirdaba-distributor';
const String kClientUrl      = '$kSiteUrl/sirdaba-client';
const String kHomeUrl        = '$kSiteUrl/';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
  await flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(channel);
  const AndroidInitializationSettings androidSettings =
      AndroidInitializationSettings('@mipmap/ic_launcher');
  await flutterLocalNotificationsPlugin.initialize(
      const InitializationSettings(android: androidSettings));
  SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(statusBarColor: Colors.transparent));
  runApp(const SirDabaApp());
}

class SirDabaApp extends StatelessWidget {
  const SirDabaApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SirDaba',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
          colorScheme:
              ColorScheme.fromSeed(seedColor: const Color(0xFFE8821A))),
      home: const SplashScreen(),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SPLASH — يتحقق من session قبل ما يكمل
// ─────────────────────────────────────────────────────────────────────────────
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});
  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _scale, _fade;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        duration: const Duration(milliseconds: 1200), vsync: this);
    _scale = Tween<double>(begin: 0.6, end: 1.0).animate(
        CurvedAnimation(parent: _ctrl, curve: Curves.elasticOut));
    _fade = Tween<double>(begin: 0.0, end: 1.0).animate(CurvedAnimation(
        parent: _ctrl,
        curve: const Interval(0.0, 0.5, curve: Curves.easeIn)));
    _ctrl.forward();

    // ننتظر 2 ثانية minimum للـ splash ثم نتحقق من الـ session
    Future.wait([
      Future.delayed(const Duration(seconds: 2)),
      _checkSession(),
    ]).then((results) {
      if (!mounted) return;
      final sessionResult = results[1] as _SessionResult;
      Navigator.of(context).pushReplacement(PageRouteBuilder(
        pageBuilder: (_, __, ___) =>
            MainWebViewScreen(initialUrl: sessionResult.startUrl),
        transitionsBuilder: (_, a, __, c) =>
            FadeTransition(opacity: a, child: c),
        transitionDuration: const Duration(milliseconds: 400),
      ));
    });
  }

  /// يتحقق من session المستخدم — يرجع URL المناسب للبداية
  Future<_SessionResult> _checkSession() async {
    final prefs = await SharedPreferences.getInstance();
    final savedToken = prefs.getString('app_token_backup') ?? '';

    if (savedToken.isEmpty) {
      return _SessionResult(startUrl: kHomeUrl);
    }

    try {
      final response = await http.get(
        Uri.parse('$kSiteUrl/wp-json/sirdaba/v1/mobile/app-status'),
        headers: {
          'Authorization': 'Bearer $savedToken',
          'User-Agent':
              'Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36 SirDabaApp/1.0 SirDaba-App-Android-Agent',
        },
      ).timeout(const Duration(seconds: 8));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final loggedIn = data['logged_in'] == true;
        final userType = (data['sirdaba_user'] as Map<String, dynamic>?)?['type'] as String? ?? '';

        if (loggedIn) {
          final dashUrl = userType == 'distributor' ? kDistributorUrl : kClientUrl;
          return _SessionResult(startUrl: dashUrl, userType: userType, token: savedToken);
        }
      } else if (response.statusCode == 401) {
        // Token انتهت صلاحيته
        await prefs.remove('app_token_backup');
        await prefs.remove('fcm_token_registered');
      }
    } catch (_) {
      // خطأ في الشبكة — ابدأ من الـ home بدل ما تعلق
    }

    return _SessionResult(startUrl: kHomeUrl);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Center(
        child: AnimatedBuilder(
          animation: _ctrl,
          builder: (_, __) => FadeTransition(
            opacity: _fade,
            child: ScaleTransition(
              scale: _scale,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Image.asset('assets/images/logo.png',
                      width: 260, height: 260, fit: BoxFit.contain),
                  const SizedBox(height: 32),
                  const Text('SirDaba Delivery',
                      style: TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFFE8821A))),
                  const SizedBox(height: 8),
                  const Text('توصيل سريع وموثوق',
                      style: TextStyle(
                          fontSize: 14, color: Color(0xFF555555))),
                  const SizedBox(height: 48),
                  const CircularProgressIndicator(
                      color: Color(0xFFE8821A), strokeWidth: 2.5),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// نتيجة فحص الـ session
class _SessionResult {
  final String startUrl;
  final String userType;
  final String token;
  const _SessionResult({
    required this.startUrl,
    this.userType = '',
    this.token = '',
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// MAIN WEBVIEW
// ─────────────────────────────────────────────────────────────────────────────
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

  // JS لقراءة cookie وإرساله لـ Flutter
  static const String _kReadCookieJs = '''
    (function() {
      var appToken = '';
      var cookies = document.cookie.split(';');
      for (var i = 0; i < cookies.length; i++) {
        var c = cookies[i].trim();
        if (c.startsWith('sirdaba_app_token=')) {
          appToken = c.substring('sirdaba_app_token='.length);
          break;
        }
      }
      if (appToken) {
        window.SirDabaFlutter.postMessage(JSON.stringify({
          type: 'app_token',
          token: decodeURIComponent(appToken)
        }));
      } else {
        window.SirDabaFlutter.postMessage(JSON.stringify({
          type: 'cookie_missing'
        }));
      }
    })();
  ''';

  @override
  void initState() {
    super.initState();
    _initWebView();
    _initFCM();
  }

  void _initWebView() {
    _wvc = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(
          'Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36 SirDabaApp/1.0 SirDaba-App-Android-Agent')
      ..addJavaScriptChannel('SirDabaFlutter',
          onMessageReceived: _onJsMessage)
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (_) => setState(() => _loading = true),
        onPageFinished: _onPageFinished,
        onWebResourceError: (_) => setState(() => _loading = false),
      ))
      ..loadRequest(Uri.parse(widget.initialUrl));
  }

  void _onPageFinished(String url) {
    setState(() => _loading = false);
    _injectStatusBarHeight();
    _wvc.runJavaScript(_kReadCookieJs);
  }

  void _injectStatusBarHeight() {
    final double ratio = ui.PlatformDispatcher.instance.views.first.devicePixelRatio;
    final double statusBarPx = ui.PlatformDispatcher.instance.views.first.padding.top;
    final double statusBarDp = statusBarPx / ratio;
    _wvc.runJavaScript(
      "document.documentElement.style.setProperty('--sd-status-bar-height', '${statusBarDp.toStringAsFixed(1)}px');"
    );
  }

  void _onJsMessage(JavaScriptMessage msg) async {
    try {
      final data = jsonDecode(msg.message) as Map<String, dynamic>;
      final type = data['type'] as String? ?? '';

      if (type == 'app_token') {
        final appToken = data['token'] as String? ?? '';
        if (appToken.isNotEmpty) {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('app_token_backup', appToken);

          if (_fcmToken != null && !_tokenRegistered) {
            _registerFcmTokenWithAuth(_fcmToken!, appToken);
          }
        }
      } else if (type == 'cookie_missing') {
        await _restoreSessionFromPrefs();
      }
    } catch (_) {}
  }

  Future<void> _restoreSessionFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final savedToken = prefs.getString('app_token_backup') ?? '';
    if (savedToken.isEmpty) return;

    try {
      final response = await http.post(
        Uri.parse('$kSiteUrl/wp-json/sirdaba/v1/mobile/set-app-token'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'token': savedToken}),
      );

      if (response.statusCode == 200) {
        _wvc.reload();
      } else {
        await prefs.remove('app_token_backup');
        await prefs.remove('fcm_token_registered');
        _tokenRegistered = false;
      }
    } catch (_) {}
  }

  Future<void> _initFCM() async {
    final m = FirebaseMessaging.instance;
    await m.requestPermission(alert: true, badge: true, sound: true);

    final token = await m.getToken();
    if (token != null) await _handleNewToken(token);
    m.onTokenRefresh.listen(_handleNewToken);

    FirebaseMessaging.onMessage.listen((msg) {
      final n = msg.notification;
      final a = n?.android;
      if (n != null && a != null) {
        flutterLocalNotificationsPlugin.show(
          n.hashCode,
          n.title,
          n.body,
          NotificationDetails(
            android: AndroidNotificationDetails(
              channel.id,
              channel.name,
              channelDescription: channel.description,
              importance: Importance.max,
              priority: Priority.high,
              icon: '@mipmap/ic_launcher',
            ),
          ),
        );
      }
    });

    FirebaseMessaging.onMessageOpenedApp.listen(_handleTap);
    final init = await m.getInitialMessage();
    if (init != null) _handleTap(init);
  }

  Future<void> _handleNewToken(String token) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('fcm_token', token);
    _fcmToken = token;
    _tokenRegistered = false;

    try {
      await _wvc.runJavaScript("localStorage.setItem('fcm_token','$token');");
    } catch (_) {}

    try {
      await _wvc.runJavaScript(_kReadCookieJs);
    } catch (_) {}
  }

  Future<void> _registerFcmTokenWithAuth(
      String fcmToken, String appToken) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final oldToken = prefs.getString('fcm_token_registered') ?? '';

      final response = await http.post(
        Uri.parse('$kSiteUrl/wp-json/sirdaba/v1/mobile/device-token'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $appToken',
        },
        body: jsonEncode({
          'token': fcmToken,
          'platform': 'android',
          'app_version': '1.0.0',
          if (oldToken.isNotEmpty && oldToken != fcmToken) 'old_token': oldToken,
        }),
      );

      if (response.statusCode == 200) {
        _tokenRegistered = true;
        await prefs.setString('fcm_token_registered', fcmToken);
        debugPrint('[SirDaba] FCM token registered');
      }
    } catch (e) {
      debugPrint('[SirDaba] FCM register error: $e');
    }
  }

  void _handleTap(RemoteMessage msg) {
    final url = msg.data['url'] ?? msg.data['link'];
    if (url != null) _wvc.loadRequest(Uri.parse(url));
  }

  Future<bool> _onBack() async {
    if (await _wvc.canGoBack()) {
      _wvc.goBack();
      return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: _onBack,
      child: Scaffold(
        backgroundColor: Colors.white,
        // بدون SafeArea — الـ WebView يأخذ الشاشة كاملة من فوق لتحت
        // الـ topbar في الموقع عنده padding-top خاص بالـ status bar
        body: Stack(
          children: [
            WebViewWidget(controller: _wvc),
            if (_loading)
              Container(
                color: Colors.white,
                child: const Center(
                  child: CircularProgressIndicator(
                      color: Color(0xFFE8821A), strokeWidth: 2.5),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

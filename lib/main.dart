import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Constants
// ─────────────────────────────────────────────────────────────────────────────
const String kBaseUrl         = 'https://sirdaba.delivery';
const String kDeviceTokenUrl  = '$kBaseUrl/wp-json/sirdaba/v1/mobile/device-token';
const String kMeUrl           = '$kBaseUrl/wp-json/sirdaba/v1/mobile/me';
const String kAppVersion      = '1.0.0';
const String kUserAgent       = 'SirDaba-App-Android-Agent/1.0';

// ─────────────────────────────────────────────────────────────────────────────
// تُعرَّف هنا نصوص حالات الطلب بالعربية
// ─────────────────────────────────────────────────────────────────────────────
const Map<String, String> kStatusLabels = {
  'pending':           'قيد الانتظار ⏳',
  'pending_admin':     'بانتظار موافقة الإدارة 🕐',
  'accepted':          'تم قبول طلبك ✅',
  'picked_up':         'تم استلام الطرد 📦',
  'on_the_way':        'الموزع في الطريق إليك 🚚',
  'delivered':         'تم التسليم بنجاح 🎉',
  'cancelled':         'تم إلغاء الطلب ❌',
  'returned':          'تم إرجاع الطلب 🔄',
  'dues_paid':         'تمت تسوية المستحقات 💰',
  'paying_dues':       'جارٍ تسوية المستحقات 💳',
};

String _translateStatus(String status) {
  return kStatusLabels[status] ?? status;
}

// ─────────────────────────────────────────────────────────────────────────────
// Background FCM handler – يجب أن يكون top-level function
// ─────────────────────────────────────────────────────────────────────────────
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  debugPrint('[FCM] Background message: ${message.messageId}');
  // يمكن هنا تحديث بيانات محلية إن احتجت
}

// ─────────────────────────────────────────────────────────────────────────────
// main
// ─────────────────────────────────────────────────────────────────────────────
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  await Firebase.initializeApp();
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
  runApp(const SirdabaApp());
}

// ─────────────────────────────────────────────────────────────────────────────
// App
// ─────────────────────────────────────────────────────────────────────────────
class SirdabaApp extends StatelessWidget {
  const SirdabaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SirDaba Delivery',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1F8B4C),
          primary: const Color(0xFF1F8B4C),
          secondary: const Color(0xFFF28C1B),
        ),
        scaffoldBackgroundColor: Colors.black,
        useMaterial3: true,
      ),
      home: const SirdabaWebViewPage(),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Main screen – WebView + FCM
// ─────────────────────────────────────────────────────────────────────────────
class SirdabaWebViewPage extends StatefulWidget {
  const SirdabaWebViewPage({super.key});

  @override
  State<SirdabaWebViewPage> createState() => _SirdabaWebViewPageState();
}

class _SirdabaWebViewPageState extends State<SirdabaWebViewPage>
    with WidgetsBindingObserver {
  InAppWebViewController? _controller;
  double _progress    = 0;
  bool   _isReady     = false;
  bool   _isGpsDialogVisible = false;

  String? _fcmToken;
  bool?   _isDistributor; // null = غير معروف بعد

  // ── إشعار Foreground يُعرض كـ Banner ──────────────────────────────────────
  _FcmBannerData? _activeBanner;
  Timer?          _bannerTimer;

  static const Set<String> _allowedWebSchemes = {
    'http', 'https', 'file', 'chrome', 'data', 'javascript', 'about',
  };

  // ───────────────────────────────────────────────────────────────────────────
  // Lifecycle
  // ───────────────────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_initializeAppServices());
  }

  @override
  void dispose() {
    _bannerTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _isDistributor == true) {
      unawaited(_checkGpsAvailability(showDialog: true));
    }
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Initialisation
  // ───────────────────────────────────────────────────────────────────────────

  Future<void> _initializeAppServices() async {
    await _requestStartupPermissions();
    await _configureFCM();
    if (!mounted) return;
    setState(() => _isReady = true);
  }

  Future<void> _requestStartupPermissions() async {
    await Permission.locationWhenInUse.request();
    if (Platform.isIOS) {
      await Permission.photos.request();
      await Permission.camera.request();
    } else if (Platform.isAndroid) {
      await Permission.camera.request();
      await Permission.storage.request();
      await Permission.notification.request();
    }
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Firebase Cloud Messaging — الجزء المُحدَّث والمُكتمل
  // ───────────────────────────────────────────────────────────────────────────

  Future<void> _configureFCM() async {
    try {
      final messaging = FirebaseMessaging.instance;

      // 1. طلب الإذن
      final settings = await messaging.requestPermission(
        alert:         true,
        badge:         true,
        sound:         true,
        announcement:  false,
        carPlay:       false,
        criticalAlert: false,
        provisional:   false,
      );

      debugPrint('[FCM] Permission: ${settings.authorizationStatus}');
      if (settings.authorizationStatus == AuthorizationStatus.denied) return;

      // 2. ضبط خيارات عرض iOS
      await messaging.setForegroundNotificationPresentationOptions(
        alert: true,
        badge: true,
        sound: true,
      );

      // 3. احضر التوكن وسجّله
      final token = await messaging.getToken();
      if (token != null && token.isNotEmpty) {
        _fcmToken = token;
        debugPrint('[FCM] Token: $token');
        unawaited(_registerTokenWithBackend(token));
      }

      // 4. تحديث تلقائي عند تجديد التوكن
      messaging.onTokenRefresh.listen((newToken) {
        _fcmToken = newToken;
        debugPrint('[FCM] Token refreshed: $newToken');
        unawaited(_registerTokenWithBackend(newToken));
      });

      // 5. معالجة الإشعارات حسب حالة التطبيق
      FirebaseMessaging.onMessage.listen(_handleForegroundMessage);
      FirebaseMessaging.onMessageOpenedApp.listen(_handleNotificationTap);

      // 6. التطبيق فُتح من إشعار (كان مغلقاً تماماً)
      final initial = await messaging.getInitialMessage();
      if (initial != null) {
        // تأخير بسيط حتى يكتمل بناء الـ Widget
        await Future.delayed(const Duration(milliseconds: 500));
        _handleNotificationTap(initial);
      }
    } catch (e) {
      debugPrint('[FCM] Configuration error: $e');
    }
  }

  /// تسجيل FCM Token في الـ WordPress backend
  Future<void> _registerTokenWithBackend(String token) async {
    if (token.isEmpty) return;
    try {
      final response = await http.post(
        Uri.parse(kDeviceTokenUrl),
        headers: {
          'Content-Type':  'application/json',
          'Accept':        'application/json',
          'User-Agent':    kUserAgent,
        },
        body: jsonEncode({
          'token':       token,
          'platform':    Platform.isAndroid ? 'android' : 'ios',
          'app_version': kAppVersion,
        }),
      ).timeout(const Duration(seconds: 15));
      debugPrint('[FCM] Backend response: ${response.statusCode}');
    } catch (e) {
      debugPrint('[FCM] Backend registration error: $e');
    }
  }

  /// إشعار وصل والتطبيق مفتوح في المقدمة ← يعرض Banner داخل التطبيق
  void _handleForegroundMessage(RemoteMessage message) {
    if (!mounted) return;

    final notif  = message.notification;
    final data   = message.data;

    // استخرج العنوان والنص — يدعم كلاً من notification payload و data payload
    final title  = notif?.title ?? data['title']?.toString() ?? 'SirDaba';
    String body  = notif?.body  ?? data['body']?.toString()  ?? '';

    // إذا كان إشعار حالة طلب، نُحسّن نص الجسم
    if (data['type'] == 'order_status_update') {
      final newStatus = data['new_status']?.toString() ?? '';
      final orderRef  = data['order_ref']?.toString()  ?? data['order_id']?.toString() ?? '';
      if (newStatus.isNotEmpty) {
        body = 'طلب #$orderRef → ${_translateStatus(newStatus)}';
      }
    }

    setState(() {
      _activeBanner = _FcmBannerData(title: title, body: body, data: data);
    });

    _bannerTimer?.cancel();
    _bannerTimer = Timer(const Duration(seconds: 6), () {
      if (mounted) setState(() => _activeBanner = null);
    });

    debugPrint('[FCM] Foreground: $title | $body');
  }

  /// المستخدم ضغط على الإشعار ← تنقّل داخل WebView
  void _handleNotificationTap(RemoteMessage message) {
    final data = message.data;
    debugPrint('[FCM] Tap: $data');

    // دعم launch_url المباشر
    final launchUrl = data['launch_url']?.toString();
    if (launchUrl != null && launchUrl.isNotEmpty) {
      unawaited(_navigateWebViewTo(launchUrl));
      return;
    }

    // دعم تنقل صفحة تفاصيل الطلب
    final orderId = data['order_id']?.toString();
    if (orderId != null && orderId.isNotEmpty) {
      unawaited(_navigateWebViewTo('$kBaseUrl/?sirdaba_order_id=$orderId'));
    }
  }

  /// تنقّل WebView إلى رابط معين
  Future<void> _navigateWebViewTo(String url) async {
    if (_controller == null) return;
    try {
      await _controller!.loadUrl(
        urlRequest: URLRequest(url: WebUri(url)),
      );
    } catch (e) {
      debugPrint('[WebView] Navigate error: $e');
    }
  }

  // ───────────────────────────────────────────────────────────────────────────
  // User role detection
  // ───────────────────────────────────────────────────────────────────────────

  Future<bool> _fetchIsDistributor() async {
    try {
      final response = await http.get(
        Uri.parse(kMeUrl),
        headers: {
          'Accept':     'application/json',
          'User-Agent': kUserAgent,
        },
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final body     = jsonDecode(response.body);
        final userType = body['data']?['user_type']?.toString() ?? '';
        return userType == 'distributor';
      }
    } catch (e) {
      debugPrint('[Me] Error: $e');
    }
    return false;
  }

  Future<void> _onPageLoaded(Uri? uri) async {
    // إعادة تسجيل التوكن بعد كل تحميل (يغطي حالة ما بعد الـ login)
    if (_fcmToken != null && _fcmToken!.isNotEmpty) {
      unawaited(_registerTokenWithBackend(_fcmToken!));
    }

    final isDistributor = await _fetchIsDistributor();
    if (_isDistributor != isDistributor) {
      _isDistributor = isDistributor;
      debugPrint('[Role] isDistributor = $isDistributor');
    }

    if (_isDistributor == true) {
      unawaited(_checkGpsAvailability(showDialog: true));
    }
  }

  // ───────────────────────────────────────────────────────────────────────────
  // GPS helpers
  // ───────────────────────────────────────────────────────────────────────────

  Future<bool> _checkGpsAvailability({bool showDialog = false}) async {
    try {
      final isEnabled = await Geolocator.isLocationServiceEnabled();
      if (!isEnabled && showDialog && _isDistributor == true) {
        await _showGpsDisabledDialog();
      }
      return isEnabled;
    } catch (_) {
      return true;
    }
  }

  Future<void> _showGpsDisabledDialog() async {
    if (!mounted || _isGpsDialogVisible) return;
    _isGpsDialogVisible = true;
    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => AlertDialog(
        title: const Text('GPS غير مفعّل'),
        content: const Text(
          'يرجى تفعيل الـ GPS لمشاركة موقعك مع العملاء واستخدام خرائط التوصيل.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('لاحقاً'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.of(ctx).pop();
              await Geolocator.openLocationSettings();
            },
            child: const Text('تفعيل GPS'),
          ),
        ],
      ),
    );
    _isGpsDialogVisible = false;
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Navigation helpers
  // ───────────────────────────────────────────────────────────────────────────

  Future<bool> _openOutsideWebView(String rawUrl) async {
    final uri = Uri.tryParse(rawUrl);
    if (uri == null) return false;

    if (_isLikelyGoogleMapsLink(rawUrl, uri)) {
      final gpsEnabled = await Geolocator.isLocationServiceEnabled();
      if (!gpsEnabled) {
        if (_isDistributor == true) await _showGpsDisabledDialog();
        return false;
      }
      return _openGoogleMaps(rawUrl);
    }

    Uri targetUri = uri;
    if (uri.scheme == 'intent') targetUri = _extractUriFromIntent(rawUrl) ?? uri;

    final launched = await _tryLaunch(targetUri);
    if (launched) return true;

    if (uri.scheme == 'intent') {
      final fallback = _extractBrowserFallbackUri(rawUrl);
      if (fallback != null) return _tryLaunch(fallback);
    }
    return false;
  }

  bool _isLikelyGoogleMapsLink(String rawUrl, Uri uri) {
    final n = rawUrl.toLowerCase();
    final h = uri.host.toLowerCase();
    final p = uri.path.toLowerCase();
    if ({'geo', 'google.navigation', 'comgooglemaps'}.contains(uri.scheme)) return true;
    if (n.startsWith('intent://') && n.contains('google.com/maps')) return true;
    if (h.contains('maps.app.goo.gl')) return true;
    if (h.contains('google.') && p.startsWith('/maps')) return true;
    return false;
  }

  Uri? _extractUriFromIntent(String rawUrl) {
    if (!rawUrl.toLowerCase().startsWith('intent://')) return Uri.tryParse(rawUrl);
    final sep  = rawUrl.indexOf('#Intent;');
    final body = (sep == -1 ? rawUrl : rawUrl.substring(0, sep)).substring('intent://'.length);
    final scheme = _parseIntentMetadata(rawUrl)['scheme'] ?? 'https';
    return Uri.tryParse('$scheme://$body');
  }

  Uri? _extractBrowserFallbackUri(String rawUrl) {
    final fallback = _parseIntentMetadata(rawUrl)['S.browser_fallback_url'];
    if (fallback == null || fallback.isEmpty) return null;
    return Uri.tryParse(Uri.decodeComponent(fallback));
  }

  Map<String, String> _parseIntentMetadata(String rawUrl) {
    final sep = rawUrl.indexOf('#Intent;');
    if (sep == -1) return const {};
    final meta = <String, String>{};
    for (final e in rawUrl.substring(sep + 8).split(';')) {
      if (e.isEmpty || e == 'end') continue;
      final eq = e.indexOf('=');
      if (eq <= 0) continue;
      meta[e.substring(0, eq)] = e.substring(eq + 1);
    }
    return meta;
  }

  Future<bool> _openGoogleMaps(String rawUrl) async {
    final incomingUri = _extractUriFromIntent(rawUrl) ?? Uri.tryParse(rawUrl);
    if (incomingUri == null) return false;

    final params = incomingUri.queryParameters;
    final dest   = params['destination'] ?? params['daddr'] ?? params['q'];
    final origin = params['origin'] ?? params['saddr'];
    final mode   = _mapTravelMode(params['travelmode'] ?? params['directionsmode']);

    if (Platform.isAndroid && dest != null && dest.isNotEmpty) {
      final navUri = Uri.parse(
        'google.navigation:q=${Uri.encodeComponent(dest)}${mode == null ? '' : '&mode=$mode'}',
      );
      if (await _tryLaunch(navUri)) return true;
    }

    if (Platform.isIOS && dest != null && dest.isNotEmpty) {
      final q = <String, String>{'daddr': dest};
      if (origin != null && origin.isNotEmpty) q['saddr'] = origin;
      final dm = _mapIosTravelMode(params['travelmode'] ?? params['directionsmode']);
      if (dm != null) q['directionsmode'] = dm;
      if (await _tryLaunch(Uri.parse('comgooglemaps://?${Uri(queryParameters: q).query}'))) return true;
    }

    final fallback = _extractBrowserFallbackUri(rawUrl);
    if (fallback != null && await _tryLaunch(fallback)) return true;
    return _tryLaunch(incomingUri);
  }

  String? _mapTravelMode(String? m) {
    switch (m?.toLowerCase()) {
      case 'driving':   return 'd';
      case 'walking':   return 'w';
      case 'bicycling': return 'b';
      default:          return null;
    }
  }

  String? _mapIosTravelMode(String? m) {
    switch (m?.toLowerCase()) {
      case 'driving': case 'walking': case 'transit': case 'bicycling':
        return m!.toLowerCase();
      default: return null;
    }
  }

  Future<bool> _tryLaunch(Uri uri) async {
    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }

  Future<void> _handleDownload(Uri uri) async {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('تم إرسال الملف لتطبيق التنزيل.')),
    );
  }

  Future<void> _showPermissionNotice(String msg) async {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<bool> _handleNavigationInterception(String rawUrl) async {
    final uri = Uri.tryParse(rawUrl);
    if (uri == null) return false;

    if (_isLikelyGoogleMapsLink(rawUrl, uri)) {
      final gpsEnabled = await Geolocator.isLocationServiceEnabled();
      if (!gpsEnabled) {
        if (_isDistributor == true) await _showGpsDisabledDialog();
        return true;
      }
      final launched = await _openGoogleMaps(rawUrl);
      if (!launched && mounted) await _showPermissionNotice('تعذر فتح Google Maps.');
      return launched || (uri.scheme != 'http' && uri.scheme != 'https');
    }

    if (!_allowedWebSchemes.contains(uri.scheme)) {
      final launched = await _openOutsideWebView(rawUrl);
      if (!launched && mounted) await _showPermissionNotice('تعذر فتح الرابط الخارجي.');
      return true;
    }

    return false;
  }

  Future<bool> _onWillPop() async {
    if (_controller != null && await _controller!.canGoBack()) {
      await _controller!.goBack();
      return false;
    }
    return true;
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Build
  // ───────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: _onWillPop,
      child: Scaffold(
        body: SafeArea(
          child: Stack(
            children: [
              // ── WebView + progress bar ──────────────────────────────────
              Column(
                children: [
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    child: _progress < 1
                        ? LinearProgressIndicator(
                            key: const ValueKey('progress'),
                            value: _progress == 0 ? null : _progress,
                            minHeight: 3,
                            backgroundColor: Colors.white10,
                            valueColor: const AlwaysStoppedAnimation<Color>(
                              Color(0xFFF28C1B),
                            ),
                          )
                        : const SizedBox(
                            key: ValueKey('progress-hidden'),
                            height: 3,
                          ),
                  ),
                  Expanded(
                    child: InAppWebView(
                      initialUrlRequest: URLRequest(url: WebUri(kBaseUrl)),
                      initialSettings: InAppWebViewSettings(
                        javaScriptEnabled: true,
                        javaScriptCanOpenWindowsAutomatically: true,
                        domStorageEnabled: true,
                        databaseEnabled: true,
                        allowFileAccess: true,
                        allowContentAccess: true,
                        geolocationEnabled: true,
                        mediaPlaybackRequiresUserGesture: false,
                        allowsInlineMediaPlayback: true,
                        transparentBackground: false,
                        supportZoom: false,
                        useShouldOverrideUrlLoading: true,
                        useOnDownloadStart: true,
                        userAgent: kUserAgent,
                      ),
                      onWebViewCreated:  (c) => _controller = c,
                      onProgressChanged: (_, p) {
                        if (!mounted) return;
                        setState(() => _progress = p / 100);
                      },
                      onLoadStart: (_, __) {
                        if (!mounted) return;
                        setState(() => _progress = 0);
                      },
                      onLoadStop: (_, uri) {
                        if (!mounted) return;
                        setState(() => _progress = 1);
                        unawaited(_onPageLoaded(uri));
                      },
                      onCreateWindow: (controller, action) async {
                        final raw = action.request.url?.toString();
                        if (raw != null && await _handleNavigationInterception(raw)) return false;
                        if (action.request.url != null) {
                          await controller.loadUrl(urlRequest: action.request);
                        }
                        return true;
                      },
                      shouldOverrideUrlLoading: (_, nav) async {
                        final raw = nav.request.url?.toString() ?? '';
                        if (raw.isEmpty) return NavigationActionPolicy.ALLOW;
                        if (await _handleNavigationInterception(raw)) {
                          return NavigationActionPolicy.CANCEL;
                        }
                        return NavigationActionPolicy.ALLOW;
                      },
                      onPermissionRequest: (_, req) async => PermissionResponse(
                        action: PermissionResponseAction.GRANT,
                        resources: req.resources,
                      ),
                      onGeolocationPermissionsShowPrompt: (_, origin) async {
                        if (_isDistributor != true) {
                          return GeolocationPermissionShowPromptResponse(
                            origin: origin, allow: false, retain: false,
                          );
                        }
                        final gpsEnabled = await Geolocator.isLocationServiceEnabled();
                        if (!gpsEnabled) {
                          await _showGpsDisabledDialog();
                          return GeolocationPermissionShowPromptResponse(
                            origin: origin, allow: false, retain: false,
                          );
                        }
                        final status  = await Permission.locationWhenInUse.request();
                        final allowed = status.isGranted || status.isLimited;
                        if (!allowed) {
                          await _showPermissionNotice(
                            'يرجى السماح بالموقع لتفعيل خرائط التوصيل.',
                          );
                        }
                        return GeolocationPermissionShowPromptResponse(
                          origin: origin, allow: allowed, retain: true,
                        );
                      },
                      onDownloadStartRequest: (_, req) async {
                        final uri = Uri.tryParse(req.url.toString());
                        if (uri != null) await _handleDownload(uri);
                      },
                      onReceivedError: (_, req, err) async {
                        if (req.isForMainFrame == true) {
                          await _showPermissionNotice(
                            'تعذر تحميل الصفحة: ${err.description}',
                          );
                        }
                      },
                    ),
                  ),
                ],
              ),

              // ── Splash أثناء التهيئة ───────────────────────────────────
              if (!_isReady)
                const Positioned.fill(
                  child: ColoredBox(
                    color: Colors.black,
                    child: Center(
                      child: CircularProgressIndicator(
                        color: Color(0xFFF28C1B),
                      ),
                    ),
                  ),
                ),

              // ── FCM Foreground Banner ──────────────────────────────────
              if (_activeBanner != null)
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: _FcmBanner(
                    data: _activeBanner!,
                    onTap: () {
                      _handleNotificationTap(
                        RemoteMessage(data: _activeBanner!.data),
                      );
                      setState(() => _activeBanner = null);
                    },
                    onDismiss: () => setState(() => _activeBanner = null),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// FCM Banner widget — يظهر عند وصول إشعار والتطبيق مفتوح
// ─────────────────────────────────────────────────────────────────────────────

class _FcmBannerData {
  final String              title;
  final String              body;
  final Map<String, dynamic> data;
  const _FcmBannerData({required this.title, required this.body, required this.data});
}

class _FcmBanner extends StatelessWidget {
  const _FcmBanner({
    required this.data,
    required this.onTap,
    required this.onDismiss,
  });

  final _FcmBannerData data;
  final VoidCallback   onTap;
  final VoidCallback   onDismiss;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.all(10),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: const Color(0xFF1F8B4C),
            borderRadius: BorderRadius.circular(14),
            boxShadow: const [
              BoxShadow(color: Colors.black26, blurRadius: 8, offset: Offset(0, 3)),
            ],
          ),
          child: Row(
            children: [
              const Icon(Icons.notifications, color: Colors.white, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      data.title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (data.body.isNotEmpty)
                      Text(
                        data.body,
                        style: const TextStyle(color: Colors.white70, fontSize: 12),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, color: Colors.white70, size: 18),
                onPressed: onDismiss,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

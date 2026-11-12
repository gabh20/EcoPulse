import 'dart:async';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'screens/login_screen.dart';
import 'screens/map_screen.dart';
import 'services/app_state.dart';
import 'services/local_store.dart';

@pragma('vm:entry-point')
Future<void> backgroundMessage(RemoteMessage message) async {
  await Firebase.initializeApp();
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  var firebaseReady = false;
  if (const bool.fromEnvironment('FIREBASE_ENABLED')) {
    try {
      await Firebase.initializeApp();
      FirebaseMessaging.onBackgroundMessage(backgroundMessage);
      firebaseReady = true;
    } catch (error) {
      debugPrint('Firebase não inicializado: $error');
    }
  }
  final store = await LocalStore.open();
  final state = AppState(
    store,
    firebaseReady,
    const String.fromEnvironment(
      'API_URL',
      defaultValue: 'http://10.0.2.2:8000',
    ),
  );
  runApp(EcoPulseApp(state: state));
  unawaited(state.initialize());
}

class EcoPulseApp extends StatefulWidget {
  final AppState state;
  const EcoPulseApp({super.key, required this.state});
  @override
  State<EcoPulseApp> createState() => _EcoPulseAppState();
}

class _EcoPulseAppState extends State<EcoPulseApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && widget.state.loggedIn) {
      widget.state.refresh();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.state.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'EcoPulse',
    debugShowCheckedModeBanner: false,
    locale: const Locale('pt', 'BR'),
    supportedLocales: const [Locale('pt', 'BR')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF176B4A)),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
      ),
    ),
    home: ListenableBuilder(
      listenable: widget.state,
      builder: (context, _) => widget.state.initializing
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : widget.state.loggedIn
          ? MapScreen(state: widget.state)
          : LoginScreen(state: widget.state),
    ),
  );
}

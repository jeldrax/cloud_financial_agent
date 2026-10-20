import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

import 'modules/auth/views/biometric_lock_view.dart';
import 'modules/dashboard/views/main_dashboard_view.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // Estilo de barra de estado transparente sincronizado con el fondo #1F2E4D
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: AppColors.background,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );

  runApp(const CloudFinancialAgentApp());
}

/// Paleta de colores oficial inspirada en MonAi / Starfield.
abstract final class AppColors {
  /// Fondo principal oscuro profundo (#1F2E4D).
  static const Color background = Color(0xFF1F2E4D);

  /// Superficie elevada para tarjetas grandes y NavigationRail.
  static const Color surface = Color(0xFF283B60);

  /// Superficie secundaria más oscura para contenedores internos y barras.
  static const Color surfaceDark = Color(0xFF16223A);

  /// Acento primario naranja/ámbar (#E5A84B) - Destaca 50% Necesidades y acciones principales.
  static const Color accentOrange = Color(0xFFE5A84B);

  /// Acento secundario rojo carmesí (#D34037) - Destaca 30% Gustos, alertas y grabación activa.
  static const Color accentRed = Color(0xFFD34037);

  /// Acento complementario para el 20% Ahorro e inversiones.
  static const Color accentTeal = Color(0xFF48C9B0);

  /// Texto primario y secundario.
  static const Color textPrimary = Color(0xFFF4F7FB);
  static const Color textSecondary = Color(0xFFA3B3CC);

  /// Borde sutil estilo técnico Starfield.
  static const Color cardBorder = Color(0xFF364D7A);
}

/// Tema global minimalista de la aplicación.
abstract final class AppTheme {
  static ThemeData get darkTheme {
    const colorScheme = ColorScheme.dark(
      primary: AppColors.accentOrange,
      onPrimary: AppColors.surfaceDark,
      secondary: AppColors.accentRed,
      onSecondary: AppColors.textPrimary,
      tertiary: AppColors.accentTeal,
      surface: AppColors.surface,
      onSurface: AppColors.textPrimary,
      error: AppColors.accentRed,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: AppColors.background,
      colorScheme: colorScheme,
      cardTheme: CardThemeData(
        color: AppColors.surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: const BorderSide(color: AppColors.cardBorder, width: 1),
        ),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.background,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: AppColors.textPrimary,
          fontSize: 20,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
        ),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: AppColors.surfaceDark,
        selectedItemColor: AppColors.accentOrange,
        unselectedItemColor: AppColors.textSecondary,
        type: BottomNavigationBarType.fixed,
        elevation: 0,
        selectedLabelStyle: TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
        unselectedLabelStyle: TextStyle(fontSize: 12),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: AppColors.surfaceDark,
        selectedIconTheme: const IconThemeData(color: AppColors.accentOrange, size: 26),
        unselectedIconTheme: const IconThemeData(color: AppColors.textSecondary, size: 24),
        selectedLabelTextStyle: const TextStyle(
          color: AppColors.accentOrange,
          fontWeight: FontWeight.w700,
          fontSize: 13,
        ),
        unselectedLabelTextStyle: const TextStyle(
          color: AppColors.textSecondary,
          fontSize: 13,
        ),
        indicatorColor: AppColors.accentOrange.withValues(alpha: 0.16),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.surfaceDark,
        hintStyle: const TextStyle(color: AppColors.textSecondary),
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(20),
          borderSide: const BorderSide(color: AppColors.cardBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(20),
          borderSide: const BorderSide(color: AppColors.cardBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(20),
          borderSide: const BorderSide(color: AppColors.accentOrange, width: 1.8),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.accentOrange,
          foregroundColor: AppColors.surfaceDark,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
          textStyle: const TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 15,
            letterSpacing: 0.3,
          ),
        ),
      ),
    );
  }
}

/// Widget raíz con Seguridad Local Continua mediante [WidgetsBindingObserver] y [LocalAuthentication].
class CloudFinancialAgentApp extends StatefulWidget {
  const CloudFinancialAgentApp({super.key});

  @override
  State<CloudFinancialAgentApp> createState() => _CloudFinancialAgentAppState();
}

class _CloudFinancialAgentAppState extends State<CloudFinancialAgentApp>
    with WidgetsBindingObserver {
  final LocalAuthentication _localAuth = LocalAuthentication();

  /// Indica si la interfaz financiera se encuentra bloqueada esperando biometría/PIN.
  bool _isLocked = true;

  /// Evita disparar múltiples diálogos biométricos en bucle cuando el diálogo del SO
  /// devuelve el foco a la aplicación (`resumed`).
  bool _isAuthenticating = false;

  /// Registra si la app realmente pasó a segundo plano antes de volver a `resumed`.
  bool _wentToBackground = false;

  /// Mensaje de estado o error en la pantalla de bloqueo.
  String? _authErrorMessage;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _authenticateUser();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Monitorea el ciclo de vida de la app para exigir biometría al volver de segundo plano.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    if (_isAuthenticating) return;

    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _wentToBackground = true;
      if (!_isLocked) {
        setState(() {
          _isLocked = true;
          _authErrorMessage = null;
        });
      }
    } else if (state == AppLifecycleState.resumed && _wentToBackground) {
      _wentToBackground = false;
      setState(() {
        _isLocked = true;
      });
      _authenticateUser();
    }
  }

  /// Ejecuta la validación biométrica o de credencial del sistema (huella, rostro o PIN/contraseña).
  Future<void> _authenticateUser() async {
    if (_isAuthenticating) return;

    setState(() {
      _isAuthenticating = true;
      _authErrorMessage = null;
    });

    try {
      final bool isDeviceSupported = await _localAuth.isDeviceSupported();
      final bool canCheckBiometrics = await _localAuth.canCheckBiometrics;

      if (!isDeviceSupported && !canCheckBiometrics) {
        if (!mounted) return;
        setState(() {
          _isLocked = false;
        });
        return;
      }

      final bool authenticated = await _localAuth.authenticate(
        localizedReason:
            'Verifica tu identidad para acceder a tu balance 50/30/20 y registrar transacciones.',
        options: const AuthenticationOptions(
          stickyAuth: true,
          biometricOnly: false,
          useErrorDialogs: true,
        ),
      );

      if (!mounted) return;

      setState(() {
        _isLocked = !authenticated;
        if (!authenticated) {
          _authErrorMessage =
              'Autenticación cancelada o fallida. Intenta nuevamente.';
        }
      });
    } on MissingPluginException {
      // En escritorio Linux (CachyOS KDE Plasma) local_auth no registra canal nativo;
      // se permite el desbloqueo explícito bajo la sesión activa del sistema.
      if (!mounted) return;
      setState(() {
        _isLocked = false;
      });
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() {
        _isLocked = true;
        _authErrorMessage =
            'Error del sistema de seguridad (${e.code}). Reintenta para desbloquear.';
      });
    } finally {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      if (mounted) {
        setState(() {
          _isAuthenticating = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Cloud Financial Agent',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: AppTheme.darkTheme,
      home: const MainDashboardView(),
      builder: (context, child) {
        return Stack(
          children: [
            if (child != null) child,
            if (_isLocked)
              Positioned.fill(
                child: BiometricLockView(
                  isAuthenticating: _isAuthenticating,
                  errorMessage: _authErrorMessage,
                  onRetryAuth: _authenticateUser,
                ),
              ),
          ],
        );
      },
    );
  }
}

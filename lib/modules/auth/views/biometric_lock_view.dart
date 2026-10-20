import 'package:flutter/material.dart';

import '../../../main.dart';

/// Vista del módulo `auth`:
/// Escudo de bloqueo biométrico y splash de seguridad que protege los datos financieros
/// cuando la aplicación inicia o regresa de segundo plano (`AppLifecycleState.resumed`).
class BiometricLockView extends StatelessWidget {
  final bool isAuthenticating;
  final String? errorMessage;
  final VoidCallback onRetryAuth;

  const BiometricLockView({
    super.key,
    required this.isAuthenticating,
    required this.errorMessage,
    required this.onRetryAuth,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.background,
      child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(28.0),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 28.0,
                    vertical: 36.0,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 80,
                        height: 80,
                        decoration: BoxDecoration(
                          color: AppColors.accentOrange.withValues(alpha: 0.14),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: AppColors.accentOrange,
                            width: 1.5,
                          ),
                        ),
                        child: const Icon(
                          Icons.fingerprint_rounded,
                          size: 44,
                          color: AppColors.accentOrange,
                        ),
                      ),
                      const SizedBox(height: 24),
                      const Text(
                        'Bóveda Financiera Protegida',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 10),
                      const Text(
                        'Cloud Financial Agent requiere verificación biométrica o contraseña del sistema antes de mostrar tu presupuesto 50/30/20.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 14,
                          height: 1.45,
                          color: AppColors.textSecondary,
                        ),
                      ),
                      if (errorMessage != null) ...[
                        const SizedBox(height: 20),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: AppColors.accentRed.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: AppColors.accentRed.withValues(alpha: 0.6),
                            ),
                          ),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.gpp_maybe_rounded,
                                color: AppColors.accentRed,
                                size: 20,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  errorMessage!,
                                  style: const TextStyle(
                                    color: AppColors.textPrimary,
                                    fontSize: 12.5,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(height: 28),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: isAuthenticating ? null : onRetryAuth,
                          icon: isAuthenticating
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.2,
                                    color: AppColors.surfaceDark,
                                  ),
                                )
                              : const Icon(Icons.lock_open_rounded),
                          label: Text(
                            isAuthenticating
                                ? 'Verificando identidad...'
                                : 'Desbloquear con Biometría',
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

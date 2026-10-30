import 'package:flutter/material.dart';

import '../../../core/network/api_client.dart';
import '../../../main.dart';

/// Vista del módulo `settings`:
/// - Diagnóstico en vivo de la red privada Tailscale hacia FastAPI (`ApiClient.checkTailscaleHealth`).
/// - Configuración persistente en SQLite del presupuesto base mensual para la regla 50/30/20.
/// - Resumen de controles activos de seguridad en tránsito y blindaje contra explotación de IA.
class SettingsView extends StatefulWidget {
  final double monthlyIncome;
  final ValueChanged<double> onMonthlyIncomeChanged;

  const SettingsView({
    super.key,
    required this.monthlyIncome,
    required this.onMonthlyIncomeChanged,
  });

  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> {
  final ApiClient _apiClient = ApiClient();
  late final TextEditingController _incomeController = TextEditingController(
    text: widget.monthlyIncome.toStringAsFixed(0),
  );

  bool _isCheckingHealth = false;
  bool _isSavingBudget = false;
  TailscaleHealthStatus? _healthStatus;

  @override
  void didUpdateWidget(covariant SettingsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.monthlyIncome != widget.monthlyIncome && !_isSavingBudget) {
      _incomeController.text = widget.monthlyIncome.toStringAsFixed(0);
    }
  }

  @override
  void dispose() {
    _incomeController.dispose();
    super.dispose();
  }

  Future<void> _runTailscaleDiagnostics() async {
    setState(() => _isCheckingHealth = true);
    final status = await _apiClient.checkTailscaleHealth();
    if (!mounted) return;
    setState(() {
      _healthStatus = status;
      _isCheckingHealth = false;
    });
  }

  Future<void> _saveMonthlyBudget() async {
    final double? parsed =
        double.tryParse(_incomeController.text.trim().replaceAll(',', '.'));
    if (parsed == null || parsed <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: AppColors.accentRed,
          content: Text('Ingresa un monto mensual válido mayor a 0.'),
        ),
      );
      return;
    }

    setState(() => _isSavingBudget = true);
    try {
      final double saved = await _apiClient.updateMonthlyBudget(parsed);
      if (!mounted) return;
      widget.onMonthlyIncomeChanged(saved);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: AppColors.surface,
          content: Text(
            'Presupuesto 50/30/20 guardado en el servidor: \$${saved.toStringAsFixed(2)} MXN',
          ),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: AppColors.accentRed,
          content: Text(
            'No se pudo guardar el presupuesto en el servidor. Verifica Tailscale.',
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isSavingBudget = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24.0),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 920),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Seguridad Zero-Trust y Presupuesto',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                'Administración del túnel cifrado Tailscale, presupuesto base 50/30/20 y protecciones contra explotación de IA.',
                style: TextStyle(
                  fontSize: 13.5,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 24),

              // 1. Diagnóstico del Túnel Tailscale y Backend FastAPI
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(24.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        alignment: WrapAlignment.spaceBetween,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.lan_rounded,
                                color: AppColors.accentOrange,
                              ),
                              SizedBox(width: 10),
                              Text(
                                'Conectividad Privada Tailscale (Zero-Trust)',
                                style: TextStyle(
                                  fontSize: 16.5,
                                  fontWeight: FontWeight.w800,
                                  color: AppColors.textPrimary,
                                ),
                              ),
                            ],
                          ),
                          ElevatedButton.icon(
                            onPressed: _isCheckingHealth
                                ? null
                                : _runTailscaleDiagnostics,
                            icon: _isCheckingHealth
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: AppColors.surfaceDark,
                                    ),
                                  )
                                : const Icon(Icons.network_check_rounded),
                            label: Text(
                              _isCheckingHealth
                                  ? 'Verificando...'
                                  : 'Probar Latencia',
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      const Text(
                        'Toda transmisión de datos viaja exclusivamente sobre la red cifrada WireGuard de Tailscale utilizando credenciales ofuscadas en binario (`Env.apiUrl` y `Env.apiToken`).',
                        style: TextStyle(
                          fontSize: 13,
                          color: AppColors.textSecondary,
                          height: 1.45,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: AppColors.surfaceDark,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: AppColors.cardBorder),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              '• Endpoint Remoto: Env.apiUrl (Ofuscación Binaria Activa)',
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 12.5,
                                color: AppColors.accentOrange,
                              ),
                            ),
                            const SizedBox(height: 6),
                            const Text(
                              '• Autenticación: Bearer <Env.apiToken> (Comparación en Tiempo Constante)',
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 12.5,
                                color: AppColors.accentTeal,
                              ),
                            ),
                            if (_healthStatus != null) ...[
                              const Divider(
                                height: 24,
                                color: AppColors.cardBorder,
                              ),
                              Row(
                                children: [
                                  Icon(
                                    _healthStatus!.isOnline
                                        ? Icons.check_circle_rounded
                                        : Icons.warning_amber_rounded,
                                    size: 18,
                                    color: _healthStatus!.isOnline
                                        ? AppColors.accentTeal
                                        : AppColors.accentRed,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      _healthStatus!.statusMessage,
                                      style: const TextStyle(
                                        fontSize: 12.5,
                                        color: AppColors.textPrimary,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),

              // 2. Ajuste del Presupuesto Base Mensual (Persistido en SQLite)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(24.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          Icon(
                            Icons.pie_chart_rounded,
                            color: AppColors.accentOrange,
                          ),
                          SizedBox(width: 10),
                          Text(
                            'Presupuesto Mensual Base (Regla 50/30/20)',
                            style: TextStyle(
                              fontSize: 16.5,
                              fontWeight: FontWeight.w800,
                              color: AppColors.textPrimary,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'Define tu presupuesto mensual base en SQLite para calcular tus topes de 50% Necesidades, 30% Gustos y 20% Ahorro en todos tus dispositivos.',
                        style: TextStyle(
                          fontSize: 13,
                          color: AppColors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _incomeController,
                              onSubmitted: (_) => _saveMonthlyBudget(),
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                decimal: true,
                              ),
                              decoration: const InputDecoration(
                                labelText: 'Presupuesto Mensual Total (MXN)',
                                prefixIcon: Icon(
                                  Icons.attach_money_rounded,
                                  color: AppColors.accentOrange,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 14),
                          ElevatedButton(
                            onPressed:
                                _isSavingBudget ? null : _saveMonthlyBudget,
                            child: Text(
                              _isSavingBudget
                                  ? 'Guardando...'
                                  : 'Guardar Topes',
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),

              // 3. Blindaje de Privacidad y Seguridad de IA
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(24.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: const [
                      Row(
                        children: [
                          Icon(
                            Icons.verified_user_rounded,
                            color: AppColors.accentTeal,
                          ),
                          SizedBox(width: 10),
                          Text(
                            'Arquitectura Aislada y Anti-Explotación de IA',
                            style: TextStyle(
                              fontSize: 16.5,
                              fontWeight: FontWeight.w800,
                              color: AppColors.textPrimary,
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: 14),
                      _SecurityFeatureRow(
                        title: 'Cero Conexiones Bancarias Externas',
                        subtitle:
                            'Sin acceso IMAP a correos ni lectura de notificaciones. Solo existen los ingresos y egresos que tú agregas.',
                      ),
                      SizedBox(height: 10),
                      _SecurityFeatureRow(
                        title: 'Defensa Anti-Prompt Injection y Sandbox XML',
                        subtitle:
                            'Saneamiento de etiquetas XML, detección previa de patrones de jailbreak, temperatura 0.0 y esquema JSON estricto.',
                      ),
                      SizedBox(height: 10),
                      _SecurityFeatureRow(
                        title: 'Protección de Transmisión y Cuota',
                        subtitle:
                            'Cabeceras HTTP sin caché, esquema OpenAPI oculto, límite de tamaño de audio (5 MB) y Rate Limiting activo.',
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SecurityFeatureRow extends StatelessWidget {
  final String title;
  final String subtitle;

  const _SecurityFeatureRow({
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 2.0),
          child: Icon(
            Icons.check_circle_outline_rounded,
            size: 18,
            color: AppColors.accentTeal,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: const TextStyle(
                  fontSize: 12.5,
                  color: AppColors.textSecondary,
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

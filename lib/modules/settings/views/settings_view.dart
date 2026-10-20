import 'package:flutter/material.dart';

import '../../../core/network/api_client.dart';
import '../../../main.dart';
import '../../transactions/services/bank_notification_webhook_service.dart';

/// Vista del módulo `settings`:
/// - Diagnóstico en vivo de la red privada Tailscale hacia FastAPI en TrueNAS (`ApiClient.checkTailscaleHealth`).
/// - Configuración del presupuesto base mensual para el cálculo automático del 50/30/20.
/// - Gestión de paquetes bancarios autorizados en Android (S23 Ultra) para el Scraping de notificaciones.
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
  TailscaleHealthStatus? _healthStatus;

  bool _isCheckingImap = false;
  Map<String, dynamic>? _imapDiagnostics;

  final Map<String, bool> _enabledBankPackages = {
    for (final entry in SupportedBankingApps.allowedPackages.entries)
      entry.key: true,
  };

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

  Future<void> _runImapDiagnostics() async {
    setState(() => _isCheckingImap = true);
    try {
      final result = await _apiClient.fetchGmailImapDiagnostics();
      if (!mounted) return;
      setState(() {
        _imapDiagnostics = result;
        _isCheckingImap = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _imapDiagnostics = {
          'conectado': false,
          'mensaje': 'No se pudo consultar el diagnóstico IMAP: $e',
          'muestra_recientes': <dynamic>[],
        };
        _isCheckingImap = false;
      });
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
                'Configuración de Red Local y Presupuesto',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                'Administración del nodo privado Tailscale, variables ofuscadas Zero-Trust y demonios de intercepción bancaria.',
                style: TextStyle(
                  fontSize: 13.5,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 24),

              // 1. Diagnóstico del Túnel Tailscale y Backend TrueNAS
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(24.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Row(
                            children: [
                              Icon(
                                Icons.lan_rounded,
                                color: AppColors.accentOrange,
                              ),
                              SizedBox(width: 10),
                              Text(
                                'Conectividad Malla Tailscale (TrueNAS FastAPI)',
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
                        'Las peticiones HTTP y Webhooks utilizan exclusivamente `Env.apiUrl` y `Env.apiToken` ofuscados mediante `envied` en tiempo de compilación. No existen puertos expuestos a Internet.',
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
                              '• Base URL: Env.apiUrl (Ofuscación Binaria Activa)',
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 12.5,
                                color: AppColors.accentOrange,
                              ),
                            ),
                            const SizedBox(height: 6),
                            const Text(
                              '• Auth Header: Bearer <Env.apiToken> (Ofuscación Binaria Activa)',
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

              // 2. Diagnóstico en Vivo de Gmail IMAP y Cuentas Bancarias (Banca_Agente)
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
                                Icons.mark_email_read_rounded,
                                color: AppColors.accentOrange,
                              ),
                              SizedBox(width: 10),
                              Text(
                                'Conexión Gmail IMAP y Cuentas (Banca_Agente)',
                                style: TextStyle(
                                  fontSize: 16.5,
                                  fontWeight: FontWeight.w800,
                                  color: AppColors.textPrimary,
                                ),
                              ),
                            ],
                          ),
                          ElevatedButton.icon(
                            onPressed:
                                _isCheckingImap ? null : _runImapDiagnostics,
                            icon: _isCheckingImap
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: AppColors.surfaceDark,
                                    ),
                                  )
                                : const Icon(Icons.fact_check_rounded),
                            label: Text(
                              _isCheckingImap
                                  ? 'Consultando Gmail...'
                                  : 'Probar Gmail IMAP',
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'Verifica en modo solo lectura que el contenedor en TrueNAS pueda iniciar sesión en Gmail IMAP (`imap.gmail.com:993`), abrir la etiqueta `Banca_Agente` y filtrar alertas de Banorte, Nu y Mercado Pago.',
                        style: TextStyle(
                          fontSize: 13,
                          color: AppColors.textSecondary,
                          height: 1.45,
                        ),
                      ),
                      if (_imapDiagnostics != null) ...[
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
                              Row(
                                children: [
                                  Icon(
                                    (_imapDiagnostics!['conectado'] == true)
                                        ? Icons.verified_rounded
                                        : Icons.error_outline_rounded,
                                    color:
                                        (_imapDiagnostics!['conectado'] == true)
                                            ? AppColors.accentTeal
                                            : AppColors.accentRed,
                                    size: 20,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      (_imapDiagnostics!['mensaje'] ?? '')
                                          .toString(),
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                        color: AppColors.textPrimary,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              if (_imapDiagnostics!['conectado'] == true) ...[
                                const SizedBox(height: 8),
                                Text(
                                  'Cuenta: ${_imapDiagnostics!['usuario']} • Carpeta: ${_imapDiagnostics!['carpeta']} • Total: ${_imapDiagnostics!['total_en_carpeta']} correos (${_imapDiagnostics!['no_leidos']} no leídos)',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: AppColors.accentOrange,
                                    fontFamily: 'monospace',
                                  ),
                                ),
                                const Divider(
                                  height: 22,
                                  color: AppColors.cardBorder,
                                ),
                                const Text(
                                  'ÚLTIMOS CORREOS EN LA ETIQUETA:',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 1.0,
                                    color: AppColors.textSecondary,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                for (final item in (_imapDiagnostics![
                                            'muestra_recientes']
                                        as List<dynamic>? ??
                                    const []))
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 8.0),
                                    child: Text(
                                      '• [${item['fecha']}] ${item['asunto']} -> ${item['estado']}',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: (item['en_sqlite'] == true)
                                            ? AppColors.accentTeal
                                            : ((item['es_candidato'] == true)
                                                ? AppColors.textPrimary
                                                : AppColors.textSecondary),
                                      ),
                                    ),
                                  ),
                                if (((_imapDiagnostics![
                                            'registradas_desde_gmail']
                                        as List<dynamic>?) ??
                                    const [])
                                    .isNotEmpty) ...[
                                  const Divider(
                                    height: 22,
                                    color: AppColors.cardBorder,
                                  ),
                                  const Text(
                                    'TRANSACCIONES REALES EXTRAÍDAS DE GMAIL EN SQLITE:',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: 1.0,
                                      color: AppColors.accentTeal,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  for (final tx in (_imapDiagnostics![
                                          'registradas_desde_gmail']
                                      as List<dynamic>))
                                    Padding(
                                      padding:
                                          const EdgeInsets.only(bottom: 6.0),
                                      child: Text(
                                        '✓ [${tx['fecha']}] ${tx['concepto']} (\$${tx['monto']} MXN) -> ${tx['categoria']} (${tx['metodo_pago']})',
                                        style: const TextStyle(
                                          fontSize: 12,
                                          color: AppColors.textPrimary,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                ],
                              ],
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),

              // 2. Ajuste del Ingreso Base Mensual para la Regla 50/30/20
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
                        'Define tu ingreso neto mensual para recalcular automáticamente los topes de 50% Necesidades, 30% Gustos y 20% Ahorro.',
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
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                decimal: true,
                              ),
                              decoration: const InputDecoration(
                                labelText: 'Ingreso Mensual Total (MXN)',
                                prefixIcon: Icon(
                                  Icons.attach_money_rounded,
                                  color: AppColors.accentOrange,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 14),
                          ElevatedButton(
                            onPressed: () {
                              final double? parsed =
                                  double.tryParse(_incomeController.text.trim());
                              if (parsed != null && parsed > 0) {
                                widget.onMonthlyIncomeChanged(parsed);
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      'Presupuesto 50/30/20 actualizado a \$${parsed.toStringAsFixed(2)} MXN',
                                    ),
                                  ),
                                );
                              }
                            },
                            child: const Text('Actualizar Topes'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),

              // 3. Whitelist de Apps Bancarias para Scraping de Notificaciones (S23 Ultra)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(24.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          Icon(
                            Icons.notifications_active_rounded,
                            color: AppColors.accentOrange,
                          ),
                          SizedBox(width: 10),
                          Text(
                            'Scraping de Notificaciones Bancarias (Webhook S23 Ultra)',
                            style: TextStyle(
                              fontSize: 16.5,
                              fontWeight: FontWeight.w800,
                              color: AppColors.textPrimary,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      const Text(
                        'Selecciona las aplicaciones cuyas notificaciones serán interceptadas, hasheadas con SHA-256 (`identificador_externo`) y enviadas vía Webhook a FastAPI:',
                        style: TextStyle(
                          fontSize: 13,
                          color: AppColors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 12),
                      for (final entry
                          in SupportedBankingApps.allowedPackages.entries)
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          activeThumbColor: AppColors.accentOrange,
                          title: Text(
                            entry.value,
                            style: const TextStyle(
                              color: AppColors.textPrimary,
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                            ),
                          ),
                          subtitle: Text(
                            entry.key,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 11.5,
                              color: AppColors.textSecondary,
                            ),
                          ),
                          value: _enabledBankPackages[entry.key] ?? true,
                          onChanged: (val) {
                            setState(() {
                              _enabledBankPackages[entry.key] = val;
                            });
                          },
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

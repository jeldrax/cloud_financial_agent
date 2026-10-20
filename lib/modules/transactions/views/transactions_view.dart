import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/network/api_client.dart';
import '../../../main.dart';
import '../models/transaction_model.dart';
import '../services/bank_notification_webhook_service.dart';
import '../services/voice_recorder_service.dart';

/// Vista principal del módulo `transactions`:
/// - Botón de micrófono destacado ("Plug & Play" estilo MonAi) para captura directa de audio con Gemini.
/// - Caja de texto en lenguaje natural con reglas de exclusión (`IGNORAR`) y clasificación 50/30/20.
/// - Historial filtrable de transacciones recibidas por Webhooks de notificaciones bancarias e IA.
class TransactionsView extends StatefulWidget {
  final List<TransactionRecord> transactions;
  final ValueChanged<TransactionRecord> onTransactionCreated;

  const TransactionsView({
    super.key,
    required this.transactions,
    required this.onTransactionCreated,
  });

  @override
  State<TransactionsView> createState() => _TransactionsViewState();
}

class _TransactionsViewState extends State<TransactionsView> {
  final TextEditingController _textController = TextEditingController();
  final ApiClient _apiClient = ApiClient();
  final VoiceRecorderService _voiceRecorder = VoiceRecorderService();
  late final BankNotificationWebhookService _webhookService =
      BankNotificationWebhookService(apiClient: _apiClient);

  bool _isRecording = false;
  bool _isProcessingAi = false;
  int _recordingSeconds = 0;
  Timer? _recordingTimer;

  /// Filtro activo sobre el historial: null = Todos, o una categoría / canal específico.
  BudgetCategory? _selectedCategoryFilter;
  bool _onlyWebhooksFilter = false;

  @override
  void dispose() {
    _recordingTimer?.cancel();
    _textController.dispose();
    _voiceRecorder.dispose();
    super.dispose();
  }

  /// Inicia o detiene la grabación directa de audio al estilo MonAi.
  Future<void> _toggleVoiceRecording() async {
    if (_isProcessingAi) return;

    if (!_isRecording) {
      final bool started = await _voiceRecorder.startRecording();
      if (!mounted) return;

      if (!started) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            backgroundColor: AppColors.accentRed,
            content: Text(
              'Permiso de micrófono denegado o dispositivo de audio no disponible.',
            ),
          ),
        );
        return;
      }

      setState(() {
        _isRecording = true;
        _recordingSeconds = 0;
      });

      _recordingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) {
          setState(() => _recordingSeconds++);
        }
      });
    } else {
      _recordingTimer?.cancel();
      final String? audioPath = await _voiceRecorder.stopRecording();
      if (!mounted) return;

      setState(() {
        _isRecording = false;
        _isProcessingAi = true;
      });

      try {
        if (audioPath != null) {
          final TransactionRecord created =
              await _apiClient.ingestVoiceNote(audioFilePath: audioPath);
          if (!mounted) return;
          _handleNewRecordResult(created);
        }
      } catch (_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Nota de voz capturada. Verifica conexión Tailscale (Env.apiUrl) para transcripción Gemini.',
            ),
          ),
        );
      } finally {
        await _voiceRecorder.purgeTemporaryAudio(audioPath);
        if (mounted) {
          setState(() => _isProcessingAi = false);
        }
      }
    }
  }

  /// Envía texto en lenguaje natural a FastAPI + Gemini (`procesar_texto_ia`).
  Future<void> _submitNaturalLanguageText() async {
    final String prompt = _textController.text.trim();
    if (prompt.isEmpty || _isProcessingAi) return;

    setState(() => _isProcessingAi = true);

    try {
      final TransactionRecord created =
          await _apiClient.ingestNaturalLanguageText(prompt);
      if (!mounted) return;
      _textController.clear();
      _handleNewRecordResult(created);
    } catch (_) {
      // Fallback local demostrativo cuando el contenedor TrueNAS no está alcanzable aún
      if (!mounted) return;
      final TransactionRecord localPreview = _buildLocalHeuristicPreview(prompt);
      _textController.clear();
      _handleNewRecordResult(localPreview, isOfflinePreview: true);
    } finally {
      if (mounted) {
        setState(() => _isProcessingAi = false);
      }
    }
  }

  /// Clasificador heurístico local de respaldo cuando se prueba la UI sin conexión al backend.
  TransactionRecord _buildLocalHeuristicPreview(String rawText) {
    final String lower = rawText.toLowerCase();
    final RegExp numRegex = RegExp(r'(\d+(?:\.\d{1,2})?)');
    final Match? amountMatch = numRegex.firstMatch(rawText);
    final double amount =
        amountMatch != null ? (double.tryParse(amountMatch.group(1)!) ?? 0) : 0;

    // Regla anti-duplicidad idéntica a `src/ai_engine.py`
    final bool isCardPaymentOrInternal =
        (lower.contains('transfer') && lower.contains('nu')) ||
            lower.contains('pagar la tarjeta') ||
            lower.contains('pago a tarjeta') ||
            lower.contains('quincena') ||
            lower.contains('sueldo');

    BudgetCategory category = BudgetCategory.gustos;
    if (isCardPaymentOrInternal) {
      category = BudgetCategory.ignorar;
    } else if (lower.contains('luz') ||
        lower.contains('agua') ||
        lower.contains('internet') ||
        lower.contains('despensa') ||
        lower.contains('renta') ||
        lower.contains('transporte')) {
      category = BudgetCategory.necesidades;
    } else if (lower.contains('ahorro') ||
        lower.contains('inversi') ||
        lower.contains('emergencia') ||
        lower.contains('cetes')) {
      category = BudgetCategory.ahorro;
    }

    final bool isIncome = lower.contains('devolvieron') ||
        lower.contains('reembolso') ||
        lower.contains('recib');

    return TransactionRecord(
      fecha: DateTime.now(),
      monto: amount > 0 ? amount : 150.0,
      concepto: rawText.trim(),
      categoria: category,
      metodoPago: lower.contains('efectivo')
          ? 'Efectivo'
          : (lower.contains('mercado pago') ? 'Mercado Pago' : 'Tarjeta Nu'),
      tipo: isIncome ? TransactionType.ingreso : TransactionType.gasto,
      source: IngestionSource.textAi,
    );
  }

  void _handleNewRecordResult(
    TransactionRecord record, {
    bool isOfflinePreview = false,
  }) {
    if (record.isIgnoredByRule) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: AppColors.surfaceDark,
          content: Text(
            'Movimiento IGNORADO por regla anti-duplicidad: "${record.concepto}" (Pago de tarjeta / transferencia propia).',
          ),
        ),
      );
      return;
    }

    widget.onTransactionCreated(record);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: AppColors.surface,
        content: Text(
          '${isOfflinePreview ? "[Modo Vista Previa] " : ""}Registrado en ${record.categoria.backendValue}: \$${record.monto.toStringAsFixed(2)} MXN',
        ),
      ),
    );
  }

  /// Simula la intercepción de una notificación bancaria del S23 Ultra y su envío vía Webhook.
  Future<void> _simulateIncomingBankWebhook() async {
    final DateTime now = DateTime.now();
    const String pkg = 'com.nu.production';
    const String title = 'Compra aprobada con tu Tarjeta Nu';
    const String body =
        'Compra por \$485.00 MXN en Supermercado La Comer. Método: Crédito.';

    final String externalId = _webhookService.buildExternalDeduplicationId(
      packageName: pkg,
      title: title,
      body: body,
      timestamp: now,
    );

    final record = TransactionRecord(
      fecha: now,
      monto: 485.00,
      concepto: 'Supermercado La Comer (Notificación Nu)',
      categoria: BudgetCategory.necesidades,
      metodoPago: 'Tarjeta Nu',
      tipo: TransactionType.gasto,
      identificadorExterno: externalId,
      source: IngestionSource.bankWebhook,
    );

    widget.onTransactionCreated(record);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: AppColors.surface,
        content: Text(
          'Webhook procesado ($externalId) -> Necesidades (50%): \$485.00 MXN',
        ),
      ),
    );
  }

  List<TransactionRecord> get _filteredTransactions {
    return widget.transactions.where((item) {
      if (_onlyWebhooksFilter && item.source != IngestionSource.bankWebhook) {
        return false;
      }
      if (_selectedCategoryFilter != null &&
          item.categoria != _selectedCategoryFilter) {
        return false;
      }
      return true;
    }).toList();
  }

  String _formatDuration(int totalSeconds) {
    final int minutes = totalSeconds ~/ 60;
    final int seconds = totalSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filteredTransactions;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24.0),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1020),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Encabezado + Botón de prueba de Webhook bancario
              Wrap(
                spacing: 16,
                runSpacing: 12,
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Captura Inteligente IA y Webhooks',
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w800,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      SizedBox(height: 4),
                      Text(
                        'Experiencia Plug & Play (Voz / Texto) + Scraping autónomo de notificaciones bancarias.',
                        style: TextStyle(
                          fontSize: 13.5,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                  OutlinedButton.icon(
                    onPressed: _simulateIncomingBankWebhook,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.accentOrange,
                      side: const BorderSide(color: AppColors.accentOrange),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    icon: const Icon(Icons.webhook_rounded, size: 18),
                    label: const Text('Probar Webhook Bancario'),
                  ),
                ],
              ),
              const SizedBox(height: 24),

              // Tarjeta Principal de Captura Multimodal (Estilo MonAi)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(28.0),
                  child: Column(
                    children: [
                      GestureDetector(
                        onTap: _toggleVoiceRecording,
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 220),
                          width: 104,
                          height: 104,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: _isRecording
                                ? AppColors.accentRed
                                : AppColors.accentOrange,
                            boxShadow: [
                              BoxShadow(
                                color: (_isRecording
                                        ? AppColors.accentRed
                                        : AppColors.accentOrange)
                                    .withValues(alpha: 0.42),
                                blurRadius: _isRecording ? 32 : 18,
                                spreadRadius: _isRecording ? 8 : 2,
                              ),
                            ],
                          ),
                          child: Icon(
                            _isRecording
                                ? Icons.stop_rounded
                                : Icons.mic_rounded,
                            size: 48,
                            color: _isRecording
                                ? AppColors.textPrimary
                                : AppColors.surfaceDark,
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        _isRecording
                            ? 'Grabando nota de voz (${_formatDuration(_recordingSeconds)}) • Toca para enviar a Gemini'
                            : 'Toca el micrófono para dictar un gasto o ingreso al instante',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w700,
                          color: _isRecording
                              ? AppColors.accentRed
                              : AppColors.accentOrange,
                        ),
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        'Pagos de tarjeta de crédito (Nu / Mercado Pago) y transferencias propias se omiten automáticamente.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 24),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _textController,
                              onSubmitted: (_) => _submitNaturalLanguageText(),
                              style: const TextStyle(
                                color: AppColors.textPrimary,
                              ),
                              decoration: const InputDecoration(
                                hintText:
                                    'Escribe: "Pagué 450 de luz con Nu" o "Comí tacos por 120 en efectivo"...',
                                prefixIcon: Icon(
                                  Icons.auto_awesome_rounded,
                                  color: AppColors.accentOrange,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          ElevatedButton.icon(
                            onPressed: _isProcessingAi
                                ? null
                                : _submitNaturalLanguageText,
                            icon: _isProcessingAi
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: AppColors.surfaceDark,
                                    ),
                                  )
                                : const Icon(Icons.send_rounded),
                            label: Text(
                              _isProcessingAi ? 'Analizando...' : 'Procesar IA',
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 28),

              // Filtros rápidos de categoría 50/30/20 y canal Webhook
              Wrap(
                spacing: 10,
                runSpacing: 10,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Text(
                    'FILTRAR HISTORIAL:',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.1,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  FilterChip(
                    label: const Text('Todos'),
                    selected:
                        _selectedCategoryFilter == null && !_onlyWebhooksFilter,
                    onSelected: (_) {
                      setState(() {
                        _selectedCategoryFilter = null;
                        _onlyWebhooksFilter = false;
                      });
                    },
                  ),
                  FilterChip(
                    label: const Text('50% Necesidades'),
                    selected:
                        _selectedCategoryFilter == BudgetCategory.necesidades,
                    selectedColor:
                        AppColors.accentOrange.withValues(alpha: 0.25),
                    onSelected: (selected) {
                      setState(() {
                        _selectedCategoryFilter =
                            selected ? BudgetCategory.necesidades : null;
                      });
                    },
                  ),
                  FilterChip(
                    label: const Text('30% Gustos'),
                    selected: _selectedCategoryFilter == BudgetCategory.gustos,
                    selectedColor: AppColors.accentRed.withValues(alpha: 0.25),
                    onSelected: (selected) {
                      setState(() {
                        _selectedCategoryFilter =
                            selected ? BudgetCategory.gustos : null;
                      });
                    },
                  ),
                  FilterChip(
                    label: const Text('20% Ahorro'),
                    selected: _selectedCategoryFilter == BudgetCategory.ahorro,
                    selectedColor: AppColors.accentTeal.withValues(alpha: 0.25),
                    onSelected: (selected) {
                      setState(() {
                        _selectedCategoryFilter =
                            selected ? BudgetCategory.ahorro : null;
                      });
                    },
                  ),
                  FilterChip(
                    avatar: const Icon(Icons.webhook_rounded, size: 16),
                    label: const Text('Solo Webhooks Bancarios'),
                    selected: _onlyWebhooksFilter,
                    onSelected: (selected) {
                      setState(() => _onlyWebhooksFilter = selected);
                    },
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // Listado de transacciones
              Card(
                child: filtered.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.all(32.0),
                        child: Center(
                          child: Text(
                            'No hay transacciones que coincidan con el filtro seleccionado.',
                            style: TextStyle(color: AppColors.textSecondary),
                          ),
                        ),
                      )
                    : ListView.separated(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: filtered.length,
                        separatorBuilder: (_, __) => const Divider(
                          height: 1,
                          color: AppColors.cardBorder,
                        ),
                        itemBuilder: (context, index) {
                          return TransactionListTile(record: filtered[index]);
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Widget reutilizable para mostrar una fila de transacción tanto en el Dashboard como en el Historial.
class TransactionListTile extends StatelessWidget {
  final TransactionRecord record;

  const TransactionListTile({super.key, required this.record});

  String _formatDate(DateTime dt) {
    final String hh = dt.hour.toString().padLeft(2, '0');
    final String mm = dt.minute.toString().padLeft(2, '0');
    return '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')} $hh:$mm';
  }

  @override
  Widget build(BuildContext context) {
    final bool isExpense = record.tipo.isExpense;
    final Color amountColor =
        isExpense ? AppColors.accentRed : AppColors.accentTeal;
    final String sign = isExpense ? '-' : '+';

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(
        horizontal: 20.0,
        vertical: 8.0,
      ),
      leading: Container(
        width: 46,
        height: 46,
        decoration: BoxDecoration(
          color: record.categoria.color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: record.categoria.color.withValues(alpha: 0.5),
          ),
        ),
        child: Icon(
          record.source.icon,
          color: record.categoria.color,
          size: 22,
        ),
      ),
      title: Text(
        record.concepto,
        style: const TextStyle(
          fontWeight: FontWeight.w700,
          color: AppColors.textPrimary,
          fontSize: 14.5,
        ),
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4.0),
        child: Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: AppColors.surfaceDark,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '${record.categoria.backendValue} (${record.categoria.targetPercentage}%)',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: record.categoria.color,
                ),
              ),
            ),
            Text(
              '${record.metodoPago} • ${record.source.label} • ${_formatDate(record.fecha)}',
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            ),
            if (record.identificadorExterno != null)
              Text(
                '[${record.identificadorExterno}]',
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11,
                  color: AppColors.textSecondary,
                ),
              ),
          ],
        ),
      ),
      trailing: Text(
        '$sign\$${record.monto.toStringAsFixed(2)}',
        style: TextStyle(
          fontWeight: FontWeight.w800,
          fontSize: 15.5,
          color: amountColor,
        ),
      ),
    );
  }
}

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/network/api_client.dart';
import '../../../main.dart';
import '../models/transaction_model.dart';
import '../services/voice_recorder_service.dart';

/// Vista principal del módulo `transactions` (100% Manual y Auto-Gestionado):
/// - Formulario directo para registrar Ingresos o Egresos con precisión exacta sin depender de IA.
/// - Asistente opcional de Voz o Texto libre con Gemini protegido contra Prompt Injection.
/// - Historial filtrable con opción de eliminar cualquier movimiento.
class TransactionsView extends StatefulWidget {
  final List<TransactionRecord> transactions;
  final ValueChanged<TransactionRecord> onTransactionCreated;
  final ValueChanged<TransactionRecord> onTransactionDeleted;

  const TransactionsView({
    super.key,
    required this.transactions,
    required this.onTransactionCreated,
    required this.onTransactionDeleted,
  });

  @override
  State<TransactionsView> createState() => _TransactionsViewState();
}

class _TransactionsViewState extends State<TransactionsView> {
  static const List<String> _paymentMethods = [
    'Efectivo',
    'Tarjeta de Débito',
    'Tarjeta de Crédito',
    'Transferencia',
  ];

  // Controladores del Formulario Manual Directo
  final TextEditingController _amountController = TextEditingController();
  final TextEditingController _conceptController = TextEditingController();
  TransactionType _manualType = TransactionType.gasto;
  BudgetCategory _manualCategory = BudgetCategory.necesidades;
  String _manualPaymentMethod = 'Efectivo';
  bool _isSavingManual = false;

  // Controladores del Asistente IA (Voz / Texto)
  final TextEditingController _aiTextController = TextEditingController();
  final ApiClient _apiClient = ApiClient();
  final VoiceRecorderService _voiceRecorder = VoiceRecorderService();

  bool _isRecording = false;
  bool _isProcessingAi = false;
  int _recordingSeconds = 0;
  Timer? _recordingTimer;

  // Filtros del Historial
  BudgetCategory? _selectedCategoryFilter;
  TransactionType? _selectedTypeFilter;

  @override
  void dispose() {
    _recordingTimer?.cancel();
    _amountController.dispose();
    _conceptController.dispose();
    _aiTextController.dispose();
    _voiceRecorder.dispose();
    super.dispose();
  }

  /// Guarda un movimiento (Gasto o Ingreso) directamente en SQLite sin pasar por IA.
  Future<void> _submitManualForm() async {
    if (_isSavingManual) return;

    final String rawAmount =
        _amountController.text.trim().replaceAll(',', '.');
    final double? amount = double.tryParse(rawAmount);
    final String concept = _conceptController.text.trim();

    if (amount == null || amount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: AppColors.accentRed,
          content: Text('Ingresa un monto numérico válido mayor a 0.'),
        ),
      );
      return;
    }

    if (concept.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: AppColors.accentRed,
          content: Text('Escribe un concepto breve (mínimo 2 caracteres).'),
        ),
      );
      return;
    }

    setState(() => _isSavingManual = true);
    try {
      final TransactionRecord created =
          await _apiClient.createManualTransaction(
        monto: amount,
        concepto: concept,
        categoria: _manualCategory,
        tipo: _manualType,
        metodoPago: _manualPaymentMethod,
      );
      if (!mounted) return;
      _amountController.clear();
      _conceptController.clear();
      _handleCreatedRecord(created);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: AppColors.accentRed,
          content: Text(
            'Error al guardar en el servidor. Verifica Tailscale ($e).',
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isSavingManual = false);
      }
    }
  }

  /// Inicia o detiene la grabación directa de audio enviada manualmente por el usuario.
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
          _handleCreatedRecord(created);
        }
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: AppColors.accentRed,
            content: Text(
              'No se pudo procesar la nota de voz ($e). Verifica conexión Tailscale.',
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
  /// Sin previsualizaciones falsas locales: solo registra si el servidor confirma escritura real.
  Future<void> _submitNaturalLanguageText() async {
    final String prompt = _aiTextController.text.trim();
    if (prompt.isEmpty || _isProcessingAi) return;

    setState(() => _isProcessingAi = true);
    try {
      final TransactionRecord created =
          await _apiClient.ingestNaturalLanguageText(prompt);
      if (!mounted) return;
      _aiTextController.clear();
      _handleCreatedRecord(created);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: AppColors.accentRed,
          content: Text(
            'No se registró el movimiento: $e',
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isProcessingAi = false);
      }
    }
  }

  void _handleCreatedRecord(TransactionRecord record) {
    if (record.isIgnoredByRule) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: AppColors.surfaceDark,
          content: Text(
            'Movimiento omitido por regla antiduplicidad: "${record.concepto}".',
          ),
        ),
      );
      return;
    }

    widget.onTransactionCreated(record);
    final String tipoLabel =
        record.tipo == TransactionType.ingreso ? 'Ingreso' : 'Gasto';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: AppColors.surface,
        content: Text(
          '$tipoLabel guardado en ${record.categoria.backendValue}: \$${record.monto.toStringAsFixed(2)} MXN',
        ),
      ),
    );
  }

  List<TransactionRecord> get _filteredTransactions {
    return widget.transactions.where((item) {
      if (_selectedTypeFilter != null && item.tipo != _selectedTypeFilter) {
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
              const Text(
                'Registro Personal de Ingresos y Egresos',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'Control 100% manual: agrega tus movimientos mediante formulario exacto o dictado rápido con IA.',
                style: TextStyle(
                  fontSize: 13.5,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 24),

              // 1. Formulario Manual Directo (Sin IA, 100% Determinista)
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
                                Icons.edit_note_rounded,
                                color: AppColors.accentOrange,
                              ),
                              SizedBox(width: 10),
                              Text(
                                'Registro Manual Exacto',
                                style: TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w800,
                                  color: AppColors.textPrimary,
                                ),
                              ),
                            ],
                          ),
                          SegmentedButton<TransactionType>(
                            segments: const [
                              ButtonSegment<TransactionType>(
                                value: TransactionType.gasto,
                                icon: Icon(Icons.trending_down_rounded, size: 18),
                                label: Text('Egreso (Gasto)'),
                              ),
                              ButtonSegment<TransactionType>(
                                value: TransactionType.ingreso,
                                icon: Icon(Icons.trending_up_rounded, size: 18),
                                label: Text('Ingreso'),
                              ),
                            ],
                            selected: {_manualType},
                            onSelectionChanged: (selection) {
                              setState(() => _manualType = selection.first);
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 18),
                      LayoutBuilder(
                        builder: (context, constraints) {
                          final bool wide = constraints.maxWidth >= 620;
                          final amountField = TextField(
                            controller: _amountController,
                            keyboardType:
                                const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            decoration: const InputDecoration(
                              labelText: 'Monto (MXN)',
                              hintText: 'Ej. 350.00',
                              prefixIcon: Icon(
                                Icons.attach_money_rounded,
                                color: AppColors.accentOrange,
                              ),
                            ),
                          );
                          final conceptField = TextField(
                            controller: _conceptController,
                            maxLength: 100,
                            onSubmitted: (_) => _submitManualForm(),
                            decoration: const InputDecoration(
                              labelText: 'Concepto o motivo',
                              hintText: 'Ej. Despensa supermercado / Reembolso',
                              counterText: '',
                              prefixIcon: Icon(
                                Icons.description_outlined,
                                color: AppColors.accentOrange,
                              ),
                            ),
                          );

                          if (wide) {
                            return Row(
                              children: [
                                SizedBox(width: 210, child: amountField),
                                const SizedBox(width: 14),
                                Expanded(child: conceptField),
                              ],
                            );
                          }
                          return Column(
                            children: [
                              amountField,
                              const SizedBox(height: 12),
                              conceptField,
                            ],
                          );
                        },
                      ),
                      const SizedBox(height: 16),
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          const Text(
                            'Categoría 50/30/20:',
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                              color: AppColors.textSecondary,
                            ),
                          ),
                          for (final cat in const [
                            BudgetCategory.necesidades,
                            BudgetCategory.gustos,
                            BudgetCategory.ahorro,
                          ])
                            ChoiceChip(
                              label: Text(
                                '${cat.backendValue} (${cat.targetPercentage}%)',
                              ),
                              selected: _manualCategory == cat,
                              selectedColor: cat.color.withValues(alpha: 0.25),
                              onSelected: (_) {
                                setState(() => _manualCategory = cat);
                              },
                            ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        alignment: WrapAlignment.spaceBetween,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              const Text(
                                'Método:',
                                style: TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.textSecondary,
                                ),
                              ),
                              for (final method in _paymentMethods)
                                ChoiceChip(
                                  label: Text(method),
                                  selected: _manualPaymentMethod == method,
                                  onSelected: (_) {
                                    setState(
                                      () => _manualPaymentMethod = method,
                                    );
                                  },
                                ),
                            ],
                          ),
                          ElevatedButton.icon(
                            onPressed:
                                _isSavingManual ? null : _submitManualForm,
                            icon: _isSavingManual
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: AppColors.surfaceDark,
                                    ),
                                  )
                                : const Icon(Icons.check_circle_outline_rounded),
                            label: Text(
                              _isSavingManual
                                  ? 'Guardando...'
                                  : 'Guardar Movimiento',
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),

              // 2. Tarjeta Opcional de Captura Asistida por IA (Voz / Texto Libre)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(24.0),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          GestureDetector(
                            onTap: _toggleVoiceRecording,
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 220),
                              width: 64,
                              height: 64,
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
                                        .withValues(alpha: 0.35),
                                    blurRadius: _isRecording ? 24 : 12,
                                    spreadRadius: _isRecording ? 4 : 1,
                                  ),
                                ],
                              ),
                              child: Icon(
                                _isRecording
                                    ? Icons.stop_rounded
                                    : Icons.mic_rounded,
                                size: 32,
                                color: _isRecording
                                    ? AppColors.textPrimary
                                    : AppColors.surfaceDark,
                              ),
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _isRecording
                                      ? 'Grabando voz (${_formatDuration(_recordingSeconds)}) • Toca para enviar'
                                      : 'Captura Rápida con IA (Voz o Texto Libre)',
                                  style: TextStyle(
                                    fontSize: 15.5,
                                    fontWeight: FontWeight.w800,
                                    color: _isRecording
                                        ? AppColors.accentRed
                                        : AppColors.textPrimary,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                const Text(
                                  'Dicta o escribe en lenguaje natural y Gemini clasificará el monto y la categoría 50/30/20 bajo aislamiento anti-inyección.',
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    color: AppColors.textSecondary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 18),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _aiTextController,
                              maxLength: ApiClient.maxPromptLength,
                              onSubmitted: (_) => _submitNaturalLanguageText(),
                              style: const TextStyle(
                                color: AppColors.textPrimary,
                              ),
                              decoration: const InputDecoration(
                                counterText: '',
                                hintText:
                                    'Ej. "Pagué 450 de luz en efectivo" o "Recibí 300 de reembolso"...',
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
                              _isProcessingAi ? 'Analizando...' : 'Analizar IA',
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 28),

              // 3. Filtros rápidos del historial
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
                    selected: _selectedCategoryFilter == null &&
                        _selectedTypeFilter == null,
                    onSelected: (_) {
                      setState(() {
                        _selectedCategoryFilter = null;
                        _selectedTypeFilter = null;
                      });
                    },
                  ),
                  FilterChip(
                    label: const Text('Solo Egresos'),
                    selected: _selectedTypeFilter == TransactionType.gasto,
                    onSelected: (selected) {
                      setState(() {
                        _selectedTypeFilter =
                            selected ? TransactionType.gasto : null;
                      });
                    },
                  ),
                  FilterChip(
                    label: const Text('Solo Ingresos'),
                    selected: _selectedTypeFilter == TransactionType.ingreso,
                    onSelected: (selected) {
                      setState(() {
                        _selectedTypeFilter =
                            selected ? TransactionType.ingreso : null;
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
                ],
              ),
              const SizedBox(height: 16),

              // 4. Listado real de transacciones
              Card(
                child: filtered.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.all(32.0),
                        child: Center(
                          child: Text(
                            'No hay movimientos registrados que coincidan con el filtro.',
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
                          return TransactionListTile(
                            record: filtered[index],
                            onDelete: widget.onTransactionDeleted,
                          );
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

/// Widget reutilizable para mostrar una fila de transacción con opción de borrado seguro.
class TransactionListTile extends StatelessWidget {
  final TransactionRecord record;
  final ValueChanged<TransactionRecord>? onDelete;

  const TransactionListTile({
    super.key,
    required this.record,
    this.onDelete,
  });

  String _formatDate(DateTime dt) {
    final String hh = dt.hour.toString().padLeft(2, '0');
    final String mm = dt.minute.toString().padLeft(2, '0');
    return '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year} $hh:$mm';
  }

  Future<void> _confirmDelete(BuildContext context) async {
    if (onDelete == null || record.id == null) return;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Eliminar movimiento'),
        content: Text(
          '¿Deseas eliminar "${record.concepto}" por \$${record.monto.toStringAsFixed(2)} MXN?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.accentRed,
              foregroundColor: AppColors.textPrimary,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      onDelete!(record);
    }
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
          ],
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$sign\$${record.monto.toStringAsFixed(2)}',
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 15.5,
              color: amountColor,
            ),
          ),
          if (onDelete != null && record.id != null) ...[
            const SizedBox(width: 6),
            IconButton(
              tooltip: 'Eliminar movimiento',
              icon: const Icon(
                Icons.delete_outline_rounded,
                size: 20,
                color: AppColors.textSecondary,
              ),
              onPressed: () => _confirmDelete(context),
            ),
          ],
        ],
      ),
    );
  }
}

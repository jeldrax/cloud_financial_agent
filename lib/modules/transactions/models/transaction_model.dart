import 'package:flutter/material.dart';

import '../../../main.dart';

/// Categorías estrictas de la regla presupuestal 50/30/20 + regla de exclusión `IGNORAR`
/// sincronizadas con `GastoExtraido` en `src/ai_engine.py`.
enum BudgetCategory {
  necesidades('Necesidades', 50, AppColors.accentOrange, Icons.home_work_rounded),
  gustos('Gustos', 30, AppColors.accentRed, Icons.local_fire_department_rounded),
  ahorro('Ahorro', 20, AppColors.accentTeal, Icons.savings_rounded),
  ignorar('IGNORAR', 0, AppColors.textSecondary, Icons.block_rounded);

  final String backendValue;
  final int targetPercentage;
  final Color color;
  final IconData icon;

  const BudgetCategory(
    this.backendValue,
    this.targetPercentage,
    this.color,
    this.icon,
  );

  static BudgetCategory fromBackend(String raw) {
    switch (raw.trim().toLowerCase()) {
      case 'necesidades':
        return BudgetCategory.necesidades;
      case 'gustos':
        return BudgetCategory.gustos;
      case 'ahorro':
        return BudgetCategory.ahorro;
      case 'ignorar':
        return BudgetCategory.ignorar;
      default:
        return BudgetCategory.gustos;
    }
  }
}

/// Tipo de movimiento financiero ('Gasto' o 'Ingreso') según `src/database.py`.
enum TransactionType {
  gasto('Gasto'),
  ingreso('Ingreso');

  final String backendValue;
  const TransactionType(this.backendValue);

  bool get isExpense => this == TransactionType.gasto;

  static TransactionType fromBackend(String raw) {
    return raw.trim().toLowerCase() == 'ingreso'
        ? TransactionType.ingreso
        : TransactionType.gasto;
  }
}

/// Canal de origen de la ingesta de datos.
enum IngestionSource {
  voiceAi('Voz IA (MonAi)', Icons.graphic_eq_rounded),
  textAi('Texto IA', Icons.auto_awesome_rounded),
  bankWebhook('Webhook Bancario', Icons.webhook_rounded);

  final String label;
  final IconData icon;
  const IngestionSource(this.label, this.icon);
}

/// Entidad inmutable que representa una fila de la tabla SQLite `transacciones`
/// o el resultado estructurado devuelto por Gemini (`GastoExtraido`).
class TransactionRecord {
  final int? id;
  final DateTime fecha;
  final double monto;
  final String concepto;
  final BudgetCategory categoria;
  final String metodoPago;
  final TransactionType tipo;
  final String? identificadorExterno;
  final IngestionSource source;

  const TransactionRecord({
    this.id,
    required this.fecha,
    required this.monto,
    required this.concepto,
    required this.categoria,
    required this.metodoPago,
    required this.tipo,
    this.identificadorExterno,
    this.source = IngestionSource.textAi,
  });

  bool get isIgnoredByRule => categoria == BudgetCategory.ignorar;

  factory TransactionRecord.fromJson(
    Map<String, dynamic> json, {
    IngestionSource defaultSource = IngestionSource.textAi,
  }) {
    final String? extId = json['identificador_externo'] as String?;
    return TransactionRecord(
      id: json['id'] as int?,
      fecha: json['fecha'] != null
          ? (DateTime.tryParse(json['fecha'].toString()) ?? DateTime.now())
          : DateTime.now(),
      monto: (json['monto'] as num?)?.toDouble() ?? 0.0,
      concepto: (json['concepto'] as String?) ?? 'Movimiento sin descripción',
      categoria: BudgetCategory.fromBackend(
        (json['categoria'] as String?) ?? 'Gustos',
      ),
      metodoPago: (json['metodo_pago'] as String?) ?? 'No especificado',
      tipo: TransactionType.fromBackend((json['tipo'] as String?) ?? 'Gasto'),
      identificadorExterno: extId,
      source: (extId != null && extId.startsWith('WH-'))
          ? IngestionSource.bankWebhook
          : defaultSource,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (id != null) 'id': id,
      'fecha': fecha.toIso8601String(),
      'monto': monto,
      'concepto': concepto,
      'categoria': categoria.backendValue,
      'metodo_pago': metodoPago,
      'tipo': tipo.backendValue,
      if (identificadorExterno != null)
        'identificador_externo': identificadorExterno,
    };
  }
}

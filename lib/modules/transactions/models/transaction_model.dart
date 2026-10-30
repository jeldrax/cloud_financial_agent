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

/// Canal de registro manual del usuario (sin conexiones bancarias externas).
enum IngestionSource {
  manualForm('Registro Manual', Icons.edit_note_rounded),
  textAi('Texto IA', Icons.auto_awesome_rounded),
  voiceAi('Voz IA', Icons.graphic_eq_rounded);

  final String label;
  final IconData icon;
  const IngestionSource(this.label, this.icon);
}

/// Entidad inmutable que representa una fila real de la tabla SQLite `transacciones`.
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
    this.source = IngestionSource.manualForm,
  });

  bool get isIgnoredByRule => categoria == BudgetCategory.ignorar;

  factory TransactionRecord.fromJson(
    Map<String, dynamic> json, {
    IngestionSource defaultSource = IngestionSource.manualForm,
  }) {
    final String? extId = json['identificador_externo'] as String?;
    final String metodo = (json['metodo_pago'] as String?) ?? 'Efectivo';

    IngestionSource resolvedSource = defaultSource;
    if (extId == 'MANUAL') {
      resolvedSource = IngestionSource.manualForm;
    } else if (metodo.toLowerCase().contains('voz')) {
      resolvedSource = IngestionSource.voiceAi;
    } else if (metodo.toLowerCase().contains('ia')) {
      resolvedSource = IngestionSource.textAi;
    }

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
      metodoPago: metodo,
      tipo: TransactionType.fromBackend((json['tipo'] as String?) ?? 'Gasto'),
      identificadorExterno: extId,
      source: resolvedSource,
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

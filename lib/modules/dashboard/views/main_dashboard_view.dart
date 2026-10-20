import 'package:flutter/material.dart';

import '../../../core/network/api_client.dart';
import '../../../main.dart';
import '../../settings/views/settings_view.dart';
import '../../transactions/models/transaction_model.dart';
import '../../transactions/views/transactions_view.dart';

/// Modelo inmutable para cada bloque de la regla presupuestal 50/30/20.
class BudgetCategorySummary {
  final BudgetCategory category;
  final String subtitle;
  final double allocatedAmount;
  final double netSpentAmount;

  const BudgetCategorySummary({
    required this.category,
    required this.subtitle,
    required this.allocatedAmount,
    required this.netSpentAmount,
  });

  String get title => category.backendValue;
  int get targetPercentage => category.targetPercentage;
  Color get accentColor => category.color;
  IconData get icon => category.icon;

  double get remainingAmount =>
      (allocatedAmount - netSpentAmount).clamp(0.0, double.infinity);

  double get usageRatio =>
      allocatedAmount <= 0 ? 0.0 : (netSpentAmount / allocatedAmount).clamp(0.0, 1.0);

  bool get isNearOrOverLimit => usageRatio >= 0.85;
}

/// Vista principal con ruteo adaptativo mediante [LayoutBuilder]:
/// - Pantallas pequeñas (< 720px, ej. S23 Ultra): [BottomNavigationBar]
/// - Pantallas medianas/grandes (>= 720px, ej. Galaxy Tab S7 FE y Linux KDE Desktop): [NavigationRail]
class MainDashboardView extends StatefulWidget {
  const MainDashboardView({super.key});

  @override
  State<MainDashboardView> createState() => _MainDashboardViewState();
}

class _MainDashboardViewState extends State<MainDashboardView> {
  static const double _tabletDesktopBreakpoint = 720.0;
  static const double _extendedRailBreakpoint = 1080.0;

  final ApiClient _apiClient = ApiClient();

  int _selectedIndex = 0;
  bool _isSyncing = false;

  /// Ingreso mensual base para la distribución 50% / 30% / 20%.
  double _monthlyTotalIncome = 24000.00;

  /// Gasto neto mensual reportado directamente por SQLite en TrueNAS (si está sincronizado).
  Map<BudgetCategory, double>? _remoteNetSpend;

  /// Historial reactivo de transacciones (alimentado por Voz IA, Texto IA y Webhooks Bancarios).
  final List<TransactionRecord> _transactions = [
    TransactionRecord(
      id: 104,
      fecha: DateTime.now().subtract(const Duration(hours: 2)),
      monto: 640.00,
      concepto: 'CFE Suministrador de Servicios Básicos',
      categoria: BudgetCategory.necesidades,
      metodoPago: 'Tarjeta Nu',
      tipo: TransactionType.gasto,
      identificadorExterno: 'WH-8F91D2A4E7B019C3',
      source: IngestionSource.bankWebhook,
    ),
    TransactionRecord(
      id: 103,
      fecha: DateTime.now().subtract(const Duration(hours: 5)),
      monto: 320.00,
      concepto: 'Cena tacos y bebidas con amigos',
      categoria: BudgetCategory.gustos,
      metodoPago: 'Efectivo',
      tipo: TransactionType.gasto,
      source: IngestionSource.voiceAi,
    ),
    TransactionRecord(
      id: 102,
      fecha: DateTime.now().subtract(const Duration(days: 1, hours: 3)),
      monto: 250.00,
      concepto: 'Reembolso parcial compra Amazon',
      categoria: BudgetCategory.gustos,
      metodoPago: 'Mercado Pago',
      tipo: TransactionType.ingreso,
      identificadorExterno: 'WH-3C77A109F4D822E1',
      source: IngestionSource.bankWebhook,
    ),
    TransactionRecord(
      id: 101,
      fecha: DateTime.now().subtract(const Duration(days: 2)),
      monto: 2400.00,
      concepto: 'Aportación mensual Fondo de Emergencia',
      categoria: BudgetCategory.ahorro,
      metodoPago: 'Transferencia SPEI',
      tipo: TransactionType.gasto,
      source: IngestionSource.textAi,
    ),
    TransactionRecord(
      id: 100,
      fecha: DateTime.now().subtract(const Duration(days: 3)),
      monto: 5800.00,
      concepto: 'Renta y mantenimiento departamento',
      categoria: BudgetCategory.necesidades,
      metodoPago: 'Transferencia SPEI',
      tipo: TransactionType.gasto,
      source: IngestionSource.textAi,
    ),
  ];

  @override
  void initState() {
    super.initState();
    _syncWithFastApiBackend(silent: true);
  }

  /// Sincroniza el gasto neto 50/30/20 y las transacciones recientes desde FastAPI en TrueNAS.
  Future<void> _syncWithFastApiBackend({bool silent = false}) async {
    if (_isSyncing) return;
    setState(() => _isSyncing = true);

    try {
      final netSpend = await _apiClient.fetchMonthlyNetSpendByCategory();
      final remoteTransactions =
          await _apiClient.fetchRecentTransactions(limit: 50);

      if (!mounted) return;
      setState(() {
        _remoteNetSpend = netSpend;
        if (remoteTransactions.isNotEmpty) {
          _transactions
            ..clear()
            ..addAll(remoteTransactions);
        }
      });

      if (!silent) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            backgroundColor: AppColors.surface,
            content: Text(
              'Sincronizado con FastAPI / SQLite en TrueNAS vía Tailscale.',
            ),
          ),
        );
      }
    } catch (_) {
      if (!mounted || silent) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Operando con caché local. Verifica conexión Tailscale con TrueNAS.',
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isSyncing = false);
      }
    }
  }

  /// Calcula el gasto neto (`Gastos - Ingresos`) por categoría siguiendo la lógica SQL de `src/database.py`.
  double _netSpentFor(BudgetCategory category) {
    if (_remoteNetSpend != null && _remoteNetSpend!.containsKey(category)) {
      return _remoteNetSpend![category]!.clamp(0.0, double.infinity);
    }
    double net = 0.0;
    for (final tx in _transactions) {
      if (tx.categoria == category) {
        net += tx.tipo.isExpense ? tx.monto : -tx.monto;
      }
    }
    return net.clamp(0.0, double.infinity);
  }

  List<BudgetCategorySummary> get _budgetCategories => [
        BudgetCategorySummary(
          category: BudgetCategory.necesidades,
          subtitle: 'Vivienda, servicios, despensa esencial y transporte',
          allocatedAmount: _monthlyTotalIncome * 0.50,
          netSpentAmount: _netSpentFor(BudgetCategory.necesidades),
        ),
        BudgetCategorySummary(
          category: BudgetCategory.gustos,
          subtitle: 'Salidas, estilo de vida, suscripciones y ocio',
          allocatedAmount: _monthlyTotalIncome * 0.30,
          netSpentAmount: _netSpentFor(BudgetCategory.gustos),
        ),
        BudgetCategorySummary(
          category: BudgetCategory.ahorro,
          subtitle: 'Fondo de emergencia, inversiones y amortización',
          allocatedAmount: _monthlyTotalIncome * 0.20,
          netSpentAmount: _netSpentFor(BudgetCategory.ahorro),
        ),
      ];

  void _addNewTransaction(TransactionRecord record) {
    setState(() {
      _remoteNetSpend = null;
      _transactions.insert(0, record);
    });
  }

  @override
  Widget build(BuildContext context) {
    final List<Widget> moduleViews = [
      _DashboardOverviewTab(
        monthlyTotalIncome: _monthlyTotalIncome,
        categories: _budgetCategories,
        recentTransactions: _transactions.take(5).toList(),
        isSyncing: _isSyncing,
        onRefreshSync: () => _syncWithFastApiBackend(silent: false),
        onNavigateToTransactions: () => setState(() => _selectedIndex = 1),
      ),
      TransactionsView(
        transactions: _transactions,
        onTransactionCreated: _addNewTransaction,
      ),
      SettingsView(
        monthlyIncome: _monthlyTotalIncome,
        onMonthlyIncomeChanged: (newIncome) {
          setState(() => _monthlyTotalIncome = newIncome);
        },
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final bool isWideScreen =
            constraints.maxWidth >= _tabletDesktopBreakpoint;
        final bool isExtendedRail =
            constraints.maxWidth >= _extendedRailBreakpoint;

        // Vista para Tablet (Galaxy Tab S7 FE) y Escritorio Linux (CachyOS KDE Plasma)
        if (isWideScreen) {
          return Scaffold(
            body: SafeArea(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  NavigationRail(
                    extended: isExtendedRail,
                    selectedIndex: _selectedIndex,
                    onDestinationSelected: (index) {
                      setState(() => _selectedIndex = index);
                    },
                    leading: Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: 20.0,
                        horizontal: 12.0,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 42,
                            height: 42,
                            decoration: BoxDecoration(
                              color: AppColors.accentOrange.withValues(alpha: 0.16),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: AppColors.accentOrange,
                                width: 1.4,
                              ),
                            ),
                            child: const Icon(
                              Icons.account_balance_wallet_rounded,
                              color: AppColors.accentOrange,
                            ),
                          ),
                          if (isExtendedRail) ...[
                            const SizedBox(width: 12),
                            const Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'HERMES 50/30/20',
                                  style: TextStyle(
                                    color: AppColors.textPrimary,
                                    fontWeight: FontWeight.w800,
                                    fontSize: 14,
                                    letterSpacing: 0.8,
                                  ),
                                ),
                                Text(
                                  'Tailscale • TrueNAS',
                                  style: TextStyle(
                                    color: AppColors.textSecondary,
                                    fontSize: 11.5,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                    destinations: const [
                      NavigationRailDestination(
                        icon: Icon(Icons.space_dashboard_outlined),
                        selectedIcon: Icon(Icons.space_dashboard_rounded),
                        label: Text('Dashboard 50/30/20'),
                      ),
                      NavigationRailDestination(
                        icon: Icon(Icons.mic_none_rounded),
                        selectedIcon: Icon(Icons.mic_rounded),
                        label: Text('Captura IA y Webhooks'),
                      ),
                      NavigationRailDestination(
                        icon: Icon(Icons.lan_outlined),
                        selectedIcon: Icon(Icons.lan_rounded),
                        label: Text('Red Tailscale'),
                      ),
                    ],
                  ),
                  const VerticalDivider(
                    width: 1,
                    thickness: 1,
                    color: AppColors.cardBorder,
                  ),
                  Expanded(
                    child: IndexedStack(
                      index: _selectedIndex,
                      children: moduleViews,
                    ),
                  ),
                ],
              ),
            ),
          );
        }

        // Vista para Móvil (Samsung S23 Ultra)
        return Scaffold(
          body: SafeArea(
            child: IndexedStack(
              index: _selectedIndex,
              children: moduleViews,
            ),
          ),
          bottomNavigationBar: Container(
            decoration: const BoxDecoration(
              border: Border(
                top: BorderSide(color: AppColors.cardBorder, width: 1),
              ),
            ),
            child: BottomNavigationBar(
              currentIndex: _selectedIndex,
              onTap: (index) => setState(() => _selectedIndex = index),
              items: const [
                BottomNavigationBarItem(
                  icon: Icon(Icons.space_dashboard_outlined),
                  activeIcon: Icon(Icons.space_dashboard_rounded),
                  label: 'Dashboard',
                ),
                BottomNavigationBarItem(
                  icon: Icon(Icons.mic_none_rounded),
                  activeIcon: Icon(Icons.mic_rounded),
                  label: 'Transacciones',
                ),
                BottomNavigationBarItem(
                  icon: Icon(Icons.lan_outlined),
                  activeIcon: Icon(Icons.lan_rounded),
                  label: 'Configuración',
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Módulo `dashboard`: Tarjeta de Balance General, Distribución 50/30/20 y Barras de Progreso.
class _DashboardOverviewTab extends StatelessWidget {
  final double monthlyTotalIncome;
  final List<BudgetCategorySummary> categories;
  final List<TransactionRecord> recentTransactions;
  final bool isSyncing;
  final VoidCallback onRefreshSync;
  final VoidCallback onNavigateToTransactions;

  const _DashboardOverviewTab({
    required this.monthlyTotalIncome,
    required this.categories,
    required this.recentTransactions,
    required this.isSyncing,
    required this.onRefreshSync,
    required this.onNavigateToTransactions,
  });

  @override
  Widget build(BuildContext context) {
    final double totalNetSpent = categories.fold(
      0.0,
      (sum, item) => sum + item.netSpentAmount,
    );
    final double totalRemaining =
        (monthlyTotalIncome - totalNetSpent).clamp(0.0, double.infinity);

    return LayoutBuilder(
      builder: (context, constraints) {
        final bool isMultiColumn = constraints.maxWidth >= 840;

        return SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 24.0),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1280),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Cloud Financial Agent',
                              style: TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.w800,
                                color: AppColors.textPrimary,
                                letterSpacing: 0.3,
                              ),
                            ),
                            SizedBox(height: 4),
                            Text(
                              'Presupuesto Inteligente 50/30/20 • Mes en curso',
                              style: TextStyle(
                                fontSize: 13.5,
                                color: AppColors.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: 'Sincronizar con TrueNAS FastAPI',
                            onPressed: isSyncing ? null : onRefreshSync,
                            icon: isSyncing
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: AppColors.accentOrange,
                                    ),
                                  )
                                : const Icon(
                                    Icons.sync_rounded,
                                    color: AppColors.accentOrange,
                                  ),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: AppColors.surfaceDark,
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(color: AppColors.cardBorder),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.shield_rounded,
                                  size: 16,
                                  color: AppColors.accentOrange,
                                ),
                                SizedBox(width: 6),
                                Text(
                                  'Tailscale Zero-Trust',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.textPrimary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),

                  _HeroBalanceCard(
                    monthlyTotalIncome: monthlyTotalIncome,
                    totalNetSpent: totalNetSpent,
                    totalRemaining: totalRemaining,
                    categories: categories,
                    onQuickVoiceCapture: onNavigateToTransactions,
                  ),
                  const SizedBox(height: 28),

                  const Text(
                    'DESGLOSE PRESUPUESTAL 50 / 30 / 20',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.2,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 14),

                  if (isMultiColumn)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (int i = 0; i < categories.length; i++) ...[
                          Expanded(
                            child: _BudgetCategoryCard(category: categories[i]),
                          ),
                          if (i < categories.length - 1)
                            const SizedBox(width: 18),
                        ],
                      ],
                    )
                  else
                    Column(
                      children: [
                        for (int i = 0; i < categories.length; i++) ...[
                          _BudgetCategoryCard(category: categories[i]),
                          if (i < categories.length - 1)
                            const SizedBox(height: 16),
                        ],
                      ],
                    ),

                  const SizedBox(height: 28),

                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'ÚLTIMOS MOVIMIENTOS (IA Y WEBHOOKS)',
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.2,
                          color: AppColors.textSecondary,
                        ),
                      ),
                      TextButton.icon(
                        onPressed: onNavigateToTransactions,
                        icon: const Icon(
                          Icons.arrow_forward_rounded,
                          size: 18,
                          color: AppColors.accentOrange,
                        ),
                        label: const Text(
                          'Ver todo / Capturar',
                          style: TextStyle(color: AppColors.accentOrange),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Card(
                    child: ListView.separated(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: recentTransactions.length,
                      separatorBuilder: (_, __) => const Divider(
                        height: 1,
                        color: AppColors.cardBorder,
                      ),
                      itemBuilder: (context, index) {
                        return TransactionListTile(
                          record: recentTransactions[index],
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Tarjeta principal de gran formato con bordes redondeados y barra apilada 50/30/20.
class _HeroBalanceCard extends StatelessWidget {
  final double monthlyTotalIncome;
  final double totalNetSpent;
  final double totalRemaining;
  final List<BudgetCategorySummary> categories;
  final VoidCallback onQuickVoiceCapture;

  const _HeroBalanceCard({
    required this.monthlyTotalIncome,
    required this.totalNetSpent,
    required this.totalRemaining,
    required this.categories,
    required this.onQuickVoiceCapture,
  });

  @override
  Widget build(BuildContext context) {
    final double globalRatio = monthlyTotalIncome <= 0
        ? 0.0
        : (totalNetSpent / monthlyTotalIncome).clamp(0.0, 1.0);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(26.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 20,
              runSpacing: 16,
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'SALDO RESTANTE DISPONIBLE',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.1,
                        color: AppColors.accentOrange,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '\$${totalRemaining.toStringAsFixed(2)} MXN',
                      style: const TextStyle(
                        fontSize: 34,
                        fontWeight: FontWeight.w900,
                        color: AppColors.textPrimary,
                        letterSpacing: -0.5,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Gasto neto acumulado: \$${totalNetSpent.toStringAsFixed(2)} de \$${monthlyTotalIncome.toStringAsFixed(2)} MXN (${(globalRatio * 100).toStringAsFixed(1)}%)',
                      style: const TextStyle(
                        fontSize: 13.5,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
                ElevatedButton.icon(
                  onPressed: onQuickVoiceCapture,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.accentOrange,
                    foregroundColor: AppColors.surfaceDark,
                  ),
                  icon: const Icon(Icons.mic_rounded),
                  label: const Text('Capturar con Voz / IA'),
                ),
              ],
            ),
            const SizedBox(height: 26),

            const Text(
              'DISTRIBUCIÓN ACTIVA DE LA REGLA 50% NECESIDADES • 30% GUSTOS • 20% AHORRO',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.9,
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                height: 18,
                child: Row(
                  children: [
                    for (int i = 0; i < categories.length; i++) ...[
                      Expanded(
                        flex: categories[i].targetPercentage,
                        child: Stack(
                          children: [
                            Container(
                              color: categories[i]
                                  .accentColor
                                  .withValues(alpha: 0.22),
                            ),
                            FractionallySizedBox(
                              widthFactor: categories[i].usageRatio,
                              child: Container(
                                color: categories[i].accentColor,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (i < categories.length - 1)
                        const SizedBox(width: 3),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 24,
              runSpacing: 8,
              children: categories.map((cat) {
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: cat.accentColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${cat.targetPercentage}% ${cat.title}: \$${cat.remainingAmount.toStringAsFixed(0)} libres',
                      style: const TextStyle(
                        fontSize: 12.5,
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                );
              }).toList(),
            ),
          ],
        ),
      ),
    );
  }
}

/// Tarjeta individual para cada categoría (50% Necesidades, 30% Gustos, 20% Ahorro).
class _BudgetCategoryCard extends StatelessWidget {
  final BudgetCategorySummary category;

  const _BudgetCategoryCard({required this.category});

  @override
  Widget build(BuildContext context) {
    final Color progressColor = category.isNearOrOverLimit
        ? AppColors.accentRed
        : category.accentColor;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(22.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: category.accentColor.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(
                    category.icon,
                    color: category.accentColor,
                    size: 22,
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceDark,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: category.accentColor.withValues(alpha: 0.5),
                    ),
                  ),
                  child: Text(
                    'Meta ${category.targetPercentage}%',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: category.accentColor,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              category.title,
              style: const TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              category.subtitle,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12.5,
                color: AppColors.textSecondary,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Gasto neto: \$${category.netSpentAmount.toStringAsFixed(2)}',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
                Text(
                  '${(category.usageRatio * 100).toStringAsFixed(0)}%',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: progressColor,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: category.usageRatio,
                minHeight: 10,
                backgroundColor: AppColors.surfaceDark,
                valueColor: AlwaysStoppedAnimation<Color>(progressColor),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Tope: \$${category.allocatedAmount.toStringAsFixed(0)}',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                  ),
                ),
                Text(
                  'Restante: \$${category.remainingAmount.toStringAsFixed(2)}',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: category.accentColor,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

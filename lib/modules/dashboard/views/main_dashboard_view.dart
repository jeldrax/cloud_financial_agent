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

  double get usageRatio => allocatedAmount <= 0
      ? 0.0
      : (netSpentAmount / allocatedAmount).clamp(0.0, 1.0);

  bool get isNearOrOverLimit => usageRatio >= 0.85;
}

/// Vista principal con ruteo adaptativo mediante [LayoutBuilder]:
/// - Pantallas compactas (< 720px): [BottomNavigationBar]
/// - Pantallas medianas/grandes (>= 720px): [NavigationRail]
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
  bool _isBackendOnline = true;

  /// Ingreso mensual base para la distribución 50% / 30% / 20% (sincronizado con SQLite).
  double _monthlyTotalIncome = 2400.00;

  /// Gasto neto mensual reportado directamente por SQLite en el servidor.
  Map<BudgetCategory, double>? _remoteNetSpend;

  /// Historial real de transacciones (100% vacío hasta sincronizar con SQLite; cero datos de prueba).
  final List<TransactionRecord> _transactions = [];

  @override
  void initState() {
    super.initState();
    _syncWithFastApiBackend(silent: true);
  }

  /// Sincroniza presupuesto, gasto neto 50/30/20 y transacciones reales desde FastAPI / SQLite.
  Future<void> _syncWithFastApiBackend({bool silent = false}) async {
    if (_isSyncing) return;
    setState(() => _isSyncing = true);

    try {
      final results = await Future.wait<dynamic>([
        _apiClient.fetchMonthlyBudget(),
        _apiClient.fetchMonthlyNetSpendByCategory(),
        _apiClient.fetchRecentTransactions(limit: 100),
      ]);

      final double remoteBudget = results[0] as double;
      final Map<BudgetCategory, double> netSpend =
          results[1] as Map<BudgetCategory, double>;
      final List<TransactionRecord> remoteTransactions =
          results[2] as List<TransactionRecord>;

      if (!mounted) return;
      setState(() {
        _isBackendOnline = true;
        _monthlyTotalIncome = remoteBudget;
        _remoteNetSpend = netSpend;
        _transactions
          ..clear()
          ..addAll(remoteTransactions);
      });

      if (!silent) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            backgroundColor: AppColors.surface,
            content: Text(
              'Sincronizado correctamente con el servidor vía Tailscale.',
            ),
          ),
        );
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isBackendOnline = false;
      });
      if (!silent) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            backgroundColor: AppColors.accentRed,
            content: Text(
              'No se pudo conectar al servidor. Verifica que Tailscale esté activo.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSyncing = false);
      }
    }
  }

  /// Calcula el gasto neto (`Gastos - Ingresos`) por categoría siguiendo `src/database.py`.
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
          subtitle: 'Fondo de emergencia, inversiones y metas de ahorro',
          allocatedAmount: _monthlyTotalIncome * 0.20,
          netSpentAmount: _netSpentFor(BudgetCategory.ahorro),
        ),
      ];

  Future<void> _onTransactionCreated(TransactionRecord record) async {
    setState(() {
      _remoteNetSpend = null;
      _transactions.insert(0, record);
    });
    await _syncWithFastApiBackend(silent: true);
  }

  Future<void> _onTransactionDeleted(TransactionRecord record) async {
    final int? txId = record.id;
    if (txId == null) return;

    try {
      await _apiClient.deleteTransaction(txId);
      if (!mounted) return;
      setState(() {
        _remoteNetSpend = null;
        _transactions.removeWhere((item) => item.id == txId);
      });
      await _syncWithFastApiBackend(silent: true);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: AppColors.surface,
          content: Text('Movimiento eliminado: "${record.concepto}".'),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: AppColors.accentRed,
          content: Text(
            'No se pudo eliminar el movimiento. Verifica tu conexión Tailscale.',
          ),
        ),
      );
    }
  }

  Future<void> _onMonthlyIncomeUpdated(double newIncome) async {
    setState(() => _monthlyTotalIncome = newIncome);
    await _syncWithFastApiBackend(silent: true);
  }

  @override
  Widget build(BuildContext context) {
    final List<Widget> moduleViews = [
      _DashboardOverviewTab(
        monthlyTotalIncome: _monthlyTotalIncome,
        categories: _budgetCategories,
        recentTransactions: _transactions.take(5).toList(),
        isSyncing: _isSyncing,
        isBackendOnline: _isBackendOnline,
        onRefreshSync: () => _syncWithFastApiBackend(silent: false),
        onNavigateToTransactions: () => setState(() => _selectedIndex = 1),
        onDeleteTransaction: _onTransactionDeleted,
      ),
      TransactionsView(
        transactions: _transactions,
        onTransactionCreated: _onTransactionCreated,
        onTransactionDeleted: _onTransactionDeleted,
      ),
      SettingsView(
        monthlyIncome: _monthlyTotalIncome,
        onMonthlyIncomeChanged: _onMonthlyIncomeUpdated,
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final bool isWideScreen =
            constraints.maxWidth >= _tabletDesktopBreakpoint;
        final bool isExtendedRail =
            constraints.maxWidth >= _extendedRailBreakpoint;

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
                              color:
                                  AppColors.accentOrange.withValues(alpha: 0.16),
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
                                  '100% Manual • Zero-Trust',
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
                        icon: Icon(Icons.add_card_outlined),
                        selectedIcon: Icon(Icons.add_card_rounded),
                        label: Text('Ingresos y Egresos'),
                      ),
                      NavigationRailDestination(
                        icon: Icon(Icons.security_outlined),
                        selectedIcon: Icon(Icons.security_rounded),
                        label: Text('Seguridad y Ajustes'),
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
                  icon: Icon(Icons.add_card_outlined),
                  activeIcon: Icon(Icons.add_card_rounded),
                  label: 'Movimientos',
                ),
                BottomNavigationBarItem(
                  icon: Icon(Icons.security_outlined),
                  activeIcon: Icon(Icons.security_rounded),
                  label: 'Seguridad',
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Módulo `dashboard`: Tarjeta de Balance General, Distribución 50/30/20 y Movimientos Reales.
class _DashboardOverviewTab extends StatelessWidget {
  final double monthlyTotalIncome;
  final List<BudgetCategorySummary> categories;
  final List<TransactionRecord> recentTransactions;
  final bool isSyncing;
  final bool isBackendOnline;
  final VoidCallback onRefreshSync;
  final VoidCallback onNavigateToTransactions;
  final ValueChanged<TransactionRecord> onDeleteTransaction;

  const _DashboardOverviewTab({
    required this.monthlyTotalIncome,
    required this.categories,
    required this.recentTransactions,
    required this.isSyncing,
    required this.isBackendOnline,
    required this.onRefreshSync,
    required this.onNavigateToTransactions,
    required this.onDeleteTransaction,
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
                              'Control Personal 50/30/20 • Sin Conexión Bancaria Externa',
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
                            tooltip: 'Sincronizar con el servidor',
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
                              border: Border.all(
                                color: isBackendOnline
                                    ? AppColors.cardBorder
                                    : AppColors.accentRed,
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  isBackendOnline
                                      ? Icons.shield_rounded
                                      : Icons.cloud_off_rounded,
                                  size: 16,
                                  color: isBackendOnline
                                      ? AppColors.accentOrange
                                      : AppColors.accentRed,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  isBackendOnline
                                      ? 'Tailscale Zero-Trust'
                                      : 'Sin Conexión',
                                  style: const TextStyle(
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
                  if (!isBackendOnline) ...[
                    const SizedBox(height: 16),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: AppColors.accentRed.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: AppColors.accentRed),
                      ),
                      child: const Row(
                        children: [
                          Icon(
                            Icons.warning_amber_rounded,
                            color: AppColors.accentRed,
                          ),
                          SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'No hay conexión activa con tu servidor vía Tailscale. Conéctate a Tailscale y pulsa el icono de sincronizar.',
                              style: TextStyle(
                                color: AppColors.textPrimary,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),

                  _HeroBalanceCard(
                    monthlyTotalIncome: monthlyTotalIncome,
                    totalNetSpent: totalNetSpent,
                    totalRemaining: totalRemaining,
                    categories: categories,
                    onQuickCapture: onNavigateToTransactions,
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
                        'ÚLTIMOS MOVIMIENTOS REGISTRADOS POR TI',
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
                          'Registrar / Ver todo',
                          style: TextStyle(color: AppColors.accentOrange),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Card(
                    child: recentTransactions.isEmpty
                        ? Padding(
                            padding: const EdgeInsets.all(32.0),
                            child: Center(
                              child: Column(
                                children: [
                                  const Icon(
                                    Icons.receipt_long_outlined,
                                    size: 40,
                                    color: AppColors.textSecondary,
                                  ),
                                  const SizedBox(height: 10),
                                  const Text(
                                    'Aún no has registrado ingresos ni egresos.',
                                    style: TextStyle(
                                      color: AppColors.textPrimary,
                                      fontWeight: FontWeight.w700,
                                      fontSize: 14.5,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  const Text(
                                    'Todos los movimientos son 100% manuales (formulario directo, texto o voz).',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: AppColors.textSecondary,
                                      fontSize: 12.5,
                                    ),
                                  ),
                                  const SizedBox(height: 16),
                                  OutlinedButton.icon(
                                    onPressed: onNavigateToTransactions,
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: AppColors.accentOrange,
                                      side: const BorderSide(
                                        color: AppColors.accentOrange,
                                      ),
                                    ),
                                    icon: const Icon(Icons.add_rounded),
                                    label: const Text('Agregar Movimiento'),
                                  ),
                                ],
                              ),
                            ),
                          )
                        : ListView.separated(
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
                                onDelete: onDeleteTransaction,
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
  final VoidCallback onQuickCapture;

  const _HeroBalanceCard({
    required this.monthlyTotalIncome,
    required this.totalNetSpent,
    required this.totalRemaining,
    required this.categories,
    required this.onQuickCapture,
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
                  onPressed: onQuickCapture,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.accentOrange,
                    foregroundColor: AppColors.surfaceDark,
                  ),
                  icon: const Icon(Icons.add_circle_outline_rounded),
                  label: const Text('Registrar Ingreso / Egreso'),
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
                      if (i < categories.length - 1) const SizedBox(width: 3),
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

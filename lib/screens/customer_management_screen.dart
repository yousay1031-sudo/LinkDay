import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/customer.dart';
import '../services/customer_service.dart';
import '../theme/app_theme.dart';
import 'customer_edit_screen.dart';
import 'import_customers_screen.dart';

class CustomerManagementScreen extends StatefulWidget {
  const CustomerManagementScreen({super.key});

  @override
  State<CustomerManagementScreen> createState() =>
      _CustomerManagementScreenState();
}

class _CustomerManagementScreenState extends State<CustomerManagementScreen> {
  final _searchController = TextEditingController();

  List<Customer> _allCustomers = [];
  List<Customer> _filteredCustomers = [];
  List<Customer> _expiringCustomers = [];
  bool _showExpiringOnly = false;

  @override
  void initState() {
    super.initState();
    _loadCustomers();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _loadCustomers() {
    setState(() {
      _allCustomers = CustomerService.instance.getAllCustomers();
      _expiringCustomers =
          CustomerService.instance.getExpiringCertCustomers(daysThreshold: 30);
      _applyFilter();
    });
  }

  void _applyFilter() {
    final query = _searchController.text;
    List<Customer> base;
    if (_showExpiringOnly) {
      base = _expiringCustomers;
    } else if (query.isNotEmpty) {
      base = CustomerService.instance.searchCustomers(query);
    } else {
      base = _allCustomers;
    }
    _filteredCustomers = base;
  }

  void _onSearchChanged(String value) {
    setState(() {
      _showExpiringOnly = false;
      _applyFilter();
    });
  }

  void _onExpiringAlertTapped() {
    setState(() {
      _showExpiringOnly = !_showExpiringOnly;
      if (_showExpiringOnly) {
        _searchController.clear();
      }
      _applyFilter();
    });
  }

  Future<void> _navigateToEdit({Customer? customer}) async {
    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => CustomerEditScreen(customer: customer),
      ),
    );
    if (result == true) {
      _loadCustomers();
    }
  }

  Future<void> _navigateToImport() async {
    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const ImportCustomersScreen()),
    );
    if (result == true) {
      _loadCustomers();
    }
  }

  // ── グリッド列数 ────────────────────────────────────────────────────

  int _getColumnCount(double width) {
    if (width >= 1280) return 4;
    if (width >= 900) return 3;
    if (width >= 600) return 2;
    return 1;
  }

  double _getChildAspectRatio(int cols) {
    switch (cols) {
      case 4:
        return 1.3;
      case 3:
        return 1.25;
      case 2:
        return 1.2;
      default:
        return 2.5;
    }
  }

  // ── ビルド ──────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _buildAppBar(),
      body: Column(
        children: [
          _buildSearchBar(),
          if (_expiringCustomers.isNotEmpty) _buildExpiringAlert(),
          Expanded(child: _buildBody()),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _navigateToEdit(),
        icon: const Icon(Icons.person_add),
        label: const Text('新規登録'),
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      title: const Text('顧客管理'),
      actions: [
        IconButton(
          icon: const Icon(Icons.upload_file),
          tooltip: 'Excel一括インポート',
          onPressed: _navigateToImport,
        ),
        IconButton(
          icon: const Icon(Icons.person_add),
          tooltip: '新規登録',
          onPressed: () => _navigateToEdit(),
        ),
        const SizedBox(width: 4),
      ],
    );
  }

  Widget _buildSearchBar() {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: TextField(
        controller: _searchController,
        onChanged: _onSearchChanged,
        decoration: InputDecoration(
          prefixIcon: const Icon(Icons.search, color: AppColors.onSurfaceVariant),
          hintText: '氏名・ふりがな・電話番号で検索',
          suffixIcon: _searchController.text.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.clear, size: 18),
                  onPressed: () {
                    _searchController.clear();
                    _onSearchChanged('');
                  },
                )
              : null,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        ),
      ),
    );
  }

  Widget _buildExpiringAlert() {
    final count = _expiringCustomers.length;
    return GestureDetector(
      onTap: _onExpiringAlertTapped,
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        decoration: BoxDecoration(
          color: const Color(0xFFFFEBEE),
          borderRadius: BorderRadius.circular(8),
          border: Border(
            left: BorderSide(
              color: _showExpiringOnly ? AppColors.error : const Color(0xFFE53935),
              width: 4,
            ),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              const Icon(Icons.warning_amber_rounded,
                  color: AppColors.error, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '受給者証の期限が近い顧客が $count 名います',
                  style: const TextStyle(
                    color: AppColors.error,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                _showExpiringOnly ? '全員表示' : '絞り込む',
                style: const TextStyle(
                  color: AppColors.error,
                  fontSize: 12,
                  decoration: TextDecoration.underline,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_allCustomers.isEmpty) {
      return _buildEmptyState();
    }
    if (_filteredCustomers.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.search_off,
                size: 64, color: AppColors.onSurfaceVariant),
            const SizedBox(height: 16),
            Text(
              '「${_searchController.text}」に一致する顧客が見つかりません',
              style: const TextStyle(color: AppColors.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final cols = _getColumnCount(constraints.maxWidth);
        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cols,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            childAspectRatio: _getChildAspectRatio(cols),
          ),
          itemCount: _filteredCustomers.length,
          itemBuilder: (context, index) {
            return _buildCustomerCard(_filteredCustomers[index], cols);
          },
        );
      },
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.people_outline,
                size: 80, color: AppColors.onSurfaceVariant),
            const SizedBox(height: 20),
            const Text(
              '顧客がまだ登録されていません',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: AppColors.onSurface,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Excelで一括登録するか、\n新規登録ボタンから追加してください',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: AppColors.onSurfaceVariant,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 32),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                OutlinedButton.icon(
                  onPressed: _navigateToImport,
                  icon: const Icon(Icons.upload_file),
                  label: const Text('Excel一括登録'),
                ),
                const SizedBox(width: 12),
                ElevatedButton.icon(
                  onPressed: () => _navigateToEdit(),
                  icon: const Icon(Icons.person_add),
                  label: const Text('新規登録'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCustomerCard(Customer customer, int columnCount) {
    final remaining = customer.remainingDays;
    final certDays = customer.certExpiryDaysLeft;

    // 利用残日数バッジの色
    Color remainingColor;
    if (remaining >= 5) {
      remainingColor = AppColors.secondary;
    } else if (remaining >= 1) {
      remainingColor = AppColors.warning;
    } else {
      remainingColor = AppColors.error;
    }

    // 受給者証期限の色
    Color certColor;
    if (certDays == null) {
      certColor = AppColors.onSurfaceVariant;
    } else if (certDays <= 30) {
      certColor = AppColors.error;
    } else if (certDays <= 60) {
      certColor = AppColors.warning;
    } else {
      certColor = AppColors.onSurfaceVariant;
    }

    final isHorizontal = columnCount == 1;

    return Card(
      child: InkWell(
        onTap: () => _navigateToEdit(customer: customer),
        borderRadius: BorderRadius.circular(AppTheme.cardBorderRadius),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: isHorizontal
              ? _buildCardHorizontal(
                  customer, remaining, remainingColor, certDays, certColor)
              : _buildCardVertical(
                  customer, remaining, remainingColor, certDays, certColor),
        ),
      ),
    );
  }

  Widget _buildCardVertical(
    Customer customer,
    int remaining,
    Color remainingColor,
    int? certDays,
    Color certColor,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // 氏名
        Text(
          customer.name,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: AppColors.onSurface,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 2),
        // ふりがな
        Text(
          customer.nameKana,
          style: const TextStyle(
            fontSize: 11,
            color: AppColors.onSurfaceVariant,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 6),
        // 定期利用曜日
        if (customer.regularDays.isNotEmpty)
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: customer.regularDayLabels
                .map((d) => _buildDayChip(d))
                .toList(),
          ),
        const Spacer(),
        // 下段: 今月利用 & 受給者証期限
        Row(
          children: [
            _buildUsageBadge(
                customer.currentMonthUsedDays,
                customer.monthlyAvailableDays,
                remaining,
                remainingColor),
            const Spacer(),
            if (certDays != null)
              _buildCertBadge(certDays, certColor),
          ],
        ),
      ],
    );
  }

  Widget _buildCardHorizontal(
    Customer customer,
    int remaining,
    Color remainingColor,
    int? certDays,
    Color certColor,
  ) {
    return Row(
      children: [
        // アバター
        CircleAvatar(
          radius: 24,
          backgroundColor: AppColors.primary.withValues(alpha: 0.15),
          child: Text(
            customer.name.isNotEmpty ? customer.name[0] : '?',
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: AppColors.primary,
            ),
          ),
        ),
        const SizedBox(width: 12),
        // 氏名・ふりがな
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                customer.name,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: AppColors.onSurface,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                customer.nameKana,
                style: const TextStyle(
                  fontSize: 11,
                  color: AppColors.onSurfaceVariant,
                ),
              ),
              if (customer.regularDays.isNotEmpty)
                Text(
                  customer.regularDayLabels.join('・'),
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.secondary,
                  ),
                ),
            ],
          ),
        ),
        // バッジ
        Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            _buildUsageBadge(
                customer.currentMonthUsedDays,
                customer.monthlyAvailableDays,
                remaining,
                remainingColor),
            if (certDays != null) ...[
              const SizedBox(height: 4),
              _buildCertBadge(certDays, certColor),
            ],
          ],
        ),
        const SizedBox(width: 4),
        const Icon(Icons.chevron_right,
            color: AppColors.onSurfaceVariant, size: 20),
      ],
    );
  }

  Widget _buildDayChip(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.secondary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 10,
          color: AppColors.secondary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _buildUsageBadge(
      int used, int total, int remaining, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        '今月 $used/$total 日',
        style: TextStyle(
          fontSize: 11,
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _buildCertBadge(int days, Color color) {
    String label;
    if (days < 0) {
      label = '期限切れ';
    } else if (days == 0) {
      label = '本日期限';
    } else {
      label = '残$days日';
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (days <= 30)
          Icon(Icons.warning_amber_rounded, size: 12, color: color),
        if (days <= 30) const SizedBox(width: 2),
        Text(
          label,
          style: TextStyle(
            fontSize: 10,
            color: color,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

/// 今日の日付をフォーマットするユーティリティ（顧客カードから使用）
String formatDate(DateTime? date) {
  if (date == null) return '—';
  return DateFormat('yyyy/MM/dd').format(date);
}

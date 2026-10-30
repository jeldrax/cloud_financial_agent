import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../modules/transactions/models/transaction_model.dart';
import '../config/env.dart';

/// Resultado de diagnóstico de conectividad sobre la malla privada Tailscale.
class TailscaleHealthStatus {
  final bool isOnline;
  final int latencyMs;
  final String statusMessage;

  const TailscaleHealthStatus({
    required this.isOnline,
    required this.latencyMs,
    required this.statusMessage,
  });
}

/// Cliente HTTP Zero-Trust para comunicarse exclusivamente con FastAPI vía Tailscale.
///
/// Extrae la URL base y el token de las variables ofuscadas [Env] (`Env.apiUrl` y `Env.apiToken`),
/// sin conexiones bancarias de terceros ni telemetría externa.
class ApiClient {
  static const int maxPromptLength = 500;
  final http.Client _httpClient;

  ApiClient({http.Client? httpClient})
      : _httpClient = httpClient ?? http.Client();

  Uri _buildUri(String endpointPath) {
    final String base = Env.apiUrl.endsWith('/')
        ? Env.apiUrl.substring(0, Env.apiUrl.length - 1)
        : Env.apiUrl;
    final String normalizedPath =
        endpointPath.startsWith('/') ? endpointPath : '/$endpointPath';
    return Uri.parse('$base$normalizedPath');
  }

  Map<String, String> get _authHeaders => {
        HttpHeaders.authorizationHeader: 'Bearer ${Env.apiToken}',
        HttpHeaders.contentTypeHeader: 'application/json; charset=utf-8',
        HttpHeaders.acceptHeader: 'application/json',
      };

  /// Registra un Gasto o Ingreso de forma 100% manual y determinista en SQLite (`POST /api/v1/transactions/manual`).
  Future<TransactionRecord> createManualTransaction({
    required double monto,
    required String concepto,
    required BudgetCategory categoria,
    required TransactionType tipo,
    required String metodoPago,
  }) async {
    final uri = _buildUri('/api/v1/transactions/manual');
    final response = await _httpClient
        .post(
          uri,
          headers: _authHeaders,
          body: jsonEncode({
            'monto': monto,
            'concepto': concepto.trim(),
            'categoria': categoria.backendValue,
            'tipo': tipo.backendValue,
            'metodo_pago': metodoPago.trim(),
          }),
        )
        .timeout(const Duration(seconds: 12));

    if (response.statusCode >= 200 && response.statusCode < 300) {
      final Map<String, dynamic> data =
          jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      return TransactionRecord.fromJson(
        data,
        defaultSource: IngestionSource.manualForm,
      );
    }

    throw HttpException(
      'Error HTTP ${response.statusCode} al registrar movimiento manual',
      uri: uri,
    );
  }

  /// Elimina una transacción registrada por su ID (`DELETE /api/v1/transactions/{id}`).
  Future<void> deleteTransaction(int id) async {
    final uri = _buildUri('/api/v1/transactions/$id');
    final response = await _httpClient
        .delete(uri, headers: _authHeaders)
        .timeout(const Duration(seconds: 10));

    if (response.statusCode >= 200 && response.statusCode < 300) {
      return;
    }

    throw HttpException(
      'Error HTTP ${response.statusCode} al eliminar movimiento',
      uri: uri,
    );
  }

  /// Envía texto escrito por el usuario a FastAPI para extracción segura con Gemini (`POST /api/v1/transactions/ingest-text`).
  Future<TransactionRecord> ingestNaturalLanguageText(String rawText) async {
    final String trimmed = rawText.trim();
    final String bounded = trimmed.length > maxPromptLength
        ? trimmed.substring(0, maxPromptLength)
        : trimmed;

    final uri = _buildUri('/api/v1/transactions/ingest-text');
    final response = await _httpClient
        .post(
          uri,
          headers: _authHeaders,
          body: jsonEncode({'texto': bounded}),
        )
        .timeout(const Duration(seconds: 20));

    if (response.statusCode >= 200 && response.statusCode < 300) {
      final Map<String, dynamic> data =
          jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      return TransactionRecord.fromJson(
        data,
        defaultSource: IngestionSource.textAi,
      );
    }

    String detail = 'Error HTTP ${response.statusCode} al procesar texto con IA';
    try {
      final Map<String, dynamic> err =
          jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      if (err['detail'] != null) {
        detail = err['detail'].toString();
      }
    } catch (_) {}

    throw HttpException(detail, uri: uri);
  }

  /// Envía una nota de voz dictada por el usuario a FastAPI (`POST /api/v1/transactions/ingest-voice`).
  Future<TransactionRecord> ingestVoiceNote({
    required String audioFilePath,
    String mimeType = 'audio/m4a',
  }) async {
    final uri = _buildUri('/api/v1/transactions/ingest-voice');
    final request = http.MultipartRequest('POST', uri)
      ..headers[HttpHeaders.authorizationHeader] = 'Bearer ${Env.apiToken}'
      ..headers[HttpHeaders.acceptHeader] = 'application/json'
      ..fields['mime_type'] = mimeType
      ..files.add(await http.MultipartFile.fromPath('audio', audioFilePath));

    final streamedResponse =
        await _httpClient.send(request).timeout(const Duration(seconds: 30));
    final response = await http.Response.fromStream(streamedResponse);

    if (response.statusCode >= 200 && response.statusCode < 300) {
      final Map<String, dynamic> data =
          jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      return TransactionRecord.fromJson(
        data,
        defaultSource: IngestionSource.voiceAi,
      );
    }

    throw HttpException(
      'Error HTTP ${response.statusCode} al procesar nota de voz con IA',
      uri: uri,
    );
  }

  /// Obtiene el presupuesto base mensual persistido en SQLite (`GET /api/v1/budget`).
  Future<double> fetchMonthlyBudget() async {
    final uri = _buildUri('/api/v1/budget');
    final response = await _httpClient
        .get(uri, headers: _authHeaders)
        .timeout(const Duration(seconds: 10));

    if (response.statusCode >= 200 && response.statusCode < 300) {
      final Map<String, dynamic> data =
          jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      return (data['monthly_income'] as num?)?.toDouble() ?? 2400.0;
    }

    throw HttpException(
      'Error HTTP ${response.statusCode} al consultar presupuesto mensual',
      uri: uri,
    );
  }

  /// Actualiza el presupuesto base mensual en SQLite (`PUT /api/v1/budget`).
  Future<double> updateMonthlyBudget(double monthlyIncome) async {
    final uri = _buildUri('/api/v1/budget');
    final response = await _httpClient
        .put(
          uri,
          headers: _authHeaders,
          body: jsonEncode({'monthly_income': monthlyIncome}),
        )
        .timeout(const Duration(seconds: 10));

    if (response.statusCode >= 200 && response.statusCode < 300) {
      final Map<String, dynamic> data =
          jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      return (data['monthly_income'] as num?)?.toDouble() ?? monthlyIncome;
    }

    throw HttpException(
      'Error HTTP ${response.statusCode} al guardar presupuesto mensual',
      uri: uri,
    );
  }

  /// Obtiene el gasto neto mensual agrupado por categoría (`GET /api/v1/dashboard/net-spend`).
  Future<Map<BudgetCategory, double>> fetchMonthlyNetSpendByCategory() async {
    final uri = _buildUri('/api/v1/dashboard/net-spend');
    final response = await _httpClient
        .get(uri, headers: _authHeaders)
        .timeout(const Duration(seconds: 10));

    if (response.statusCode >= 200 && response.statusCode < 300) {
      final Map<String, dynamic> raw =
          jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      return {
        BudgetCategory.necesidades:
            (raw['Necesidades'] as num?)?.toDouble() ?? 0.0,
        BudgetCategory.gustos: (raw['Gustos'] as num?)?.toDouble() ?? 0.0,
        BudgetCategory.ahorro: (raw['Ahorro'] as num?)?.toDouble() ?? 0.0,
      };
    }

    throw HttpException(
      'Error HTTP ${response.statusCode} al consultar balance 50/30/20',
      uri: uri,
    );
  }

  /// Obtiene el listado real de transacciones almacenadas en SQLite (`GET /api/v1/transactions`).
  Future<List<TransactionRecord>> fetchRecentTransactions({
    int limit = 50,
  }) async {
    final uri = _buildUri('/api/v1/transactions?limite=$limit');
    final response = await _httpClient
        .get(uri, headers: _authHeaders)
        .timeout(const Duration(seconds: 10));

    if (response.statusCode >= 200 && response.statusCode < 300) {
      final List<dynamic> items =
          jsonDecode(utf8.decode(response.bodyBytes)) as List<dynamic>;
      return items
          .map(
            (e) => TransactionRecord.fromJson(e as Map<String, dynamic>),
          )
          .toList();
    }

    throw HttpException(
      'Error HTTP ${response.statusCode} al listar transacciones',
      uri: uri,
    );
  }

  /// Verifica la conectividad y latencia del túnel Tailscale contra el servidor FastAPI.
  Future<TailscaleHealthStatus> checkTailscaleHealth() async {
    final stopwatch = Stopwatch()..start();
    try {
      final uri = _buildUri('/api/v1/health');
      final response = await _httpClient
          .get(uri, headers: _authHeaders)
          .timeout(const Duration(seconds: 6));
      stopwatch.stop();

      final bool ok = response.statusCode >= 200 && response.statusCode < 300;
      return TailscaleHealthStatus(
        isOnline: ok,
        latencyMs: stopwatch.elapsedMilliseconds,
        statusMessage: ok
            ? 'Túnel Tailscale activo • Servidor FastAPI operativo (${stopwatch.elapsedMilliseconds} ms)'
            : 'Servidor respondió con código HTTP ${response.statusCode}',
      );
    } catch (_) {
      stopwatch.stop();
      return TailscaleHealthStatus(
        isOnline: false,
        latencyMs: stopwatch.elapsedMilliseconds,
        statusMessage:
            'Sin respuesta del servidor. Verifica que Tailscale esté activo.',
      );
    }
  }
}

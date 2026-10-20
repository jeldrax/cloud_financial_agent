import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../modules/transactions/models/transaction_model.dart';
import '../config/env.dart';

/// Resultado de diagnóstico de conectividad sobre la malla Tailscale.
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

/// Cliente HTTP Zero-Trust para comunicarse con FastAPI (TrueNAS) vía Tailscale.
///
/// Extrae la URL base y el token exclusivamente de la clase ofuscada [Env]
/// (`Env.apiUrl` y `Env.apiToken`), garantizando cero IPs o secretos quemados.
class ApiClient {
  final http.Client _httpClient;

  ApiClient({http.Client? httpClient})
      : _httpClient = httpClient ?? http.Client();

  /// Construye un [Uri] seguro combinando [Env.apiUrl] con el path del endpoint.
  Uri _buildUri(String endpointPath) {
    final String base = Env.apiUrl.endsWith('/')
        ? Env.apiUrl.substring(0, Env.apiUrl.length - 1)
        : Env.apiUrl;
    final String normalizedPath =
        endpointPath.startsWith('/') ? endpointPath : '/$endpointPath';
    return Uri.parse('$base$normalizedPath');
  }

  /// Cabeceras Zero-Trust autenticadas con [Env.apiToken].
  Map<String, String> get _authHeaders => {
        HttpHeaders.authorizationHeader: 'Bearer ${Env.apiToken}',
        HttpHeaders.contentTypeHeader: 'application/json; charset=utf-8',
        HttpHeaders.acceptHeader: 'application/json',
      };

  /// Envía texto en lenguaje natural a FastAPI para extracción con Gemini 50/30/20 (`procesar_texto_ia`).
  Future<TransactionRecord> ingestNaturalLanguageText(String rawText) async {
    final uri = _buildUri('/api/v1/transactions/ingest-text');
    final response = await _httpClient
        .post(
          uri,
          headers: _authHeaders,
          body: jsonEncode({'texto': rawText.trim()}),
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

    throw HttpException(
      'Error HTTP ${response.statusCode} al procesar texto con Gemini',
      uri: uri,
    );
  }

  /// Envía una nota de voz grabada directamente ("Plug & Play" estilo MonAi)
  /// hacia FastAPI (`procesar_multimodal_ia`) mediante `MultipartRequest`.
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
      'Error HTTP ${response.statusCode} al procesar nota de voz con Gemini',
      uri: uri,
    );
  }

  /// Envía una notificación bancaria interceptada en el S23 Ultra vía Webhook a FastAPI.
  /// Incluye `identificador_externo` único para deduplicación en SQLite (`transaccion_existe`).
  Future<TransactionRecord> dispatchBankNotificationWebhook({
    required String packageName,
    required String notificationTitle,
    required String notificationBody,
    required String externalId,
    required DateTime receivedAt,
  }) async {
    final uri = _buildUri('/api/v1/webhooks/bank-notification');
    final response = await _httpClient
        .post(
          uri,
          headers: _authHeaders,
          body: jsonEncode({
            'package_name': packageName,
            'title': notificationTitle,
            'body': notificationBody,
            'identificador_externo': externalId,
            'timestamp': receivedAt.toIso8601String(),
          }),
        )
        .timeout(const Duration(seconds: 15));

    if (response.statusCode >= 200 && response.statusCode < 300) {
      final Map<String, dynamic> data =
          jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      return TransactionRecord.fromJson(
        data,
        defaultSource: IngestionSource.bankWebhook,
      );
    }

    throw HttpException(
      'Error HTTP ${response.statusCode} en el Webhook bancario',
      uri: uri,
    );
  }

  /// Obtiene el gasto neto mensual agrupado por categoría (`obtener_gasto_neto_mes`).
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

  /// Obtiene el listado de transacciones recientes almacenadas en SQLite (`GET /api/v1/transactions`).
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

  /// Verifica la conectividad y latencia del túnel Tailscale contra el contenedor en TrueNAS.
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
            ? 'Túnel Tailscale activo • FastAPI TrueNAS operativo (${stopwatch.elapsedMilliseconds} ms)'
            : 'Servidor respondió con código HTTP ${response.statusCode}',
      );
    } catch (_) {
      stopwatch.stop();
      return TailscaleHealthStatus(
        isOnline: false,
        latencyMs: stopwatch.elapsedMilliseconds,
        statusMessage:
            'Sin respuesta del nodo TrueNAS. Verifica que Tailscale esté conectado.',
      );
    }
  }

  /// Ejecuta el diagnóstico en vivo de Gmail IMAP y la etiqueta `Banca_Agente` (`GET /api/v1/diagnostics/imap`).
  Future<Map<String, dynamic>> fetchGmailImapDiagnostics() async {
    final uri = _buildUri('/api/v1/diagnostics/imap');
    final response = await _httpClient
        .get(uri, headers: _authHeaders)
        .timeout(const Duration(seconds: 15));

    if (response.statusCode >= 200 && response.statusCode < 300) {
      return jsonDecode(utf8.decode(response.bodyBytes))
          as Map<String, dynamic>;
    }

    throw HttpException(
      'Error HTTP ${response.statusCode} al diagnosticar Gmail IMAP',
      uri: uri,
    );
  }
}

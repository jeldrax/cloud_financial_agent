import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../../core/network/api_client.dart';
import '../models/transaction_model.dart';

/// Paquetes de aplicaciones bancarias autorizadas en el S23 Ultra para Scraping de notificaciones.
abstract final class SupportedBankingApps {
  static const Map<String, String> allowedPackages = {
    'com.nu.production': 'Tarjeta Nu México',
    'com.mercadopago.wallet': 'Mercado Pago',
    'com.bbva.bbvacontigo': 'BBVA México',
    'com.banorte.movil': 'Banorte Móvil',
    'mx.bancosantander.supermovil': 'Santander',
  };
}

/// Servicio autónomo de Scraping, Parsing preliminar y envío de Webhooks bancarios.
///
/// Intercepta las notificaciones financieras del celular (S23 Ultra), filtra publicidad,
/// genera un `identificador_externo` SHA-256 determinista para evitar duplicidad en SQLite
/// y lo envía al backend FastAPI usando [ApiClient] (`Env.apiUrl` y `Env.apiToken`).
class BankNotificationWebhookService {
  final ApiClient _apiClient;

  /// Expresión regular para verificar que la notificación contenga un monto monetario
  /// y descartar notificaciones promocionales o informativas sin impacto en el 50/30/20.
  static final RegExp _monetaryPattern = RegExp(
    r'(\$\s?\d+(?:,\d{3})*(?:\.\d{1,2})?|\b(?:compra|cargo|pago|transferencia|retiro|reembolso|abono)\b)',
    caseSensitive: false,
  );

  BankNotificationWebhookService({required ApiClient apiClient})
      : _apiClient = apiClient;

  /// Evalúa si la notificación proviene de una app bancaria autorizada y contiene datos transaccionales.
  bool shouldInterceptNotification({
    required String packageName,
    required String title,
    required String body,
  }) {
    if (!SupportedBankingApps.allowedPackages.containsKey(packageName)) {
      return false;
    }
    final String combined = '$title $body'.trim();
    return _monetaryPattern.hasMatch(combined);
  }

  /// Genera un hash único (`WH-<sha256_16>`) compatible con `transaccion_existe(identificador_externo)`
  /// en `src/database.py` para garantizar idempotencia ante reintentos de red en Tailscale.
  String buildExternalDeduplicationId({
    required String packageName,
    required String title,
    required String body,
    required DateTime timestamp,
  }) {
    // Agrupa por ventana de minuto para evitar duplicados si Android re-emite la misma alerta
    final String minuteBucket =
        '${timestamp.year}-${timestamp.month}-${timestamp.day}-${timestamp.hour}-${timestamp.minute}';
    final String rawPayload = '$packageName|$title|$body|$minuteBucket';
    final Digest digest = sha256.convert(utf8.encode(rawPayload));
    return 'WH-${digest.toString().substring(0, 16).toUpperCase()}';
  }

  /// Procesa una notificación bancaria interceptada y la despacha vía Webhook hacia TrueNAS.
  Future<TransactionRecord?> processAndSendWebhook({
    required String packageName,
    required String title,
    required String body,
    DateTime? receivedAt,
  }) async {
    if (!shouldInterceptNotification(
      packageName: packageName,
      title: title,
      body: body,
    )) {
      return null;
    }

    final DateTime timestamp = receivedAt ?? DateTime.now();
    final String externalId = buildExternalDeduplicationId(
      packageName: packageName,
      title: title,
      body: body,
      timestamp: timestamp,
    );

    final String bankLabel =
        SupportedBankingApps.allowedPackages[packageName] ?? packageName;

    return _apiClient.dispatchBankNotificationWebhook(
      packageName: packageName,
      notificationTitle: '[$bankLabel] $title',
      notificationBody: body,
      externalId: externalId,
      receivedAt: timestamp,
    );
  }
}

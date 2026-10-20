import 'package:envied/envied.dart';

part 'env.env.g.dart';

/// Configuración Zero-Trust de variables de entorno ofuscadas mediante `envied`.
///
/// NUNCA quemar IPs de Tailscale, puertos de TrueNAS ni tokens en el código fuente.
/// Generar el archivo ofuscado ejecutando:
/// `dart run build_runner build --delete-conflicting-outputs`
@Envied(path: '.env', obfuscate: true)
abstract class Env {
  /// URL base de la API REST (FastAPI en TrueNAS accesible vía Tailscale).
  @EnviedField(varName: 'API_URL', obfuscate: true)
  static final String apiUrl = _Env.apiUrl;

  /// Token Bearer / Webhook Secret para autenticar peticiones hacia el backend.
  @EnviedField(varName: 'API_TOKEN', obfuscate: true)
  static final String apiToken = _Env.apiToken;
}

import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

/// Servicio multiplataforma de grabación directa de voz ("Plug & Play" estilo MonAi).
///
/// Soporta Android (S23 Ultra / Galaxy Tab S7 FE) y Linux Desktop (CachyOS PipeWire/ALSA).
/// Los archivos de audio se guardan temporalmente y se destruyen tras ser enviados a Gemini.
class VoiceRecorderService {
  final AudioRecorder _audioRecorder = AudioRecorder();
  String? _activeRecordingPath;

  /// Verifica permisos del micrófono e inicia la grabación en formato AAC/M4A ligero.
  Future<bool> startRecording() async {
    final bool hasPermission = await _audioRecorder.hasPermission();
    if (!hasPermission) {
      return false;
    }

    final Directory tempDir = await getTemporaryDirectory();
    final String timestamp = DateTime.now().millisecondsSinceEpoch.toString();
    _activeRecordingPath = '${tempDir.path}/hermes_voice_$timestamp.m4a';

    const config = RecordConfig(
      encoder: AudioEncoder.aacLc,
      bitRate: 64000,
      sampleRate: 24000,
      numChannels: 1,
    );

    await _audioRecorder.start(config, path: _activeRecordingPath!);
    return true;
  }

  /// Detiene la grabación activa y devuelve la ruta local del archivo para enviarlo a FastAPI.
  Future<String?> stopRecording() async {
    final String? recordedPath = await _audioRecorder.stop();
    return recordedPath ?? _activeRecordingPath;
  }

  /// Elimina de forma segura el archivo temporal de audio una vez procesado por Gemini.
  Future<void> purgeTemporaryAudio(String? filePath) async {
    if (filePath == null) return;
    try {
      final file = File(filePath);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {
      // Ignorar si el sistema operativo ya limpió el directorio temporal
    } finally {
      if (_activeRecordingPath == filePath) {
        _activeRecordingPath = null;
      }
    }
  }

  Future<void> dispose() async {
    await _audioRecorder.dispose();
  }
}

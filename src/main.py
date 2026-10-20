import sys
import os
import logging
import threading
from dotenv import load_dotenv

# Asegurar que el directorio raíz del proyecto esté en sys.path
DIRECTORIO_RAIZ = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
if DIRECTORIO_RAIZ not in sys.path:
    sys.path.insert(0, DIRECTORIO_RAIZ)

# Cargar variables de entorno desde .env ubicado en la raíz
load_dotenv(os.path.join(DIRECTORIO_RAIZ, ".env"))

import uvicorn
from src.database import init_db
from src.tg_bot import iniciar_bot
from src.api import app as fastapi_app


def _iniciar_servidor_fastapi(host: str, port: int, logger: logging.Logger):
    """Ejecuta el servidor REST FastAPI con Uvicorn para clientes Flutter en Tailscale."""
    logger.info(f"Iniciando servidor FastAPI Zero-Trust en {host}:{port}...")
    config = uvicorn.Config(
        fastapi_app,
        host=host,
        port=port,
        log_level="info",
        access_log=False,
    )
    server = uvicorn.Server(config)
    server.run()


def main():
    logging.basicConfig(
        format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
        level=logging.INFO
    )
    logger = logging.getLogger("HermesFinanciero")
    logger.info("Iniciando Agente Financiero Autónomo (FastAPI + Telegram Bot)...")

    # 1. Asegurar esquema de base de datos
    try:
        init_db()
        logger.info("Base de datos SQLite inicializada correctamente.")
    except Exception as e:
        logger.critical(f"Error crítico al inicializar la base de datos: {e}", exc_info=True)
        sys.exit(1)

    api_host = os.getenv("API_HOST", "0.0.0.0")
    api_port = int(os.getenv("API_PORT", "8000"))

    # 2. Si hay credenciales de Telegram, levantar FastAPI en un hilo demonio y el bot en el hilo principal.
    # Si no hay credenciales de Telegram, mantener FastAPI en el hilo principal.
    tiene_telegram = bool(os.getenv("TELEGRAM_TOKEN")) and int(os.getenv("TELEGRAM_CHAT_ID", "0")) != 0

    try:
        if tiene_telegram:
            hilo_api = threading.Thread(
                target=_iniciar_servidor_fastapi,
                args=(api_host, api_port, logger),
                daemon=True,
                name="FastAPIWorker",
            )
            hilo_api.start()
            iniciar_bot()
        else:
            logger.info("Modo exclusivo API REST activado (sin credenciales de Telegram).")
            _iniciar_servidor_fastapi(api_host, api_port, logger)
    except KeyboardInterrupt:
        logger.info("Agente detenido por el usuario.")
    except Exception as e:
        logger.critical(f"Error fatal en la ejecución del agente: {e}", exc_info=True)
        sys.exit(1)


if __name__ == "__main__":
    main()

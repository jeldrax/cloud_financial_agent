import sys
import logging
from dotenv import load_dotenv

# Cargar variables de entorno desde .env
load_dotenv()

from src.database import init_db
from src.tg_bot import iniciar_bot

def main():
    logging.basicConfig(
        format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
        level=logging.INFO
    )
    logger = logging.getLogger("HermesFinanciero")
    logger.info("Iniciando Agente Financiero Autónomo...")

    # 1. Asegurar esquema de base de datos
    try:
        init_db()
        logger.info("Base de datos SQLite inicializada correctamente.")
    except Exception as e:
        logger.critical(f"Error crítico al inicializar la base de datos: {e}", exc_info=True)
        sys.exit(1)

    # 2. Iniciar el bot y el loop de eventos
    try:
        iniciar_bot()
    except KeyboardInterrupt:
        logger.info("Agente detenido por el usuario.")
    except Exception as e:
        logger.critical(f"Error fatal en la ejecución del agente: {e}", exc_info=True)
        sys.exit(1)

if __name__ == "__main__":
    main()

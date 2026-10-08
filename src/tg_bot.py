import io
import os
import logging
import matplotlib

# Configurar backend headless para entornos sin GUI (Docker / TrueNAS)
matplotlib.use("Agg")
import matplotlib.pyplot as plt

from telegram import Update
from telegram.ext import (
    Application,
    CommandHandler,
    MessageHandler,
    filters,
    ContextTypes,
)

from src.i18n import i18n
from src.ai_engine import procesar_texto_ia
from src.database import insertar_gasto, obtener_gastos_por_categoria, transaccion_existe
from src.mail_parser import extraer_correos

logger = logging.getLogger(__name__)

TELEGRAM_TOKEN = os.getenv("TELEGRAM_TOKEN")
MI_CHAT_ID = int(os.getenv("TELEGRAM_CHAT_ID", "0"))

def _es_usuario_autorizado(update: Update) -> bool:
    """Verifica si el mensaje proviene del chat_id autorizado."""
    if not update.effective_chat:
        return False
    return update.effective_chat.id == MI_CHAT_ID

async def comando_start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Responde al comando /start."""
    if not _es_usuario_autorizado(update):
        return
    await update.message.reply_text(i18n.t("welcome"), parse_mode="Markdown")

async def comando_ayuda(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Responde al comando /ayuda."""
    if not _es_usuario_autorizado(update):
        return
    await update.message.reply_text(i18n.t("help"), parse_mode="Markdown")

async def recibir_gasto(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Escucha mensajes de texto del usuario y los analiza con Gemini."""
    if not _es_usuario_autorizado(update):
        return

    texto_usuario = update.message.text
    if not texto_usuario:
        return

    mensaje_temporal = await update.message.reply_text(i18n.t("processing"))

    datos = procesar_texto_ia(texto_usuario)
    if datos:
        metodo = datos.get("metodo_pago") or "Telegram/Efectivo"
        insertar_gasto(
            monto=datos["monto"],
            concepto=datos["concepto"],
            categoria=datos["categoria"],
            metodo_pago=metodo
        )
        mensaje_exito = i18n.t(
            "expense_saved",
            monto=datos["monto"],
            categoria=datos["categoria"],
            concepto=datos["concepto"],
            metodo_pago=metodo
        )
        await mensaje_temporal.edit_text(mensaje_exito, parse_mode="Markdown")
    else:
        await mensaje_temporal.edit_text(i18n.t("expense_error"))

async def generar_grafico(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Comando /reporte para generar y enviar gráfica de gastos por categoría."""
    if not _es_usuario_autorizado(update):
        return

    datos = obtener_gastos_por_categoria()
    if not datos:
        await update.message.reply_text(i18n.t("report_empty"))
        return

    categorias = [fila[0] for fila in datos]
    montos = [fila[1] for fila in datos]

    # Generación del gráfico en memoria
    fig, ax = plt.subplots(figsize=(7, 7))
    ax.pie(montos, labels=categorias, autopct="%1.1f%%", startangle=140)
    ax.set_title(i18n.t("report_title", "Distribución de Gastos por Categoría"), fontsize=14, weight="bold")
    plt.tight_layout()

    buf = io.BytesIO()
    plt.savefig(buf, format="png", dpi=150)
    plt.close(fig)
    buf.seek(0)

    await context.bot.send_photo(chat_id=MI_CHAT_ID, photo=buf)

async def tarea_revisar_correos(context: ContextTypes.DEFAULT_TYPE):
    """Tarea periódica de fondo para leer correos bancarios y procesarlos con IA."""
    if MI_CHAT_ID == 0:
        return

    try:
        correos = extraer_correos(marcar_leidos=True)
        for correo in correos:
            identificador = correo["id"]
            if transaccion_existe(identificador):
                continue

            datos = procesar_texto_ia(correo["texto_completo"])
            if datos:
                metodo = datos.get("metodo_pago") or "Banca / Correo"
                insertado = insertar_gasto(
                    monto=datos["monto"],
                    concepto=datos["concepto"],
                    categoria=datos["categoria"],
                    metodo_pago=metodo,
                    identificador_externo=identificador
                )
                if insertado:
                    mensaje = i18n.t(
                        "expense_email_saved",
                        monto=datos["monto"],
                        categoria=datos["categoria"],
                        concepto=datos["concepto"],
                        metodo_pago=metodo
                    )
                    await context.bot.send_message(
                        chat_id=MI_CHAT_ID,
                        text=mensaje,
                        parse_mode="Markdown"
                    )
    except Exception as e:
        logger.error(f"Error en tarea periódica de correos: {e}", exc_info=True)

def iniciar_bot():
    """Configura y arranca el bot de Telegram junto con tareas periódicas."""
    if not TELEGRAM_TOKEN or MI_CHAT_ID == 0:
        logger.error("Faltan credenciales de Telegram (TELEGRAM_TOKEN o TELEGRAM_CHAT_ID) en .env")
        print("❌ Error: Debes configurar TELEGRAM_TOKEN y TELEGRAM_CHAT_ID en tu archivo .env")
        return

    app = Application.builder().token(TELEGRAM_TOKEN).build()

    # Comandos y manejadores
    app.add_handler(CommandHandler("start", comando_start))
    app.add_handler(CommandHandler("ayuda", comando_ayuda))
    app.add_handler(CommandHandler("help", comando_ayuda))
    app.add_handler(CommandHandler("reporte", generar_grafico))
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, recibir_gasto))

    # Tarea de fondo para IMAP si están configuradas las credenciales
    if app.job_queue and os.getenv("IMAP_USER") and os.getenv("IMAP_PASSWORD"):
        intervalo_minutos = int(os.getenv("IMAP_CHECK_INTERVAL_MINUTES", "5"))
        app.job_queue.run_repeating(
            tarea_revisar_correos,
            interval=intervalo_minutos * 60,
            first=15
        )
        logger.info(f"Revisión de correos IMAP activada cada {intervalo_minutos} minutos.")
    else:
        logger.info("Revisión de correos IMAP desactivada (faltan credenciales IMAP_USER / IMAP_PASSWORD).")

    print("🤖 Bot de Telegram 'Hermes' iniciado correctamente...")
    app.run_polling()
import logging
import os
import tempfile

import matplotlib

# Configurar backend headless para entornos sin GUI (Docker / TrueNAS)
matplotlib.use("Agg")
import matplotlib.pyplot as plt

from telegram import Update
from telegram.ext import (
    Application,
    CommandHandler,
    ContextTypes,
    MessageHandler,
    filters,
)

from src.ai_engine import (
    MAX_MULTIMODAL_BYTES,
    procesar_multimodal_ia,
    procesar_texto_ia,
)
from src.database import (
    insertar_gasto,
    obtener_gasto_neto_mes,
    obtener_ingreso_mensual,
)
from src.i18n import i18n

logger = logging.getLogger(__name__)

TELEGRAM_TOKEN = os.getenv("TELEGRAM_TOKEN")
MI_CHAT_ID = int(os.getenv("TELEGRAM_CHAT_ID", "0"))


def _es_usuario_autorizado(update: Update) -> bool:
    """Verifica estrictamente que el mensaje provenga del chat_id autorizado."""
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
    """Recibe mensajes de texto manuales del usuario y los clasifica con Gemini."""
    if not _es_usuario_autorizado(update):
        return

    texto_usuario = update.message.text
    if not texto_usuario:
        return

    mensaje_temporal = await update.message.reply_text(i18n.t("processing"))

    datos = procesar_texto_ia(texto_usuario)
    if datos:
        if datos.get("categoria") == "IGNORAR":
            await mensaje_temporal.edit_text(
                "Movimiento interno omitido (no afecta tu presupuesto 50/30/20)."
            )
            return

        metodo = datos.get("metodo_pago") or "Telegram / Manual"
        tipo = datos.get("tipo", "Gasto")
        insertar_gasto(
            monto=datos["monto"],
            concepto=datos["concepto"],
            categoria=datos["categoria"],
            metodo_pago=metodo,
            tipo=tipo,
        )
        encabezado = "Ingreso registrado:" if tipo == "Ingreso" else "Gasto registrado:"
        mensaje_exito = (
            f"{encabezado}\n"
            f"• Monto: ${datos['monto']:,.2f}\n"
            f"• Categoría (50/30/20): {datos['categoria']}\n"
            f"• Concepto: {datos['concepto']}\n"
            f"• Método: {metodo}"
        )
        await mensaje_temporal.edit_text(mensaje_exito)
    else:
        await mensaje_temporal.edit_text(i18n.t("expense_error"))


async def recibir_audio(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Recibe notas de voz enviadas manualmente y las analiza con Gemini."""
    if not _es_usuario_autorizado(update):
        return

    archivo = update.message.voice or update.message.audio
    if not archivo:
        return

    if archivo.file_size and archivo.file_size > MAX_MULTIMODAL_BYTES:
        await update.message.reply_text("El archivo de audio excede el límite de 5 MB.")
        return

    mensaje_temporal = await update.message.reply_text("Procesando nota de voz con IA...")

    try:
        tg_file = await archivo.get_file()
        datos_bytes = bytes(await tg_file.download_as_bytearray())
        mime = getattr(archivo, "mime_type", None) or "audio/ogg"

        datos = procesar_multimodal_ia(datos_bytes, mime_type=mime)
        if datos:
            if datos.get("categoria") == "IGNORAR":
                await mensaje_temporal.edit_text(
                    "Movimiento interno omitido (no afecta tu presupuesto 50/30/20)."
                )
                return

            metodo = datos.get("metodo_pago") or "Voz / Telegram"
            tipo = datos.get("tipo", "Gasto")
            insertar_gasto(
                monto=datos["monto"],
                concepto=datos["concepto"],
                categoria=datos["categoria"],
                metodo_pago=metodo,
                tipo=tipo,
            )
            icono = "*Ingreso registrado:*" if tipo == "Ingreso" else "*Gasto registrado:*"
            mensaje_exito = (
                f"{icono}\n"
                f"- *Monto:* ${datos['monto']:,.2f}\n"
                f"- *Categoría (50/30/20):* {datos['categoria']}\n"
                f"- *Concepto:* {datos['concepto']}\n"
                f"- *Método:* {metodo}"
            )
            await mensaje_temporal.edit_text(mensaje_exito)
        else:
            await mensaje_temporal.edit_text(i18n.t("expense_error"))
    except Exception as e:
        logger.error(f"Error procesando audio: {e}", exc_info=True)
        await mensaje_temporal.edit_text(i18n.t("expense_error"))


async def recibir_foto(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Recibe fotos de tickets enviadas manualmente y las analiza con Gemini."""
    if not _es_usuario_autorizado(update) or not update.message.photo:
        return

    foto = update.message.photo[-1]
    if foto.file_size and foto.file_size > MAX_MULTIMODAL_BYTES:
        await update.message.reply_text("La imagen excede el límite de 5 MB.")
        return

    mensaje_temporal = await update.message.reply_text("Analizando foto del recibo con IA...")

    try:
        tg_file = await foto.get_file()
        datos_bytes = bytes(await tg_file.download_as_bytearray())

        datos = procesar_multimodal_ia(datos_bytes, mime_type="image/jpeg")
        if datos:
            if datos.get("categoria") == "IGNORAR":
                await mensaje_temporal.edit_text(
                    "Movimiento interno omitido (no afecta tu presupuesto 50/30/20)."
                )
                return

            metodo = datos.get("metodo_pago") or "Foto / Ticket"
            tipo = datos.get("tipo", "Gasto")
            insertar_gasto(
                monto=datos["monto"],
                concepto=datos["concepto"],
                categoria=datos["categoria"],
                metodo_pago=metodo,
                tipo=tipo,
            )
            icono = "*Ingreso registrado:*" if tipo == "Ingreso" else "*Gasto registrado:*"
            mensaje_exito = (
                f"{icono}\n"
                f"- *Monto:* ${datos['monto']:,.2f}\n"
                f"- *Categoría (50/30/20):* {datos['categoria']}\n"
                f"- *Concepto:* {datos['concepto']}\n"
                f"- *Método:* {metodo}"
            )
            await mensaje_temporal.edit_text(mensaje_exito)
        else:
            await mensaje_temporal.edit_text(i18n.t("expense_error"))
    except Exception as e:
        logger.error(f"Error procesando foto: {e}", exc_info=True)
        await mensaje_temporal.edit_text(i18n.t("expense_error"))


async def generar_grafico(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Comando /reporte para generar barra horizontal apilada con balance neto 50/30/20."""
    if not _es_usuario_autorizado(update):
        return

    ingreso_total = obtener_ingreso_mensual()
    limite_nec = ingreso_total * 0.50
    limite_gus = ingreso_total * 0.30
    limite_aho = ingreso_total * 0.20

    gasto_neto = {"Necesidades": 0.0, "Gustos": 0.0, "Ahorro": 0.0}
    for cat, val in obtener_gasto_neto_mes():
        if cat in gasto_neto and val is not None:
            gasto_neto[cat] = float(val)

    val_necesidades = gasto_neto["Necesidades"]
    val_gustos = gasto_neto["Gustos"]
    val_ahorro = gasto_neto["Ahorro"]

    w_nec = max(0.0, val_necesidades)
    w_gus = max(0.0, val_gustos)
    w_aho = max(0.0, val_ahorro)

    fig, ax = plt.subplots(figsize=(9, 2.8))
    ax.barh(0, w_nec, color="#286EF0", label=f"Necesidades (${limite_nec:,.0f})")
    ax.barh(0, w_gus, left=w_nec, color="#F59E0B", label=f"Gustos (${limite_gus:,.0f})")
    ax.barh(
        0,
        w_aho,
        left=w_nec + w_gus,
        color="#10B981",
        label=f"Ahorro (${limite_aho:,.0f})",
    )

    ax.set_xlim(0, max(ingreso_total, w_nec + w_gus + w_aho, 1.0))
    ax.set_yticks([])
    ax.set_title(
        f"Progreso del Presupuesto Mensual: ${ingreso_total:,.2f} MXN",
        fontsize=13,
        weight="bold",
        pad=12,
    )
    ax.legend(
        loc="upper center",
        bbox_to_anchor=(0.5, -0.2),
        ncol=3,
        frameon=False,
    )
    plt.tight_layout()

    fd, ruta_imagen = tempfile.mkstemp(suffix=".png")
    os.close(fd)
    try:
        plt.savefig(ruta_imagen, dpi=150, bbox_inches="tight")
        plt.close(fig)

        restante_nec = limite_nec - val_necesidades
        restante_gus = limite_gus - val_gustos
        restante_aho = limite_aho - val_ahorro
        restante_total = restante_nec + restante_gus + restante_aho

        caption = (
            f"*Progreso del Presupuesto (${ingreso_total:,.2f} MXN)*\n\n"
            f"*Necesidades (${limite_nec:,.2f}):*\n"
            f"  - Gasto neto: ${val_necesidades:,.2f}\n"
            f"  - Saldo restante: ${restante_nec:,.2f}\n\n"
            f"*Gustos (${limite_gus:,.2f}):*\n"
            f"  - Gasto neto: ${val_gustos:,.2f}\n"
            f"  - Saldo restante: ${restante_gus:,.2f}\n\n"
            f"*Ahorro (${limite_aho:,.2f}):*\n"
            f"  - Gasto neto: ${val_ahorro:,.2f}\n"
            f"  - Saldo restante: ${restante_aho:,.2f}\n\n"
            f"*Saldo restante total disponible:* ${restante_total:,.2f}"
        )

        with open(ruta_imagen, "rb") as foto:
            await context.bot.send_photo(
                chat_id=MI_CHAT_ID,
                photo=foto,
                caption=caption,
                parse_mode="Markdown",
            )
    finally:
        if os.path.exists(ruta_imagen):
            os.remove(ruta_imagen)


def iniciar_bot():
    """Configura y arranca el bot privado de Telegram (exclusivamente registro manual)."""
    if not TELEGRAM_TOKEN or MI_CHAT_ID == 0:
        logger.error(
            "Faltan credenciales de Telegram (TELEGRAM_TOKEN o TELEGRAM_CHAT_ID) en .env"
        )
        return

    app = Application.builder().token(TELEGRAM_TOKEN).build()

    app.add_handler(CommandHandler("start", comando_start))
    app.add_handler(CommandHandler("ayuda", comando_ayuda))
    app.add_handler(CommandHandler("help", comando_ayuda))
    app.add_handler(CommandHandler("reporte", generar_grafico))

    app.add_handler(MessageHandler(filters.VOICE | filters.AUDIO, recibir_audio))
    app.add_handler(MessageHandler(filters.PHOTO, recibir_foto))
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, recibir_gasto))

    logger.info(
        "Bot de Telegram iniciado en modo 100% manual (sin conexiones bancarias externas)."
    )
    app.run_polling()
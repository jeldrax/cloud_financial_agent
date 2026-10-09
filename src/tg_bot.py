import os
import sqlite3
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
from src.ai_engine import procesar_texto_ia, procesar_multimodal_ia
from src.database import DB_PATH, insertar_gasto, transaccion_existe
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
    """Escucha mensajes de texto del usuario y los analiza con Gemini (Gasto, Ingreso o IGNORAR)."""
    if not _es_usuario_autorizado(update):
        return

    texto_usuario = update.message.text
    if not texto_usuario:
        return

    mensaje_temporal = await update.message.reply_text(i18n.t("processing"))

    datos = procesar_texto_ia(texto_usuario)
    if datos:
        # Validación de exclusión para evitar duplicidad y no alterar regla 50/30/20
        if datos.get("categoria") == "IGNORAR":
            await mensaje_temporal.edit_text(
                "✅ Movimiento interno o ingreso ignorado correctamente (No afecta tu presupuesto 50/30/20)."
            )
            return

        metodo = datos.get("metodo_pago") or "Telegram/Efectivo"
        tipo = datos.get("tipo", "Gasto")
        insertar_gasto(
            monto=datos["monto"],
            concepto=datos["concepto"],
            categoria=datos["categoria"],
            metodo_pago=metodo,
            tipo=tipo
        )
        icono = "💵 *Ingreso registrado:*" if tipo == "Ingreso" else "✅ *Gasto registrado:*"
        mensaje_exito = (
            f"{icono}\n"
            f"💰 *Monto:* ${datos['monto']:,.2f}\n"
            f"🏷️ *Categoría (50/30/20):* {datos['categoria']}\n"
            f"📝 *Concepto:* {datos['concepto']}\n"
            f"💳 *Método:* {metodo}"
        )
        await mensaje_temporal.edit_text(mensaje_exito, parse_mode="Markdown")
    else:
        await mensaje_temporal.edit_text(i18n.t("expense_error"))

async def recibir_audio(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Escucha notas de voz o archivos de audio y los analiza directamente con Gemini."""
    if not _es_usuario_autorizado(update):
        return

    archivo = update.message.voice or update.message.audio
    if not archivo:
        return

    mensaje_temporal = await update.message.reply_text("🎧 Procesando nota de voz con IA...")

    try:
        tg_file = await archivo.get_file()
        datos_bytes = bytes(await tg_file.download_as_bytearray())
        mime = getattr(archivo, "mime_type", None) or "audio/ogg"

        datos = procesar_multimodal_ia(datos_bytes, mime_type=mime)
        if datos:
            # Validación de exclusión para evitar duplicidad y no alterar regla 50/30/20
            if datos.get("categoria") == "IGNORAR":
                await mensaje_temporal.edit_text(
                    "✅ Movimiento interno o ingreso ignorado correctamente (No afecta tu presupuesto 50/30/20)."
                )
                return

            metodo = datos.get("metodo_pago") or "Voz / Telegram"
            tipo = datos.get("tipo", "Gasto")
            insertar_gasto(
                monto=datos["monto"],
                concepto=datos["concepto"],
                categoria=datos["categoria"],
                metodo_pago=metodo,
                tipo=tipo
            )
            icono = "💵 *Ingreso registrado:*" if tipo == "Ingreso" else "✅ *Gasto registrado:*"
            mensaje_exito = (
                f"{icono}\n"
                f"💰 *Monto:* ${datos['monto']:,.2f}\n"
                f"🏷️ *Categoría (50/30/20):* {datos['categoria']}\n"
                f"📝 *Concepto:* {datos['concepto']}\n"
                f"💳 *Método:* {metodo}"
            )
            await mensaje_temporal.edit_text(mensaje_exito, parse_mode="Markdown")
        else:
            await mensaje_temporal.edit_text(i18n.t("expense_error"))
    except Exception as e:
        logger.error(f"Error procesando audio: {e}", exc_info=True)
        await mensaje_temporal.edit_text(i18n.t("expense_error"))

async def recibir_foto(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Escucha fotos de tickets o recibos y las analiza directamente con Gemini."""
    if not _es_usuario_autorizado(update) or not update.message.photo:
        return

    mensaje_temporal = await update.message.reply_text("📸 Analizando foto del recibo con IA...")

    try:
        foto = update.message.photo[-1]
        tg_file = await foto.get_file()
        datos_bytes = bytes(await tg_file.download_as_bytearray())

        datos = procesar_multimodal_ia(datos_bytes, mime_type="image/jpeg")
        if datos:
            # Validación de exclusión para evitar duplicidad y no alterar regla 50/30/20
            if datos.get("categoria") == "IGNORAR":
                await mensaje_temporal.edit_text(
                    "✅ Movimiento interno o ingreso ignorado correctamente (No afecta tu presupuesto 50/30/20)."
                )
                return

            metodo = datos.get("metodo_pago") or "Foto / Ticket"
            tipo = datos.get("tipo", "Gasto")
            insertar_gasto(
                monto=datos["monto"],
                concepto=datos["concepto"],
                categoria=datos["categoria"],
                metodo_pago=metodo,
                tipo=tipo
            )
            icono = "💵 *Ingreso registrado:*" if tipo == "Ingreso" else "✅ *Gasto registrado:*"
            mensaje_exito = (
                f"{icono}\n"
                f"💰 *Monto:* ${datos['monto']:,.2f}\n"
                f"🏷️ *Categoría (50/30/20):* {datos['categoria']}\n"
                f"📝 *Concepto:* {datos['concepto']}\n"
                f"💳 *Método:* {metodo}"
            )
            await mensaje_temporal.edit_text(mensaje_exito, parse_mode="Markdown")
        else:
            await mensaje_temporal.edit_text(i18n.t("expense_error"))
    except Exception as e:
        logger.error(f"Error procesando foto: {e}", exc_info=True)
        await mensaje_temporal.edit_text(i18n.t("expense_error"))

async def generar_grafico(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Comando /reporte para generar barra horizontal apilada con balance neto 50/30/20."""
    if not _es_usuario_autorizado(update):
        return

    # Extraer de la base de datos el gasto neto (Gastos - Ingresos) del mes actual por categoría
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()
    cursor.execute(
        """
        SELECT categoria, SUM(CASE WHEN tipo = 'Gasto' THEN monto ELSE -monto END)
        FROM transacciones
        WHERE strftime('%Y-%m', fecha) = strftime('%Y-%m', 'now')
        GROUP BY categoria
        """
    )
    datos_db = cursor.fetchall()
    conn.close()

    # Si alguna de las 3 categorías no tiene datos en la consulta, asumirla matemáticamente como 0
    gasto_neto = {"Necesidades": 0.0, "Gustos": 0.0, "Ahorro": 0.0}
    for cat, val in datos_db:
        if cat in gasto_neto:
            gasto_neto[cat] = float(val) if val is not None else 0.0

    val_necesidades = gasto_neto["Necesidades"]
    val_gustos = gasto_neto["Gustos"]
    val_ahorro = gasto_neto["Ahorro"]

    # Valores para apilar en el gráfico
    w_nec = max(0.0, val_necesidades)
    w_gus = max(0.0, val_gustos)
    w_aho = max(0.0, val_ahorro)

    # Crear una única barra horizontal usando plt.barh
    fig, ax = plt.subplots(figsize=(9, 2.8))

    # Apilar los valores usando el parámetro left:
    # Necesidades empieza en 0 (#286EF0)
    # Gustos empieza donde termina Necesidades (#F59E0B)
    # Ahorro empieza donde termina Gustos (#10B981)
    ax.barh(0, w_nec, color='#286EF0', label='Necesidades ($1,200)')
    ax.barh(0, w_gus, left=w_nec, color='#F59E0B', label='Gustos ($720)')
    ax.barh(0, w_aho, left=w_nec + w_gus, color='#10B981', label='Ahorro ($480)')

    # Fijar el límite del eje X estrictamente de 0 a 2400
    ax.set_xlim(0, 2400)

    # Ocultar el eje Y
    ax.set_yticks([])

    # Título
    ax.set_title("Progreso del Ingreso Total: $2,400 MXN", fontsize=13, weight="bold", pad=12)

    # Leyenda en la parte inferior
    ax.legend(
        loc='upper center',
        bbox_to_anchor=(0.5, -0.2),
        ncol=3,
        frameon=False
    )

    plt.tight_layout()

    # Guardar la imagen como temp_chart.png
    ruta_imagen = 'temp_chart.png'
    plt.savefig(ruta_imagen, dpi=150, bbox_inches='tight')
    plt.close(fig)

    # Límite fijo menos el gasto neto calculado
    limite_nec = 1200.0
    limite_gus = 720.0
    limite_aho = 480.0

    restante_nec = limite_nec - val_necesidades
    restante_gus = limite_gus - val_gustos
    restante_aho = limite_aho - val_ahorro
    restante_total = restante_nec + restante_gus + restante_aho

    caption = (
        "📊 *Progreso del Ingreso Total ($2,400 MXN)*\n\n"
        f"🔵 *Necesidades ($1,200):*\n"
        f"  • Gasto neto: ${val_necesidades:,.2f}\n"
        f"  • Saldo restante: ${restante_nec:,.2f}\n\n"
        f"🟡 *Gustos ($720):*\n"
        f"  • Gasto neto: ${val_gustos:,.2f}\n"
        f"  • Saldo restante: ${restante_gus:,.2f}\n\n"
        f"🟢 *Ahorro ($480):*\n"
        f"  • Gasto neto: ${val_ahorro:,.2f}\n"
        f"  • Saldo restante: ${restante_aho:,.2f}\n\n"
        f"💵 *Saldo restante total disponible:* ${restante_total:,.2f}"
    )

    try:
        with open(ruta_imagen, 'rb') as foto:
            await context.bot.send_photo(
                chat_id=MI_CHAT_ID,
                photo=foto,
                caption=caption,
                parse_mode="Markdown"
            )
    finally:
        if os.path.exists(ruta_imagen):
            os.remove(ruta_imagen)

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
                # Regla de exclusión para correos bancarios (ej. pagos a tarjeta Nu, depósitos de sueldo)
                if datos.get("categoria") == "IGNORAR":
                    logger.info(f"Correo {correo['id']} ignorado correctamente (pago a tarjeta / transferencia / ingreso regular).")
                    continue

                metodo = datos.get("metodo_pago") or "Banca / Correo"
                tipo = datos.get("tipo", "Gasto")
                insertado = insertar_gasto(
                    monto=datos["monto"],
                    concepto=datos["concepto"],
                    categoria=datos["categoria"],
                    metodo_pago=metodo,
                    tipo=tipo,
                    identificador_externo=identificador
                )
                if insertado:
                    icono = "💵 *Ingreso detectado en correo bancario:*" if tipo == "Ingreso" else "📥 *Gasto detectado en correo bancario:*"
                    mensaje = (
                        f"{icono}\n"
                        f"💰 *Monto:* ${datos['monto']:,.2f}\n"
                        f"🏷️ *Categoría:* {datos['categoria']}\n"
                        f"📝 *Concepto:* {datos['concepto']}\n"
                        f"💳 *Método:* {metodo}"
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

    # Comandos
    app.add_handler(CommandHandler("start", comando_start))
    app.add_handler(CommandHandler("ayuda", comando_ayuda))
    app.add_handler(CommandHandler("help", comando_ayuda))
    app.add_handler(CommandHandler("reporte", generar_grafico))

    # Mensajes multimedia y de texto
    app.add_handler(MessageHandler(filters.VOICE | filters.AUDIO, recibir_audio))
    app.add_handler(MessageHandler(filters.PHOTO, recibir_foto))
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
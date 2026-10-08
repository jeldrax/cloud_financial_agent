from telegram import Update
from telegram.ext import ContextTypes
from src.i18n import i18n
import os

MI_CHAT_ID = int(os.getenv("TELEGRAM_CHAT_ID"))

async def recibir_gasto(update: Update, context: ContextTypes.DEFAULT_TYPE):
    # Blindaje: Validación de usuario
    if update.effective_chat.id != MI_CHAT_ID:
        return
        
    await update.message.reply_text(i18n.t("processing"))
    # Aquí se llamará a ai_engine.py
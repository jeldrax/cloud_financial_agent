# 📊 Agente Financiero Autónomo con IA

Sistema personal self-hosted para rastrear y clasificar gastos usando la API de Gemini, Python y SQLite. Diseñado con un enfoque en seguridad (Anti-Prompt Injection) y soporte multilingüe.

## 🚀 Características
* **Ingesta Segura:** Lectura truncada de notificaciones bancarias vía IMAP.
* **Interfaz Multilingüe (i18n):** Bot de Telegram con validación estricta de `chat_id` y respuestas dinámicas según el idioma.
* **Procesamiento de IA:** Extracción unificada a JSON usando Google AI Studio, procesando entradas en cualquier idioma y estandarizando salidas.
* **Despliegue Homelab:** Contenerizado con Docker para correr junto a Grafana.

## 🛠️ Stack
Python 3 | SQLite3 | Gemini Pro API | python-telegram-bot | Docker
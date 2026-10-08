# 📊 Agente Financiero Autónomo con IA (Hermes)

Sistema personal self-hosted para rastrear y clasificar gastos usando la API de Gemini, Python y SQLite. Diseñado con un enfoque en seguridad (Anti-Prompt Injection) y soporte multilingüe.

## 🚀 Características
* **Ingesta Segura:** Lectura truncada y sanitizada de notificaciones bancarias vía IMAP con deduplicación por `Message-ID`.
* **Interfaz Multilingüe (i18n):** Bot de Telegram con validación estricta de `chat_id`, soporte para español e inglés y respuestas dinámicas.
* **Procesamiento con IA:** Extracción unificada a JSON usando Google Gemini API (Structured Outputs) con defensas contra Prompt Injection.
* **Despliegue Homelab / TrueNAS:** Contenerizado con Docker Compose junto a Grafana con el plugin de SQLite preinstalado.

## 🛠️ Stack
Python 3.11+ | SQLite3 | Google Gemini API (`google-genai`) | `python-telegram-bot` | Grafana | Docker

---

## ⚙️ Configuración Rápida

### 1. Clonar y crear archivo `.env`
Copia la plantilla y coloca tus credenciales:
```bash
cp .env.example .env
```
Edita `.env` con tus datos:
* `TELEGRAM_TOKEN`: Obtenido en Telegram mediante `@BotFather`.
* `TELEGRAM_CHAT_ID`: Tu ID numérico personal (puedes consultarlo con `@userinfobot`).
* `GEMINI_API_KEY`: Tu clave gratuita o de pago desde [Google AI Studio](https://aistudio.google.com/).
* `IMAP_USER` y `IMAP_PASSWORD`: Tu cuenta de correo y su **Contraseña de Aplicación** (si usas Gmail).
* `IMAP_FOLDER`: Carpeta donde caen las alertas bancarias (por defecto `Banca_Agente` o `INBOX`).

### 2. Ejecución Local (Entorno Virtual)
```bash
# Crear y activar venv
python3 -m venv venv
source venv/bin/activate

# Instalar dependencias
pip install -r requirements.txt

# Iniciar agente
python src/main.py
```

### 3. Ejecución con Docker Compose (Homelab / TrueNAS)
```bash
docker compose up -d --build
```
* **Bot de Telegram:** Ejecutándose en el contenedor `hermes_financiero`.
* **Grafana:** Disponible en `http://<IP_HOMELAB>:3000` (Usuario: `admin` / Password: `admin`).
  * El plugin `frser-sqlite-datasource` se instala automáticamente.
  * Para configurar el Datasource en Grafana: Tipo `SQLite`, Path: `/var/lib/grafana/data/gastos.db`.
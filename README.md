# Cloud Financial Agent (Hermes) 🏛️💰

Sistema integral y autónomo de finanzas personales *self-hosted* basado en la metodología presupuestal **50/30/20**. Integra un **backend inteligente en Python (FastAPI + Google Gemini API + Gmail IMAP + SQLite + Telegram Bot)** desplegado en servidor **TrueNAS SCALE** y un **frontend multiplataforma en Flutter** para **Android (Samsung Galaxy S23 Ultra, Galaxy Tab S7 FE)** y **Linux Desktop (CachyOS / KDE Plasma)** con arquitectura de seguridad **Zero-Trust**.

---

## 📑 Tabla de Contenidos

- [Visión General del Sistema](#-visión-general-del-sistema)
- [Arquitectura y Metodología](#-arquitectura-y-metodología)
  - [Regla Presupuestal 50/30/20](#regla-presupuestal-503020)
  - [Reglas de Exclusión Antiduplicidad (Banorte, Nu, Mercado Pago)](#reglas-de-exclusión-antiduplicidad)
  - [Seguridad Zero-Trust y Bóveda Biométrica](#seguridad-zero-trust-y-bóveda-biométrica)
- [Stack Tecnológico](#-stack-tecnológico)
- [Estructura del Proyecto](#-estructura-del-proyecto)
- [Guía Paso a Paso de Instalación y Configuración](#-guía-paso-a-paso-de-instalación-y-configuración)
  - [Paso 1: Obtención de Llaves y Credenciales](#paso-1-obtención-de-llaves-y-credenciales)
  - [Paso 2: Configuración de Gmail (2FA, Contraseña de App y Filtros)](#paso-2-configuración-de-gmail)
  - [Paso 3: Despliegue en Servidor TrueNAS SCALE / Homelab](#paso-3-despliegue-en-servidor-truenas-scale--homelab)
  - [Paso 4: Instalación en Dispositivos Clientes](#paso-4-instalación-en-dispositivos-clientes)
    - [Android (Samsung Galaxy S23 Ultra / Galaxy Tab S7 FE)](#a-android-samsung-galaxy-s23-ultra-y-galaxy-tab-s7-fe)
    - [Linux Desktop (CachyOS / Arch / Ubuntu / KDE Plasma)](#b-linux-desktop-cachyos--kde-plasma)
- [Uso y Pruebas del Sistema](#-uso-y-pruebas-del-sistema)
  - [Panel de Diagnóstico de Gmail IMAP y Cuentas](#panel-de-diagnóstico-de-gmail-imap-y-cuentas)
  - [Ingesta por Voz, Texto y Notificaciones Bancarias](#ingesta-por-voz-texto-y-notificaciones-bancarias)
  - [Bot de Telegram y Visualización en Grafana](#bot-de-telegram-y-visualización-en-grafana)
- [Pruebas Automatizadas y CI/CD](#-pruebas-automatizadas-y-cicd)
- [Licencia](#-licencia)

---

## 🌟 Visión General del Sistema

```
                      ┌──────────────────────────────────────────────┐
                      │          Notificaciones Bancarias            │
                      │  (Banorte, Mercado Pago, Nu, BBVA, etc.)     │
                      └──────────────────────┬───────────────────────┘
                                             │ IMAP SSL / Webhook
                                             ▼
┌───────────────────────────┐      ┌────────────────────────────────────────────────────────┐
│   Dispositivos Clientes   │      │                  TrueNAS SCALE Homelab                 │
│                           │      │                                                        │
│ • S23 Ultra (Android APK) │◄────►│  • FastAPI REST API (Bearer Auth Zero-Trust / Port 8000)│
│ • Tab S7 FE (Tablet)      │ Tail-│  • Motor Gemini Multimodal (Esquemas Pydantic 50/30/20)│
│ • CachyOS (Linux Desktop) │ scale│  • Monitor IMAP Banca_Agente con Deduplicación Única   │
│   (Bóveda Biométrica +    │      │  • SQLite3 (Persistencia local en data/gastos.db)       │
│    Starfield Dark Theme)  │      │  • Telegram Bot Polling (Reportes y Gráficos)          │
└───────────────────────────┘      │  • Grafana Homelab (Dashboards Analíticos / Port 3000)  │
                                   └────────────────────────────────────────────────────────┘
```

---

## 📐 Arquitectura y Metodología

### Regla Presupuestal 50/30/20
Cada movimiento financiero se clasifica automáticamente con un esquema estructurado:
1. **Necesidades (50%):** Vivienda, despensa esencial, servicios públicos, educación, salud y transporte obligatorio.
2. **Gustos (30%):** Salidas, restaurantes, streaming, pasatiempos, compras personales y ocio.
3. **Ahorro (20%):** Fondo de emergencia, inversiones, amortización de capital o ahorro programado.

### Reglas de Exclusión Antiduplicidad
Para evitar contabilizar dos veces el dinero o inflar falsamente los egresos:
- **Transferencias entre cuentas propias:** Movimientos entre tus cuentas (ej. transferir de Banorte a Mercado Pago a nombre de *Pablo Esteban Paredes Canche*) se marcan como `IGNORAR`.
- **Pagos de tarjetas de crédito:** Liquidar la tarjeta Nu o Banorte se ignora; lo que se contabiliza son las compras individuales que generaron ese saldo.
- **Depósitos salariales regulares:** Financian el presupuesto base mensual y no se suman como gasto invertido.

### Seguridad Zero-Trust y Bóveda Biométrica
- **Sin Secretos en Git:** Las credenciales del cliente Flutter se inyectan en tiempo de compilación con `envied` ofuscadas en binario. Nunca se suben archivos `.env` ni `*.env.g.dart`.
- **Bóveda Biométrica Local:** En Android y Linux, al pasar la app a segundo plano (`AppLifecycleState.paused` o `hidden`), la pantalla se bloquea inmediatamente exigiendo huella dactilar, biometría facial o credenciales de sistema (`local_auth`) para volver a ingresar.
- **Red Privada Tailscale:** Comunicación cifrada de extremo a extremo sin exponer puertos hacia Internet en el router.
- **Autenticación en Tiempo Constante:** El backend FastAPI valida el Bearer token con `secrets.compare_digest` para neutralizar ataques de tiempo (*timing attacks*).

---

## 🛠️ Stack Tecnológico

| Capa | Tecnologías |
| :--- | :--- |
| **Backend & API** | Python 3.11+, FastAPI, Pydantic v2, Uvicorn |
| **Inteligencia Artificial** | Google Gemini API (`gemini-2.5-flash` / `gemini-1.5-flash`) estructurado con JSON Schema |
| **Ingesta de Correo** | Python `imaplib`, `email` RFC 2822 parser con filtrado inteligente previo |
| **Frontend Multiplataforma** | Flutter 3.47+, Dart 3.11+, Material 3 Starfield Dark Theme |
| **Seguridad de Cliente** | `envied`, `local_auth` (Biometría Android/Linux) |
| **Audio & Notificaciones** | `record: ^7.1.2`, Webhooks SHA-256 idempotentes |
| **Almacenamiento** | SQLite 3 (`WAL mode`), índices optimizados de fecha y hash |
| **Infraestructura** | Docker Compose, TrueNAS SCALE, Tailscale VPN, Grafana |

---

## 📂 Estructura del Proyecto

```text
cloud_financial_agent/
├── android/                   # Proyecto nativo Android (S23 Ultra / Tab S7 FE)
│   ├── app/build.gradle.kts   # Configuración de compilación, permisos y MinSDK 24
│   └── app/src/main/          # MainActivity (FlutterFragmentActivity) y Manifest
├── linux/                     # Proyecto nativo Linux (CachyOS / Arch / Ubuntu)
│   ├── CMakeLists.txt         # Integración GTK3 y plugins nativos
│   └── runner/                # Punto de entrada C++ de la aplicación de escritorio
├── lib/                       # Código fuente multiplataforma en Flutter
│   ├── core/
│   │   ├── config/            # Envied Zero-Trust (env.dart)
│   │   └── network/           # ApiClient (HTTP Bearer client + Tailscale)
│   ├── modules/
│   │   ├── auth/              # Bóveda biométrica (BiometricLockView)
│   │   ├── dashboard/         # Pantalla principal 50/30/20 adaptativa
│   │   ├── settings/          # Panel de diagnóstico Gmail IMAP y configuración
│   │   └── transactions/      # Ingesta por voz, texto y webhooks bancarios
│   └── main.dart              # Inicializador global y observador de ciclo de vida
├── src/                       # Backend en Python
│   ├── ai_engine.py           # Prompts del sistema, reglas antiduplicidad y Gemini
│   ├── api.py                 # Servidor FastAPI REST (Bearer Auth)
│   ├── database.py            # Esquema SQLite, migraciones e histórico de gastos
│   ├── mail_parser.py         # Lector IMAP de notificaciones y panel diagnóstico
│   ├── main.py                # Orquestador del servicio backend
│   └── tg_bot.py              # Bot de Telegram con gráficos Matplotlib
├── tests/
│   └── test_api.py            # Suite de pruebas unitarias y de integración
├── scripts/
│   └── deploy_truenas.sh      # Script de despliegue automatizado para TrueNAS SCALE
├── docker-compose.yml         # Orquestación de backend y Grafana
├── Dockerfile                 # Imagen Docker optimizada para producción
└── pubspec.yaml               # Dependencias de Flutter
```

---

## 🚀 Guía Paso a Paso de Instalación y Configuración

### Paso 1: Obtención de Llaves y Credenciales

Antes de iniciar, prepara las siguientes llaves:

1. **Google Gemini API Key:**
   - Ingresa a [Google AI Studio](https://aistudio.google.com/) y genera una clave de API gratuita.
2. **Telegram Bot Token y Chat ID (Opcional para reportes móviles por chat):**
   - Crea tu bot con [@BotFather](https://t.me/BotFather) para obtener el `TELEGRAM_TOKEN`.
   - Obtén tu identificador numérico privado con [@userinfobot](https://t.me/userinfobot) (`TELEGRAM_CHAT_ID`).
3. **Token de Seguridad de la API (Zero-Trust):**
   - Genera una cadena aleatoria de 32 bytes en tu terminal:
     ```bash
     openssl rand -hex 32
     ```
   - Este valor será tu `API_TOKEN` compartido entre TrueNAS y las aplicaciones Flutter.
4. **Red Segura Tailscale:**
   - Instala Tailscale en TrueNAS, en tu PC Linux y en tus dispositivos Android.
   - Anota la IP asignada a tu servidor TrueNAS (ej. `100.126.199.65`).

---

### Paso 2: Configuración de Gmail

Para que el agente procese automáticamente transferencias y compras notificadas por correo:

#### 1. Crear una Contraseña de Aplicación
1. Ve a tu cuenta de Google: [myaccount.google.com/security](https://myaccount.google.com/security).
2. Asegúrate de tener activada la **Verificación en dos pasos (2FA)**.
3. Dirígete a [Contraseñas de aplicaciones](https://myaccount.google.com/apppasswords).
4. Escribe el nombre de la app (ej. `Hermes TrueNAS`) y pulsa **Crear**.
5. Copia la contraseña de 16 caracteres generada (esta será tu `IMAP_PASSWORD`).

#### 2. Crear la Etiqueta `Banca_Agente`
1. Abre [Gmail](https://mail.google.com/).
2. En el menú lateral izquierdo, haz clic en **+ Crear etiqueta nueva**.
3. Nómbrala exactamente: `Banca_Agente`.

#### 3. Configurar Filtros Automáticos en Gmail
Crea filtros para que los correos bancarios se etiqueten automáticamente en `Banca_Agente`:
- En la barra de búsqueda superior de Gmail, haz clic en el icono de **Mostrar opciones de búsqueda**.
- En el campo **De:** agrega las direcciones de tus bancos. Por ejemplo:
  ```text
  (notificaciones@banorte.com OR avisos@mercadopago.com.mx OR no-reply@nu.com.mx)
  ```
- Haz clic en **Crear filtro**.
- Marca las casillas:
  - ☑ **Aplicar la etiqueta:** `Banca_Agente`.
  - ☑ **Nunca marcar como spam**.
  - *(Opcional)* ☑ **Aplicar también el filtro a las conversaciones que coincidan**.

---

### Paso 3: Despliegue en Servidor TrueNAS SCALE / Homelab

#### 1. Preparar el Entorno en TrueNAS
Conéctate por SSH a tu servidor TrueNAS:
```bash
ssh truenas_admin@<TU_IP_TAILSCALE>
cd /mnt/Biblioteca/cloud_financial_agent  # O la ruta de tu dataset persistente
```

#### 2. Configurar el Archivo `.env` del Servidor
Crea el archivo `.env` en el servidor:
```env
# Telegram
TELEGRAM_TOKEN=123456789:ABCDefghIJKLmnOPQRstuvWXYZ
TELEGRAM_CHAT_ID=987654321

# Google Gemini
GEMINI_API_KEY=AIzaSyD-tu-clave-de-google-ai-studio
GEMINI_MODEL=gemini-2.5-flash

# Gmail IMAP
IMAP_USER=tu_correo@gmail.com
IMAP_PASSWORD=tu_contrasena_de_aplicacion_16_caracteres
IMAP_SERVER=imap.gmail.com
IMAP_PORT=993
IMAP_FOLDER=Banca_Agente
IMAP_CHECK_INTERVAL_MINUTES=5

# API de Clientes Flutter (Zero-Trust)
API_TOKEN=tu_token_generado_con_openssl_rand_hex_32

# Presupuesto Base Mensual (MXN)
MONTHLY_INCOME=2400.0

# Configuración Regional
DEFAULT_LANG=es
```

#### 3. Ejecutar el Despliegue Automatizado
El repositorio incluye un script listo para producción:
```bash
bash scripts/deploy_truenas.sh
```
O directamente con Docker Compose:
```bash
docker compose up -d --build
```

Verifica el estado del contenedor:
```bash
docker compose ps
curl -H "Authorization: Bearer <TU_API_TOKEN>" http://localhost:8000/api/v1/health
```

---

### Paso 4: Instalación en Dispositivos Clientes

#### A. Android (Samsung Galaxy S23 Ultra y Galaxy Tab S7 FE)

Los APKs compilados en modo Release se encuentran listos en el repositorio en:
- **APK Optimizado para `arm64-v8a` (18.6 MB — Recomendado):**
  `build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`
- **APK Universal Release (50 MB):**
  `build/app/outputs/flutter-apk/Hermes-Financial-Agent-v1.0.0.apk`

##### ¿Cómo enviarlo e instalarlo?
1. **Vía Taildrop (Tailscale):** Con Tailscale activo en tu PC y en tu Galaxy S23 Ultra / Tab S7 FE, envía el archivo con clic derecho o por comando:
   ```bash
   tailscale file cp build/app/outputs/flutter-apk/app-arm64-v8a-release.apk "Galaxy-S23-Ultra:"
   ```
2. **Vía KDE Connect:** Envía el archivo directamente a tu teléfono o tablet.
3. **Instalación directa por ADB (opcional con depuración USB/WiFi activada):**
   ```bash
   adb install -r build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
   ```

##### Permisos solicitados por la aplicación:
- **Huella Dactilar / Biometría:** Para desbloquear la bóveda financiera al abrir o reanudar la app.
- **Micrófono:** Para el registro rápido de gastos mediante notas de voz interpretadas por Gemini.
- **Acceso a Notificaciones:** Para interceptar y registrar automáticamente pagos de tus aplicaciones bancarias.

---

#### B. Linux Desktop (CachyOS / KDE Plasma)

La aplicación ya se encuentra compilada e integrada en el sistema de escritorio:

- **Binario del sistema:**
  `~/.local/share/cloud_financial_agent/cloud_financial_agent`
- **Comando global en terminal:**
  ```bash
  cloud-financial-agent
  ```
- **Lanzador de aplicaciones (.desktop):**
  `~/.local/share/applications/cloud-financial-agent.desktop` con icono oficial Starfield.

##### Abrir desde el entorno gráfico:
Presiona la tecla **Super (Windows)** en KDE Plasma y escribe **"Hermes Financial Agent"** o **"Bóveda Financiera"**.

##### Para volver a compilar e instalar desde cero en Linux:
```bash
# Compilar bundle de release
flutter build linux --release

# Instalar en el directorio local de aplicaciones
mkdir -p "$HOME/.local/share/cloud_financial_agent" "$HOME/.local/bin"
cp -r build/linux/x64/release/bundle/* "$HOME/.local/share/cloud_financial_agent/"
ln -sf "$HOME/.local/share/cloud_financial_agent/cloud_financial_agent" "$HOME/.local/bin/cloud-financial-agent"
update-desktop-database "$HOME/.local/share/applications"
```

---

## 📱 Uso y Pruebas del Sistema

### Panel de Diagnóstico de Gmail IMAP y Cuentas
1. Abre la aplicación en tu Android o Linux.
2. Dirígete a la pestaña de **Ajustes** (icono de engranaje).
3. En la sección **Conexión de Cuentas y Gmail IMAP**, pulsa el botón **"Probar Gmail"**.
4. La app se comunicará con TrueNAS en tiempo real y mostrará:
   - Estado de la conexión SSL y carpeta `Banca_Agente`.
   - Total de correos analizados en el mes.
   - Cuentas detectadas (ej. `banorte`, `mercadopago`, `nu`).
   - Última sincronización y desglose por entidad bancaria.

### Ingesta por Voz, Texto y Notificaciones Bancarias
- **Voz con Gemini:** Mantén presionado el botón de micrófono en la pestaña de Movimientos, dicta: *"Compré una pizza de 280 pesos en Domino's con tarjeta de débito"* y suelta. El backend transcribirá y clasificará el gasto automáticamente en **Gustos**.
- **Texto Libre:** Ingresa descripciones informales; el modelo identificará comercio, monto y categoría 50/30/20.
- **Notificaciones Bancarias:** Cuando recibas un SMS o alerta de compra en tu S23 Ultra, el servicio de escucha lo enviará al webhook con un hash SHA-256 para evitar registros duplicados.

### Bot de Telegram y Visualización en Grafana
- **/reporte:** Envía el balance consolidado del mes junto con el gráfico de barras apiladas generado por Matplotlib.
- **/ayuda:** Muestra la lista de comandos disponibles.
- **Grafana (Puerto 3000):** Ingresa a `http://<IP_TAILSCALE>:3000` con `admin` / `admin` para consultar tus métricas en SQLite.

---

## 🧪 Pruebas Automatizadas y CI/CD

El repositorio cuenta con una suite completa de pruebas unitarias y de integración que validan:
1. Autenticación con token Bearer en tiempo constante.
2. Cálculo neto mensual 50/30/20 (`Gastos - Devoluciones`).
3. Deduplicación estricta de webhooks bancarios.
4. Pre-filtrado de remitentes de correo para no desperdiciar cuota de Gemini.

Para ejecutar las pruebas localmente:
```bash
python -m unittest tests/test_api.py -v
```

Para verificar la integridad del código Flutter:
```bash
flutter analyze
```

---

## 📄 Licencia

Este proyecto se distribuye bajo la licencia **MIT**. Puedes usarlo, adaptarlo y extenderlo libremente en tu homelab personal.

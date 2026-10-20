import imaplib
import email
from email.header import decode_header
from email.message import Message
from email.utils import parsedate_to_datetime
from datetime import datetime, timezone
import os
import re
import logging
import warnings
from typing import List, Dict, Any, Optional, Tuple

logger = logging.getLogger(__name__)

try:
    from bs4 import XMLParsedAsHTMLWarning
    warnings.filterwarnings("ignore", category=XMLParsedAsHTMLWarning)
except ImportError:
    pass

# Meses en inglés requeridos por el estándar RFC 3501 para el comando IMAP SINCE
_IMAP_MONTHS = [
    "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
]

# Remitentes o asuntos no transaccionales que deben descartarse localmente sin gastar cuota de Gemini
_REMITENTES_EXCLUIDOS = (
    "tiktok.com",
    "facebookmail.com",
    "instagram.com",
    "twitter.com",
    "x.com",
    "linkedin.com",
)

_ASUNTOS_INFORMATIVOS_EXCLUIDOS = (
    "continúa tu registro",
    "llegó cuenta nu",
    "el contrato de tu tarjeta",
    "tenemos una gran noticia",
    "te estás perdiendo parte de la experiencia",
    "conectaste tu cuenta a google",
    "iniciaste sesión",
    "código de verificación",
    "aviso de privacidad",
    "estado de cuenta disponible",
)

_PATRON_MONETARIO_O_OPERACION = re.compile(
    r"(\$\s?\d+(?:,\d{3})*(?:\.\d{1,2})?|\b(?:compra|cargo|pago|transferencia|spei|retiro|reembolso|abono|depósito|deposito)\b)",
    re.IGNORECASE,
)


def _decodificar_encabezado(valor: Optional[str]) -> str:
    """Decodifica encabezados como Subject o From si vienen codificados en RFC 2047."""
    if not valor:
        return ""
    partes = decode_header(valor)
    texto = ""
    for fragmento, charset in partes:
        if isinstance(fragmento, bytes):
            texto += fragmento.decode(charset or "utf-8", errors="replace")
        else:
            texto += str(fragmento)
    return texto.strip()


def _parsear_fecha_correo(raw_date: Optional[str]) -> datetime:
    """Convierte el encabezado Date RFC 2822 de un correo a datetime UTC."""
    if not raw_date:
        return datetime.now(timezone.utc)
    try:
        dt = parsedate_to_datetime(raw_date)
        if dt.tzinfo is None:
            return dt.replace(tzinfo=timezone.utc)
        return dt.astimezone(timezone.utc)
    except Exception:
        return datetime.now(timezone.utc)


def _es_correo_financiero_candidato(remitente: str, asunto: str, cuerpo: str) -> Tuple[bool, str]:
    """
    Pre-filtro local para descartar redes sociales (ej. TikTok filtrado por 'nu')
    y correos de bienvenida/marketing bancario sin gastar cuota de la API de Gemini.
    Retorna (es_valido: bool, motivo: str).
    """
    rem_lower = remitente.lower()
    asu_lower = asunto.lower()

    for dom in _REMITENTES_EXCLUIDOS:
        if dom in rem_lower:
            return False, f"Remitente no bancario ({dom})"

    for frase in _ASUNTOS_INFORMATIVOS_EXCLUIDOS:
        if frase in asu_lower:
            return False, f"Correo informativo/onboarding ('{asunto[:45]}')"

    texto_combinado = f"{asunto} {cuerpo}"
    if not _PATRON_MONETARIO_O_OPERACION.search(texto_combinado):
        return False, "Sin monto monetario ni palabras clave de transacción"

    return True, "Candidato transaccional válido"


def extraer_cuerpo_correo(msg: Message) -> str:
    """
    Extrae de forma robusta el texto plano de un mensaje de correo,
    soportando multipart y convirtiendo HTML a texto limpio si es necesario.
    """
    texto = ""

    if msg.is_multipart():
        for parte in msg.walk():
            if parte.is_multipart():
                continue
            disposicion = str(parte.get("Content-Disposition", ""))
            if "attachment" in disposicion.lower():
                continue

            tipo = parte.get_content_type()
            payload = parte.get_payload(decode=True)
            if not payload:
                continue

            charset = parte.get_content_charset() or "utf-8"
            contenido_decodificado = payload.decode(charset, errors="replace")

            if tipo == "text/plain":
                texto = contenido_decodificado
                break
            elif tipo == "text/html" and not texto:
                try:
                    from bs4 import BeautifulSoup
                    soup = BeautifulSoup(contenido_decodificado, "html.parser")
                    texto = soup.get_text(separator=" ", strip=True)
                except Exception:
                    texto = contenido_decodificado
    else:
        payload = msg.get_payload(decode=True)
        if payload:
            charset = msg.get_content_charset() or "utf-8"
            contenido_decodificado = payload.decode(charset, errors="replace")
            if msg.get_content_type() == "text/html":
                try:
                    from bs4 import BeautifulSoup
                    soup = BeautifulSoup(contenido_decodificado, "html.parser")
                    texto = soup.get_text(separator=" ", strip=True)
                except Exception:
                    texto = contenido_decodificado
            else:
                texto = contenido_decodificado

    return texto.strip()


def extraer_correos(
    usuario: Optional[str] = None,
    password: Optional[str] = None,
    servidor: Optional[str] = None,
    puerto: Optional[int] = None,
    carpeta: Optional[str] = None,
    marcar_leidos: bool = True,
    solo_mes_actual: bool = True,
    max_correos: int = 10,
) -> List[Dict[str, Any]]:
    """
    Se conecta al servidor IMAP, busca correos no leídos (UNSEEN) del mes actual
    en la carpeta indicada, filtra ruido no financiero y retorna una lista de diccionarios
    con fecha real del correo, asunto, remitente, identificador y cuerpo truncado.
    """
    usuario = usuario or os.getenv("IMAP_USER")
    password = password or os.getenv("IMAP_PASSWORD")
    servidor = servidor or os.getenv("IMAP_SERVER", "imap.gmail.com")
    puerto = puerto or int(os.getenv("IMAP_PORT", "993"))
    carpeta = carpeta or os.getenv("IMAP_FOLDER", "INBOX")

    if not usuario or not password:
        logger.warning("Credenciales IMAP no configuradas (IMAP_USER / IMAP_PASSWORD vacíos).")
        return []

    mail = None
    correos = []

    try:
        mail = imaplib.IMAP4_SSL(servidor, puerto)
        mail.login(usuario, password)
        status, _ = mail.select(carpeta)
        if status != "OK":
            logger.error(f"No se pudo seleccionar la carpeta IMAP '{carpeta}'.")
            return []

        ahora_utc = datetime.now(timezone.utc)
        if solo_mes_actual:
            mes_str = _IMAP_MONTHS[ahora_utc.month - 1]
            criterio = f'(UNSEEN SINCE "01-{mes_str}-{ahora_utc.year}")'
        else:
            criterio = "UNSEEN"

        status, data = mail.search(None, criterio)
        if status != "OK" or not data or not data[0]:
            return []

        ids_correos = data[0].split()
        # Procesar desde los más recientes con un límite por ciclo para cuidar cuota de Gemini
        for num in ids_correos[-max_correos:]:
            try:
                res, msg_data = mail.fetch(num, "(RFC822)")
                if res != "OK" or not msg_data or not msg_data[0]:
                    continue

                raw_email = msg_data[0][1]
                msg = email.message_from_bytes(raw_email)

                message_id = (msg.get("Message-ID") or f"imap_{num.decode()}").strip()
                asunto = _decodificar_encabezado(msg.get("Subject", ""))
                remitente = _decodificar_encabezado(msg.get("From", ""))
                fecha_dt = _parsear_fecha_correo(msg.get("Date"))
                fecha_sql = fecha_dt.strftime("%Y-%m-%d %H:%M:%S")
                cuerpo = extraer_cuerpo_correo(msg)
                cuerpo_truncado = cuerpo[:1200]

                es_candidato, motivo = _es_correo_financiero_candidato(
                    remitente, asunto, cuerpo_truncado
                )
                if not es_candidato:
                    logger.info(f"Correo IMAP omitido por filtro local ({motivo}): {asunto}")
                    if marcar_leidos:
                        mail.store(num, "+FLAGS", "\\Seen")
                    continue

                correos.append({
                    "id": message_id,
                    "imap_num": num,
                    "fecha_sql": fecha_sql,
                    "asunto": asunto,
                    "remitente": remitente,
                    "cuerpo": cuerpo_truncado,
                    "texto_completo": f"Asunto: {asunto}\nDe: {remitente}\nFecha: {fecha_sql}\n\n{cuerpo_truncado}"
                })

                if marcar_leidos:
                    mail.store(num, "+FLAGS", "\\Seen")

            except Exception as e:
                logger.error(f"Error procesando correo individual {num}: {e}")
                continue

    except Exception as e:
        logger.error(f"Error conectando al servidor IMAP {servidor}: {e}")
    finally:
        if mail:
            try:
                mail.close()
            except Exception:
                pass
            try:
                mail.logout()
            except Exception:
                pass

    return correos


def diagnosticar_conexion_imap(limite_muestra: int = 6) -> Dict[str, Any]:
    """
    Ejecuta una prueba de diagnóstico en modo SOLO LECTURA sobre Gmail IMAP.
    Verifica autenticación, existencia de la etiqueta/carpeta (ej. Banca_Agente),
    conteo de correos y analiza los últimos correos sin alterar su estado de lectura.
    """
    from src.database import transaccion_existe

    usuario = os.getenv("IMAP_USER", "")
    password = os.getenv("IMAP_PASSWORD", "")
    servidor = os.getenv("IMAP_SERVER", "imap.gmail.com")
    puerto = int(os.getenv("IMAP_PORT", "993"))
    carpeta = os.getenv("IMAP_FOLDER", "INBOX")

    usuario_enmascarado = (
        f"{usuario[:3]}***@{usuario.split('@')[-1]}"
        if "@" in usuario
        else "No configurado"
    )

    if not usuario or not password:
        return {
            "conectado": False,
            "usuario": usuario_enmascarado,
            "servidor": f"{servidor}:{puerto}",
            "carpeta": carpeta,
            "total_en_carpeta": 0,
            "no_leidos": 0,
            "mensaje": "Faltan credenciales IMAP_USER o IMAP_PASSWORD en .env",
            "muestra_recientes": [],
        }

    mail = None
    try:
        mail = imaplib.IMAP4_SSL(servidor, puerto)
        mail.login(usuario, password)
        status, data_sel = mail.select(carpeta, readonly=True)
        if status != "OK":
            return {
                "conectado": False,
                "usuario": usuario_enmascarado,
                "servidor": f"{servidor}:{puerto}",
                "carpeta": carpeta,
                "total_en_carpeta": 0,
                "no_leidos": 0,
                "mensaje": f"Login exitoso, pero no existe la etiqueta/carpeta '{carpeta}' en Gmail.",
                "muestra_recientes": [],
            }

        total_msgs = (
            int(data_sel[0].decode())
            if data_sel and data_sel[0]
            else 0
        )

        _, data_unseen = mail.search(None, "UNSEEN")
        unseen_ids = (
            data_unseen[0].split()
            if data_unseen and data_unseen[0]
            else []
        )

        _, data_all = mail.search(None, "ALL")
        all_ids = (
            data_all[0].split()
            if data_all and data_all[0]
            else []
        )

        muestra = []
        for num in reversed(all_ids[-limite_muestra:]):
            res, msg_data = mail.fetch(num, "(RFC822)")
            if res != "OK" or not msg_data or not msg_data[0]:
                continue
            msg = email.message_from_bytes(msg_data[0][1])
            msg_id = (msg.get("Message-ID") or f"imap_{num.decode()}").strip()
            asunto = _decodificar_encabezado(msg.get("Subject", ""))
            remitente = _decodificar_encabezado(msg.get("From", ""))
            fecha_dt = _parsear_fecha_correo(msg.get("Date"))
            fecha_sql = fecha_dt.strftime("%Y-%m-%d %H:%M:%S")
            cuerpo = extraer_cuerpo_correo(msg)[:500]

            es_candidato, motivo = _es_correo_financiero_candidato(
                remitente, asunto, cuerpo
            )
            en_sqlite = transaccion_existe(msg_id)

            # Detectar si es transferencia propia a Pablo Paredes
            cuerpo_lower = cuerpo.lower()
            es_autotransferencia = (
                "pablo paredes" in cuerpo_lower or "yopablo" in cuerpo_lower
            ) and ("enviaste" in cuerpo_lower or "transferencia" in cuerpo_lower)

            if en_sqlite:
                estado_diag = "Registrado en SQLite"
            elif not es_candidato:
                estado_diag = f"Filtrado ({motivo})"
            elif es_autotransferencia:
                estado_diag = "Ignorado (Transferencia entre tus propias cuentas)"
            else:
                estado_diag = "Candidato bancario listo para procesar"

            muestra.append({
                "imap_seq": num.decode(),
                "fecha": fecha_sql,
                "remitente": remitente,
                "asunto": asunto,
                "es_candidato": es_candidato,
                "en_sqlite": en_sqlite,
                "estado": estado_diag,
            })

        import sqlite3
        from src.database import DB_PATH
        conn = sqlite3.connect(DB_PATH)
        conn.row_factory = sqlite3.Row
        cur = conn.cursor()
        cur.execute(
            """
            SELECT id, fecha, monto, concepto, categoria, metodo_pago, tipo
            FROM transacciones
            WHERE identificador_externo IS NOT NULL AND identificador_externo NOT LIKE 'WH-%'
            ORDER BY datetime(fecha) DESC, id DESC
            LIMIT 5
            """
        )
        registradas_gmail = [dict(r) for r in cur.fetchall()]
        conn.close()

        return {
            "conectado": True,
            "usuario": usuario_enmascarado,
            "servidor": f"{servidor}:{puerto}",
            "carpeta": carpeta,
            "total_en_carpeta": total_msgs,
            "no_leidos": len(unseen_ids),
            "mensaje": f"Conexión IMAP SSL exitosa con {usuario_enmascarado} en etiqueta '{carpeta}'.",
            "muestra_recientes": muestra,
            "registradas_desde_gmail": registradas_gmail,
        }
    except Exception as e:
        return {
            "conectado": False,
            "usuario": usuario_enmascarado,
            "servidor": f"{servidor}:{puerto}",
            "carpeta": carpeta,
            "total_en_carpeta": 0,
            "no_leidos": 0,
            "mensaje": f"Error de conexión IMAP: {e}",
            "muestra_recientes": [],
        }
    finally:
        if mail:
            try:
                mail.logout()
            except Exception:
                pass
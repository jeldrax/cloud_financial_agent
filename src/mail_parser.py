import imaplib
import email
from email.header import decode_header
import os
import logging
from typing import List, Dict, Any, Optional

logger = logging.getLogger(__name__)

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
    return texto

def extraer_cuerpo_correo(msg: email.message.Message) -> str:
    """
    Extrae de forma robusta el texto plano de un mensaje de correo,
    soportando multipart y convirtiendo HTML a texto limpio si es necesario.
    """
    texto = ""
    
    if msg.is_multipart():
        for parte in msg.walk():
            # Saltar partes multipart principales o adjuntos
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
    marcar_leidos: bool = True
) -> List[Dict[str, Any]]:
    """
    Se conecta al servidor IMAP, busca correos no leídos (UNSEEN) en la carpeta indicada
    y retorna una lista de diccionarios con el asunto, remitente, identificador y cuerpo truncado.
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

        status, data = mail.search(None, "UNSEEN")
        if status != "OK" or not data or not data[0]:
            return []

        ids_correos = data[0].split()
        for num in ids_correos:
            try:
                res, msg_data = mail.fetch(num, "(RFC822)")
                if res != "OK" or not msg_data or not msg_data[0]:
                    continue

                raw_email = msg_data[0][1]
                msg = email.message_from_bytes(raw_email)

                message_id = msg.get("Message-ID", f"imap_{num.decode()}")
                asunto = _decodificar_encabezado(msg.get("Subject", ""))
                remitente = _decodificar_encabezado(msg.get("From", ""))
                cuerpo = extraer_cuerpo_correo(msg)

                # Truncar a 1200 caracteres para control de tokens y protección
                cuerpo_truncado = cuerpo[:1200]

                correos.append({
                    "id": message_id,
                    "imap_num": num,
                    "asunto": asunto,
                    "remitente": remitente,
                    "cuerpo": cuerpo_truncado,
                    "texto_completo": f"Asunto: {asunto}\nDe: {remitente}\n\n{cuerpo_truncado}"
                })

                if marcar_leidos:
                    # Marcar correo como leído para no procesarlo repetidamente
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
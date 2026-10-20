import os
import secrets
import logging
from datetime import datetime, timezone
from typing import Dict, List, Optional

from fastapi import (
    Depends,
    FastAPI,
    File,
    Form,
    HTTPException,
    Security,
    UploadFile,
    status,
)
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pydantic import BaseModel, Field

from src.ai_engine import procesar_multimodal_ia, procesar_texto_ia
from src.database import (
    insertar_gasto,
    obtener_gasto_neto_mes,
    obtener_transacciones_recientes,
    transaccion_existe,
)

logger = logging.getLogger("HermesFastAPI")

security_scheme = HTTPBearer(auto_error=False)


def verificar_token_zero_trust(
    credentials: Optional[HTTPAuthorizationCredentials] = Security(security_scheme),
) -> str:
    """
    Valida en tiempo constante el Bearer Token enviado por la app Flutter (Env.apiToken)
    contra la variable de entorno API_TOKEN del servidor en TrueNAS.
    """
    token_esperado = os.getenv("API_TOKEN", "").strip()
    if not token_esperado:
        logger.error("API_TOKEN no está configurado en el archivo .env del servidor.")
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Servidor sin API_TOKEN configurado.",
        )

    if not credentials or credentials.scheme.lower() != "bearer":
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Cabecera Authorization Bearer requerida.",
        )

    if not secrets.compare_digest(credentials.credentials, token_esperado):
        logger.warning("Intento de acceso rechazado: API_TOKEN inválido.")
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Token de autenticación inválido.",
        )

    return credentials.credentials


# ==========================================
# Esquemas Pydantic de Entrada / Salida REST
# ==========================================

class IngestaTextoRequest(BaseModel):
    texto: str = Field(..., min_length=2, max_length=1500)


class WebhookBancarioRequest(BaseModel):
    package_name: str = Field(..., max_length=120)
    title: str = Field(..., max_length=250)
    body: str = Field(..., max_length=1500)
    identificador_externo: str = Field(..., min_length=4, max_length=120)
    timestamp: Optional[str] = None


class TransaccionResponse(BaseModel):
    id: Optional[int] = None
    fecha: str
    monto: float
    concepto: str
    categoria: str
    metodo_pago: str
    tipo: str
    identificador_externo: Optional[str] = None
    duplicado_omitido: bool = False


app = FastAPI(
    title="Cloud Financial Agent API (Hermes 50/30/20)",
    description="API REST Zero-Trust alojada en TrueNAS para ingesta multimodal con Gemini y Webhooks bancarios vía Tailscale.",
    version="1.0.0",
    docs_url=None,  # Deshabilita Swagger público por seguridad Zero-Trust
    redoc_url=None,
)


@app.get("/api/v1/health", dependencies=[Depends(verificar_token_zero_trust)])
def health_check() -> Dict[str, str]:
    """Diagnóstico de conectividad y latencia desde el cliente Flutter vía Tailscale."""
    return {
        "status": "ok",
        "service": "cloud_financial_agent",
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }


@app.get(
    "/api/v1/diagnostics/imap",
    dependencies=[Depends(verificar_token_zero_trust)],
)
def diagnosticar_gmail_imap() -> Dict:
    """
    Ejecuta una prueba de diagnóstico en vivo (modo solo lectura) sobre Gmail IMAP
    y la etiqueta configurada (ej. Banca_Agente), devolviendo el estado de los últimos correos.
    """
    from src.mail_parser import diagnosticar_conexion_imap
    return diagnosticar_conexion_imap(limite_muestra=6)


@app.get(
    "/api/v1/dashboard/net-spend",
    dependencies=[Depends(verificar_token_zero_trust)],
)
def obtener_balance_neto_mensual() -> Dict[str, float]:
    """
    Devuelve el gasto neto (Gastos - Ingresos) del mes actual para cada bloque del 50/30/20.
    """
    gasto_neto = {"Necesidades": 0.0, "Gustos": 0.0, "Ahorro": 0.0}
    for categoria, total in obtener_gasto_neto_mes():
        if categoria in gasto_neto and total is not None:
            gasto_neto[categoria] = round(float(total), 2)
    return gasto_neto


@app.get(
    "/api/v1/transactions",
    response_model=List[TransaccionResponse],
    dependencies=[Depends(verificar_token_zero_trust)],
)
def listar_transacciones(limite: int = 50) -> List[Dict]:
    """Lista las transacciones más recientes almacenadas en SQLite."""
    limite_seguro = max(1, min(limite, 200))
    return obtener_transacciones_recientes(limite=limite_seguro)


@app.post(
    "/api/v1/transactions/ingest-text",
    response_model=TransaccionResponse,
    dependencies=[Depends(verificar_token_zero_trust)],
)
def ingestar_texto_lenguaje_natural(payload: IngestaTextoRequest) -> TransaccionResponse:
    """
    Procesa un texto libre con Gemini (`procesar_texto_ia`), aplica la regla 50/30/20
    y la regla de exclusión `IGNORAR`, y guarda en SQLite si procede.
    """
    datos = procesar_texto_ia(payload.texto)
    if not datos:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="No se detectó una transacción financiera válida en el texto enviado.",
        )

    ahora_iso = datetime.now(timezone.utc).isoformat()
    categoria = datos["categoria"]
    metodo = datos.get("metodo_pago") or "App Flutter / Texto IA"
    tipo = datos.get("tipo", "Gasto")

    if categoria != "IGNORAR":
        insertar_gasto(
            monto=datos["monto"],
            concepto=datos["concepto"],
            categoria=categoria,
            metodo_pago=metodo,
            tipo=tipo,
        )

    return TransaccionResponse(
        fecha=ahora_iso,
        monto=datos["monto"],
        concepto=datos["concepto"],
        categoria=categoria,
        metodo_pago=metodo,
        tipo=tipo,
    )


@app.post(
    "/api/v1/transactions/ingest-voice",
    response_model=TransaccionResponse,
    dependencies=[Depends(verificar_token_zero_trust)],
)
async def ingestar_nota_de_voz(
    audio: UploadFile = File(...),
    mime_type: str = Form("audio/m4a"),
) -> TransaccionResponse:
    """
    Recibe una grabación directa de voz ("Plug & Play" estilo MonAi) desde S23 Ultra,
    Tab S7 FE o CachyOS Desktop y la procesa multimodalmente con Gemini.
    """
    datos_bytes = await audio.read()
    if not datos_bytes:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="El archivo de audio recibido está vacío.",
        )

    datos = procesar_multimodal_ia(datos_bytes, mime_type=mime_type)
    if not datos:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="Gemini no pudo extraer una transacción válida del audio.",
        )

    ahora_iso = datetime.now(timezone.utc).isoformat()
    categoria = datos["categoria"]
    metodo = datos.get("metodo_pago") or "Voz IA (MonAi)"
    tipo = datos.get("tipo", "Gasto")

    if categoria != "IGNORAR":
        insertar_gasto(
            monto=datos["monto"],
            concepto=datos["concepto"],
            categoria=categoria,
            metodo_pago=metodo,
            tipo=tipo,
        )

    return TransaccionResponse(
        fecha=ahora_iso,
        monto=datos["monto"],
        concepto=datos["concepto"],
        categoria=categoria,
        metodo_pago=metodo,
        tipo=tipo,
    )


@app.post(
    "/api/v1/webhooks/bank-notification",
    response_model=TransaccionResponse,
    dependencies=[Depends(verificar_token_zero_trust)],
)
def recibir_webhook_notificacion_bancaria(
    payload: WebhookBancarioRequest,
) -> TransaccionResponse:
    """
    Recibe notificaciones bancarias interceptadas por el celular (S23 Ultra),
    verifica deduplicación mediante `identificador_externo` en SQLite,
    clasifica con Gemini y almacena el movimiento.
    """
    ahora_iso = payload.timestamp or datetime.now(timezone.utc).isoformat()

    # 1. Verificación idempotente anti-duplicados en SQLite
    if transaccion_existe(payload.identificador_externo):
        logger.info(
            f"Webhook duplicado omitido ({payload.identificador_externo})."
        )
        return TransaccionResponse(
            fecha=ahora_iso,
            monto=0.0,
            concepto=f"Notificación ya procesada ({payload.identificador_externo})",
            categoria="IGNORAR",
            metodo_pago=payload.package_name,
            tipo="Gasto",
            identificador_externo=payload.identificador_externo,
            duplicado_omitido=True,
        )

    # 2. Clasificación con Gemini bajo la regla 50/30/20 y regla IGNORAR
    texto_notificacion = f"{payload.title} - {payload.body}"
    datos = procesar_texto_ia(texto_notificacion)
    if not datos:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="La notificación bancaria no contiene una transacción clasificable.",
        )

    categoria = datos["categoria"]
    metodo = datos.get("metodo_pago") or payload.title[:50]
    tipo = datos.get("tipo", "Gasto")

    if categoria != "IGNORAR":
        insertar_gasto(
            monto=datos["monto"],
            concepto=datos["concepto"],
            categoria=categoria,
            metodo_pago=metodo,
            tipo=tipo,
            identificador_externo=payload.identificador_externo,
        )

    return TransaccionResponse(
        fecha=ahora_iso,
        monto=datos["monto"],
        concepto=datos["concepto"],
        categoria=categoria,
        metodo_pago=metodo,
        tipo=tipo,
        identificador_externo=payload.identificador_externo,
    )

import logging
import os
import re
import secrets
import threading
import time
from collections import deque
from datetime import datetime, timezone
from typing import Deque, Dict, List, Literal, Optional

from fastapi import (
    Depends,
    FastAPI,
    File,
    Form,
    HTTPException,
    Request,
    Response,
    Security,
    UploadFile,
    status,
)
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pydantic import BaseModel, Field, field_validator

from src.ai_engine import (
    MAX_LONGITUD_TEXTO,
    MAX_MONTO_PERMITIDO,
    MAX_MULTIMODAL_BYTES,
    procesar_multimodal_ia,
    procesar_texto_ia,
)
from src.database import (
    actualizar_ingreso_mensual,
    eliminar_transaccion,
    insertar_gasto,
    obtener_gasto_neto_mes,
    obtener_ingreso_mensual,
    obtener_transacciones_recientes,
)

logger = logging.getLogger("HermesFastAPI")

security_scheme = HTTPBearer(auto_error=False)

# ==============================================================================
# Rate Limiter en Memoria para Endpoints de IA (Protección Anti-Abuso / Cuota)
# ==============================================================================
MAX_PETICIONES_IA_POR_MINUTO = 20
_VENTANA_SEGUNDOS = 60.0
_historial_peticiones_ia: Deque[float] = deque()
_lock_rate_limit = threading.Lock()

MIMES_AUDIO_PERMITIDOS = frozenset(
    {
        "audio/m4a",
        "audio/mp4",
        "audio/aac",
        "audio/ogg",
        "audio/wav",
        "audio/webm",
        "audio/mpeg",
        "audio/mp3",
    }
)

_CARACTERES_PELIGROSOS = re.compile(r"[\x00-\x1f\x7f<>`$\[\]{}\\]")


def _limpiar_texto_manual(valor: str, max_len: int) -> str:
    limpio = _CARACTERES_PELIGROSOS.sub("", valor or "")
    limpio = re.sub(r"\s+", " ", limpio).strip()[:max_len]
    return limpio


def verificar_token_zero_trust(
    credentials: Optional[HTTPAuthorizationCredentials] = Security(security_scheme),
) -> str:
    """
    Valida en tiempo constante el Bearer Token enviado por la app Flutter (Env.apiToken)
    contra la variable de entorno API_TOKEN del servidor.
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


def verificar_rate_limit_ia() -> None:
    """Limita la frecuencia de llamadas a Gemini para prevenir abuso o agotamiento de cuota."""
    ahora = time.monotonic()
    with _lock_rate_limit:
        while (
            _historial_peticiones_ia
            and ahora - _historial_peticiones_ia[0] > _VENTANA_SEGUNDOS
        ):
            _historial_peticiones_ia.popleft()

        if len(_historial_peticiones_ia) >= MAX_PETICIONES_IA_POR_MINUTO:
            logger.warning("Límite de peticiones por minuto a IA alcanzado.")
            raise HTTPException(
                status_code=status.HTTP_429_TOO_MANY_REQUESTS,
                detail="Demasiadas solicitudes de IA. Espera unos segundos antes de intentar de nuevo.",
            )

        _historial_peticiones_ia.append(ahora)


def reset_rate_limiter_para_tests() -> None:
    """Auxiliar para pruebas unitarias."""
    with _lock_rate_limit:
        _historial_peticiones_ia.clear()


# ==========================================
# Esquemas Pydantic de Entrada / Salida REST
# ==========================================


class IngestaTextoRequest(BaseModel):
    texto: str = Field(..., min_length=2, max_length=MAX_LONGITUD_TEXTO)


class CrearTransaccionManualRequest(BaseModel):
    monto: float = Field(..., gt=0.0, le=MAX_MONTO_PERMITIDO)
    concepto: str = Field(..., min_length=2, max_length=100)
    categoria: Literal["Necesidades", "Gustos", "Ahorro"]
    tipo: Literal["Gasto", "Ingreso"] = "Gasto"
    metodo_pago: str = Field(default="Efectivo", min_length=2, max_length=50)

    @field_validator("concepto")
    @classmethod
    def validar_concepto(cls, v: str) -> str:
        limpio = _limpiar_texto_manual(v, 100)
        if len(limpio) < 2:
            raise ValueError("El concepto contiene caracteres inválidos o es demasiado corto.")
        return limpio

    @field_validator("metodo_pago")
    @classmethod
    def validar_metodo(cls, v: str) -> str:
        limpio = _limpiar_texto_manual(v, 50)
        return limpio if len(limpio) >= 2 else "Efectivo"


class PresupuestoMensualPayload(BaseModel):
    monthly_income: float = Field(..., gt=0.0, le=10_000_000.0)


class TransaccionResponse(BaseModel):
    id: Optional[int] = None
    fecha: str
    monto: float
    concepto: str
    categoria: str
    metodo_pago: str
    tipo: str
    identificador_externo: Optional[str] = None


app = FastAPI(
    title="Cloud Financial Agent API (50/30/20 Self-Managed)",
    description="API REST Zero-Trust sin conexiones bancarias externas para registro manual y asistido por IA vía Tailscale.",
    version="2.0.0",
    docs_url=None,
    redoc_url=None,
    openapi_url=None,  # Oculta el esquema OpenAPI ante escaneos no autenticados
)


@app.middleware("http")
async def agregar_cabeceras_seguridad(request: Request, call_next) -> Response:
    """Agrega cabeceras HTTP de endurecimiento y evita caché de datos financieros sensibles."""
    response: Response = await call_next(request)
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["X-Frame-Options"] = "DENY"
    response.headers["Referrer-Policy"] = "no-referrer"
    response.headers["Cache-Control"] = "no-store, no-cache, must-revalidate, private"
    return response


@app.get("/api/v1/health", dependencies=[Depends(verificar_token_zero_trust)])
def health_check() -> Dict[str, str]:
    """Diagnóstico de conectividad y latencia desde el cliente Flutter vía Tailscale."""
    return {
        "status": "ok",
        "service": "cloud_financial_agent",
        "mode": "manual_zero_trust",
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }


@app.get("/api/v1/budget", dependencies=[Depends(verificar_token_zero_trust)])
def consultar_presupuesto_mensual() -> Dict[str, float]:
    """Devuelve el presupuesto base mensual persistido en SQLite."""
    return {"monthly_income": obtener_ingreso_mensual()}


@app.put("/api/v1/budget", dependencies=[Depends(verificar_token_zero_trust)])
def guardar_presupuesto_mensual(
    payload: PresupuestoMensualPayload,
) -> Dict[str, float]:
    """Actualiza el presupuesto base mensual en SQLite para todos los dispositivos."""
    actualizado = actualizar_ingreso_mensual(payload.monthly_income)
    return {"monthly_income": actualizado}


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
    "/api/v1/transactions/manual",
    response_model=TransaccionResponse,
    status_code=status.HTTP_201_CREATED,
    dependencies=[Depends(verificar_token_zero_trust)],
)
def crear_transaccion_manual(
    payload: CrearTransaccionManualRequest,
) -> TransaccionResponse:
    """
    Registra directamente un Gasto o Ingreso ingresado manualmente por el usuario
    sin pasar por modelos de IA ni conexiones bancarias externas.
    """
    ahora_iso = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
    monto_redondeado = round(float(payload.monto), 2)

    tx_id = insertar_gasto(
        monto=monto_redondeado,
        concepto=payload.concepto,
        categoria=payload.categoria,
        metodo_pago=payload.metodo_pago,
        tipo=payload.tipo,
        identificador_externo=None,
    )

    return TransaccionResponse(
        id=tx_id,
        fecha=ahora_iso,
        monto=monto_redondeado,
        concepto=payload.concepto,
        categoria=payload.categoria,
        metodo_pago=payload.metodo_pago,
        tipo=payload.tipo,
        identificador_externo="MANUAL",
    )


@app.delete(
    "/api/v1/transactions/{tx_id}",
    dependencies=[Depends(verificar_token_zero_trust)],
)
def borrar_transaccion(tx_id: int) -> Dict[str, object]:
    """Permite al usuario eliminar cualquier movimiento registrado manualmente o por IA."""
    if tx_id <= 0:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Identificador de transacción inválido.",
        )

    eliminado = eliminar_transaccion(tx_id)
    if not eliminado:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="La transacción solicitada no existe.",
        )

    return {"deleted": True, "id": tx_id}


@app.post(
    "/api/v1/transactions/ingest-text",
    response_model=TransaccionResponse,
    dependencies=[
        Depends(verificar_token_zero_trust),
        Depends(verificar_rate_limit_ia),
    ],
)
def ingestar_texto_lenguaje_natural(
    payload: IngestaTextoRequest,
) -> TransaccionResponse:
    """
    Procesa un texto escrito por el usuario con Gemini (`procesar_texto_ia`),
    aplica el blindaje anti-prompt injection y la regla 50/30/20, y guarda en SQLite.
    """
    datos = procesar_texto_ia(payload.texto)
    if not datos:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="No se detectó un movimiento financiero válido o la entrada fue bloqueada por seguridad.",
        )

    ahora_iso = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
    categoria = datos["categoria"]
    metodo = datos.get("metodo_pago") or "Texto IA"
    tipo = datos.get("tipo", "Gasto")

    tx_id: Optional[int] = None
    if categoria != "IGNORAR":
        tx_id = insertar_gasto(
            monto=datos["monto"],
            concepto=datos["concepto"],
            categoria=categoria,
            metodo_pago=metodo,
            tipo=tipo,
        )

    return TransaccionResponse(
        id=tx_id,
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
    dependencies=[
        Depends(verificar_token_zero_trust),
        Depends(verificar_rate_limit_ia),
    ],
)
async def ingestar_nota_de_voz(
    audio: UploadFile = File(...),
    mime_type: str = Form("audio/m4a"),
) -> TransaccionResponse:
    """
    Recibe una grabación directa de voz enviada manualmente por el usuario,
    verifica tipo MIME y tamaño máximo (anti-DoS), y la procesa con Gemini.
    """
    mime_limpio = (mime_type or "").split(";")[0].strip().lower()
    if mime_limpio not in MIMES_AUDIO_PERMITIDOS:
        raise HTTPException(
            status_code=status.HTTP_415_UNSUPPORTED_MEDIA_TYPE,
            detail="Formato de audio no permitido.",
        )

    datos_bytes = await audio.read(MAX_MULTIMODAL_BYTES + 1)
    if not datos_bytes:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="El archivo de audio recibido está vacío.",
        )
    if len(datos_bytes) > MAX_MULTIMODAL_BYTES:
        raise HTTPException(
            status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
            detail="El archivo de audio excede el límite máximo de 5 MB.",
        )

    datos = procesar_multimodal_ia(datos_bytes, mime_type=mime_limpio)
    if not datos:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="No se pudo extraer un movimiento financiero válido del audio.",
        )

    ahora_iso = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
    categoria = datos["categoria"]
    metodo = datos.get("metodo_pago") or "Voz IA"
    tipo = datos.get("tipo", "Gasto")

    tx_id: Optional[int] = None
    if categoria != "IGNORAR":
        tx_id = insertar_gasto(
            monto=datos["monto"],
            concepto=datos["concepto"],
            categoria=categoria,
            metodo_pago=metodo,
            tipo=tipo,
        )

    return TransaccionResponse(
        id=tx_id,
        fecha=ahora_iso,
        monto=datos["monto"],
        concepto=datos["concepto"],
        categoria=categoria,
        metodo_pago=metodo,
        tipo=tipo,
    )

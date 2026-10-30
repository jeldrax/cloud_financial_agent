import os
import sqlite3
from typing import Dict, List, Optional, Tuple

DB_PATH = os.path.abspath(os.path.join(os.path.dirname(__file__), "../data/gastos.db"))


def _get_connection() -> sqlite3.Connection:
    """Crea una conexión SQLite con modo WAL e integridad referencial habilitada."""
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    conn = sqlite3.connect(DB_PATH, timeout=10.0)
    conn.execute("PRAGMA journal_mode=WAL;")
    conn.execute("PRAGMA foreign_keys=ON;")
    return conn


def init_db() -> None:
    """Inicializa la base de datos y crea las tablas e índices si no existen."""
    conn = _get_connection()
    cursor = conn.cursor()
    cursor.execute(
        """
        CREATE TABLE IF NOT EXISTS transacciones (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            fecha DATETIME DEFAULT CURRENT_TIMESTAMP,
            monto REAL NOT NULL CHECK(monto > 0),
            concepto TEXT NOT NULL,
            categoria TEXT NOT NULL CHECK(categoria IN ('Necesidades', 'Gustos', 'Ahorro')),
            metodo_pago TEXT NOT NULL,
            tipo TEXT NOT NULL CHECK(tipo IN ('Gasto', 'Ingreso')),
            identificador_externo TEXT UNIQUE
        )
        """
    )
    cursor.execute(
        """
        CREATE TABLE IF NOT EXISTS configuracion (
            clave TEXT PRIMARY KEY,
            valor TEXT NOT NULL
        )
        """
    )
    cursor.execute(
        "CREATE INDEX IF NOT EXISTS idx_transacciones_fecha ON transacciones(fecha)"
    )
    cursor.execute(
        "CREATE INDEX IF NOT EXISTS idx_transacciones_categoria ON transacciones(categoria)"
    )
    cursor.execute(
        "CREATE INDEX IF NOT EXISTS idx_transacciones_tipo ON transacciones(tipo)"
    )

    # Inicializar presupuesto base mensual si no existe aún en SQLite
    ingreso_default = os.getenv("MONTHLY_INCOME", "2400.0").strip()
    try:
        valor_inicial = str(max(1.0, float(ingreso_default)))
    except ValueError:
        valor_inicial = "2400.0"

    cursor.execute(
        "INSERT OR IGNORE INTO configuracion (clave, valor) VALUES ('monthly_income', ?)",
        (valor_inicial,),
    )

    conn.commit()
    conn.close()


def obtener_ingreso_mensual() -> float:
    """Obtiene el presupuesto base mensual almacenado en SQLite."""
    conn = _get_connection()
    cursor = conn.cursor()
    try:
        cursor.execute(
            "SELECT valor FROM configuracion WHERE clave = 'monthly_income'"
        )
        fila = cursor.fetchone()
        if fila and fila[0]:
            return round(float(fila[0]), 2)
    except (sqlite3.Error, ValueError):
        pass
    finally:
        conn.close()

    try:
        return round(float(os.getenv("MONTHLY_INCOME", "2400.0")), 2)
    except ValueError:
        return 2400.0


def actualizar_ingreso_mensual(nuevo_monto: float) -> float:
    """Actualiza y persiste el presupuesto base mensual para la regla 50/30/20."""
    monto_limpio = round(float(nuevo_monto), 2)
    if monto_limpio <= 0:
        raise ValueError("El presupuesto mensual debe ser mayor a cero.")

    conn = _get_connection()
    cursor = conn.cursor()
    try:
        cursor.execute(
            """
            INSERT INTO configuracion (clave, valor)
            VALUES ('monthly_income', ?)
            ON CONFLICT(clave) DO UPDATE SET valor = excluded.valor
            """,
            (str(monto_limpio),),
        )
        conn.commit()
        return monto_limpio
    finally:
        conn.close()


def insertar_gasto(
    monto: float,
    concepto: str,
    categoria: str,
    metodo_pago: str,
    tipo: str = "Gasto",
    identificador_externo: Optional[str] = None,
    fecha: Optional[str] = None,
) -> Optional[int]:
    """
    Inserta una transacción manual o asistida por IA (Gasto o Ingreso) en SQLite.
    Retorna el ID numérico de la fila insertada, o None si ya existía (deduplicación).
    """
    conn = _get_connection()
    cursor = conn.cursor()
    try:
        if fecha:
            cursor.execute(
                """
                INSERT INTO transacciones (fecha, monto, concepto, categoria, metodo_pago, tipo, identificador_externo)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    fecha,
                    monto,
                    concepto,
                    categoria,
                    metodo_pago,
                    tipo,
                    identificador_externo,
                ),
            )
        else:
            cursor.execute(
                """
                INSERT INTO transacciones (monto, concepto, categoria, metodo_pago, tipo, identificador_externo)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                (
                    monto,
                    concepto,
                    categoria,
                    metodo_pago,
                    tipo,
                    identificador_externo,
                ),
            )
        conn.commit()
        return int(cursor.lastrowid) if cursor.lastrowid is not None else 1
    except sqlite3.IntegrityError:
        return None
    finally:
        conn.close()


def eliminar_transaccion(tx_id: int) -> bool:
    """Elimina una transacción por su ID primario. Retorna True si existía y fue borrada."""
    conn = _get_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("DELETE FROM transacciones WHERE id = ?", (tx_id,))
        conn.commit()
        return cursor.rowcount > 0
    finally:
        conn.close()


def transaccion_existe(identificador_externo: str) -> bool:
    """Verifica si ya existe una transacción registrada con ese identificador externo."""
    if not identificador_externo:
        return False
    conn = _get_connection()
    cursor = conn.cursor()
    try:
        cursor.execute(
            "SELECT 1 FROM transacciones WHERE identificador_externo = ?",
            (identificador_externo,),
        )
        return cursor.fetchone() is not None
    finally:
        conn.close()


def obtener_gasto_neto_mes() -> List[Tuple[str, float]]:
    """
    Calcula el gasto neto (Gastos - Ingresos) del mes actual por categoría:
    SELECT categoria, SUM(CASE WHEN tipo = 'Gasto' THEN monto ELSE -monto END)
    FROM transacciones
    WHERE strftime('%Y-%m', fecha) = strftime('%Y-%m', 'now')
    GROUP BY categoria
    """
    conn = _get_connection()
    cursor = conn.cursor()
    try:
        cursor.execute(
            """
            SELECT categoria, SUM(CASE WHEN tipo = 'Gasto' THEN monto ELSE -monto END)
            FROM transacciones
            WHERE strftime('%Y-%m', fecha) = strftime('%Y-%m', 'now')
            GROUP BY categoria
            """
        )
        return cursor.fetchall()
    finally:
        conn.close()


def obtener_gastos_por_categoria() -> List[Tuple[str, float]]:
    """Devuelve una lista de tuplas (categoria, total_gastado) agrupada por categoría."""
    conn = _get_connection()
    cursor = conn.cursor()
    try:
        cursor.execute(
            """
            SELECT categoria, SUM(monto)
            FROM transacciones
            WHERE tipo = 'Gasto'
            GROUP BY categoria
            HAVING SUM(monto) > 0
            ORDER BY SUM(monto) DESC
            """
        )
        return cursor.fetchall()
    finally:
        conn.close()


def obtener_transacciones_recientes(limite: int = 50) -> List[Dict]:
    """Devuelve las transacciones más recientes como lista de diccionarios para la API REST."""
    conn = _get_connection()
    conn.row_factory = sqlite3.Row
    cursor = conn.cursor()
    try:
        cursor.execute(
            """
            SELECT id, fecha, monto, concepto, categoria, metodo_pago, tipo, identificador_externo
            FROM transacciones
            ORDER BY datetime(fecha) DESC, id DESC
            LIMIT ?
            """,
            (limite,),
        )
        return [dict(row) for row in cursor.fetchall()]
    finally:
        conn.close()
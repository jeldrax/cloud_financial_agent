import sqlite3
import os
from typing import List, Tuple, Optional

DB_PATH = os.path.abspath(os.path.join(os.path.dirname(__file__), '../data/gastos.db'))

def init_db():
    """Inicializa la base de datos y crea la tabla e índices si no existen."""
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()
    cursor.execute('''
        CREATE TABLE IF NOT EXISTS transacciones (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            fecha DATETIME DEFAULT CURRENT_TIMESTAMP,
            monto REAL NOT NULL,
            concepto TEXT NOT NULL,
            categoria TEXT NOT NULL,
            metodo_pago TEXT NOT NULL,
            identificador_externo TEXT UNIQUE
        )
    ''')
    cursor.execute('CREATE INDEX IF NOT EXISTS idx_transacciones_fecha ON transacciones(fecha)')
    cursor.execute('CREATE INDEX IF NOT EXISTS idx_transacciones_categoria ON transacciones(categoria)')
    conn.commit()
    conn.close()

def insertar_gasto(
    monto: float,
    concepto: str,
    categoria: str,
    metodo_pago: str,
    identificador_externo: Optional[str] = None
) -> bool:
    """
    Inserta un gasto en la base de datos.
    Retorna True si fue insertado, o False si ya existía (deduplicación por identificador_externo).
    """
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()
    try:
        cursor.execute(
            """
            INSERT INTO transacciones (monto, concepto, categoria, metodo_pago, identificador_externo)
            VALUES (?, ?, ?, ?, ?)
            """,
            (monto, concepto, categoria, metodo_pago, identificador_externo)
        )
        conn.commit()
        return True
    except sqlite3.IntegrityError:
        # Ya fue registrado previamente (identificador_externo duplicado)
        return False
    finally:
        conn.close()

def transaccion_existe(identificador_externo: str) -> bool:
    """Verifica si ya existe una transacción registrada con ese identificador externo."""
    if not identificador_externo:
        return False
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()
    cursor.execute("SELECT 1 FROM transacciones WHERE identificador_externo = ?", (identificador_externo,))
    existe = cursor.fetchone() is not None
    conn.close()
    return existe

def obtener_gastos_por_categoria() -> List[Tuple[str, float]]:
    """Devuelve una lista de tuplas (categoria, total_gastado) agrupada por categoría."""
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()
    cursor.execute(
        "SELECT categoria, SUM(monto) FROM transacciones GROUP BY categoria HAVING SUM(monto) > 0 ORDER BY SUM(monto) DESC"
    )
    datos = cursor.fetchall()
    conn.close()
    return datos
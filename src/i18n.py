import json
import os
from typing import Optional

class GestorIdiomas:
    def __init__(self):
        self.idioma = os.getenv("DEFAULT_LANG", "es")
        self.textos = {}
        self.cargar_idioma(self.idioma)

    def cargar_idioma(self, idioma: str):
        ruta = os.path.join(os.path.dirname(__file__), f"../locales/{idioma}.json")
        try:
            with open(ruta, "r", encoding="utf-8") as archivo:
                self.textos = json.load(archivo)
            self.idioma = idioma
        except FileNotFoundError:
            # Si no existe, intentar fallback a español
            if idioma != "es":
                self.cargar_idioma("es")

    def t(self, clave: str, default: Optional[str] = None, **kwargs) -> str:
        """
        Obtiene el texto traducido para una clave dada.
        Permite valor por defecto y formateo de variables con kwargs.
        """
        plantilla = self.textos.get(clave, default if default is not None else clave)
        if kwargs:
            try:
                return plantilla.format(**kwargs)
            except Exception:
                return plantilla
        return plantilla

i18n = GestorIdiomas()
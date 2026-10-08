import json
import os

class GestorIdiomas:
    def __init__(self):
        self.idioma = os.getenv("DEFAULT_LANG", "es")
        self.textos = {}
        self.cargar_idioma(self.idioma)

    def cargar_idioma(self, idioma):
        ruta = os.path.join(os.path.dirname(__file__), f"../locales/{idioma}.json")
        try:
            with open(ruta, 'r', encoding='utf-8') as archivo:
                self.textos = json.load(archivo)
            self.idioma = idioma
        except FileNotFoundError:
            pass

    def t(self, clave):
        return self.textos.get(clave, clave)

i18n = GestorIdiomas()
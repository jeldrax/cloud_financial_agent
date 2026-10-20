import os
import tempfile
import unittest
from unittest.mock import patch

from fastapi.testclient import TestClient

import src.database as db_module
from src.api import app


class TestCloudFinancialAgentFastAPI(unittest.TestCase):
    def setUp(self):
        self.temp_db = tempfile.NamedTemporaryFile(suffix=".db", delete=False)
        self.temp_db.close()
        self.original_db_path = db_module.DB_PATH
        db_module.DB_PATH = self.temp_db.name
        db_module.init_db()

        os.environ["API_TOKEN"] = "test_zero_trust_token_2026"
        self.client = TestClient(app)
        self.headers = {"Authorization": "Bearer test_zero_trust_token_2026"}

    def tearDown(self):
        db_module.DB_PATH = self.original_db_path
        if os.path.exists(self.temp_db.name):
            os.remove(self.temp_db.name)

    def test_zero_trust_rejects_unauthorized_requests(self):
        res_no_token = self.client.get("/api/v1/health")
        self.assertEqual(res_no_token.status_code, 401)

        res_bad_token = self.client.get(
            "/api/v1/health",
            headers={"Authorization": "Bearer token_incorrecto"},
        )
        self.assertEqual(res_bad_token.status_code, 401)

    def test_health_check_authenticated(self):
        res = self.client.get("/api/v1/health", headers=self.headers)
        self.assertEqual(res.status_code, 200)
        self.assertEqual(res.json()["status"], "ok")

    @patch("src.api.procesar_texto_ia")
    def test_ingest_text_and_net_spend_50_30_20(self, mock_ia):
        # 1. Registrar Gasto en Necesidades ($600)
        mock_ia.return_value = {
            "monto": 600.0,
            "concepto": "Recibo de luz CFE",
            "categoria": "Necesidades",
            "tipo": "Gasto",
            "metodo_pago": "Tarjeta Nu",
        }
        res1 = self.client.post(
            "/api/v1/transactions/ingest-text",
            headers=self.headers,
            json={"texto": "Pagué 600 de luz con tarjeta Nu"},
        )
        self.assertEqual(res1.status_code, 200)
        self.assertEqual(res1.json()["categoria"], "Necesidades")

        # 2. Registrar Gasto en Gustos ($350) y Reembolso/Ingreso en Gustos ($100)
        mock_ia.return_value = {
            "monto": 350.0,
            "concepto": "Cena restaurante",
            "categoria": "Gustos",
            "tipo": "Gasto",
            "metodo_pago": "Efectivo",
        }
        self.client.post(
            "/api/v1/transactions/ingest-text",
            headers=self.headers,
            json={"texto": "Cena restaurante 350"},
        )

        mock_ia.return_value = {
            "monto": 100.0,
            "concepto": "Reembolso promo restaurante",
            "categoria": "Gustos",
            "tipo": "Ingreso",
            "metodo_pago": "Tarjeta Nu",
        }
        self.client.post(
            "/api/v1/transactions/ingest-text",
            headers=self.headers,
            json={"texto": "Me devolvieron 100 del restaurante"},
        )

        # 3. Verificar regla IGNORAR (no se debe guardar en SQLite)
        mock_ia.return_value = {
            "monto": 1500.0,
            "concepto": "Pago de tarjeta Nu desde Mercado Pago",
            "categoria": "IGNORAR",
            "tipo": "Gasto",
            "metodo_pago": "Transferencia",
        }
        res_ignore = self.client.post(
            "/api/v1/transactions/ingest-text",
            headers=self.headers,
            json={"texto": "Transferí 1500 de Mercado Pago a Nu para pagar la tarjeta"},
        )
        self.assertEqual(res_ignore.status_code, 200)
        self.assertEqual(res_ignore.json()["categoria"], "IGNORAR")

        # 4. Consultar balance neto (Gastos - Ingresos)
        res_net = self.client.get(
            "/api/v1/dashboard/net-spend",
            headers=self.headers,
        )
        self.assertEqual(res_net.status_code, 200)
        net_data = res_net.json()
        self.assertEqual(net_data["Necesidades"], 600.0)
        self.assertEqual(net_data["Gustos"], 250.0)  # 350 - 100
        self.assertEqual(net_data["Ahorro"], 0.0)

        # 5. Verificar que solo hay 3 transacciones en SQLite (el IGNORAR fue omitido)
        res_list = self.client.get("/api/v1/transactions", headers=self.headers)
        self.assertEqual(res_list.status_code, 200)
        self.assertEqual(len(res_list.json()), 3)

    @patch("src.api.procesar_texto_ia")
    def test_bank_notification_webhook_deduplication(self, mock_ia):
        mock_ia.return_value = {
            "monto": 485.0,
            "concepto": "Supermercado La Comer",
            "categoria": "Necesidades",
            "tipo": "Gasto",
            "metodo_pago": "Tarjeta Nu",
        }
        payload = {
            "package_name": "com.nu.production",
            "title": "Compra aprobada",
            "body": "Compra por $485.00 en La Comer",
            "identificador_externo": "WH-TESTDEDUP123456",
        }

        # Primera llamada inserta en SQLite
        first = self.client.post(
            "/api/v1/webhooks/bank-notification",
            headers=self.headers,
            json=payload,
        )
        self.assertEqual(first.status_code, 200)
        self.assertFalse(first.json()["duplicado_omitido"])

        # Segunda llamada con el mismo identificador_externo se detecta como duplicada
        second = self.client.post(
            "/api/v1/webhooks/bank-notification",
            headers=self.headers,
            json=payload,
        )
        self.assertEqual(second.status_code, 200)
        self.assertTrue(second.json()["duplicado_omitido"])

    def test_gmail_imap_prefilter_and_date_parser(self):
        from src.mail_parser import (
            _es_correo_financiero_candidato,
            _parsear_fecha_correo,
        )

        # 1. Correo de TikTok colado en la etiqueta Banca_Agente debe rechazarse localmente
        ok_tiktok, _ = _es_correo_financiero_candidato(
            '"TikTok" <notification@service.tiktok.com>',
            "Pablo.parch publicó 6 videos nu...",
            "Mira los nuevos videos en TikTok",
        )
        self.assertFalse(ok_tiktok)

        # 2. Correo de bienvenida de Nu sin transacción debe rechazarse localmente
        ok_onboarding, _ = _es_correo_financiero_candidato(
            "Nu <nu@nu.com.mx>",
            "¡Llegó Cuenta Nu!",
            "Gracias por ser de las primeras personas en probar Cuenta Nu.",
        )
        self.assertFalse(ok_onboarding)

        # 3. Correo transaccional real de Banorte debe aceptarse
        ok_banorte, _ = _es_correo_financiero_candidato(
            "Notificaciones Banorte <notificaciones@banorte.com>",
            "Compra con Tarjeta de Débito",
            "Se realizó una compra por $450.00 MN en Oxxo.",
        )
        self.assertTrue(ok_banorte)

        # 4. Verificar que la fecha real del correo se conserve
        dt = _parsear_fecha_correo("Fri, 16 Oct 2026 14:48:48 -0600 (CST)")
        self.assertEqual(dt.year, 2026)
        self.assertEqual(dt.month, 10)
        self.assertEqual(dt.day, 16)


if __name__ == "__main__":
    unittest.main()


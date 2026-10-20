FROM python:3.11-slim

WORKDIR /app

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONPATH=/app \
    API_HOST=0.0.0.0 \
    API_PORT=8000

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY src/ ./src/
COPY locales/ ./locales/
RUN mkdir -p /app/data

EXPOSE 8000

# Healthcheck nativo para TrueNAS SCALE verificando FastAPI con el API_TOKEN del contenedor
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD python -c "import os, urllib.request; req = urllib.request.Request(f'http://127.0.0.1:{os.getenv(\"API_PORT\", \"8000\")}/api/v1/health', headers={'Authorization': 'Bearer ' + os.getenv('API_TOKEN', '')}); urllib.request.urlopen(req, timeout=4)" || exit 1

CMD ["python", "src/main.py"]
#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Script Dual de Despliegue Zero-Trust para TrueNAS SCALE (root o truenas_admin)
# - Si se ejecuta en TrueNAS (/mnt/Biblioteca/cloud_financial_agent), reconstruye
#   y reinicia los contenedores preservando data/gastos.db y .env.
# - Si se ejecuta desde la estación de trabajo local (CachyOS), sincroniza los
#   archivos hacia TrueNAS y ejecuta este mismo script remotamente.
# ==============================================================================

REMOTE_HOST="${1:-truenas_root}"
REMOTE_DIR="${2:-/mnt/Biblioteca/cloud_financial_agent}"

# Detectar si ya estamos dentro del servidor TrueNAS
if [[ "$(pwd)" == "/mnt/"* ]] || [[ "$(hostname)" == *"truenas"* ]]; then
  echo "==> [TrueNAS Local ($(whoami))] Verificando configuración en $(pwd)..."
  mkdir -p data

  if ! grep -q "^API_TOKEN=.\+" .env; then
    echo "Error: API_TOKEN no está definido en $(pwd)/.env"
    exit 1
  fi

  if [[ "$(id -u)" -eq 0 ]]; then
    DOCKER_CMD="/usr/bin/docker"
  else
    DOCKER_CMD="sudo -n /usr/bin/docker"
  fi

  echo "==> [TrueNAS Local] Construyendo y desplegando hermes_financiero + grafana_homelab..."
  $DOCKER_CMD compose up -d --build
  $DOCKER_CMD compose ps
  echo "==> [TrueNAS Local] Despliegue finalizado exitosamente."
  exit 0
fi

# Si estamos en la máquina de desarrollo local (CachyOS):
echo "==> [1/4] Sincronizando código del backend y scripts hacia ${REMOTE_HOST}:${REMOTE_DIR} (preservando .env y data/)..."
rsync -avz \
  --include='src/***' \
  --include='locales/***' \
  --include='scripts/***' \
  --include='Dockerfile' \
  --include='docker-compose.yml' \
  --include='.dockerignore' \
  --include='requirements.txt' \
  --exclude='*' \
  ./ "${REMOTE_HOST}:${REMOTE_DIR}/"

echo "==> [2/4] Sincronizando API_TOKEN Zero-Trust en el .env remoto (sin alterar credenciales IMAP/Telegram)..."
LOCAL_API_TOKEN=$(grep "^API_TOKEN=" .env | cut -d= -f2-)
ssh "$REMOTE_HOST" "
  if ! grep -q '^API_TOKEN=' '${REMOTE_DIR}/.env'; then
    printf '\n# FastAPI Zero-Trust Token (Flutter App)\nAPI_TOKEN=%s\n' '${LOCAL_API_TOKEN}' >> '${REMOTE_DIR}/.env'
    echo '    API_TOKEN añadido al .env de TrueNAS.'
  else
    sed -i 's|^API_TOKEN=.*|API_TOKEN=${LOCAL_API_TOKEN}|' '${REMOTE_DIR}/.env'
    echo '    API_TOKEN sincronizado en el .env de TrueNAS.'
  fi
"

echo "==> [3/4] Ejecutando despliegue en TrueNAS..."
ssh "$REMOTE_HOST" "cd '${REMOTE_DIR}' && bash scripts/deploy_truenas.sh"

#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Script Dual de Despliegue Zero-Trust para Servidor Homelab / TrueNAS SCALE
# - Preserva data/gastos.db y .env remoto.
# - Elimina módulos obsoletos en src/ (--delete) manteniendo modo 100% manual.
# ==============================================================================

if [[ -f .env ]]; then
  REMOTE_HOST_ENV=$(grep "^TRUENAS_REMOTE_HOST=" .env | cut -d= -f2- || true)
  REMOTE_DIR_ENV=$(grep "^TRUENAS_REMOTE_DIR=" .env | cut -d= -f2- || true)
fi
REMOTE_HOST="${1:-${REMOTE_HOST_ENV:-truenas_server}}"
REMOTE_DIR="${2:-${REMOTE_DIR_ENV:-/mnt/tank/apps/cloud_financial_agent}}"

if [[ "$(pwd)" == "/mnt/"* ]] || [[ "$(hostname)" == *"truenas"* ]]; then
  echo "==> [Servidor Local ($(whoami))] Verificando configuración en $(pwd)..."
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

  echo "==> [Servidor Local] Construyendo y desplegando contenedores..."
  $DOCKER_CMD compose up -d --build
  $DOCKER_CMD compose ps
  echo "==> [Servidor Local] Despliegue finalizado exitosamente."
  exit 0
fi

echo "==> [1/3] Sincronizando código del backend hacia ${REMOTE_HOST}:${REMOTE_DIR} (preservando .env y data/)..."
rsync -avz --delete \
  --exclude='data/***' \
  --exclude='.env' \
  --exclude='grafana/***' \
  --include='src/***' \
  --include='locales/***' \
  --include='scripts/***' \
  --include='Dockerfile' \
  --include='docker-compose.yml' \
  --include='.dockerignore' \
  --include='requirements.txt' \
  --exclude='*' \
  ./ "${REMOTE_HOST}:${REMOTE_DIR}/"

echo "==> [2/3] Sincronizando API_TOKEN Zero-Trust en el .env remoto..."
LOCAL_API_TOKEN=$(grep "^API_TOKEN=" .env | cut -d= -f2-)
ssh "$REMOTE_HOST" "
  if ! grep -q '^API_TOKEN=' '${REMOTE_DIR}/.env'; then
    printf '\n# FastAPI Zero-Trust Token (Flutter App)\nAPI_TOKEN=%s\n' '${LOCAL_API_TOKEN}' >> '${REMOTE_DIR}/.env'
  else
    sed -i 's|^API_TOKEN=.*|API_TOKEN=${LOCAL_API_TOKEN}|' '${REMOTE_DIR}/.env'
  fi
  # Desactivar variables IMAP heredadas para garantizar cero conexiones bancarias
  sed -i '/^IMAP_/d' '${REMOTE_DIR}/.env'
"

echo "==> [3/3] Ejecutando despliegue en el servidor..."
ssh "$REMOTE_HOST" "cd '${REMOTE_DIR}' && bash scripts/deploy_truenas.sh"

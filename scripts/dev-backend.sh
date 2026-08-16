#!/usr/bin/env bash
#
# scripts/dev-backend.sh — sobe o backend Vapor completo em desenvolvimento local.
#
# Pressupõe que `scripts/dev-db.sh` já rodou (papéis jklar_owner/jklar_app e o banco
# jklar_dev existem). Roda as migrations com o DSN **owner** (`swift run App migrate --yes`)
# e depois serve com o DSN de **runtime** (`swift run App serve`, papel `jklar_app`) — dois
# comandos, é o que fecha a promessa de "a stack inteira sobe com dois comandos"
# (`scripts/dev-db.sh` + este script).
#
# Rodar este script mais de uma vez não pode falhar — a migration e a geração de chave JWT
# são idempotentes.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

APP_PASSWORD="${JKLAR_APP_PASSWORD:-REMOVIDO}"
OWNER_PASSWORD="${JKLAR_OWNER_PASSWORD:-REMOVIDO}"

export DATABASE_URL="postgres://jklar_app:${APP_PASSWORD}@127.0.0.1:5432/jklar_dev?sslmode=disable"
export DATABASE_OWNER_URL="postgres://jklar_owner:${OWNER_PASSWORD}@127.0.0.1:5432/jklar_dev?sslmode=disable"

# Chave de assinatura JWT ES256 do backend (D-09) — nunca versionada (.gitignore: *.pem
# fica de fora indiretamente via a convenção .env/*.p8; este arquivo específico soma-se a
# essa lista abaixo). Gerada uma vez, reaproveitada em execuções seguintes: um restart não
# pode invalidar sessões existentes (refresh tokens de 30 dias, plano 01-04).
JWT_KEY_PATH="${REPO_ROOT}/.jwt-dev-key.pem"
if [ ! -f "${JWT_KEY_PATH}" ]; then
  echo "==> Gerando chave de desenvolvimento ES256 (${JWT_KEY_PATH})..."
  openssl ecparam -name prime256v1 -genkey -noout -out "${JWT_KEY_PATH}"
fi
export JWT_PRIVATE_KEY_PEM
JWT_PRIVATE_KEY_PEM="$(cat "${JWT_KEY_PATH}")"

echo "==> Rodando migrations (DSN owner)..."
(cd "${REPO_ROOT}/backend" && swift run App migrate --yes)

echo "==> Subindo o servidor em 127.0.0.1:8080 (DSN app)..."
(cd "${REPO_ROOT}/backend" && swift run App serve --hostname 127.0.0.1 --port 8080)

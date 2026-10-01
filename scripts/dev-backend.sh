#!/usr/bin/env bash
#
# scripts/dev-backend.sh — sobe o backend Vapor completo em desenvolvimento local.
#
# Pressupõe que `scripts/dev-db.sh` já rodou (papéis fridgemagnet_owner/fridgemagnet_app e o banco
# fridgemagnet_dev existem). Roda as migrations com o DSN **owner** (`swift run App migrate --yes`)
# e depois serve com o DSN de **runtime** (`swift run App serve`, papel `fridgemagnet_app`) — dois
# comandos, é o que fecha a promessa de "a stack inteira sobe com dois comandos"
# (`scripts/dev-db.sh` + este script).
#
# Pré-requisito adicional do plano 02-04 (fotos do mural em Cloudflare R2): as quatro
# variáveis de ambiente `R2_ACCOUNT_ID`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`,
# `R2_BUCKET_NAME` (ver `user_setup` do plano 02-04 — Cloudflare Dashboard -> R2) precisam
# estar exportadas antes de rodar este script; o backend recusa subir sem elas fora de
# `.testing` (`R2Config.fromEnvironment()`).
#
# Rodar este script mais de uma vez não pode falhar — a migration e a geração de chave JWT
# são idempotentes.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Verificação prévia das variáveis de R2 — falha cedo e nomeando exatamente o que falta, em
# vez de deixar o backend subir as migrations e só então abortar no boot (R2Config.LoadError).
missing_r2_vars=()
for var_name in R2_ACCOUNT_ID R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_BUCKET_NAME; do
  if [ -z "${!var_name:-}" ]; then
    missing_r2_vars+=("${var_name}")
  fi
done
if [ "${#missing_r2_vars[@]}" -gt 0 ]; then
  echo "==> Variáveis de R2 ausentes (ver user_setup do plano 02-04, Cloudflare Dashboard -> R2):"
  for var_name in "${missing_r2_vars[@]}"; do
    echo "    - ${var_name}"
  done
  exit 1
fi

# Senhas dos papéis locais: vêm do ambiente e nunca ficam no repositório.
APP_PASSWORD="${FRIDGEMAGNET_APP_PASSWORD:?defina FRIDGEMAGNET_APP_PASSWORD (senha local do papel fridgemagnet_app)}"
OWNER_PASSWORD="${FRIDGEMAGNET_OWNER_PASSWORD:?defina FRIDGEMAGNET_OWNER_PASSWORD (senha local do papel fridgemagnet_owner)}"

export DATABASE_URL="postgres://fridgemagnet_app:${APP_PASSWORD}@127.0.0.1:5432/fridgemagnet_dev?sslmode=disable"
export DATABASE_OWNER_URL="postgres://fridgemagnet_owner:${OWNER_PASSWORD}@127.0.0.1:5432/fridgemagnet_dev?sslmode=disable"

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

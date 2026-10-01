#!/usr/bin/env bash
#
# scripts/dev-db.sh — sobe o Postgres 17 local do JK Lar, idempotente.
#
# Cria (se ausentes) os dois papéis de banco que o backend exige desde a Fase 1
# (ver 01-RESEARCH.md "Security Domain" e SKELETON.md):
#   jklar_owner — dono do schema, roda migrations. NÃO tem SUPERUSER.
#   jklar_app   — papel de runtime do backend Vapor. NOSUPERUSER NOBYPASSRLS —
#                 essencial porque o dono de uma tabela ignora Row-Level Security
#                 por padrão no Postgres; sem esse papel separado, o teste de
#                 isolamento por household (plano 01-02) passaria por engano.
# Cria (se ausentes) os bancos jklar_dev e jklar_test.
#
# Rodar este script duas vezes seguidas não pode falhar — cada passo checa o
# estado atual antes de agir.
set -euo pipefail

PG_BIN="/opt/homebrew/opt/postgresql@17/bin"
export PATH="${PG_BIN}:${PATH}"

# Senhas dos papéis locais: vêm do ambiente e nunca ficam no repositório.
APP_PASSWORD="${JKLAR_APP_PASSWORD:?defina JKLAR_APP_PASSWORD (senha local do papel jklar_app)}"
OWNER_PASSWORD="${JKLAR_OWNER_PASSWORD:?defina JKLAR_OWNER_PASSWORD (senha local do papel jklar_owner)}"

echo "==> Verificando postgresql@17 (Homebrew)..."
if ! brew list --formula 2>/dev/null | grep -q '^postgresql@17$'; then
  echo "==> Instalando postgresql@17 via Homebrew..."
  brew install postgresql@17
fi

echo "==> Garantindo que o serviço está rodando..."
brew services start postgresql@17 >/dev/null 2>&1 || true

echo "==> Aguardando o Postgres aceitar conexões..."
ready=false
for _ in $(seq 1 30); do
  if pg_isready -q; then
    ready=true
    break
  fi
  sleep 1
done
if [ "${ready}" != "true" ]; then
  echo "ERRO: Postgres não respondeu a tempo." >&2
  exit 1
fi

psql_super() {
  psql -v ON_ERROR_STOP=1 -d postgres "$@"
}

echo "==> Papel jklar_owner (idempotente)..."
if ! psql_super -tAc "SELECT 1 FROM pg_roles WHERE rolname = 'jklar_owner'" | grep -q 1; then
  psql_super -c "CREATE ROLE jklar_owner WITH LOGIN CREATEDB PASSWORD '${OWNER_PASSWORD}'"
else
  echo "    já existe."
fi

echo "==> Papel jklar_app — NOSUPERUSER NOBYPASSRLS (idempotente)..."
if ! psql_super -tAc "SELECT 1 FROM pg_roles WHERE rolname = 'jklar_app'" | grep -q 1; then
  psql_super -c "CREATE ROLE jklar_app WITH LOGIN NOSUPERUSER NOBYPASSRLS PASSWORD '${APP_PASSWORD}'"
else
  echo "    já existe."
fi

create_db_if_absent() {
  local dbname="$1"
  if ! psql_super -tAc "SELECT 1 FROM pg_database WHERE datname = '${dbname}'" | grep -q 1; then
    echo "==> Criando banco ${dbname} (dono jklar_owner)..."
    psql_super -c "CREATE DATABASE ${dbname} OWNER jklar_owner"
  else
    echo "==> Banco ${dbname} já existe."
  fi
}

create_db_if_absent "jklar_dev"
create_db_if_absent "jklar_test"

for dbname in jklar_dev jklar_test; do
  echo "==> Concedendo CONNECT em ${dbname} para jklar_app (idempotente)..."
  psql_super -d "${dbname}" -c "GRANT CONNECT ON DATABASE ${dbname} TO jklar_app" >/dev/null
done

DEV_OWNER_DSN="postgres://jklar_owner:${OWNER_PASSWORD}@127.0.0.1:5432/jklar_dev"
DEV_APP_DSN="postgres://jklar_app:${APP_PASSWORD}@127.0.0.1:5432/jklar_dev"
TEST_OWNER_DSN="postgres://jklar_owner:${OWNER_PASSWORD}@127.0.0.1:5432/jklar_test"
TEST_APP_DSN="postgres://jklar_app:${APP_PASSWORD}@127.0.0.1:5432/jklar_test"

cat <<EOF

==> Postgres 17 local pronto (jklar_dev e jklar_test).

  # dev
  DATABASE_URL=${DEV_APP_DSN}
  DATABASE_OWNER_URL=${DEV_OWNER_DSN}

  # test (usado por 'swift test')
  DATABASE_URL=${TEST_APP_DSN}
  DATABASE_OWNER_URL=${TEST_OWNER_DSN}

EOF

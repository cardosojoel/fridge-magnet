#!/usr/bin/env bash
#
# scripts/dev-client.sh — regenera o projeto Xcode do cliente a partir de
# client/project.yml e builda o app em macOS.
#
# client/project.yml é a única fonte da verdade do projeto (plano 01-03):
# client/FridgeMagnet.xcodeproj, client/FridgeMagnet/Info.plist e client/FridgeMagnet/FridgeMagnet.entitlements são
# artefatos gerados por este script, nunca versionados (ver .gitignore). Rodar este script
# duas vezes seguidas não pode falhar — xcodegen generate é idempotente por natureza.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

echo "==> Verificando xcodegen..."
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "==> Instalando xcodegen via Homebrew..."
  brew install xcodegen
fi

echo "==> Gerando client/FridgeMagnet.xcodeproj a partir de client/project.yml..."
xcodegen generate --spec client/project.yml

echo "==> Build macOS (Debug, sem assinatura)..."
xcodebuild \
  -project client/FridgeMagnet.xcodeproj \
  -scheme FridgeMagnet \
  -destination 'platform=macOS,arch=arm64' \
  -configuration Debug \
  build \
  CODE_SIGNING_ALLOWED=NO

echo "==> Pronto. Abra client/FridgeMagnet.xcodeproj no Xcode para rodar a janela macOS nativa."

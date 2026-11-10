#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

echo "==> [1/2] Compilando Flutter macOS Release (.app)..."
flutter build macos --release

APP_BUNDLE="$PROJECT_ROOT/build/macos/Build/Products/Release/terminal_agente.app"
# Verify the .app bundle is present before packaging.
[[ -d "$APP_BUNDLE" ]] || { echo "Erro: bundle macOS ausente" >&2; exit 1; }
[[ -f "$APP_BUNDLE/Contents/MacOS/terminal_agente" ]] || { echo "Erro: executável macOS ausente" >&2; exit 1; }
[[ -d "$APP_BUNDLE/Contents/Frameworks" ]] || { echo "Erro: frameworks macOS ausentes" >&2; exit 1; }
DIST_DIR="$PROJECT_ROOT/dist"
mkdir -p "$DIST_DIR"

echo "==> [2/2] Empacotando bundle macOS autocontido..."
if command -v hdiutil >/dev/null 2>&1; then
  hdiutil create -volname "Terminal Agente" -srcfolder "$APP_BUNDLE" -ov -format UDZO "$DIST_DIR/TerminalAgente-macos.dmg"
  [[ -s "$DIST_DIR/TerminalAgente-macos.dmg" ]] || { echo "Erro: DMG vazio ou ausente" >&2; exit 1; }
  echo "    DMG criado em: $DIST_DIR/TerminalAgente-macos.dmg"
else
  tar -czf "$DIST_DIR/TerminalAgente-macos-app.tar.gz" -C "$(dirname "$APP_BUNDLE")" "$(basename "$APP_BUNDLE")"
  [[ -s "$DIST_DIR/TerminalAgente-macos-app.tar.gz" ]] || { echo "Erro: tar.gz macOS vazio ou ausente" >&2; exit 1; }
  echo "    Pacote .app criado em: $DIST_DIR/TerminalAgente-macos-app.tar.gz"
fi

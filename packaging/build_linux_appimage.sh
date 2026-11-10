#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

echo "==> [1/4] Compilando Flutter Linux Release..."
flutter build linux --release

BUNDLE_DIR="$PROJECT_ROOT/build/linux/x64/release/bundle"
# Fail before packaging if the Flutter build is incomplete.
[[ -f "$BUNDLE_DIR/terminal_agente" ]] || { echo "Erro: executável Linux ausente" >&2; exit 1; }
[[ -d "$BUNDLE_DIR/data/flutter_assets" ]] || { echo "Erro: assets Flutter ausentes" >&2; exit 1; }
[[ -d "$BUNDLE_DIR/lib" ]] || { echo "Erro: bibliotecas Linux ausentes" >&2; exit 1; }

APPDIR="$PROJECT_ROOT/build/AppDir"
DIST_DIR="$PROJECT_ROOT/dist"

rm -rf "$APPDIR"
mkdir -p "$APPDIR/usr/bin"
mkdir -p "$DIST_DIR"

echo "==> [2/4] Montando estrutura AppDir autocontida..."
cp -r "$BUNDLE_DIR/"* "$APPDIR/usr/bin/"

cat > "$APPDIR/AppRun" << 'EOF'
#!/usr/bin/env bash
SELF="$(readlink -f "$0")"
HERE="${SELF%/*}"
export LD_LIBRARY_PATH="${HERE}/usr/bin/lib:${LD_LIBRARY_PATH:-}"
exec "${HERE}/usr/bin/terminal_agente" "$@"
EOF
chmod +x "$APPDIR/AppRun"

cat > "$APPDIR/terminal_agente.desktop" << 'EOF'
[Desktop Entry]
Name=Terminal Agente
Comment=Terminal Integrado Multi-Abas com Diff em Tempo Real e Rollback SQLite
Exec=terminal_agente
Icon=terminal_agente
Type=Application
Categories=Development;IDE;Utility;
Terminal=false
EOF

cat > "$APPDIR/terminal_agente.svg" << 'EOF'
<svg xmlns="http://www.w3.org/2000/svg" width="256" height="256" viewBox="0 0 256 256">
  <rect width="256" height="256" rx="44" fill="#0F111A"/>
  <rect x="20" y="20" width="216" height="216" rx="32" fill="#161925" stroke="#7AA2F7" stroke-width="6"/>
  <path d="M56 88 L96 128 L56 168" fill="none" stroke="#73DACA" stroke-width="14" stroke-linecap="round" stroke-linejoin="round"/>
  <line x1="112" y1="168" x2="164" y2="168" stroke="#7AA2F7" stroke-width="14" stroke-linecap="round"/>
  <circle cx="192" cy="88" r="14" fill="#9ECE6A"/>
  <circle cx="192" cy="128" r="14" fill="#F7768E"/>
</svg>
EOF

echo "==> [3/4] Gerando pacote portátil autoexecutável (.tar.gz)..."
tar -czf "$DIST_DIR/TerminalAgente-linux-x86_64-portable.tar.gz" -C "$PROJECT_ROOT/build" AppDir
[[ -s "$DIST_DIR/TerminalAgente-linux-x86_64-portable.tar.gz" ]] || { echo "Erro: pacote tar.gz vazio ou ausente" >&2; exit 1; }
echo "    Criado: $DIST_DIR/TerminalAgente-linux-x86_64-portable.tar.gz"

echo "==> [4/4] Gerando executável único standalone (.AppImage / .run)..."
if command -v appimagetool >/dev/null 2>&1; then
  ARCH=x86_64 appimagetool "$APPDIR" "$DIST_DIR/TerminalAgente-x86_64.AppImage"
  [[ -s "$DIST_DIR/TerminalAgente-x86_64.AppImage" ]] || { echo "Erro: AppImage vazio ou ausente" >&2; exit 1; }
  chmod +x "$DIST_DIR/TerminalAgente-x86_64.AppImage"
  echo "    Sucesso! AppImage gerado em: $DIST_DIR/TerminalAgente-x86_64.AppImage"
fi

# Gera também um binário único autoextraível (.run) que não depende de FUSE nem de appimagetool
SINGLE_BIN="$DIST_DIR/TerminalAgente-linux-x86_64.run"
cat > "$SINGLE_BIN" << 'LAUNCHER_EOF'
#!/usr/bin/env bash
set -euo pipefail
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/terminal_agente_standalone"
mkdir -p "$CACHE_DIR"
ARCHIVE_LINE=$(awk '/^__ARCHIVE_BELOW__/ {print NR + 1; exit 0; }' "$0")
tail -n+"$ARCHIVE_LINE" "$0" | tar -xz -C "$CACHE_DIR"
exec "$CACHE_DIR/AppDir/AppRun" "$@"
__ARCHIVE_BELOW__
LAUNCHER_EOF
cat "$DIST_DIR/TerminalAgente-linux-x86_64-portable.tar.gz" >> "$SINGLE_BIN"
[[ -s "$SINGLE_BIN" ]] || { echo "Erro: executável .run vazio ou ausente" >&2; exit 1; }
chmod +x "$SINGLE_BIN"
echo "    Criado executável único standalone: $SINGLE_BIN"
echo "    Executável direto do bundle:        $BUNDLE_DIR/terminal_agente"

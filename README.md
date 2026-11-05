# Terminal Agente

Aplicação Desktop Multiplataforma (**Linux, Windows e macOS**) construída em **Flutter**, projetada para integrar um **Terminal Real Multi-Abas** (`xterm` + `flutter_pty`) com **Detecção Híbrida de Arquivos Alterados (Git + File Watcher)**, **Visualizador Interativo de Diff (Lado a Lado e Unificado)**, **Rollback Granular (por bloco, por arquivo ou por linha do tempo)** e **Banco de Dados Local SQLite com Content-Addressable Storage (CAS)**.

---

## Principais Funcionalidades

1. **Layout de 3 Colunas Redimensionáveis (`MultiSplitView`)**:
   * **Coluna 1 — Arquivos Alterados & Timeline**: Lista em tempo real arquivos modificados (`M`), adicionados (`A`), removidos (`D`) e não rastreados (`U`) com contadores `+X / -Y`, além da aba de **Timeline de Snapshots** armazenados no SQLite.
   * **Coluna 2 — Visualizador Interativo de Diff**: Alternância instantânea entre **Lado a Lado (Split View: Como Estava vs. Como Ficou)** e **Unificado (Unified View)**, com destaque de caracteres intra-linha e botões de **Reverter este bloco** (`DiffHunk`) ou **Reverter Arquivo**.
   * **Coluna 3 — Terminal Integrado Multi-Abas & Snippets de Agentes**: Múltiplas sessões de pseudoterminal nativas (`bash`, `zsh`, `powershell`), gravação automática de histórico de comandos e logs no SQLite, e barra de botões rápidos para disparar agentes CLI (`Claude Code`, `Gemini CLI`, `Aider AI`, `Git Status`, `Git Diff`, `Flutter Test` ou comandos customizados).

---

## Documentação das Fases de Desenvolvimento

* [Plano de Arquitetura e Implementação](implementation_plan.md)
* [Fase 1 — Scaffolding e Estrutura Base](fase_1_scaffolding_e_estrutura_base.md)
* [Fase 2 — Banco de Dados SQLite Local (CAS + Repositórios)](fase_2_banco_de_dados_sqlite.md)
* [Fase 3 — Motor de Diff, Hunk Rollback e Hybrid Watcher](fase_3_motor_diff_rollback_e_watcher.md)
* [Fase 4 — Terminal Multi-Abas e Snippets de Agentes](fase_4_terminal_multi_abas_e_agentes.md)
* [Fase 5 — Interface de 3 Colunas e Empacotamento Standalone](fase_5_interface_3_colunas_e_empacotamento.md)

---

## Como Executar em Desenvolvimento

```bash
# Instalar dependências
flutter pub get

# Executar testes automatizados e análise estática
flutter test && flutter analyze

# Executar aplicação no Desktop (Linux / Windows / macOS)
flutter run -d linux   # ou -d windows / -d macos
```

---

## Como Gerar Executáveis Standalone (Autoexecutáveis)

* **Linux (`AppImage` e Bundle Portátil `.tar.gz`)**:
  ```bash
  ./packaging/build_linux_appimage.sh
  ```
* **Windows (`Standalone .exe` + `.zip` com DLLs embarcadas)**:
  ```powershell
  .\packaging\build_windows_standalone.ps1
  ```
* **macOS (`.app` / `.dmg` autocontido)**:
  ```bash
  ./packaging/build_macos_standalone.sh
  ```

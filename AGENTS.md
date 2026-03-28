# Repository Agent Instructions

## Docs First

- Ler `docs/README.md` antes de agir e usar `docs/` como fonte de verdade documental.
- Manter `AGENTS.md` e `.claude/CLAUDE.md` curtos; mover detalhe, estado, decisões e fontes para `docs/`.

## Working Rules

- Distinguir sempre entre evidência, inferência, alteração aplicada e pendente.
- Não criar lixo operacional no repositório: caches, logs, tmp, outputs, backups, relatórios transitórios, scratch ou runtime local.
- Quando o estado real do repositório mudar, atualizar `docs/STATE.md`, `docs/DECISIONS.md`, `docs/SOURCES.md` e `docs/LAST_OUTPUTS.md`.
- Antes de editar ficheiros sensíveis, correr `bash .codex/scripts/protect-files.sh <path>`.
- Após editar `.ts`, `.tsx`, `.js` ou `.jsx`, correr `bash .codex/scripts/auto-format.sh <path>`.

## Agent Layers

- `.claude/` é a camada principal de orquestração versionável.
- `.codex/` é a camada complementar de compatibilidade e execução delimitada.
- Versionar apenas assets estáveis e úteis do workflow. Cache, artifacts, worktrees, logs, runtime e settings locais devem ficar fora do Git.

# Doc/Code Alignment Report

- repo analisado: `scripts`
- ficheiros/documentacao inspecionados: `README.md`, `AGENTS.md`, `docs/README.md`, `docs/STATE.md`, `scripts/forgejo-sync.sh`, `scripts/forgejo-prune-remote.sh`, `scripts/push-all.sh`, `scripts/push`, `scripts/aplica-template`, `tests/architecture.test.sh`, `tests/dev-install.test.sh`
- evidencia principal encontrada: os executaveis documentados vivem em `scripts/`; as variaveis de ambiente reais diferem por script (`WORKSPACE_DIR`, `BASE_DIR`, `REMOTE`, `SKIP_DIRTY`, `SKIP_MIRROR`, `FORGEJO_OWNER`, `GITHUB_OWNER`, `MIRROR_DIR`)
- inconsistencias encontradas: o README anterior usava caminhos incompletos no `chmod` e agregava variaveis como se fossem comuns a todos os scripts
- correcoes aplicadas: `README.md` corrigido para os caminhos reais e para a configuracao efetivamente suportada; criado este relatorio
- validacoes executadas: `bash -n scripts/forgejo-sync.sh scripts/forgejo-prune-remote.sh scripts/push-all.sh scripts/push scripts/aplica-template tests/architecture.test.sh tests/dev-install.test.sh`; `python3 -m py_compile scripts/update-changelog.py`
- limitacoes / pontos nao validados: scripts que fazem chamadas reais a Forgejo/GitHub nao foram executados para evitar efeitos remotos; o baseline completo do repo fica afetado por delecoes locais pre-existentes em `.claude/` e `.codex/`
- resultado final: docs alinhadas

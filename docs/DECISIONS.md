# Decisions

- 2026-03-28: `docs/` torna-se a fonte de verdade documental.
- 2026-03-28: ficheiros de agente ficam curtos e remetem para `docs/`.
- 2026-03-28: runtime, caches e outputs operacionais locais deixam de ser versionáveis.
- 2026-03-28: `scripts/dev-install.sh` passa a aceitar aliases `DNS_SERVER` e `DNS_DOMAIN` e a aplicar `VLAN` no `net0`.
- 2026-03-28: a regressão de `dev-install` é coberta com mocks de comandos Proxmox para permitir validação fora do host Proxmox.
- 2026-03-28: quando `GIT_URL` aponta para GitHub, `dev-install` usa `raw.githubusercontent.com` em vez do formato `raw/branch`.

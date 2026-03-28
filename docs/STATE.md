# State

- Evidência: `README.md` descreve scripts operacionais para gestão de múltiplos repositórios.
- Evidência: existem mudanças locais adicionais em `misc/` e `tests/`, mantidas como contexto e não revertidas.
- Estado atual: `docs/` criado; documentação estrutural passa a residir aqui.
- Evidência: `scripts/dev-install.sh` agora propaga `VLAN`, `DNS_SERVER` e `DNS_DOMAIN` para a configuração do CT Proxmox.
- Evidência: existe `tests/dev-install.test.sh` para validar `tag=`, `--nameserver` e `--searchdomain` por mocks.
- Evidência: `scripts/dev-install.sh` passa a resolver URLs raw de GitHub com `raw.githubusercontent.com`, evitando `404` no download do `docker-compose.yml`.

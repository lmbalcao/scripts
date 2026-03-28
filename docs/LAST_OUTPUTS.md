# Last Outputs

- Não há outputs persistentes documentados em Git.
- Saídas operacionais e relatórios locais devem permanecer fora do versionamento.
- 2026-03-28: `bash -n scripts/dev-install.sh tests/dev-install.test.sh` -> sucesso.
- 2026-03-28: `bash tests/dev-install.test.sh` -> `dev-install test passed`.
- 2026-03-28: `curl -I -L -s -o /dev/null -w '%{http_code} %{url_effective}\n' https://raw.githubusercontent.com/lmbalcao/docker/master/terraform/docker-compose.yml` -> `200 https://raw.githubusercontent.com/lmbalcao/docker/master/terraform/docker-compose.yml`.

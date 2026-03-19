# Repository Agent Instructions

Este repositório usa um modelo de dupla camada:

- `.claude/` = camada principal de orquestração
- `.codex/` = camada complementar de compatibilidade e execução

## Fonte de verdade do processo

A fonte de verdade do workflow está em `.claude/`, nomeadamente:

- agents
- commands
- hooks
- rules
- artifacts
- skills

O diretório `.codex/` existe para:

- compatibilidade com o workflow anterior
- execução complementar
- segunda opinião
- implementação delimitada
- revisão paralela

## Papéis operacionais

### Claude Code
Usar como agente principal para:

- análise
- planeamento
- decomposição por fases
- coordenação de execução
- revisão final
- aplicação do workflow principal

### Codex
Usar como agente complementar para:

- segunda opinião
- alternativa de solução
- validação técnica paralela
- execução de tarefas delimitadas
- compatibilidade com comandos herdados

## Precedência

Quando existir conflito entre instruções:

1. instruções explícitas do utilizador
2. contexto específico do repositório
3. `AGENTS.md` local do repositório
4. `.claude/` como workflow principal
5. `.codex/` como camada complementar
6. defaults da ferramenta

## Compatibilidade Codex

A skill disponível em `.codex/skills/claude-compat-pipeline/` mantém compatibilidade com os comandos:

- `/pre-check`
- `/plan`
- `/build`
- `/security-review`
- `/dev-pipeline`
- `/auto-pipeline`

## Artefactos e cache

- manter artefactos em `.claude/artifacts/<timestamp>/`
- não versionar runtime local nem settings locais

## Proteções locais

Antes de editar ficheiros sensíveis:

```bash
bash .codex/scripts/protect-files.sh <path>
```

Após editar ficheiros `.ts`, `.tsx`, `.js`, `.jsx`:

```bash
bash .codex/scripts/auto-format.sh <path>
```

## Seleção de modelo

Os agentes deste repositório usam `model: inherit`. O modelo efetivo é herdado da sessão ativa de Claude Code ou Codex.
## Workflow Claude + Codex

1. Claude Code faz análise, planeamento e coordenação.
2. Codex é usado para segunda opinião, alternativa de implementação ou validação paralela.
3. O uso do Codex não substitui o workflow principal do Claude; complementa-o.
4. Sempre que possível, evitar trabalho duplicado entre Claude e Codex sobre a mesma tarefa sem objetivo claro.

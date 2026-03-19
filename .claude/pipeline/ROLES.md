# Pipeline Roles

## Nota operacional
- Por omissão, usar variantes `slim` quando existirem no workflow faseado.
- Escalar para agentes full apenas quando o resultado vier com `NEEDS_*`, houver risco alto, ou o utilizador pedir profundidade extra.

## Fase: brief
Fonte:
- input do utilizador

Saída:
- `.claude/artifacts/<run>/brief.md`

## Fase: pre-check
Agente principal:
- `pre-check.md`
Apoio opcional:
- `clarifier.md`
- `requirements-crystallizer.md`
- `drift-detector.md`

Saída:
- `.claude/artifacts/<run>/pre-check.md`

## Fase: plan
Agente principal:
- `planner.md`
Apoio opcional:
- `architect.md`
- `atomic-planner.md`
- `plan-reviewer.md`

Saída:
- `.claude/artifacts/<run>/plan.md`

## Fase: build
Agente principal:
- `builder.md`
Apoio opcional:
- `implementer.md`
- `architect.md`
- `tester.md`

Saída:
- `.claude/artifacts/<run>/build-report.md`

## Fase: QA / review
Agente principal:
- `code-reviewer.md`
Apoio opcional:
- `security-auditor.md`
- `tester.md`
- `quality-fit.md`
- `quality-docs.md`
- `quality-behavior.md`

Saída:
- `.claude/artifacts/<run>/qa-report.md`

## Papel do Codex
Codex entra como camada complementar para:
- segunda opinião ao plano
- revisão paralela do build
- crítica técnica ao design ou implementação
- validação complementar, não substituta, da revisão do Claude

## Regra operacional
1. Claude coordena sempre o run.
2. Um agente principal por fase.
3. Agentes de apoio só entram quando acrescentam valor claro.
4. Codex entra preferencialmente em plan review e QA review.
5. Evitar duplicação entre agentes sem objetivo explícito.

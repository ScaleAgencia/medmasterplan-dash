# MedMasterPlan · Dashboard de Captação (MMP-29-30AGO)

Dashboard ao vivo (GitHub Pages) do funil de captação de leads da campanha **MedMasterPlan** no Meta Ads.

- **URL:** https://scaleagencia.github.io/medmasterplan-dash/
- Cruza **Queries do Meta** × **Lista de Leads** (somente leitura via gviz CSV).
- **Imposto Meta ×1,1385** incluso em todo gasto e nas métricas.
- **Leadscore A/B** (critério do cliente):
  - **A** — faturamento acima de R$ 1 milhão/ano.
  - **B** — faturamento R$ 500 mil a 1 milhão/ano + possui clínica + 5+ anos de formado.
  - Qualificado = A + B.
- Ignora **leads de teste** (UTM com macro `{{...}}`, `utm_source/medium` = "teste", e-mail interno da agência, linhas sem nenhuma UTM).
- 3 abas: **Funil & Otimização** (KPIs, gráficos, visão diária, árvore campanha›conjunto›anúncio com tags de ação), **Leadscore A/B** e **Perfil dos Leads**.

## Arquitetura
- `build.ps1` (PowerShell) baixa as 2 planilhas, cruza e escreve `data.js` (`window.MMP`).
- Página estática `index.html` + `app.js` + `styles.css` (SVG na mão, sem libs).
- Atualização **a cada 3h** via GitHub Actions (`refresh.yml`), disparada por cron-job.org (`workflow_dispatch`). Só publica agregados/anonimizado — os CSVs crus (`data/`) ficam fora do deploy.

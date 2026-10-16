# Painel das GERES (Pernambuco) – dados abertos do DATASUS

Base para o painel Power BI de informações estratégicas das Gerências Regionais
de Saúde de PE. Os dados vêm do FTP do DATASUS e são atualizados pelo GitHub Actions.

## Conteúdo atual

| Arquivo | O que faz |
|---|---|
| `cnes_candidatos.R` | Gera a lista candidata de estabelecimentos da rede própria estadual (hospitais, UPAEs, UPAs) a partir do CNES-ST, com leitos SUS por categoria (CNES-LT) e Região de Saúde |
| `leitos.R` | Série mensal de leitos de PE desde 01/2022 (CNES-LT), por CNES e categoria (UTI adulto/neonatal/pediátrica, enfermaria, complementar não UTI), com QT_SUS e QT_EXIST. Saída: `dados/saida/leitos_pe.{csv,parquet}`. Atualizada diariamente se houver competência nova |
| `producao_sia.R` | Produção ambulatorial (SIA-PA) desde 01/2022 por movimento: (a) unidades da lista validada, por procedimento SIGTAP e CBO (CBO só nas consultas 0301); (b) TC, RNM e densitometria de todos os estabelecimentos de PE. Saídas: `dados/saida/sia_estabelecimentos.parquet` e `dados/saida/sia_exames_pe.parquet`. Processa até 60 movimentos por execução. **Depois de editar a lista validada, rodar o workflow com `--reprocessar-tudo`** |
| `utils.R` | Funções comuns (FTP, leitura de .dbc, gravação) |
| `referencias/municipios_regiao_saude_pe.csv` | Município → Região de Saúde/GERES |
| `referencias/estabelecimentos_validados.csv` | **Lista oficial validada pela SES (16/10/2026)**. Os indicadores de "hospitais da rede própria" usam REDE_PROPRIA_ESTADUAL + ESTADUAL_ADM_INDIRETA: CNES, tipo (HOSPITAL/UPAE/UPA) e vínculo (REDE_PROPRIA_ESTADUAL, ESTADUAL_ADM_INDIRETA, REFERENCIA_FORA_DA_REDE). Editar este arquivo para incluir ou retirar unidades. |
| `dados/referencias/cnes_candidatos.csv` | Lista candidata (para validação da SES) |
| `dados/referencias/leitos_pe.csv` | Leitos de PE por CNES e código de leito (QT_EXIST, QT_CONTR, QT_SUS, QT_NSUS) |

## Regras

- Rede própria estadual: mantenedora no CNES = Secretaria Estadual de Saúde (CNPJ 10.572.048/0001-28), o que inclui as unidades geridas por OS.
- Leitos: contagem principal por **QT_SUS**, com QT_EXIST exibido ao lado no painel (decisão de 16/10/2026: nas UTIs estaduais muitos leitos não habilitados aparecem como não SUS). Leitos totais = UTI (adulto, neonatal, pediátrica) + enfermaria; UCI/isolamento ficam à parte.

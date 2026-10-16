# Painel das GERES (Pernambuco) – dados abertos do DATASUS

Base para o painel Power BI de informações estratégicas das Gerências Regionais
de Saúde de PE. Os dados vêm do FTP do DATASUS e são atualizados pelo GitHub Actions.

## Conteúdo atual

| Arquivo | O que faz |
|---|---|
| `cnes_candidatos.R` | Gera a lista candidata de estabelecimentos da rede própria estadual (hospitais, UPAEs, UPAs) a partir do CNES-ST, com leitos SUS por categoria (CNES-LT) e Região de Saúde |
| `utils.R` | Funções comuns (FTP, leitura de .dbc, gravação) |
| `referencias/municipios_regiao_saude_pe.csv` | Município → Região de Saúde/GERES |
| `referencias/estabelecimentos_validados.csv` | **Lista oficial validada pela SES (16/10/2026)**: CNES, tipo (HOSPITAL/UPAE/UPA) e vínculo (REDE_PROPRIA_ESTADUAL, ESTADUAL_ADM_INDIRETA, REFERENCIA_FORA_DA_REDE). Editar este arquivo para incluir ou retirar unidades. |
| `dados/referencias/cnes_candidatos.csv` | Lista candidata (para validação da SES) |
| `dados/referencias/leitos_pe.csv` | Leitos de PE por CNES e código de leito (QT_EXIST, QT_CONTR, QT_SUS, QT_NSUS) |

## Regras

- Rede própria estadual: mantenedora no CNES = Secretaria Estadual de Saúde (CNPJ 10.572.048/0001-28), o que inclui as unidades geridas por OS.
- Leitos: contagem por **QT_SUS**. Leitos totais = UTI (adulto, neonatal, pediátrica) + enfermaria; UCI/isolamento ficam à parte.

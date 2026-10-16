# Guia: montar o painel das GERES no Power BI

O painel lê as tabelas que o GitHub atualiza sozinho, na pasta
[`dados/saida`](../dados/saida) deste repositório. Não há planilha para manter
à mão. Ao atualizar o painel, o Power BI baixa a versão mais recente.

**Competência = mês de processamento.** No SIA é o movimento (`PA_MVM`), no SIH
é `ANO_CMPT/MES_CMPT` e no CNES é a competência do arquivo. O último mês
publicado costuma vir incompleto, porque ainda chegam reapresentações.

---

## 1. Parâmetro com o endereço da base

*Página Inicial > Transformar dados > Gerenciar parâmetros > Novo*:

- Nome: `URL_Base`
- Tipo: Texto
- Valor atual: `https://raw.githubusercontent.com/DGMOG-SES/informacoes-estrategicas-geres/main/dados/saida/`

Se o Power BI pedir credencial em qualquer consulta abaixo, escolha **Anônimo**.

## 2. Consultas

Para cada consulta: *Nova fonte > Consulta nula*, abra o *Editor Avançado*,
cole o código e renomeie a consulta com o nome indicado.

### fIndicadores (fato principal)

```powerquery
let
    Fonte = Parquet.Document(Binary.Buffer(Web.Contents(URL_Base & "indicadores.parquet"))),
    Tipos = Table.TransformColumnTypes(Fonte, {
        {"COMPETENCIA", type text}, {"CNES", type text}, {"CO_MUNICIPIO", type text},
        {"BASE_MUNICIPIO", type text}, {"INDICADOR", type text}, {"VALOR", type number}}),
    Data = Table.AddColumn(Tipos, "Data",
        each #date(Number.From(Text.Start([COMPETENCIA], 4)), Number.From(Text.End([COMPETENCIA], 2)), 1),
        type date)
in
    Data
```

### fEspecialidades (CBO com consultas em UPAE e UPA)

```powerquery
let
    Fonte = Parquet.Document(Binary.Buffer(Web.Contents(URL_Base & "especialidades.parquet"))),
    Data = Table.AddColumn(Fonte, "Data",
        each #date(Number.From(Text.Start([COMPETENCIA], 4)), Number.From(Text.End([COMPETENCIA], 2)), 1),
        type date)
in
    Data
```

### Dimensões (CSV)

Crie uma consulta para cada arquivo, trocando só o nome do arquivo:

| Consulta | Arquivo |
|---|---|
| `dEstabelecimento` | `dim_estabelecimento.csv` |
| `dMunicipio` | `dim_municipio.csv` |
| `dIndicador` | `dim_indicador.csv` |

```powerquery
let
    Fonte = Csv.Document(Web.Contents(URL_Base & "dim_estabelecimento.csv"),
        [Delimiter = ";", Encoding = 65001, QuoteStyle = QuoteStyle.Csv]),
    Cab = Table.PromoteHeaders(Fonte, [PromoteAllScalars = true]),
    // Todas as colunas como texto: CNES e códigos de município têm zeros à esquerda.
    Texto = Table.TransformColumnTypes(Cab, List.Transform(Table.ColumnNames(Cab), each {_, type text}))
in
    Texto
```

Clique em *Fechar e Aplicar*.

## 3. Calendário

*Modelagem > Nova tabela*:

```dax
dCalendario =
VAR _fim = MAX ( fIndicadores[Data] )
RETURN
    ADDCOLUMNS (
        CALENDAR ( DATE ( 2022, 1, 1 ), EOMONTH ( _fim, 0 ) ),
        "Ano", YEAR ( [Date] ),
        "Mês Nº", MONTH ( [Date] ),
        "Mês/Ano", FORMAT ( [Date], "mmm/yyyy" ),
        "AnoMês", YEAR ( [Date] ) * 100 + MONTH ( [Date] )
    )
```

Classifique `Mês/Ano` por `AnoMês` e marque a tabela como tabela de datas
(coluna `Date`). Desligue *Data/hora automática* em *Opções > Arquivo atual >
Carregamento de dados*.

## 4. Relacionamentos

Em *Exibição de modelo*, todos de 1 para muitos, filtro em direção única:

| De (lado 1) | Para (lado muitos) |
|---|---|
| `dCalendario[Date]` | `fIndicadores[Data]` |
| `dCalendario[Date]` | `fEspecialidades[Data]` |
| `dMunicipio[CO_MUNICIPIO]` | `fIndicadores[CO_MUNICIPIO]` |
| `dIndicador[INDICADOR]` | `fIndicadores[INDICADOR]` |
| `dEstabelecimento[CNES]` | `fIndicadores[CNES]` |
| `dEstabelecimento[CNES]` | `fEspecialidades[CNES]` |

**Não ligue `dEstabelecimento` a `dMunicipio`.** A região da unidade já está em
`dEstabelecimento[REGIAO_SAUDE]`, e uma segunda ligação criaria caminho ambíguo.
Para filtrar por GERES, use `dMunicipio[REGIAO_SAUDE]`.

## 5. Medidas

Crie uma tabela vazia `Medidas` (*Inserir dados > Carregar*) e adicione as
medidas abaixo.

Há dois tipos de indicador:

- **Fluxo** (procedimentos, consultas, partos, cirurgias, exames): soma os meses
  do período selecionado.
- **Estoque** (leitos): não se soma no tempo. A medida pega o último mês do
  período selecionado.

```dax
Valor Fluxo =
CALCULATE ( SUM ( fIndicadores[VALOR] ), fIndicadores[BASE_MUNICIPIO] = "ATENDIMENTO" )

Valor Estoque =
VAR _ult = CALCULATE ( MAX ( fIndicadores[Data] ), fIndicadores[INDICADOR] = "LEITOS_TOTAIS_SUS" )
RETURN
    CALCULATE ( SUM ( fIndicadores[VALOR] ), fIndicadores[Data] = _ult,
                fIndicadores[BASE_MUNICIPIO] = "ATENDIMENTO" )
```

### Leitos (página Hospitais)

```dax
Leitos UTI Adulto SUS = CALCULATE ( [Valor Estoque], fIndicadores[INDICADOR] = "LEITOS_UTI_ADULTO_SUS" )
Leitos UTI Neo SUS = CALCULATE ( [Valor Estoque], fIndicadores[INDICADOR] = "LEITOS_UTI_NEONATAL_SUS" )
Leitos UTI Pediátrica SUS = CALCULATE ( [Valor Estoque], fIndicadores[INDICADOR] = "LEITOS_UTI_PEDIATRICA_SUS" )
Leitos Outros SUS = CALCULATE ( [Valor Estoque], fIndicadores[INDICADOR] = "LEITOS_ENFERMARIA_SUS" )
Leitos Totais SUS = CALCULATE ( [Valor Estoque], fIndicadores[INDICADOR] = "LEITOS_TOTAIS_SUS" )
Leitos Totais Existentes = CALCULATE ( [Valor Estoque], fIndicadores[INDICADOR] = "LEITOS_TOTAIS_EXISTENTES" )
```

Repita o padrão para `LEITOS_UTI_*_EXISTENTES` e `LEITOS_ENFERMARIA_EXISTENTES`
se quiser mostrar os existentes ao lado de cada tipo de leito.

### Procedimentos, consultas, partos e exames

Todos seguem o mesmo padrão: `CALCULATE ( [Valor Fluxo], fIndicadores[INDICADOR] = "<código>" )`.

| Medida | Código do indicador |
|---|---|
| Promoção e Prevenção | `PROC_PROMOCAO_PREVENCAO` |
| Proc. Diagnósticos | `PROC_DIAGNOSTICO` |
| Proc. Clínicos | `PROC_CLINICOS` |
| Proc. Cirúrgicos | `PROC_CIRURGICOS` |
| Transplantes | `PROC_TRANSPLANTES` |
| OPM | `PROC_OPM` |
| OCI | `PROC_OCI` |
| Radioterapia | `PROC_RADIOTERAPIA` |
| Hemodiálise | `PROC_HEMODIALISE` |
| Total de Procedimentos | `PROC_TOTAL` |
| Consultas Médicas | `CONSULTAS_MEDICAS` |
| Consultas Nível Superior (não médicos) | `CONSULTAS_NIVEL_SUPERIOR_NAO_MEDICO` |
| Total de Consultas | `CONSULTAS_TOTAL` |
| Acolhimento c/ Classificação de Risco | `ACOLHIMENTO_CLASSIFICACAO_RISCO` |
| Partos Normais | `PARTO_NORMAL` |
| Partos Normais Alto Risco | `PARTO_NORMAL_ALTO_RISCO` |
| Cesarianas | `CESARIANA` |
| Cesarianas Alto Risco | `CESARIANA_ALTO_RISCO` |
| Cesarianas c/ Laqueadura | `CESARIANA_LAQUEADURA` |
| Total de Partos | `PARTOS_TOTAL` |
| Tomografias | `EXAMES_TOMOGRAFIA` |
| Ressonâncias | `EXAMES_RESSONANCIA` |
| Densitometrias | `EXAMES_DENSITOMETRIA` |

### Cirurgias eletivas (local de atendimento × residência)

```dax
Eletivas Realizadas na Região =
CALCULATE ( SUM ( fIndicadores[VALOR] ),
    fIndicadores[INDICADOR] = "CIRURGIAS_ELETIVAS", fIndicadores[BASE_MUNICIPIO] = "ATENDIMENTO" )

Eletivas em Residentes =
CALCULATE ( SUM ( fIndicadores[VALOR] ),
    fIndicadores[INDICADOR] = "CIRURGIAS_ELETIVAS", fIndicadores[BASE_MUNICIPIO] = "RESIDENCIA" )
```

Com a segmentação `dMunicipio[REGIAO_SAUDE]` na I GERES, a primeira mostra as
cirurgias feitas em estabelecimentos da I GERES. A segunda mostra as cirurgias
de moradores da I GERES, onde quer que tenham sido operados.

### Data da base

```dax
Último Mês SIA/SIH =
FORMAT ( CALCULATE ( MAX ( fIndicadores[Data] ), fIndicadores[INDICADOR] = "PROC_TOTAL", REMOVEFILTERS () ), "mmm/yyyy" )

Último Mês Leitos =
FORMAT ( CALCULATE ( MAX ( fIndicadores[Data] ), fIndicadores[INDICADOR] = "LEITOS_TOTAIS_SUS", REMOVEFILTERS () ), "mmm/yyyy" )
```

## 6. Filtros de cada página

| Página | Filtro no nível da página |
|---|---|
| Hospitais da rede própria | `dEstabelecimento[TIPO]` = HOSPITAL e `dEstabelecimento[VINCULO]` = REDE_PROPRIA_ESTADUAL, ESTADUAL_ADM_INDIRETA |
| UPAEs | `dEstabelecimento[TIPO]` = UPAE |
| UPAs | `dEstabelecimento[TIPO]` = UPA |
| Cirurgias eletivas, Partos, Exames | **sem** filtro de estabelecimento: são indicadores de todos os estabelecimentos de PE, filtrados por `dMunicipio[REGIAO_SAUDE]` |

Para ver também os hospitais de referência fora da rede, inclua
`REFERENCIA_FORA_DA_REDE` no filtro de `VINCULO`.

## 7. Relação de especialidades (UPAE e UPA)

Visual de *Tabela* com:

- Linhas: `fEspecialidades[NO_OCUPACAO]`
- Valores: `SUM ( fEspecialidades[QTD_APROVADA] )`
- Segmentação: `fEspecialidades[CATEGORIA]` (MEDICA ou MULTIPROFISSIONAL)
- Filtro da página: `dEstabelecimento[TIPO]` = UPAE (ou UPA)

A relação mostra as especialidades que **tiveram produção** no período, não as
apenas cadastradas.

## 8. Atualização automática no Power BI Service

Depois de publicar, em *Configurações do modelo semântico*:

1. *Credenciais da fonte de dados*: método **Anônimo**, nível de privacidade
   **Público**. Não precisa de gateway, porque a fonte é a internet.
2. *Atualização agendada*: ligue e escolha um horário depois das 09h. Os
   workflows do GitHub rodam entre 07h30 e 08h40.

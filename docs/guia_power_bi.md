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

### f_Indicadores (fato principal)

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

### f_Especialidades (CBO com consultas em UPAE e UPA)

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
| `dim_Estabelecimentos` | `dim_estabelecimento.csv` |
| `dim_Municipios` | `dim_municipio.csv` |
| `dim_Indicadores` | `dim_indicador.csv` |

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
_Calendario =
VAR _fim = MAX ( f_Indicadores[Data] )
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
| `_Calendario[Date]` | `f_Indicadores[Data]` |
| `_Calendario[Date]` | `f_Especialidades[Data]` |
| `dim_Municipios[CO_MUNICIPIO]` | `f_Indicadores[CO_MUNICIPIO]` |
| `dim_Indicadores[INDICADOR]` | `f_Indicadores[INDICADOR]` |
| `dim_Estabelecimentos[CNES]` | `f_Indicadores[CNES]` |
| `dim_Estabelecimentos[CNES]` | `f_Especialidades[CNES]` |

**Não ligue `dim_Estabelecimentos` a `dim_Municipios`.** A região da unidade já está em
`dim_Estabelecimentos[REGIAO_SAUDE]`, e uma segunda ligação criaria caminho ambíguo.
Para filtrar por GERES, use `dim_Municipios[REGIAO_SAUDE]`.

## 5. Medidas

Todas as medidas ficam numa tabela só, `_Medidas`, organizada em pastas que
seguem as páginas do painel. Crie a tabela em *Página Inicial > Inserir dados*:
nomeie `_Medidas` e clique em *Carregar*. Depois de criar a primeira medida,
oculte a coluna `Coluna1`; o Power BI passa a mostrar `_Medidas` no topo do
painel *Dados*, com ícone de calculadora.

### Estrutura de pastas

```text
_Medidas
├── 00 Base                         (medidas auxiliares, ocultas)
├── 01 Hospitais
│   ├── Leitos SUS
│   ├── Leitos Existentes
│   └── Procedimentos
├── 02 UPAE e UPA
│   ├── Consultas
│   └── Especialidades
├── 03 Cirurgias Eletivas
├── 04 Partos
├── 05 Exames
└── 99 Data da Base
```

O número na frente mantém as pastas na ordem das páginas. A barra invertida
cria subpasta: a pasta `01 Hospitais\Leitos SUS` aparece como *Leitos SUS*
dentro de *01 Hospitais*.

### Como colocar a medida na pasta

**Atalho (recomendado): exibição TMDL.** No Power BI Desktop, abra a
*Exibição TMDL* (ícone `</>` na barra da esquerda; se não aparecer, ligue em
*Opções > Recursos de visualização*). Cole o script do fim desta seção e clique
em *Aplicar*. Ele cria todas as medidas já com pasta e formato. Rodar de novo
substitui as medidas de mesmo nome, sem duplicar.

**À mão.** Na *Exibição de modelo*, selecione uma ou várias medidas com Ctrl e,
no painel *Propriedades*, preencha *Pasta de exibição* com o caminho da coluna
**Pasta** das tabelas abaixo.

### Dois tipos de indicador

- **Fluxo** (procedimentos, consultas, partos, cirurgias, exames): soma os meses
  do período selecionado.
- **Estoque** (leitos): não se soma no tempo. A medida pega o último mês do
  período selecionado.

### Pasta `00 Base`

```dax
Valor Fluxo =
CALCULATE ( SUM ( f_Indicadores[VALOR] ), f_Indicadores[BASE_MUNICIPIO] = "ATENDIMENTO" )

Valor Estoque =
VAR _ult = CALCULATE ( MAX ( f_Indicadores[Data] ), f_Indicadores[INDICADOR] = "LEITOS_TOTAIS_SUS" )
RETURN
    CALCULATE ( SUM ( f_Indicadores[VALOR] ), f_Indicadores[Data] = _ult,
                f_Indicadores[BASE_MUNICIPIO] = "ATENDIMENTO" )
```

Oculte as duas depois de criar as demais, porque só servem de base.

### Pastas `01 Hospitais\Leitos SUS` e `01 Hospitais\Leitos Existentes`

Padrão: `CALCULATE ( [Valor Estoque], f_Indicadores[INDICADOR] = "<código>" )`.

| Medida | Código do indicador | Pasta |
|---|---|---|
| Leitos UTI Adulto SUS | `LEITOS_UTI_ADULTO_SUS` | `01 Hospitais\Leitos SUS` |
| Leitos UTI Neo SUS | `LEITOS_UTI_NEONATAL_SUS` | `01 Hospitais\Leitos SUS` |
| Leitos UTI Pediátrica SUS | `LEITOS_UTI_PEDIATRICA_SUS` | `01 Hospitais\Leitos SUS` |
| Leitos Outros SUS | `LEITOS_ENFERMARIA_SUS` | `01 Hospitais\Leitos SUS` |
| Leitos Totais SUS | `LEITOS_TOTAIS_SUS` | `01 Hospitais\Leitos SUS` |
| Leitos UTI Adulto Existentes | `LEITOS_UTI_ADULTO_EXISTENTES` | `01 Hospitais\Leitos Existentes` |
| Leitos UTI Neo Existentes | `LEITOS_UTI_NEONATAL_EXISTENTES` | `01 Hospitais\Leitos Existentes` |
| Leitos UTI Pediátrica Existentes | `LEITOS_UTI_PEDIATRICA_EXISTENTES` | `01 Hospitais\Leitos Existentes` |
| Leitos Outros Existentes | `LEITOS_ENFERMARIA_EXISTENTES` | `01 Hospitais\Leitos Existentes` |
| Leitos Totais Existentes | `LEITOS_TOTAIS_EXISTENTES` | `01 Hospitais\Leitos Existentes` |

### Pastas de procedimentos, consultas, partos e exames

Padrão: `CALCULATE ( [Valor Fluxo], f_Indicadores[INDICADOR] = "<código>" )`.

| Medida | Código do indicador | Pasta |
|---|---|---|
| Promoção e Prevenção | `PROC_PROMOCAO_PREVENCAO` | `01 Hospitais\Procedimentos` |
| Proc. Diagnósticos | `PROC_DIAGNOSTICO` | `01 Hospitais\Procedimentos` |
| Proc. Clínicos | `PROC_CLINICOS` | `01 Hospitais\Procedimentos` |
| Proc. Cirúrgicos | `PROC_CIRURGICOS` | `01 Hospitais\Procedimentos` |
| Transplantes | `PROC_TRANSPLANTES` | `01 Hospitais\Procedimentos` |
| OPM | `PROC_OPM` | `01 Hospitais\Procedimentos` |
| OCI | `PROC_OCI` | `01 Hospitais\Procedimentos` |
| Radioterapia | `PROC_RADIOTERAPIA` | `01 Hospitais\Procedimentos` |
| Hemodiálise | `PROC_HEMODIALISE` | `01 Hospitais\Procedimentos` |
| Total de Procedimentos | `PROC_TOTAL` | `01 Hospitais\Procedimentos` |
| Consultas Médicas | `CONSULTAS_MEDICAS` | `02 UPAE e UPA\Consultas` |
| Consultas Nível Superior (não médicos) | `CONSULTAS_NIVEL_SUPERIOR_NAO_MEDICO` | `02 UPAE e UPA\Consultas` |
| Total de Consultas | `CONSULTAS_TOTAL` | `02 UPAE e UPA\Consultas` |
| Acolhimento c/ Classificação de Risco | `ACOLHIMENTO_CLASSIFICACAO_RISCO` | `02 UPAE e UPA\Consultas` |
| Partos Normais | `PARTO_NORMAL` | `04 Partos` |
| Partos Normais Alto Risco | `PARTO_NORMAL_ALTO_RISCO` | `04 Partos` |
| Cesarianas | `CESARIANA` | `04 Partos` |
| Cesarianas Alto Risco | `CESARIANA_ALTO_RISCO` | `04 Partos` |
| Cesarianas c/ Laqueadura | `CESARIANA_LAQUEADURA` | `04 Partos` |
| Total de Partos | `PARTOS_TOTAL` | `04 Partos` |
| Tomografias | `EXAMES_TOMOGRAFIA` | `05 Exames` |
| Ressonâncias | `EXAMES_RESSONANCIA` | `05 Exames` |
| Densitometrias | `EXAMES_DENSITOMETRIA` | `05 Exames` |

### Pasta `02 UPAE e UPA\Especialidades`

```dax
Especialidades Ofertadas = DISTINCTCOUNT ( f_Especialidades[CBO] )

Produção por Especialidade = SUM ( f_Especialidades[QTD_APROVADA] )
```

`Especialidades Ofertadas` conta as ocupações (CBO) com produção no período,
respeitando os filtros de unidade e de `f_Especialidades[CATEGORIA]`.

### Pasta `03 Cirurgias Eletivas` (local de atendimento × residência)

```dax
Eletivas Realizadas na Região =
CALCULATE ( SUM ( f_Indicadores[VALOR] ),
    f_Indicadores[INDICADOR] = "CIRURGIAS_ELETIVAS", f_Indicadores[BASE_MUNICIPIO] = "ATENDIMENTO" )

Eletivas em Residentes =
CALCULATE ( SUM ( f_Indicadores[VALOR] ),
    f_Indicadores[INDICADOR] = "CIRURGIAS_ELETIVAS", f_Indicadores[BASE_MUNICIPIO] = "RESIDENCIA" )
```

Com a segmentação `dim_Municipios[REGIAO_SAUDE]` na I GERES, a primeira mostra as
cirurgias feitas em estabelecimentos da I GERES. A segunda mostra as cirurgias
de moradores da I GERES, onde quer que tenham sido operados.

### Pasta `99 Data da Base`

```dax
Último Mês SIA/SIH =
FORMAT ( CALCULATE ( MAX ( f_Indicadores[Data] ), f_Indicadores[INDICADOR] = "PROC_TOTAL", REMOVEFILTERS () ), "mmm/yyyy" )

Último Mês Leitos =
FORMAT ( CALCULATE ( MAX ( f_Indicadores[Data] ), f_Indicadores[INDICADOR] = "LEITOS_TOTAIS_SUS", REMOVEFILTERS () ), "mmm/yyyy" )
```

### Script TMDL (todas as medidas com pasta)

Cole na *Exibição TMDL* com a tabela `_Medidas` já criada e clique em *Aplicar*.
A indentação precisa ser com **tabulação**; se o editor reclamar, selecione tudo
e use *Shift+Tab* / *Tab* para refazer o recuo.

```tmdl
createOrReplace

	ref table _Medidas

		measure 'Valor Fluxo' = CALCULATE ( SUM ( f_Indicadores[VALOR] ), f_Indicadores[BASE_MUNICIPIO] = "ATENDIMENTO" )
			formatString: #,0
			displayFolder: 00 Base
			isHidden

		measure 'Valor Estoque' = VAR _ult = CALCULATE ( MAX ( f_Indicadores[Data] ), f_Indicadores[INDICADOR] = "LEITOS_TOTAIS_SUS" ) RETURN CALCULATE ( SUM ( f_Indicadores[VALOR] ), f_Indicadores[Data] = _ult, f_Indicadores[BASE_MUNICIPIO] = "ATENDIMENTO" )
			formatString: #,0
			displayFolder: 00 Base
			isHidden

		measure 'Leitos UTI Adulto SUS' = CALCULATE ( [Valor Estoque], f_Indicadores[INDICADOR] = "LEITOS_UTI_ADULTO_SUS" )
			formatString: #,0
			displayFolder: 01 Hospitais\Leitos SUS

		measure 'Leitos UTI Neo SUS' = CALCULATE ( [Valor Estoque], f_Indicadores[INDICADOR] = "LEITOS_UTI_NEONATAL_SUS" )
			formatString: #,0
			displayFolder: 01 Hospitais\Leitos SUS

		measure 'Leitos UTI Pediátrica SUS' = CALCULATE ( [Valor Estoque], f_Indicadores[INDICADOR] = "LEITOS_UTI_PEDIATRICA_SUS" )
			formatString: #,0
			displayFolder: 01 Hospitais\Leitos SUS

		measure 'Leitos Outros SUS' = CALCULATE ( [Valor Estoque], f_Indicadores[INDICADOR] = "LEITOS_ENFERMARIA_SUS" )
			formatString: #,0
			displayFolder: 01 Hospitais\Leitos SUS

		measure 'Leitos Totais SUS' = CALCULATE ( [Valor Estoque], f_Indicadores[INDICADOR] = "LEITOS_TOTAIS_SUS" )
			formatString: #,0
			displayFolder: 01 Hospitais\Leitos SUS

		measure 'Leitos UTI Adulto Existentes' = CALCULATE ( [Valor Estoque], f_Indicadores[INDICADOR] = "LEITOS_UTI_ADULTO_EXISTENTES" )
			formatString: #,0
			displayFolder: 01 Hospitais\Leitos Existentes

		measure 'Leitos UTI Neo Existentes' = CALCULATE ( [Valor Estoque], f_Indicadores[INDICADOR] = "LEITOS_UTI_NEONATAL_EXISTENTES" )
			formatString: #,0
			displayFolder: 01 Hospitais\Leitos Existentes

		measure 'Leitos UTI Pediátrica Existentes' = CALCULATE ( [Valor Estoque], f_Indicadores[INDICADOR] = "LEITOS_UTI_PEDIATRICA_EXISTENTES" )
			formatString: #,0
			displayFolder: 01 Hospitais\Leitos Existentes

		measure 'Leitos Outros Existentes' = CALCULATE ( [Valor Estoque], f_Indicadores[INDICADOR] = "LEITOS_ENFERMARIA_EXISTENTES" )
			formatString: #,0
			displayFolder: 01 Hospitais\Leitos Existentes

		measure 'Leitos Totais Existentes' = CALCULATE ( [Valor Estoque], f_Indicadores[INDICADOR] = "LEITOS_TOTAIS_EXISTENTES" )
			formatString: #,0
			displayFolder: 01 Hospitais\Leitos Existentes

		measure 'Promoção e Prevenção' = CALCULATE ( [Valor Fluxo], f_Indicadores[INDICADOR] = "PROC_PROMOCAO_PREVENCAO" )
			formatString: #,0
			displayFolder: 01 Hospitais\Procedimentos

		measure 'Proc. Diagnósticos' = CALCULATE ( [Valor Fluxo], f_Indicadores[INDICADOR] = "PROC_DIAGNOSTICO" )
			formatString: #,0
			displayFolder: 01 Hospitais\Procedimentos

		measure 'Proc. Clínicos' = CALCULATE ( [Valor Fluxo], f_Indicadores[INDICADOR] = "PROC_CLINICOS" )
			formatString: #,0
			displayFolder: 01 Hospitais\Procedimentos

		measure 'Proc. Cirúrgicos' = CALCULATE ( [Valor Fluxo], f_Indicadores[INDICADOR] = "PROC_CIRURGICOS" )
			formatString: #,0
			displayFolder: 01 Hospitais\Procedimentos

		measure 'Transplantes' = CALCULATE ( [Valor Fluxo], f_Indicadores[INDICADOR] = "PROC_TRANSPLANTES" )
			formatString: #,0
			displayFolder: 01 Hospitais\Procedimentos

		measure 'OPM' = CALCULATE ( [Valor Fluxo], f_Indicadores[INDICADOR] = "PROC_OPM" )
			formatString: #,0
			displayFolder: 01 Hospitais\Procedimentos

		measure 'OCI' = CALCULATE ( [Valor Fluxo], f_Indicadores[INDICADOR] = "PROC_OCI" )
			formatString: #,0
			displayFolder: 01 Hospitais\Procedimentos

		measure 'Radioterapia' = CALCULATE ( [Valor Fluxo], f_Indicadores[INDICADOR] = "PROC_RADIOTERAPIA" )
			formatString: #,0
			displayFolder: 01 Hospitais\Procedimentos

		measure 'Hemodiálise' = CALCULATE ( [Valor Fluxo], f_Indicadores[INDICADOR] = "PROC_HEMODIALISE" )
			formatString: #,0
			displayFolder: 01 Hospitais\Procedimentos

		measure 'Total de Procedimentos' = CALCULATE ( [Valor Fluxo], f_Indicadores[INDICADOR] = "PROC_TOTAL" )
			formatString: #,0
			displayFolder: 01 Hospitais\Procedimentos

		measure 'Consultas Médicas' = CALCULATE ( [Valor Fluxo], f_Indicadores[INDICADOR] = "CONSULTAS_MEDICAS" )
			formatString: #,0
			displayFolder: 02 UPAE e UPA\Consultas

		measure 'Consultas Nível Superior (não médicos)' = CALCULATE ( [Valor Fluxo], f_Indicadores[INDICADOR] = "CONSULTAS_NIVEL_SUPERIOR_NAO_MEDICO" )
			formatString: #,0
			displayFolder: 02 UPAE e UPA\Consultas

		measure 'Total de Consultas' = CALCULATE ( [Valor Fluxo], f_Indicadores[INDICADOR] = "CONSULTAS_TOTAL" )
			formatString: #,0
			displayFolder: 02 UPAE e UPA\Consultas

		measure 'Acolhimento c/ Classificação de Risco' = CALCULATE ( [Valor Fluxo], f_Indicadores[INDICADOR] = "ACOLHIMENTO_CLASSIFICACAO_RISCO" )
			formatString: #,0
			displayFolder: 02 UPAE e UPA\Consultas

		measure 'Partos Normais' = CALCULATE ( [Valor Fluxo], f_Indicadores[INDICADOR] = "PARTO_NORMAL" )
			formatString: #,0
			displayFolder: 04 Partos

		measure 'Partos Normais Alto Risco' = CALCULATE ( [Valor Fluxo], f_Indicadores[INDICADOR] = "PARTO_NORMAL_ALTO_RISCO" )
			formatString: #,0
			displayFolder: 04 Partos

		measure 'Cesarianas' = CALCULATE ( [Valor Fluxo], f_Indicadores[INDICADOR] = "CESARIANA" )
			formatString: #,0
			displayFolder: 04 Partos

		measure 'Cesarianas Alto Risco' = CALCULATE ( [Valor Fluxo], f_Indicadores[INDICADOR] = "CESARIANA_ALTO_RISCO" )
			formatString: #,0
			displayFolder: 04 Partos

		measure 'Cesarianas c/ Laqueadura' = CALCULATE ( [Valor Fluxo], f_Indicadores[INDICADOR] = "CESARIANA_LAQUEADURA" )
			formatString: #,0
			displayFolder: 04 Partos

		measure 'Total de Partos' = CALCULATE ( [Valor Fluxo], f_Indicadores[INDICADOR] = "PARTOS_TOTAL" )
			formatString: #,0
			displayFolder: 04 Partos

		measure 'Tomografias' = CALCULATE ( [Valor Fluxo], f_Indicadores[INDICADOR] = "EXAMES_TOMOGRAFIA" )
			formatString: #,0
			displayFolder: 05 Exames

		measure 'Ressonâncias' = CALCULATE ( [Valor Fluxo], f_Indicadores[INDICADOR] = "EXAMES_RESSONANCIA" )
			formatString: #,0
			displayFolder: 05 Exames

		measure 'Densitometrias' = CALCULATE ( [Valor Fluxo], f_Indicadores[INDICADOR] = "EXAMES_DENSITOMETRIA" )
			formatString: #,0
			displayFolder: 05 Exames

		measure 'Especialidades Ofertadas' = DISTINCTCOUNT ( f_Especialidades[CBO] )
			formatString: #,0
			displayFolder: 02 UPAE e UPA\Especialidades

		measure 'Produção por Especialidade' = SUM ( f_Especialidades[QTD_APROVADA] )
			formatString: #,0
			displayFolder: 02 UPAE e UPA\Especialidades

		measure 'Eletivas Realizadas na Região' = CALCULATE ( SUM ( f_Indicadores[VALOR] ), f_Indicadores[INDICADOR] = "CIRURGIAS_ELETIVAS", f_Indicadores[BASE_MUNICIPIO] = "ATENDIMENTO" )
			formatString: #,0
			displayFolder: 03 Cirurgias Eletivas

		measure 'Eletivas em Residentes' = CALCULATE ( SUM ( f_Indicadores[VALOR] ), f_Indicadores[INDICADOR] = "CIRURGIAS_ELETIVAS", f_Indicadores[BASE_MUNICIPIO] = "RESIDENCIA" )
			formatString: #,0
			displayFolder: 03 Cirurgias Eletivas

		measure 'Último Mês SIA/SIH' = FORMAT ( CALCULATE ( MAX ( f_Indicadores[Data] ), f_Indicadores[INDICADOR] = "PROC_TOTAL", REMOVEFILTERS () ), "mmm/yyyy" )
			displayFolder: 99 Data da Base

		measure 'Último Mês Leitos' = FORMAT ( CALCULATE ( MAX ( f_Indicadores[Data] ), f_Indicadores[INDICADOR] = "LEITOS_TOTAIS_SUS", REMOVEFILTERS () ), "mmm/yyyy" )
			displayFolder: 99 Data da Base
```

Os leitos existentes não somam com os SUS: são uma visão alternativa da mesma
capacidade, para mostrar ao lado.

## 6. Filtros de cada página

| Página | Filtro no nível da página |
|---|---|
| Hospitais da rede própria | `dim_Estabelecimentos[TIPO]` = HOSPITAL e `dim_Estabelecimentos[VINCULO]` = REDE_PROPRIA_ESTADUAL, ESTADUAL_ADM_INDIRETA |
| UPAEs | `dim_Estabelecimentos[TIPO]` = UPAE |
| UPAs | `dim_Estabelecimentos[TIPO]` = UPA |
| Cirurgias eletivas, Partos, Exames | **sem** filtro de estabelecimento: são indicadores de todos os estabelecimentos de PE, filtrados por `dim_Municipios[REGIAO_SAUDE]` |

Para ver também os hospitais de referência fora da rede, inclua
`REFERENCIA_FORA_DA_REDE` no filtro de `VINCULO`.

## 7. Relação de especialidades (UPAE e UPA)

Visual de *Tabela* com:

- Linhas: `f_Especialidades[NO_OCUPACAO]`
- Valores: `[Produção por Especialidade]`
- Cartão ao lado: `[Especialidades Ofertadas]`
- Segmentação: `f_Especialidades[CATEGORIA]` (MEDICA ou MULTIPROFISSIONAL)
- Filtro da página: `dim_Estabelecimentos[TIPO]` = UPAE (ou UPA)

A relação mostra as especialidades que **tiveram produção** no período, não as
apenas cadastradas.

## 8. Atualização automática no Power BI Service

Depois de publicar, em *Configurações do modelo semântico*:

1. *Credenciais da fonte de dados*: método **Anônimo**, nível de privacidade
   **Público**. Não precisa de gateway, porque a fonte é a internet.
2. *Atualização agendada*: ligue e escolha um horário depois das 09h. Os
   workflows do GitHub rodam entre 07h30 e 08h40.

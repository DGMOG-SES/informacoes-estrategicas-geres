#!/usr/bin/env Rscript
# ------------------------------------------------------------------------------
# Tabela de indicadores para o Power BI, a partir das bases já extraídas
# (leitos.R, producao_sia.R, producao_sih.R) e da lista validada de unidades.
#
# Saídas em dados/saida/:
#   indicadores.{parquet,csv}  formato longo: COMPETENCIA, CNES, CO_MUNICIPIO,
#                              BASE_MUNICIPIO (ATENDIMENTO/RESIDENCIA), INDICADOR, VALOR
#   especialidades.parquet     CBO com produção de consultas em UPAE/UPA, por mês
#   dim_indicador.csv          nome, seção e regra de cada indicador
#   dim_estabelecimento.csv    lista validada com código de município
#   dim_municipio.csv          município -> Região de Saúde/GERES
#   dim_procedimento.csv, dim_ocupacao.csv  nomes do SIGTAP vigente
#
# Competência = mês de processamento (SIA: PA_MVM; SIH: ANO_CMPT/MES_CMPT;
# CNES: competência do arquivo). Quantidades do SIA = aprovadas (PA_QTDAPR).
# ------------------------------------------------------------------------------

source("utils.R")

SAIDA <- file.path(CFG$dir_dados, "saida")
FTP_SIGTAP <- "ftp://ftp2.datasus.gov.br/pub/sistemas/tup/downloads/"

# Procedimentos de consulta/atendimento (grupo 0301) usados em UPAE e UPA.
# Médico ou não médico é decidido pelo CBO do profissional.
CONSULTAS <- c(
  "0301010072",  # consulta médica em atenção especializada
  "0301010048",  # consulta de profissional de nível superior na atenção especializada (exceto médico)
  "0301010064",  # consulta médica em atenção primária
  "0301010030",  # consulta de profissional de nível superior na atenção primária (exceto médico)
  "0301060096",  # atendimento médico em UPA 24h
  "0301060029",  # atendimento de urgência c/ observação até 24 h em atenção especializada
  "0301060061"   # atendimento de urgência em atenção especializada
)
eh_medico <- function(cbo) startsWith(cbo, "225") | startsWith(cbo, "2231")
eh_superior_nao_medico <- function(cbo) startsWith(cbo, "2") & !eh_medico(cbo) & nchar(cbo) == 6

PARTOS <- list(
  PARTO_NORMAL            = c("0310010039", "0310010055"),
  PARTO_NORMAL_ALTO_RISCO = "0310010047",
  CESARIANA               = "0411010034",
  CESARIANA_ALTO_RISCO    = "0411010026",
  CESARIANA_LAQUEADURA    = "0411010042"
)

GRUPOS <- c("01" = "PROC_PROMOCAO_PREVENCAO", "02" = "PROC_DIAGNOSTICO", "03" = "PROC_CLINICOS",
            "04" = "PROC_CIRURGICOS", "05" = "PROC_TRANSPLANTES", "07" = "PROC_OPM", "09" = "PROC_OCI")

ler_pq <- function(nome) as.data.table(arrow::read_parquet(file.path(SAIDA, nome)))

# ---- SIGTAP ----------------------------------------------------------------------

ler_sigtap <- function(dir, tabela) {
  lay <- fread(file.path(dir, paste0(tabela, "_layout.txt")), colClasses = "character")
  linhas <- enc2utf8(iconv(readLines(file.path(dir, paste0(tabela, ".txt")), warn = FALSE), "latin1", "UTF-8"))
  as.data.table(setNames(lapply(seq_len(nrow(lay)), function(i)
    trimws(substr(linhas, as.integer(lay$Inicio[i]), as.integer(lay$Fim[i])))), lay$Coluna))
}

baixar_sigtap <- function() {
  res <- com_tentativas(function() curl_fetch_memory(FTP_SIGTAP, handle = novo_handle()), "listar SIGTAP")
  lst <- interpretar_listagem(strsplit(rawToChar(res$content), "\r?\n")[[1]])
  zip <- tail(sort(grep("^TabelaUnificada_\\d{6}_v\\d+\\.zip$", lst$nome, value = TRUE)), 1)
  log_msg("SIGTAP: %s", zip)
  arq <- tempfile(fileext = ".zip")
  com_tentativas(function() curl_download(paste0(FTP_SIGTAP, zip), arq, handle = novo_handle(), quiet = TRUE),
                 "baixar SIGTAP")
  dir <- tempfile(); dir.create(dir)
  tabs <- c("tb_procedimento", "tb_grupo", "tb_ocupacao")
  unzip(arq, exdir = dir, files = paste0(rep(tabs, each = 2), c(".txt", "_layout.txt")))
  proc <- ler_sigtap(dir, "tb_procedimento")[, .(CO_PROCEDIMENTO, NO_PROCEDIMENTO)]
  proc[, CO_GRUPO := substr(CO_PROCEDIMENTO, 1, 2)]
  proc <- merge(proc, ler_sigtap(dir, "tb_grupo")[, .(CO_GRUPO, NO_GRUPO)], by = "CO_GRUPO", all.x = TRUE)
  list(proc = proc, ocup = ler_sigtap(dir, "tb_ocupacao")[, .(CBO = CO_OCUPACAO, NO_OCUPACAO)])
}

# ---- Indicadores -------------------------------------------------------------------

linha <- function(dt, indicador, base = "ATENDIMENTO") {
  dt[, .(COMPETENCIA, CNES, CO_MUNICIPIO, BASE_MUNICIPIO = base, INDICADOR = indicador, VALOR)]
}

main <- function() {
  bases <- c("leitos_pe.parquet", "sia_estabelecimentos.parquet", "sia_exames_pe.parquet",
             "sih_aih_pe.parquet", "sih_servicos.parquet")
  faltam <- bases[!file.exists(file.path(SAIDA, bases))]
  if (length(faltam)) {
    log_msg("Indicadores não gerados; faltam as bases: %s", paste(faltam, collapse = ", "))
    return(invisible(NULL))
  }
  estab <- fread("referencias/estabelecimentos_validados.csv", colClasses = "character", encoding = "UTF-8")
  cand <- fread(file.path(CFG$dir_dados, "referencias", "cnes_candidatos.csv"),
                colClasses = "character", encoding = "UTF-8")
  estab <- merge(estab, cand[, .(CNES, CO_MUNICIPIO = CODUFMUN)], by = "CNES", all.x = TRUE)
  rede <- estab[VINCULO != "REFERENCIA_FORA_DA_REDE"]
  hosp <- estab[TIPO == "HOSPITAL"]$CNES
  mun_cnes <- estab[, .(CNES, CO_MUNICIPIO)]
  out <- list()

  # Leitos (todos os estabelecimentos de PE; o painel filtra pela lista validada)
  lt <- ler_pq("leitos_pe.parquet")
  for (medida in c("QT_SUS", "QT_EXIST")) {
    suf <- if (medida == "QT_SUS") "SUS" else "EXISTENTES"
    l <- lt[, .(VALOR = sum(get(medida))), by = .(COMPETENCIA, CNES, CO_MUNICIPIO = CODUFMUN, CATEGORIA)]
    for (cat in c("UTI_ADULTO", "UTI_NEONATAL", "UTI_PEDIATRICA", "ENFERMARIA", "COMPLEMENTAR_NAO_UTI"))
      out[[length(out) + 1]] <- linha(l[CATEGORIA == cat], paste0("LEITOS_", cat, "_", suf))
    tot <- l[CATEGORIA != "COMPLEMENTAR_NAO_UTI", .(VALOR = sum(VALOR)), by = .(COMPETENCIA, CNES, CO_MUNICIPIO)]
    out[[length(out) + 1]] <- linha(tot, paste0("LEITOS_TOTAIS_", suf))
  }

  # SIA das unidades validadas
  sia <- ler_pq("sia_estabelecimentos.parquet")
  sia <- merge(sia, mun_cnes, by = "CNES")
  sia[, `:=`(COMPETENCIA = PA_MVM, GRUPO = substr(PA_PROC_ID, 1, 2))]

  # SIH: AIH (procedimento principal) e atos de OPM
  aih <- ler_pq("sih_aih_pe.parquet")
  sp  <- ler_pq("sih_servicos.parquet")

  # Procedimentos por grupo SIGTAP nos hospitais = SIA (aprovada) + AIH por
  # procedimento principal; OPM (07) do SIH vem dos atos (SP), pois não é procedimento principal.
  amb <- sia[CNES %chin% hosp, .(VALOR = sum(QTD_APROVADA)), by = .(COMPETENCIA, CNES, CO_MUNICIPIO, GRUPO, PA_PROC_ID)]
  hos <- aih[CNES %chin% hosp, .(VALOR = sum(N_AIH)), by = .(COMPETENCIA, CNES, GRUPO = substr(PROC_REA, 1, 2), PA_PROC_ID = PROC_REA)]
  opm <- sp[CNES %chin% hosp & startsWith(PROC_ATO, "07"), .(VALOR = sum(QTD_ATO)), by = .(COMPETENCIA, CNES, PA_PROC_ID = PROC_ATO)]
  opm[, GRUPO := "07"]
  hos <- merge(rbind(hos, opm), mun_cnes, by = "CNES")
  proc_h <- rbind(amb, hos, use.names = TRUE)
  for (g in names(GRUPOS)) {
    out[[length(out) + 1]] <- linha(proc_h[GRUPO == g, .(VALOR = sum(VALOR)), by = .(COMPETENCIA, CNES, CO_MUNICIPIO)], GRUPOS[[g]])
  }
  out[[length(out) + 1]] <- linha(proc_h[GRUPO %chin% names(GRUPOS), .(VALOR = sum(VALOR)), by = .(COMPETENCIA, CNES, CO_MUNICIPIO)], "PROC_TOTAL")
  out[[length(out) + 1]] <- linha(proc_h[startsWith(PA_PROC_ID, "030401"), .(VALOR = sum(VALOR)), by = .(COMPETENCIA, CNES, CO_MUNICIPIO)], "PROC_RADIOTERAPIA")
  out[[length(out) + 1]] <- linha(proc_h[startsWith(PA_PROC_ID, "030501"), .(VALOR = sum(VALOR)), by = .(COMPETENCIA, CNES, CO_MUNICIPIO)], "PROC_HEMODIALISE")

  # Consultas em UPAE e UPA
  cons <- sia[CNES %chin% estab[TIPO %chin% c("UPAE", "UPA")]$CNES & PA_PROC_ID %chin% CONSULTAS]
  out[[length(out) + 1]] <- linha(cons[eh_medico(CBO), .(VALOR = sum(QTD_APROVADA)), by = .(COMPETENCIA, CNES, CO_MUNICIPIO)], "CONSULTAS_MEDICAS")
  out[[length(out) + 1]] <- linha(cons[eh_superior_nao_medico(CBO), .(VALOR = sum(QTD_APROVADA)), by = .(COMPETENCIA, CNES, CO_MUNICIPIO)], "CONSULTAS_NIVEL_SUPERIOR_NAO_MEDICO")
  out[[length(out) + 1]] <- linha(cons[eh_medico(CBO) | eh_superior_nao_medico(CBO), .(VALOR = sum(QTD_APROVADA)), by = .(COMPETENCIA, CNES, CO_MUNICIPIO)], "CONSULTAS_TOTAL")
  out[[length(out) + 1]] <- linha(sia[CNES %chin% estab[TIPO %chin% c("UPAE", "UPA")]$CNES & PA_PROC_ID == "0301060118",
                                      .(VALOR = sum(QTD_APROVADA)), by = .(COMPETENCIA, CNES, CO_MUNICIPIO)], "ACOLHIMENTO_CLASSIFICACAO_RISCO")
  esp <- cons[eh_medico(CBO) | eh_superior_nao_medico(CBO),
              .(QTD_APROVADA = sum(QTD_APROVADA)), by = .(COMPETENCIA, CNES, CBO)]
  esp[, CATEGORIA := fifelse(eh_medico(CBO), "MEDICA", "MULTIPROFISSIONAL")]

  # Partos (AIH normais, todos os estabelecimentos de PE)
  a1 <- aih[IDENT == "1"]
  for (nm in names(PARTOS)) {
    out[[length(out) + 1]] <- linha(a1[PROC_REA %chin% PARTOS[[nm]], .(VALOR = sum(N_AIH)),
                                       by = .(COMPETENCIA, CNES, CO_MUNICIPIO = MUNIC_MOV)], nm)
  }
  out[[length(out) + 1]] <- linha(a1[PROC_REA %chin% unlist(PARTOS), .(VALOR = sum(N_AIH)),
                                     by = .(COMPETENCIA, CNES, CO_MUNICIPIO = MUNIC_MOV)], "PARTOS_TOTAL")

  # Cirurgias eletivas: grupo 04, caráter eletivo, AIH normal
  ele <- a1[startsWith(PROC_REA, "04") & CAR_INT == "01"]
  out[[length(out) + 1]] <- linha(ele[, .(VALOR = sum(N_AIH)), by = .(COMPETENCIA, CNES, CO_MUNICIPIO = MUNIC_MOV)], "CIRURGIAS_ELETIVAS")
  out[[length(out) + 1]] <- linha(ele[startsWith(MUNIC_RES, "26"), .(VALOR = sum(N_AIH)), by = .(COMPETENCIA, CNES, CO_MUNICIPIO = MUNIC_RES)],
                                  "CIRURGIAS_ELETIVAS", base = "RESIDENCIA")

  # Exames de alta complexidade (SIA, todos os estabelecimentos de PE)
  ex <- ler_pq("sia_exames_pe.parquet")
  ex[, COMPETENCIA := PA_MVM]
  out[[length(out) + 1]] <- linha(ex[startsWith(PA_PROC_ID, "0206"), .(VALOR = sum(QTD_APROVADA)), by = .(COMPETENCIA, CNES, CO_MUNICIPIO = PA_UFMUN)], "EXAMES_TOMOGRAFIA")
  out[[length(out) + 1]] <- linha(ex[startsWith(PA_PROC_ID, "0207"), .(VALOR = sum(QTD_APROVADA)), by = .(COMPETENCIA, CNES, CO_MUNICIPIO = PA_UFMUN)], "EXAMES_RESSONANCIA")
  out[[length(out) + 1]] <- linha(ex[PA_PROC_ID == "0204060028", .(VALOR = sum(QTD_APROVADA)), by = .(COMPETENCIA, CNES, CO_MUNICIPIO = PA_UFMUN)], "EXAMES_DENSITOMETRIA")

  ind <- rbindlist(out, use.names = TRUE)[VALOR != 0]
  setorder(ind, INDICADOR, COMPETENCIA, CNES)
  gravar_atomico(function(f) arrow::write_parquet(ind, f), file.path(SAIDA, "indicadores.parquet"))
  gravar_atomico(function(f) fwrite(ind, f, sep = ";", bom = TRUE), file.path(SAIDA, "indicadores.csv"))
  log_msg("indicadores: %d linhas, %d indicadores", nrow(ind), uniqueN(ind$INDICADOR))

  # Dimensões
  sig <- tryCatch(baixar_sigtap(), error = function(e) { log_msg("SIGTAP indisponível: %s", conditionMessage(e)); NULL })
  if (!is.null(sig)) {
    esp <- merge(esp, sig$ocup, by = "CBO", all.x = TRUE)
    fwrite(sig$proc, file.path(SAIDA, "dim_procedimento.csv"), sep = ";", bom = TRUE)
    fwrite(sig$ocup, file.path(SAIDA, "dim_ocupacao.csv"), sep = ";", bom = TRUE)
  }
  gravar_atomico(function(f) arrow::write_parquet(esp, f), file.path(SAIDA, "especialidades.parquet"))
  fwrite(estab, file.path(SAIDA, "dim_estabelecimento.csv"), sep = ";", bom = TRUE)
  file.copy("referencias/municipios_regiao_saude_pe.csv", file.path(SAIDA, "dim_municipio.csv"), overwrite = TRUE)
  file.copy("referencias/dim_indicador.csv", file.path(SAIDA, "dim_indicador.csv"), overwrite = TRUE)
}

if (sys.nframe() == 0L) main()

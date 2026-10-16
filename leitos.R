#!/usr/bin/env Rscript
# ------------------------------------------------------------------------------
# Série mensal de leitos de PE (CNES-LT, arquivos LTPEaamm.dbc).
#
# Para cada competência grava um arquivo em dados/leitos/mensal/ e consolida tudo
# em dados/saida/leitos_pe.{csv,parquet}, no formato longo:
#   COMPETENCIA, CNES, CODUFMUN, CATEGORIA, QT_SUS, QT_EXIST
# CATEGORIA: UTI_ADULTO, UTI_NEONATAL, UTI_PEDIATRICA, ENFERMARIA,
#            COMPLEMENTAR_NAO_UTI (UCI, unidade intermediária, isolamento).
# Leitos totais = UTI + ENFERMARIA, contados por QT_SUS (decisão da SES).
#
# Só baixa competências novas ou republicadas (compara nome, tamanho e data).
# Uso: Rscript leitos.R [--reprocessar-tudo]
# ------------------------------------------------------------------------------

source("utils.R")

LEITOS <- list(
  ftp    = "ftp://ftp.datasus.gov.br/dissemin/publicos/CNES/200508_/Dados/LT/",
  uf     = "PE",
  inicio = "202201",   # primeira competência da série
  dir    = file.path(CFG$dir_dados, "leitos", "mensal"),
  controle = file.path(CFG$dir_dados, "controle", "leitos_processados.csv"),
  saida  = file.path(CFG$dir_dados, "saida", "leitos_pe")
)

processar <- function(nome, competencia) {
  destino <- file.path(tempdir(), nome)
  com_tentativas(function() curl_download(paste0(LEITOS$ftp, nome), destino,
                                          handle = novo_handle(), quiet = TRUE),
                 paste("baixar", nome))
  lt <- ler_arquivo(destino)
  unlink(destino)
  lt[, `:=`(QT_SUS = as.integer(QT_SUS), QT_EXIST = as.integer(QT_EXIST))]
  lt[, `:=`(CATEGORIA = categoria_leito(as.character(TP_LEITO), as.character(CODLEITO)),
            COMPETENCIA = competencia)]
  lt[, .(QT_SUS = sum(QT_SUS, na.rm = TRUE), QT_EXIST = sum(QT_EXIST, na.rm = TRUE)),
     by = .(COMPETENCIA, CNES, CODUFMUN, CATEGORIA)]
}

consolidar <- function() {
  arqs <- list.files(LEITOS$dir, "^leitos_.*\\.csv$", full.names = TRUE)
  if (!length(arqs)) return(invisible(NULL))
  base <- rbindlist(lapply(arqs, fread, colClasses = c(COMPETENCIA = "character",
                                                      CNES = "character",
                                                      CODUFMUN = "character")))
  setorder(base, COMPETENCIA, CNES, CATEGORIA)
  dir.create(dirname(LEITOS$saida), recursive = TRUE, showWarnings = FALSE)
  gravar_atomico(function(f) fwrite(base, f, sep = ";", bom = TRUE), paste0(LEITOS$saida, ".csv"))
  if (requireNamespace("arrow", quietly = TRUE)) {
    gravar_atomico(function(f) arrow::write_parquet(base, f), paste0(LEITOS$saida, ".parquet"))
  }
  log_msg("leitos_pe: %d linhas, %d competências", nrow(base), uniqueN(base$COMPETENCIA))
}

main <- function() {
  reprocessar <- "--reprocessar-tudo" %in% commandArgs(trailingOnly = TRUE)
  dir.create(LEITOS$dir, recursive = TRUE, showWarnings = FALSE)
  dir.create(dirname(LEITOS$controle), recursive = TRUE, showWarnings = FALSE)

  ftp <- listar_competencias(LEITOS$ftp, paste0("LT", LEITOS$uf))[competencia >= LEITOS$inicio]
  ftp[, assinatura := paste(nome, tamanho, data, sep = "|")]
  ctrl <- if (file.exists(LEITOS$controle)) fread(LEITOS$controle, colClasses = "character") else
    data.table(competencia = character(), assinatura = character())
  pendentes <- if (reprocessar) ftp else ftp[!ctrl, on = .(competencia, assinatura)]
  log_msg("%d competências no FTP desde %s; %d a processar", nrow(ftp), LEITOS$inicio, nrow(pendentes))

  falhas <- character()
  for (i in seq_len(nrow(pendentes))) {
    p <- pendentes[i]
    ok <- tryCatch({
      dt <- processar(p$nome, p$competencia)
      gravar_atomico(function(f) fwrite(dt, f),
                     file.path(LEITOS$dir, sprintf("leitos_%s_%s.csv", LEITOS$uf, p$competencia)))
      ctrl <- rbind(ctrl[competencia != p$competencia],
                    data.table(competencia = p$competencia, assinatura = p$assinatura))
      gravar_atomico(function(f) fwrite(ctrl, f), LEITOS$controle)
      log_msg("Competência %s: %d linhas", p$competencia, nrow(dt))
      TRUE
    }, error = function(e) { log_msg("ERRO em %s: %s", p$competencia, conditionMessage(e)); FALSE })
    if (!ok) falhas <- c(falhas, p$competencia)
  }

  consolidar()
  if (length(falhas)) {
    log_msg("Competências com falha (tentadas de novo na próxima execução): %s", paste(falhas, collapse = ", "))
    quit(status = 1)
  }
}

if (sys.nframe() == 0L) main()

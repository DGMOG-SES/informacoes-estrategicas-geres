#!/usr/bin/env Rscript
# ------------------------------------------------------------------------------
# Produção ambulatorial do SIA/SUS de PE (arquivos PAPEaamm[a,b,...].dbc), por
# movimento (competência de processamento, PA_MVM).
#
# Saídas (Parquet), uma partição por movimento e uma base consolidada:
#   dados/sia/estabelecimentos/  -> dados/saida/sia_estabelecimentos.parquet
#     Unidades de referencias/estabelecimentos_validados.csv, por
#     PA_MVM, PA_CMP, CNES, PA_PROC_ID e CBO. O CBO só é mantido nos
#     procedimentos 0301 (consultas e atendimentos); nos demais fica vazio.
#   dados/sia/exames/            -> dados/saida/sia_exames_pe.parquet
#     Todos os estabelecimentos de PE, só TC (0206), RNM (0207) e densitometria
#     óssea (0204060028), por PA_MVM, PA_CMP, CNES, PA_UFMUN e PA_PROC_ID.
# Medidas: QTD_APROVADA (PA_QTDAPR) e QTD_APRESENTADA (PA_QTDPRO).
#
# Só baixa movimentos novos ou republicados. Cada execução processa no máximo
# SIA$max_por_execucao movimentos, para caber no tempo do GitHub Actions; a
# carga histórica se completa em execuções seguidas.
# Uso: Rscript producao_sia.R [--reprocessar-tudo]
# ------------------------------------------------------------------------------

source("utils.R")

SIA <- list(
  ftp    = "ftp://ftp.datasus.gov.br/dissemin/publicos/SIASUS/200801_/Dados/",
  uf     = "PE",
  inicio = "202201",
  max_por_execucao = 15,
  dir    = file.path(CFG$dir_dados, "sia"),
  controle = file.path(CFG$dir_dados, "controle", "sia_processados.csv"),
  exames = c("0206", "0207", "0204060028")
)

COLS <- c("PA_CODUNI", "PA_CMP", "PA_MVM", "PA_UFMUN", "PA_PROC_ID", "PA_CBOCOD",
          "PA_QTDAPR", "PA_QTDPRO")

listar_sia <- function() {
  res <- com_tentativas(function() curl_fetch_memory(SIA$ftp, handle = novo_handle()), "listar SIA")
  lst <- interpretar_listagem(strsplit(rawToChar(res$content), "\r?\n")[[1]])
  padrao <- sprintf("^PA%s(\\d{2})(\\d{2})([a-z]?)\\.dbc$", SIA$uf)
  lst <- lst[grepl(padrao, nome, ignore.case = TRUE)]
  lst[, mvm := sub(padrao, "20\\1\\2", nome, ignore.case = TRUE)]
  lst <- lst[mvm >= SIA$inicio]
  setorder(lst, mvm, nome)
  lst[, assinatura := paste(nome, tamanho, data, sep = "|")]
  lst
}

ler_parte <- function(nome, mvm, cnes_validos) {
  destino <- file.path(tempdir(), nome)
  com_tentativas(function() curl_download(paste0(SIA$ftp, nome), destino,
                                          handle = novo_handle(), quiet = TRUE),
                 paste("baixar", nome))
  on.exit(unlink(destino))
  dt <- ler_arquivo(destino)
  if (!"PA_MVM" %in% names(dt)) dt[, PA_MVM := mvm]
  if (!"PA_CBOCOD" %in% names(dt)) dt[, PA_CBOCOD := NA_character_]
  dt <- dt[, intersect(COLS, names(dt)), with = FALSE]
  for (cl in setdiff(COLS, c("PA_QTDAPR", "PA_QTDPRO"))) set(dt, j = cl, value = trimws(as.character(dt[[cl]])))
  dt[, `:=`(PA_QTDAPR = as.numeric(PA_QTDAPR), PA_QTDPRO = as.numeric(PA_QTDPRO))]
  n <- nrow(dt)

  estab <- dt[PA_CODUNI %chin% cnes_validos]
  estab[!startsWith(PA_PROC_ID, "0301"), PA_CBOCOD := ""]
  estab <- estab[, .(QTD_APROVADA = sum(PA_QTDAPR, na.rm = TRUE),
                     QTD_APRESENTADA = sum(PA_QTDPRO, na.rm = TRUE)),
                 by = .(PA_MVM, PA_CMP, CNES = PA_CODUNI, PA_PROC_ID, CBO = PA_CBOCOD)]

  ex <- dt[Reduce(`|`, lapply(SIA$exames, function(p) startsWith(PA_PROC_ID, p)))]
  ex <- ex[, .(QTD_APROVADA = sum(PA_QTDAPR, na.rm = TRUE),
               QTD_APRESENTADA = sum(PA_QTDPRO, na.rm = TRUE)),
           by = .(PA_MVM, PA_CMP, CNES = PA_CODUNI, PA_UFMUN, PA_PROC_ID)]
  rm(dt); gc(verbose = FALSE)
  log_msg("  %s: %s registros; %d linhas de estabelecimentos, %d de exames",
          nome, format(n, big.mark = "."), nrow(estab), nrow(ex))
  list(estab = estab, exames = ex)
}

somar <- function(dt, chaves) {
  dt[, .(QTD_APROVADA = sum(QTD_APROVADA), QTD_APRESENTADA = sum(QTD_APRESENTADA)), by = chaves]
}

consolidar <- function(sub, saida) {
  arqs <- list.files(file.path(SIA$dir, sub), "\\.parquet$", full.names = TRUE)
  if (!length(arqs)) return(invisible(NULL))
  base <- rbindlist(lapply(arqs, arrow::read_parquet), use.names = TRUE)
  dir.create(file.path(CFG$dir_dados, "saida"), recursive = TRUE, showWarnings = FALSE)
  gravar_atomico(function(f) arrow::write_parquet(base, f), file.path(CFG$dir_dados, "saida", saida))
  log_msg("%s: %d linhas, %d movimentos", saida, nrow(base), uniqueN(base$PA_MVM))
}

main <- function() {
  reprocessar <- "--reprocessar-tudo" %in% commandArgs(trailingOnly = TRUE)
  for (d in c("estabelecimentos", "exames")) dir.create(file.path(SIA$dir, d), recursive = TRUE, showWarnings = FALSE)
  dir.create(dirname(SIA$controle), recursive = TRUE, showWarnings = FALSE)
  cnes_validos <- fread("referencias/estabelecimentos_validados.csv", colClasses = "character",
                        encoding = "UTF-8")$CNES

  ftp <- listar_sia()
  movs <- ftp[, .(assinatura = paste(assinatura, collapse = ";")), by = mvm]
  ctrl <- if (file.exists(SIA$controle)) fread(SIA$controle, colClasses = "character") else
    data.table(mvm = character(), assinatura = character(), processado_em = character())
  pend <- if (reprocessar) movs else movs[!ctrl, on = .(mvm, assinatura)]
  # Mais recentes primeiro: o mês novo entra logo; o histórico vem nas execuções seguintes.
  setorder(pend, -mvm)
  log_msg("%d movimentos no FTP desde %s; %d pendentes; processando até %d",
          nrow(movs), SIA$inicio, nrow(pend), SIA$max_por_execucao)
  pend <- head(pend, SIA$max_por_execucao)

  falhas <- character()
  for (m in pend$mvm) {
    log_msg("Movimento %s", m)
    ok <- tryCatch({
      partes <- lapply(ftp[mvm == m]$nome, ler_parte, mvm = m, cnes_validos = cnes_validos)
      estab <- somar(rbindlist(lapply(partes, `[[`, "estab")), c("PA_MVM", "PA_CMP", "CNES", "PA_PROC_ID", "CBO"))
      ex <- somar(rbindlist(lapply(partes, `[[`, "exames")), c("PA_MVM", "PA_CMP", "CNES", "PA_UFMUN", "PA_PROC_ID"))
      gravar_atomico(function(f) arrow::write_parquet(estab, f),
                     file.path(SIA$dir, "estabelecimentos", sprintf("sia_estab_%s.parquet", m)))
      gravar_atomico(function(f) arrow::write_parquet(ex, f),
                     file.path(SIA$dir, "exames", sprintf("sia_exames_%s.parquet", m)))
      ctrl <- rbind(ctrl[mvm != m], data.table(mvm = m, assinatura = pend[mvm == m]$assinatura,
                                               processado_em = format(Sys.time(), "%Y-%m-%d %H:%M:%S")))
      gravar_atomico(function(f) fwrite(ctrl, f), SIA$controle)
      TRUE
    }, error = function(e) { log_msg("ERRO no movimento %s: %s", m, conditionMessage(e)); FALSE })
    if (!ok) falhas <- c(falhas, m)
  }

  consolidar("estabelecimentos", "sia_estabelecimentos.parquet")
  consolidar("exames", "sia_exames_pe.parquet")
  if (length(falhas)) {
    log_msg("Movimentos com falha (tentados de novo na próxima execução): %s", paste(falhas, collapse = ", "))
    quit(status = 1)
  }
}

if (sys.nframe() == 0L) main()

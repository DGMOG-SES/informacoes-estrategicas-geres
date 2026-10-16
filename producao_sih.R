#!/usr/bin/env Rscript
# ------------------------------------------------------------------------------
# Produção hospitalar do SIH/SUS de PE, por arquivo mensal (RDPEaamm e SPPEaamm).
#
# Saídas (Parquet), uma partição por mês de arquivo e uma base consolidada:
#   dados/sih/aih/       -> dados/saida/sih_aih_pe.parquet
#     AIH reduzida (RD) de todos os estabelecimentos de PE: contagem de AIH por
#     competência (ANO_CMPT/MES_CMPT), CNES, município do estabelecimento
#     (MUNIC_MOV), município de residência (MUNIC_RES), procedimento realizado
#     (PROC_REA), caráter da internação (CAR_INT) e tipo de AIH (IDENT:
#     1 = normal, 5 = longa permanência). Serve para partos, cirurgias eletivas
#     e internações por GERES de atendimento e de residência.
#   dados/sih/servicos/  -> dados/saida/sih_servicos.parquet
#     Atos profissionais (SP) das unidades da lista validada: quantidade
#     (SP_QTD_ATO) e linhas por competência, CNES e procedimento do ato
#     (SP_ATOPROF). Inclui OPM e exames feitos durante a internação.
#
# Só baixa meses novos ou republicados. Uso: Rscript producao_sih.R [--reprocessar-tudo]
# ------------------------------------------------------------------------------

source("utils.R")

SIH <- list(
  ftp    = "ftp://ftp.datasus.gov.br/dissemin/publicos/SIHSUS/200801_/Dados/",
  uf     = "PE",
  inicio = "202201",
  max_por_execucao = 60,
  dir    = file.path(CFG$dir_dados, "sih"),
  controle = file.path(CFG$dir_dados, "controle", "sih_processados.csv")
)

listar_sih <- function() {
  res <- com_tentativas(function() curl_fetch_memory(SIH$ftp, handle = novo_handle()), "listar SIH")
  lst <- interpretar_listagem(strsplit(rawToChar(res$content), "\r?\n")[[1]])
  padrao <- sprintf("^(RD|SP)%s(\\d{2})(\\d{2})\\.dbc$", SIH$uf)
  lst <- lst[grepl(padrao, nome, ignore.case = TRUE)]
  lst[, `:=`(tipo = toupper(sub(padrao, "\\1", nome, ignore.case = TRUE)),
             mes = sub(padrao, "20\\2\\3", nome, ignore.case = TRUE))]
  lst <- lst[mes >= SIH$inicio]
  lst[, assinatura := paste(nome, tamanho, data, sep = "|")]
  setorder(lst, mes, tipo)
  lst
}

baixar_ler_sih <- function(nome) {
  destino <- file.path(tempdir(), nome)
  com_tentativas(function() curl_download(paste0(SIH$ftp, nome), destino,
                                          handle = novo_handle(), quiet = TRUE),
                 paste("baixar", nome))
  on.exit(unlink(destino))
  ler_arquivo(destino)
}

processar_rd <- function(nome) {
  rd <- baixar_ler_sih(nome)
  cols <- c("ANO_CMPT", "MES_CMPT", "CNES", "MUNIC_MOV", "MUNIC_RES", "PROC_REA", "CAR_INT", "IDENT")
  rd <- rd[, cols, with = FALSE]
  for (cl in cols) set(rd, j = cl, value = trimws(as.character(rd[[cl]])))
  out <- rd[, .(N_AIH = .N), by = .(COMPETENCIA = paste0(ANO_CMPT, MES_CMPT), CNES, MUNIC_MOV,
                                    MUNIC_RES, PROC_REA, CAR_INT, IDENT)]
  log_msg("  %s: %s AIH, %d linhas agregadas", nome, format(nrow(rd), big.mark = "."), nrow(out))
  out
}

processar_sp <- function(nome, cnes_validos) {
  sp <- baixar_ler_sih(nome)
  cols <- c("SP_AA", "SP_MM", "SP_CNES", "SP_ATOPROF", "SP_QTD_ATO")
  sp <- sp[, cols, with = FALSE]
  for (cl in cols[1:4]) set(sp, j = cl, value = trimws(as.character(sp[[cl]])))
  n <- nrow(sp)
  sp <- sp[SP_CNES %chin% cnes_validos]
  out <- sp[, .(QTD_ATO = sum(as.numeric(SP_QTD_ATO), na.rm = TRUE), N_LINHAS = .N),
            by = .(COMPETENCIA = paste0(SP_AA, SP_MM), CNES = SP_CNES, PROC_ATO = SP_ATOPROF)]
  log_msg("  %s: %s atos, %d linhas agregadas das unidades validadas", nome, format(n, big.mark = "."), nrow(out))
  out
}

consolidar <- function(sub, saida) {
  arqs <- list.files(file.path(SIH$dir, sub), "\\.parquet$", full.names = TRUE)
  if (!length(arqs)) return(invisible(NULL))
  base <- rbindlist(lapply(arqs, arrow::read_parquet), use.names = TRUE)
  dir.create(file.path(CFG$dir_dados, "saida"), recursive = TRUE, showWarnings = FALSE)
  gravar_atomico(function(f) arrow::write_parquet(base, f), file.path(CFG$dir_dados, "saida", saida))
  log_msg("%s: %d linhas", saida, nrow(base))
}

main <- function() {
  reprocessar <- "--reprocessar-tudo" %in% commandArgs(trailingOnly = TRUE)
  for (d in c("aih", "servicos")) dir.create(file.path(SIH$dir, d), recursive = TRUE, showWarnings = FALSE)
  dir.create(dirname(SIH$controle), recursive = TRUE, showWarnings = FALSE)
  cnes_validos <- fread("referencias/estabelecimentos_validados.csv", colClasses = "character",
                        encoding = "UTF-8")$CNES

  ftp <- listar_sih()
  ctrl <- if (file.exists(SIH$controle)) fread(SIH$controle, colClasses = "character") else
    data.table(nome = character(), assinatura = character(), processado_em = character())
  pend <- if (reprocessar) ftp else ftp[!ctrl, on = .(nome, assinatura)]
  setorder(pend, -mes, tipo)
  log_msg("%d arquivos no FTP desde %s; %d pendentes; processando até %d",
          nrow(ftp), SIH$inicio, nrow(pend), SIH$max_por_execucao * 2)
  pend <- head(pend, SIH$max_por_execucao * 2)

  falhas <- character()
  for (i in seq_len(nrow(pend))) {
    p <- pend[i]
    ok <- tryCatch({
      if (p$tipo == "RD") {
        dt <- processar_rd(p$nome); sub <- "aih"
      } else {
        dt <- processar_sp(p$nome, cnes_validos); sub <- "servicos"
      }
      gravar_atomico(function(f) arrow::write_parquet(dt, f),
                     file.path(SIH$dir, sub, sprintf("%s_%s.parquet", tolower(p$tipo), p$mes)))
      ctrl <- rbind(ctrl[nome != p$nome], data.table(nome = p$nome, assinatura = p$assinatura,
                                                     processado_em = format(Sys.time(), "%Y-%m-%d %H:%M:%S")))
      gravar_atomico(function(f) fwrite(ctrl, f), SIH$controle)
      TRUE
    }, error = function(e) { log_msg("ERRO em %s: %s", p$nome, conditionMessage(e)); FALSE })
    if (!ok) falhas <- c(falhas, p$nome)
  }

  consolidar("aih", "sih_aih_pe.parquet")
  consolidar("servicos", "sih_servicos.parquet")
  if (length(falhas)) {
    log_msg("Arquivos com falha (tentados de novo na próxima execução): %s", paste(falhas, collapse = ", "))
    quit(status = 1)
  }
}

if (sys.nframe() == 0L) main()

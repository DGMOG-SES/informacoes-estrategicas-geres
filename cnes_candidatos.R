#!/usr/bin/env Rscript
# ------------------------------------------------------------------------------
# Lista candidata de estabelecimentos da rede própria estadual (hospitais,
# UPAEs e UPAs) para validação pela SES-PE.
#
# Fontes (competência mais recente do FTP do DATASUS):
#   CNES-ST  STPEaamm.dbc  tipo de unidade, gestão, natureza jurídica, mantenedora
#   CNES-LT  LTPEaamm.dbc  leitos por tipo
#   API de dados abertos do CNES  nome, razão social, esfera administrativa
#
# Saídas em dados/referencias/:
#   cnes_candidatos.csv   um estabelecimento por linha, com tipo e classificação
#                         sugeridos e leitos por categoria
#   leitos_pe.csv         leitos de PE por CNES e código de leito
#
# Critério principal: no CNES de PE, as unidades estaduais (inclusive as geridas
# por Organização Social) têm a Secretaria Estadual de Saúde como mantenedora
# (CNPJ_MAN = 10.572.048/0001-28) e natureza jurídica 1023. UPE, HEMOPE e IRH
# são administração indireta e ficam marcados para a SES decidir.
#
# Uso: Rscript cnes_candidatos.R
# ------------------------------------------------------------------------------

source("utils.R")

CAND <- list(
  ftp_st   = "ftp://ftp.datasus.gov.br/dissemin/publicos/CNES/200508_/Dados/ST/",
  ftp_lt   = "ftp://ftp.datasus.gov.br/dissemin/publicos/CNES/200508_/Dados/LT/",
  api_cnes = "https://apidadosabertos.saude.gov.br/cnes/estabelecimentos/",
  dir_saida = file.path(CFG$dir_dados, "referencias"),
  # 04 policlínica, 05 hospital geral, 07 hospital especializado, 15 unidade mista,
  # 20/21 pronto-socorro, 36 clínica/centro de especialidade, 62 hospital-dia,
  # 73 pronto atendimento (UPA)
  tipos    = c("04", "05", "07", "15", "20", "21", "36", "62", "73"),
  # naturezas jurídicas da administração pública estadual
  nat_jur_estadual = c("1023", "1112", "1147", "1228"),
  cnpj_ses = "10572048000128"
)

ultimo_arquivo <- function(url, prefixo) {
  res <- com_tentativas(function() curl_fetch_memory(url, handle = novo_handle()),
                        paste("listar", url))
  lst <- interpretar_listagem(strsplit(rawToChar(res$content), "\r?\n")[[1]])
  padrao <- sprintf("^%s(\\d{4})\\.dbc$", prefixo)
  lst <- lst[grepl(padrao, nome, ignore.case = TRUE)]
  if (!nrow(lst)) stop("Nenhum arquivo ", prefixo, " em ", url)
  lst[, aamm := sub(padrao, "\\1", nome, ignore.case = TRUE)]
  lst[which.max(as.integer(aamm))]$nome
}

baixar_ler <- function(url, nome) {
  destino <- file.path(tempdir(), nome)
  com_tentativas(function() curl_download(paste0(url, nome), destino, handle = novo_handle(), quiet = TRUE),
                 paste("baixar", nome))
  dt <- ler_arquivo(destino)
  unlink(destino)
  dt
}

consultar_api <- function(cnes) {
  res <- tryCatch(com_tentativas(function() {
    r <- curl_fetch_memory(paste0(CAND$api_cnes, as.integer(cnes)), handle = novo_handle())
    if (r$status_code >= 500) stop("HTTP ", r$status_code)
    r
  }, paste("consultar CNES", cnes)), error = function(e) NULL)
  if (is.null(res) || res$status_code != 200) return(data.table(CNES = cnes))
  j <- jsonlite::fromJSON(rawToChar(res$content))
  campo <- function(n) if (!is.null(j[[n]])) as.character(j[[n]]) else NA_character_
  data.table(
    CNES          = cnes,
    NOME_FANTASIA = campo("nome_fantasia"),
    RAZAO_SOCIAL  = campo("nome_razao_social"),
    CNPJ          = campo("numero_cnpj_entidade"),
    ESFERA_ADMINISTRATIVA = campo("descricao_esfera_administrativa"),
    NATUREZA_ORGANIZACAO  = campo("descricao_natureza_organizacao"),
    NATUREZA_JURIDICA_API = campo("codigo_natureza_juridica_estabelecimento")
  )
}

main_candidatos <- function() {
  dir.create(CAND$dir_saida, recursive = TRUE, showWarnings = FALSE)

  arq_st <- ultimo_arquivo(CAND$ftp_st, "STPE")
  log_msg("CNES-ST: %s", arq_st)
  st <- baixar_ler(CAND$ftp_st, arq_st)
  log_msg("Colunas ST: %s", paste(names(st), collapse = ", "))
  st[, TP_UNID := sprintf("%02d", as.integer(TP_UNID))]

  arq_lt <- ultimo_arquivo(CAND$ftp_lt, "LTPE")
  log_msg("CNES-LT: %s", arq_lt)
  lt <- baixar_ler(CAND$ftp_lt, arq_lt)
  log_msg("Colunas LT: %s", paste(names(lt), collapse = ", "))
  qt <- intersect(c("QT_EXIST", "QT_CONTR", "QT_SUS", "QT_NSUS"), names(lt))
  lt[, (qt) := lapply(.SD, as.integer), .SDcols = qt]
  leitos <- lt[, lapply(.SD, sum, na.rm = TRUE), by = .(CNES, CODUFMUN, TP_LEITO, CODLEITO), .SDcols = qt]
  leitos[, COMPETENCIA := sub("^LTPE(\\d{4}).*", "20\\1", arq_lt, ignore.case = TRUE)]
  gravar_atomico(function(f) fwrite(leitos, f, sep = ";", bom = TRUE),
                 file.path(CAND$dir_saida, "leitos_pe.csv"))
  log_msg("leitos_pe: %d linhas", nrow(leitos))

  # Candidatos: tipos de interesse com gestão estadual/dupla ou natureza jurídica
  # estadual, mais todos os pronto-atendimentos (UPAs), qualquer que seja a gestão.
  manter <- intersect(c("CNES", "CODUFMUN", "TP_UNID", "TPGESTAO", "NAT_JUR", "ESFERA_A",
                        "CNPJ_MAN", "CPF_CNPJ", "PF_PJ", "NIV_DEP", "VINC_SUS", "COMPETEN"),
                      names(st))
  cand <- st[(TP_UNID %in% CAND$tipos &
                (TPGESTAO %in% c("E", "D") | NAT_JUR %in% CAND$nat_jur_estadual | TP_UNID == "73")) |
               CNPJ_MAN == CAND$cnpj_ses,
             ..manter]
  log_msg("Candidatos: %d estabelecimentos", nrow(cand))

  api <- rbindlist(lapply(cand$CNES, function(cn) { Sys.sleep(0.2); consultar_api(cn) }), fill = TRUE)
  cand <- merge(cand, api, by = "CNES", all.x = TRUE)

  # Leitos SUS por categoria (QT_SUS: foco no acesso da população dependente do SUS)
  leitos[, CATEGORIA := categoria_leito(TP_LEITO, CODLEITO)]
  cat_leitos <- dcast(leitos, CNES ~ CATEGORIA, value.var = "QT_SUS", fun.aggregate = sum)
  cols <- c("UTI_ADULTO", "UTI_NEONATAL", "UTI_PEDIATRICA", "ENFERMARIA", "COMPLEMENTAR_NAO_UTI")
  for (cl in setdiff(cols, names(cat_leitos))) cat_leitos[, (cl) := 0L]
  cat_leitos[, LEITOS_TOTAIS := UTI_ADULTO + UTI_NEONATAL + UTI_PEDIATRICA + ENFERMARIA]
  setnames(cat_leitos, c(cols, "LEITOS_TOTAIS"), paste0("LEITOS_", c(cols, "TOTAIS")))
  cand <- merge(cand, cat_leitos, by = "CNES", all.x = TRUE)
  lcols <- grep("^LEITOS_", names(cand), value = TRUE)
  for (cl in lcols) set(cand, which(is.na(cand[[cl]])), cl, 0L)

  # Tipo e classificação sugeridos
  nome <- toupper(cand$NOME_FANTASIA)
  cand[, MANTENEDORA_SES := CNPJ_MAN == CAND$cnpj_ses]
  cand[, TIPO_SUGERIDO := fcase(grepl("\\bUPAE\\b", nome), "UPAE",
                                TP_UNID == "73" | grepl("^UPA\\b", nome), "UPA",
                                TP_UNID %chin% c("05", "07", "15", "62"), "HOSPITAL",
                                default = "OUTRO")]
  cand[, CLASSIFICACAO := fcase(
    MANTENEDORA_SES & TIPO_SUGERIDO != "OUTRO", "1 Rede própria estadual (provável)",
    MANTENEDORA_SES, "2 Unidade estadual de outro tipo",
    NAT_JUR %chin% CAND$nat_jur_estadual, "3 Estadual indireta (UPE/HEMOPE/IRH): SES decide",
    default = "4 Fora da rede própria (provável)")]

  # Município e Região de Saúde (GERES)
  mun <- fread("referencias/municipios_regiao_saude_pe.csv", sep = ";", colClasses = "character", encoding = "UTF-8")
  cand <- merge(cand, mun[, .(CODUFMUN = CO_MUNICIPIO, MUNICIPIO, CO_REGIAO_SAUDE, REGIAO_SAUDE)],
                by = "CODUFMUN", all.x = TRUE)

  setcolorder(cand, c("CLASSIFICACAO", "TIPO_SUGERIDO", "CNES", "NOME_FANTASIA", "RAZAO_SOCIAL",
                      "MUNICIPIO", "REGIAO_SAUDE"))
  setorder(cand, CLASSIFICACAO, TIPO_SUGERIDO, REGIAO_SAUDE, NOME_FANTASIA)
  gravar_atomico(function(f) fwrite(cand, f, sep = ";", bom = TRUE),
                 file.path(CAND$dir_saida, "cnes_candidatos.csv"))
  log_msg("cnes_candidatos: %d linhas", nrow(cand))
}

main_candidatos()

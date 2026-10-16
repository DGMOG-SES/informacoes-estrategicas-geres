# Utilitários comuns: log, gravação atômica, tentativas de rede, leitura do FTP
# e dos arquivos .dbc do DATASUS.

suppressPackageStartupMessages({
  library(data.table)
  library(curl)
})

CFG <- list(
  dir_dados  = Sys.getenv("GERES_DIR_DADOS", "dados"),
  tentativas = 4
)

log_msg <- function(...) {
  cat(format(Sys.time(), "[%Y-%m-%d %H:%M:%S] "), sprintf(...), "\n", sep = "")
}

# Grava em arquivo temporário e renomeia, para nunca deixar arquivo pela metade.
gravar_atomico <- function(escrever, destino) {
  tmp <- paste0(destino, ".tmp")
  escrever(tmp)
  if (file.exists(destino)) file.remove(destino)
  file.rename(tmp, destino)
}

com_tentativas <- function(f, descricao) {
  for (i in seq_len(CFG$tentativas)) {
    res <- tryCatch(f(), error = function(e) e)
    if (!inherits(res, "error")) return(res)
    log_msg("Falha em %s (tentativa %d/%d): %s",
            descricao, i, CFG$tentativas, conditionMessage(res))
    if (i < CFG$tentativas) Sys.sleep(2^i * 5)
  }
  stop("Desisti de ", descricao, " após ", CFG$tentativas, " tentativas")
}

novo_handle <- function() {
  new_handle(connecttimeout = 60, low_speed_limit = 1000, low_speed_time = 180,
             ftp_use_epsv = FALSE)
}

# ---- FTP -----------------------------------------------------------------------

# Interpreta a listagem do FTP. Aceita o formato MS-DOS (usado pelo DATASUS:
# "10-25-24  02:15PM  123456 PAPE2409.dbc") e o formato Unix ("-rw-r--r-- ...").
interpretar_listagem <- function(linhas) {
  linhas <- trimws(linhas[nzchar(trimws(linhas))])
  if (!length(linhas)) return(data.table(nome = character(), tamanho = numeric(), data = character()))
  partes <- strsplit(linhas, "\\s+")
  rbindlist(lapply(partes, function(p) {
    if (grepl("^\\d{2}-\\d{2}-\\d{2,4}$", p[1]) && length(p) >= 4) {
      data.table(nome = paste(p[4:length(p)], collapse = " "),
                 tamanho = suppressWarnings(as.numeric(p[3])),
                 data = paste(p[1], p[2]))
    } else if (length(p) >= 9) {
      data.table(nome = paste(p[9:length(p)], collapse = " "),
                 tamanho = suppressWarnings(as.numeric(p[5])),
                 data = paste(p[6], p[7], p[8]))
    } else {
      NULL
    }
  }))
}


ler_arquivo <- function(caminho) {
  if (grepl("\\.dbc$", caminho, ignore.case = TRUE)) {
    if (requireNamespace("read.dbc", quietly = TRUE)) {
      df <- read.dbc::read.dbc(caminho, as.is = TRUE)
    } else {
      # Alternativa: descompacta com o pyreaddbc (pip install pyreaddbc).
      dbf <- sub("\\.dbc$", ".dbf", caminho, ignore.case = TRUE)
      on.exit(unlink(dbf))
      status <- system2("python3", c("-c", shQuote(sprintf(
        "from pyreaddbc import dbc2dbf; dbc2dbf('%s', '%s')", caminho, dbf))))
      if (status != 0 || !file.exists(dbf)) {
        stop("Não foi possível ler .dbc: instale read.dbc (instalar_pacotes.R) ou pyreaddbc")
      }
      df <- foreign::read.dbf(dbf, as.is = TRUE)
    }
  } else {
    df <- foreign::read.dbf(caminho, as.is = TRUE)
  }
  setDT(df)
}

# ---- Leitos (CNES-LT) ------------------------------------------------------------

# Leitos de UTI por código CNES (TP_LEITO 3 = complementar). Os demais
# complementares (UCI, unidade intermediária, isolamento) ficam em coluna própria,
# porque não são UTI nem enfermaria. TP_LEITO 1, 2, 4, 5, 6 e 7 = enfermaria.
UTI <- list(
  adulto     = c("51", "74", "75", "76", "83", "85", "86"),
  pediatrica = c("52", "77", "78", "79"),
  neonatal   = c("80", "81", "82")
)

categoria_leito <- function(tp, cod) {
  fcase(cod %chin% UTI$adulto, "UTI_ADULTO",
        cod %chin% UTI$pediatrica, "UTI_PEDIATRICA",
        cod %chin% UTI$neonatal, "UTI_NEONATAL",
        tp == "3", "COMPLEMENTAR_NAO_UTI",
        default = "ENFERMARIA")
}

# Lista os arquivos <prefixo>AAMM.dbc de um diretório do FTP do DATASUS.
listar_competencias <- function(url, prefixo) {
  res <- com_tentativas(function() curl_fetch_memory(url, handle = novo_handle()),
                        paste("listar", url))
  lst <- interpretar_listagem(strsplit(rawToChar(res$content), "\r?\n")[[1]])
  padrao <- sprintf("^%s(\\d{2})(\\d{2})\\.dbc$", prefixo)
  lst <- lst[grepl(padrao, nome, ignore.case = TRUE)]
  lst[, competencia := sub(padrao, "20\\1\\2", nome, ignore.case = TRUE)]
  setorder(lst, competencia)
  lst
}

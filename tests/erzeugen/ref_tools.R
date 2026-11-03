# Referenzfälle für die Python- und die Julia-Fassung (T20: Katalog tests/faelle, eine Datei je Bereich).
#
# Ein Bereichsgenerator tests/erzeugen/<bereich>.R ruft ref_bereich("<bereich>") auf, dann je Modul
# ref_init("<modul>"), ref_case(...) für jeden Fall und ref_done(); am Ende schreibt ref_schreiben() die Datei
# <SIMLEV_FAELLE_DIR>/<bereich>.jsonl.gz (Standard tests/faelle; gzip -9 -n, Byte für Byte reproduzierbar):
#   Zeile 1   {"format":3,"bereich":<bereich>,"faelle":<n>,"inputs":{<schlüssel>:<baum>,...}}
#   je Fall   eine Zeile: Fall als JSON (s. u.); im Bereich engine zusätzlich die Fälle von
#             tests/erzeugen/engine_faelle.R und engine_stress.R (Engine-Format, ref_golden())
# Abgelegt werden nur die Fälle aus tests/erzeugen/auswahl.txt (Zeilen <modul>/<kennung>; kleinste Fallmenge
# mit derselben Zeilenabdeckung wie alle Fälle, T20). Ausgewertet werden immer alle Fälle (gleiche Zufallsfolge
# der Generatoren). Mit SIMLEV_GEN_ALLE=1 (Gleichlauf) zusätzlich alle Fälle nach <dir>/alle/<bereich>.jsonl.gz.
#
# Ein Fall (Modulformat) enthält
#   id, module          Kennung
#   inputs              benannte Eingabeobjekte (als Baum, s. enc(), oder als Verweis
#                       {"t": "ref", "k": <schlüssel>} auf den Eingabespeicher in Zeile 1)
#   r                   R-Code, der das Ergebnis liefert (letzter Ausdruck)
#   py                  Python-Code, der `result = ...` setzt
#   jl                  Julia-Code, der `result = ...` setzt (optional)
#   result              Ergebnis als Baum
#   output              Konsolenausgabe während des Aufrufs (cat/print)
#   print               capture.output(print(result)) oder NULL
#   warnings            Warnungen (Texte) während des Aufrufs
#   error               Fehlermeldung, falls R mit Fehler abbricht
#
# Eingabespeicher: Eingaben, deren kanonische JSON-Form (kompakt, UTF-8) mindestens .REF_INLINE_MAX Bytes lang
# ist, stehen einmal je Bereich in Zeile 1; Schlüssel = MD5-Prüfsumme (hex) der kanonischen Form, sortiert.
#
# Baumformat (enc): jedes Objekt ist eine Liste mit Typ `t`:
#   null | num | int | lgl | chr | date | list | df | mat | skip
# Zahlen als Hex-Literale ("%a"), NA als "NA", NaN als "NaN"; Attribute
# `names`, `dim`, `dimnames`, `class` werden mitgeschrieben.
#
# Umgebung:
#   SIMLEV_FAELLE_DIR   Ausgabeordner (Standard tests/faelle)
#   SIMLEV_GEN_ALLE=1   zusätzlich alle Fälle nach <dir>/alle/ (Gleichlauf, tests/gleichlauf/run.sh)
#   SIMLEV_GEN_SUBSET=m nur die Fälle, deren Kennung (Modul/Fall) per Prüfsumme in eine 1/m-Stichprobe fällt
#                       (deterministisch; m = 1 oder leer: alle); die übrigen werden nicht ausgewertet
#   SIMLEV_GOLDEN_SRC   Ordner mit cases/ und stress/ (Ausgaben von engine_faelle.R 500 4711 und
#                       engine_stress.R 1000 90210); leer: ref_golden() erzeugt sie selbst
#
# Verwendung (Arbeitsverzeichnis = Repo-Wurzel):
#   source("tests/erzeugen/ref_tools.R"); ref_bereich("bootstrap")
#   ref_init("bootstrap")
#   ref_case("bs01", r = "simlev_seed(1); bootstrap_data(d, n = 10)",
#            py = "simlev.simlev_seed(1); result = simlev.bootstrap_data(d, n=10)",
#            inputs = list(d = df))
#   ref_done(); ref_schreiben()
suppressMessages({ library(SimLev); library(jsonlite) })

.ref <- new.env()

.REF_INLINE_MAX <- 256L    # kürzere Eingaben bleiben im Fall

.ref_root <- function() {
  d <- Sys.getenv("SIMLEV_FAELLE_DIR")
  if (nzchar(d)) d else file.path("tests", "faelle")
}

.ref_alle <- function() identical(Sys.getenv("SIMLEV_GEN_ALLE"), "1")

.ref_subset <- function() {
  m <- suppressWarnings(as.integer(Sys.getenv("SIMLEV_GEN_SUBSET")))
  if (is.na(m) || m < 1L) 1L else m
}

# Prüfsumme der Kennung: Polynom-Hash zur Basis 131 modulo 2^31 - 1 (in double exakt)
.ref_hash <- function(key) {
  h <- 0
  for (cc in utf8ToInt(enc2utf8(key))) h <- (h * 131 + cc) %% 2147483647
  h
}

.ref_in_subset <- function(id) {
  m <- .ref_subset()
  m == 1L || .ref_hash(paste0(.ref$module, "/", id)) %% m == 0
}

# Bereich beginnen. alle = TRUE: alle Fälle in <dir>/<bereich>.jsonl.gz (Zufallsprüfungen des Gleichlaufs)
ref_bereich <- function(bereich, alle = FALSE) {
  .ref$bereich <- bereich; .ref$nur_alle <- alle
  .ref$lines <- character(0); .ref$sel <- logical(0); .ref$keys <- list(); .ref$ids <- character(0)
  .ref$store <- list(); .ref$last <- NULL
  .ref$auswahl <- if (alle) character(0) else readLines(file.path("tests", "erzeugen", "auswahl.txt"))
  invisible(bereich)
}

ref_init <- function(module) {
  .ref$module <- module; .ref$n <- 0L
  invisible(module)
}

.ref_json <- function(x)
  toJSON(x, digits = NA, auto_unbox = TRUE, null = "null", na = "null", always_decimal = FALSE)

# Eingabe (Baum) in den Speicher legen, falls groß genug; liefert Baum oder Verweis
.ref_input <- function(tree) {
  s <- enc2utf8(as.character(.ref_json(tree)))
  if (nchar(s, type = "bytes") < .REF_INLINE_MAX) return(tree)
  f <- tempfile(); on.exit(unlink(f))
  writeBin(charToRaw(s), f)
  k <- unname(tools::md5sum(f))
  .ref$store[[k]] <- s
  .ref$used <- c(.ref$used, k)
  list(t = "ref", k = k)
}

.hx <- function(x) {
  x <- as.numeric(x); out <- sprintf("%a", x)
  out[is.na(x)] <- "NA"; out[is.nan(x)] <- "NaN"; out
}

.attrs <- function(x, out) {
  if (!is.null(names(x)) && !is.data.frame(x)) out$names <- as.character(names(x))
  if (!is.null(dim(x))) out$dim <- as.integer(dim(x))
  dn <- dimnames(x)
  if (!is.null(dn)) out$dimnames <- lapply(dn, function(v) if (is.null(v)) NULL else as.character(v))
  cl <- attr(x, "class")
  if (!is.null(cl)) out$class <- as.character(cl)
  out
}

enc <- function(x) {
  if (is.null(x)) return(list(t = "null"))
  if (is.function(x) || is.environment(x) || is.language(x) || inherits(x, "formula"))
    return(list(t = "skip"))
  if (inherits(x, "Date")) {
    out <- list(t = "date", v = ifelse(is.na(x), NA_integer_, as.integer(unclass(x))))
    if (!is.null(names(x))) out$names <- names(x)
    return(out)
  }
  if (inherits(x, "POSIXt")) return(list(t = "chr", v = format(x)))
  if (is.data.frame(x)) {
    cols <- lapply(x, enc)
    out <- list(t = "df", names = as.character(names(x)), nrow = nrow(x), cols = unname(cols))
    rn <- attr(x, "row.names")
    if (is.character(rn)) out$row_names <- rn
    cl <- attr(x, "class"); if (!identical(cl, "data.frame")) out$class <- cl
    return(out)
  }
  if (is.factor(x)) return(.attrs(unclass(x)[0], list(t = "chr", v = as.character(x), class = "factor")))
  if (is.list(x)) {
    out <- list(t = "list", v = unname(lapply(x, enc)))
    if (!is.null(names(x))) out$names <- as.character(names(x))
    cl <- attr(x, "class"); if (!is.null(cl)) out$class <- as.character(cl)
    return(out)
  }
  if (is.matrix(x) || is.array(x)) {
    out <- list(t = "mat", type = typeof(x))
    v <- as.vector(x)
    out$v <- if (is.numeric(v)) .hx(v) else if (is.logical(v)) v else as.character(v)
    out <- .attrs(x, out); out$names <- NULL
    return(out)
  }
  if (is.complex(x)) return(list(t = "num", v = .hx(Re(x))))
  if (is.integer(x)) out <- list(t = "int", v = .hx(x))
  else if (is.double(x)) out <- list(t = "num", v = .hx(x))
  else if (is.logical(x)) out <- list(t = "lgl", v = x)
  else if (is.character(x)) out <- list(t = "chr", v = x)
  else return(list(t = "skip"))
  .attrs(x, out)
}

.has_print <- function(x) {
  ns <- asNamespace("SimLev")
  any(vapply(class(x), function(cl) exists(paste0("print.", cl), envir = ns, inherits = FALSE), NA))
}

# Fall als Zeile merken (abgelegt, wenn in der Auswahl; alle mit SIMLEV_GEN_ALLE=1)
.ref_add <- function(key, txt, keys) {
  .ref$lines <- c(.ref$lines, txt)
  .ref$sel <- c(.ref$sel, .ref$nur_alle || key %in% .ref$auswahl)
  .ref$keys[[length(.ref$lines)]] <- unique(keys)
  .ref$ids <- c(.ref$ids, key)
}

# print = NA: Druckausgabe nur für Objekte mit eigener print-Methode in SimLev
ref_case <- function(id, r, py, inputs = list(), print = NA, note = NULL, jl = NULL) {
  if (!.ref_in_subset(id)) return(invisible(NULL))
  env <- new.env(parent = globalenv())
  for (k in names(inputs)) assign(k, inputs[[k]], envir = env)
  warns <- character(0)
  err <- NULL
  out_txt <- character(0)
  res <- NULL
  out_txt <- capture.output(
    res <- tryCatch(withCallingHandlers(eval(parse(text = r), envir = env),
                                        warning = function(w) { warns <<- c(warns, conditionMessage(w)); invokeRestart("muffleWarning") },
                                        message = function(m) invokeRestart("muffleMessage")),
                    error = function(e) { err <<- conditionMessage(e); NULL }))
  .ref$used <- character(0)
  case <- list(id = id, module = .ref$module, note = note,
               inputs = lapply(inputs, function(x) .ref_input(enc(x))), r = r, py = py)
  if (!is.null(jl)) case$jl <- jl
  if (!is.null(err)) case$error <- err
  else {
    case$result <- enc(res)
    case$output <- paste(out_txt, collapse = "\n")
    if (is.na(print)) print <- .has_print(res)
    if (isTRUE(print)) {
      txt <- withCallingHandlers(capture.output(print(res)),
                                 warning = function(w) invokeRestart("muffleWarning"))
      case$print <- paste(txt, collapse = "\n")
    }
  }
  case$warnings <- unique(warns)
  .ref_add(paste0(.ref$module, "/", id), as.character(.ref_json(case)), .ref$used)
  .ref$last <- case
  .ref$n <- .ref$n + 1L
  invisible(res)
}

# Felder an den zuletzt geschriebenen Fall anhängen (Zufallsprüfungen: r_calls)
ref_case_extra <- function(fields) {
  case <- .ref$last
  for (k in names(fields)) case[k] <- list(fields[[k]])
  .ref$lines[length(.ref$lines)] <- as.character(.ref_json(case))
  .ref$last <- case
  invisible(NULL)
}

ref_done <- function() {
  cat(sprintf("%s/%s: %d Fälle\n", .ref$bereich, .ref$module, .ref$n))
}

# Engine-Fälle (Engine-Format, engine_faelle.R und engine_stress.R) des Bereichs anhängen: f…/r… aus cases/,
# x…/y… aus stress/ (Modul "cases" bzw. "extra"); abgelegt die der Auswahl, mit SIMLEV_GEN_ALLE=1 alle
ref_golden <- function() {
  src <- Sys.getenv("SIMLEV_GOLDEN_SRC")
  if (!nzchar(src)) {
    src <- tempfile("golden"); dir.create(src)
    here <- file.path("tests", "erzeugen")
    for (a in list(c("engine_faelle.R", "cases", "500", "4711"), c("engine_stress.R", "stress", "1000", "90210")))
      if (system2("Rscript", c(file.path(here, a[1]), file.path(src, a[2]), a[3], a[4]), stdout = FALSE) != 0)
        stop("ref_golden: ", a[1], " gescheitert")
  }
  for (d in c("cases", "stress")) {
    m <- if (d == "cases") "cases" else "extra"
    fs <- sort(list.files(file.path(src, d), "\\.json$"), method = "radix")
    for (f in fs) {
      key <- paste0(m, "/", sub("\\.json$", "", f))
      if (!(key %in% .ref$auswahl) && !.ref_alle()) next
      txt <- readLines(file.path(src, d, f), encoding = "UTF-8")
      stopifnot(length(txt) == 1L)
      .ref_add(key, txt, character(0))
    }
  }
  invisible(NULL)
}

.ref_write <- function(f, sel) {
  dir.create(dirname(f), showWarnings = FALSE, recursive = TRUE)
  k <- sort(unique(unlist(.ref$keys[sel])), method = "radix")
  head <- paste0('{"format":3,"bereich":', .ref_json(.ref$bereich), ',"faelle":', sum(sel), ',"inputs":{',
                 paste0('"', k, '":', unlist(.ref$store[k], use.names = FALSE), collapse = ","), "}}")
  tmp <- tempfile(fileext = ".jsonl"); on.exit(unlink(tmp))
  con <- file(tmp, "wb")
  writeLines(enc2utf8(c(head, .ref$lines[sel])), con, useBytes = TRUE)
  close(con)
  if (system(paste("gzip -9 -n -c", shQuote(tmp), ">", shQuote(f))) != 0) stop("gzip gescheitert: ", f)
}

# Bereichsdatei schreiben (Auswahl; mit SIMLEV_GEN_ALLE=1 zusätzlich alle Fälle unter alle/)
ref_schreiben <- function() {
  root <- .ref_root()
  if (.ref$nur_alle) {
    .ref_write(file.path(root, paste0(.ref$bereich, ".jsonl.gz")), rep(TRUE, length(.ref$lines)))
  } else {
    .ref_write(file.path(root, paste0(.ref$bereich, ".jsonl.gz")), .ref$sel)
    if (.ref_alle()) .ref_write(file.path(root, "alle", paste0(.ref$bereich, ".jsonl.gz")), rep(TRUE, length(.ref$lines)))
  }
  fehlt <- setdiff(grep(paste0("^(", paste(unique(sub("/.*", "", .ref$ids)), collapse = "|"), ")/"), .ref$auswahl, value = TRUE), .ref$ids)
  if (length(fehlt) && .ref_subset() == 1L && !nzchar(Sys.getenv("SIMLEV_GOLDEN_SRC_TEIL")))
    warning("Auswahl nennt Fälle, die der Generator nicht erzeugt: ", paste(head(fehlt, 10), collapse = ", "))
  cat(sprintf("%s: %d Fälle erzeugt, %d abgelegt (%s)\n", .ref$bereich, length(.ref$lines), sum(.ref$sel), root))
}

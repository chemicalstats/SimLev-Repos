# Referenzfälle für die Python- und die Julia-Fassung (Katalog nach Zweck, je Gruppe und Bereich eine Datei).
#
# Ein Bereichsgenerator tests/gleichlauf/erzeugen/<bereich>.R ruft ref_bereich("<bereich>") auf, dann je Modul
# ref_init("<modul>"[, gruppe]), ref_case(...) bzw. ref_tabelle(...) und ref_done(); am Ende schreibt ref_schreiben()
# je Gruppe eine Datei tests/<gruppe>/faelle/<bereich>.jsonl.gz (gleichlauf, fehler, ausgabe; mit SIMLEV_FAELLE_DIR=D
# nach D/<gruppe>/<bereich>.jsonl.gz; gzip -9 -n, Byte für Byte reproduzierbar):
#   Zeile 1   {"format":4,"bereich":<bereich>,"gruppe":<gruppe>,"faelle":<n>,"inputs":{<schlüssel>:<baum>,...}}
#   je Test   eine Zeile: Szenario (Fall) oder Tabelle (Feld tabelle, je Zeile ein eigener Aufruf)
#
# Gruppe und Tabelle:
#   ref_init(modul, gruppe = "gleichlauf" | "fehler" | "ausgabe"): die folgenden ref_case() sind Szenarien bzw.
#     ref_tabelle() Tabellen dieser Gruppe und werden immer abgelegt (Bereich engine).
#   Szenarien mit Teilen und Tabellen der übrigen Bereiche: SZ(), TB() aus szenario_tools.R.
#   ref_init(modul) ohne Gruppe (nur noch r_grundfunktionen und slc; Breitenprüfungen tests/werkzeuge/breite mit
#     ref_bereich(…, alle = TRUE)): abgelegt werden nur die Fälle aus tests/gleichlauf/erzeugen/auswahl.txt (Zeilen
#     <modul>/<kennung>; kleinste Fallmenge mit derselben Zeilenabdeckung); jeder wird Zeile einer Tabelle je
#     Modul und Funktion (erster SimLev-Export bzw. erste Funktion im letzten Ausdruck des R-Codes; Zeilenname = alte
#     Kennung). Gruppe: fehler bei Fehler oder Warnung, ausgabe bei print()/summary()/capture.output() als letztem
#     Aufruf, sonst gleichlauf.
# Ausgewertet werden immer alle Fälle (gleiche Zufallsfolge der Generatoren). Mit SIMLEV_GEN_ALLE=1 (Gleichlauf in
# tests/werkzeuge) zusätzlich alle Fälle flach nach <dir>/alle/<bereich>.jsonl.gz (Format 3: je Zeile ein Fall).
#
# Ein Fall enthält
#   id, module          Kennung
#   inputs              benannte Eingabeobjekte (als Baum, s. enc(), oder als Verweis
#                       {"t": "ref", "k": <schlüssel>} auf den Eingabespeicher in Zeile 1)
#   r                   R-Code, der das Ergebnis liefert (letzter Ausdruck)
#   py                  Python-Code, der `result = ...` setzt
#   jl                  Julia-Code, der `result = ...` setzt (optional)
#   nur                 "py" oder "jl": Fall nur für diese Sprache (seit 1.6.1, wenn die Nachbildung der anderen
#                       Sprache ohne Aufrufer im Paket entfallen ist); py bzw. jl der anderen Sprache entfällt
#   result              Ergebnis als Baum
#   output              Konsolenausgabe während des Aufrufs (cat/print)
#   print               capture.output(print(result)) oder NULL
#   warnings            Warnungen (Texte) während des Aufrufs
#   error               Fehlermeldung, falls R mit Fehler abbricht
# Eine Tabelle enthält id, module, note, inputs (gemeinsame Eingaben) und tabelle: je Zeile z (Name), optional
# quelle und inputs (eigene Eingaben), r, py, jl und die Ergebnisfelder wie ein Fall.
#
# Eingabespeicher: Eingaben, deren kanonische JSON-Form (kompakt, UTF-8) mindestens .REF_INLINE_MAX Bytes lang
# ist, stehen einmal je Datei in Zeile 1; Schlüssel = MD5-Prüfsumme (hex) der kanonischen Form, sortiert.
#
# Baumformat (enc): jedes Objekt ist eine Liste mit Typ `t`:
#   null | num | int | lgl | chr | date | list | df | mat | skip
# Zahlen als Hex-Literale ("%a"), NA als "NA", NaN als "NaN"; Attribute
# `names`, `dim`, `dimnames`, `class` werden mitgeschrieben.
#
# Umgebung:
#   SIMLEV_FAELLE_DIR   Ausgabeordner D (Standard: tests/<gruppe>/faelle, seit 1.6.2 nur mit SIMLEV_ERZEUGEN=1, das
#                       tests/werkzeuge/erzeugen.py setzt; ohne beides bricht ref_schreiben() ab)
#   SIMLEV_GEN_ALLE=1   zusätzlich alle Fälle nach D/alle/ (Gleichlauf, tests/werkzeuge/gleichlauf/run.py)
#   SIMLEV_GEN_SUBSET=m nur die Fälle, deren Kennung (Modul/Fall) per Prüfsumme in eine 1/m-Stichprobe fällt
#                       (deterministisch; m = 1 oder leer: alle); die übrigen werden nicht ausgewertet
#   SIMLEV_GEN_NUR_ALLE=1  (seit 1.6.3) mit SIMLEV_GEN_ALLE=1 nur D/alle/ schreiben, keine Dateien je Gruppe (die liest
#                       nur faelle_diff.py im vollen Gleichlauf); ebenso ohne den Schalter bei SIMLEV_GEN_SUBSET > 1
#                       (Teilmenge, --quick). Die Zählzeile bleibt.
#   SIMLEV_GZIP_STUFE=k (seit 1.6.3) gzip-Stufe der flachen Dateien (D/alle/, Zufallsprüfungen, Breite; Standard 1,
#                       Arbeitsdateien). Dateien je Gruppe und alles mit SIMLEV_ERZEUGEN=1 immer gzip -9 -n.
#
# Zufallsprüfungen (tests/werkzeuge/gleichlauf/*_fuzz.R): fuzz_case() wie ref_case(), dazu r_calls (Aufrufe der
# Warnungen und des Fehlers, deparse) aus derselben Auswertung; pick() und coin() für die Zufallswahl.
#
# Verwendung (Arbeitsverzeichnis = Repo-Wurzel):
#   source("tests/gleichlauf/erzeugen/ref_tools.R"); ref_bereich("bootstrap")
#   ref_init("bootstrap")
#   ref_case("bs01", r = "simlev_seed(1); bootstrap_data(d, n = 10)",
#            py = "simlev.simlev_seed(1); result = simlev.bootstrap_data(d, n=10)",
#            inputs = list(d = df))
#   ref_done(); ref_schreiben()
suppressMessages({ library(SimLev); library(jsonlite) })

.ref <- new.env()

.REF_INLINE_MAX <- 256L    # kürzere Eingaben bleiben im Fall
.REF_GRUPPEN <- c("gleichlauf", "fehler", "ausgabe")

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

# Bereich beginnen. alle = TRUE: alle Fälle flach in <SIMLEV_FAELLE_DIR>/<bereich>.jsonl.gz (Zufallsprüfungen)
ref_bereich <- function(bereich, alle = FALSE) {
  .ref$bereich <- bereich; .ref$nur_alle <- alle
  .ref$items <- list(); .ref$store <- list(); .ref$last <- NULL; .ref$gruppe <- NULL
  .ref$auswahl <- if (alle) character(0) else readLines(file.path("tests", "gleichlauf", "erzeugen", "auswahl.txt"))
  invisible(bereich)
}

ref_init <- function(module, gruppe = NULL) {
  if (!is.null(gruppe)) stopifnot(gruppe %in% .REF_GRUPPEN)
  .ref$module <- module; .ref$gruppe <- gruppe; .ref$n <- 0L
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

# Code r in einer frischen Umgebung mit den Eingaben auswerten; Ergebnisfelder eines Falls bzw. einer
# Tabellenzeile: error oder result, output, print (print = NA: nur Objekte mit eigener print-Methode in SimLev),
# dazu warnings. calls = TRUE (Zufallsprüfungen, fuzz_case): zusätzlich nach .ref$calls die Aufrufe der Warnungen
# (alle, in Reihenfolge) und des Fehlers (deparse, .ref_dp) sowie die Bedingungen ("W: …" bzw. "M: …")
.ref_dp <- function(x) if (is.null(x)) "NULL" else paste(deparse(x), collapse = " ")
.ref_eval <- function(r, inputs, print = NA, calls = FALSE) {
  env <- new.env(parent = globalenv())
  for (k in names(inputs)) assign(k, inputs[[k]], envir = env)
  warns <- character(0)
  err <- NULL
  out_txt <- character(0)
  res <- NULL
  wc <- character(0); ec <- NULL; cs <- character(0)
  out_txt <- capture.output(
    res <- tryCatch(withCallingHandlers(eval(parse(text = r), envir = env),
                                        warning = function(w) {
                                          warns <<- c(warns, conditionMessage(w))
                                          if (calls) { wc <<- c(wc, .ref_dp(conditionCall(w))); cs <<- c(cs, paste0("W: ", conditionMessage(w))) }
                                          invokeRestart("muffleWarning")
                                        },
                                        message = function(m) {
                                          if (calls) cs <<- c(cs, paste0("M: ", conditionMessage(m)))
                                          invokeRestart("muffleMessage")
                                        }),
                    error = function(e) { err <<- conditionMessage(e); if (calls) ec <<- .ref_dp(conditionCall(e)); NULL }))
  if (calls) .ref$calls <- list(warnings = wc, error = ec, conds = cs)
  out <- list()
  if (!is.null(err)) out$error <- err
  else {
    out$result <- enc(res)
    out$output <- paste(out_txt, collapse = "\n")
    if (is.na(print)) print <- .has_print(res)
    if (isTRUE(print)) {
      txt <- withCallingHandlers(capture.output(print(res)),
                                 warning = function(w) invokeRestart("muffleWarning"))
      out$print <- paste(txt, collapse = "\n")
    }
  }
  out$warnings <- unique(warns)
  list(fields = out, res = res)
}

# Test merken: abgelegt mit fester Gruppe (ref_init(..., gruppe)), sonst wenn in der Auswahl
.ref_add <- function(case, keys) {
  key <- paste0(.ref$module, "/", case$id)
  .ref$items[[length(.ref$items) + 1L]] <- list(key = key, case = case, keys = unique(keys), gruppe = .ref$gruppe,
                                                sel = .ref$nur_alle || !is.null(.ref$gruppe) || key %in% .ref$auswahl)
  .ref$last <- length(.ref$items)
  .ref$n <- .ref$n + 1L
}

# Laufzeit je Fall (seit 1.6.5, FB-14): mit SIMLEV_ZEITEN eine Zeile „R<TAB>Kennung<TAB>Sekunden“ in diese Datei
# (die abgelegten Fälle bleiben unverändert)
.ref_zeit <- function(id, dt) {
  zf <- Sys.getenv("SIMLEV_ZEITEN")
  if (nzchar(zf)) cat(sprintf("R\t%s/%s\t%.6f\n", .ref$module, id, dt), file = zf, append = TRUE)
}

# print = NA: Druckausgabe nur für Objekte mit eigener print-Methode in SimLev
ref_case <- function(id, r, py, inputs = list(), print = NA, note = NULL, jl = NULL, nur = NULL, calls = FALSE) {
  if (!.ref_in_subset(id)) return(invisible(NULL))
  stopifnot(is.null(nur) || nur %in% c("py", "jl"))
  t0 <- proc.time()[["elapsed"]]
  ev <- .ref_eval(r, inputs, print, calls)
  .ref_zeit(id, proc.time()[["elapsed"]] - t0)
  .ref$used <- character(0)
  case <- list(id = id, module = .ref$module, note = note,
               inputs = lapply(inputs, function(x) .ref_input(enc(x))), r = r)
  if (!identical(nur, "jl")) case$py <- py
  if (!is.null(jl) && !identical(nur, "py")) case$jl <- jl
  if (!is.null(nur)) case$nur <- nur
  case <- c(case, ev$fields)
  .ref_add(case, .ref$used)
  invisible(ev$res)
}

# Tabelle = ein Test mit mehreren Zeilen „Eingabe -> erwarteter Wert bzw. erwartete Meldung“. Jede Zeile ist ein
# eigener Aufruf in frischer Umgebung (ein Fehler bricht nur seine Zeile ab); gemeinsame Eingaben einmal je Tabelle.
# zeilen: Liste von list(z = <Zeilenname>, r =, py =, jl =[, print =][, quelle =][, inputs = <eigene Eingaben>][, nur = "py" | "jl"]).
ref_tabelle <- function(id, zeilen, inputs = list(), note = NULL) {
  if (!.ref_in_subset(id)) return(invisible(NULL))
  zs <- vapply(zeilen, function(z) z$z, "")
  if (anyDuplicated(zs)) stop("ref_tabelle ", id, ": Zeilennamen doppelt: ", paste(zs[duplicated(zs)], collapse = ", "))
  .ref$used <- character(0)
  rows <- lapply(zeilen, function(z) {
    inp <- inputs; inp[names(z$inputs)] <- z$inputs          # eigene Eingaben der Zeile vor den gemeinsamen
    ev <- .ref_eval(z$r, inp, if (is.null(z$print)) NA else z$print)
    zi <- if (length(z$inputs)) lapply(z$inputs, function(x) .ref_input(enc(x)))
    stopifnot(is.null(z$nur) || z$nur %in% c("py", "jl"))   # Zeile nur für eine Sprache (seit 1.6.4, wie ref_case)
    c(Filter(Negate(is.null), list(z = z$z, quelle = z$quelle, inputs = zi, r = z$r,
                                   py = if (!identical(z$nur, "jl")) z$py, jl = if (!identical(z$nur, "py")) z$jl, nur = z$nur)), ev$fields)
  })
  case <- list(id = id, module = .ref$module, note = note,
               inputs = lapply(inputs, function(x) .ref_input(enc(x))), tabelle = rows)
  .ref_add(case, .ref$used)
  invisible(NULL)
}

# Felder an den zuletzt geschriebenen Fall anhängen (Zufallsprüfungen: r_calls)
ref_case_extra <- function(fields) {
  case <- .ref$items[[.ref$last]]$case
  for (k in names(fields)) case[k] <- list(fields[[k]])
  .ref$items[[.ref$last]]$case <- case
  invisible(NULL)
}

# Zufallsprüfungen (seit 1.6.3 gemeinsam, bis 1.6.2 je Skript mit zweiter Auswertung): Zufallswahl und Fall mit
# r_calls = list(warnings = Aufrufe der Warnungen, error = Aufruf des Fehlers oder NULL) aus der Auswertung von ref_case.
# sim_call = TRUE: r_calls$sim_call = erster Aufruf von simulation() im Code (deparse; Bedingungen aus dem Kern tragen
# seit 1.4.1 diesen Aufruf, Sollwert in sim_fuzz_cmp.py); conds = TRUE: dazu r_conds ("W: <Warnung>", "M: <Meldung>").
# Rückgabe: Ergebnis des R-Codes (NULL bei Fehler oder außerhalb der Teilmenge).
pick <- function(x) x[[sample.int(length(x), 1L)]]
coin <- function(p) runif(1) < p
.ref_sim_call <- function(r) {
  fs <- function(e) {
    if (!is.call(e)) return(NULL)
    if (identical(e[[1L]], as.name("simulation"))) return(e)
    for (i in seq_along(e)[-1L]) { x <- tryCatch(fs(e[[i]]), error = function(err) NULL); if (!is.null(x)) return(x) }
    NULL
  }
  sc <- NULL
  for (e in parse(text = r, keep.source = FALSE)) if (is.null(sc)) sc <- fs(e)
  sc
}
# Genauigkeitsteil der Zufallsprüfungen (eigen, prec; Rmpfr): SIMLEV_FUZZ_GENAU=1 an, =0 aus, sonst nur ab n = 1000 Fällen
# (run.py --full: 2000; --quick: 300). Seit 1.6.3; die Genauigkeit hängt vom Stand ab, nicht vom Lauf.
fuzz_genau <- function(n) {
  s <- Sys.getenv("SIMLEV_FUZZ_GENAU")
  if (s %in% c("0", "1")) s == "1" else n >= 1000L
}
fuzz_case <- function(id, r, py, jl, inputs, nur = NULL, sim_call = FALSE, conds = FALSE) {
  res <- ref_case(id, r = r, py = py, jl = jl, inputs = inputs, nur = nur, calls = TRUE)
  if (!.ref_in_subset(id)) return(invisible(NULL))
  rc <- list(warnings = as.list(.ref$calls$warnings), error = .ref$calls$error)
  if (sim_call) rc$sim_call <- .ref_dp(.ref_sim_call(r))
  ref_case_extra(if (conds) list(r_calls = rc, r_conds = as.list(.ref$calls$conds)) else list(r_calls = rc))
  invisible(res)
}

ref_done <- function() {
  cat(sprintf("%s/%s: %d Fälle\n", .ref$bereich, .ref$module, .ref$n))
}

# Gruppe und Funktion eines Falls ohne feste Gruppe (s. oben)
.REF_R_MODULE <- c("r_fmt", "r_nana", "r_stats", "rexpr")
.REF_SKIP <- c("c", "list", "data.frame", "set.seed", "simlev_seed", "as.Date", "seq", "rep", "matrix", "print", "summary",
               "capture.output", "tryCatch", "function", "suppressWarnings", "suppressMessages", "invisible", "names",
               "setNames", "cbind", "rbind", "head", "tail", "unlist", "lapply", "sapply", "vapply", "length", "nrow",
               "ncol", "structure", "do.call", "withCallingHandlers", "local", "quote", "eval", "parse", "tempfile",
               "writeLines", "file.path", "stop", "warning", "if", "for", "while", "return", "identical", "unclass")
.ref_calls <- function(x) {
  m <- regmatches(x, gregexpr("[A-Za-z_.][A-Za-z0-9_.]*[[:space:]]*\\(", x))[[1]]
  sub("[[:space:]]*\\($", "", m)
}
.ref_fn <- function(case) {
  zl <- strsplit(case$r, "\n", fixed = TRUE)[[1]]; zl <- zl[nzchar(trimws(zl))]
  ex <- getNamespaceExports("SimLev")
  for (cs in list(.ref_calls(tail(zl, 1)), .ref_calls(case$r))) {
    f <- cs[cs %in% ex & !(cs %in% .REF_SKIP)]
    if (length(f)) return(f[1])
    f <- cs[!(cs %in% .REF_SKIP)]
    if (length(f)) return(f[1])
  }
  case$module
}
.ref_gruppe <- function(case) {
  if (!is.null(case$error) || length(case$warnings)) return("fehler")
  zl <- strsplit(case$r, "\n", fixed = TRUE)[[1]]; zl <- zl[nzchar(trimws(zl))]
  if (!(case$module %in% .REF_R_MODULE) && grepl("^[[:space:]]*(print|summary|capture\\.output)\\(", tail(zl, 1))) return("ausgabe")
  "gleichlauf"
}

# Datei schreiben: Kopf mit Eingabespeicher, je Test eine Zeile
.ref_write <- function(f, cases, keys, kopf) {
  dir.create(dirname(f), showWarnings = FALSE, recursive = TRUE)
  k <- sort(unique(as.character(unlist(keys))), method = "radix")
  head <- paste0('{"format":', kopf$format, ',"bereich":', .ref_json(.ref$bereich),
                 if (!is.null(kopf$gruppe)) paste0(',"gruppe":', .ref_json(kopf$gruppe)) else "",
                 ',"faelle":', length(cases), ',"inputs":{',
                 if (length(k)) paste0('"', k, '":', unlist(.ref$store[k], use.names = FALSE), collapse = ",") else "", "}}")
  tmp <- tempfile(fileext = ".jsonl"); on.exit(unlink(tmp))
  con <- file(tmp, "wb")
  writeLines(enc2utf8(c(head, vapply(cases, function(x) as.character(.ref_json(x)), ""))), con, useBytes = TRUE)
  close(con)
  if (system(paste0("gzip -", .ref_gzip_stufe(kopf$format), " -n -c ", shQuote(tmp), " > ", shQuote(f))) != 0)
    stop("gzip gescheitert: ", f)
}
# gzip-Stufe: Dateien je Gruppe (Format 4; faelle_diff.py vergleicht sie Byte für Byte mit dem Katalog) und alles mit
# SIMLEV_ERZEUGEN=1 mit 9; flache Arbeitsdateien (Format 3) mit SIMLEV_GZIP_STUFE, sonst 1 (gleicher Inhalt)
.ref_gzip_stufe <- function(format) {
  if (format != 3 || identical(Sys.getenv("SIMLEV_ERZEUGEN"), "1")) return(9L)
  k <- suppressWarnings(as.integer(Sys.getenv("SIMLEV_GZIP_STUFE")))
  if (is.na(k) || k < 1L || k > 9L) 1L else k
}

# Abgelegte Tests je Gruppe: feste Gruppe unverändert, sonst Zeilen von Tabellen je Modul und Funktion
.ref_gruppiert <- function(items) {
  out <- setNames(lapply(.REF_GRUPPEN, function(g) list(cases = list(), keys = list(), tab = list())), .REF_GRUPPEN)
  for (it in items) {
    c0 <- it$case
    if (!is.null(it$gruppe)) {
      g <- it$gruppe; n <- length(out[[g]]$cases) + 1L
      out[[g]]$cases[[n]] <- c0; out[[g]]$keys[[n]] <- it$keys
      next
    }
    g <- .ref_gruppe(c0); fn <- .ref_fn(c0); tk <- paste0(c0$module, "/", fn)
    row <- c(list(z = c0$id), c0[setdiff(names(c0), c("id", "module"))])
    i <- out[[g]]$tab[[tk]]
    if (is.null(i)) {
      i <- length(out[[g]]$cases) + 1L; out[[g]]$tab[[tk]] <- i
      out[[g]]$cases[[i]] <- list(id = fn, module = c0$module, note = NULL, tabelle = list()); out[[g]]$keys[[i]] <- character(0)
    }
    out[[g]]$cases[[i]]$tabelle[[length(out[[g]]$cases[[i]]$tabelle) + 1L]] <- row
    out[[g]]$keys[[i]] <- c(out[[g]]$keys[[i]], it$keys)
  }
  for (g in .REF_GRUPPEN) for (i in seq_along(out[[g]]$cases)) {
    x <- out[[g]]$cases[[i]]
    if (!is.null(x$tabelle) && is.null(x$inputs) && is.null(x$note))
      out[[g]]$cases[[i]]$note <- sprintf("prüft: %s (%s) je Zeile wie R (Ergebnis, Ausgaben, Warnungen bzw. Meldung)", x$id, x$module)
  }
  out
}

# Dateien schreiben: je Gruppe tests/<gruppe>/faelle/<bereich>.jsonl.gz (SIMLEV_FAELLE_DIR=D: D/<gruppe>/…); mit
# SIMLEV_GEN_ALLE=1 zusätzlich alle Fälle flach nach D/alle/; Zufallsprüfungen (alle = TRUE) flach nach D/<bereich>
ref_schreiben <- function() {
  d <- Sys.getenv("SIMLEV_FAELLE_DIR")
  # seit 1.6.2: in den Katalog tests/ nur über den ausdrücklichen Befehl tests/werkzeuge/erzeugen.py (SIMLEV_ERZEUGEN=1);
  # Gleichlauf und Zufallsprüfungen schreiben immer nach SIMLEV_FAELLE_DIR
  if (!nzchar(d) && !identical(Sys.getenv("SIMLEV_ERZEUGEN"), "1"))
    stop("Referenzfälle in tests/ nur über tests/werkzeuge/erzeugen.py (sonst SIMLEV_FAELLE_DIR setzen)", call. = FALSE)
  its <- .ref$items
  if (.ref$nur_alle) {
    f <- file.path(if (nzchar(d)) d else "tests", paste0(.ref$bereich, ".jsonl.gz"))
    .ref_write(f, lapply(its, `[[`, "case"), lapply(its, `[[`, "keys"), list(format = 3))
    cat(sprintf("%s: %d Fälle (%s)\n", .ref$bereich, length(its), f))
    return(invisible(NULL))
  }
  sel <- vapply(its, `[[`, NA, "sel")
  gr <- .ref_gruppiert(its[sel])
  n <- integer(0)
  # Dateien je Gruppe nur, wenn sie jemand liest (seit 1.6.3; R-kern-18): nicht im Gleichlauf mit Teilmenge
  nur_alle <- .ref_alle() && (identical(Sys.getenv("SIMLEV_GEN_NUR_ALLE"), "1") || .ref_subset() > 1L)
  for (g in .REF_GRUPPEN) {
    f <- if (nzchar(d)) file.path(d, g, paste0(.ref$bereich, ".jsonl.gz")) else file.path("tests", g, "faelle", paste0(.ref$bereich, ".jsonl.gz"))
    if (!nur_alle) {
      if (length(gr[[g]]$cases)) .ref_write(f, gr[[g]]$cases, gr[[g]]$keys, list(format = 4, gruppe = g))
      else if (file.exists(f)) unlink(f)
    }
    n[g] <- length(gr[[g]]$cases)
  }
  if (.ref_alle()) .ref_write(file.path(if (nzchar(d)) d else "tests", "alle", paste0(.ref$bereich, ".jsonl.gz")),
                              lapply(its, `[[`, "case"), lapply(its, `[[`, "keys"), list(format = 3))
  ids <- vapply(its, `[[`, "", "key")
  fehlt <- setdiff(grep(paste0("^(", paste(unique(sub("/.*", "", ids)), collapse = "|"), ")/"), .ref$auswahl, value = TRUE), ids)
  if (length(fehlt) && .ref_subset() == 1L)
    warning("Auswahl nennt Fälle, die der Generator nicht erzeugt: ", paste(head(fehlt, 10), collapse = ", "))
  cat(sprintf("%s: %d Fälle erzeugt, %d abgelegt als %s Tests (gleichlauf/fehler/ausgabe)%s\n", .ref$bereich, length(its),
              sum(sel), paste(n, collapse = "/"), if (nur_alle) "; Dateien je Gruppe nicht geschrieben" else ""))
}

# Referenzfälle für die Python- und die Julia-Fassung: alle Funktionen des R-Pakets
# (die Engine simulation() zusätzlich über golden/cases und golden/extra) und die
# nachgebauten R-Interna.
#
# Ein Fall ist eine gzip-komprimierte JSON-Datei mit
#   id, module          Kennung
#   inputs              benannte Eingabeobjekte (als Baum, s. enc())
#   r                   R-Code, der das Ergebnis liefert (letzter Ausdruck)
#   py                  Python-Code, der `result = ...` setzt
#   jl                  Julia-Code, der `result = ...` setzt (optional)
#   result              Ergebnis als Baum
#   output              Konsolenausgabe während des Aufrufs (cat/print)
#   print               capture.output(print(result)) oder NULL
#   warnings            Warnungen (Texte) während des Aufrufs
#   error               Fehlermeldung, falls R mit Fehler abbricht
#   suggests            optionale Pakete (evd, rugarch, imputeTS), die R installiert hatte
#   sys_time            (optional) feste Uhrzeit as.numeric(Sys.time()) während des
#                       Aufrufs, als Text ("%.17g"); die Harnesses setzen dann
#                       SIMLEV_R_SYS_TIME (z. B. für Rsolnp::gosolnp mit rseed = NULL)
#
# Baumformat (enc): jedes Objekt ist eine Liste mit Typ `t`:
#   null | num | int | lgl | chr | date | list | df | mat | skip
# Zahlen als Hex-Literale ("%a"), NA als "NA", NaN als "NaN"; Attribute
# `names`, `dim`, `dimnames`, `class` werden mitgeschrieben.
#
# Verwendung in einem Generator (Arbeitsverzeichnis = Repo-Wurzel):
#   source("golden/modules/ref_tools.R")
#   ref_init("bootstrap")
#   ref_case("bs01", r = "set.seed(1); bootstrap_data(d, n = 10)",
#            py = "simlev.set_seed(1); result = simlev.bootstrap_data(d, n=10)",
#            inputs = list(d = df))
suppressMessages({ library(SimLev); library(jsonlite) })

.ref <- new.env()

ref_init <- function(module, outdir = file.path("golden", "modules", module)) {
  dir.create(outdir, showWarnings = FALSE, recursive = TRUE)
  old <- list.files(outdir, "\\.json\\.gz$", full.names = TRUE)
  if (length(old)) file.remove(old)
  .ref$module <- module; .ref$outdir <- outdir; .ref$n <- 0L
  invisible(outdir)
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

# Sys.time() liefert bis zum Aufruf von undo() den festen Wert t (Ersatz in baseenv(),
# gilt auch für Aufrufe aus Paket-Namensräumen, z. B. Rsolnp::gosolnp)
.ref_fix_time <- function(t) {
  be <- baseenv(); old <- get("Sys.time", be)
  unlockBinding("Sys.time", be); assign("Sys.time", function() .POSIXct(t), be); lockBinding("Sys.time", be)
  function() { unlockBinding("Sys.time", be); assign("Sys.time", old, be); lockBinding("Sys.time", be) }
}

# print = NA: Druckausgabe nur für Objekte mit eigener print-Methode in SimLev
# sys_time: feste Uhrzeit (Sekunden seit 1970) während des Aufrufs (Feld sys_time)
ref_case <- function(id, r, py, inputs = list(), print = NA, note = NULL, jl = NULL, sys_time = NULL) {
  env <- new.env(parent = globalenv())
  for (k in names(inputs)) assign(k, inputs[[k]], envir = env)
  if (!is.null(sys_time)) {
    undo_time <- .ref_fix_time(sys_time)
    on.exit(undo_time(), add = TRUE)
  }
  warns <- character(0)
  err <- NULL
  out_txt <- character(0)
  res <- NULL
  out_txt <- capture.output(
    res <- tryCatch(withCallingHandlers(eval(parse(text = r), envir = env),
                                        warning = function(w) { warns <<- c(warns, conditionMessage(w)); invokeRestart("muffleWarning") },
                                        message = function(m) invokeRestart("muffleMessage")),
                    error = function(e) { err <<- conditionMessage(e); NULL }))
  case <- list(id = id, module = .ref$module, note = note,
               inputs = lapply(inputs, enc), r = r, py = py)
  if (!is.null(jl)) case$jl <- jl
  # optionale Pakete, die R bei diesem Fall installiert hatte (die Ports setzen
  # SIMLEV_R_SUGGESTS entsprechend; Fälle ohne das Feld: keines)
  case$suggests <- I(Filter(function(p) requireNamespace(p, quietly = TRUE), c("evd", "rugarch", "imputeTS")))
  if (!is.null(sys_time)) case$sys_time <- sprintf("%.17g", sys_time)
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
  f <- file.path(.ref$outdir, sprintf("%s.json", id))
  writeLines(toJSON(case, digits = NA, auto_unbox = TRUE, null = "null", na = "null", always_decimal = FALSE), f)
  system2("gzip", c("-9", "-f", "-n", shQuote(f)))
  .ref$n <- .ref$n + 1L
  invisible(res)
}

ref_done <- function() cat(sprintf("%s: %d Fälle in %s\n", .ref$module, .ref$n, .ref$outdir))

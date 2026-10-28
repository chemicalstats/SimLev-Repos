#!/usr/bin/env Rscript
# Schnittstellen-Auszug der R-Fassung (Etappe 3, tools/api_snapshot).
#
# Liest die Exporte (export(...)) und S3-Methoden (S3method(...)) aus
# r/NAMESPACE und je Funktion die Argumente aus den Quellen r/R/*.R:
# Namen in Reihenfolge, Standardwert als Text (formals + deparse), `...`
# markiert, Datei und Zeile (srcref). Die Quellen werden nur geparst; es wird
# nur der Ausdruck `function(...)` ausgewertet, kein Paketcode ausgeführt.
#
# Aufruf aus der Repo-Wurzel:
#   LC_ALL=C.UTF-8 Rscript tools/api_snapshot/api_r.R [ausgabe.json]
# Voreinstellung der Ausgabe: tools/api_snapshot/out/api_r.json
# Braucht nur Basis-R und jsonlite.

args <- commandArgs(trailingOnly = TRUE)
root <- normalizePath(".")
if (!file.exists(file.path(root, "r", "NAMESPACE")))
  stop("Bitte aus der Repo-Wurzel aufrufen (r/NAMESPACE fehlt).")
out <- if (length(args)) args[[1]] else file.path(root, "tools", "api_snapshot", "out", "api_r.json")
dir.create(dirname(out), showWarnings = FALSE, recursive = TRUE)

# ── NAMESPACE ────────────────────────────────────────────────────────────────
ns <- parse(file.path(root, "r", "NAMESPACE"), keep.source = FALSE)
exports <- character(); s3 <- list()
for (e in ns) {
  fn <- as.character(e[[1]])
  if (fn == "export") exports <- c(exports, vapply(as.list(e)[-1], as.character, ""))
  if (fn == "S3method") s3[[length(s3) + 1]] <- c(as.character(e[[2]]), as.character(e[[3]]))
}

# ── Definitionen in r/R/*.R ──────────────────────────────────────────────────
defs <- list()     # name -> list(fun, file, line)
alias <- list()    # name -> anderer Name (name <- anderer_name)
sandbox <- new.env(parent = baseenv())
for (f in sort(list.files(file.path(root, "r", "R"), pattern = "[.][Rr]$", full.names = TRUE))) {
  ex <- parse(f, keep.source = TRUE, encoding = "UTF-8")
  sr <- attr(ex, "srcref")
  rel <- sub(paste0("^", root, "/"), "", normalizePath(f))
  for (i in seq_along(ex)) {
    e <- ex[[i]]
    if (!is.call(e) || !(as.character(e[[1]]) %in% c("<-", "=")) || !is.name(e[[2]])) next
    nm <- as.character(e[[2]]); rhs <- e[[3]]
    if (is.call(rhs) && identical(rhs[[1]], as.name("function"))) {
      defs[[nm]] <- list(fun = eval(rhs, sandbox), file = rel, line = sr[[i]][1])
    } else if (is.name(rhs)) {
      alias[[nm]] <- list(to = as.character(rhs), file = rel, line = sr[[i]][1])
    } else if (startsWith(nm, ".") && is.call(rhs) &&
               all(all.names(rhs) %in% c("c", "list", "data.frame", "character", "numeric", "integer",
                                         "logical", "TRUE", "FALSE", "NULL", "-", "stringsAsFactors"))) {
      # Konstante der Quellen aus reinen Literalen (z. B. .wd_rules <- c(constant = 1L, ...))
      v <- tryCatch(eval(rhs, baseenv()), error = function(e) NULL)
      if (!is.null(v)) assign(nm, v, envir = sandbox)
    }
  }
}

# Argumente, die der Rumpf mit match.arg(<arg>, ...) auswertet: Ihr Standardwert
# c("a", "b", ...) ist die Auswahl, wirksam ist das erste Element.
match_arg_names <- function(fun) {
  found <- character()
  walk <- function(e) {
    if (is.call(e)) {
      if (identical(e[[1]], as.name("match.arg")) && length(e) >= 2 && is.name(e[[2]]))
        found <<- c(found, as.character(e[[2]]))
      for (k in as.list(e)[-1]) if (!missing(k)) walk(k)
    }
  }
  walk(body(fun))
  unique(found)
}

# Wertet der Rumpf `...` aus (list(...), f(...), ..1, hasArg, nargs)?
dots_used <- function(fun) {
  used <- FALSE
  walk <- function(e) {
    if (is.symbol(e) && as.character(e) %in% c("...", "..1", "..2")) used <<- TRUE
    if (is.call(e)) {
      if (identical(e[[1]], as.name("hasArg")) || identical(e[[1]], as.name("nargs"))) used <<- TRUE
      for (k in as.list(e)) if (!missing(k)) walk(k)
    }
  }
  walk(body(fun))
  used
}

# Ausdrücke als Standardwert (z. B. names(.wd_rules)), die keine anderen
# Argumente und keine Paketfunktionen verwenden, werden in der Sandbox
# ausgewertet (Basis-R plus die Konstanten der Quellen); nur kurze atomare
# Ergebnisse kommen als default_value dazu.
eval_default <- function(v, formal_names) {
  if (!(is.call(v) || is.symbol(v))) return(NULL)
  if (is.call(v) && as.character(v[[1]])[1] %in% c("c", "list", "function")) return(NULL)
  nm <- all.names(v)
  if (any(nm %in% formal_names) || any(nm %in% names(defs))) return(NULL)
  r <- tryCatch(eval(v, sandbox), error = function(e) NULL)
  if (is.null(r) || !is.atomic(r) || length(r) > 30 || length(r) == 0) return(NULL)
  paste(deparse(unname(r), width.cutoff = 500L), collapse = " ")
}

arg_list <- function(fun) {
  fo <- formals(fun)
  ma <- match_arg_names(fun)
  du <- dots_used(fun)
  lapply(seq_along(fo), function(i) {
    a <- names(fo)[i]
    if (a == "...") return(list(name = "...", kind = "dots", has_default = FALSE, default = NULL, dots_used = du))
    miss <- is.symbol(fo[[i]]) && identical(as.character(fo[[i]]), "")
    r <- list(name = a, kind = "arg", has_default = !miss,
              default = if (miss) NULL else paste(trimws(deparse(fo[[i]], width.cutoff = 500L)), collapse = " "))
    if (a %in% ma) r$match_arg <- TRUE
    if (!miss) {
      ev <- eval_default(fo[[i]], names(fo))
      if (!is.null(ev)) r$default_value <- ev
    }
    r
  })
}

entry <- function(name, kind, generic = NULL, cls = NULL) {
  d <- defs[[name]]; note <- NULL
  if (is.null(d) && !is.null(alias[[name]])) {
    a <- alias[[name]]; d <- defs[[a$to]]
    note <- sprintf("Alias von %s (%s:%d)", a$to, a$file, a$line)
  }
  base <- list(name = name, key = name, kind = kind, generic = generic, class = cls)
  if (is.null(d))
    return(c(base, list(file = NULL, line = NULL, args = list(), defaults_known = FALSE,
                        note = "keine Definition in r/R/*.R gefunden")))
  c(base, list(file = d$file, line = d$line, args = arg_list(d$fun), defaults_known = TRUE, note = note))
}

funs <- lapply(sort(unique(exports)), function(n) entry(n, "function"))
meths <- lapply(s3, function(m) entry(paste0(m[1], ".", m[2]), "method", generic = m[1], cls = m[2]))

res <- list(
  language = "R",
  source = "r/NAMESPACE, r/R/*.R",
  generated = format(Sys.time(), "%Y-%m-%d %H:%M:%S %Z"),
  tool = "tools/api_snapshot/api_r.R",
  notes = list("Standardwerte: deparse() der formals, unverändert.",
               "kind 'dots' markiert `...`.",
               "match_arg: der Rumpf ruft match.arg(<arg>) auf (Auswahlvektor, wirksam ist das erste Element).",
               "dots_used (bei `...`): der Rumpf wertet `...` aus bzw. reicht es weiter.",
               "default_value: Ausdruck ohne Argument- und Paketfunktionsbezug, in Basis-R mit den Literal-Konstanten der Quellen ausgewertet."),
  functions = c(funs, meths),
  classes = list()
)
writeLines(jsonlite::toJSON(res, auto_unbox = TRUE, null = "null", pretty = TRUE, digits = NA), out, useBytes = TRUE)
miss <- vapply(res$functions, function(x) is.null(x$file), TRUE)
cat(sprintf("R: %d Exporte, %d S3-Methoden -> %s%s\n", length(funs), length(meths), out,
            if (any(miss)) sprintf(" (ohne Definition: %s)", paste(vapply(res$functions[miss], `[[`, "", "name"), collapse = ", ")) else ""))

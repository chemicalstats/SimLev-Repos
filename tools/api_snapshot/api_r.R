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
#       [--frozen-out datei --stand text] [--frozen-check datei]
# Voreinstellung der Ausgabe: tools/api_snapshot/out/api_r.json
# --frozen-out: zusätzlich den eingefrorenen Stand schreiben (ohne Datei, Zeile,
#   Datum; sortiert), --stand ist die Überschrift des Eintrags in CHANGES.md.
# --frozen-check: Auszug mit dem eingefrorenen Stand vergleichen; bei
#   Abweichung Liste der Unterschiede und Rückgabewert 1
#   (r/tests/testthat/test-api-frozen.R, run.sh --check).
# Braucht nur Basis-R und jsonlite.

args <- commandArgs(trailingOnly = TRUE)
take_opt <- function(flag) {
  i <- match(flag, args)
  if (is.na(i)) return(NULL)
  if (i == length(args)) stop(flag, " braucht einen Wert")
  v <- args[[i + 1L]]; args <<- args[-c(i, i + 1L)]
  v
}
frozen_out <- take_opt("--frozen-out"); frozen_check <- take_opt("--frozen-check"); stand <- take_opt("--stand")
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

# ── Eingefrorener Stand (tools/api_snapshot/frozen/r.json) ──────────────────
# Je Funktion bzw. Methode die Argumente in Reihenfolge: Name, Art, Standardwert
# (Text; null = keiner), dazu value (ausgewerteter Standardwert) und match_arg,
# wo vorhanden. Ohne Datei, Zeile, Modul, Datum und Vermerke; Schlüssel nach
# Bytes sortiert, ein Argument je Zeile.
FROZEN_HINT <- "Erzeugt von tools/api_snapshot/run.sh --freeze (mit Eintrag in CHANGES.md); nicht von Hand ändern."
FROZEN_FIELDS <- c("name", "kind", "default", "value", "match_arg", "default_known")

frozen_of <- function(res) {
  one <- function(a) {
    r <- list(name = a$name, kind = a$kind, default = if (isTRUE(a$has_default)) a$default else NULL)
    if (!is.null(a$default_value)) r$value <- a$default_value
    if (isTRUE(a$match_arg)) r$match_arg <- TRUE
    r
  }
  sect <- function(kind) {
    fs <- Filter(function(f) f$kind == kind, res$functions)
    k <- vapply(fs, `[[`, "", "key")
    o <- order(k, method = "radix")
    stats::setNames(lapply(fs[o], function(f) lapply(f$args, one)), k[o])
  }
  list(functions = sect("function"), methods = sect("method"), classes = list(), other = list())
}

json1 <- function(x) {
  if (is.null(x)) return("null")
  if (is.list(x)) return(paste0("{", paste(sprintf("%s: %s", vapply(names(x), json1, ""),
                                                   vapply(x, json1, "")), collapse = ", "), "}"))
  as.character(jsonlite::toJSON(x, auto_unbox = TRUE, digits = NA))
}

frozen_text <- function(fz, lang, stand) {
  L <- c("{", sprintf(" \"language\": %s,", json1(lang)), sprintf(" \"stand\": %s,", json1(stand)),
         sprintf(" \"hinweis\": %s,", json1(FROZEN_HINT)))
  secs <- c("functions", "methods", "classes", "other")
  for (s in secs) {
    end <- if (s == secs[length(secs)]) "" else ","
    v <- fz[[s]]
    if (!length(v)) { L <- c(L, sprintf(" %s: %s%s", json1(s), if (s %in% c("classes", "other")) "[]" else "{}", end)); next }
    if (s %in% c("classes", "other")) {
      L <- c(L, sprintf(" %s: [", json1(s)), paste0("  ", vapply(v, json1, ""), c(rep(",", length(v) - 1L), "")),
             paste0(" ]", end))
      next
    }
    L <- c(L, sprintf(" %s: {", json1(s)))
    for (i in seq_along(v)) {
      e <- if (i < length(v)) "," else ""; a <- v[[i]]
      if (!length(a)) { L <- c(L, sprintf("  %s: []%s", json1(names(v)[i]), e)); next }
      L <- c(L, sprintf("  %s: [", json1(names(v)[i])),
             paste0("   ", vapply(a, json1, ""), c(rep(",", length(a) - 1L), "")), paste0("  ]", e))
    }
    L <- c(L, paste0(" }", end))
  }
  c(L, "}")
}

read_frozen <- function(file) jsonlite::fromJSON(file, simplifyVector = FALSE)

# Unterschiede alt (eingefroren) -> neu (heute), als lesbare Zeilen
frozen_diff <- function(old, new) {
  msg <- character()
  shown <- function(a) if (is.null(a$default)) "(keiner)" else a$default
  sig <- function(args) paste(vapply(args, function(a) if (is.null(a$default)) a$name else paste(a$name, "=", a$default), ""),
                              collapse = ", ")
  for (s in c("functions", "methods")) {
    what <- if (s == "functions") "Funktion" else "Methode"
    o <- old[[s]]; n <- new[[s]]
    for (k in setdiff(names(o), names(n))) msg <- c(msg, sprintf("%s weg: %s", what, k))
    for (k in setdiff(names(n), names(o))) msg <- c(msg, sprintf("%s neu: %s(%s)", what, k, sig(n[[k]])))
    for (k in intersect(names(o), names(n))) {
      oa <- o[[k]]; na <- n[[k]]
      on <- vapply(oa, `[[`, "", "name"); nn <- vapply(na, `[[`, "", "name")
      for (x in setdiff(on, nn)) msg <- c(msg, sprintf("%s: Argument weg: %s", k, x))
      for (x in setdiff(nn, on)) {
        i <- match(x, nn)
        msg <- c(msg, sprintf("%s: Argument neu: %s (Stelle %d, Standardwert %s)", k, x, i, shown(na[[i]])))
      }
      common_o <- on[on %in% nn]; common_n <- nn[nn %in% on]
      if (!identical(common_o, common_n))
        msg <- c(msg, sprintf("%s: Argumente umsortiert: vorher %s; jetzt %s", k,
                              paste(common_o, collapse = ", "), paste(common_n, collapse = ", ")))
      for (x in common_o) {
        a <- oa[[match(x, on)]]; b <- na[[match(x, nn)]]
        if (!identical(a$kind, b$kind)) msg <- c(msg, sprintf("%s: Art von %s geändert: %s -> %s", k, x, a$kind, b$kind))
        if (!identical(a$default, b$default))
          msg <- c(msg, sprintf("%s: Standardwert von %s geändert: %s -> %s", k, x, shown(a), shown(b)))
        for (f in setdiff(FROZEN_FIELDS, c("name", "kind", "default"))) {
          if (!identical(a[[f]], b[[f]]))
            msg <- c(msg, sprintf("%s: Standardwert von %s geändert (%s): %s -> %s", k, x, f,
                                  if (is.null(a[[f]])) "(keiner)" else format(a[[f]]),
                                  if (is.null(b[[f]])) "(keiner)" else format(b[[f]])))
        }
      }
    }
  }
  for (s in c("classes", "other")) {
    what <- if (s == "classes") "Klasse" else "sonstiger Export"
    o <- unlist(old[[s]]); n <- unlist(new[[s]])
    for (k in setdiff(o, n)) msg <- c(msg, sprintf("%s weg: %s", what, k))
    for (k in setdiff(n, o)) msg <- c(msg, sprintf("%s neu: %s", what, k))
  }
  msg
}

FREEZE_HOWTO <- c(
  "Ist die Änderung gewollt, den Stand bewusst neu festschreiben:",
  "  1. Eintrag oben in tools/api_snapshot/CHANGES.md: \"## JJJJ-MM-TT – Titel\" mit \"- Was: …\" und \"- Warum: …\"",
  "  2. tools/api_snapshot/run.sh --freeze   (aus der Repo-Wurzel; schreibt frozen/ für R, Python und Julia neu)",
  "  3. frozen/ und CHANGES.md zusammen einchecken.",
  "Sonst die Änderung im Code zurücknehmen.")

if (!is.null(frozen_out) || !is.null(frozen_check)) {
  fz <- frozen_of(res)
  if (!is.null(frozen_out)) {
    if (is.null(stand)) stop("--frozen-out braucht --stand (Überschrift des Eintrags in CHANGES.md)")
    dir.create(dirname(frozen_out), showWarnings = FALSE, recursive = TRUE)
    writeLines(frozen_text(fz, "R", stand), frozen_out, useBytes = TRUE)
    cat(sprintf("R: eingefrorener Stand -> %s\n", frozen_out))
  }
  if (!is.null(frozen_check)) {
    if (!file.exists(frozen_check)) {
      cat(sprintf("R: eingefrorener Stand %s fehlt; anlegen mit tools/api_snapshot/run.sh --freeze\n", frozen_check))
      quit(status = 1)
    }
    old <- read_frozen(frozen_check)
    tmp <- tempfile(fileext = ".json"); writeLines(frozen_text(fz, "R", old$stand), tmp, useBytes = TRUE)
    new <- read_frozen(tmp); unlink(tmp)
    d <- frozen_diff(old, new)
    if (length(d)) {
      cat(sprintf("R: Schnittstelle weicht vom eingefrorenen Stand ab (%s, Stand \"%s\"), %d Unterschied(e):\n",
                  frozen_check, old$stand, length(d)),
          paste0("  - ", d, "\n"), paste0(FREEZE_HOWTO, "\n"), sep = "")
      quit(status = 1)
    }
    cat(sprintf("R: Schnittstelle entspricht dem eingefrorenen Stand (%s; %d Funktionen, %d Methoden)\n",
                old$stand, length(new$functions), length(new$methods)))
  }
}

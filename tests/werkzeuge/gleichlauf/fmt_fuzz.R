# tests/werkzeuge/gleichlauf/fmt_fuzz.R – Fuzz des Zahlformats (seit 1.6.0 in Python und Julia im C-Kern
# core/slc_rbase_fmt.cpp: sl_r_sprintf, sl_r_str_signif, sl_r_format_real, sl_r_encode_real, sl_r_as_character_real,
# sl_r_fround, sl_r_fprec; bis 1.5.2 je zwei sprintf-Nachbildungen in python/simlev/_r/ und julia/src/r/)
#
#   LC_ALL=C.UTF-8 R_LIBS=<R-Bibliothek> SIMLEV_FAELLE_DIR=<ordner> Rscript tests/werkzeuge/gleichlauf/fmt_fuzz.R <n> <seed>
#
# Erzeugt <n> Fälle im Format der Referenzfälle (tests/gleichlauf/erzeugen/ref_tools.R) als Modul fmt_fuzz:
#   - s-Fälle: sprintf (Vektorform simlev._r.fmt.sprintf / RFmt.sprintf und für Skalare der schnelle Weg
#     simlev._r.rformat.r_sprintf / SL.r_sprintf) mit allen Umwandlungen diosfeEgGxXaA, Flags -+ #0, Breite,
#     Genauigkeit, * und %n$, %%, Doubles mit NA, NaN, ±Inf, ±0, sehr großen und kleinen Werten, ganzen Zahlen, Wahrheits-
#     werten, Texten mit Nicht-ASCII (Breiten in Bytes), Recycling; Fehler (falscher Typ, zu wenige Argumente).
#   - r-Fälle: round und signif mit Stellen als Vektor (auch negativ, groß, NA).
#   - c-Fälle: formatC mit den Formaten d, f, e, E, g, G, fg, Flags, positiver und negativer Breite, digits (auch negativ).
#   - f-Fälle: format(x, digits, nsmall) und as.character für Doubles.
# NA in ganzen Zahlen, Wahrheitswerten und Texten nur in Vektoren (ein skalares NA kommt in Python als None an).
# Warnungen und Fehler mit ihren Aufrufen (r_calls) wie sim_fuzz.R.
#
# Prüfung (tests/werkzeuge/gleichlauf/run.py, Schritt 5): abgelegte Referenz (seit 1.6.2 aus R 1.6.2, run.py --ref-erzeugen 162), R neu mit
# tests/werkzeuge/gleichlauf/sim_fuzz_cmp.py, Python und Julia mit vergleich.py/vergleich.jl gegen die Referenz.
source("tests/gleichlauf/erzeugen/ref_tools.R")
args <- commandArgs(TRUE)
N <- as.integer(args[1]); seed0 <- as.integer(if (length(args) >= 2) args[2] else 20261122)
ref_bereich("fmt_fuzz", alle = TRUE); ref_init("fmt_fuzz")
pick <- function(x) x[[sample.int(length(x), 1L)]]
coin <- function(p) runif(1) < p

fuzz_case <- function(id, r, py, jl, inputs) {
  ref_case(id, r = r, py = py, jl = jl, inputs = inputs)
  if (!.ref_in_subset(id)) return(invisible(NULL))
  env <- new.env(parent = globalenv())
  for (k in names(inputs)) assign(k, inputs[[k]], envir = env)
  dp <- function(x) if (is.null(x)) "NULL" else paste(deparse(x), collapse = " ")
  wc <- character(0); ec <- NULL
  invisible(capture.output(tryCatch(withCallingHandlers(eval(parse(text = r), envir = env),
    warning = function(w) { wc <<- c(wc, dp(conditionCall(w))); invokeRestart("muffleWarning") },
    message = function(m) invokeRestart("muffleMessage")),
    error = function(e) ec <<- dp(conditionCall(e)))))
  ref_case_extra(list(r_calls = list(warnings = as.list(wc), error = ec)))
}
num <- function(v) sprintf("%.17g", v)
qs <- function(s) paste0("'", gsub("'", "\\\\'", s), "'")          # Python/R-Text
qj <- function(s) paste0("\"", gsub("\\$", "\\\\$", gsub("\"", "\\\\\"", s)), "\"")   # Julia-Text
PH <- "import math\nimport numpy as np\nimport simlev._r.fmt as fm\nimport simlev._r.rformat as rf\n"
JH <- "F = SL.RFmt\n"
SPEZ <- c(NA, NaN, Inf, -Inf, 0, -0, 1e300, -1e-300, 5e-324, 2^53, 0.5, 2.5, -1.5)
TXT <- c("a", "äöü", "名前", "€", "", "x y", "NA", "abcdefghij")
dbl <- function(n) {
  x <- switch(pick(1:5), rnorm(n), rnorm(n) * 10^sample(-12:12, n, TRUE), round(rnorm(n) * 1000), runif(n),
              round(rnorm(n), sample(0:4, 1)))
  if (n > 0 && coin(0.5)) { k <- sample.int(n, max(1L, n %/% 3L)); x[k] <- sample(SPEZ, length(k), TRUE) }
  x
}
wert <- function(cl, n) switch(cl,
  d = dbl(n),
  i = sample(c(-1000000L, -255L, -1L, 0L, 1L, 7L, 255L, 65535L, .Machine$integer.max), n, TRUE),   # ohne NA: Python
  # liest ganze Zahlen mit NA als Doubles
  w = { v <- round(rnorm(n) * 100); if (n > 1 && coin(0.3)) v[sample.int(n, 1)] <- NA; v },   # ganze Doubles
  l = { v <- sample(c(TRUE, FALSE), n, TRUE); if (n > 1 && coin(0.3)) v[sample.int(n, 1)] <- NA; v },
  s = { v <- sample(TXT, n, TRUE); if (n > 1 && coin(0.2)) v[sample.int(n, 1)] <- NA; v })
spec1 <- function(cl) {
  conv <- switch(cl, d = pick(c("f", "e", "E", "g", "G", "a", "A", "s", "f", "g", "d")),
                 i = pick(c("d", "i", "o", "x", "X", "s", "f", "d")), w = pick(c("d", "x", "f", "s")),
                 l = pick(c("d", "i", "s", "f", "x")), s = pick(c("s", "s", "d")))
  fl <- paste(unique(sample(c("-", "+", " ", "#", "0"), pick(0:2), TRUE)), collapse = "")
  wd <- pick(c("", "", "1", "5", "8", "12", "*"))
  pr <- if (coin(0.5) || cl == "s") "" else paste0(".", pick(c("0", "1", "3", "6", "10", "*")))   # Texte ohne
  # Genauigkeit: R schneidet Bytes ab und kann ungültiges UTF-8 liefern
  paste0("%", fl, wd, pr, conv)
}

for (kk in seq_len(N)) {
  set.seed(seed0 + kk)
  art <- c("s", "s", "s", "s", "r", "c", "c", "f")[kk %% 8 + 1]
  if (art == "s") {
    n <- pick(c(1, 1, 1, 3)); k <- pick(c(1, 1, 2))
    cls <- sample(c("d", "d", "i", "w", "l", "s"), k, TRUE)
    specs <- vapply(cls, spec1, "")
    nstar <- sum(lengths(regmatches(specs, gregexpr("\\*", specs))))
    pre <- pick(c("", "x=", "Wert: ", "% ", "€ "))
    f <- paste0(pre, paste(specs, collapse = pick(c(" ", "|", "%%"))), pick(c("", ";", " Tage")))
    if (coin(0.05)) f <- paste0("%2$s %1$s")
    inp <- list(); an <- character(0)
    if (grepl("^%2\\$s %1\\$s$", f)) { inp <- list(a1 = wert("d", n), a2 = wert("s", n)); an <- c("a1", "a2") }
    else {
      j <- 0
      for (q in seq_along(cls)) {
        m <- lengths(regmatches(specs[q], gregexpr("\\*", specs[q])))
        for (t in seq_len(m)) { j <- j + 1; nm <- paste0("a", j); inp[[nm]] <- sample(c(-6L, 0L, 3L, 9L), 1); an <- c(an, nm) }
        j <- j + 1; nm <- paste0("a", j); inp[[nm]] <- wert(cls[q], n); an <- c(an, nm)
      }
    }
    if (coin(0.04) && length(an)) { inp[[an[length(an)]]] <- NULL; an <- an[-length(an)] }   # zu wenige Argumente
    fast <- n == 1 && coin(0.5) && !grepl("\\$", f)
    r <- sprintf("sprintf(%s%s)", qs(f), paste0(", ", an, collapse = ""))
    if (!length(an)) r <- sprintf("sprintf(%s)", qs(f))
    pa <- paste0(", ", an, collapse = ""); if (!length(an)) pa <- ""
    py <- sprintf("%sresult = %s(%s%s)", PH, if (fast) "rf.r_sprintf" else "fm.sprintf", qs(f), pa)
    jl <- sprintf("%sresult = %s(%s%s)", JH, if (fast) "SL.r_sprintf" else "F.sprintf", qj(f), pa)
    fuzz_case(sprintf("s%05d", kk), r = r, py = py, jl = jl, inputs = inp)
  } else if (art == "r") {
    n <- pick(c(1, 4, 20)); x <- dbl(n)
    d <- if (coin(0.6)) pick(c(0, 1, 2, 3, -1, -2, 5, 15, 16, 20, 400, -400)) else sample(c(-2, 0, 1, 2, 7, NA, 0.5), pick(c(2, n)), TRUE)
    if (length(d) > 1 && n %% length(d) != 0 && length(d) %% n != 0) d <- d[1]
    f <- pick(c("round", "signif"))
    r <- sprintf("%s(x, d)", f)
    py <- sprintf("%sresult = fm.%s(np.atleast_1d(x), d)", PH, if (f == "round") "r_round" else "signif")
    jl <- sprintf("%sresult = F.%s(x isa AbstractVector ? x : [x], d)", JH, if (f == "round") "r_round" else "signif")
    fuzz_case(sprintf("r%05d", kk), r = r, py = py, jl = jl, inputs = list(x = x, d = d))
  } else if (art == "c") {
    n <- pick(c(1, 3, 10)); fm_ <- pick(c("d", "f", "e", "E", "g", "G", "fg", "fg"))
    x <- if (fm_ == "d") as.integer(round(rnorm(n) * 1000)) else dbl(n)
    if (fm_ != "d") x[!is.finite(x)] <- 1.25
    wd <- pick(c(0, 1, 5, 10, -8)); dg <- pick(c(NA, 0, 1, 3, 6, 10, -2))
    fl <- pick(c("", "-", "0", "+", " ", "#", "0+"))
    if (fm_ == "fg" && coin(0.3)) fl <- pick(c("#", "-"))
    dr <- if (is.na(dg)) "NULL" else num(dg); dp <- if (is.na(dg)) "None" else num(dg); dj <- if (is.na(dg)) "nothing" else num(dg)
    r <- sprintf("formatC(x, width = %d, digits = %s, format = '%s', flag = '%s')", wd, dr, fm_, fl)
    py <- sprintf("%sresult = fm.formatC(%s, width=%d, digits=%s, format='%s', flag='%s')", PH, if (n == 1) "np.atleast_1d(x)" else "x", wd, dp, fm_, fl)
    jl <- sprintf("%sresult = F.formatC(%s; width = %d, digits = %s, format = \"%s\", flag = \"%s\")", JH, if (n == 1) "[x]" else "x", wd, dj, fm_, fl)
    fuzz_case(sprintf("c%05d", kk), r = r, py = py, jl = jl, inputs = list(x = x))
  } else {
    n <- pick(c(1, 3, 12)); x <- dbl(n)
    if (coin(0.5)) {
      dg <- pick(c(1, 3, 7, 15, 17, 22)); ns <- pick(c(0, 0, 2, 5))
      r <- sprintf("format(x, digits = %d, nsmall = %d)", dg, ns)
      py <- sprintf("%sresult = fm.format(%s, digits=%d, nsmall=%d)", PH, if (n == 1) "np.atleast_1d(x)" else "x", dg, ns)
      jl <- sprintf("%sresult = F.format(%s; digits = %d, nsmall = %d)", JH, if (n == 1) "[x]" else "x", dg, ns)
    } else {
      r <- "as.character(x)"
      py <- sprintf("%sresult = fm.as_character(%s)", PH, if (n == 1) "np.atleast_1d(x)" else "x")
      jl <- sprintf("%sresult = F.as_character(%s)", JH, if (n == 1) "[x]" else "x")
    }
    fuzz_case(sprintf("f%05d", kk), r = r, py = py, jl = jl, inputs = list(x = x))
  }
}
ref_done(); ref_schreiben()

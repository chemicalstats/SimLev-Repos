# tests/werkzeuge/gleichlauf/vec_fuzz.R – Fuzz von Einteilen, Folgen, Median und Sortieren (seit 1.6.0 in Python und
# Julia im C-Kern core/slc_rbase_vec.cpp: sl_r_bincode, sl_r_seq_len, sl_r_median; sort über sl_r_order)
#
#   LC_ALL=C.UTF-8 R_LIBS=<R-Bibliothek> SIMLEV_FAELLE_DIR=<ordner> Rscript tests/werkzeuge/gleichlauf/vec_fuzz.R <n> <seed>
#
# Erzeugt <n> Fälle im Format der Referenzfälle (tests/gleichlauf/erzeugen/ref_tools.R) als Modul vec_fuzz:
#   - c-Fälle: cut (Grenzen als Vektor, unsortiert, oder Anzahl; right, include.lowest, labels = FALSE, Standard-
#     beschriftung, eigene Beschriftungen mit Nicht-ASCII) und .bincode; Werte mit NA, NaN, ±Inf, ±0, auf den Grenzen;
#     Fehler (doppelte Grenzen, zu wenige Intervalle, falsche Zahl von Beschriftungen).
#   - s-Fälle: seq.int(from, to, length.out) mit großen, kleinen, nicht endlichen Differenzen und n 0 bis 50.
#   - m-Fälle: median (Doubles mit Bindungen und ±0, ganze Zahlen, NA/NaN mit und ohne na.rm, leer, Länge 1).
#   - o-Fälle: sort mit NA-Regeln (na.last NA/TRUE/FALSE, decreasing) für Zahlen mit ±0, NA, NaN, ±Inf.
# Warnungen und Fehler mit ihren Aufrufen (r_calls) wie sim_fuzz.R.
#
# Prüfung (tests/werkzeuge/gleichlauf/run.py, Schritt 5): Referenz aus R 1.5.2 (R_LIBS=/home/claude/rlib152), R neu mit
# tests/werkzeuge/gleichlauf/sim_fuzz_cmp.py, Python und Julia mit vergleich.py/vergleich.jl gegen die Referenz.
source("tests/gleichlauf/erzeugen/ref_tools.R")
args <- commandArgs(TRUE)
N <- as.integer(args[1]); seed0 <- as.integer(if (length(args) >= 2) args[2] else 20261119)
ref_bereich("vec_fuzz", alle = TRUE); ref_init("vec_fuzz")
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
pv <- function(v) if (is.na(v) && !is.nan(v)) "fm.NA_REAL" else if (is.nan(v)) "math.nan" else if (is.infinite(v)) (if (v > 0) "math.inf" else "-math.inf") else if (v == 0 && 1 / v < 0) "-0.0" else num(v)
jv <- function(v) if (is.na(v) && !is.nan(v)) "SL.NA" else if (is.nan(v)) "NaN" else if (is.infinite(v)) (if (v > 0) "Inf" else "-Inf") else if (v == 0 && 1 / v < 0) "-0.0" else num(v)
PH <- "import math\nimport numpy as np\nimport simlev._r.fmt as fm\nimport simlev._r.stats as st\n"
JH <- "st = SL.RStats\n"
SPEZ <- c(NA, NaN, Inf, -Inf, 0, -0)
werte <- function(n) {
  x <- switch(pick(1:5), rnorm(n), round(rnorm(n, 0, 3)), round(runif(n, -2, 2), 1), exp(rnorm(n, 0, 4)),
              sample(c(-1, 0, 1, 2), n, TRUE))
  if (n > 0 && coin(0.4)) { k <- sample.int(n, max(1L, n %/% 6L)); x[k] <- sample(SPEZ, length(k), TRUE) }
  x
}
LAB <- c("niedrig", "mäßig", "hoch", "名", "€", "x", "y", "z", "w")
TF <- function(b) if (b) "TRUE" else "FALSE"
PB <- function(b) if (b) "True" else "False"
JB <- function(b) if (b) "true" else "false"

for (kk in seq_len(N)) {
  set.seed(seed0 + kk)
  art <- c("c", "c", "c", "s", "m", "m", "o")[kk %% 7 + 1]
  if (art == "c") {
    n <- pick(c(0, 1, 5, 30, 200)); x <- werte(n)
    right <- coin(0.6); il <- coin(0.4)
    if (coin(0.35)) {
      br <- pick(c(2, 3, 5, 10)); if (coin(0.03)) br <- pick(c(1, NA))
      brs <- num(br); brp <- if (is.na(br)) "fm.NA_REAL" else num(br); brj <- if (is.na(br)) "SL.NA" else num(br)
    } else {
      br <- sort(unique(round(runif(pick(c(2, 3, 4, 7)), -3, 3), pick(0:2))))
      if (length(br) < 2) br <- c(-1, 1)
      if (coin(0.15)) br <- c(-Inf, br, Inf)
      if (coin(0.2)) br <- sample(br)
      if (coin(0.03)) br <- c(br, br[1])
      if (n > 0 && coin(0.4)) x[sample.int(n, max(1, n %/% 4))] <- sample(br[is.finite(br)], max(1, n %/% 4), TRUE)
      brs <- sprintf("c(%s)", paste(num(br), collapse = ", ")); brp <- sprintf("[%s]", paste(sapply(br, pv), collapse = ", "))
      brj <- sprintf("[%s]", paste(sapply(br, jv), collapse = ", "))
    }
    nl <- if (length(br) == 1) (if (is.na(br)) 1 else br) else length(br) - 1
    lab <- pick(c("std", "std", "false", "eigen", "bincode"))
    if (lab == "bincode" && length(br) == 1) lab <- "false"
    if (lab == "std") {
      r <- sprintf("cut(x, %s, right = %s, include.lowest = %s)", brs, TF(right), TF(il))
      py <- sprintf("%sresult = st.cut(x, %s, right=%s, include_lowest=%s)", PH, brp, PB(right), PB(il))
      jl <- sprintf("%sresult = st.cut(x, %s; right = %s, include_lowest = %s)", JH, brj, JB(right), JB(il))
    } else if (lab == "false") {
      r <- sprintf("cut(x, %s, labels = FALSE, right = %s, include.lowest = %s)", brs, TF(right), TF(il))
      py <- sprintf("%sresult = st.cut(x, %s, labels=False, right=%s, include_lowest=%s)", PH, brp, PB(right), PB(il))
      jl <- sprintf("%sresult = st.cut(x, %s; labels = false, right = %s, include_lowest = %s)", JH, brj, JB(right), JB(il))
    } else if (lab == "eigen") {
      k <- max(1, nl + if (coin(0.05)) 1 else 0); lb <- rep_len(LAB, k)
      lb <- if (anyDuplicated(lb)) paste0(lb, seq_along(lb)) else lb
      r <- sprintf("cut(x, %s, labels = c(%s), right = %s, include.lowest = %s)", brs, paste0("'", lb, "'", collapse = ", "), TF(right), TF(il))
      py <- sprintf("%sresult = st.cut(x, %s, labels=[%s], right=%s, include_lowest=%s)", PH, brp, paste0("'", lb, "'", collapse = ", "), PB(right), PB(il))
      jl <- sprintf("%sresult = st.cut(x, %s; labels = [%s], right = %s, include_lowest = %s)", JH, brj, paste0("\"", lb, "\"", collapse = ", "), JB(right), JB(il))
    } else {
      bs <- sort(br)
      r <- sprintf(".bincode(x, %s, right = %s, include.lowest = %s)", sprintf("c(%s)", paste(num(bs), collapse = ", ")), TF(right), TF(il))
      py <- sprintf("%simport simlev._r.stats_sort as ss\nresult = ss._bincode(np.atleast_1d(x), [%s], right=%s, include_lowest=%s)", PH, paste(sapply(bs, pv), collapse = ", "), PB(right), PB(il))
      jl <- sprintf("%sresult = SL._rb_bincode(Float64[x...], Float64[%s], %s, %s)\nresult = [c == 0 ? missing : c for c in result]", JH, paste(sapply(bs, jv), collapse = ", "), JB(right), JB(il))
      if (n == 1) jl <- paste0(jl, "\nresult = result[1]")
    }
    fuzz_case(sprintf("c%05d", kk), r = r, py = py, jl = jl, inputs = list(x = x))
  } else if (art == "s") {
    a <- pick(list(runif(1, -10, 10), 0, 1e308, -1e308, 1e-300, 5e-324, round(rnorm(1) * 100)))
    b <- pick(list(runif(1, -10, 10), a, 1.7e308, -1.7e308, 1, 2^53, 0 - a))   # ohne -0: R liefert dort ganze Zahlen
    n <- pick(c(0, 1, 2, 3, 4, 7, 10, 50))
    r <- sprintf("seq.int(%s, %s, length.out = %d)", num(a), num(b), n)
    py <- sprintf("%sresult = st.seq_len_out(%s, %s, %d)", PH, pv(a), pv(b), n)
    jl <- sprintf("%sresult = st.seq_len_out(%s, %s, %d)", JH, jv(a), jv(b), n)
    if (n == 1) jl <- paste0(jl, "\nresult = result[1]")
    fuzz_case(sprintf("s%05d", kk), r = r, py = py, jl = jl, inputs = list())
  } else if (art == "m") {
    n <- pick(c(0, 1, 2, 3, 4, 5, 10, 11, 100, 101)); isint <- coin(0.25)
    x <- if (isint) sample(-5:5, n, TRUE) else werte(n)
    if (!isint && n > 0 && coin(0.3)) x[sample.int(n, max(1, n %/% 2))] <- pick(c(0, -0))
    narm <- coin(0.5)
    if (isint && n > 0 && coin(0.2)) x[sample.int(n, 1)] <- NA_integer_
    r <- sprintf("median(x, na.rm = %s)", TF(narm))
    py <- sprintf("%sresult = st.median(x, na_rm=%s)", PH, PB(narm))
    jl <- sprintf("%sresult = st.median(x; na_rm = %s)", JH, JB(narm))
    fuzz_case(sprintf("m%05d", kk), r = r, py = py, jl = jl, inputs = list(x = x))
  } else {
    n <- pick(c(0, 1, 2, 5, 40)); x <- werte(n)
    nl <- pick(list(NA, TRUE, FALSE)); dec <- coin(0.4)
    nlr <- if (is.na(nl)) "NA" else TF(nl); nlp <- if (is.na(nl)) "None" else PB(nl); nlj <- if (is.na(nl)) "nothing" else JB(nl)
    r <- sprintf("sort(x, decreasing = %s, na.last = %s)", TF(dec), nlr)
    py <- sprintf("%sresult = st.sort(np.atleast_1d(x), decreasing=%s, na_last=%s)", PH, PB(dec), nlp)
    jl <- sprintf("%sresult = st.r_sort(x; decreasing = %s, na_last = %s)", JH, JB(dec), nlj)
    fuzz_case(sprintf("o%05d", kk), r = r, py = py, jl = jl, inputs = list(x = x))
  }
}
ref_done(); ref_schreiben()

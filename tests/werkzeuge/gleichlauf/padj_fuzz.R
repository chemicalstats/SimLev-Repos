# tests/werkzeuge/gleichlauf/padj_fuzz.R – Fuzz von p.adjust und ecdf (seit 1.6.0 in Python und Julia im C-Kern
# core/slc_rbase_models.cpp: sl_r_p_adjust; Julia auch ecdf über sl_r_ecdf)
#
#   LC_ALL=C.UTF-8 R_LIBS=<R-Bibliothek> SIMLEV_FAELLE_DIR=<ordner> Rscript tests/werkzeuge/gleichlauf/padj_fuzz.R <n> <seed>
#
# Erzeugt <n> Fälle im Format der Referenzfälle (tests/gleichlauf/erzeugen/ref_tools.R) als Modul padj_fuzz:
#   - p-Fälle: p.adjust mit allen acht Verfahren (auch abgekürzt), 0 bis 60 Werten mit NA/NaN, Bindungen, 0 und 1,
#     Namen (auch Nicht-ASCII), n größer als die Zahl der Werte; Fehler (n zu klein, unbekanntes Verfahren).
#   - e-Fälle: ecdf(x)(v) mit Bindungen, ±0, ±Inf, NA/NaN in x; Fehler (keine Werte). Seit 1.6.1 nur Julia (nur = "jl").
# Warnungen und Fehler mit ihren Aufrufen (r_calls) wie sim_fuzz.R.
#
# Prüfung (tests/werkzeuge/gleichlauf/run.py, Schritt 5): Referenz aus R 1.5.2 (R_LIBS=/home/claude/rlib152), R neu mit
# tests/werkzeuge/gleichlauf/sim_fuzz_cmp.py, Python und Julia mit vergleich.py/vergleich.jl gegen die Referenz.
source("tests/gleichlauf/erzeugen/ref_tools.R")
args <- commandArgs(TRUE)
N <- as.integer(args[1]); seed0 <- as.integer(if (length(args) >= 2) args[2] else 20261121)
ref_bereich("padj_fuzz", alle = TRUE); ref_init("padj_fuzz")
pick <- function(x) x[[sample.int(length(x), 1L)]]
coin <- function(p) runif(1) < p

fuzz_case <- function(id, r, py, jl, inputs, nur = NULL) {   # nur: seit 1.6.1 (Nachbildung einer Sprache entfallen)
  ref_case(id, r = r, py = py, jl = jl, inputs = inputs, nur = nur)
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
PH <- "import math\nimport numpy as np\nimport simlev._r.stats as st\n"
JH <- "st = SL.RStats\n"
M <- c("holm", "hochberg", "hommel", "bonferroni", "BH", "BY", "fdr", "none", "hom", "BY", "ho", "bonf")
NM <- c("a", "ä", "名", "x1", "β", "z")

for (kk in seq_len(N)) {
  set.seed(seed0 + kk)
  if (kk %% 4 != 0) {
    n <- pick(c(0, 1, 2, 3, 5, 10, 25, 60))
    p <- switch(pick(1:4), runif(n), round(runif(n), 2), runif(n)^4, sample(c(0, 0.01, 0.05, 0.5, 1), n, TRUE))
    if (n > 0 && coin(0.3)) p[sample.int(n, max(1, n %/% 5))] <- pick(c(NA, NaN))
    if (n > 0 && n <= length(NM) && coin(0.2)) names(p) <- NM[seq_len(n)]
    m <- pick(M)
    lp <- sum(!is.na(p))
    # n nur bei mindestens einem Wert: p.adjust(numeric(0), n = 3) liefert in R über p0[TRUE] <- … eine Länge, die die
    # Nachbildungen nicht abbilden (unverändert seit 1.5.2)
    nn <- if (lp > 0 && coin(0.35)) pick(c(lp, lp + 1, lp + 7, 2 * lp + 3, max(0, lp - 1))) else NULL
    nr <- if (is.null(nn)) "" else sprintf(", n = %d", nn)
    np_ <- if (is.null(nn)) "" else sprintf(", n=%d", nn)
    r <- sprintf("p.adjust(p, '%s'%s)", m, nr)
    py <- sprintf("%sresult = st.p_adjust(%s, '%s'%s)", PH, if (n == 1 && is.null(names(p))) "np.atleast_1d(p)" else "p", m, np_)
    jl <- sprintf("%sresult = st.p_adjust(%s, \"%s\"%s)", JH, if (n == 1 && is.null(names(p))) "[p]" else "p", m, if (is.null(nn)) "" else sprintf("; n = %d", nn))
    fuzz_case(sprintf("p%05d", kk), r = r, py = py, jl = jl, inputs = list(p = p))
  } else {
    n <- pick(c(0, 1, 2, 5, 20, 100))
    x <- switch(pick(1:3), rnorm(n), round(rnorm(n)), sample(c(-1, 0, -0, 1, 2), n, TRUE))
    if (n > 0 && coin(0.3)) x[sample.int(n, max(1, n %/% 5))] <- pick(c(NA, NaN, Inf, -Inf))
    v <- c(-Inf, -2, -1, -0.5, -0, 0, 0.3, 1, 1.5, 2, Inf, NA)
    r <- "ecdf(x)(v)"
    jl <- sprintf("%sresult = st.ecdf(%s)(v)", JH, if (n == 1) "[x]" else "x")
    # ecdf nur noch in Julia (Python-Nachbildung seit 1.6.1 ohne Aufrufer entfallen)
    fuzz_case(sprintf("e%05d", kk), r = r, py = NULL, jl = jl, inputs = list(x = x, v = v), nur = "jl")
  }
}
ref_done(); ref_schreiben()

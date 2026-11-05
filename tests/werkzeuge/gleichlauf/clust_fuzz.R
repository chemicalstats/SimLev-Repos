# tests/werkzeuge/gleichlauf/clust_fuzz.R – Fuzz von dist und hclust (seit 1.6.0 in Python und Julia im C-Kern
# core/slc_rbase_clust.cpp: sl_r_dist, sl_r_hclust; bis 1.5.2 je eine Nachbildung in python/simlev/_r/stats_cluster.py
# und julia/src/r/stats_cluster.jl)
#
#   LC_ALL=C.UTF-8 R_LIBS=<R-Bibliothek> SIMLEV_FAELLE_DIR=<ordner> Rscript tests/werkzeuge/gleichlauf/clust_fuzz.R <n> <seed>
#
# Erzeugt <n> Fälle im Format der Referenzfälle (tests/gleichlauf/erzeugen/ref_tools.R) als Modul clust_fuzz:
#   - d-Fälle: stats::dist mit allen sechs Methoden (Abkürzungen, "euclidian"), p für minkowski (auch ungültig),
#     0 bis 40 Zeilen und 1 bis 7 Spalten, Werte mit NA, NaN, ±Inf, ±0, Bindungen, Zeilennamen mit Nicht-ASCII
#     (as.matrix), Fehler (unbekannte Methode).
#   - h-Fälle: stats::hclust mit allen acht Verfahren über dist bzw. as.dist, 1 bis 120 Objekte, viele Bindungen
#     (gerundete Daten, gleiche Abstände), Gewichte (members), Fehler (n < 2, Länge von members, Methode).
# Warnungen und Fehler mit ihren Aufrufen (r_calls) wie sim_fuzz.R.
#
# Prüfung (tests/werkzeuge/gleichlauf/run.py, Schritt 5): Referenz aus R 1.5.2 (R_LIBS=/home/claude/rlib152), R neu mit
# tests/werkzeuge/gleichlauf/sim_fuzz_cmp.py, Python und Julia mit vergleich.py/vergleich.jl gegen die Referenz.
source("tests/gleichlauf/erzeugen/ref_tools.R")
args <- commandArgs(TRUE)
N <- as.integer(args[1]); seed0 <- as.integer(if (length(args) >= 2) args[2] else 20261118)
ref_bereich("clust_fuzz", alle = TRUE); ref_init("clust_fuzz")
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
pnum <- function(v) if (is.infinite(v)) (if (v > 0) "math.inf" else "-math.inf") else num(v)   # Python
PH <- "import math\nimport numpy as np\nimport simlev._r.stats as st\n"
JH <- "st = SL.RStats\n"
SPEZ <- c(NA, NaN, Inf, -Inf, 0, -0, 1e-310, 1e300)
DM <- c("euclidean", "maximum", "manhattan", "canberra", "binary", "minkowski", "euc", "max", "can", "bin", "mink",
        "euclidian", "man")
HM <- c("ward.D", "single", "complete", "average", "mcquitty", "median", "centroid", "ward.D2", "ave", "cen", "ward.D2")
LAB <- c("a", "ä", "Ölfonds", "名", "x y", "β", "z", "€uro")

mat <- function(n, k) {
  X <- switch(pick(1:5), matrix(rnorm(n * k), n, k), matrix(round(rnorm(n * k)), n, k),
              matrix(sample(0:1, n * k, TRUE), n, k), matrix(round(runif(n * k, -3, 3), 1), n, k),
              matrix(exp(rnorm(n * k, 0, 5)), n, k))
  if (n * k > 0 && coin(0.4)) { i <- sample.int(n * k, max(1L, (n * k) %/% 8L)); X[i] <- sample(SPEZ, length(i), TRUE) }
  X
}

nd <- round(N * 0.45)
for (kk in seq_len(N)) {
  set.seed(seed0 + kk)
  if (kk <= nd) {
    n <- pick(c(0, 1, 2, 3, 5, 8, 20, 40)); k <- pick(c(1, 2, 3, 7))
    X <- mat(n, k)
    m <- pick(DM); p <- pick(c(2, 3, 1, 0.5, 1.5))
    if (coin(0.03)) m <- pick(c("foo", "m"))
    if (m %in% c("minkowski", "mink") && coin(0.08)) p <- pick(c(0, -1, Inf))
    lab <- n > 0 && n <= length(LAB) && coin(0.3)
    if (lab) rownames(X) <- LAB[seq_len(n)]
    if (lab && coin(0.7)) {
      r <- sprintf("as.matrix(dist(X, method = '%s', p = %s))", m, num(p))
      py <- sprintf("%sresult = st.dist_as_matrix(st.dist(X, method='%s', p=%s))", PH, m, pnum(p))
      jl <- sprintf("%sresult = st.dist_as_matrix(st.dist(X; method = \"%s\", p = %s))", JH, m, num(p))
    } else {
      r <- sprintf("as.vector(dist(X, method = '%s', p = %s))", m, num(p))
      py <- sprintf("%sresult = np.asarray(st.dist(X, method='%s', p=%s))", PH, m, pnum(p))
      jl <- sprintf("%sresult = st.dist(X; method = \"%s\", p = %s)", JH, m, num(p))
    }
    fuzz_case(sprintf("d%05d", kk), r = r, py = py, jl = jl, inputs = list(X = X))
  } else {
    n <- pick(c(1, 2, 3, 4, 6, 10, 25, 60, 120)); k <- pick(c(1, 2, 4))
    X <- switch(pick(1:4), matrix(rnorm(n * k), n, k), matrix(round(rnorm(n * k)), n, k),
                matrix(sample(0:2, n * k, TRUE), n, k), matrix(round(runif(n * k, 0, 10)), n, k))
    m <- pick(HM); dm <- pick(c("euclidean", "manhattan", "maximum"))
    if (coin(0.03)) m <- pick(c("foo", "c"))
    mem <- if (coin(0.2)) sample(1:4, n, TRUE) else NULL
    if (!is.null(mem) && coin(0.05)) mem <- mem[-1]
    asd <- coin(0.2)
    rd <- if (asd) "as.dist(as.matrix(dist(X, '%s')))" else "dist(X, '%s')"
    pd <- if (asd) "st.as_dist(st.dist_as_matrix(st.dist(X, method='%s')).to_numpy())" else "st.dist(X, method='%s')"
    jd <- if (asd) "st.as_dist(st.dist_as_matrix(st.dist(X; method = \"%s\")))" else "st.dist(X; method = \"%s\")"
    mr <- if (is.null(mem)) "" else sprintf(", members = c(%s)", paste(mem, collapse = ", "))
    mp <- if (is.null(mem)) "" else sprintf(", members=[%s]", paste(mem, collapse = ", "))
    mj <- if (is.null(mem)) "" else sprintf("; members = [%s]", paste(mem, collapse = ", "))
    r <- sprintf("h <- hclust(%s, method = '%s'%s); h[c('merge', 'height', 'order')]", sprintf(rd, dm), m, mr)
    py <- sprintf("%sresult = st.hclust(%s, method='%s'%s)", PH, sprintf(pd, dm), m, mp)
    jl <- sprintf("%sresult = st.hclust(%s, \"%s\"%s)", JH, sprintf(jd, dm), m, mj)
    fuzz_case(sprintf("h%05d", kk), r = r, py = py, jl = jl, inputs = list(X = X))
  }
}
ref_done(); ref_schreiben()

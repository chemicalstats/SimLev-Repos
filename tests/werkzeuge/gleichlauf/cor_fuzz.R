# tests/werkzeuge/gleichlauf/cor_fuzz.R – Fuzz von cor/cov (alle use, pearson/kendall/spearman), cov2cor und scale
# (seit 1.6.0 in Python und Julia im C-Kern core/slc_rbase_cor.cpp: sl_r_cor, sl_r_cov2cor, sl_r_scale; pearson und
# kendall über sl_r_cov in core/slc_rbase_cov.cpp)
#
#   LC_ALL=C.UTF-8 R_LIBS=<R-Bibliothek> SIMLEV_FAELLE_DIR=<ordner> Rscript tests/werkzeuge/gleichlauf/cor_fuzz.R <n> <seed>
#
# Erzeugt <n> Fälle im Format der Referenzfälle (tests/gleichlauf/erzeugen/ref_tools.R) als Modul cor_fuzz:
#   - k-Fälle: cor und cov mit Matrix x (0 bis 60 Zeilen, 1 bis 5 Spalten, Spaltennamen auch mit Nicht-ASCII) oder
#     Vektoren x und y, y als Vektor oder Matrix; use in allen fünf Formen (auch abgekürzt), alle drei Verfahren;
#     NA- und NaN-Muster, Bindungen, ±Inf, konstante Spalten (Warnung), eine Zeile; Fehler (fehlende Werte bei all.obs,
#     keine vollständigen Paare, paarweise ohne cor, ungültiges use).
#   - v-Fälle: cov2cor mit NA, nicht positiver Diagonale (Warnung), 0 bis 5 Spalten.
#   - s-Fälle: scale mit center/scale TRUE/FALSE oder Vektoren, NA, eine Zeile; Fehler (falsche Länge).
# Warnungen und Fehler mit ihren Aufrufen (r_calls) wie sim_fuzz.R.
#
# Prüfung (tests/werkzeuge/gleichlauf/run.py, Schritt 5): abgelegte Referenz (seit 1.6.2 aus R 1.6.2, run.py --ref-erzeugen 162), R neu mit
# tests/werkzeuge/gleichlauf/sim_fuzz_cmp.py, Python und Julia mit vergleich.py/vergleich.jl gegen die Referenz.
source("tests/gleichlauf/erzeugen/ref_tools.R")
args <- commandArgs(TRUE)
N <- as.integer(args[1]); seed0 <- as.integer(if (length(args) >= 2) args[2] else 20261120)
ref_bereich("cor_fuzz", alle = TRUE); ref_init("cor_fuzz")

num <- function(v) sprintf("%.17g", v)
PH <- "import math\nimport numpy as np\nimport simlev._r.fmt as fm\nimport simlev._r.stats as st\n"
JH <- "st = SL.RStats\n"
USE <- c("everything", "all.obs", "complete.obs", "pairwise.complete.obs", "na.or.complete", "pair", "complete",
         "na", "every", "all")
SPEZ <- c(NA, NaN, Inf, -Inf, 0, -0)
CN <- c("a", "ä", "Öl", "名", "b")
mat <- function(n, k) {
  X <- switch(pick(1:4), matrix(rnorm(n * k), n, k), matrix(round(rnorm(n * k)), n, k),
              matrix(sample(1:3, n * k, TRUE), n, k), matrix(round(runif(n * k, 0, 5), 1), n, k))
  if (n * k > 0 && coin(0.15)) X[, sample.int(k, 1)] <- pick(c(1, 0))
  if (n * k > 0 && coin(0.45)) { i <- sample.int(n * k, max(1L, (n * k) %/% 7L)); X[i] <- sample(SPEZ[if (coin(0.8)) 1:2 else 1:6], length(i), TRUE) }
  X
}
TF <- function(b) if (b) "TRUE" else "FALSE"
PB <- function(b) if (b) "True" else "False"
JB <- function(b) if (b) "true" else "false"

for (kk in seq_len(N)) {
  set.seed(seed0 + kk)
  art <- c("k", "k", "k", "k", "k", "v", "s")[kk %% 7 + 1]
  if (art == "k") {
    n <- pick(c(0, 1, 2, 3, 5, 12, 60)); k <- pick(c(1, 2, 3, 5))
    meth <- pick(c("pearson", "kendall", "spearman")); use <- pick(USE); f <- pick(c("cor", "cor", "cov"))
    if (coin(0.02)) use <- pick(c("foo", "c"))
    form <- pick(c("mat", "mat", "xy", "xmat_y", "xy_mat"))
    X <- mat(n, k)
    if (form == "mat" && coin(0.3)) colnames(X) <- CN[seq_len(k)]
    inp <- list(X = X); yr <- ""; yp <- ""; yj <- ""
    xr <- "X"; xp <- "X"; xj <- "X"
    if (form == "xy") { inp <- list(x = X[, 1], y = mat(n, 1)[, 1]); xr <- xp <- xj <- "x"; yr <- ", y"; yp <- ", y"; yj <- ", y" }
    if (form == "xmat_y") { inp$y <- mat(n, 1)[, 1]; yr <- ", y"; yp <- ", y"; yj <- ", y" }
    if (form == "xy_mat") { inp <- list(x = X[, 1], Y = mat(n, pick(c(1, 2, 3)))); xr <- xp <- xj <- "x"; yr <- ", Y"; yp <- ", Y"; yj <- ", Y" }
    if (n == 1 && form %in% c("xy", "xy_mat")) { xp <- "np.atleast_1d(x)"; xj <- "[x]" }
    if (n == 1 && form %in% c("xy", "xmat_y")) { yp <- ", np.atleast_1d(y)"; yj <- ", [y]" }
    # kendall mit NA bei use = everything/all.obs: R 4.3.3 liest in cov.c einen nicht gesetzten Wert und warnt zufällig
    # "the standard deviation is zero" (Q34) -> dort complete.obs
    if (meth == "kendall" && use %in% c("everything", "all.obs", "every", "all") && anyNA(unlist(inp))) use <- "complete.obs"
    r <- sprintf("%s(%s%s, use = '%s', method = '%s')", f, xr, yr, use, meth)
    py <- sprintf("%sresult = st.%s(%s%s, use='%s', method='%s')", PH, f, xp, yp, use, meth)
    jl <- sprintf("%sresult = st.%s(%s%s; use = \"%s\", method = \"%s\")", JH, f, xj, yj, use, meth)
    fuzz_case(sprintf("k%05d", kk), r = r, py = py, jl = jl, inputs = inp)
  } else if (art == "v") {
    p <- pick(c(1, 2, 3, 5)); A <- matrix(rnorm(p * 20), 20, p); V <- cov(A)
    if (coin(0.3)) V[sample.int(p * p, 1)] <- pick(c(NA, NaN))
    if (coin(0.25)) { i <- sample.int(p, 1); V[i, i] <- pick(c(0, -1, NA, Inf)) }
    fuzz_case(sprintf("v%05d", kk), r = "cov2cor(V)", py = paste0(PH, "result = st.cov2cor(V)"),
              jl = paste0(JH, "result = st.cov2cor(V)"), inputs = list(V = V))
  } else {
    n <- pick(c(1, 2, 5, 30)); k <- pick(c(1, 2, 4)); X <- mat(n, k)
    cm <- pick(c("TRUE", "FALSE", "vec")); sm <- pick(c("TRUE", "FALSE", "vec"))
    cv <- round(rnorm(k + if (coin(0.04)) 1 else 0), 2); sv <- round(runif(k + if (coin(0.04)) 1 else 0, 0.5, 2), 2)
    vr <- function(v) sprintf("c(%s)", paste(num(v), collapse = ", ")); vp <- function(v) sprintf("[%s]", paste(num(v), collapse = ", "))
    cr <- if (cm == "vec") vr(cv) else cm; sr <- if (sm == "vec") vr(sv) else sm
    cp <- if (cm == "vec") vp(cv) else PB(cm == "TRUE"); sp <- if (sm == "vec") vp(sv) else PB(sm == "TRUE")
    cj <- if (cm == "vec") vp(cv) else JB(cm == "TRUE"); sj <- if (sm == "vec") vp(sv) else JB(sm == "TRUE")
    r <- sprintf("s <- scale(X, center = %s, scale = %s); list(as.vector(s), attr(s, 'scaled:center'), attr(s, 'scaled:scale'))", cr, sr)
    py <- sprintf("%ss = st.scale(X, center=%s, scale=%s)\nresult = [np.asarray(s).ravel(order='F'), s.scaled_center, s.scaled_scale]", PH, cp, sp)
    jl <- sprintf("%ss = st.scale(X; center = %s, scale = %s)\nresult = [vec(s.data), get(s.attrs, \"scaled:center\", nothing), get(s.attrs, \"scaled:scale\", nothing)]", JH, cj, sj)
    fuzz_case(sprintf("s%05d", kk), r = r, py = py, jl = jl, inputs = list(X = X))
  }
}
ref_done(); ref_schreiben()

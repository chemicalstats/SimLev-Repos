# Referenzfälle für simlev._r.nmath (bitgleiche Ports der R-nmath-Funktionen).
#
# Aufruf aus der Repo-Wurzel:
#   LC_ALL=C.UTF-8 R_LIBS=<R-Bibliothek mit SimLev> Rscript golden/modules/gen_r_nmath.R
#
# Je Funktion einige tausend Werte über breite Wertebereiche (zufällig und
# gezielt: 0, 1, +-Inf, NA, NaN, Tails bis 1e-300, log.p, lower.tail = FALSE,
# df in {0.1, 0.5, 1, 1.5, 2, 3, 4.5, 10, 30, 100, 1e5, 1e10, Inf}, kleine
# und große Formparameter), gebündelt zu wenigen Fällen (alle vier
# Kombinationen von lower.tail/log.p in einem Fall). Dazu Fälle für
# Skalar/Recycling/Matrix/Namen und die Warnpfade.
#
# Die internen Hilfen (stirlerr, bd0, ebd0, lgammacor, chebyshev_eval,
# log1pmx, lgamma1p, logspace_add, dpois_raw) sind in R nicht aufrufbar; sie
# werden über ein kleines C-Modul geprüft, das beim Erzeugen übersetzt wird
# (exportierte Rf_*-Funktionen direkt aus libR, die versteckten aus den
# R-4.3.3-Quellen, Verzeichnis src/nmath; Pfad per Umgebungsvariable `SIMLEV_R_NMATH_SRC`). Fehlt der Compiler oder
# die Quelle, entfallen nur diese Fälle.
source("golden/modules/ref_tools.R")
# Ohne die R-Quellen fielen die helper_*-Fälle weg (ref_init() leert den Ordner):
# dann abbrechen, außer SIMLEV_ALLOW_PARTIAL=1 ist gesetzt.
if (!file.exists(file.path(Sys.getenv("SIMLEV_R_NMATH_SRC", ""), "stirlerr.c")) &&
    Sys.getenv("SIMLEV_ALLOW_PARTIAL") != "1")
  stop("SIMLEV_R_NMATH_SRC muss auf src/nmath der R-4.3.3-Quellen zeigen (sonst entfallen die helper_*-F\u00e4lle; ",
       "mit SIMLEV_ALLOW_PARTIAL=1 trotzdem erzeugen).")
ref_init("r_nmath")

PY <- "import simlev._r.nmath as nm\n"
JL <- "N = SL.RNmath\n"
# Julia: Pflichtargumente positional, "name = wert" als Schlüsselwort
jlcall <- function(fn, a, extra = character(0)) {
  pos <- a[!grepl("=", a)]; kw <- c(a[grepl("=", a)], extra)
  sprintf("N.%s(%s%s)", fn, paste(pos, collapse = ", "),
          if (length(kw)) paste0("; ", paste(kw, collapse = ", ")) else "")
}

# ── Eingabegeneratoren ─────────────────────────────────────────────────────
mixn <- function(n, k) sample(rep_len(seq_len(k), n))
SPECIAL <- c(0, 1, -1, Inf, -Inf, NA, NaN, 0.5, 2, 1e-300, 1e300, 5e-324, 1e-10, 1 - 1e-16, 1e-16)
xs <- function(n) {
  k <- mixn(n, 5); x <- numeric(n)
  x[k == 1] <- rnorm(sum(k == 1), 0, 3)
  x[k == 2] <- runif(sum(k == 2), -40, 40)
  s <- sum(k == 3); x[k == 3] <- sample(c(-1, 1), s, TRUE) * 10^runif(s, -20, 20)
  s <- sum(k == 4); x[k == 4] <- sample(c(-1, 1), s, TRUE) * 10^runif(s, -300, 300)
  x[k == 5] <- round(runif(sum(k == 5), -60, 60) * 4) / 4
  x[seq_along(SPECIAL)] <- SPECIAL
  x
}
probs <- function(n) {
  k <- mixn(n, 4); p <- numeric(n)
  p[k == 1] <- runif(sum(k == 1))
  p[k == 2] <- 10^runif(sum(k == 2), -320, 0)
  p[k == 3] <- 1 - 10^runif(sum(k == 3), -17, 0)
  p[k == 4] <- 10^runif(sum(k == 4), -20, 0)
  p[1:8] <- c(0, 1, 0.5, NA, -0.1, 1.1, 1e-300, 1 - 2^-53)
  p
}
logprobs <- function(n) {
  k <- mixn(n, 3); p <- numeric(n)
  p[k == 1] <- -10^runif(sum(k == 1), -20, 5)
  p[k == 2] <- -runif(sum(k == 2), 0, 50)
  p[k == 3] <- -10^runif(sum(k == 3), -300, 300)
  p[1:6] <- c(0, -Inf, 0.1, NaN, -1e-300, -745.2)
  p
}
DFS <- c(0.1, 0.5, 1, 1.5, 2, 3, 4.5, 10, 30, 100, 1e5, 1e10, Inf)
dfs <- function(n, min_df = 0) {
  k <- mixn(n, 4); d <- numeric(n)
  d[k == 1] <- sample(DFS[DFS >= min_df], sum(k == 1), TRUE)
  d[k == 2] <- runif(sum(k == 2), min_df, 10)
  d[k == 3] <- 10^runif(sum(k == 3), log10(max(min_df, 1e-3)), 12)
  d[k == 4] <- round(runif(sum(k == 4), max(0.5, min_df), 200) * 2) / 2
  d
}
SHAPES <- c(0, 1e-300, 1e-12, 1e-5, 0.01, 0.1, 0.5, 1, 1.5, 2, 5, 10, 15, 40, 100, 1e3, 1e5, 1e8, 1e15, Inf)
shapes <- function(n) {
  k <- mixn(n, 4); a <- numeric(n)
  a[k == 1] <- sample(SHAPES, sum(k == 1), TRUE)
  a[k == 2] <- runif(sum(k == 2), 0, 3)
  a[k == 3] <- 10^runif(sum(k == 3), -8, 8)
  a[k == 4] <- runif(sum(k == 4), 0, 200)
  a
}
TINY <- c(1e-320, 1e-300, 1e-200, 1e-30, 1e-20, 1e-18, 1e-16, 1e-15, 3e-16, 1e-14, 1e-10, 1e-5)
ODD_DF <- c(2 + 1e-13, 2 - 1e-13, 2 + 2e-12, 1 + 1e-13, 1 - 1e-13, 0.999, 1e-5, 1e-300, 1e-10,
            1e20, 2e20, 1e300, 0.01, 0.2, 1.0000001)

# ── Fallbauer ──────────────────────────────────────────────────────────────
LT <- list(c(TRUE, FALSE), c(TRUE, TRUE), c(FALSE, FALSE), c(FALSE, TRUE))
lgl <- function(b) if (b) "TRUE" else "FALSE"
pyb <- function(b) if (b) "True" else "False"
jlb <- function(b) if (b) "true" else "false"

# Verteilungs-/Quantilfunktion in allen vier lower.tail/log.p-Varianten.
# args: Namen der Eingaben; für Quantilfunktionen ist das erste Argument bei
# log.p = TRUE `lp` statt `p`.
pq_case <- function(id, fn, args, inputs, quantile = FALSE, note = NULL) {
  r <- character(0); py <- character(0); jl <- character(0)
  for (v in LT) {
    a <- args
    if (quantile && v[2]) a[1] <- "lp"
    r <- c(r, sprintf("%s(%s, lower.tail = %s, log.p = %s)", fn, paste(a, collapse = ", "), lgl(v[1]), lgl(v[2])))
    py <- c(py, sprintf("nm.%s(%s, lower_tail=%s, log_p=%s)", fn, paste(a, collapse = ", "), pyb(v[1]), pyb(v[2])))
    jl <- c(jl, jlcall(fn, a, c(sprintf("lower_tail = %s", jlb(v[1])), sprintf("log_p = %s", jlb(v[2])))))
  }
  ref_case(id, r = sprintf("list(%s)", paste(r, collapse = ",\n     ")),
           py = sprintf("%sresult = [%s]", PY, paste(py, collapse = ",\n          ")),
           inputs = inputs, note = note,
           jl = sprintf("%sresult = Any[%s]", JL, paste(jl, collapse = ",\n          ")))
}
d_case <- function(id, fn, args, inputs, note = NULL) {
  r <- sprintf("list(%s(%s, log = FALSE), %s(%s, log = TRUE))", fn, paste(args, collapse = ", "),
               fn, paste(args, collapse = ", "))
  py <- sprintf("%sresult = [nm.%s(%s, log=False), nm.%s(%s, log=True)]", PY, fn,
                paste(args, collapse = ", "), fn, paste(args, collapse = ", "))
  jl <- sprintf("%sresult = Any[%s, %s]", JL, jlcall(fn, args, "log = false"), jlcall(fn, args, "log = true"))
  ref_case(id, r = r, py = py, inputs = inputs, note = note, jl = jl)
}
s_case <- function(id, r, py, inputs = list(), note = NULL, jl = NULL)
  ref_case(id, r = r, py = paste0(PY, py), inputs = inputs, note = note,
           jl = if (!is.null(jl)) paste0(JL, jl))

set.seed(20240229)
N <- 1500

# ── Normalverteilung ───────────────────────────────────────────────────────
pq_case("pnorm_wide", "pnorm", "x", list(x = xs(N)))
pq_case("pnorm_far", "pnorm", "x", list(x = sample(c(-1, 1), N, TRUE) * 10^runif(N, -1, 200)))
pq_case("pnorm_musd", "pnorm", c("x", "m", "s"), list(x = xs(N), m = xs(N), s = abs(xs(N))))
pq_case("qnorm_wide", "qnorm", "p", list(p = probs(N), lp = logprobs(N)), quantile = TRUE)
pq_case("qnorm_tails", "qnorm", "p", list(p = 10^runif(N, -323, -1), lp = -10^runif(N, -1, 309)), quantile = TRUE)
pq_case("qnorm_musd", "qnorm", c("p", "m", "s"), list(p = probs(N), lp = logprobs(N), m = xs(N), s = abs(xs(N))),
        quantile = TRUE)
d_case("dnorm_wide", "dnorm", "x", list(x = c(xs(N), runif(N, -45, 45))))
d_case("dnorm_musd", "dnorm", c("x", "m", "s"), list(x = xs(N), m = xs(N), s = abs(xs(N))))

# ── t-Verteilung ───────────────────────────────────────────────────────────
pq_case("pt_wide", "pt", c("x", "df"), list(x = xs(N), df = dfs(N)))
pq_case("pt_dfgrid", "pt", c("x", "df"), list(x = xs(N), df = sample(c(DFS, ODD_DF), N, TRUE)))
pq_case("pt_bigx", "pt", c("x", "df"), list(x = sample(c(-1, 1), N, TRUE) * 10^runif(N, 1, 300), df = dfs(N)))
pq_case("qt_wide", "qt", c("p", "df"), list(p = probs(N), lp = logprobs(N), df = dfs(N, min_df = 1)), quantile = TRUE)
pq_case("qt_dfgrid", "qt", c("p", "df"), list(p = probs(N), lp = logprobs(N), df = sample(c(DFS[DFS >= 1], ODD_DF[ODD_DF >= 1]), N, TRUE)),
        quantile = TRUE)
pq_case("qt_dflt1", "qt", c("p", "df"),       # df < 1: Bisektion (langsam in Python) -> wenige Werte
        list(p = probs(120), lp = logprobs(120), df = sample(c(0.1, 0.5, 0.999, 1e-5, 0.01, 0.2, runif(5)), 120, TRUE)),
        quantile = TRUE)
d_case("dt_wide", "dt", c("x", "df"), list(x = xs(2 * N), df = c(dfs(N), sample(c(DFS, ODD_DF), N, TRUE))))

# ── Beta ───────────────────────────────────────────────────────────────────
pq_case("pbeta_wide", "pbeta", c("x", "a", "b"),
        list(x = runif(N)^sample(c(1, 5, 50), N, TRUE), a = shapes(N), b = shapes(N)))
pq_case("pbeta_tiny", "pbeta", c("x", "a", "b"),
        list(x = probs(N), a = c(sample(TINY, N / 2, TRUE), shapes(N / 2)), b = c(shapes(N / 2), sample(TINY, N / 2, TRUE))))
pq_case("pbeta_large", "pbeta", c("x", "a", "b"),
        list(x = c(runif(N / 2), 1 - probs(N / 2)), a = 10^runif(N, -3, 7), b = 10^runif(N, -3, 7)))
s_case("lbeta_wide", "list(lbeta(a, b), lbeta(a2, b2))", "result = [nm.lbeta(a, b), nm.lbeta(a2, b2)]",
       list(a = shapes(2 * N), b = shapes(2 * N), a2 = 10^runif(N, -320, 300), b2 = 10^runif(N, -320, 300)),
       jl = r"---(result = Any[N.lbeta(a, b), N.lbeta(a2, b2)])---")
s_case("beta_wide", "list(beta(a, b), beta(a2, b2))", "result = [nm.beta(a, b), nm.beta(a2, b2)]",
       list(a = shapes(2 * N), b = shapes(2 * N), a2 = 10^runif(N, -320, 4), b2 = 10^runif(N, -320, 4)),
       jl = r"---(result = Any[N.beta(a, b), N.beta(a2, b2)])---")

# ── gamma / lgamma ─────────────────────────────────────────────────────────
negx <- -runif(N, 0, 180); negx[1:500] <- round(negx[1:500]) + sample(c(1e-12, -1e-12, 1e-8, 1e-15), 500, TRUE)
posx <- c(10^runif(N / 2, -320, 308), round(runif(N / 2, 0, 60) * 2) / 2)
s_case("lgamma_wide", "list(lgamma(x), lgamma(negx), lgamma(posx))",
       "result = [nm.lgamma(x), nm.lgamma(negx), nm.lgamma(posx)]", list(x = xs(N), negx = negx, posx = posx),
       jl = r"---(result = Any[N.lgamma(x), N.lgamma(negx), N.lgamma(posx)])---")
s_case("gamma_wide", "list(gamma(x), gamma(negx), gamma(posx))",
       "result = [nm.gamma(x), nm.gamma(negx), nm.gamma(posx)]",
       list(x = xs(N), negx = negx, posx = c(10^runif(N / 2, -320, 3), round(runif(N / 2, 0, 60) * 2) / 2)),
       jl = r"---(result = Any[N.gamma(x), N.gamma(negx), N.gamma(posx)])---")

# ── Logistische Verteilung ─────────────────────────────────────────────────
pq_case("plogis_wide", "plogis", c("x", "m", "s"), list(x = xs(N), m = c(rep(0, N / 2), xs(N / 2)), s = c(rep(1, N / 2), abs(xs(N / 2)))))
pq_case("qlogis_wide", "qlogis", c("p", "m", "s"), list(p = probs(N), lp = logprobs(N), m = c(rep(0, N / 2), xs(N / 2)),
                                                       s = c(rep(1, N / 2), abs(xs(N / 2)))), quantile = TRUE)
d_case("dlogis_wide", "dlogis", c("x", "m", "s"), list(x = xs(N), m = c(rep(0, N / 2), xs(N / 2)), s = c(rep(1, N / 2), abs(xs(N / 2)))))

# ── Chi-Quadrat, Gamma, F ──────────────────────────────────────────────────
pq_case("pchisq_wide", "pchisq", c("x", "df"), list(x = abs(xs(N)), df = dfs(N)))
pq_case("qchisq_wide", "qchisq", c("p", "df"), list(p = probs(N), lp = logprobs(N), df = dfs(N)), quantile = TRUE)
pq_case("pgamma_wide", "pgamma", c("x", "a"), list(x = abs(xs(N)), a = shapes(N)))
sh <- 10^runif(N, -3, 8)
pq_case("pgamma_near", "pgamma", c("x", "a"), list(x = sh * (1 + rnorm(N) / sqrt(sh)), a = sh))
pq_case("pgamma_scale", "pgamma", c("x", "a", "scale = s"), list(x = abs(xs(N)), a = shapes(N), s = 10^runif(N, -5, 5)))
pq_case("qgamma_wide", "qgamma", c("p", "a"), list(p = probs(N), lp = logprobs(N), a = c(sample(TINY, N / 4, TRUE), shapes(3 * N / 4))),
        quantile = TRUE)
pq_case("qgamma_rate", "qgamma", c("p", "a", "rate = r"), list(p = probs(N), lp = logprobs(N), a = shapes(N), r = 10^runif(N, -5, 5)),
        quantile = TRUE)
d_case("dgamma_wide", "dgamma", c("x", "a"), list(x = c(abs(xs(N)), 10^runif(N, -300, 300)), a = c(shapes(N), 10^runif(N, -12, 12))))
d_case("dchisq_wide", "dchisq", c("x", "df"), list(x = abs(xs(N)), df = dfs(N)))
pq_case("pf_wide", "pf", c("x", "df1", "df2"), list(x = abs(xs(N)), df1 = dfs(N), df2 = dfs(N)))
pq_case("pf_grid", "pf", c("x", "df1", "df2"),
        list(x = 10^runif(500, -10, 10), df1 = sample(c(DFS, 1e-3, 1e8, 1e15), 500, TRUE),   # große df: bpser bis 1e7 Schritte
             df2 = sample(c(DFS, 1e-3, 1e8, 1e15), 500, TRUE)))
d_case("dpois_wide", "dpois", c("x", "lam"),
       list(x = c(round(10^runif(N, -1, 6)), 0:20, 1e15, 1e300), lam = c(10^runif(N, -300, 7), rep(3.5, 21), 1e15, 1e300)))

# ── Form, Recycling, Randfälle, Warnungen ─────────────────────────────────
s_case("shape_scalar", "c(pnorm(1.96), qnorm(0.975), qt(0.975, 3), pt(-2, 4.5), lgamma(0.5), gamma(5), beta(2, 3), lbeta(2, 3), qchisq(0.95, 1), pchisq(3.84, 1), pf(4, 3, 10), qgamma(0.5, 2, 3), plogis(1), qlogis(0.3), dlogis(0.2), dt(1, 2), dnorm(0))",
       "result = [nm.pnorm(1.96), nm.qnorm(0.975), nm.qt(0.975, 3), nm.pt(-2, 4.5), nm.lgamma(0.5), nm.gamma(5), nm.beta(2, 3), nm.lbeta(2, 3), nm.qchisq(0.95, 1), nm.pchisq(3.84, 1), nm.pf(4, 3, 10), nm.qgamma(0.5, 2, 3), nm.plogis(1), nm.qlogis(0.3), nm.dlogis(0.2), nm.dt(1, 2), nm.dnorm(0)]",
       jl = r"---(result = [N.pnorm(1.96), N.qnorm(0.975), N.qt(0.975, 3), N.pt(-2, 4.5), N.lgamma(0.5), N.gamma(5), N.beta(2, 3), N.lbeta(2, 3), N.qchisq(0.95, 1), N.pchisq(3.84, 1), N.pf(4, 3, 10), N.qgamma(0.5, 2, 3), N.plogis(1), N.qlogis(0.3), N.dlogis(0.2), N.dt(1, 2), N.dnorm(0)])---")
s_case("shape_recycle", "list(qt(p, c(1.5, 3, 30)), pnorm(c(-1, 0, 1), c(0, 1), 2), pbeta(0.3, a, 2), dt(x, df = 4), pgamma(1:6, shape = c(0.5, 2)))",
       "result = [nm.qt(p, np.array([1.5, 3, 30])), nm.pnorm(np.array([-1., 0, 1]), np.array([0., 1]), 2), nm.pbeta(0.3, a, 2), nm.dt(x, df=4), nm.pgamma(np.arange(1, 7), shape=np.array([0.5, 2]))]",
       list(p = c(0.01, 0.2, 0.5, 0.9, 0.999, 0.75), a = c(0.5, 1, 2, 10), x = c(-3, 0, 2.5)),
       jl = r"---(result = Any[N.qt(p, [1.5, 3, 30]), N.pnorm([-1.0, 0, 1], [0.0, 1], 2), N.pbeta(0.3, a, 2), N.dt(x, 4), N.pgamma(1:6, [0.5, 2])])---")
s_case("shape_matrix", "qt(U, 4)", "result = nm.qt(U, 4)", list(U = matrix(c(0.1, 0.5, 0.9, 0.2, 0.7, 0.99), 3, 2)),
       jl = r"---(result = N.qt(U, 4))---")
s_case("shape_names", "pnorm(z)", "result = nm.pnorm(z)", list(z = c(a = -1, b = 0, c = 2)),
       jl = r"---(result = N.pnorm(z))---")
s_case("shape_empty", "list(pnorm(numeric(0)), qt(numeric(0), 3), lgamma(numeric(0)))",
       "result = [nm.pnorm(np.array([])), nm.qt(np.array([]), 3), nm.lgamma(np.array([]))]",
       jl = r"---(result = Any[N.pnorm(Float64[]), N.qt(Float64[], 3), N.lgamma(Float64[])])---")
s_case("na_nan", "list(pnorm(c(NA, NaN, 1)), qt(c(NA, 0.5), c(3, NaN)), lgamma(c(NA, NaN)), pbeta(NA, 1, 2))",
       "from simlev._r.fmt import NA_REAL as NA\nresult = [nm.pnorm(np.array([NA, np.nan, 1])), nm.qt(np.array([NA, 0.5]), np.array([3, np.nan])), nm.lgamma(np.array([NA, np.nan])), nm.pbeta(NA, 1, 2)]",
       jl = r"---(result = Any[N.pnorm([NA, NaN, 1]), N.qt([NA, 0.5], [3, NaN]), N.lgamma([NA, NaN]), N.pbeta(NA, 1, 2)])---")
s_case("warn_nan_qt", "qt(c(0.5, 2, -1), 3)", "result = nm.qt(np.array([0.5, 2, -1]), 3)",
       jl = r"---(result = N.qt([0.5, 2, -1], 3))---")
s_case("warn_nan_pt", "pt(1, c(-1, 0, 2))", "result = nm.pt(1, np.array([-1., 0, 2]))",
       jl = r"---(result = N.pt(1, [-1.0, 0, 2]))---")
s_case("warn_nan_pnorm", "pnorm(1, 0, -1)", "result = nm.pnorm(1, 0, -1)",
       jl = r"---(result = N.pnorm(1, 0, -1))---")
s_case("warn_nan_gamma", "gamma(c(-1, 0, 2.5))", "result = nm.gamma(np.array([-1., 0, 2.5]))",
       jl = r"---(result = N.gamma([-1.0, 0, 2.5]))---")
s_case("warn_range_gamma", "gamma(c(1e-309, 3))", "result = nm.gamma(np.array([1e-309, 3]))",
       jl = r"---(result = N.gamma([1e-309, 3]))---")
s_case("warn_prec_lgamma", "lgamma(-11 + 1e-12)", "result = nm.lgamma(-11 + 1e-12)",
       jl = r"---(result = N.lgamma(-11 + 1e-12))---")
s_case("warn_bgrat", "pbeta(1e-320, 1e-5, 0.5)", "result = nm.pbeta(1e-320, 1e-5, 0.5)",
       jl = r"---(result = N.pbeta(1e-320, 1e-5, 0.5))---")
s_case("warn_beta", "beta(1e-320, 1e-320)", "result = nm.beta(1e-320, 1e-320)",
       jl = r"---(result = N.beta(1e-320, 1e-320))---")
s_case("warn_dpois", "dpois(c(1.5, 2), 2)", "result = nm.dpois(np.array([1.5, 2]), 2)",
       jl = r"---(result = N.dpois([1.5, 2], 2))---")
s_case("warn_qgamma_rate_scale", "qgamma(0.5, 2, rate = 2, scale = 0.5)", "result = nm.qgamma(0.5, 2, rate=2, scale=0.5)",
       jl = r"---(result = N.qgamma(0.5, 2; rate = 2, scale = 0.5))---")
s_case("err_qgamma_rate_scale", "qgamma(0.5, 2, rate = 2, scale = 2)", "result = nm.qgamma(0.5, 2, rate=2, scale=2)",
       jl = r"---(result = N.qgamma(0.5, 2; rate = 2, scale = 2))---")
s_case("edge_qt", "c(qt(1e-300, 0.01), qt(-1e5, 2, log.p = TRUE), qt(-1e5, 1, log.p = TRUE), qt(-800, 1.5, log.p = TRUE), qt(0.5, 1e21), qt(1e-310, 2.5), qt(0.1, 0.1))",
       "result = [nm.qt(1e-300, 0.01), nm.qt(-1e5, 2, log_p=True), nm.qt(-1e5, 1, log_p=True), nm.qt(-800, 1.5, log_p=True), nm.qt(0.5, 1e21), nm.qt(1e-310, 2.5), nm.qt(0.1, 0.1)]",
       jl = r"---(result = [N.qt(1e-300, 0.01), N.qt(-1e5, 2; log_p = true), N.qt(-1e5, 1; log_p = true), N.qt(-800, 1.5; log_p = true), N.qt(0.5, 1e21), N.qt(1e-310, 2.5), N.qt(0.1, 0.1)])---")

# ── interne Hilfen über C-Modul ───────────────────────────────────────────
helper_src <- '
#include <R.h>
#include <Rinternals.h>
double Rf_stirlerr(double); double Rf_bd0(double, double); void Rf_ebd0(double, double, double*, double*);
double Rf_lgammacor(double); double Rf_chebyshev_eval(double, const double*, const int);
double Rf_log1pmx(double); double Rf_lgamma1p(double); double Rf_logspace_add(double, double);
double Rf_dpois_raw(double, double, int);
static const double gamcs[22] = {
 +.8571195590989331421920062399942e-2, +.4415381324841006757191315771652e-2,
 +.5685043681599363378632664588789e-1, -.4219835396418560501012500186624e-2,
 +.1326808181212460220584006796352e-2, -.1893024529798880432523947023886e-3,
 +.3606925327441245256578082217225e-4, -.6056761904460864218485548290365e-5,
 +.1055829546302283344731823509093e-5, -.1811967365542384048291855891166e-6,
 +.3117724964715322277790254593169e-7, -.5354219639019687140874081024347e-8,
 +.9193275519859588946887786825940e-9, -.1577941280288339761767423273953e-9,
 +.2707980622934954543266540433089e-10, -.4646818653825730144081661058933e-11,
 +.7973350192007419656460767175359e-12, -.1368078209830916025799499172309e-12,
 +.2347319486563800657233471771688e-13, -.4027432614949066932766570534699e-14,
 +.6910051747372100912138336975257e-15, -.1185584500221992907052387126192e-15 };
SEXP nm_helper(SEXP sw, SEXP sa, SEXP sb) {
  int w = asInteger(sw); R_xlen_t n = XLENGTH(sa);
  SEXP out = PROTECT(allocVector(REALSXP, w == 9 ? 2 * n : n));
  double *a = REAL(sa), *b = REAL(sb), *y = REAL(out);
  for (R_xlen_t i = 0; i < n; i++) switch (w) {
    case 1: y[i] = Rf_stirlerr(a[i]); break;
    case 2: y[i] = Rf_bd0(a[i], b[i]); break;
    case 3: y[i] = Rf_lgammacor(a[i]); break;
    case 4: y[i] = Rf_chebyshev_eval(a[i], gamcs, 22); break;
    case 5: y[i] = Rf_log1pmx(a[i]); break;
    case 6: y[i] = Rf_lgamma1p(a[i]); break;
    case 7: y[i] = Rf_logspace_add(a[i], b[i]); break;
    case 8: y[i] = Rf_dpois_raw(a[i], b[i], 0); break;
    case 10: y[i] = Rf_dpois_raw(a[i], b[i], 1); break;
    case 9: Rf_ebd0(a[i], b[i], y + i, y + n + i); break;
  }
  UNPROTECT(1); return out;
}'
# Interne nmath-Hilfen (stirlerr, bd0, ...) sind in libR nicht exportiert; für ihre Fälle
# werden sie aus den R-Quellen übersetzt. Pfad zu src/nmath der passenden R-Version:
nmsrc <- Sys.getenv("SIMLEV_R_NMATH_SRC", "")
hdir <- tempfile("nmhelp"); dir.create(hdir)
ok <- file.exists(file.path(nmsrc, "stirlerr.c")) && nzchar(Sys.which("gcc"))
if (ok) {
  writeLines(helper_src, file.path(hdir, "nmhelp.c"))
  for (f in c("stirlerr.c", "bd0.c", "lgammacor.c", "chebyshev.c")) file.copy(file.path(nmsrc, f), hdir)
  old <- setwd(hdir)
  st <- system2(file.path(R.home("bin"), "R"),
                c("CMD", "SHLIB", "-o", "nmhelp.so", "nmhelp.c", "stirlerr.c", "bd0.c", "lgammacor.c", "chebyshev.c"),
                env = sprintf("PKG_CPPFLAGS=-I%s", nmsrc), stdout = FALSE, stderr = FALSE)
  setwd(old)
  ok <- st == 0 && file.exists(file.path(hdir, "nmhelp.so"))
}
if (ok) {
  dyn.load(file.path(hdir, "nmhelp.so"))
  hcall <<- function(w, a, b = a) .Call("nm_helper", as.integer(w), as.double(a), as.double(b))
  M <- 1000
  w10 <- function(n, lo, hi) 10^runif(n, lo, hi)
  hx <- c(w10(M / 4, -300, 300), runif(M / 4, 0, 16), round(runif(M / 4, 0, 40) * 2) / 2, runif(M / 4, 14, 600))
  lam <- c(w10(M / 4, -300, 300), runif(M / 4, 0, 50), w10(M / 4, -5, 10), runif(M / 4, 0, 1000))
  kx <- ifelse(runif(M) < 0.5, round(lam * (1 + rnorm(M, 0, 0.3))), lam * exp(rnorm(M, 0, 2)))
  kx <- abs(kx); kx[1:50] <- w10(50, -300, 300)
  s_case("helper_stirlerr", "hcall(1, x)", "result = [nm.stirlerr(v) for v in np.atleast_1d(x)]", list(x = hx),
         note = "C-Modul: stirlerr.c aus R 4.3.3",
       jl = r"---(result = [N.stirlerr(v) for v in x])---")
  s_case("helper_bd0", "hcall(2, x, l)", "result = [nm.bd0(u, v) for u, v in zip(x, l)]", list(x = kx, l = lam),
       jl = r"---(result = [N.bd0(u, v) for (u, v) in zip(x, l)])---")
  s_case("helper_ebd0", "hcall(9, x, l)",
         "r = [nm.ebd0(u, v) for u, v in zip(x, l)]\nresult = [t[0] for t in r] + [t[1] for t in r]", list(x = kx, l = lam),
       jl = r"---(r = [N.ebd0(u, v) for (u, v) in zip(x, l)]
result = vcat(first.(r), last.(r)))---")
  s_case("helper_lgammacor", "hcall(3, x)", "result = [nm.lgammacor(v) for v in x]",
         list(x = c(w10(M / 4, 1, 308), runif(M / 4, 10, 100), runif(M / 4, 0, 12), w10(M / 4, 7, 9))),
       jl = r"---(result = [N.lgammacor(v) for v in x])---")
  s_case("helper_chebyshev", "hcall(4, x)", "result = [nm.chebyshev_eval(v, nm._GAMCS, 22) for v in x]",
         list(x = runif(M, -1.2, 1.2)),
       jl = r"---(result = [N.chebyshev_eval(v, N._GAMCS, 22) for v in x])---")
  s_case("helper_log1pmx", "hcall(5, x)", "result = [nm.log1pmx(v) for v in x]",
         list(x = c(runif(M / 4, -1, 2), sample(c(-1, 1), M / 4, TRUE) * w10(M / 4, -20, 0), w10(M / 4, -300, 300), runif(M / 4, -0.8, 1.1))),
       jl = r"---(result = [N.log1pmx(v) for v in x])---")
  s_case("helper_lgamma1p", "hcall(6, x)", "result = [nm.lgamma1p(v) for v in x]",
         list(x = c(runif(M / 4, -0.6, 0.6), sample(c(-1, 1), M / 4, TRUE) * w10(M / 4, -20, 0), runif(M / 4, -20, 50), runif(M / 4, -0.5, 0.5))),
       jl = r"---(result = [N.lgamma1p(v) for v in x])---")
  s_case("helper_logspace_add", "hcall(7, x, y)", "result = [nm.logspace_add(u, v) for u, v in zip(x, y)]",
         list(x = -w10(M, -5, 5), y = -w10(M, -5, 5)),
       jl = r"---(result = [N.logspace_add(u, v) for (u, v) in zip(x, y)])---")
  s_case("helper_dpois_raw", "c(hcall(8, x, l), hcall(10, x, l))",
         "result = [nm.dpois_raw(u, v, 0) for u, v in zip(x, l)] + [nm.dpois_raw(u, v, 1) for u, v in zip(x, l)]",
         list(x = kx, l = lam),
       jl = r"---(result = vcat([N.dpois_raw(u, v, false) for (u, v) in zip(x, l)], [N.dpois_raw(u, v, true) for (u, v) in zip(x, l)]))---")
} else {
  cat("Hinweis: C-Modul für interne Hilfen nicht übersetzbar - Hilfsfälle entfallen\n")
}
ref_done()

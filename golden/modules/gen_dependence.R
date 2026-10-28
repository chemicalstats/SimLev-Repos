# Referenzfälle für dependence.R (+ Kerne .kendall_tau_core, .quantile_reg_core aus
# research_core.cpp; DCC-Filter seit 9.6c über die C-Bibliothek slc, .sl_dcc_filter).
source("golden/modules/ref_tools.R"); ref_init("dependence")
`%||%` <- function(a, b) if (is.null(a)) b else a
P <- "from simlev import _dependence_core as C\nfrom simlev import dependence as D\n"
J <- 'D = SL.Dependence\nC = SL.DependenceCore\nsub(m, r, c) = SL.NamedMat(m.data[r, c]; colnames = m.colnames[c])\n'
# Kern-Fälle: Startwert (KQ) und Skala in R berechnet und als Eingabe übergeben
qcase <- function(id, specs) {
  inp <- list(); rc <- character(0); pc <- character(0); jc <- character(0)
  for (i in seq_along(specs)) { s <- specs[[i]]
    b0 <- s$b0 %||% qr.coef(qr(s$X), s$y); sc <- s$sc %||% max(sd(s$y), 1e-12)
    inp[[paste0("y", i)]] <- s$y; inp[[paste0("X", i)]] <- s$X; inp[[paste0("b", i)]] <- as.numeric(b0); inp[[paste0("s", i)]] <- sc
    mi <- s$maxit %||% 2000L
    rc <- c(rc, sprintf("{b <- SimLev:::.quantile_reg_core(y%d, X%d, %.17g, b%d, s%d, 1e-10, %dL); list(beta = as.numeric(b), optimal = attr(b, 'optimal'))}", i, i, s$tau, i, i, mi))
    pc <- c(pc, sprintf("qrc(y%d, X%d, %.17g, b%d, s%d, %d)", i, i, s$tau, i, i, mi))
    jc <- c(jc, sprintf("qrc(y%d, X%d, %.17g, b%d, s%d, %d)", i, i, s$tau, i, i, mi)) }
  ref_case(id, sprintf("list(%s)", paste(rc, collapse = ", ")),
           paste0(PQ, sprintf("result = [%s]", paste(pc, collapse = ", "))), inputs = inp,
           jl = paste0(JQ, sprintf("result = [%s]", paste(jc, collapse = ", "))))
}
PQ <- paste0(P, "def qrc(y, X, tau, b0, sc, maxit=2000):\n",
             "    y = np.atleast_1d(np.asarray(y, float)); X = np.asarray(X, float).reshape(len(y), -1)\n",
             "    b, o = C.quantile_reg_core(y, X, tau, np.atleast_1d(np.asarray(b0, float)), sc, 1e-10, maxit)\n",
             "    return {'beta': b, 'optimal': o}\n")
JQ <- paste0(J, "function qrc(y, X, tau, b0, sc, maxit = 2000)\n",
             "    y = y isa Real ? [Float64(y)] : Float64.(y); X = reshape(Float64.(X), length(y), :)\n",
             "    b, o = C.quantile_reg_core(y, X, tau, b0 isa Real ? [Float64(b0)] : Float64.(b0), sc, 1e-10, maxit)\n",
             "    return SL.RList(\"beta\" => b, \"optimal\" => o)\nend\n")
sp <- function(y, X, tau, b0 = NULL, sc = NULL, maxit = NULL) list(y = y, X = X, tau = tau, b0 = b0, sc = sc, maxit = maxit)

# ── Kerne ────────────────────────────────────────────────────────────────
set.seed(3)
K <- list()
for (n in c(5, 50, 800)) { x <- rnorm(n); y <- x + rnorm(n); K[[length(K) + 1]] <- list(x = x, y = y)
  K[[length(K) + 1]] <- list(x = round(x), y = round(y)) }
K[[length(K) + 1]] <- list(x = c(1, 1, 1, 2), y = c(3, 3, 3, 3))
K[[length(K) + 1]] <- list(x = 1, y = 2)
for (i in seq_along(K))
  ref_case(sprintf("kendall_core_%02d", i), "SimLev:::.kendall_tau_core(x, y)",
           paste0(P, "result = C.kendall_tau_core(x, y)"), inputs = K[[i]],
           jl = paste0(J, "result = C.kendall_tau_core(x, y)"))
set.seed(7); M <- matrix(rnorm(300), ncol = 3, dimnames = list(NULL, c("a", "b", "c")))
Mt <- round(M * 2)
ref_case("kendall_mat", "list(SimLev:::.kendall(M), SimLev:::.kendall(Mt), SimLev:::.kendall(M[, 1], Mt[, 2]))",
         paste0(P, "result = [D._kendall(M), D._kendall(Mt), D._kendall(M.iloc[:, 0], Mt.iloc[:, 1])]"),
         inputs = list(M = M, Mt = Mt), jl = paste0(J, "result = [D._kendall(M), D._kendall(Mt), D._kendall(M[:, 1], Mt[:, 2])]"))
Mn <- M; Mn[5, 2] <- NA
ref_case("kendall_na", "list(SimLev:::.kendall(Mn), SimLev:::.kendall(Mn[, 1], Mn[, 2]), SimLev:::.kendall(1:5, c(1, 1, 1, 1, 1)))",
         paste0(P, "result = [D._kendall(Mn), D._kendall(Mn.iloc[:, 0], Mn.iloc[:, 1]), D._kendall(np.arange(1, 6), np.ones(5))]"),
         inputs = list(Mn = Mn), jl = paste0(J, "result = [D._kendall(Mn), D._kendall(Mn[:, 1], Mn[:, 2]), D._kendall(1:5, ones(5))]"))

# DCC-Filter. 9.6c neu gefasst: der frühere Kern .dcc_filter (dependence_core.cpp) und seine Ports
# (Python _dependence_core, Julia DependenceCore) sind entfallen; dieselben Aufrufe über den
# slc-Filter (R .sl_dcc_filter, Python simlev._lib.dcc_filter, Julia SLib.dcc_filter).
set.seed(11); Z <- matrix(rnorm(600), 200); Z[, 2] <- 0.5 * Z[, 1] + Z[, 2]; Z[, 3] <- Z[, 3] - 0.3 * Z[, 1]
Qb <- cor(Z)
ref_case("dcc_filter", "list(SimLev:::.sl_dcc_filter(Z, 0.05, 0.9, Qb, TRUE), SimLev:::.sl_dcc_filter(Z, 0.02, 0.95, Qb, FALSE), SimLev:::.sl_dcc_filter(Z[, 1:2], 0.1, 0.8, Qb[1:2, 1:2], TRUE))",
         paste0(P, "import simlev._lib as L\nresult = [L.dcc_filter(Z, 0.05, 0.9, Qb, True), L.dcc_filter(Z, 0.02, 0.95, Qb, False), L.dcc_filter(Z[:, :2], 0.1, 0.8, Qb[:2, :2], True)]"),
         inputs = list(Z = Z, Qb = Qb),
         jl = paste0(J, "L = SL.SLib\nresult = [L.dcc_filter(Z, 0.05, 0.9, Qb, true), L.dcc_filter(Z, 0.02, 0.95, Qb, false), L.dcc_filter(Z[:, 1:2], 0.1, 0.8, Qb[1:2, 1:2], true)]"))
Qs <- matrix(c(1, 1, 1, 1), 2)
ref_case("dcc_filter_bad", "SimLev:::.sl_dcc_filter(Z[, 1:2], 0.05, 0.9, Qs, TRUE)",
         paste0(P, "import simlev._lib as L\nresult = L.dcc_filter(Z[:, :2], 0.05, 0.9, Qs, True)"), inputs = list(Z = Z, Qs = Qs),
         jl = paste0(J, "L = SL.SLib\nresult = L.dcc_filter(Z[:, 1:2], 0.05, 0.9, Qs, true)"))

# Quantilsregressions-Kern
set.seed(5); n <- 300; x <- rnorm(n); y <- 0.4 * x + rt(n, 3); X <- cbind(1, x)
qcase("qr_core_t", lapply(c(0.01, 0.1, 0.5, 0.9, 0.99), function(tau) sp(y, X, tau)))
qcase("qr_core_int", list(sp(y, X[, 1, drop = FALSE], 0.3), sp(c(1, 2, 3, 4), matrix(1, 4, 1), 0.5),
                          sp(c(1, 3, 3, 1, 2, 2), matrix(1, 6, 1), 0.5), sp(c(5, 1, 4, 2, 3, 3, 1), matrix(1, 7, 1), 0.2)))
set.seed(4); n <- 600; Xd <- cbind(1, matrix(sample(0:2, n * 3, TRUE), n)); yd <- sample(0:3, n, TRUE) + 0
qcase("qr_core_discrete", list(sp(yd, Xd, 0.05), sp(yd, Xd, 0.5), sp(yd, Xd, 0.8)))
for (s in 1:5) {
  set.seed(s); n <- 14; Xs <- cbind(1, matrix(sample(0:1, n * 2, TRUE), n)); ys <- sample(0:2, n, TRUE) + 0
  if (qr(Xs)$rank < 3) next
  qcase(sprintf("qr_core_small%d", s), list(sp(ys, Xs, 0.1), sp(ys, Xs, 0.5), sp(ys, Xs, 0.8)))
}
set.seed(9); n <- 200; x <- rnorm(n); yy <- 1 + 2 * x + rnorm(n) * (1 + abs(x)); XX <- cbind(1, x, x^2)
qcase("qr_core_start", list(sp(yy, XX, 0.02, b0 = c(0, 0, 0)), sp(yy, XX, 0.97, b0 = c(5, -1, 2), sc = 0.1), sp(yy, XX, 0.5, b0 = c(1, 2, 0))))
yr <- round(yy); Xr <- cbind(1, round(x, 1))
qcase("qr_core_round", list(sp(yr, Xr, 0.1), sp(yr, Xr, 0.5), sp(yr, Xr, 0.95), sp(c(yr, yr), rbind(Xr, Xr), 0.25)))
set.seed(12); n <- 120; xt <- sample(1:5, n, TRUE); yt <- xt + sample(c(-1, 0, 0, 1), n, TRUE)
qcase("qr_core_ties", list(sp(yt, cbind(1, xt), 0.5), sp(yt, cbind(1, xt), 0.3), sp(yt, cbind(1, xt), 0.9), sp(yt, cbind(1, xt), 0.01)))
# kurze MM-Stufen: Austauschschritte und LP-Nachweis (auch gescheitert)
set.seed(21)
for (blk in 1:4) {
  specs <- list()
  for (r in 1:10) {
    n <- sample(8:60, 1); p <- sample(1:3, 1); disc <- runif(1) < 0.5
    X <- cbind(1, matrix(if (disc) sample(0:2, n * (p - 1), TRUE) + 0 else round(rnorm(n * (p - 1)), 1), n))
    y <- if (disc) sample(0:3, n, TRUE) + 0 else round(rt(n, 2), 1)
    if (qr(X)$rank < p) next
    specs[[length(specs) + 1]] <- sp(y, X, sample(c(0.01, 0.03, 0.1, 0.5, 0.9, 0.97, 0.99), 1), maxit = sample(c(1L, 2L, 3L, 2000L), 1))
  }
  qcase(sprintf("qr_core_short%d", blk), specs)
}
qcase("qr_core_sing", list(sp(c(1, 2, 3), cbind(1, c(1, 1, 1)), 0.5, b0 = c(0, 0))))

# ── Daten ────────────────────────────────────────────────────────────────
mkdata <- function(seed = 1, n = 3 * 365, start = "2015-01-01") {
  set.seed(seed)
  d <- data.frame(date = seq.Date(as.Date(start), by = "day", length.out = n))
  infl <- 2 + cumsum(rnorm(n, 0, 0.05)); e1 <- rnorm(n); e2 <- rnorm(n); rho <- ifelse(infl > 2, 0.5, -0.3)
  d$stocks <- 100 * exp(cumsum(0.01 * e1))
  d$bonds <- 100 * exp(cumsum(0.005 * (rho * e1 + sqrt(1 - rho^2) * e2)))
  d$gold <- 100 * exp(cumsum(0.008 * rnorm(n) - 0.002 * e1))
  d$inflation <- infl
  d$zins <- round(1 + cumsum(rnorm(n, 0, 0.02)), 1)
  d$regime <- rep(rep(1:2, each = 200), length.out = n)
  d
}
d1 <- mkdata(1)
dna <- d1; dna$stocks[c(5, 6, 300)] <- NA; dna$bonds[1:3] <- NA; dna$inflation[c(10, 400)] <- NA

# Hilfen: Datumssortierung, Kursprüfung, Renditen
du <- d1[c(3, 1, 2, 4:40), c("date", "stocks")]
ref_case("sort_dates", "SimLev:::.dep_sort_dates(du)", paste0(P, "result = D._dep_sort_dates(du)"), inputs = list(du = du),
         jl = paste0(J, "result = D._dep_sort_dates(du)"))
ref_case("sort_dates_chr", "x <- d1[1:30, 1:2]; x$date <- format(x$date); SimLev:::.dep_sort_dates(x, 'Test')",
         paste0(P, "x = d1.iloc[:30, :2].copy(); x['date'] = [str(v) for v in x['date'].to_numpy().astype('datetime64[D]')]; result = D._dep_sort_dates(x, 'Test')"),
         inputs = list(d1 = d1[1:30, ]),
         jl = paste0(J, 'x = SL.RFrame("date" => Dates.format.(d1["date"], "yyyy-mm-dd"), "stocks" => d1["stocks"]); result = D._dep_sort_dates(x, "Test")'))
dm <- d1[1:20, 1:2]; dm$date[c(4, 9)] <- NA
ref_case("sort_dates_na", "SimLev:::.dep_sort_dates(dm)", paste0(P, "result = D._dep_sort_dates(dm)"), inputs = list(dm = dm),
         jl = paste0(J, "result = D._dep_sort_dates(dm)"))
dd <- d1[c(1:10, 3, 5, 5, 7), 1:2]
ref_case("sort_dates_dup", "SimLev:::.dep_sort_dates(dd)", paste0(P, "result = D._dep_sort_dates(dd)"), inputs = list(dd = dd),
         jl = paste0(J, "result = D._dep_sort_dates(dd)"))
dd7 <- d1[c(1:10, 1:7), 1:2]
ref_case("sort_dates_dup7", "SimLev:::.dep_sort_dates(dd7, 'X')", paste0(P, "result = D._dep_sort_dates(dd7, 'X')"), inputs = list(dd7 = dd7),
         jl = paste0(J, 'result = D._dep_sort_dates(dd7, "X")'))
ref_case("check_prices", "list(SimLev:::.dep_check_prices(c(1, NA, 3), 'a', d1$date[1:3]))",
         paste0(P, "result = [D._dep_check_prices(np.array([1, simlev._r.fmt.NA_REAL, 3]), 'a', d1['date'].to_numpy()[:3])]"), inputs = list(d1 = d1[1:5, ]),
         jl = paste0(J, 'result = [D._dep_check_prices([1, SL.NA, 3], "a", d1["date"][1:3])]'))
ref_case("check_prices_neg", "SimLev:::.dep_check_prices(c(1, 2, -3.25, 0, Inf), 'aktien', d1$date[1:5])",
         paste0(P, "result = D._dep_check_prices(np.array([1, 2, -3.25, 0, np.inf]), 'aktien', d1['date'].to_numpy()[:5])"), inputs = list(d1 = d1[1:5, ]),
         jl = paste0(J, 'result = D._dep_check_prices([1, 2, -3.25, 0, Inf], "aktien", d1["date"][1:5])'))
ref_case("check_prices_inf", "SimLev:::.dep_check_prices(c(1, Inf), 'b', d1$date[1:2])",
         paste0(P, "result = D._dep_check_prices(np.array([1, np.inf]), 'b', d1['date'].to_numpy()[:2])"), inputs = list(d1 = d1[1:5, ]),
         jl = paste0(J, 'result = D._dep_check_prices([1, Inf], "b", d1["date"][1:2])'))
for (fr in c("week", "month", "day"))
  ref_case(paste0("returns_", fr), sprintf("SimLev:::.dep_returns(dna, c('stocks', 'bonds'), c('inflation', 'zins'), '%s')", fr),
           paste0(P, sprintf("result = D._dep_returns(dna, ['stocks', 'bonds'], ['inflation', 'zins'], '%s')", fr)), inputs = list(dna = dna),
           jl = paste0(J, sprintf('result = D._dep_returns(dna, ["stocks", "bonds"], ["inflation", "zins"], "%s")', fr)))
dfl <- d1[1:200, c("date", "stocks", "bonds")]; dfl$stocks[50:60] <- dfl$stocks[50]; dfl$bonds[50:60] <- dfl$bonds[50]
ref_case("returns_flat", "list(SimLev:::.dep_returns(dfl, c('stocks', 'bonds'), NULL, 'day'), SimLev:::.dep_returns(dfl, c('stocks', 'bonds'), NULL, 'day', drop_flat = FALSE))",
         paste0(P, "result = [D._dep_returns(dfl, ['stocks', 'bonds'], None, 'day'), D._dep_returns(dfl, ['stocks', 'bonds'], None, 'day', drop_flat=False)]"),
         inputs = list(dfl = dfl),
         jl = paste0(J, 'result = [D._dep_returns(dfl, ["stocks", "bonds"], nothing, "day"), D._dep_returns(dfl, ["stocks", "bonds"], nothing, "day"; drop_flat = false)]'))
ref_case("returns_err1", "SimLev:::.dep_returns(as.matrix(d1[, 2:3]), 'stocks')", paste0(P, "result = D._dep_returns(d1.iloc[:, 1:3].to_numpy(), 'stocks')"), inputs = list(d1 = d1[1:5, ]),
         jl = paste0(J, 'result = D._dep_returns(hcat(d1["stocks"], d1["bonds"]), "stocks")'))
ref_case("returns_err2", "SimLev:::.dep_returns(d1, c('stocks', 'xx'), 'yy')", paste0(P, "result = D._dep_returns(d1, ['stocks', 'xx'], 'yy')"), inputs = list(d1 = d1[1:5, ]),
         jl = paste0(J, 'result = D._dep_returns(d1, ["stocks", "xx"], "yy")'))
dneg <- d1[1:50, 1:3]; dneg$bonds[20] <- -1
ref_case("returns_err3", "SimLev:::.dep_returns(dneg, c('stocks', 'bonds'))", paste0(P, "result = D._dep_returns(dneg, ['stocks', 'bonds'])"), inputs = list(dneg = dneg),
         jl = paste0(J, 'result = D._dep_returns(dneg, ["stocks", "bonds"])'))
ref_case("pobs", "list(SimLev:::.pobs(c(3, 1, 2, 2, 5)), SimLev:::.pobs(d1$stocks[1:50]))",
         paste0(P, "result = [D._pobs(np.array([3., 1, 2, 2, 5])), D._pobs(d1['stocks'].to_numpy()[:50])]"), inputs = list(d1 = d1[1:50, ]),
         jl = paste0(J, 'result = [D._pobs([3.0, 1, 2, 2, 5]), D._pobs(d1["stocks"][1:50])]'))

# Copula-Dichten und Tail-Koeffizienten
set.seed(2); uu <- runif(60); vv <- runif(60); uu[1] <- 1e-9; vv[2] <- 1 - 1e-9
fams <- list(list("gaussian", c(.5, NA)), list("gaussian", -0.9), list("t", c(-.4, 5)), list("t", c(0.7, 30)), list("clayton", 2),
             list("clayton_90", 1.5), list("clayton_180", 0.3), list("clayton_270", 1.5), list("gumbel", 1.8), list("gumbel_90", 1.2),
             list("gumbel_180", 2), list("gumbel_270", 3), list("frank", -4), list("frank", 1e-9), list("frank", 12), list("clayton", 1e-4))
for (i in seq_along(fams)) {
  f <- fams[[i]]
  ref_case(sprintf("cop_%02d_%s", i, f[[1]]), sprintf("list(SimLev:::.cop_ll('%s', p, uu, vv), SimLev:::.cop_lambda('%s', p))", f[[1]], f[[1]]),
           paste0(P, sprintf("result = [D._cop_ll('%s', p, uu, vv), D._cop_lambda('%s', p)]", f[[1]], f[[1]])),
           inputs = list(uu = uu, vv = vv, p = f[[2]]),
           jl = paste0(J, sprintf('result = [D._cop_ll("%s", p, uu, vv), D._cop_lambda("%s", p)]', f[[1]], f[[1]])))
}
ref_case("cop_bad", "SimLev:::.cop_ll('student', 1, uu, vv)", paste0(P, "result = D._cop_ll('student', 1, uu, vv)"), inputs = list(uu = uu, vv = vv),
         jl = paste0(J, 'result = D._cop_ll("student", 1, uu, vv)'))
ref_case("cop_nonfinite", "SimLev:::.cop_ll('gaussian', 1, uu, vv)", paste0(P, "result = D._cop_ll('gaussian', 1, uu, vv)"), inputs = list(uu = uu, vv = vv),
         jl = paste0(J, 'result = D._cop_ll("gaussian", 1, uu, vv)'))

# copula_fit
set.seed(1); n <- 300
z <- matrix(rnorm(2 * n), ncol = 2) %*% chol(matrix(c(1, .6, .6, 1), 2)); w <- sqrt(rchisq(n, 4) / 4)
CX <- list(x = z[, 1] / w, y = z[, 2] / w, yn = -z[, 2])
ref_case("fitcop_t", "copula_fit(x, y)", paste0(P, "result = D.copula_fit(x, y)"), inputs = CX[c("x", "y")],
         jl = paste0(J, "result = D.copula_fit(x, y)"))
ref_case("fitcop_neg", "copula_fit(x, yn)", paste0(P, "result = D.copula_fit(x, yn)"), inputs = CX[c("x", "yn")],
         jl = paste0(J, "result = D.copula_fit(x, yn)"))
ref_case("fitcop_fam", "copula_fit(x, y, c('frank', 'gumbel_180', 'clayton_270', 'gaussian'))",
         paste0(P, "result = D.copula_fit(x, y, families=['frank', 'gumbel_180', 'clayton_270', 'gaussian'])"), inputs = CX[c("x", "y")],
         jl = paste0(J, 'result = D.copula_fit(x, y, ["frank", "gumbel_180", "clayton_270", "gaussian"])'))
set.seed(3); th <- 3; u <- runif(200); t <- runif(200); v <- ((t^(-th / (1 + th)) - 1) * u^(-th) + 1)^(-1 / th)
# 9.6b: Normalquantil der C-Bibliothek slc in allen drei Sprachen (statt stats::qnorm und der nmath-Nachbildung)
ref_case("fitcop_clayton", "copula_fit(SimLev:::.sl_qnorm(u), SimLev:::.sl_qnorm(v))", paste0(P, "from simlev import _lib\nresult = D.copula_fit(_lib.qnorm(u), _lib.qnorm(v))"),
         inputs = list(u = u, v = v), jl = paste0(J, "result = D.copula_fit(SL.SLib.qnorm(u), SL.SLib.qnorm(v))"))
xna <- CX$x[1:60]; yna <- CX$y[1:60]; xna[c(3, 9)] <- NA; yna[20] <- Inf
ref_case("fitcop_na", "copula_fit(xna, round(yna, 1), 'gaussian')", paste0(P, "result = D.copula_fit(xna, simlev._r.fmt.r_round(yna, 1), families='gaussian')"),
         inputs = list(xna = xna, yna = yna), jl = paste0(J, 'result = D.copula_fit(xna, SL.RFmt.r_round.(yna, 1), "gaussian")'))
ref_case("fitcop_err_len", "copula_fit(1:30, 1:29)", paste0(P, "result = D.copula_fit(np.arange(1, 31), np.arange(1, 30))"),
         jl = paste0(J, "result = D.copula_fit(1:30, 1:29)"))
ref_case("fitcop_err_n", "copula_fit(c(1:19, NA), 1:20)", paste0(P, "result = D.copula_fit(np.r_[np.arange(1., 20), simlev._r.fmt.NA_REAL], np.arange(1, 21))"),
         jl = paste0(J, "result = D.copula_fit(vcat(1.0:19.0, SL.NA), 1:20)"))
ref_case("fitcop_err_fam", "copula_fit(x, y, c('t', 'gaussian_90', 'joe', 'gumbel_45'))",
         paste0(P, "result = D.copula_fit(x, y, families=['t', 'gaussian_90', 'joe', 'gumbel_45'])"), inputs = CX[c("x", "y")],
         jl = paste0(J, 'result = D.copula_fit(x, y, ["t", "gaussian_90", "joe", "gumbel_45"])'))
ref_case("fitcop_err_const", "copula_fit(rep(1, 30), 1:30)", paste0(P, "result = D.copula_fit(np.ones(30), np.arange(1, 31))"),
         jl = paste0(J, "result = D.copula_fit(ones(30), 1:30)"))

# tail_dependence
set.seed(1); z0 <- rnorm(500); tx <- z0 + rnorm(500); ty <- z0 + rnorm(500)
ref_case("tail_default", "tail_dependence(tx, ty)", paste0(P, "result = D.tail_dependence(tx, ty)"), inputs = list(tx = tx, ty = ty),
         jl = paste0(J, "result = D.tail_dependence(tx, ty)"))
ref_case("tail_q", "tail_dependence(tx, ty, c(0.05, 0.1, 0.3))", paste0(P, "result = D.tail_dependence(tx, ty, q=[0.05, 0.1, 0.3])"), inputs = list(tx = tx, ty = ty),
         jl = paste0(J, "result = D.tail_dependence(tx, ty, [0.05, 0.1, 0.3])"))
txs <- tx[1:30]; tys <- round(ty[1:30]); txs[2] <- NaN
ref_case("tail_small", "tail_dependence(txs, tys, c(0.1, 0.5))", paste0(P, "result = D.tail_dependence(txs, tys, q=[0.1, 0.5])"), inputs = list(txs = txs, tys = tys),
         jl = paste0(J, "result = D.tail_dependence(txs, tys, [0.1, 0.5])"))
ref_case("tail_const", "tail_dependence(rep(1, 40), 1:40, 0.4)", paste0(P, "result = D.tail_dependence(np.ones(40), np.arange(1, 41), q=0.4)"),
         jl = paste0(J, "result = D.tail_dependence(ones(40), 1:40, 0.4)"))
ref_case("tail_err_q", "tail_dependence(tx, ty, c(0.05, 1, 5))", paste0(P, "result = D.tail_dependence(tx, ty, q=[0.05, 1, 5])"), inputs = list(tx = tx, ty = ty),
         jl = paste0(J, "result = D.tail_dependence(tx, ty, [0.05, 1, 5])"))
ref_case("tail_err_q2", "tail_dependence(tx, ty, numeric(0))", paste0(P, "result = D.tail_dependence(tx, ty, q=[])"), inputs = list(tx = tx, ty = ty),
         jl = paste0(J, "result = D.tail_dependence(tx, ty, Float64[])"))
ref_case("tail_err_q3", "tail_dependence(tx, ty, 'a')", paste0(P, "result = D.tail_dependence(tx, ty, q='a')"), inputs = list(tx = tx, ty = ty),
         jl = paste0(J, 'result = D.tail_dependence(tx, ty, "a")'))
ref_case("tail_err_len", "tail_dependence(1:3, 1:4)", paste0(P, "result = D.tail_dependence(np.arange(1, 4), np.arange(1, 5))"),
         jl = paste0(J, "result = D.tail_dependence(1:3, 1:4)"))
ref_case("tail_err_n", "tail_dependence(c(1, NA), c(2, 3))", paste0(P, "result = D.tail_dependence(np.array([1, simlev._r.fmt.NA_REAL]), np.array([2., 3]))"),
         jl = paste0(J, "result = D.tail_dependence([1, SL.NA], [2.0, 3])"))

# DCC
set.seed(1); n <- 300
RR <- cbind(a = rnorm(n, 0, 0.01), b = rnorm(n, 0, 0.01), c = rnorm(n, 0, 0.012))
RR[, "b"] <- 0.5 * RR[, "a"] + sqrt(0.75) * RR[, "b"]
ref_case("dcc_fit2", "dependence_dcc(RR[, 1:2])", paste0(P, "result = D.dependence_dcc(RR.iloc[:, :2])"), inputs = list(RR = RR),
         jl = paste0(J, "result = D.dependence_dcc(sub(RR, :, 1:2))"))
ref_case("dcc_fit3", "dependence_dcc(unname(RR))", paste0(P, "result = D.dependence_dcc(RR.to_numpy())"), inputs = list(RR = RR),
         jl = paste0(J, "result = D.dependence_dcc(RR.data)"))
ref_case("dcc_err_n", "dependence_dcc(RR[1:99, ])", paste0(P, "result = D.dependence_dcc(RR.iloc[:99])"), inputs = list(RR = RR),
         jl = paste0(J, "result = D.dependence_dcc(sub(RR, 1:99, :))"))
ref_case("dcc_err_k", "dependence_dcc(RR[, 1, drop = FALSE])", paste0(P, "result = D.dependence_dcc(RR.iloc[:, :1])"), inputs = list(RR = RR),
         jl = paste0(J, "result = D.dependence_dcc(sub(RR, :, 1:1))"))
RC <- RR; RC[, "c"] <- 0.001
ref_case("dcc_err_const", "dependence_dcc(RC)", paste0(P, "result = D.dependence_dcc(RC)"), inputs = list(RC = RC),
         jl = paste0(J, "result = D.dependence_dcc(RC)"))
RS <- cbind(RR, d = RR[, "a"] * 2)
ref_case("dcc_err_sing", "dependence_dcc(RS)", paste0(P, "result = D.dependence_dcc(RS)"), inputs = list(RS = RS),
         jl = paste0(J, "result = D.dependence_dcc(RS)"))

# Regime aus Zustandsvariablen
set.seed(5); cvx <- rnorm(200); cvd <- sample(1:2, 200, TRUE); cvd2 <- c(rep(0, 150), 1:50)
rg <- function(...) { r <- SimLev:::.dep_regimes(...); list(regime = as.character(r$regime), levels = levels(r$regime), breaks = r$breaks) }
JR <- paste0(J, "function rg(a...)\n    code, lab, br = D._dep_regimes(a...)\n    SL.RList(\"regime\" => Union{Missing,String}[c > 0 ? lab[c] : missing for c in code], \"levels\" => lab, \"breaks\" => br)\nend\n")
PR <- paste0(P, "def rg(*a):\n    code, lab, br = D._dep_regimes(*a)\n    return {'regime': [lab[c - 1] if c > 0 else None for c in code], 'levels': lab, 'breaks': br}\n")
ref_case("regimes_q", "list(rg(cvx), rg(cvx, NULL, 2L), rg(cvx, NULL, 5L), rg(cvd), rg(cvd2), rg(rep(3, 40)))",
         paste0(PR, "result = [rg(cvx), rg(cvx, None, 2), rg(cvx, None, 5), rg(cvd), rg(cvd2), rg(np.full(40, 3.))]"),
         inputs = list(cvx = cvx, cvd = cvd, cvd2 = cvd2),
         jl = paste0(JR, "result = [rg(cvx), rg(cvx, nothing, 2), rg(cvx, nothing, 5), rg(cvd), rg(cvd2), rg(fill(3.0, 40))]"))
ref_case("regimes_breaks", "list(rg(cvx, c(-Inf, 0, Inf)), rg(cvx, c(-1, 0.5, 1)), rg(cvx * 1000, c(-Inf, -123.4567, 2345.678, Inf)), rg(cvx, c(1, -1, 0)))",
         paste0(PR, "result = [rg(cvx, [-np.inf, 0, np.inf]), rg(cvx, [-1, 0.5, 1]), rg(cvx * 1000, [-np.inf, -123.4567, 2345.678, np.inf]), rg(cvx, [1, -1, 0])]"),
         inputs = list(cvx = cvx),
         jl = paste0(JR, "result = [rg(cvx, [-Inf, 0, Inf]), rg(cvx, [-1, 0.5, 1]), rg(cvx .* 1000, [-Inf, -123.4567, 2345.678, Inf]), rg(cvx, [1, -1, 0])]"))
ref_case("regimes_err", "rg(cvx, c(-Inf, 0, 0, Inf))", paste0(PR, "result = rg(cvx, [-np.inf, 0, 0, np.inf])"), inputs = list(cvx = cvx),
         jl = paste0(JR, "result = rg(cvx, [-Inf, 0, 0, Inf])"))

# .dep_reg_cor
set.seed(8); XR <- matrix(rnorm(300), 100); rk <- factor(sample(c("a", "b", "c"), 100, TRUE, prob = c(.45, .45, .1)), levels = c("a", "b", "c"))
XR[rk == "b", 2] <- 1
ref_case("reg_cor", "rk <- factor(rk, levels = c('a', 'b', 'c')); pidx <- t(combn(3, 2)); suppressWarnings(list(SimLev:::.dep_reg_cor(XR, rk, levels(rk), pidx), SimLev:::.dep_reg_cor(XR, rk, levels(rk), pidx, TRUE)))",
         paste0(P, "code = np.array([{'a': 1, 'b': 2, 'c': 3}[v] for v in rk]); pidx = [(0, 1), (0, 2), (1, 2)]\nresult = [D._dep_reg_cor(XR, code, 3, pidx), D._dep_reg_cor(XR, code, 3, pidx, rank=True)]"),
         inputs = list(XR = XR, rk = as.character(rk)),
         jl = paste0(J, 'code = [Dict("a" => 1, "b" => 2, "c" => 3)[v] for v in rk]; pidx = [(1, 2), (1, 3), (2, 3)]\nresult = [D._dep_reg_cor(XR, code, 3, pidx), D._dep_reg_cor(XR, code, 3, pidx; rank = true)]'))

# dependence_analysis
DA <- list(d1 = d1)
ref_case("da_basic", "dependence_analysis(d1, c('stocks', 'bonds'), copulas = FALSE)",
         paste0(P, "result = D.dependence_analysis(d1, ['stocks', 'bonds'], copulas=False)"), inputs = DA,
         jl = paste0(J, 'result = D.dependence_analysis(d1, ["stocks", "bonds"]; copulas = false)'))
ref_case("da_cond", "dependence_analysis(d1, c('stocks', 'bonds', 'gold'), conditions = c('inflation', 'regime'), B = 19, seed = 1, dcc = FALSE)",
         paste0(P, "result = D.dependence_analysis(d1, ['stocks', 'bonds', 'gold'], conditions=['inflation', 'regime'], B=19, seed=1, dcc=False)"), inputs = DA,
         jl = paste0(J, 'result = D.dependence_analysis(d1, ["stocks", "bonds", "gold"]; conditions = ["inflation", "regime"], B = 19, seed = 1, dcc = false)'))
ref_case("da_breaks", "dependence_analysis(d1, c('stocks', 'bonds'), conditions = 'inflation', breaks = list(inflation = c(-Inf, 2, Inf)), quantiles = c(0.1, 0.25), B = 9, block = 4, seed = 3, tail_q = 0.2, window = 20)",
         paste0(P, "result = D.dependence_analysis(d1, ['stocks', 'bonds'], conditions='inflation', breaks={'inflation': [-np.inf, 2, np.inf]}, quantiles=[0.1, 0.25], B=9, block=4, seed=3, tail_q=0.2, window=20)"), inputs = DA,
         jl = paste0(J, 'result = D.dependence_analysis(d1, ["stocks", "bonds"]; conditions = "inflation", breaks = Dict("inflation" => [-Inf, 2, Inf]), quantiles = [0.1, 0.25], B = 9, block = 4, seed = 3, tail_q = 0.2, window = 20)'))
ref_case("da_month", "dependence_analysis(d1, c('stocks', 'gold'), frequency = 'month', conditions = 'zins', n_regimes = 2L, B = 0)",
         paste0(P, "result = D.dependence_analysis(d1, ['stocks', 'gold'], frequency='month', conditions='zins', n_regimes=2, B=0)"), inputs = DA,
         jl = paste0(J, 'result = D.dependence_analysis(d1, ["stocks", "gold"]; frequency = "month", conditions = "zins", n_regimes = 2, B = 0)'))
d400 <- d1[1:420, ]
ref_case("da_day", "dependence_analysis(d400, c('stocks', 'bonds'), frequency = 'day', conditions = 'zins', B = 5, seed = 2, n_regimes = 4L)",
         paste0(P, "result = D.dependence_analysis(d400, ['stocks', 'bonds'], frequency='day', conditions='zins', B=5, seed=2, n_regimes=4)"), inputs = list(d400 = d400),
         jl = paste0(J, 'result = D.dependence_analysis(d400, ["stocks", "bonds"]; frequency = "day", conditions = "zins", B = 5, seed = 2, n_regimes = 4)'))
dsh <- d1[1:300, ]; dsh$inflation[1:200] <- NA
ref_case("da_warn", "dependence_analysis(dsh, c('stocks', 'bonds'), conditions = 'inflation', copulas = FALSE)",
         paste0(P, "result = D.dependence_analysis(dsh, ['stocks', 'bonds'], conditions='inflation', copulas=False)"), inputs = list(dsh = dsh),
         jl = paste0(J, 'result = D.dependence_analysis(dsh, ["stocks", "bonds"]; conditions = "inflation", copulas = false)'))
ref_case("da_dccfail", "x <- d1; x$b2 <- x$bonds; dependence_analysis(x, c('stocks', 'bonds', 'b2'), copulas = FALSE)",
         paste0(P, "x = d1.copy(); x['b2'] = x['bonds']; result = D.dependence_analysis(x, ['stocks', 'bonds', 'b2'], copulas=False)"), inputs = DA,
         jl = paste0(J, 'x = copy(d1); x["b2"] = copy(x["bonds"]); result = D.dependence_analysis(x, ["stocks", "bonds", "b2"]; copulas = false)'))
ref_case("da_err1", "dependence_analysis(d1, 'stocks')", paste0(P, "result = D.dependence_analysis(d1, 'stocks')"), inputs = list(d1 = d1[1:10, ]),
         jl = paste0(J, 'result = D.dependence_analysis(d1, "stocks")'))
ref_case("da_err2", "dependence_analysis(d1, c('stocks', 'bonds'), frequency = 'month')", paste0(P, "result = D.dependence_analysis(d1, ['stocks', 'bonds'], frequency='month')"), inputs = list(d1 = d1[1:400, ]),
         jl = paste0(J, 'result = D.dependence_analysis(d1, ["stocks", "bonds"]; frequency = "month")'))
ref_case("da_err3", "dependence_analysis(d1, c('stocks', 'bonds'), frequency = 'year')", paste0(P, "result = D.dependence_analysis(d1, ['stocks', 'bonds'], frequency='year')"), inputs = list(d1 = d1[1:10, ]),
         jl = paste0(J, 'result = D.dependence_analysis(d1, ["stocks", "bonds"]; frequency = "year")'))

# quantile_regression
set.seed(1); x <- rnorm(200); y <- 1 + 2 * x + rnorm(200) * (1 + abs(x)); x2 <- rnorm(200)
QI <- list(x = x, y = y, x2 = x2)
ref_case("qreg_basic", "list(quantile_regression(y, x, 0.9), quantile_regression(y, NULL, 0.3), quantile_regression(y, cbind(a = x, b = x2), 0.5), quantile_regression(y, data.frame(u = x), 0.1, intercept = FALSE))",
         paste0(P, "result = [D.quantile_regression(y, X=x, tau=0.9), D.quantile_regression(y, X=None, tau=0.3), D.quantile_regression(y, X=pd.DataFrame({'a': x, 'b': x2}), tau=0.5), D.quantile_regression(y, X=pd.DataFrame({'u': x}), tau=0.1, intercept=False)]"), inputs = QI,
         jl = paste0(J, 'result = [D.quantile_regression(y, x, 0.9), D.quantile_regression(y, nothing, 0.3), D.quantile_regression(y, SL.NamedMat(hcat(x, x2); colnames = ["a", "b"]), 0.5), D.quantile_regression(y, SL.RFrame("u" => x), 0.1; intercept = false)]'))
ref_case("qreg_na", "y2 <- y; y2[3] <- NA; x3 <- x; x3[7] <- Inf; quantile_regression(y2, cbind(x3, x2), 0.25, tol = 1e-8, maxit = 50L)",
         paste0(P, "y2 = y.copy(); y2[2] = simlev._r.fmt.NA_REAL; x3 = x.copy(); x3[6] = np.inf; result = D.quantile_regression(y2, X=pd.DataFrame({'x3': x3, 'x2': x2}), tau=0.25, tol=1e-8, maxit=50)"), inputs = QI,
         jl = paste0(J, 'y2 = copy(y); y2[3] = SL.NA; x3 = copy(x); x3[7] = Inf; result = D.quantile_regression(y2, SL.NamedMat(hcat(x3, x2); colnames = ["x3", "x2"]), 0.25; tol = 1e-8, maxit = 50)'))
for (tv in list("0", "1", "c(0.1, 0.2)", "NA", "'a'"))
  ref_case(sprintf("qreg_err_tau_%s", gsub("[^a-z0-9]", "", tv)), sprintf("quantile_regression(y, x, %s)", tv),
           paste0(P, sprintf("result = D.quantile_regression(y, X=x, tau=%s)", c("0" = "0", "1" = "1", "c(0.1, 0.2)" = "[0.1, 0.2]", "NA" = "simlev._r.fmt.NA_REAL", "'a'" = "'a'")[[tv]])), inputs = QI,
           jl = paste0(J, sprintf("result = D.quantile_regression(y, x, %s)", c("0" = "0", "1" = "1", "c(0.1, 0.2)" = "[0.1, 0.2]", "NA" = "missing", "'a'" = '"a"')[[tv]])))
ref_case("qreg_err_y", "quantile_regression(letters, x)", paste0(P, "result = D.quantile_regression(np.array(list('abc'), dtype=object), X=x)"), inputs = QI,
         jl = paste0(J, 'result = D.quantile_regression(string.(collect("abcdefghijklmnopqrstuvwxyz")), x)'))
ref_case("qreg_err_df", "quantile_regression(y, data.frame(a = x, f = factor(x > 0), g = 'z'))", paste0(P, "result = D.quantile_regression(y, X=pd.DataFrame({'a': x, 'f': pd.Categorical(x > 0), 'g': 'z'}))"), inputs = QI,
         jl = paste0(J, 'result = D.quantile_regression(y, SL.RFrame("a" => x, "f" => string.(x .> 0), "g" => fill("z", length(x))))'))
ref_case("qreg_err_rows", "quantile_regression(y, x[-1])", paste0(P, "result = D.quantile_regression(y, X=x[1:])"), inputs = QI,
         jl = paste0(J, "result = D.quantile_regression(y, x[2:end])"))
ref_case("qreg_err_noreg", "quantile_regression(y, NULL, intercept = FALSE)", paste0(P, "result = D.quantile_regression(y, X=None, intercept=False)"), inputs = QI,
         jl = paste0(J, "result = D.quantile_regression(y, nothing; intercept = false)"))
ref_case("qreg_err_few", "quantile_regression(y[1:2], cbind(x, x2)[1:2, ])", paste0(P, "result = D.quantile_regression(y[:2], X=np.column_stack([x, x2])[:2])"), inputs = QI,
         jl = paste0(J, "result = D.quantile_regression(y[1:2], hcat(x, x2)[1:2, :])"))
ref_case("qreg_err_coll", "quantile_regression(y, cbind(a = x, b = 2 * x, c = 1))", paste0(P, "result = D.quantile_regression(y, X=pd.DataFrame({'a': x, 'b': 2 * x, 'c': 1.0}))"), inputs = QI,
         jl = paste0(J, 'result = D.quantile_regression(y, SL.NamedMat(hcat(x, 2 .* x, ones(length(x))); colnames = ["a", "b", "c"]))'))
ref_case("qreg_err_X", "quantile_regression(y, matrix(letters[1:2], 200, 1))", paste0(P, "result = D.quantile_regression(y, X=np.full((200, 1), 'a', dtype=object))"), inputs = QI,
         jl = paste0(J, 'result = D.quantile_regression(y, fill("a", 200, 1))'))
# Warnung (Optimalität nicht nachgewiesen) bei sehr kurzen MM-Stufen
set.seed(21); wq <- NULL
for (s in 1:400) { n <- sample(8:60, 1); p <- sample(1:3, 1); disc <- runif(1) < 0.5
  X <- matrix(if (disc) sample(0:2, n * (p - 1), TRUE) + 0 else round(rnorm(n * (p - 1)), 1), n)
  yy <- if (disc) sample(0:3, n, TRUE) + 0 else round(rt(n, 2), 1); tau <- sample(c(0.01, 0.03, 0.1, 0.5, 0.9, 0.97, 0.99), 1)
  if (qr(cbind(1, X))$rank < p) next
  w <- tryCatch({ quantile_regression(yy, X, tau, maxit = 1L); NULL }, warning = function(w) TRUE)
  if (isTRUE(w)) { wq <- list(yy = yy, X = X, tau = tau); break } }
if (!is.null(wq)) ref_case("qreg_warn", "quantile_regression(yy, X, tau, maxit = 1L)", paste0(P, "result = D.quantile_regression(yy, X=X, tau=tau, maxit=1)"), inputs = wq,
                          jl = paste0(J, "result = D.quantile_regression(yy, X, tau; maxit = 1)"))

# tail_regression
ref_case("treg_basic", "tail_regression(d1, 'bonds', 'inflation', quantiles = c(0.1, 0.5, 0.9), B = 19, seed = 1)",
         paste0(P, "result = D.tail_regression(d1, 'bonds', 'inflation', quantiles=[0.1, 0.5, 0.9], B=19, seed=1)"), inputs = DA,
         jl = paste0(J, 'result = D.tail_regression(d1, "bonds", "inflation"; quantiles = [0.1, 0.5, 0.9], B = 19, seed = 1)'))
ref_case("treg_multi", "tail_regression(dna, 'stocks', c('inflation', 'zins'), quantiles = 0.25, frequency = 'month', B = 9, block = 3, seed = 2)",
         paste0(P, "result = D.tail_regression(dna, 'stocks', ['inflation', 'zins'], quantiles=0.25, frequency='month', B=9, block=3, seed=2)"), inputs = list(dna = dna),
         jl = paste0(J, 'result = D.tail_regression(dna, "stocks", ["inflation", "zins"]; quantiles = 0.25, frequency = "month", B = 9, block = 3, seed = 2)'))
ref_case("treg_b0", "tail_regression(d1, 'gold', 'zins', B = 0)", paste0(P, "result = D.tail_regression(d1, 'gold', 'zins', B=0)"), inputs = DA,
         jl = paste0(J, 'result = D.tail_regression(d1, "gold", "zins"; B = 0)'))
dsp <- d1; dsp$event <- 0; dsp$event[c(100, 101, 102, 103, 104, 105, 106)] <- 1
ref_case("treg_fail", "tail_regression(dsp, 'stocks', 'event', quantiles = c(0.5), B = 15, seed = 4)",
         paste0(P, "result = D.tail_regression(dsp, 'stocks', 'event', quantiles=[0.5], B=15, seed=4)"), inputs = list(dsp = dsp),
         jl = paste0(J, 'result = D.tail_regression(dsp, "stocks", "event"; quantiles = [0.5], B = 15, seed = 4)'))
ref_case("treg_err", "tail_regression(d1[1:100, ], 'stocks', 'zins')", paste0(P, "result = D.tail_regression(d1.iloc[:100], 'stocks', 'zins')"), inputs = list(d1 = d1[1:100, ]),
         jl = paste0(J, 'result = D.tail_regression(d1, "stocks", "zins")'))

# tail_covar
dp <- d1; dp$port <- 0.6 * dp$stocks / dp$stocks[1] + 0.4 * dp$bonds / dp$bonds[1]
ref_case("covar_basic", "tail_covar(dp, 'port', c('stocks', 'bonds'))", paste0(P, "result = D.tail_covar(dp, 'port', ['stocks', 'bonds'])"), inputs = list(dp = dp),
         jl = paste0(J, 'result = D.tail_covar(dp, "port", ["stocks", "bonds"])'))
ref_case("covar_state", "tail_covar(dp, 'port', c('stocks', 'gold', 'port'), state = c('inflation', 'zins'), q = 0.1, frequency = 'month')",
         paste0(P, "result = D.tail_covar(dp, 'port', ['stocks', 'gold', 'port'], state=['inflation', 'zins'], q=0.1, frequency='month')"), inputs = list(dp = dp),
         jl = paste0(J, 'result = D.tail_covar(dp, "port", ["stocks", "gold", "port"]; state = ["inflation", "zins"], q = 0.1, frequency = "month")'))

# dependence_validate
set.seed(4); n <- 1200
e <- matrix(rnorm(2 * n), ncol = 2) %*% chol(matrix(c(1, .5, .5, 1), 2))
h <- data.frame(us = exp(0.01 * e[, 1]), eu = exp(0.01 * e[, 2]), jp = exp(0.012 * rnorm(n)), infl = rep(c(1, 5, 1), c(400, 400, 400)))
cfg <- bootstrap_config(c(us = "us", eu = "eu"))
PB <- paste0(P, "from simlev import bootstrap as BS\n")
JB <- paste0(J, "BS = SL.Bootstrap\n")
ref_case("valdep", "b <- bootstrap(h, cfg, 'stationary', n = 6, params = list(L = 20), seed = 1, progress = FALSE); dependence_validate(b, h, agg = 5, max_paths = 4)",
         paste0(PB, "cfg = BS.bootstrap_config({'us': 'us', 'eu': 'eu'})\nb = BS.bootstrap(h, cfg, method='stationary', n=6, params={'L': 20}, seed=1, progress=False)\nresult = D.dependence_validate(b, h, agg=5, max_paths=4)"),
         inputs = list(h = h),
         jl = paste0(JB, 'cfg = BS.bootstrap_config(SL.named("us" => "us", "eu" => "eu"))\nb = BS.bootstrap(h, cfg; method = "stationary", n = 6, params = Dict("L" => 20), seed = 1, progress = false)\nresult = D.dependence_validate(b, h; agg = 5, max_paths = 4)'))
ref_case("valdep3", "cfg3 <- bootstrap_config(c(us = 'us', eu = 'eu', jp = 'jp')); b <- bootstrap(h, cfg3, 'iid', n = 3, seed = 2, progress = FALSE); dependence_validate(b, h, agg = 10L, q = 0.2)",
         paste0(PB, "cfg3 = BS.bootstrap_config({'us': 'us', 'eu': 'eu', 'jp': 'jp'})\nb = BS.bootstrap(h, cfg3, method='iid', n=3, seed=2, progress=False)\nresult = D.dependence_validate(b, h, agg=10, q=0.2)"),
         inputs = list(h = h),
         jl = paste0(JB, 'cfg3 = BS.bootstrap_config(SL.named("us" => "us", "eu" => "eu", "jp" => "jp"))\nb = BS.bootstrap(h, cfg3; method = "iid", n = 3, seed = 2, progress = false)\nresult = D.dependence_validate(b, h; agg = 10, q = 0.2)'))
ref_case("valdep_err1", "dependence_validate(list(), h)", paste0(P, "result = D.dependence_validate({}, h)"), inputs = list(h = h[1:5, ]),
         jl = paste0(J, "result = D.dependence_validate(SL.RList(), h)"))
ref_case("valdep_err2", "b <- bootstrap(h, bootstrap_config(c(us = 'us')), 'iid', n = 2, seed = 1, progress = FALSE); dependence_validate(b, h)",
         paste0(PB, "b = BS.bootstrap(h, BS.bootstrap_config({'us': 'us'}), method='iid', n=2, seed=1, progress=False)\nresult = D.dependence_validate(b, h)"), inputs = list(h = h),
         jl = paste0(JB, 'b = BS.bootstrap(h, BS.bootstrap_config(SL.named("us" => "us")); method = "iid", n = 2, seed = 1, progress = false)\nresult = D.dependence_validate(b, h)'))
ref_case("valdep_err3", "b <- bootstrap(h, cfg, 'iid', n = 2, seed = 1, progress = FALSE); dependence_validate(b, h, agg = 100)",
         paste0(PB, "cfg = BS.bootstrap_config({'us': 'us', 'eu': 'eu'})\nb = BS.bootstrap(h, cfg, method='iid', n=2, seed=1, progress=False)\nresult = D.dependence_validate(b, h, agg=100)"), inputs = list(h = h),
         jl = paste0(JB, 'cfg = BS.bootstrap_config(SL.named("us" => "us", "eu" => "eu"))\nb = BS.bootstrap(h, cfg; method = "iid", n = 2, seed = 1, progress = false)\nresult = D.dependence_validate(b, h; agg = 100)'))

# regime_subset
rs <- function(...) { s <- regime_subset(...); list(data = s, episodes = attr(s, "episodes")) }
JS <- paste0(J, "rs(a...; k...) = (s = D.regime_subset(a...; k...); SL.RList(\"data\" => s, \"episodes\" => SL.attrs(s)[\"episodes\"]))\n")
PS <- paste0(P, "def rs(*a, **k):\n    s = D.regime_subset(*a, **k)\n    return {'data': s, 'episodes': s.attrs['episodes']}\n")
hs <- h[1:100, ]; hs$infl <- c(rep(1, 20), rep(5, 30), 1, 1, rep(5, 3), rep(1, 20), rep(5, 25))
ref_case("rsub_basic", "list(rs(hs, 'infl >= 4'), rs(hs, 'infl >= 4', min_run = 10), rs(hs, 'infl < 2 & us > 1'))",
         paste0(PS, "result = [rs(hs, 'infl >= 4'), rs(hs, 'infl >= 4', min_run=10), rs(hs, 'infl < 2 & us > 1')]"), inputs = list(hs = hs),
         jl = paste0(JS, 'result = [rs(hs, "infl >= 4"), rs(hs, "infl >= 4"; min_run = 10), rs(hs, "infl < 2 & us > 1")]'))
hd <- d1[1:60, c("date", "stocks", "regime")]; lg <- c(rep(TRUE, 10), NA, rep(FALSE, 20), rep(TRUE, 29)); lg[45] <- NA
ref_case("rsub_date", "rs(hd, lg, min_run = 5L)", paste0(PS, "result = rs(hd, lg, min_run=5)"), inputs = list(hd = hd, lg = lg),
         jl = paste0(JS, "result = rs(hd, lg; min_run = 5)"))
ref_case("rsub_err1", "regime_subset(hs, 'infl > 10')", paste0(P, "result = D.regime_subset(hs, 'infl > 10')"), inputs = list(hs = hs),
         jl = paste0(J, 'result = D.regime_subset(hs, "infl > 10")'))
ref_case("rsub_err2", "regime_subset(hs, c(TRUE, FALSE))", paste0(P, "result = D.regime_subset(hs, [True, False])"), inputs = list(hs = hs),
         jl = paste0(J, "result = D.regime_subset(hs, [true, false])"))
# regime_subset: Bedingungen in R-Syntax (gemeinsamer Auswerter, Modul rexpr)
hs2 <- hs; hs2$lbl <- ifelse(hs$infl > 3, "hoch", "tief")
RSX <- c("!infl < 4", "infl >= 4 & !is.na(us)", "infl %in% c(5)", "if (TRUE) infl > thr2 else FALSE", "as.character(infl > 4)",
         "infl > 4\n", "infl > 4 # Kommentar", "(us > 1) + (infl > 4) == 2L", "infl > c(1, 6)")
rsq <- function(x) paste0("'", gsub("\n", "\\n", x, fixed = TRUE), "'")
rsj <- function(x) paste0('"', gsub("\n", "\\n", x, fixed = TRUE), '"')
ref_case("rsub_rsyntax", paste0("thr2 <<- 3; list(", paste0("rs(hs, ", vapply(RSX, deparse, ""), ")", collapse = ", "),
                                ", rs(hs, 'infl > mean(infl)', min_run = 3), rs(hs2, 'lbl == \"hoch\" & us > 0.99'))"),
         paste0(PS, "thr2 = 3\nresult = [", paste0("rs(hs, ", vapply(RSX, rsq, ""), ")", collapse = ", "),
                ", rs(hs, 'infl > mean(infl)', min_run=3), rs(hs2, 'lbl == \"hoch\" & us > 0.99')]"), inputs = list(hs = hs, hs2 = hs2),
         jl = paste0(JS, "thr2 = 3\nresult = [", paste0("rs(hs, ", vapply(RSX, rsj, ""), "; env = @__MODULE__)", collapse = ", "),
                     ', rs(hs, "infl > mean(infl)"; min_run = 3), rs(hs2, "lbl == \\"hoch\\" & us > 0.99")]'))
for (k in seq_along(RSE <- c("infl >", "zz > 1", "infl[1] > 0", "infl > 2 &&& us", "lbl > 1")))
  ref_case(sprintf("rsub_rs_err%d", k), sprintf("regime_subset(hs, %s)", deparse(RSE[k])),
           paste0(P, sprintf("result = D.regime_subset(hs, %s)", rsq(RSE[k]))), inputs = list(hs = hs),
           jl = paste0(J, sprintf("result = D.regime_subset(hs, %s)", rsj(RSE[k]))))

ref_done()

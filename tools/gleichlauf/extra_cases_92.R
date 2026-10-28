# Zusatzfaelle der Gleichlaufpruefung, Etappe 9.2 (Entwurf C.8/C.9): Modul "slc_linalg" mit den
# Huellen der Kerne aus 9.2 (.sl_* in R, simlev._lib in Python, SimLev.SLib in Julia): Cholesky,
# Band-Cholesky, Dreiecksloeser, SPD-Loeser, log det, Eigenwerte, Matrixprodukt, kleinste
# Quadrate, Logit-IRLS, Stineman, Glaettungsspline, Kerndichte; je mit Randfaellen (singulaer,
# rangdefizient, fast singulaer, 1x1, leer, NA) und Fehlertexten.
#
# Aufruf aus der Repo-Wurzel (tools/gleichlauf/run.sh setzt SIMLEV_MODULE_DIR):
#   SIMLEV_MODULE_DIR=<ordner> R_LIBS=<R-Bibliothek> Rscript tools/gleichlauf/extra_cases_92.R
# Die Faelle werden immer vollstaendig erzeugt (SIMLEV_GEN_SUBSET gilt hier nicht).
Sys.setenv(SIMLEV_GEN_SUBSET = "1")
source("golden/modules/ref_tools.R")
ref_init("slc_linalg")

P <- "import numpy as np\nimport simlev._lib as L\n"
J <- "const L = SL.SLib\n"
cs <- function(id, r, py, jl, inputs = list())
  ref_case(id, r = paste0("sl <- asNamespace('SimLev')\n", r), py = paste0(P, "result = ", py),
           jl = paste0(J, "result = ", jl), inputs = inputs)

set.seed(9202)
rorth <- function(n) qr.Q(qr(matrix(rnorm(n * n), n)))
spd <- function(n, lc = 2) { Q <- rorth(n); A <- Q %*% diag(10^seq(0, -lc, length.out = n), n) %*% t(Q); (A + t(A)) / 2 }
sym <- function(n) { A <- matrix(rnorm(n * n), n); (A + t(A)) / 2 }

# ── Cholesky, Dreiecksloeser, SPD-Loeser, log det ──
mats <- list(m1 = matrix(4, 1), m3 = spd(3), m7 = spd(7, 6), m20 = spd(20, 9), e0 = matrix(numeric(0), 0, 0),
             sing = matrix(c(1, 2, 2, 4), 2), indef = matrix(c(1, 2, 2, 1), 2), fast = matrix(c(1, 1, 1, 1 + 1e-15), 2),
             na = matrix(c(1, NA, NA, 1), 2), nan = matrix(c(1, NaN, NaN, 1), 2), inf = matrix(c(Inf, 0, 0, 1), 2),
             rect = matrix(1:6 + 0, 2))
for (nm in names(mats)) {
  inp <- list(A = mats[[nm]])
  cs(paste0("chol_", nm), "sl$.sl_chol(A)", "L.chol(A)", "L.chol(A)", inp)
  if (nm %in% c("rect")) next
  n <- nrow(mats[[nm]])
  inp$b <- rnorm(n); inp$B <- matrix(rnorm(n * 2), n)
  cs(paste0("solve_vec_", nm), "sl$.sl_solve_spd(A, b)", "L.solve_spd(A, b)", "L.solve_spd(A, b)", inp)
  cs(paste0("solve_mat_", nm), "sl$.sl_solve_spd(A, B)", "L.solve_spd(A, B)", "L.solve_spd(A, B)", inp)
  cs(paste0("solve_inv_", nm), "sl$.sl_solve_spd(A)", "L.solve_spd(A)", "L.solve_spd(A)", inp)
  cs(paste0("logdet_", nm), "sl$.sl_logdet_spd(A)", "L.logdet_spd(A)", "L.logdet_spd(A)", inp)
}
cs("solve_na_b", "sl$.sl_solve_spd(A, b)", "L.solve_spd(A, b)", "L.solve_spd(A, b)", list(A = spd(3), b = c(1, NA, 2)))
cs("solve_dim", "sl$.sl_solve_spd(A, b)", "L.solve_spd(A, b)", "L.solve_spd(A, b)", list(A = spd(3), b = c(1, 2)))
R6 <- chol(spd(6)); b6 <- rnorm(6); B6 <- matrix(rnorm(18), 6)
for (up in c(TRUE, FALSE)) for (tr in c(TRUE, FALSE)) {
  T6 <- if (up) R6 else t(R6)
  id <- sprintf("backsolve_%s_%s", if (up) "oben" else "unten", if (tr) "trans" else "plain")
  rr <- sprintf("list(sl$.sl_backsolve(T, b, upper.tri = %s, transpose = %s), sl$.sl_backsolve(T, B, upper.tri = %s, transpose = %s))", up, tr, up, tr)
  py <- sprintf("[L.backsolve(T, b, upper_tri=%s, transpose=%s), L.backsolve(T, B, upper_tri=%s, transpose=%s)]",
                if (up) "True" else "False", if (tr) "True" else "False", if (up) "True" else "False", if (tr) "True" else "False")
  jl <- sprintf("Any[L.backsolve(T, b; upper_tri = %s, transpose = %s), L.backsolve(T, B; upper_tri = %s, transpose = %s)]",
                tolower(up), tolower(tr), tolower(up), tolower(tr))
  cs(id, rr, py, jl, list(T = T6, b = b6, B = B6))
}
cs("backsolve_diag0", "sl$.sl_backsolve(T, b)", "L.backsolve(T, b)", "L.backsolve(T, b)", list(T = matrix(c(1, 0, 1, 0), 2), b = c(1, 1)))
cs("backsolve_na", "sl$.sl_backsolve(T, b)", "L.backsolve(T, b)", "L.backsolve(T, b)", list(T = matrix(c(1, 0, 1, 2), 2), b = c(NA, 1)))
cs("backsolve_1x1", "sl$.sl_backsolve(T, b)", "L.backsolve(T, b)", "L.backsolve(T, b)", list(T = matrix(3, 1), b = 2))
ab <- rbind(c(4, 5, 6, 7, 8), c(1, 1, 1, 1, 0), c(0.5, 0.5, 0.5, 0, 0))
cs("chol_band", "sl$.sl_chol_band(AB, 2)", "L.chol_band(AB, 2)", "L.chol_band(AB, 2)", list(AB = ab))
cs("chol_band_indef", "sl$.sl_chol_band(AB, 1)", "L.chol_band(AB, 1)", "L.chol_band(AB, 1)", list(AB = rbind(c(1, 1, 1), c(2, 2, 0))))

# ── Eigenwerte ──
eig <- list(s3 = spd(3), s12 = spd(12, 8), i9 = sym(9), i40 = sym(40), m1 = matrix(-2, 1), e0 = matrix(numeric(0), 0, 0),
            mehrfach = diag(c(2, 2, 1, 2)), sing = matrix(c(1, 2, 2, 4), 2), null = matrix(0, 3, 3),
            unsym = matrix(c(1, 5, 2, 1), 2), na = matrix(c(1, NA, NA, 1), 2), gross = sym(5) * 1e200, klein = sym(5) * 1e-200)
for (nm in names(eig)) {
  cs(paste0("eigen_", nm), "sl$.sl_eigen_sym(A)", "L.eigen_sym(A)", "L.eigen_sym(A)", list(A = eig[[nm]]))
}
cs("eigen_nur_werte", "sl$.sl_eigen_sym(A, only.values = TRUE)", "L.eigen_sym(A, only_values=True)",
   "L.eigen_sym(A; only_values = true)", list(A = sym(6)))

# ── Matrixprodukt ──
A <- matrix(rnorm(35), 5); B <- matrix(rnorm(21), 7); Z <- matrix(rnorm(12), 3)
cs("mm_mat", "sl$.sl_matmul(A, B)", "L.matmul(A, B)", "L.matmul(A, B)", list(A = A, B = B))
cs("mm_gross", "sl$.sl_matmul(A, B)", "L.matmul(A, B)", "L.matmul(A, B)", list(A = matrix(rnorm(40 * 300), 40), B = matrix(rnorm(300 * 3), 300)))
An <- A; An[2, 3] <- NA; An[4, 1] <- Inf; Bn <- B; Bn[5, 2] <- NaN; Bn[1, 1] <- 0
cs("mm_nan", "sl$.sl_matmul(A, B)", "L.matmul(A, B)", "L.matmul(A, B)", list(A = An, B = Bn))
cs("mm_vv", "sl$.sl_matmul(x, y)", "L.matmul(x, y)", "L.matmul(x, y)", list(x = rnorm(4), y = rnorm(4)))
cs("mm_v1", "sl$.sl_matmul(x, y)", "L.matmul(x, y)", "L.matmul(x, y)", list(x = 2.5, y = rnorm(4)))
cs("mm_1v", "sl$.sl_matmul(x, y)", "L.matmul(x, y)", "L.matmul(x, y)", list(x = rnorm(4), y = -1.5))
cs("mm_vM", "sl$.sl_matmul(x, B)", "L.matmul(x, B)", "L.matmul(x, B)", list(x = rnorm(7), B = B))
cs("mm_Mv", "sl$.sl_matmul(A, x)", "L.matmul(A, x)", "L.matmul(A, x)", list(A = A, x = rnorm(7)))
cs("mm_vzeile", "sl$.sl_matmul(x, R1)", "L.matmul(x, R1)", "L.matmul(x, R1)", list(x = rnorm(3), R1 = matrix(rnorm(4), 1)))
cs("mm_leer", "sl$.sl_matmul(A, B)", "L.matmul(A, B)", "L.matmul(A, B)", list(A = matrix(numeric(0), 0, 3), B = matrix(1, 3, 2)))
cs("mm_innen0", "sl$.sl_matmul(A, B)", "L.matmul(A, B)", "L.matmul(A, B)", list(A = matrix(numeric(0), 2, 0), B = matrix(numeric(0), 0, 2)))
cs("mm_fehler", "sl$.sl_matmul(A, A)", "L.matmul(A, A)", "L.matmul(A, A)", list(A = A))
cs("mm_fehler_vv", "sl$.sl_matmul(x, y)", "L.matmul(x, y)", "L.matmul(x, y)", list(x = rnorm(3), y = rnorm(4)))
cs("cp_x", "sl$.sl_crossprod(A)", "L.crossprod(A)", "L.crossprod(A)", list(A = A))
cs("cp_xy", "sl$.sl_crossprod(A, Y)", "L.crossprod(A, Y)", "L.crossprod(A, Y)", list(A = A, Y = matrix(rnorm(10), 5)))
cs("cp_vec", "sl$.sl_crossprod(x)", "L.crossprod(x)", "L.crossprod(x)", list(x = rnorm(6)))
cs("cp_lang", "sl$.sl_crossprod(X)", "L.crossprod(X)", "L.crossprod(X)", list(X = matrix(rnorm(3000 * 4), 3000)))
cs("tcp_x", "sl$.sl_tcrossprod(A)", "L.tcrossprod(A)", "L.tcrossprod(A)", list(A = A))
cs("tcp_xy", "sl$.sl_tcrossprod(A, Z)", "L.tcrossprod(A, Z)", "L.tcrossprod(A, Z)", list(A = matrix(rnorm(20), 5), Z = Z))
cs("tcp_vec", "sl$.sl_tcrossprod(x)", "L.tcrossprod(x)", "L.tcrossprod(x)", list(x = rnorm(4)))
cs("cp_fehler", "sl$.sl_crossprod(A, Z)", "L.crossprod(A, Z)", "L.crossprod(A, Z)", list(A = A, Z = Z))

# ── kleinste Quadrate ──
x <- rnorm(40); z <- rnorm(40); y <- 1 + 2 * x - z + rnorm(40, sd = 0.3)
X3 <- cbind(1, x, z); X6 <- cbind(1, x, 2 * x, z, x + z, rnorm(40)); Xf <- cbind(1, x, x + 1e-9 * rnorm(40))
lsc <- list(voll = list(X3, y, NULL, 1), defizient = list(X6, y, NULL, 1), fast = list(Xf, y, NULL, 1),
            gewichtet = list(X3, y, runif(40, 0.2, 2), 1), gewichte0 = list(X3, y, c(0, 0, runif(38)), 1),
            voll_piv2 = list(X6, y, NULL, 2), eins = list(matrix(2, 1), 3, NULL, 1), breit = list(matrix(rnorm(6), 2), c(1, 2), NULL, 1),
            nullspalte = list(cbind(1, 0, 1:4), c(1, 3, 2, 5), NULL, 1), konst = list(cbind(1, rep(3, 5)), 1:5 + 0, NULL, 1),
            lang = list(cbind(1, rnorm(3000)), rnorm(3000), NULL, 1))
for (nm in names(lsc)) {
  a <- lsc[[nm]]
  inp <- list(X = a[[1]], y = a[[2]]); if (!is.null(a[[3]])) inp$w <- a[[3]]
  wr <- if (is.null(a[[3]])) "NULL" else "w"; wp <- if (is.null(a[[3]])) "None" else "w"; wj <- if (is.null(a[[3]])) "nothing" else "w"
  cs(paste0("lsfit_", nm), sprintf("sl$.sl_lsfit(X, y, %s, pivot = %d)", wr, a[[4]]),
     sprintf("L.lsfit(X, y, %s, pivot=%d)", wp, a[[4]]), sprintf("L.lsfit(X, y; w = %s, pivot = %d)", wj, a[[4]]), inp)
}
cs("lsfit_na", "sl$.sl_lsfit(X, y)", "L.lsfit(X, y)", "L.lsfit(X, y)", list(X = X3, y = replace(y, 3, NA)))
cs("lsfit_nan_x", "sl$.sl_lsfit(X, y)", "L.lsfit(X, y)", "L.lsfit(X, y)", list(X = replace(X3, 5, NaN), y = y))
cs("lsfit_leer", "sl$.sl_lsfit(X, y)", "L.lsfit(X, y)", "L.lsfit(X, y)", list(X = matrix(numeric(0), 0, 2), y = numeric(0)))
cs("lsfit_negw", "sl$.sl_lsfit(X, y, w)", "L.lsfit(X, y, w)", "L.lsfit(X, y; w = w)", list(X = X3, y = y, w = c(-1, rep(1, 39))))
xl <- rnorm(300); yl <- as.numeric(runif(300) < plogis(0.4 - 1.3 * xl))
cs("logit", "sl$.sl_logit_irls(X, y)", "L.logit_irls(X, y)", "L.logit_irls(X, y)", list(X = cbind(1, xl), y = yl))
cs("logit_trennung", "sl$.sl_logit_irls(X, y)", "L.logit_irls(X, y)", "L.logit_irls(X, y)",
   list(X = cbind(1, c(-2, -1, -0.5, 0.5, 1, 2)), y = c(0, 0, 0, 1, 1, 1)))
cs("logit_maxit", "sl$.sl_logit_irls(X, y, maxit = 2)", "L.logit_irls(X, y, maxit=2)", "L.logit_irls(X, y; maxit = 2)",
   list(X = cbind(1, xl), y = yl))
cs("logit_anteil", "sl$.sl_logit_irls(X, y)", "L.logit_irls(X, y)", "L.logit_irls(X, y)", list(X = cbind(1, 1:6 + 0), y = c(0.1, 0.2, 0.5, 0.4, 0.8, 0.9)))
cs("logit_kollinear", "sl$.sl_logit_irls(X, y)", "L.logit_irls(X, y)", "L.logit_irls(X, y)", list(X = cbind(1, xl, 2 * xl), y = yl))
cs("logit_fehler_y", "sl$.sl_logit_irls(X, y)", "L.logit_irls(X, y)", "L.logit_irls(X, y)", list(X = cbind(1, 1:3 + 0), y = c(0, 2, 1)))
cs("logit_fehler_na", "sl$.sl_logit_irls(X, y)", "L.logit_irls(X, y)", "L.logit_irls(X, y)", list(X = cbind(1, 1:3 + 0), y = c(0, NA, 1)))

# ── Stineman ──
xs <- cumsum(runif(30, 0.2, 2)); ys <- cumsum(rnorm(30)); xo <- c(xs[1] - 1, seq(xs[1], xs[30], length.out = 77), xs[30] + 0.5, NA, NaN)
cs("stine", "sl$.sl_stineman(x, y, xo)", "L.stineman(x, y, xo)", "L.stineman(x, y, xo)", list(x = xs, y = ys, xo = xo))
cs("stine_skaliert_aus", "sl$.sl_stineman_slopes(x, y, scale = FALSE)", "L.stineman_slopes(x, y, scale=False)",
   "L.stineman_slopes(x, y; scale = false)", list(x = xs, y = ys * 1e3))
cs("stine_steigungen", "sl$.sl_stineman_slopes(x, y)", "L.stineman_slopes(x, y)", "L.stineman_slopes(x, y)", list(x = xs, y = ys))
cs("stine_eval", "sl$.sl_stineman_eval(x, y, yp, xo)", "L.stineman_eval(x, y, yp, xo)", "L.stineman_eval(x, y, yp, xo)",
   list(x = 1:5 + 0, y = c(1, 3, 2, 2, 5), yp = c(0, 1, -1, 0, 2), xo = seq(1, 5, by = 0.25)))
cs("stine_n1", "sl$.sl_stineman(x, y, xo)", "L.stineman(x, y, xo)", "L.stineman(x, y, xo)", list(x = 2, y = 5, xo = c(1, 2, 3)))
cs("stine_n2", "sl$.sl_stineman(x, y, xo)", "L.stineman(x, y, xo)", "L.stineman(x, y, xo)", list(x = c(1, 3), y = c(1, 4), xo = c(1, 1.5, 3)))
cs("stine_konst", "sl$.sl_stineman(x, y, xo)", "L.stineman(x, y, xo)", "L.stineman(x, y, xo)", list(x = 1:4 + 0, y = rep(7, 4), xo = c(1.5, 3.2)))
cs("stine_monoton", "sl$.sl_stineman(x, y, xo)", "L.stineman(x, y, xo)", "L.stineman(x, y, xo)",
   list(x = c(1, 2, 4, 5, 8, 9), y = c(0, 0, 1, 1, 5, 5.1), xo = seq(1, 9, by = 0.5)))
cs("stine_fehler_x", "sl$.sl_stineman(x, y, xo)", "L.stineman(x, y, xo)", "L.stineman(x, y, xo)", list(x = c(1, 3, 2), y = 1:3 + 0, xo = 2.5))
cs("stine_fehler_y", "sl$.sl_stineman(x, y, xo)", "L.stineman(x, y, xo)", "L.stineman(x, y, xo)", list(x = 1:3 + 0, y = c(1, NA, 3), xo = 2.5))
cs("stine_leer", "sl$.sl_stineman(x, y, xo)", "L.stineman(x, y, xo)", "L.stineman(x, y, xo)", list(x = numeric(0), y = numeric(0), xo = 1))

# ── Glaettungsspline ──
xsp <- rnorm(300, 0, 0.01); ysp <- 2 * xsp + 40 * xsp^2 + rnorm(300, sd = 0.002)
xo <- c(-0.05, seq(min(xsp), max(xsp), length.out = 50), 0.05, NA)
cs("spline_gcv", "f <- sl$.sl_smspline_fit(x, y); list(f, sl$.sl_smspline_predict(f, xo))",
   "f = L.smspline_fit(x, y)\nresult = [f, L.smspline_predict(f, xo)]", "(f = L.smspline_fit(x, y); Any[f, L.smspline_predict(f, xo)])",
   list(x = xsp, y = ysp, xo = xo))
xt <- round(runif(60), 1); yt <- sin(3 * xt) + rnorm(60, sd = 0.1)
cs("spline_bindungen", "sl$.sl_smspline_fit(x, y)", "L.smspline_fit(x, y)", "L.smspline_fit(x, y)", list(x = xt, y = yt))
cs("spline_gewichte", "sl$.sl_smspline_fit(x, y, w)", "L.smspline_fit(x, y, w)", "L.smspline_fit(x, y; w = w)",
   list(x = xsp[1:80], y = ysp[1:80], w = runif(80, 0.5, 2)))
cs("spline_lambda", "sl$.sl_smspline_fit(x, y, lambda = 1e-3)", "L.smspline_fit(x, y, lam=1e-3)", "L.smspline_fit(x, y; lambda = 1e-3)",
   list(x = 1:20 + 0, y = sin(1:20 / 3)))
cs("spline_n4", "sl$.sl_smspline_fit(x, y)", "L.smspline_fit(x, y)", "L.smspline_fit(x, y)", list(x = c(1, 2, 4, 7), y = c(1, 3, 2, 5)))
cs("spline_linear", "sl$.sl_smspline_fit(x, y)", "L.smspline_fit(x, y)", "L.smspline_fit(x, y)", list(x = 1:30 + 0, y = 2 * (1:30) + 1))
xl2 <- rnorm(4000, 0, 0.01)
cs("spline_lang", "f <- sl$.sl_smspline_fit(x, y); list(f$df, f$lambda, f$gcv, sl$.sl_smspline_predict(f, xo))",
   "f = L.smspline_fit(x, y)\nresult = [f['df'], f['lambda'], f['gcv'], L.smspline_predict(f, xo)]",
   "(f = L.smspline_fit(x, y); Any[f[\"df\"], f[\"lambda\"], f[\"gcv\"], L.smspline_predict(f, xo)])",
   list(x = xl2, y = 2 * xl2 + rnorm(4000, sd = 0.002), xo = seq(-0.04, 0.04, by = 0.001)))
cs("spline_fehler_3", "sl$.sl_smspline_fit(x, y)", "L.smspline_fit(x, y)", "L.smspline_fit(x, y)", list(x = c(1, 2, 3, 3), y = 1:4 + 0))
cs("spline_fehler_na", "sl$.sl_smspline_fit(x, y)", "L.smspline_fit(x, y)", "L.smspline_fit(x, y)", list(x = c(1, 2, NA, 4, 5), y = 1:5 + 0))
cs("spline_fehler_w", "sl$.sl_smspline_fit(x, y, w)", "L.smspline_fit(x, y, w)", "L.smspline_fit(x, y; w = w)",
   list(x = 1:5 + 0, y = 1:5 + 0, w = c(1, 0, 1, 1, 1)))

# ── Kerndichte ──
cs("kde", "sl$.sl_kde(x)", "L.kde(x)", "L.kde(x)", list(x = rnorm(500)))
cs("kde_bw", "sl$.sl_bw_silverman(x)", "L.bw_silverman(x)", "L.bw_silverman(x)", list(x = rexp(200)))
cs("kde_gewichte", "sl$.sl_kde(x, weights = w, n = 64)", "L.kde(x, weights=w, n=64)", "L.kde(x; weights = w, n = 64)",
   list(x = rnorm(50), w = rep(1 / 50, 50) * runif(50, 0.5, 1.5)))
cs("kde_grenzen", "sl$.sl_kde(x, bw = 0.3, n = 100, from = -1, to = 1)", "L.kde(x, bw=0.3, n=100, from_=-1.0, to=1.0)",
   "L.kde(x; bw = 0.3, n = 100, from = -1.0, to = 1.0)", list(x = rnorm(100)))
cs("kde_binning", "k <- sl$.sl_kde(x); list(k$bw, k$y)", "k = L.kde(x)\nresult = [k['bw'], k['y']]", "(k = L.kde(x); Any[k[\"bw\"], k[\"y\"]])",
   list(x = rnorm(30000)))
cs("kde_konstant", "sl$.sl_kde(x, n = 16)", "L.kde(x, n=16)", "L.kde(x; n = 16)", list(x = rep(2, 10)))
cs("kde_fehler_n1", "sl$.sl_kde(x)", "L.kde(x)", "L.kde(x)", list(x = 3))
cs("kde_fehler_na", "sl$.sl_kde(x)", "L.kde(x)", "L.kde(x)", list(x = c(1, NA, 3)))
cs("kde_fehler_bw", "sl$.sl_kde(x, bw = -1)", "L.kde(x, bw=-1.0)", "L.kde(x; bw = -1.0)", list(x = c(1, 2, 3)))

ref_done()

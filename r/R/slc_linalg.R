# Huellen der C-Bibliothek slc, Etappe 9.2 (SimLev core): lineare Algebra, Matrixprodukt,
# kleinste Quadrate und Logit-IRLS, Stineman-Interpolation, Glaettungsspline, Kerndichte
# (interne Funktionen .sl_*).
#
# Die Rechnung steht in src/slc_linalg.c, slc_matmul.c, slc_lsq.c, slc_stine.c, slc_spline.c und
# slc_kde.c (Kopien von core/, tools/core_sync.py), die .Call-Huellen in src/slc_r_linalg.c
# (Registrierung in src/init.c, Block 9.2). Gegenstuecke: python/simlev/_lib_linalg.py und
# julia/src/slib_linalg.jl. Fehlertexte und Warnungen kommen aus dem Kern.
#
# Seit Etappe 9.6b sind die Aufrufstellen umgestellt (%m%, .sl_crossprod, .sl_lsfit usw.); dazu
# kommen unten die Host-Rechnungen Welch-Test, Polynom-Kleinstquadrate und r^2 (Entwurf B.7, B.16).

# double-Matrix (Vektor als Spaltenmatrix), dimnames bleiben
.sl_dmat <- function(x) {
  if (!is.matrix(x)) x <- matrix(as.double(x), ncol = 1L)
  else if (!is.double(x)) storage.mode(x) <- "double"
  x
}

.sl_dvec <- function(x) { x <- as.double(x); attributes(x) <- NULL; x }

# ── lineare Algebra ──────────────────────────────────────────────────────────

# chol(x): obere Dreiecksmatrix R mit R'R = x (gelesen wird das obere Dreieck)
.sl_chol <- function(x) {
  x <- .sl_dmat(x)
  r <- .Call(C_sl_chol, x)
  if (!is.null(dimnames(x))) dimnames(r) <- dimnames(x)
  r
}

# backsolve(r, x, upper.tri, transpose) mit k = ncol(r); Vektor bleibt Vektor
.sl_backsolve <- function(r, x, upper.tri = TRUE, transpose = FALSE) {
  r <- .sl_dmat(r)
  vec <- !is.matrix(x)
  b <- .sl_dmat(x)
  out <- .Call(C_sl_trisolve, r, b, as.logical(upper.tri), as.logical(transpose))
  if (vec) .sl_dvec(out) else { dimnames(out) <- NULL; out }
}

.sl_forwardsolve <- function(l, x, upper.tri = FALSE, transpose = FALSE)
  .sl_backsolve(l, x, upper.tri = upper.tri, transpose = transpose)

# solve(a, b) fuer symmetrisch positiv definites a (oberes Dreieck gelesen); ohne b die Inverse
.sl_solve_spd <- function(a, b = NULL) {
  a <- .sl_dmat(a)
  if (is.null(b)) {
    out <- .Call(C_sl_solve_spd, a, diag(1, nrow(a)))
    if (!is.null(dimnames(a))) dimnames(out) <- rev(dimnames(a))
    return(out)
  }
  vec <- !is.matrix(b)
  out <- .Call(C_sl_solve_spd, a, .sl_dmat(b))
  if (vec) .sl_dvec(out) else { dimnames(out) <- list(colnames(a), colnames(b)); out }
}

# log det a fuer symmetrisch positiv definites a (ersetzt determinant(a)$modulus)
.sl_logdet_spd <- function(a) .Call(C_sl_logdet_spd, .sl_dmat(a))

# eigen(x, symmetric = TRUE): absteigend, gelesen wird das untere Dreieck
.sl_eigen_sym <- function(x, only.values = FALSE) {
  x <- .sl_dmat(x)
  .Call(C_sl_eigen_sym, x, !isTRUE(only.values))
}

# Band-Cholesky (Pruefung): ab = (kd + 1) x n, unteres Band spaltenweise
.sl_chol_band <- function(ab, kd) .Call(C_sl_chol_band, .sl_dmat(ab), as.double(kd))

# ── Matrixprodukt ────────────────────────────────────────────────────────────

# x %*% y mit den Vektorregeln von %*% (Entwurf B.6)
.sl_matmul <- function(x, y) {
  if (is.double(x) && is.double(y) && is.matrix(x) && is.matrix(y)) return(.Call(C_sl_matmul, x, y))
  xm <- is.matrix(x); ym <- is.matrix(y)
  if (!xm && !ym) {
    nx <- length(x); ny <- length(y)
    if (nx == ny) { X <- matrix(as.double(x), 1L); Y <- matrix(as.double(y), ncol = 1L) }
    else if (nx == 1L) { X <- matrix(as.double(x), 1L); Y <- matrix(as.double(y), 1L) }
    else if (ny == 1L) { X <- matrix(as.double(x), ncol = 1L); Y <- matrix(as.double(y), 1L) }
    else stop("%m%: nicht passende Argumente", call. = FALSE)
  } else if (!xm) {
    Y <- .sl_dmat(y)
    X <- if (length(x) == nrow(Y)) matrix(as.double(x), 1L)
         else if (nrow(Y) == 1L) matrix(as.double(x), ncol = 1L)
         else stop("%m%: nicht passende Argumente", call. = FALSE)
  } else if (!ym) {
    X <- .sl_dmat(x)
    Y <- if (length(y) == ncol(X)) matrix(as.double(y), ncol = 1L)
         else if (ncol(X) == 1L) matrix(as.double(y), 1L)
         else stop("%m%: nicht passende Argumente", call. = FALSE)
  } else {
    X <- .sl_dmat(x); Y <- .sl_dmat(y)
  }
  .Call(C_sl_matmul, X, Y)        # Fehler und dimnames (rownames(x), colnames(y)) in der Huelle
}

`%m%` <- function(x, y) .sl_matmul(x, y)

# crossprod(x, y) = t(x) %*% y; Vektoren als Spaltenmatrix
.sl_crossprod <- function(x, y = NULL) {
  X <- .sl_dmat(x)
  .Call(C_sl_crossprod, X, if (is.null(y)) X else .sl_dmat(y))   # dimnames: colnames(x), colnames(y)
}

# tcrossprod(x, y) = x %*% t(y)
.sl_tcrossprod <- function(x, y = NULL) {
  X <- .sl_dmat(x)
  .Call(C_sl_tcrossprod, X, if (is.null(y)) X else .sl_dmat(y))  # dimnames: rownames(x), rownames(y)
}

# ── kleinste Quadrate, Logit-IRLS ────────────────────────────────────────────

# lm.fit/lm.wfit/qr.coef: Householder-QR mit begrenzter Spaltenpivotisierung (tol wie lm);
# ausgefallene Koeffizienten NA; pivot 1-basiert
.sl_lsfit <- function(x, y, w = NULL, tol = 1e-7, pivot = 1L) {
  X <- .sl_dmat(x)
  res <- .Call(C_sl_lsfit, X, .sl_dvec(y), if (is.null(w)) NULL else .sl_dvec(w), as.double(tol),
               as.double(pivot))
  if (!is.null(colnames(X))) names(res$coefficients) <- colnames(X)
  res$residuals <- .sl_dvec(y) - res$fitted.values
  res
}

# glm(y ~ x, family = binomial()): Koeffizienten per IRLS (x mit Achsenabschnittsspalte)
.sl_logit_irls <- function(x, y, maxit = 25L, tol = 1e-8) {
  X <- .sl_dmat(x)
  res <- .Call(C_sl_logit_irls, X, .sl_dvec(y), as.double(maxit), as.double(tol))
  if (!is.null(colnames(X))) names(res$coefficients) <- colnames(X)
  res
}

# ── Stineman ─────────────────────────────────────────────────────────────────

# stinterp(x, y, xout) (skaliert); NA ausserhalb [x_1, x_n]
.sl_stineman <- function(x, y, xout) .Call(C_sl_stineman, .sl_dvec(x), .sl_dvec(y), .sl_dvec(xout))

.sl_stineman_slopes <- function(x, y, scale = TRUE)
  .Call(C_sl_stineman_slopes, .sl_dvec(x), .sl_dvec(y), as.logical(scale))

.sl_stineman_eval <- function(x, y, yp, xout)
  .Call(C_sl_stineman_eval, .sl_dvec(x), .sl_dvec(y), .sl_dvec(yp), .sl_dvec(xout))

# ── Glaettungsspline ─────────────────────────────────────────────────────────

# smooth.spline(x, y, w, cv = FALSE): Knoten an allen verschiedenen x, lambda per GCV (NULL)
.sl_smspline_fit <- function(x, y, w = NULL, lambda = NULL)
  .Call(C_sl_smspline_fit, .sl_dvec(x), .sl_dvec(y), if (is.null(w)) NULL else .sl_dvec(w),
        if (is.null(lambda)) 0 else as.double(lambda))

# predict(fit, x)$y; ausserhalb der Knoten lineare Fortsetzung
.sl_smspline_predict <- function(fit, x)
  .Call(C_sl_smspline_predict, fit$x, fit$y, fit$gam, .sl_dvec(x))

# ── Kerndichte ───────────────────────────────────────────────────────────────

# Bandbreite nach Silvermans Faustregel (wie bw.nrd0)
.sl_bw_silverman <- function(x) .Call(C_sl_kde_bw, .sl_dvec(x))

# density(x): Gauss-Kern, n Gitterpunkte von min(x) - cut bw bis max(x) + cut bw
.sl_kde <- function(x, bw = NULL, n = 512L, from = NULL, to = NULL, cut = 3, weights = NULL) {
  x <- .sl_dvec(x)
  if (is.null(bw)) bw <- .sl_bw_silverman(x)
  ok <- length(x) > 0L && all(is.finite(x))       # sonst meldet der Kern den Fehler
  if (is.null(from)) from <- if (ok) min(x) - cut * bw else 0
  if (is.null(to)) to <- if (ok) max(x) + cut * bw else 1
  res <- .Call(C_sl_kde, x, if (is.null(weights)) NULL else .sl_dvec(weights), as.double(bw),
               as.double(n), as.double(from), as.double(to))
  res$bw <- bw
  res$n <- length(x)
  res
}

# ── 9.6b: Rechnungen im Host (Entwurf B.7, B.16; Ausnahmen nach Entscheidung 4) ──

# Welch-Test (Welch 1947; Satterthwaite 1946): t = (mean(x) - mean(y)) / se mit
# se^2 = var(x)/n_x + var(y)/n_y, Freiheitsgrade nu = se^4 / ((var(x)/n_x)^2/(n_x - 1) + (var(y)/n_y)^2/(n_y - 1)),
# p = 2 pt(-|t|, nu) ueber .sl_pt. Ersetzt stats::t.test(x, y) in signal_analysis; bei se = 0 (beide
# Stichproben konstant) sind Statistik und p-Wert NA (t.test bricht dort ab).
.sl_welch_test <- function(x, y) {
  nx <- length(x); ny <- length(y)
  ax <- stats::var(x) / nx; ay <- stats::var(y) / ny
  se2 <- ax + ay
  if (!is.finite(se2) || !(se2 > 0)) return(list(statistic = c(t = NA_real_), parameter = c(df = NA_real_), p.value = NA_real_))
  tt <- (mean(x) - mean(y)) / sqrt(se2)
  nu <- se2^2 / (ax^2 / (nx - 1) + ay^2 / (ny - 1))
  list(statistic = c(t = tt), parameter = c(df = nu), p.value = 2 * .sl_pt(-abs(tt), nu))
}

# Polynom-Kleinstquadrate vom Grad d (ersetzt lm(y ~ poly(x, d))): Basis 1, z, z^2, ..., z^d mit
# z = (x - mean(x)) / sd(x) (Potenzen durch fortgesetztes Multiplizieren), Loesung ueber .sl_lsfit;
# angepasste Werte und r^2 = 1 - RSS/TSS haengen nicht von der Basis ab (Entwurf B.7, B.16).
.sl_poly_fit <- function(x, y, degree) {
  x <- as.double(x); y <- as.double(y); degree <- as.integer(degree)
  cx <- mean(x); sx <- stats::sd(x)
  z <- (x - cx) / sx
  X <- matrix(1, length(z), degree + 1L)
  for (j in seq_len(degree)) X[, j + 1L] <- X[, j] * z
  colnames(X) <- c("(Intercept)", if (degree >= 1L) c("z", if (degree >= 2L) paste0("z^", 2:degree)))
  f <- .sl_lsfit(X, y)
  list(coefficients = f$coefficients, fitted = f$fitted.values, degree = degree,
       basis = c(center = cx, scale = sx), r_squared = .sl_rsq(y, f$residuals))
}

# Bestimmtheitsmass r^2 = 1 - RSS/TSS aus den Residuen (Modell mit Achsenabschnitt)
.sl_rsq <- function(y, res) 1 - sum(res^2) / sum((y - mean(y))^2)

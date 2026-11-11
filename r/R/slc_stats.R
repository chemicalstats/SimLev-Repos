# Huellen der Statistikwege der C-Bibliothek slc (seit 1.6.4, C-035): cov, cor, var, sd, optimize, approx,
# filter, dist und hclust wie in stats, die Rechnung in den Kernen (src/slc_rbase_cov.cpp, slc_rbase.cpp,
# slc_opt_fmin.cpp, slc_rbase_smooth.cpp, slc_rbase_clust.cpp; Kopien von core/, core/sync.py), die
# .Call-Huellen in src/slc_r_stats.cpp (Registrierung in src/init.cpp, in R als C_sl_*).
#
# Bis 1.6.3 rechnete R hier mit R's eigenem C- bzw. Fortran-Code; Python und Julia rechneten dieselben Funktionen
# schon mit den Kernen. R's eigener Code wird ohne -ffp-contract=off uebersetzt und darf auf ARM (aarch64, Apple
# Silicon) Multiplikation und Addition zu fma zusammenziehen, die Kerne nicht. Seit 1.6.4 rechnen alle drei Sprachen
# auf jeder Maschine mit demselben Kern (Entscheidung 121); auf x86-64 sind die Ergebnisse bitgleich zu 1.6.3.
#
# Argumente, Standardwerte, Pruefungen, Rueckgabe und Meldungen wie R 4.3.3 (R-Code der Funktionen uebernommen);
# Fehler und Warnungen nennen denselben Aufruf wie R's Funktion (z. B. "stats::cor(x, y)") und kommen aus R's
# Uebersetzungen (Domaene R-stats fuer den R-Code, stats fuer den C-Code von stats).
#
# Herkunft:           R 4.3.3, src/library/stats/R/cor.R (cor, cov, var), sd.R, optimize.R, approx.R, filter.R,
#                     dist.R, hclust.R
# Rechte:             The R Core Team, teils Robert Gentleman und Ross Ihaka, The R Foundation (laut Kopf der
#                     jeweiligen R-Quelle)
# Lizenz der Vorlage: GPL (>= 2) laut Kopf der R-Quellen; in SimLev unter GPL-3
# Aenderungen:        .Call in die Kerne statt in R's C-/Fortran-Code; stopifnot() als einzelne Pruefungen mit
#                     derselben Meldung (der Aufruf in der Meldung ist sonst der der Huelle).

# ── Meldungen mit dem Aufruf von R's Funktion ────────────────────────────────

# Aufruf fuer Meldungen: wurde die Huelle unter ihrem Namen self gerufen, der Aufruf mit dem Kopf head
# (z. B. stats::cor statt .sl_cor), sonst unveraendert (z. B. FUN(newX[, i], ...) in apply, wie bei R)
.sl_st_call <- function(call, self, head) {
  if (is.call(call) && identical(call[[1L]], as.name(self))) call[[1L]] <- head
  call
}

.sl_st_stop <- function(msg, call) stop(simpleError(msg, call))
.sl_st_warn <- function(msg, call) warning(simpleWarning(msg, call))

# stopifnot(<expr>) mit dem Aufruf call (Meldung wie stopifnot in R 4.3.3: "<expr> is not TRUE")
.sl_st_true <- function(r, txt, call)
  if (!(is.logical(r) && !anyNA(r) && all(r)))
    .sl_st_stop(sprintf(ngettext(length(r), "%s is not TRUE", "%s are not all TRUE", domain = "R-base"), txt), call)

# ── cov / cor / var / sd (stats/R/cor.R, sd.R; Kern sl_r_cov) ──────────────────

# .Call(C_cor bzw. C_cov, x, y, na.method, kendall) mit dem Kern; Meldungen mit call
.sl_corcov <- function(x, y, na.method, kendall, cor, call) {
  r <- if (is.character(x) || is.complex(x) || is.character(y) || is.complex(y))   # Warnungen der Umwandlung in double
    withCallingHandlers(.Call(C_sl_r_corcov, x, y, na.method, kendall, cor),
                        warning = function(w) { .sl_st_warn(conditionMessage(w), call); invokeRestart("muffleWarning") })
  else .Call(C_sl_r_corcov, x, y, na.method, kendall, cor)
  if (is.character(r)) .sl_st_stop(gettext(r, domain = "stats"), call)
  if (r[[2L]]) .sl_st_warn(gettext("the standard deviation is zero", domain = "stats"), call)
  r[[1L]]
}

# Rangtransformation wie in cor/cov
.sl_st_rank <- function(u) {
  if (length(u) == 0L) u
  else if (is.matrix(u)) {
    if (nrow(u) > 1L) apply(u, 2L, rank, na.last = "keep") else row(u)
  } else rank(u, na.last = "keep")
}

.sl_st_use <- c("all.obs", "complete.obs", "pairwise.complete.obs", "everything", "na.or.complete")

#' cor wie stats::cor (Kern sl_r_cov). Gewollte Abweichung von R (Entscheidung 123): bei method = "kendall",
#' use = "everything", ohne y und mit einer Spalte mit NA liest R ein nicht gesetztes Hilfsfeld (cov_na_1) und liefert
#' je nach Speicherinhalt NA mit oder ohne Ruhe-Bit und die Warnung "the standard deviation is zero"; der Kern liefert
#' stilles NA ohne Warnung wie in Python und Julia.
#' @keywords internal
#' @noRd
.sl_cor <- function(x, y = NULL, use = "everything", method = c("pearson", "kendall", "spearman")) {
  call0 <- sys.call(); cl <- function() .sl_st_call(call0, ".sl_cor", quote(stats::cor))
  na.method <- pmatch(use, .sl_st_use)
  if (is.na(na.method)) .sl_st_stop(gettext("invalid 'use' argument", domain = "R-stats"), cl())
  method <- match.arg(method)
  if (is.data.frame(y)) y <- as.matrix(y)
  if (is.data.frame(x)) x <- as.matrix(x)
  if (!is.matrix(x) && is.null(y))
    .sl_st_stop(gettext("supply both 'x' and 'y' or a matrix-like 'x'", domain = "R-stats"), cl())
  if (!(is.numeric(x) || is.logical(x))) .sl_st_stop(gettext("'x' must be numeric", domain = "R-stats"), cl())
  if (!is.atomic(x)) .sl_st_true(FALSE, "is.atomic(x)", cl())
  if (!is.null(y)) {
    if (!(is.numeric(y) || is.logical(y))) .sl_st_stop(gettext("'y' must be numeric", domain = "R-stats"), cl())
    if (!is.atomic(y)) .sl_st_true(FALSE, "is.atomic(y)", cl())
  }
  kendall <- method == "kendall"
  if (method == "pearson")
    .sl_corcov(x, y, na.method, FALSE, TRUE, cl())
  else if (na.method %in% c(2L, 5L)) {
    if (is.null(y)) {
      .sl_corcov(.sl_st_rank(na.omit(x)), NULL, na.method, kendall, TRUE, cl())
    } else {
      nas <- attr(na.omit(cbind(x, y)), "na.action")
      dropNA <- function(x, nas) {
        if (length(nas)) {
          if (is.matrix(x)) x[-nas, , drop = FALSE] else x[-nas]
        } else x
      }
      .sl_corcov(.sl_st_rank(dropNA(x, nas)), .sl_st_rank(dropNA(y, nas)), na.method, kendall, TRUE, cl())
    }
  } else if (na.method != 3L) {
    x <- .sl_st_rank(x)
    if (!is.null(y)) y <- .sl_st_rank(y)
    .sl_corcov(x, y, na.method, kendall, TRUE, cl())
  } else {
    if (is.null(y)) {
      ncy <- ncx <- ncol(x)
      if (ncx == 0) .sl_st_stop(gettext("'x' is empty", domain = "R-stats"), cl())
      r <- matrix(0, nrow = ncx, ncol = ncy)
      for (i in seq_len(ncx)) {
        for (j in seq_len(i)) {
          x2 <- x[, i]
          y2 <- x[, j]
          ok <- complete.cases(x2, y2)
          x2 <- rank(x2[ok])
          y2 <- rank(y2[ok])
          r[i, j] <- if (any(ok)) .sl_corcov(x2, y2, 1L, kendall, TRUE, cl()) else NA
        }
      }
      r <- r + t(r) - diag(diag(r))
      rownames(r) <- colnames(x)
      colnames(r) <- colnames(x)
      r
    } else {
      if (length(x) == 0L || length(y) == 0L)
        .sl_st_stop(gettext("both 'x' and 'y' must be non-empty", domain = "R-stats"), cl())
      matrix_result <- is.matrix(x) || is.matrix(y)
      if (!is.matrix(x)) x <- matrix(x, ncol = 1L)
      if (!is.matrix(y)) y <- matrix(y, ncol = 1L)
      ncx <- ncol(x)
      ncy <- ncol(y)
      r <- matrix(0, nrow = ncx, ncol = ncy)
      for (i in seq_len(ncx)) {
        for (j in seq_len(ncy)) {
          x2 <- x[, i]
          y2 <- y[, j]
          ok <- complete.cases(x2, y2)
          x2 <- rank(x2[ok])
          y2 <- rank(y2[ok])
          r[i, j] <- if (any(ok)) .sl_corcov(x2, y2, 1L, kendall, TRUE, cl()) else NA
        }
      }
      rownames(r) <- colnames(x)
      colnames(r) <- colnames(y)
      if (matrix_result) r else drop(r)
    }
  }
}

#' cov wie stats::cov (Kern sl_r_cov)
#' @keywords internal
#' @noRd
.sl_cov <- function(x, y = NULL, use = "everything", method = c("pearson", "kendall", "spearman")) {
  call0 <- sys.call(); cl <- function() .sl_st_call(call0, ".sl_cov", quote(stats::cov))
  na.method <- pmatch(use, .sl_st_use)
  if (is.na(na.method)) .sl_st_stop(gettext("invalid 'use' argument", domain = "R-stats"), cl())
  method <- match.arg(method)
  if (is.data.frame(y)) y <- as.matrix(y)
  if (is.data.frame(x)) x <- as.matrix(x)
  if (!is.matrix(x) && is.null(y))
    .sl_st_stop(gettext("supply both 'x' and 'y' or a matrix-like 'x'", domain = "R-stats"), cl())
  .sl_st_true(is.numeric(x) || is.logical(x), "is.numeric(x) || is.logical(x)", cl())
  .sl_st_true(is.atomic(x), "is.atomic(x)", cl())
  if (!is.null(y)) {
    .sl_st_true(is.numeric(y) || is.logical(y), "is.numeric(y) || is.logical(y)", cl())
    .sl_st_true(is.atomic(y), "is.atomic(y)", cl())
  }
  kendall <- method == "kendall"
  if (method == "pearson")
    .sl_corcov(x, y, na.method, kendall, FALSE, cl())
  else if (na.method %in% c(2L, 5L)) {
    if (is.null(y)) {
      .sl_corcov(.sl_st_rank(na.omit(x)), NULL, na.method, kendall, FALSE, cl())
    } else {
      nas <- attr(na.omit(cbind(x, y)), "na.action")
      dropNA <- function(x, nas) {
        if (length(nas)) {
          if (is.matrix(x)) x[-nas, , drop = FALSE] else x[-nas]
        } else x
      }
      .sl_corcov(.sl_st_rank(dropNA(x, nas)), .sl_st_rank(dropNA(y, nas)), na.method, kendall, FALSE, cl())
    }
  } else if (na.method != 3L) {
    x <- .sl_st_rank(x)
    if (!is.null(y)) y <- .sl_st_rank(y)
    .sl_corcov(x, y, na.method, kendall, FALSE, cl())
  } else
    .sl_st_stop(gettext("cannot handle 'pairwise.complete.obs'", domain = "R-stats"), cl())
}

# var(x, y, na.rm, use) mit dem Aufruf call in den Meldungen (von .sl_var und .sl_sd)
.sl_var_in <- function(x, y, na.rm, use, call) {
  if (missing(use))
    use <- if (na.rm) "na.or.complete" else "everything"
  na.method <- pmatch(use, .sl_st_use)
  if (is.na(na.method)) .sl_st_stop(gettext("invalid 'use' argument", domain = "R-stats"), call)
  if (is.data.frame(x)) x <- as.matrix(x) else if (!is.atomic(x)) .sl_st_true(FALSE, "is.atomic(x)", call)
  if (is.data.frame(y)) y <- as.matrix(y) else if (!is.atomic(y)) .sl_st_true(FALSE, "is.atomic(y)", call)
  .sl_corcov(x, y, na.method, FALSE, FALSE, call)
}

#' var wie stats::var (Kern sl_r_cov)
#' @keywords internal
#' @noRd
.sl_var <- function(x, y = NULL, na.rm = FALSE, use)
  .sl_var_in(x, y, na.rm, use, .sl_st_call(sys.call(), ".sl_var", quote(stats::var)))

#' sd wie stats::sd (Kern sl_r_cov); Meldungen wie R mit dem inneren Aufruf von var
#' @keywords internal
#' @noRd
.sl_sd <- function(x, na.rm = FALSE)
  sqrt(.sl_var_in(if (is.vector(x) || is.factor(x)) x else as.double(x), NULL, na.rm = na.rm,
                  call = quote(var(if (is.vector(x) || is.factor(x)) x else as.double(x), na.rm = na.rm))))

# ── optimize (stats/R/optimize.R, do_fmin; Kern sl_fmin_*) ─────────────────────

# asReal: erstes Element als double (leer: NA); Warnungen der Umwandlung (Text, komplex) seit 1.6.4 mit dem Aufruf call
# wie do_fmin (T4-B1; bis dahin mit dem Aufruf .sl_st_real1(...))
.sl_st_real1 <- function(v, call) {
  if (is.double(v)) return(if (length(v)) as.double(v[[1L]]) else NA_real_)
  withCallingHandlers(if (length(v)) as.double(v[[1L]]) else NA_real_,
                      warning = function(w) {
                        .sl_st_warn(conditionMessage(w), call)
                        invokeRestart("muffleWarning")
                      })
}

# Texte von fcn1 (do_fmin) mit R's Uebersetzung, erst im Bedarfsfall aus C_sl_fmin geholt
.sl_fmin_msg <- function(i)
  switch(i, gettext("NA replaced by maximum positive value", domain = "stats"),
         gettext("NA/Inf replaced by maximum positive value", domain = "stats"),
         gettext("invalid function value in 'optimize'", domain = "stats"))

# .External2(C_do_fmin, fn, lower, upper, tol) mit dem Kern; Meldungen mit call. Seit 1.6.4 (T4-R5, T4-B1): Umwandeln
# und Pruefen nacheinander wie do_fmin (xmin, xmax, tol), die Schleife mit den Aufrufen von fn in C (C_sl_fmin; bis
# dahin Frage/Antwort je Wert in R)
.sl_fmin <- function(fn, lower, upper, tol, call) {
  xmin <- .sl_st_real1(lower, call)
  if (!is.finite(xmin)) .sl_st_stop(gettextf("invalid '%s' value", "xmin", domain = "stats"), call)
  xmax <- .sl_st_real1(upper, call)
  if (!is.finite(xmax)) .sl_st_stop(gettextf("invalid '%s' value", "xmax", domain = "stats"), call)
  if (xmin >= xmax) .sl_st_stop(gettext("'xmin' not less than 'xmax'", domain = "stats"), call)
  tol <- .sl_st_real1(tol, call)
  if (!is.finite(tol) || tol <= 0) .sl_st_stop(gettextf("invalid '%s' value", "tol", domain = "stats"), call)
  .Call(C_sl_fmin, fn, environment(), xmin, xmax, tol, call, .sl_fmin_msg)
}

#' optimize wie stats::optimize (Brent fmin im Kern sl_fmin_*)
#' @keywords internal
#' @noRd
.sl_optimize <- function(f, interval, ..., lower = min(interval), upper = max(interval), maximum = FALSE,
                         tol = .Machine$double.eps^0.25) {
  if (maximum) {
    val <- .sl_fmin(function(arg) -f(arg, ...), lower, upper, tol,
                    .sl_st_call(sys.call(), ".sl_optimize", quote(stats::optimize)))
    list(maximum = val, objective = f(val, ...))
  } else {
    val <- .sl_fmin(function(arg) f(arg, ...), lower, upper, tol,
                    .sl_st_call(sys.call(), ".sl_optimize", quote(stats::optimize)))
    list(minimum = val, objective = f(val, ...))
  }
}

# ── approx (stats/R/approx.R; Kern sl_r_approx) ─────────────────────────────────

#' approx wie stats::approx (Kern sl_r_approx); regularize.values bleibt R's Funktion (reiner R-Code)
#' @keywords internal
#' @noRd
.sl_approx <- function(x, y = NULL, xout, method = "linear", n = 50, yleft, yright, rule = 1, f = 0, ties = mean,
                       na.rm = TRUE) {
  call0 <- sys.call(); cl <- function() .sl_st_call(call0, ".sl_approx", quote(stats::approx))
  regularize.values <- get("regularize.values", envir = asNamespace("stats"), inherits = FALSE)
  method <- pmatch(method, c("linear", "constant"))
  if (is.na(method)) .sl_st_stop(gettext("invalid interpolation method", domain = "R-stats"), cl())
  .sl_st_true(is.numeric(rule), "is.numeric(rule)", cl())
  .sl_st_true((lenR <- length(rule)) >= 1L, "(lenR <- length(rule)) >= 1L", cl())
  .sl_st_true(lenR <= 2L, "lenR <= 2L", cl())
  if (lenR == 1) rule <- rule[c(1, 1)]
  r <- regularize.values(x, y, ties, missing(ties), na.rm = na.rm)
  y <- r$y
  x <- r$x
  noNA <- na.rm || !r$keptNA
  nx <- if (noNA) length(x) else sum(r$notNA)
  if (is.na(nx)) .sl_st_stop(gettext("invalid length(x)", domain = "R-stats"), cl())
  if (nx <= 1) {
    if (method == 1)
      .sl_st_stop(gettext("need at least two non-NA values to interpolate", domain = "R-stats"), cl())
    if (nx == 0) .sl_st_stop(gettext("zero non-NA points", domain = "R-stats"), cl())
  }
  if (missing(yleft))
    yleft <- if (rule[1L] == 1) NA else y[1L]
  if (missing(yright))
    yright <- if (rule[2L] == 1) NA else y[length(y)]
  .sl_st_true(length(yleft) == 1L, "length(yleft) == 1L", cl())
  .sl_st_true(length(yright) == 1L, "length(yright) == 1L", cl())
  .sl_st_true(length(f) == 1L, "length(f) == 1L", cl())
  if (missing(xout)) {
    if (n <= 0) .sl_st_stop(gettext("'approx' requires n >= 1", domain = "R-stats"), cl())
    xout <- if (noNA) seq.int(x[1L], x[nx], length.out = n)
            else {
              xout <- x[r$notNA]
              seq.int(xout[1L], xout[length(xout)], length.out = n)
            }
  }
  x <- as.double(x); y <- as.double(y)
  yout <- .Call(C_sl_r_approx, x, y, xout, method, yleft, yright, f, na.rm)
  if (is.character(yout)) .sl_st_stop(gettext(yout, domain = "stats"), cl())
  list(x = xout, y = yout)
}

# ── filter (stats/R/filter.R; Kern sl_r_filter_conv/_rec) ──────────────────────

#' filter wie stats::filter (Kern sl_r_filter_conv bzw. sl_r_filter_rec)
#' @keywords internal
#' @noRd
.sl_filter <- function(x, filter, method = c("convolution", "recursive"), sides = 2L, circular = FALSE,
                       init = NULL) {
  call0 <- sys.call(); cl <- function() .sl_st_call(call0, ".sl_filter", quote(stats::filter))
  cfilt <- function(x) {
    r <- .Call(C_sl_r_cfilter, x, filter, sides, circular)
    if (is.character(r)) .sl_st_stop(r, cl())
    r
  }
  rfilt <- function(x, ini) {
    r <- .Call(C_sl_r_rfilter, x, filter, c(ini, double(0L)))
    if (is.character(r)) .sl_st_stop(r, cl())
    r
  }
  method <- match.arg(method)
  x <- as.ts(x)
  storage.mode(x) <- "double"
  xtsp <- tsp(x)
  n <- as.integer(NROW(x))
  if (is.na(n)) .sl_st_stop(gettextf("invalid value of %s", "NROW(x)", domain = "R-stats"), cl())
  nser <- NCOL(x)
  filter <- as.double(filter)
  nfilt <- as.integer(length(filter))
  if (is.na(nfilt)) .sl_st_stop(gettextf("invalid value of %s", "length(filter)", domain = "R-stats"), cl())
  if (anyNA(filter)) .sl_st_stop(gettext("missing values in 'filter'", domain = "R-stats"), cl())
  if (method == "convolution") {
    if (nfilt > n) .sl_st_stop(gettext("'filter' is longer than time series", domain = "R-stats"), cl())
    sides <- as.integer(sides)
    if (is.na(sides) || (sides != 1L && sides != 2L))
      .sl_st_stop(gettext("argument 'sides' must be 1 or 2", domain = "R-stats"), cl())
    circular <- as.logical(circular)
    if (is.na(circular)) .sl_st_stop(gettext("'circular' must be logical and not NA", domain = "R-stats"), cl())
    if (is.matrix(x)) {
      y <- matrix(NA, n, nser)
      for (i in seq_len(nser)) y[, i] <- cfilt(x[, i])
    } else
      y <- cfilt(x)
  } else {
    if (missing(init)) {
      init <- matrix(0, nfilt, nser)
    } else {
      ni <- NROW(init)
      if (ni != nfilt)
        .sl_st_stop(gettext("length of 'init' must equal length of 'filter'", domain = "R-stats"), cl())
      if (NCOL(init) != 1L && NCOL(init) != nser) {
        .sl_st_stop(sprintf(ngettext(nser, "'init' must have %d column", "'init' must have 1 or %d columns",
                                     domain = "R-stats"), nser), cl())
      }
      if (!is.matrix(init)) dim(init) <- c(nfilt, nser)
    }
    if (is.matrix(x)) {
      y <- matrix(NA, n, nser)
      for (i in seq_len(nser)) y[, i] <- rfilt(x[, i], init[, i])
    } else
      y <- rfilt(x, init[, 1L])
  }
  tsp(y) <- xtsp
  class(y) <- if (nser > 1L) c("mts", "ts") else "ts"
  y
}

# ── dist / hclust (stats/R/dist.R, hclust.R; Kern sl_r_dist, sl_r_hclust) ──────

#' dist wie stats::dist (Kern sl_r_dist)
#' @keywords internal
#' @noRd
.sl_dist <- function(x, method = "euclidean", diag = FALSE, upper = FALSE, p = 2) {
  call0 <- sys.call(); cl <- function() .sl_st_call(call0, ".sl_dist", quote(stats::dist))
  if (!is.na(pmatch(method, "euclidian"))) method <- "euclidean"
  METHODS <- c("euclidean", "maximum", "manhattan", "canberra", "binary", "minkowski")
  method <- pmatch(method, METHODS)
  if (is.na(method)) .sl_st_stop(gettext("invalid distance method", domain = "R-stats"), cl())
  if (method == -1) .sl_st_stop(gettext("ambiguous distance method", domain = "R-stats"), cl())
  x <- as.matrix(x)
  N <- nrow(x)
  mc <- .sl_st_call(match.call(), ".sl_dist", quote(stats::dist))
  attrs <- if (method == 6L)
    list(Size = N, Labels = dimnames(x)[[1L]], Diag = diag, Upper = upper, method = METHODS[method], p = p,
         call = mc, class = "dist")
  else list(Size = N, Labels = dimnames(x)[[1L]], Diag = diag, Upper = upper, method = METHODS[method],
            call = mc, class = "dist")
  r <- .Call(C_sl_r_dist, x, method, p)
  if (is.character(r)) .sl_st_stop(gettext(r, domain = "stats"), cl())
  if (r[[2L]]) {
    # R warnt (nur binary) je Spalte und Paar ohne NA, in dem ein Wert nicht endlich ist; der Kern meldet es einmal
    k <- 1
    if (method == 5L && N > 1L) {
      X <- matrix(as.double(x), N)
      a <- colSums(!is.na(X) & !is.finite(X)); b <- colSums(is.finite(X))
      k <- sum(choose(a + b, 2) - choose(b, 2))
    }
    for (i in seq_len(k)) .sl_st_warn(gettext("treating non-finite values as NA", domain = "stats"), cl())
  }
  d <- r[[1L]]
  for (k in seq_along(attrs)) attr(d, names(attrs)[k]) <- attrs[[k]]
  d
}

#' hclust wie stats::hclust (Kern sl_r_hclust statt Fortran hclust/hcass2)
#' @keywords internal
#' @noRd
.sl_hclust <- function(d, method = "complete", members = NULL) {
  call0 <- sys.call(); cl <- function() .sl_st_call(call0, ".sl_hclust", quote(stats::hclust))
  METHODS <- c("ward.D", "single", "complete", "average", "mcquitty", "median", "centroid", "ward.D2")
  if (method == "ward") {
    message(gettext("The \"ward\" method has been renamed to \"ward.D\"; note new \"ward.D2\"", domain = "R-stats"))
    method <- "ward.D"
  }
  i.meth <- pmatch(method, METHODS)
  if (is.na(i.meth))
    .sl_st_stop(paste0(gettext("invalid clustering method", domain = "R-stats"), paste("", method)), cl())
  if (i.meth == -1)
    .sl_st_stop(paste0(gettext("ambiguous clustering method", domain = "R-stats"), paste("", method)), cl())
  n <- as.integer(attr(d, "Size"))
  if (is.null(n)) .sl_st_stop(gettext("invalid dissimilarities", domain = "R-stats"), cl())
  if (is.na(n) || n > 65536L) .sl_st_stop(gettext("size cannot be NA nor exceed 65536", domain = "R-stats"), cl())
  if (n < 2) .sl_st_stop(gettext("must have n >= 2 objects to cluster", domain = "R-stats"), cl())
  len <- as.integer(n * (n - 1) / 2)
  if (length(d) != len) {
    msg <- gettext("dissimilarities of improper length", domain = "R-stats")
    if (length(d) < len) .sl_st_stop(msg, cl()) else .sl_st_warn(msg, cl())
  }
  if (is.null(members)) members <- rep(1, n)
  else if (length(members) != n) .sl_st_stop(gettext("invalid length of members", domain = "R-stats"), cl())
  storage.mode(d) <- "double"
  members <- as.double(members)
  # Pruefung von .Fortran (NAOK = FALSE): Argument 7 members, 10 diss
  if (!all(is.finite(members)))
    .sl_st_stop(gettextf("NA/NaN/Inf in foreign function call (arg %d)", 7L, domain = "R"), cl())
  if (!all(is.finite(d)))
    .sl_st_stop(gettextf("NA/NaN/Inf in foreign function call (arg %d)", 10L, domain = "R"), cl())
  hc <- .Call(C_sl_r_hclust, n, as.integer(i.meth), members, d)
  structure(list(merge = hc[[1L]], height = hc[[2L]], order = hc[[3L]], labels = attr(d, "Labels"),
                 method = METHODS[i.meth], call = .sl_st_call(match.call(), ".sl_hclust", quote(stats::hclust)),
                 dist.method = attr(d, "method")),
            class = "hclust")
}

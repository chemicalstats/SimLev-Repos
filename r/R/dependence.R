# =============================================================================
#  dependence.R  —  Abhaengigkeiten, Tail-Risiko und Drittvariablen
# -----------------------------------------------------------------------------
#  dependence_analysis()   Korrelationen (Pearson, Spearman, Kendall),
#                          empirische Tail-Abhaengigkeit, Exceedance-
#                          Korrelationen, Copula-Fits, rollierende Korrelation,
#                          DCC(1,1) und bedingte Analyse nach Regimen von
#                          Drittvariablen (Inflation, Zinsen, Spreads, ...)
#                          mit Block-Bootstrap-Konfidenzintervallen
#  fit_copula()            Gauss, t, Clayton, Gumbel, Frank inkl. Rotationen
#                          (pseudo-ML auf Raengen, Auswahl per AIC)
#  tail_dependence()       empirische Tail-Koeffizienten und Exceedance-
#                          Korrelationen je Quantil
#  dcc_fit()               DCC(1,1) nach Engle (2002), Kern in C++
#  quantile_reg()          lineare Quantilsregression (MM-Algorithmus,
#                          Hunter & Lange 2000)
#  tail_regression()       Renditequantile in Abhaengigkeit von Drittvariablen
#  covar_analysis()        CoVaR / Delta-CoVaR (Adrian & Brunnermeier 2016)
#  validate_dependence()   erhalten Bootstrap-Pfade die historische
#                          Abhaengigkeitsstruktur?
#  regime_subset()         Zeilen eines Regimes fuer Stress-Bootstraps
#
#  Alles ohne Zusatzpakete; rugarch wird fuer die univariaten GARCH-Fits der
#  DCC-Stufe genutzt, falls installiert (sonst optim, wie im Bootstrap).
#  Drittvariablen gehen immer verzoegert ein: Die Rendite der Periode t wird
#  dem Zustand zugeordnet, der am Ende der Periode t - 1 bekannt war. Fuer
#  Makrodaten mit Veroeffentlichungsverzug vorher align_macro() verwenden.
# =============================================================================

# ─────────────────────────────────────────────────────────────────────────────
# Renditen und Pseudo-Beobachtungen
# ─────────────────────────────────────────────────────────────────────────────

#' Periodenrenditen und verzoegerte Zustandsvariablen
#' @keywords internal
.dep_returns <- function(data, assets, conditions = NULL, frequency = "week", drop_flat = TRUE) {
  if (!is.data.frame(data) || !"date" %in% names(data)) stop("data.frame mit Spalte 'date' erwartet.")
  miss <- setdiff(c(assets, conditions), names(data))
  if (length(miss)) stop(sprintf("Spalten fehlen: %s", paste(miss, collapse = ", ")))
  d <- as.Date(data$date)
  end <- if (frequency == "day") seq_along(d) else {
    key <- if (frequency == "week") format(d, "%G-%V") else format(d, "%Y-%m")
    which(c(key[-1] != key[-length(key)], TRUE))
  }
  V <- vapply(assets, function(a) .fill_na(as.numeric(data[[a]]), "locf", keep_leading = TRUE), numeric(nrow(data)))
  if (!is.matrix(V)) V <- matrix(V, ncol = length(assets))
  V <- V[end, , drop = FALSE]
  R <- diff(log(V))
  out <- data.frame(date = d[end][-1], R, check.names = FALSE)
  names(out)[-1] <- assets
  for (cn in conditions) {
    cv <- .fill_na(as.numeric(data[[cn]]), "locf", keep_leading = TRUE)[end]
    out[[cn]] <- cv[-length(cv)]                     # Zustand am Ende der Vorperiode
  }
  ok <- stats::complete.cases(out[, assets, drop = FALSE])
  if (drop_flat && frequency == "day") ok <- ok & rowSums(abs(as.matrix(out[, assets, drop = FALSE])) > 0) > 0
  out <- out[ok, , drop = FALSE]
  rownames(out) <- NULL
  out
}

#' Pseudo-Beobachtungen (Raenge / (n + 1))
#' @keywords internal
.pobs <- function(x) rank(x, ties.method = "average") / (length(x) + 1)

# ─────────────────────────────────────────────────────────────────────────────
# Copulas
# ─────────────────────────────────────────────────────────────────────────────

#' Log-Dichte einer Copula (Summe), Familien inkl. Rotationen
#' @keywords internal
.cop_ll <- function(family, par, u, v) {
  rot <- sub("^[a-z]+_?", "", family); base <- sub("_.*$", "", family)
  if (rot == "180") { u <- 1 - u; v <- 1 - v } else if (rot == "90") u <- 1 - u else if (rot == "270") v <- 1 - v
  ll <- switch(base,
    gaussian = {
      r <- par[1]; x <- stats::qnorm(u); y <- stats::qnorm(v)
      -0.5 * log(1 - r^2) - (r^2 * (x^2 + y^2) - 2 * r * x * y) / (2 * (1 - r^2))
    },
    t = {
      r <- par[1]; nu <- par[2]; x <- stats::qt(u, nu); y <- stats::qt(v, nu)
      lgamma((nu + 2) / 2) + lgamma(nu / 2) - 2 * lgamma((nu + 1) / 2) - 0.5 * log(1 - r^2) -
        (nu + 2) / 2 * log1p((x^2 - 2 * r * x * y + y^2) / (nu * (1 - r^2))) +
        (nu + 1) / 2 * (log1p(x^2 / nu) + log1p(y^2 / nu))
    },
    clayton = {
      th <- par[1]
      log1p(th) - (1 + th) * (log(u) + log(v)) - (2 + 1 / th) * log(u^(-th) + v^(-th) - 1)
    },
    gumbel = {
      th <- par[1]; a <- -log(u); b <- -log(v); A <- a^th + b^th; A1 <- A^(1 / th)
      -A1 + a + b + (th - 1) * (log(a) + log(b)) + (2 / th - 2) * log(A) + log1p((th - 1) / A1)
    },
    frank = {
      th <- par[1]
      if (abs(th) < 1e-8) return(0)
      e1 <- -expm1(-th)
      log(th * e1) - th * (u + v) - 2 * log(abs(e1 - (-expm1(-th * u)) * (-expm1(-th * v))))
    },
    stop(sprintf("Unbekannte Copula-Familie '%s'.", family)))
  s <- sum(ll)
  if (!is.finite(s)) -1e10 else s
}

#' Tail-Koeffizienten einer Copula (unten, oben)
#' @keywords internal
.cop_lambda <- function(family, par) {
  rot <- sub("^[a-z]+_?", "", family); base <- sub("_.*$", "", family)
  lam <- switch(base,
    gaussian = c(0, 0), frank = c(0, 0),
    t = rep(2 * stats::pt(-sqrt((par[2] + 1) * (1 - par[1]) / (1 + par[1])), par[2] + 1), 2),
    clayton = c(2^(-1 / par[1]), 0),
    gumbel = c(0, 2 - 2^(1 / par[1])))
  if (rot == "180") lam <- rev(lam)
  if (rot %in% c("90", "270")) lam <- c(0, 0)
  stats::setNames(lam, c("lower", "upper"))
}

#' Copulas an zwei Reihen anpassen
#'
#' Pseudo-Maximum-Likelihood auf Raengen (Genest, Ghoudi & Rivest 1995) fuer
#' Gauss-, t-, Clayton-, Gumbel- und Frank-Copula. Clayton und Gumbel erfassen
#' asymmetrische Tails: Clayton die gemeinsamen Abstuerze (unterer Tail),
#' Gumbel gemeinsame Anstiege; die um 180 Grad rotierten Varianten jeweils
#' umgekehrt. Bei negativer Abhaengigkeit (z. B. Aktien und Anleihen in
#' Deflationsphasen) werden die um 90/270 Grad rotierten Varianten verwendet.
#'
#' @param x,y Numerische Vektoren gleicher Laenge (Renditen; nur die Raenge
#'   zaehlen).
#' @param families Familien (Standard: passend zum Vorzeichen von Kendalls Tau).
#' @return data.frame je Familie: \code{family}, \code{par1}, \code{par2},
#'   \code{loglik}, \code{aic}, \code{bic}, \code{lambda_lower},
#'   \code{lambda_upper} (implizite Tail-Abhaengigkeit), sortiert nach AIC.
#' @references Genest, C., Ghoudi, K. & Rivest, L.-P. (1995), Biometrika
#'   82(3); Joe, H. (2014), Dependence Modeling with Copulas.
#' @examples
#' set.seed(1); z <- matrix(rnorm(2000), ncol = 2) %*% chol(matrix(c(1, .6, .6, 1), 2))
#' w <- sqrt(rchisq(1000, 4) / 4); x <- z[, 1] / w; y <- z[, 2] / w   # t-Abhaengigkeit
#' fit_copula(x, y)[, c("family", "par1", "par2", "aic", "lambda_lower")]
#' @export
fit_copula <- function(x, y, families = NULL) {
  ok <- is.finite(x) & is.finite(y); x <- x[ok]; y <- y[ok]
  n <- length(x)
  if (n < 20) stop("fit_copula: mindestens 20 Beobachtungen noetig.")
  u <- .pobs(x); v <- .pobs(y)
  tau <- stats::cor(x, y, method = "kendall")
  if (is.null(families)) families <- if (tau >= 0)
    c("gaussian", "t", "clayton", "gumbel", "frank", "clayton_180", "gumbel_180")
    else c("gaussian", "t", "frank", "clayton_90", "clayton_270", "gumbel_90", "gumbel_270")
  rho0 <- sin(pi * tau / 2); at <- abs(tau)
  fit1 <- function(fam) {
    base <- sub("_.*$", "", fam)
    f <- function(p) -.cop_ll(fam, p, u, v)
    res <- switch(base,
      gaussian = { o <- stats::optimize(function(r) f(r), c(-0.995, 0.995)); list(par = c(o$minimum, NA), nll = o$objective, k = 1) },
      t = {
        o <- stats::optim(c(atanh(max(min(rho0, 0.95), -0.95)), log(6)),
                          function(th) f(c(tanh(th[1]), 2 + exp(th[2]))), method = "Nelder-Mead",
                          control = list(maxit = 500, reltol = 1e-10))
        nu <- min(2 + exp(o$par[2]), 500)
        list(par = c(tanh(o$par[1]), nu), nll = o$value, k = 2)
      },
      clayton = { o <- stats::optimize(function(lt) f(exp(lt)), c(log(1e-4), log(60))); list(par = c(exp(o$minimum), NA), nll = o$objective, k = 1) },
      gumbel = { o <- stats::optimize(function(lt) f(1 + exp(lt)), c(log(1e-5), log(60))); list(par = c(1 + exp(o$minimum), NA), nll = o$objective, k = 1) },
      frank = { o <- stats::optimize(function(th) f(th), c(-60, 60)); list(par = c(o$minimum, NA), nll = o$objective, k = 1) })
    lam <- .cop_lambda(fam, res$par)
    data.frame(family = fam, par1 = res$par[1], par2 = res$par[2], loglik = -res$nll,
               aic = 2 * res$k + 2 * res$nll, bic = log(n) * res$k + 2 * res$nll,
               lambda_lower = lam[1], lambda_upper = lam[2], stringsAsFactors = FALSE)
  }
  out <- do.call(rbind, lapply(families, fit1))
  out <- out[order(out$aic), , drop = FALSE]; rownames(out) <- NULL
  attr(out, "tau") <- tau; attr(out, "n") <- n
  out
}

#' Empirische Tail-Abhaengigkeit und Exceedance-Korrelationen
#'
#' \deqn{\hat\lambda_L(q) = \frac{\#\{u_i \le q, v_i \le q\}}{n q}, \quad
#'       \hat\lambda_U(q) = \frac{\#\{u_i > 1 - q, v_i > 1 - q\}}{n q}}
#' auf Pseudo-Beobachtungen. Unter Unabhaengigkeit ist
#' \eqn{\hat\lambda(q) \approx q}, bei Gauss-Abhaengigkeit faellt es fuer
#' \eqn{q \to 0} gegen 0, bei echter Tail-Abhaengigkeit bleibt es positiv.
#' Die Exceedance-Korrelation (Longin & Solnik 2001) ist die Korrelation der
#' Beobachtungen, in denen beide Reihen unter (bzw. ueber) ihrem q-Quantil
#' liegen.
#'
#' @param x,y Numerische Vektoren.
#' @param q Quantile.
#' @return data.frame je \code{q}: \code{lower}, \code{upper},
#'   \code{exceed_lower}, \code{exceed_upper}, \code{n_lower}, \code{n_upper}.
#' @references Longin, F. & Solnik, B. (2001), Journal of Finance 56(2).
#' @export
tail_dependence <- function(x, y, q = c(0.01, 0.025, 0.05, 0.10, 0.20)) {
  ok <- is.finite(x) & is.finite(y); x <- x[ok]; y <- y[ok]; n <- length(x)
  u <- .pobs(x); v <- .pobs(y)
  qx <- function(p) stats::quantile(x, p, names = FALSE); qy <- function(p) stats::quantile(y, p, names = FALSE)
  ec <- function(s) if (sum(s) >= 8 && stats::sd(x[s]) > 0 && stats::sd(y[s]) > 0) stats::cor(x[s], y[s]) else NA_real_
  do.call(rbind, lapply(q, function(p) {
    lo <- u <= p & v <= p; hi <- u > 1 - p & v > 1 - p
    el <- x <= qx(p) & y <= qy(p); eh <- x >= qx(1 - p) & y >= qy(1 - p)
    data.frame(q = p, lower = sum(lo) / (n * p), upper = sum(hi) / (n * p),
               exceed_lower = ec(el), exceed_upper = ec(eh), n_lower = sum(lo), n_upper = sum(hi))
  }))
}

# ─────────────────────────────────────────────────────────────────────────────
# DCC
# ─────────────────────────────────────────────────────────────────────────────

#' DCC(1,1)-Modell (Engle 2002)
#'
#' Zweistufige Schaetzung: univariate GARCH(1,1) je Reihe (wie im Bootstrap:
#' rugarch falls installiert, sonst optim), danach die Korrelationsdynamik
#' \deqn{Q_t = (1 - a - b)\bar Q + a z_{t-1} z_{t-1}' + b Q_{t-1}}
#' per Quasi-Maximum-Likelihood (Filter in C++).
#'
#' @param R Renditematrix (Zeilen = Zeit, Spalten = Reihen, mindestens zwei).
#' @return Liste mit \code{a}, \code{b}, \code{loglik}, \code{correlation}
#'   (Matrix Zeit x Paare), \code{pairs}, \code{garch} (Parameter je Reihe),
#'   \code{z} (standardisierte Residuen).
#' @references Engle, R. (2002), Journal of Business & Economic Statistics
#'   20(3), 339-350.
#' @export
dcc_fit <- function(R) {
  R <- as.matrix(R)
  if (ncol(R) < 2 || nrow(R) < 100) stop("dcc_fit: mindestens zwei Reihen und 100 Beobachtungen.")
  nm <- colnames(R) %||% paste0("V", seq_len(ncol(R)))
  g <- lapply(seq_len(ncol(R)), function(j) .fit_garch11(R[, j], quiet = TRUE))
  Z <- vapply(g, `[[`, numeric(nrow(R)), "z")
  Qb <- stats::cor(Z)
  par <- function(th) { s <- 0.999 * stats::plogis(th[1]); a <- s * stats::plogis(th[2]); c(a, s - a) }
  f <- function(th) { p <- par(th); .dcc_filter(Z, p[1], p[2], Qb, FALSE)$nll }
  st <- c(stats::qlogis(0.98 / 0.999), stats::qlogis(0.03 / 0.98))
  o <- stats::optim(st, f, method = "Nelder-Mead", control = list(maxit = 2000, reltol = 1e-10))
  p <- par(o$par)
  fl <- .dcc_filter(Z, p[1], p[2], Qb, TRUE)
  pn <- utils::combn(nm, 2, paste, collapse = " ~ ")
  C <- fl$R; colnames(C) <- pn
  list(a = p[1], b = p[2], loglik = -o$value, correlation = C, pairs = pn,
       garch = data.frame(series = nm, alpha = vapply(g, `[[`, 0, "alpha"), beta = vapply(g, `[[`, 0, "beta"),
                          method = vapply(g, `[[`, "", "method")), z = Z, Qbar = Qb)
}

# ─────────────────────────────────────────────────────────────────────────────
# Bedingte Analyse
# ─────────────────────────────────────────────────────────────────────────────

#' Regime aus einer Zustandsvariable
#' @keywords internal
.dep_regimes <- function(cv, breaks = NULL, n_regimes = 3L) {
  if (is.null(breaks)) {
    qs <- stats::quantile(cv, seq(0, 1, length.out = n_regimes + 1L), na.rm = TRUE, names = FALSE)
    qs[1] <- -Inf; qs[length(qs)] <- Inf
    breaks <- unique(qs)
  }
  lab <- vapply(seq_len(length(breaks) - 1L), function(i) {
    a <- breaks[i]; b <- breaks[i + 1L]
    if (!is.finite(a)) sprintf("< %s", format(signif(b, 3))) else if (!is.finite(b)) sprintf(">= %s", format(signif(a, 3)))
    else sprintf("%s bis %s", format(signif(a, 3)), format(signif(b, 3)))
  }, "")
  f <- cut(cv, breaks, labels = lab, right = FALSE)
  list(regime = f, breaks = breaks)
}

#' Korrelationen je Regime fuer alle Paare (Pearson, Spearman) als Matrix
#' @keywords internal
.dep_reg_cor <- function(X, reg, levels, pairs, rank = FALSE) {
  vapply(levels, function(l) {
    s <- which(reg == l)
    if (length(s) < 10) return(rep(NA_real_, nrow(pairs)))
    Y <- X[s, , drop = FALSE]; if (rank) Y <- apply(Y, 2, rank)
    C <- suppressWarnings(stats::cor(Y))
    C[pairs]
  }, numeric(nrow(pairs)))
}

#' Abhaengigkeitsanalyse mit Tail-Risiko und Drittvariablen
#'
#' Untersucht die Abhaengigkeit zwischen Anlagen (Kursreihen) ueber die reine
#' Korrelation hinaus: Rangkorrelationen, empirische Tail-Abhaengigkeit,
#' Exceedance-Korrelationen, die am besten passende Copula je Paar,
#' rollierende Korrelation und DCC. Mit \code{conditions} wird zusaetzlich
#' gefragt, wie sich die Abhaengigkeit mit dem Zustand von Drittvariablen
#' aendert - etwa die Aktien-Anleihen-Korrelation bei hoher gegenueber
#' niedriger Inflation oder bei steigenden gegenueber fallenden Zinsen.
#' Unterschiede zwischen Regimen werden mit einem stationaeren
#' Block-Bootstrap abgesichert (Standardtests unterschaetzen bei
#' autokorrelierten Reihen die Unsicherheit).
#'
#' @param data data.frame mit \code{date}, Kursspalten und Zustandsspalten
#'   (z. B. mit [align_series()] und [align_macro()] vorbereitet).
#' @param assets Kursspalten (mindestens zwei).
#' @param conditions Zustandsspalten (Drittvariablen); gehen verzoegert ein.
#' @param frequency \code{"week"} (Standard; vermeidet Effekte
#'   unterschiedlicher Handelszeiten), \code{"day"} oder \code{"month"}.
#' @param quantiles Quantile fuer die Tail-Kennzahlen.
#' @param breaks Optional benannte Liste von Grenzen je Zustandsvariable,
#'   z. B. \code{list(inflation = c(-Inf, 2, 4, Inf))}; sonst
#'   \code{n_regimes} Quantilsgruppen.
#' @param n_regimes Anzahl Regime ohne \code{breaks} (Standard 3: niedrig,
#'   mittel, hoch).
#' @param window Fenster der rollierenden Korrelation in Perioden (Standard:
#'   ein Jahr).
#' @param dcc DCC(1,1) schaetzen.
#' @param copulas Copula-Fits je Paar.
#' @param B Bootstrap-Wiederholungen fuer die Regime-Vergleiche (0 = aus).
#' @param block Mittlere Blocklaenge (Standard: Politis-White auf dem Produkt
#'   der standardisierten Renditen).
#' @param tail_q Quantil fuer die Tail-Kennzahlen je Regime.
#' @param seed Startwert (globaler Zufallszustand bleibt unveraendert).
#' @return Objekt der Klasse \code{SimLevDependence} mit \code{returns},
#'   \code{correlation} (Liste der Matrizen), \code{pairs} (Kennzahlen je Paar),
#'   \code{tail} (empirische Tail-Kennzahlen je Paar und Quantil),
#'   \code{copulas} (alle Fits je Paar), \code{rolling}, \code{dcc},
#'   \code{conditional} (je Zustandsvariable: Kennzahlen je Paar und Regime)
#'   und \code{differences} (oberstes minus unterstes Regime mit
#'   Bootstrap-Intervall und p-Wert). Methoden \code{print} und \code{plot}.
#' @examples
#' \donttest{
#' set.seed(1); n <- 3000
#' d <- data.frame(date = seq.Date(as.Date("2010-01-01"), by = "day", length.out = n))
#' infl <- 2 + cumsum(rnorm(n, 0, 0.05))
#' e1 <- rnorm(n); e2 <- rnorm(n)
#' rho <- ifelse(infl > 2, 0.5, -0.3)                       # Korrelation haengt am Zustand
#' d$stocks <- 100 * exp(cumsum(0.01 * e1))
#' d$bonds <- 100 * exp(cumsum(0.005 * (rho * e1 + sqrt(1 - rho^2) * e2)))
#' d$inflation <- infl
#' da <- dependence_analysis(d, c("stocks", "bonds"), conditions = "inflation", B = 99, seed = 1)
#' da
#' }
#' @export
dependence_analysis <- function(data, assets, conditions = NULL, frequency = c("week", "day", "month"),
                                quantiles = c(0.05, 0.10), breaks = NULL, n_regimes = 3L, window = NULL,
                                dcc = TRUE, copulas = TRUE, B = 499L, block = NULL, tail_q = 0.10, seed = NULL) {
  frequency <- match.arg(frequency)
  if (length(assets) < 2) stop("dependence_analysis: mindestens zwei Anlagen.")
  rd <- .dep_returns(data, assets, conditions, frequency)
  X <- as.matrix(rd[, assets, drop = FALSE]); n <- nrow(X)
  if (n < 30) stop(sprintf("dependence_analysis: nur %d Perioden.", n))
  ppy <- (n - 1) / (as.numeric(rd$date[n] - rd$date[1]) / 365.25)
  window <- window %||% max(10L, round(ppy))
  cors <- list(pearson = stats::cor(X), spearman = stats::cor(X, method = "spearman"),
               kendall = stats::cor(X, method = "kendall"))
  pidx <- t(utils::combn(length(assets), 2)); pn <- apply(pidx, 1, function(p) paste(assets[p], collapse = " ~ "))
  tails <- lapply(seq_len(nrow(pidx)), function(i) cbind(pair = pn[i], tail_dependence(X[, pidx[i, 1]], X[, pidx[i, 2]], quantiles)))
  cops <- if (copulas) lapply(seq_len(nrow(pidx)), function(i) fit_copula(X[, pidx[i, 1]], X[, pidx[i, 2]])) else NULL
  if (!is.null(cops)) names(cops) <- pn
  ptab <- data.frame(pair = pn, pearson = cors$pearson[pidx], spearman = cors$spearman[pidx], kendall = cors$kendall[pidx],
                     stringsAsFactors = FALSE)
  for (q in quantiles) {
    ptab[[sprintf("lambda_lower_%g", q)]] <- vapply(tails, function(t) t$lower[t$q == q], 0)
    ptab[[sprintf("lambda_upper_%g", q)]] <- vapply(tails, function(t) t$upper[t$q == q], 0)
  }
  if (!is.null(cops)) {
    ptab$copula <- vapply(cops, function(c) c$family[1], "")
    ptab$copula_lambda_lower <- vapply(cops, function(c) c$lambda_lower[1], 0)
    ptab$copula_lambda_upper <- vapply(cops, function(c) c$lambda_upper[1], 0)
    tf <- lapply(cops, function(c) c[c$family == "t", ])
    ptab$t_rho <- vapply(tf, `[[`, 0, "par1"); ptab$t_nu <- vapply(tf, `[[`, 0, "par2")
  }
  # rollierende Korrelation
  roll <- NULL
  if (n > window) {
    roll <- data.frame(date = rd$date)
    for (i in seq_len(nrow(pidx))) {
      x <- X[, pidx[i, 1]]; y <- X[, pidx[i, 2]]
      m <- function(v) .roll_mean(v, window)
      cv <- m(x * y) - m(x) * m(y); vx <- m(x^2) - m(x)^2; vy <- m(y^2) - m(y)^2
      roll[[pn[i]]] <- cv / sqrt(pmax(vx * vy, 1e-300))
    }
  }
  dc <- if (dcc && n >= 100) tryCatch(dcc_fit(X), error = function(e) { message("DCC nicht geschaetzt: ", conditionMessage(e)); NULL }) else NULL
  # bedingte Analyse
  cond <- diffs <- regimes <- NULL
  if (length(conditions)) {
    if (is.null(block)) {
      bl <- vapply(seq_len(nrow(pidx)), function(i) {
        x <- scale(X[, pidx[i, 1]])[, 1]; y <- scale(X[, pidx[i, 2]])[, 1]; .pw_block(x * y)[["stationary"]] }, 0)
      block <- min(max(2, max(bl)), n / 10)
    }
    cond <- list(); diffs <- list(); regimes <- list()
    for (cn in conditions) {
      cv <- rd[[cn]]; keep <- which(is.finite(cv))
      if (length(keep) < 30) { warning(sprintf("Zustand '%s': zu wenige Beobachtungen.", cn)); next }
      rg <- .dep_regimes(cv[keep], breaks[[cn]], n_regimes)
      lv <- levels(rg$regime); Xk <- X[keep, , drop = FALSE]; rk <- rg$regime
      regimes[[cn]] <- data.frame(regime = lv, n = as.integer(table(rk)[lv]),
                                  mean_state = vapply(lv, function(l) mean(cv[keep][rk == l]), 0))
      rows <- list()
      for (i in seq_len(nrow(pidx))) for (l in lv) {
        s <- which(rk == l); x <- Xk[s, pidx[i, 1]]; y <- Xk[s, pidx[i, 2]]
        td <- if (length(s) >= 20) tail_dependence(x, y, tail_q) else NULL
        fams <- if (stats::cor(x, y, method = "kendall") < 0) c("t", "gaussian", "clayton_90", "clayton_270")
                else c("t", "gaussian", "clayton", "gumbel")
        tc <- if (copulas && length(s) >= 40) tryCatch(fit_copula(x, y, fams), error = function(e) NULL) else NULL
        tt <- if (!is.null(tc)) tc[tc$family == "t", ] else NULL
        rows[[length(rows) + 1L]] <- data.frame(
          pair = pn[i], regime = l, n = length(s),
          vol_1 = stats::sd(x) * sqrt(ppy), vol_2 = stats::sd(y) * sqrt(ppy),
          pearson = if (length(s) >= 10) stats::cor(x, y) else NA_real_,
          spearman = if (length(s) >= 10) stats::cor(x, y, method = "spearman") else NA_real_,
          kendall = if (length(s) >= 10) stats::cor(x, y, method = "kendall") else NA_real_,
          lambda_lower = if (!is.null(td)) td$lower else NA_real_, lambda_upper = if (!is.null(td)) td$upper else NA_real_,
          exceed_lower = if (!is.null(td)) td$exceed_lower else NA_real_,
          t_rho = if (!is.null(tt) && nrow(tt)) tt$par1 else NA_real_, t_nu = if (!is.null(tt) && nrow(tt)) tt$par2 else NA_real_,
          copula = if (!is.null(tc)) tc$family[1] else NA_character_,
          copula_lambda_lower = if (!is.null(tc)) tc$lambda_lower[1] else NA_real_,
          stringsAsFactors = FALSE)
      }
      ct <- do.call(rbind, rows)
      if (B > 0 && length(lv) >= 2) {
        nk <- nrow(Xk)
        boot <- .with_rng_restore({
          if (!is.null(seed)) set.seed(seed)
          lapply(seq_len(B), function(b) {
            idx <- .boot_idx_stationary(nk, nk, block)
            list(p = .dep_reg_cor(Xk[idx, , drop = FALSE], rk[idx], lv, pidx),
                 s = .dep_reg_cor(Xk[idx, , drop = FALSE], rk[idx], lv, pidx, rank = TRUE))
          })
        })
        bp <- simplify2array(lapply(boot, `[[`, "p")); bs <- simplify2array(lapply(boot, `[[`, "s"))
        if (length(dim(bp)) == 2) { bp <- array(bp, c(1, dim(bp))); bs <- array(bs, c(1, dim(bs))) }
        ci <- function(A, i, j) stats::quantile(A[i, j, ], c(0.05, 0.95), na.rm = TRUE, names = FALSE)
        ct$pearson_lo <- ct$pearson_hi <- NA_real_
        for (r in seq_len(nrow(ct))) { i <- match(ct$pair[r], pn); j <- match(ct$regime[r], lv)
          q <- ci(bp, i, j); ct$pearson_lo[r] <- q[1]; ct$pearson_hi[r] <- q[2] }
        dl <- lapply(seq_along(pn), function(i) {
          est_p <- ct$pearson[ct$pair == pn[i] & ct$regime == lv[length(lv)]] - ct$pearson[ct$pair == pn[i] & ct$regime == lv[1]]
          est_s <- ct$spearman[ct$pair == pn[i] & ct$regime == lv[length(lv)]] - ct$spearman[ct$pair == pn[i] & ct$regime == lv[1]]
          dp <- bp[i, length(lv), ] - bp[i, 1, ]; ds <- bs[i, length(lv), ] - bs[i, 1, ]
          pv <- function(dd) { dd <- dd[is.finite(dd)]; min(1, 2 * min(mean(dd <= 0), mean(dd >= 0))) }
          data.frame(pair = pn[i], condition = cn, from = lv[1], to = lv[length(lv)],
                     diff_pearson = est_p, lo_pearson = stats::quantile(dp, 0.025, na.rm = TRUE, names = FALSE),
                     hi_pearson = stats::quantile(dp, 0.975, na.rm = TRUE, names = FALSE), p_pearson = pv(dp),
                     diff_spearman = est_s, lo_spearman = stats::quantile(ds, 0.025, na.rm = TRUE, names = FALSE),
                     hi_spearman = stats::quantile(ds, 0.975, na.rm = TRUE, names = FALSE), p_spearman = pv(ds),
                     stringsAsFactors = FALSE)
        })
        diffs[[cn]] <- do.call(rbind, dl)
      }
      cond[[cn]] <- ct
    }
  }
  structure(list(returns = rd, assets = assets, conditions = conditions, frequency = frequency, ppy = ppy,
                 correlation = cors, pairs = ptab, tail = do.call(rbind, tails), copulas = cops,
                 rolling = roll, window = window, dcc = dc, conditional = cond, regimes = regimes,
                 differences = if (length(diffs)) do.call(rbind, diffs) else NULL, block = block, B = B, tail_q = tail_q),
            class = "SimLevDependence")
}

#' @export
print.SimLevDependence <- function(x, ...) {
  rd <- x$returns
  cat(sprintf("SimLev Abhaengigkeitsanalyse: %d Perioden (%s), %s bis %s\n\n", nrow(rd), x$frequency,
              format(rd$date[1]), format(rd$date[nrow(rd)])))
  cat("Korrelation (Pearson unten links, Kendall oben rechts)\n")
  M <- x$correlation$pearson; M[upper.tri(M)] <- x$correlation$kendall[upper.tri(M)]
  print(round(M, 3))
  p <- x$pairs
  cat("\nTail-Abhaengigkeit je Paar\n")
  qs <- grep("^lambda_lower_", names(p), value = TRUE)
  y <- data.frame(Paar = p$pair, Kendall = sprintf("%.3f", p$kendall), check.names = FALSE)
  for (k in qs) { q <- sub("lambda_lower_", "", k)
    y[[sprintf("lamL %s", q)]] <- sprintf("%.2f", p[[k]]); y[[sprintf("lamU %s", q)]] <- sprintf("%.2f", p[[sub("lower", "upper", k)]]) }
  if (!is.null(p$copula)) {
    y$Copula <- p$copula; y$`Cop. lamL` <- sprintf("%.2f", p$copula_lambda_lower); y$`Cop. lamU` <- sprintf("%.2f", p$copula_lambda_upper)
    y$`t: rho/nu` <- sprintf("%.2f / %.1f", p$t_rho, p$t_nu)
  }
  print(y, row.names = FALSE)
  cat("  (Unabhaengigkeit: lam(q) ~ q; Gauss-Abhaengigkeit: lam -> 0 fuer kleine q)\n")
  if (!is.null(x$dcc)) cat(sprintf("\nDCC(1,1): a = %.4f, b = %.4f (Persistenz %.4f); Korrelation zuletzt: %s\n",
                                   x$dcc$a, x$dcc$b, x$dcc$a + x$dcc$b,
                                   paste(sprintf("%s %.2f", x$dcc$pairs, x$dcc$correlation[nrow(x$dcc$correlation), ]), collapse = ", ")))
  for (cn in names(x$conditional)) {
    ct <- x$conditional[[cn]]
    cat(sprintf("\nBedingt auf '%s' (Zustand am Ende der Vorperiode)\n", cn))
    z <- data.frame(Paar = ct$pair, Regime = ct$regime, n = ct$n,
                    Pearson = sprintf("%.2f", ct$pearson),
                    `90%-KI` = if (!is.null(ct$pearson_lo)) sprintf("[%.2f, %.2f]", ct$pearson_lo, ct$pearson_hi) else "",
                    Kendall = sprintf("%.2f", ct$kendall), `lamL` = sprintf("%.2f", ct$lambda_lower),
                    `t-rho` = sprintf("%.2f", ct$t_rho), Copula = ct$copula, check.names = FALSE)
    names(z)[names(z) == "lamL"] <- sprintf("lamL %g", x$tail_q)
    print(z, row.names = FALSE)
    if (!is.null(x$differences)) {
      dd <- x$differences[x$differences$condition == cn, ]
      for (r in seq_len(nrow(dd))) cat(sprintf("  %s: Pearson %s -> %s: %+.2f [%+.2f, %+.2f], p = %.3f; Spearman %+.2f, p = %.3f\n",
                                              dd$pair[r], dd$from[r], dd$to[r], dd$diff_pearson[r], dd$lo_pearson[r], dd$hi_pearson[r],
                                              dd$p_pearson[r], dd$diff_spearman[r], dd$p_spearman[r]))
    }
  }
  if (!is.null(x$differences)) cat(sprintf("  (stationaerer Block-Bootstrap, B = %d, mittlere Blocklaenge %.1f Perioden)\n", x$B, x$block))
  invisible(x)
}

#' @rdname dependence_analysis
#' @param x \code{SimLevDependence}.
#' @param type \code{"overview"}, \code{"rolling"}, \code{"tail"},
#'   \code{"conditional"} oder \code{"scatter"}.
#' @param pair Paar (Nummer oder Name).
#' @param condition Zustandsvariable (Nummer oder Name).
#' @param ... ungenutzt.
#' @export
plot.SimLevDependence <- function(x, type = c("overview", "rolling", "tail", "conditional", "scatter"),
                                  pair = 1, condition = 1, ...) {
  type <- match.arg(type)
  old <- graphics::par(no.readonly = TRUE); on.exit(graphics::par(old))
  pn <- x$pairs$pair; i <- if (is.character(pair)) match(pair, pn) else pair
  ab <- strsplit(pn[i], " ~ ")[[1]]
  X <- x$returns
  bp <- function() graphics::par(mar = c(3.8, 4.2, 2.6, 1), mgp = c(2.4, 0.6, 0), las = 1, cex.axis = 0.8)
  p_roll <- function() {
    if (is.null(x$rolling)) return(graphics::plot.new())
    v <- x$rolling[[pn[i]]]
    graphics::plot(x$rolling$date, v, type = "l", col = "#2C6E9B", ylim = c(-1, 1), xlab = "", ylab = "Korrelation",
                   main = sprintf("%s: rollierend (%d) und DCC", pn[i], x$window))
    if (!is.null(x$dcc)) graphics::lines(X$date, x$dcc$correlation[, pn[i]], col = "#B5562B")
    graphics::abline(h = 0, col = "grey60", lty = 3)
    graphics::legend("bottomleft", c("rollierend", "DCC"), col = c("#2C6E9B", "#B5562B"), lwd = 2, bty = "n", cex = 0.75)
  }
  p_tail <- function() {
    qg <- c(0.01, 0.02, 0.03, 0.05, 0.075, 0.1, 0.15, 0.2, 0.3, 0.4, 0.5)
    td <- tail_dependence(X[[ab[1]]], X[[ab[2]]], qg)
    graphics::plot(qg, td$lower, type = "b", pch = 19, col = "#B5562B", ylim = c(0, 1), log = "x", xlab = "Quantil q",
                   ylab = expression(hat(lambda)(q)), main = sprintf("%s: Tail-Abhaengigkeit", pn[i]))
    graphics::lines(qg, td$upper, type = "b", pch = 17, col = "#2C6E9B")
    graphics::lines(qg, qg, lty = 3, col = "grey40")
    if (!is.null(x$copulas)) { cp <- x$copulas[[pn[i]]][1, ]
      graphics::abline(h = cp$lambda_lower, col = "#B5562B", lty = 2); graphics::abline(h = cp$lambda_upper, col = "#2C6E9B", lty = 2) }
    graphics::legend("topright", c("unten (gemeinsame Verluste)", "oben (gemeinsame Gewinne)", "Unabhaengigkeit",
                                   if (!is.null(x$copulas)) sprintf("Copula: %s", x$copulas[[pn[i]]]$family[1])),
                     col = c("#B5562B", "#2C6E9B", "grey40", "grey20"), lty = c(1, 1, 3, 2), bty = "n", cex = 0.72)
  }
  p_cond <- function() {
    if (!length(x$conditional)) return(graphics::plot.new())
    cn <- if (is.character(condition)) condition else names(x$conditional)[condition]
    ct <- x$conditional[[cn]]; ct <- ct[ct$pair == pn[i], ]
    mids <- graphics::barplot(ct$pearson, names.arg = ct$regime, col = "#2C6E9B", border = NA, ylim = c(-1, 1),
                              ylab = "Korrelation", main = sprintf("%s nach '%s'", pn[i], cn), cex.names = 0.75)
    if (!is.null(ct$pearson_lo)) graphics::arrows(mids, ct$pearson_lo, mids, ct$pearson_hi, angle = 90, code = 3, length = 0.04)
    graphics::points(mids, ct$lambda_lower, pch = 19, col = "#B5562B")
    graphics::abline(h = 0, col = "grey40")
    graphics::legend("topleft", c("Pearson (90%-KI)", sprintf("lam unten (q = %g)", x$tail_q)), pch = c(15, 19),
                     col = c("#2C6E9B", "#B5562B"), bty = "n", cex = 0.72)
  }
  p_scatter <- function() {
    u <- .pobs(X[[ab[1]]]); v <- .pobs(X[[ab[2]]])
    lo <- u <= x$tail_q & v <= x$tail_q; hi <- u > 1 - x$tail_q & v > 1 - x$tail_q
    graphics::plot(u, v, pch = 16, cex = 0.45, col = ifelse(lo, "#B5562B", ifelse(hi, "#2C6E9B", "grey65")),
                   xlab = paste("Rang", ab[1]), ylab = paste("Rang", ab[2]), main = "Pseudo-Beobachtungen")
    graphics::rect(0, 0, x$tail_q, x$tail_q, border = "#B5562B"); graphics::rect(1 - x$tail_q, 1 - x$tail_q, 1, 1, border = "#2C6E9B")
  }
  if (type == "overview") {
    graphics::par(mfrow = c(2, 2)); bp(); p_roll(); bp(); p_tail(); bp(); p_cond(); bp(); p_scatter()
  } else { bp(); switch(type, rolling = p_roll(), tail = p_tail(), conditional = p_cond(), scatter = p_scatter()) }
  invisible(x)
}

# ─────────────────────────────────────────────────────────────────────────────
# Quantilsregression, Tail-Regression, CoVaR
# ─────────────────────────────────────────────────────────────────────────────

#' Lineare Quantilsregression
#'
#' Minimiert \eqn{\sum_i \rho_\tau(y_i - x_i'\beta)} mit dem MM-Algorithmus
#' von Hunter & Lange (2000): iterativ gewichtete kleinste Quadrate mit
#' \deqn{\beta \leftarrow (X'WX)^{-1}(X'Wy + (\tau - 1/2) X'1),\quad
#'       W = \mathrm{diag}(1 / (2(\epsilon + |r_i|)))}
#' und schrittweise kleinerem \eqn{\epsilon}. Fuer die Analysen hier genau
#' genug (Abweichung zur exakten LP-Loesung typischerweise < 1e-6 relativ).
#'
#' @param y Zielvariable.
#' @param X Regressoren (Matrix oder data.frame, ohne Konstante).
#' @param tau Quantil in (0, 1).
#' @param intercept Konstante aufnehmen.
#' @param tol,maxit Konvergenzsteuerung.
#' @return Benannter Koeffizientenvektor.
#' @references Koenker, R. & Bassett, G. (1978), Econometrica 46(1);
#'   Hunter, D. R. & Lange, K. (2000), Journal of Computational and Graphical
#'   Statistics 9(1).
#' @examples
#' set.seed(1); x <- rnorm(500); y <- 1 + 2 * x + rnorm(500) * (1 + abs(x))
#' quantile_reg(y, x, 0.9)
#' @export
quantile_reg <- function(y, X = NULL, tau = 0.5, intercept = TRUE, tol = 1e-10, maxit = 2000L) {
  if (tau <= 0 || tau >= 1) stop("tau muss in (0, 1) liegen.")
  y <- as.numeric(y)
  X <- if (is.null(X)) matrix(0, length(y), 0) else as.matrix(X)
  nm <- colnames(X) %||% if (ncol(X)) paste0("x", seq_len(ncol(X))) else character(0)
  if (intercept) { X <- cbind(1, X); nm <- c("(Intercept)", nm) }
  ok <- is.finite(y) & rowSums(!is.finite(X)) == 0; y <- y[ok]; X <- X[ok, , drop = FALSE]
  beta <- qr.solve(X, y)
  sc <- max(stats::sd(y), 1e-12); c1 <- colSums(X) * (tau - 0.5)
  for (eps in sc * c(1e-2, 1e-4, 1e-6, 1e-8)) for (it in seq_len(maxit)) {
    r <- y - drop(X %*% beta)
    w <- 1 / (2 * (eps + abs(r)))
    nb <- solve(crossprod(X, X * w), crossprod(X, w * y) + c1)[, 1]
    done <- max(abs(nb - beta)) <= tol * (1 + max(abs(beta)))
    beta <- nb
    if (done) break
  }
  stats::setNames(beta, nm)
}

#' Renditequantile in Abhaengigkeit von Drittvariablen
#'
#' Schaetzt fuer mehrere Quantile, wie sich die Verteilung der Periodenrendite
#' einer Anlage mit dem (verzoegerten) Zustand von Drittvariablen verschiebt.
#' Ein negativer Koeffizient der Inflation im 5-%-Quantil heisst z. B.: Bei
#' hoeherer Inflation fallen die schlechten Perioden schlechter aus, auch wenn
#' sich der Median kaum bewegt. Standardfehler per stationaerem
#' Block-Bootstrap.
#'
#' @param data data.frame mit \code{date}, Kurs- und Zustandsspalten.
#' @param asset Kursspalte.
#' @param drivers Zustandsspalten (Drittvariablen).
#' @param quantiles Quantile.
#' @param frequency \code{"week"}, \code{"day"} oder \code{"month"}.
#' @param B Bootstrap-Wiederholungen (0 = keine Standardfehler).
#' @param block Mittlere Blocklaenge (Standard: Politis-White).
#' @param seed Startwert.
#' @return Objekt der Klasse \code{SimLevTailRegression}: \code{coefficients}
#'   (Quantil, Term, Schaetzung, SE, 90%-Intervall), \code{ols} und Daten.
#'   Renditen in Prozent je Periode.
#' @export
tail_regression <- function(data, asset, drivers, quantiles = c(0.05, 0.25, 0.5, 0.75, 0.95),
                            frequency = c("week", "day", "month"), B = 199L, block = NULL, seed = NULL) {
  frequency <- match.arg(frequency)
  rd <- .dep_returns(data, asset, drivers, frequency)
  rd <- rd[stats::complete.cases(rd[, c(asset, drivers)]), , drop = FALSE]
  y <- 100 * rd[[asset]]; X <- as.matrix(rd[, drivers, drop = FALSE]); n <- length(y)
  if (n < 30) stop("tail_regression: zu wenige Perioden.")
  est <- vapply(quantiles, function(q) quantile_reg(y, X, q), numeric(ncol(X) + 1))
  if (!is.matrix(est)) est <- matrix(est, nrow = 1)
  terms <- c("(Intercept)", drivers)
  se <- lo <- hi <- matrix(NA_real_, nrow(est), ncol(est))
  if (B > 0) {
    block <- block %||% min(max(2, .pw_block(abs(y - mean(y)))[["stationary"]]), n / 10)
    bs <- .with_rng_restore({
      if (!is.null(seed)) set.seed(seed)
      lapply(seq_len(B), function(b) { idx <- .boot_idx_stationary(n, n, block)
        vapply(quantiles, function(q) quantile_reg(y[idx], X[idx, , drop = FALSE], q), numeric(ncol(X) + 1)) })
    })
    A <- simplify2array(bs); if (length(dim(A)) == 2) A <- array(A, c(1, dim(A)))
    se <- apply(A, c(1, 2), stats::sd, na.rm = TRUE)
    lo <- apply(A, c(1, 2), stats::quantile, 0.05, na.rm = TRUE); hi <- apply(A, c(1, 2), stats::quantile, 0.95, na.rm = TRUE)
  }
  coefs <- data.frame(quantile = rep(quantiles, each = length(terms)), term = rep(terms, length(quantiles)),
                      estimate = as.vector(est), se = as.vector(se), lower = as.vector(lo), upper = as.vector(hi),
                      stringsAsFactors = FALSE)
  ols <- stats::coef(stats::lm(y ~ X)); names(ols) <- terms
  structure(list(coefficients = coefs, ols = ols, asset = asset, drivers = drivers, quantiles = quantiles,
                 n = n, frequency = frequency, B = B, block = block, data = rd), class = "SimLevTailRegression")
}

#' @export
print.SimLevTailRegression <- function(x, ...) {
  cat(sprintf("Quantilsregression: Rendite '%s' (%% je %s) auf verzoegerte %s; %d Perioden\n\n",
              x$asset, switch(x$frequency, week = "Woche", day = "Tag", month = "Monat"), paste(x$drivers, collapse = ", "), x$n))
  cf <- x$coefficients
  y <- data.frame(Quantil = sprintf("%g %%", 100 * cf$quantile), Term = cf$term, Koeffizient = sprintf("%.4f", cf$estimate),
                  SE = ifelse(is.na(cf$se), "", sprintf("%.4f", cf$se)),
                  `90%-KI` = ifelse(is.na(cf$lower), "", sprintf("[%.4f, %.4f]", cf$lower, cf$upper)), check.names = FALSE)
  print(y, row.names = FALSE)
  cat(sprintf("\nOLS (Mittelwert): %s\n", paste(sprintf("%s %.4f", names(x$ols), x$ols), collapse = ", ")))
  invisible(x)
}

#' @export
plot.SimLevTailRegression <- function(x, ...) {
  old <- graphics::par(no.readonly = TRUE); on.exit(graphics::par(old))
  k <- length(x$drivers)
  graphics::par(mfrow = c(1, k), mar = c(4, 4.4, 2.6, 1), mgp = c(2.5, 0.6, 0), las = 1, cex.axis = 0.8)
  for (dv in x$drivers) {
    cf <- x$coefficients[x$coefficients$term == dv, ]
    yl <- range(c(cf$estimate, cf$lower, cf$upper, x$ols[dv], 0), na.rm = TRUE)
    graphics::plot(cf$quantile, cf$estimate, type = "b", pch = 19, col = "#2C6E9B", ylim = yl, xlab = "Quantil",
                   ylab = "Koeffizient", main = sprintf("%s: Effekt von %s", x$asset, dv))
    if (!all(is.na(cf$lower))) graphics::polygon(c(cf$quantile, rev(cf$quantile)), c(cf$lower, rev(cf$upper)),
                                                 col = grDevices::adjustcolor("#2C6E9B", 0.15), border = NA)
    graphics::abline(h = x$ols[dv], col = "#B5562B", lty = 2); graphics::abline(h = 0, col = "grey50", lty = 3)
  }
  invisible(x)
}

#' CoVaR und Delta-CoVaR
#'
#' Nach Adrian & Brunnermeier (2016): Wie weit verschiebt sich das
#' \code{q}-Quantil der Rendite von \code{system} (z. B. das Portfolio), wenn
#' eine Anlage selbst in ihrem \code{q}-Quantil steht, gegenueber ihrem
#' Median? Mit \code{state} (Drittvariablen, verzoegert) werden VaR und CoVaR
#' zeitvariabel:
#' \deqn{X^{sys}_t = \alpha + \beta X^i_t + \gamma' M_{t-1} + \varepsilon \quad (\text{Quantil } q)}
#' \deqn{\Delta CoVaR_t = \beta\,(VaR^i_t(q) - VaR^i_t(0.5))}
#'
#' @param data data.frame mit \code{date} und Kursspalten.
#' @param system Kursspalte des Systems bzw. Portfolios.
#' @param assets Kursspalten der einzelnen Anlagen.
#' @param state Optionale Zustandsspalten.
#' @param q Quantil (Standard 0.05).
#' @param frequency \code{"week"}, \code{"day"} oder \code{"month"}.
#' @return Objekt der Klasse \code{SimLevCoVaR}: \code{summary} je Anlage
#'   (beta, VaR, CoVaR, Delta-CoVaR in Prozent je Periode, Mittel ueber die
#'   Zeit) und \code{series} (Zeitreihen je Anlage).
#' @references Adrian, T. & Brunnermeier, M. K. (2016), American Economic
#'   Review 106(7), 1705-1741.
#' @export
covar_analysis <- function(data, system, assets, state = NULL, q = 0.05, frequency = c("week", "day", "month")) {
  frequency <- match.arg(frequency)
  rd <- .dep_returns(data, unique(c(system, assets)), state, frequency)
  rd <- rd[stats::complete.cases(rd), , drop = FALSE]
  M <- if (length(state)) as.matrix(rd[, state, drop = FALSE]) else NULL
  ys <- 100 * rd[[system]]
  res <- lapply(assets, function(a) {
    xi <- 100 * rd[[a]]
    bq <- quantile_reg(xi, M, q); bm <- quantile_reg(xi, M, 0.5)
    Mi <- if (is.null(M)) matrix(1, length(xi), 1) else cbind(1, M)
    var_q <- drop(Mi %*% bq); var_m <- drop(Mi %*% bm)
    bs <- quantile_reg(ys, cbind(xi, M), q)
    covar <- bs[1] + bs[2] * var_q + (if (!is.null(M)) drop(M %*% bs[-(1:2)]) else 0)
    dcv <- bs[2] * (var_q - var_m)
    list(summary = data.frame(asset = a, beta = unname(bs[2]), var = mean(var_q), covar = mean(covar),
                              delta_covar = mean(dcv), delta_covar_min = min(dcv), stringsAsFactors = FALSE),
         series = data.frame(date = rd$date, asset = a, var = var_q, covar = covar, delta_covar = dcv))
  })
  structure(list(summary = do.call(rbind, lapply(res, `[[`, "summary")), series = do.call(rbind, lapply(res, `[[`, "series")),
                 system = system, state = state, q = q, frequency = frequency, n = nrow(rd)), class = "SimLevCoVaR")
}

#' @export
print.SimLevCoVaR <- function(x, ...) {
  cat(sprintf("CoVaR (q = %g) fuer System '%s'%s; %d Perioden (%s), Werte in %% je Periode\n\n", x$q, x$system,
              if (length(x$state)) sprintf(", Zustand: %s", paste(x$state, collapse = ", ")) else "", x$n, x$frequency))
  s <- x$summary
  print(data.frame(Anlage = s$asset, beta = sprintf("%.3f", s$beta), `VaR Anlage` = sprintf("%.2f", s$var),
                   CoVaR = sprintf("%.2f", s$covar), `Delta-CoVaR` = sprintf("%.2f", s$delta_covar),
                   `Delta-CoVaR min` = sprintf("%.2f", s$delta_covar_min), check.names = FALSE), row.names = FALSE)
  invisible(x)
}

#' @export
plot.SimLevCoVaR <- function(x, ...) {
  old <- graphics::par(no.readonly = TRUE); on.exit(graphics::par(old))
  graphics::par(mar = c(3.6, 4.4, 2.6, 1), mgp = c(2.5, 0.6, 0), las = 1, cex.axis = 0.85)
  s <- x$series; a <- unique(s$asset); cols <- c("#2C6E9B", "#B5562B", "#3E8E5A", "#8A5BA8", "#C49A2C")[seq_along(a)]
  graphics::plot(range(s$date), range(s$delta_covar), type = "n", xlab = "", ylab = "Delta-CoVaR (%)",
                 main = sprintf("Delta-CoVaR fuer '%s' (q = %g)", x$system, x$q))
  for (j in seq_along(a)) graphics::lines(s$date[s$asset == a[j]], s$delta_covar[s$asset == a[j]], col = cols[j])
  graphics::legend("bottomleft", a, col = cols, lwd = 2, bty = "n", cex = 0.8)
  invisible(x)
}

# ─────────────────────────────────────────────────────────────────────────────
# Bootstrap-Validierung und Stress-Regime
# ─────────────────────────────────────────────────────────────────────────────

#' Abhaengigkeitsstruktur von Bootstrap-Pfaden pruefen
#'
#' Vergleicht Kendalls Tau, Pearson-Korrelation, empirische
#' Tail-Abhaengigkeit und die untere Exceedance-Korrelation der Indizes in
#' der Historie mit ihrer Verteilung ueber die Bootstrap-Pfade. Liegt der
#' historische Wert am Rand der Pfadverteilung, gibt das Verfahren die
#' Abhaengigkeit nicht wieder (z. B. Tail-Abhaengigkeit beim IID-Bootstrap
#' zwar erhalten, Volatilitaets-Clustering aber nicht).
#'
#' @param boot \code{bootstrap_result} aus [bootstrap()].
#' @param data Historische Daten wie fuer [bootstrap()].
#' @param agg Zeilen je Periode fuer die Aggregation (z. B. 5 Handelstage
#'   oder 7 Kalendertage ergibt Wochen).
#' @param q Quantil fuer die Tail-Kennzahlen.
#' @param max_paths Hoechstens so viele Pfade auswerten.
#' @return data.frame je Paar und Kennzahl: historischer Wert, Median und
#'   5-/95-%-Quantil ueber die Pfade, Perzentil der Historie.
#' @export
validate_dependence <- function(boot, data, agg = 5L, q = 0.10, max_paths = 200L) {
  if (!inherits(boot, "bootstrap_result")) stop("boot muss ein bootstrap_result sein.")
  cfg <- boot$config
  if (length(cfg$index_names) < 2) stop("validate_dependence: mindestens zwei Indizes in der Konfiguration.")
  hist <- log(.extract_returns(data, cfg)$ret)
  aggr <- function(L) { k <- nrow(L) %/% agg; if (k < 20) stop("Zu wenige Perioden nach Aggregation.")
    rowsum(L[seq_len(k * agg), , drop = FALSE], rep(seq_len(k), each = agg)) }
  stats_of <- function(L) {
    A <- aggr(L); pr <- utils::combn(ncol(A), 2)
    unlist(lapply(seq_len(ncol(pr)), function(j) {
      x <- A[, pr[1, j]]; y <- A[, pr[2, j]]; td <- tail_dependence(x, y, q)
      c(kendall = stats::cor(x, y, method = "kendall"), pearson = stats::cor(x, y),
        lambda_lower = td$lower, lambda_upper = td$upper, exceed_lower = td$exceed_lower)
    }))
  }
  h <- stats_of(hist)
  paths <- utils::head(boot$paths, max_paths)
  P <- vapply(paths, function(p) { L <- diff(log(p[, cfg$index_names, drop = FALSE])); stats_of(L) }, numeric(length(h)))
  if (!is.matrix(P)) P <- matrix(P, nrow = length(h))
  pr <- utils::combn(cfg$index_names, 2, paste, collapse = " ~ ")
  data.frame(pair = rep(pr, each = 5), metric = rep(c("kendall", "pearson", "lambda_lower", "lambda_upper", "exceed_lower"), length(pr)),
             historical = h, median = apply(P, 1, stats::median, na.rm = TRUE),
             p05 = apply(P, 1, stats::quantile, 0.05, na.rm = TRUE), p95 = apply(P, 1, stats::quantile, 0.95, na.rm = TRUE),
             percentile = vapply(seq_along(h), function(i) mean(P[i, ] <= h[i], na.rm = TRUE), 0),
             row.names = NULL, stringsAsFactors = FALSE)
}

#' Zeilen eines Regimes fuer Stress-Bootstraps
#'
#' Waehlt die Zeilen aus, in denen \code{condition} gilt (z. B. hohe
#' Inflation), und verwirft zu kurze Episoden. Mit Rendite-Eingabe
#' (\code{bootstrap_config(input = "returns")}) laesst sich das Ergebnis direkt
#' an [bootstrap()] oder [bootstrap_study()] uebergeben: Die Pfade bestehen
#' dann nur aus Bloecken dieses Regimes (inklusive der mitgezogenen
#' Zusatzreihen wie Zinsen). Bloecke koennen an Episodengrenzen ueberlappen.
#'
#' @param data data.frame (Zeilen = Tage, Renditen als Brutto-Renditen).
#' @param condition Logischer Vektor (NA = FALSE) oder Ausdruck als Zeichenkette,
#'   der in \code{data} ausgewertet wird, z. B. \code{"inflation >= 4"}.
#' @param min_run Mindestlaenge einer Episode in Zeilen.
#' @return Teilmenge von \code{data} mit Attribut \code{episodes}
#'   (Start, Ende, Laenge).
#' @examples
#' d <- data.frame(r = 1 + rnorm(100, 0, 0.01), infl = c(rep(1, 40), rep(5, 30), rep(1, 30)))
#' s <- regime_subset(d, "infl >= 4", min_run = 10)
#' attr(s, "episodes")
#' @export
regime_subset <- function(data, condition, min_run = 1L) {
  cond <- if (is.character(condition)) eval(parse(text = condition), data, parent.frame()) else condition
  cond <- as.logical(cond); cond[is.na(cond)] <- FALSE
  if (length(cond) != nrow(data)) stop("condition muss die Laenge nrow(data) haben.")
  r <- rle(cond); ends <- cumsum(r$lengths); starts <- ends - r$lengths + 1L
  keep <- r$values & r$lengths >= min_run
  if (!any(keep)) stop("regime_subset: keine Episode erfuellt condition und min_run.")
  rows <- unlist(Map(seq.int, starts[keep], ends[keep]))
  out <- data[rows, , drop = FALSE]
  ep <- data.frame(start = starts[keep], end = ends[keep], length = r$lengths[keep])
  if ("date" %in% names(data)) { ep$start_date <- as.Date(data$date[ep$start]); ep$end_date <- as.Date(data$date[ep$end]) }
  attr(out, "episodes") <- ep
  out
}

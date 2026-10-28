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
#  Alles ohne Zusatzpakete; die univariaten GARCH-Fits der DCC-Stufe nutzen
#  wie der Bootstrap die aus rugarch uebernommene Fassung (R/vendor_rugarch.R).
#  Drittvariablen gehen immer verzoegert ein: Die Rendite der Periode t wird
#  dem Zustand zugeordnet, der am Ende der Periode t - 1 bekannt war. Fuer
#  Makrodaten mit Veroeffentlichungsverzug vorher align_macro() verwenden.
# =============================================================================

# ─────────────────────────────────────────────────────────────────────────────
# Renditen und Pseudo-Beobachtungen
# ─────────────────────────────────────────────────────────────────────────────

#' Zeilen nach Datum ordnen: fehlende oder doppelte Daten sind ein Fehler,
#' unsortierte Zeilen werden mit Hinweis aufsteigend sortiert; 'date' wird per
#' .to_date() in Date gewandelt (POSIXct mit dem Kalendertag der eigenen Zeitzone)
#' @keywords internal
#' @noRd
.dep_sort_dates <- function(data, what = "data") {
  d <- data$date <- .to_date(data$date, sprintf("%s: Spalte 'date'", what))
  if (anyNA(d)) stop(sprintf("%s: Spalte 'date' enth\u00e4lt fehlende Daten (Zeile %s).", what,
                             paste(utils::head(which(is.na(d)), 5), collapse = ", ")))
  if (anyDuplicated(d)) {
    dup <- unique(d[duplicated(d)])
    stop(sprintf("%s: doppelte Daten in 'date' (%s%s); erwartet ist eine Zeile je Datum.", what,
                 paste(format(utils::head(dup, 5)), collapse = ", "), if (length(dup) > 5) sprintf(" und %d weitere", length(dup) - 5) else ""))
  }
  if (is.unsorted(d)) {
    message(sprintf("%s: Zeilen sind nicht nach 'date' sortiert und werden aufsteigend sortiert.", what))
    data <- data[order(d), , drop = FALSE]
  }
  data
}

#' Kursspalte pruefen: vorhandene Werte muessen positiv und endlich sein
#' @keywords internal
#' @noRd
.dep_check_prices <- function(v, a, d) {
  bad <- which(!is.na(v) & (!is.finite(v) | v <= 0))
  if (length(bad)) stop(sprintf("Kursspalte '%s': Kurse m\u00fcssen positiv und endlich sein, gefunden %s am %s%s (fehlende Kurse als NA angeben).",
                                a, format(v[bad[1]]), format(d[bad[1]]),
                                if (length(bad) > 1) sprintf(" und %d weitere Werte", length(bad) - 1) else ""))
  v
}

#' Periodenrenditen und verzoegerte Zustandsvariablen
#' @keywords internal
#' @noRd
.dep_returns <- function(data, assets, conditions = NULL, frequency = "week", drop_flat = TRUE) {
  if (!is.data.frame(data) || !"date" %in% names(data)) stop("data.frame mit Spalte 'date' erwartet.")
  miss <- setdiff(c(assets, conditions), names(data))
  if (length(miss)) stop(sprintf("Spalten fehlen: %s", paste(miss, collapse = ", ")))
  data <- .dep_sort_dates(data)
  d <- data$date
  end <- if (frequency == "day") seq_along(d) else {
    key <- if (frequency == "week") format(d, "%G-%V") else format(d, "%Y-%m")
    which(c(key[-1] != key[-length(key)], TRUE))
  }
  V <- vapply(assets, function(a) .fill_na(.dep_check_prices(as.numeric(data[[a]]), a, d), "locf", keep_leading = TRUE),
              numeric(nrow(data)))
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

#' Kendalls Tau-b (Kern in C++, O(n log n) nach Knight 1966); fuer eine Matrix
#' die Korrelationsmatrix. Bei fehlenden Werten wie stats::cor.
#' @keywords internal
#' @noRd
.kendall <- function(x, y = NULL) {
  if (is.null(y) && is.matrix(x)) {
    if (any(!is.finite(x))) return(stats::cor(x, method = "kendall"))
    k <- ncol(x); M <- diag(1, k); dimnames(M) <- list(colnames(x), colnames(x))
    if (k > 1) for (i in 1:(k - 1)) for (j in (i + 1):k) M[i, j] <- M[j, i] <- .kendall_tau_core(as.numeric(x[, i]), as.numeric(x[, j]))
    return(M)
  }
  x <- as.numeric(x); y <- as.numeric(y)
  if (any(!is.finite(x)) || any(!is.finite(y))) return(stats::cor(x, y, method = "kendall"))
  .kendall_tau_core(x, y)
}

#' Pseudo-Beobachtungen (Raenge / (n + 1))
#' @keywords internal
#' @noRd
.pobs <- function(x) rank(x, ties.method = "average") / (length(x) + 1)

# ─────────────────────────────────────────────────────────────────────────────
# Copulas
# ─────────────────────────────────────────────────────────────────────────────

#' Log-Dichte einer Copula (Summe), Familien inkl. Rotationen
#' @keywords internal
#' @noRd
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
#' @noRd
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
#' Passt mehrere bivariate Copula-Familien an zwei Reihen (z. B.
#' Periodenrenditen zweier Anlagen) an und vergleicht sie per AIC.
#' Pseudo-Maximum-Likelihood auf Raengen (Genest, Ghoudi & Rivest 1995):
#' Die Reihen werden in Pseudo-Beobachtungen Rang / (n + 1) umgerechnet, die
#' Raender gehen also nicht ein. Familien: Gauss-, t-, Clayton-, Gumbel- und
#' Frank-Copula. Clayton und Gumbel erfassen asymmetrische Tails: Clayton die
#' gemeinsamen Abstuerze (unterer Tail), Gumbel gemeinsame Anstiege; die um
#' 180 Grad rotierten Varianten jeweils umgekehrt. Bei negativer Abhaengigkeit
#' (z. B. Aktien und Anleihen in Deflationsphasen) werden die um 90/270 Grad
#' rotierten Varianten verwendet. Kendalls Tau wird intern in O(n log n)
#' berechnet (gleiches Ergebnis wie \code{stats::cor(method = "kendall")}).
#'
#' @param x,y Numerische Vektoren gleicher Laenge (z. B. Renditen; nur die
#'   Raenge zaehlen). Paare mit nicht endlichen Werten werden entfernt;
#'   mindestens 20 Paare noetig.
#' @param families Zeichenvektor der Familien: \code{"gaussian"}, \code{"t"},
#'   \code{"clayton"}, \code{"gumbel"}, \code{"frank"}, jeweils optional mit
#'   Rotation \code{"_90"}, \code{"_180"} oder \code{"_270"} (z. B.
#'   \code{"clayton_180"}). \code{NULL} (Standard) = Auswahl nach dem
#'   Vorzeichen von Kendalls Tau: bei Tau >= 0 \code{gaussian}, \code{t},
#'   \code{clayton}, \code{gumbel}, \code{frank}, \code{clayton_180},
#'   \code{gumbel_180}; sonst \code{gaussian}, \code{t}, \code{frank},
#'   \code{clayton_90}, \code{clayton_270}, \code{gumbel_90},
#'   \code{gumbel_270}. Rotationen gibt es nur fuer \code{clayton} und
#'   \code{gumbel} (Gauss-, t- und Frank-Copula sind radialsymmetrisch);
#'   andere Namen sind ein Fehler, ebenso eine konstante Reihe.
#' @return data.frame mit einer Zeile je Familie, aufsteigend nach AIC
#'   sortiert (erste Zeile = beste Familie): \code{family}, \code{par1}
#'   (Korrelation bei Gauss/t, sonst \eqn{\theta}), \code{par2}
#'   (Freiheitsgrade der t-Copula, hoechstens 500; sonst \code{NA}),
#'   \code{loglik}, \code{aic}, \code{bic}, \code{lambda_lower},
#'   \code{lambda_upper} (implizite Tail-Koeffizienten der Copula, Anteile
#'   0 bis 1; fuer die um 90/270 Grad rotierten Familien 0). Attribute
#'   \code{tau} (Kendalls Tau) und \code{n} (Anzahl Paare).
#' @seealso [tail_dependence()] fuer die empirischen Tail-Koeffizienten,
#'   [dependence_analysis()] (Copula-Fits fuer alle Paare),
#'   [copula_scenarios()].
#' @references Genest, C., Ghoudi, K. & Rivest, L.-P. (1995), Biometrika
#'   82(3); Joe, H. (2014), Dependence Modeling with Copulas.
#' @examples
#' set.seed(1); z <- matrix(rnorm(2000), ncol = 2) %*% chol(matrix(c(1, .6, .6, 1), 2))
#' w <- sqrt(rchisq(1000, 4) / 4); x <- z[, 1] / w; y <- z[, 2] / w   # t-Abhaengigkeit
#' fit_copula(x, y)[, c("family", "par1", "par2", "aic", "lambda_lower")]
#' @export
fit_copula <- function(x, y, families = NULL) {
  if (length(x) != length(y)) stop(sprintf("fit_copula: x und y m\u00fcssen gleich lang sein (%d bzw. %d Werte).", length(x), length(y)))
  ok <- is.finite(x) & is.finite(y); x <- x[ok]; y <- y[ok]
  n <- length(x)
  if (n < 20) stop("fit_copula: mindestens 20 Beobachtungen n\u00f6tig.")
  if (!is.null(families)) {
    base <- sub("_.*$", "", families); rot <- ifelse(grepl("_", families), sub("^[^_]*_", "", families), "")
    bad <- !base %in% c("gaussian", "t", "clayton", "gumbel", "frank") | !rot %in% c("", "90", "180", "270") |
      (base %in% c("gaussian", "t", "frank") & rot != "")
    if (any(bad)) stop(sprintf("fit_copula: unbekannte Familie %s; erlaubt sind gaussian, t, frank sowie clayton und gumbel mit optionaler Rotation _90, _180 oder _270.",
                               paste0("'", families[bad], "'", collapse = ", ")))
  }
  u <- .pobs(x); v <- .pobs(y)
  tau <- .kendall(x, y)
  if (!is.finite(tau)) stop("fit_copula: x oder y ist konstant (keine Rangstreuung); keine Copula sch\u00e4tzbar.")
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
#' Misst fuer zwei Reihen (z. B. Periodenrenditen), wie oft extreme Werte
#' gemeinsam auftreten, ohne ein Copula-Modell anzunehmen:
#' \deqn{\hat\lambda_L(q) = \frac{\#\{u_i \le q, v_i \le q\}}{n q}, \quad
#'       \hat\lambda_U(q) = \frac{\#\{u_i > 1 - q, v_i > 1 - q\}}{n q}}
#' auf Pseudo-Beobachtungen \eqn{u_i, v_i} (Rang / (n + 1)). Unter
#' Unabhaengigkeit ist \eqn{\hat\lambda(q) \approx q}, bei
#' Gauss-Abhaengigkeit faellt es fuer \eqn{q \to 0} gegen 0, bei echter
#' Tail-Abhaengigkeit bleibt es positiv.
#' Die Exceedance-Korrelation (Longin & Solnik 2001) ist die
#' Pearson-Korrelation der Beobachtungen, in denen beide Reihen hoechstens auf
#' ihrem empirischen q-Quantil (bzw. mindestens auf ihrem (1 - q)-Quantil)
#' liegen.
#'
#' @param x,y Numerische Vektoren gleicher Laenge (z. B. Periodenrenditen).
#'   Paare mit nicht endlichen Werten werden entfernt.
#' @param q Numerischer Vektor von Tail-Wahrscheinlichkeiten als Anteil
#'   echt zwischen 0 und 1 (0.05 = die unteren bzw. oberen 5 % der
#'   Beobachtungen).
#' @return data.frame mit einer Zeile je Wert von \code{q}: \code{q},
#'   \code{lower}, \code{upper} (\eqn{\hat\lambda_L(q)},
#'   \eqn{\hat\lambda_U(q)}), \code{exceed_lower}, \code{exceed_upper}
#'   (Exceedance-Korrelationen; \code{NA} bei weniger als 8 gemeinsamen
#'   Ueberschreitungen oder Streuung 0), \code{n_lower}, \code{n_upper}
#'   (Anzahl der Paare, die gemeinsam im unteren bzw. oberen Tail liegen).
#' @seealso [fit_copula()] (implizite Tail-Koeffizienten),
#'   [dependence_analysis()], [validate_dependence()].
#' @references Longin, F. & Solnik, B. (2001), Journal of Finance 56(2).
#' @examples
#' set.seed(1); z <- rnorm(2000); x <- z + rnorm(2000); y <- z + rnorm(2000)
#' tail_dependence(x, y, q = c(0.05, 0.10))
#' @export
tail_dependence <- function(x, y, q = c(0.01, 0.025, 0.05, 0.10, 0.20)) {
  if (length(x) != length(y)) stop(sprintf("tail_dependence: x und y m\u00fcssen gleich lang sein (%d bzw. %d Werte).", length(x), length(y)))
  if (!is.numeric(q) || !length(q) || any(!is.finite(q) | q <= 0 | q >= 1))
    stop(sprintf("tail_dependence: q muss aus Anteilen echt zwischen 0 und 1 bestehen (erhalten: %s).", paste(format(q), collapse = ", ")))
  ok <- is.finite(x) & is.finite(y); x <- x[ok]; y <- y[ok]; n <- length(x)
  if (n < 2) stop("tail_dependence: mindestens zwei Paare mit endlichen Werten n\u00f6tig.")
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
#' Schaetzt zeitvariable Korrelationen zwischen mehreren Renditereihen.
#' Zweistufige Schaetzung: univariate GARCH(1,1) mit Konstante je Reihe (wie
#' im Bootstrap: mit der aus rugarch 1.5-6 uebernommenen Fassung von
#' \code{ugarchfit}, wenn diese scheitert mit optim, notfalls
#' Momentschaetzer), danach die Korrelationsdynamik der standardisierten
#' Residuen \eqn{z_t}
#' \deqn{Q_t = (1 - a - b)\bar Q + a z_{t-1} z_{t-1}' + b Q_{t-1}}
#' mit \eqn{Q_1 = \bar Q} (Stichproben-Korrelation der \eqn{z_t}) und
#' \eqn{a, b > 0}, \eqn{a + b < 0.999}, per Quasi-Maximum-Likelihood
#' (Nelder-Mead; Filter in C++). Die bedingte Korrelation ist
#' \eqn{R_t = \mathrm{diag}(Q_t)^{-1/2} Q_t \mathrm{diag}(Q_t)^{-1/2}}.
#'
#' @param R Numerische Renditematrix oder data.frame (Zeilen = Zeit, Spalten
#'   = Reihen; mindestens zwei Spalten und 100 Zeilen, keine fehlenden
#'   Werte). Die Einheit ist frei (z. B. Log-Renditen als Anteil); die
#'   Korrelationen haengen nicht davon ab. Spaltennamen werden uebernommen
#'   (sonst \code{V1}, \code{V2}, ...). Konstante oder (nahezu) perfekt
#'   korrelierte Reihen (singulaere Korrelationsmatrix der standardisierten
#'   Residuen, kleinster Eigenwert unter 1e-8) sind ein Fehler.
#' @return Liste mit \code{a}, \code{b} (DCC-Parameter), \code{loglik}
#'   (Korrelationsteil der Quasi-Log-Likelihood), \code{correlation} (Matrix
#'   Zeit x Paare der bedingten Korrelationen \eqn{R_t}; Spaltennamen wie
#'   \code{pairs}), \code{pairs} (Paarnamen \code{"A ~ B"}), \code{garch}
#'   (data.frame je Reihe: \code{series}, \code{alpha}, \code{beta},
#'   \code{method} = Schaetzweg der GARCH-Stufe), \code{z} (Matrix der
#'   standardisierten Residuen) und \code{Qbar}.
#' @seealso [dependence_analysis()] (ruft \code{dcc_fit()} fuer alle Anlagen
#'   auf), [fit_copula()], [tail_dependence()].
#' @examples
#' set.seed(1); n <- 500
#' R <- cbind(a = rnorm(n, 0, 0.01), b = rnorm(n, 0, 0.01))
#' R[, "b"] <- 0.5 * R[, "a"] + sqrt(0.75) * R[, "b"]
#' fit <- dcc_fit(R)
#' c(a = fit$a, b = fit$b)
#' tail(fit$correlation, 3)
#' @references Engle, R. (2002), Journal of Business & Economic Statistics
#'   20(3), 339-350.
#' @export
dcc_fit <- function(R) {
  R <- as.matrix(R)
  if (ncol(R) < 2 || nrow(R) < 100) stop("dcc_fit: mindestens zwei Reihen und 100 Beobachtungen.")
  nm <- colnames(R) %||% paste0("V", seq_len(ncol(R)))
  g <- lapply(seq_len(ncol(R)), function(j) .fit_garch11(R[, j], quiet = TRUE))
  Z <- vapply(g, `[[`, numeric(nrow(R)), "z")
  if (!is.matrix(Z)) Z <- matrix(Z, ncol = ncol(R))
  flat <- which(apply(Z, 2, stats::sd) == 0)
  if (length(flat)) stop(sprintf("dcc_fit: Reihe %s ist konstant; keine Korrelation sch\u00e4tzbar.", paste0("'", nm[flat], "'", collapse = ", ")))
  Qb <- stats::cor(Z)
  # (nahezu) perfekt korrelierte Reihen: Qbar und damit R_t sind singulaer
  ev <- eigen(Qb, symmetric = TRUE, only.values = TRUE)$values
  if (min(ev) < 1e-8) {
    C0 <- Qb; diag(C0) <- 0; ij <- which(abs(C0) == max(abs(C0)), arr.ind = TRUE)[1, ]
    stop(sprintf("dcc_fit: Korrelationsmatrix der standardisierten Residuen ist singul\u00e4r (z. B. '%s' und '%s': Korrelation %.6f); DCC nicht sch\u00e4tzbar. Doppelte bzw. linear abh\u00e4ngige Reihen entfernen.",
                 nm[ij[1]], nm[ij[2]], Qb[ij[1], ij[2]]))
  }
  par <- function(th) { s <- 0.999 * stats::plogis(th[1]); a <- s * stats::plogis(th[2]); c(a, s - a) }
  f <- function(th) { p <- par(th); .dcc_filter(Z, p[1], p[2], Qb, FALSE)$nll }
  st <- c(stats::qlogis(0.98 / 0.999), stats::qlogis(0.03 / 0.98))
  o <- stats::optim(st, f, method = "Nelder-Mead", control = list(maxit = 2000, reltol = 1e-10))
  p <- par(o$par)
  fl <- .dcc_filter(Z, p[1], p[2], Qb, TRUE)
  if (!isTRUE(fl$ok)) stop("dcc_fit: bedingte Korrelationsmatrix nicht positiv definit; DCC nicht sch\u00e4tzbar.")
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
#' @noRd
.dep_regimes <- function(cv, breaks = NULL, n_regimes = 3L) {
  if (is.null(breaks)) {
    qs <- stats::quantile(cv, seq(0, 1, length.out = n_regimes + 1L), na.rm = TRUE, names = FALSE)
    inner <- qs[-c(1, length(qs))]; u <- sort(unique(cv[is.finite(cv)]))
    # Jede innere Grenze q trennt wie der naechste Datenwert >= q oberhalb des
    # Minimums; Grenzen mit gleicher Trennung entfallen, und eine Grenze auf dem
    # Minimum (diskrete Zustaende wie 1/2) wird auf diesen Datenwert gelegt.
    # So bleibt kein Regime leer; bei stetigen Daten aendert sich nichts.
    br <- if (length(u) < 2 || !length(inner)) numeric(0) else {
      b <- vapply(inner, function(q) u[-1][which(u[-1] >= q)[1]], 0)
      ifelse(inner > u[1], inner, b)[!duplicated(b)]
    }
    breaks <- c(-Inf, br, Inf)
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
#' @noRd
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
#' Renditen: Die Zeilen werden nach \code{date} sortiert (mit Hinweis, falls
#' noetig; fehlende oder doppelte Daten sind ein Fehler, ebenso Kurse <= 0
#' oder nicht endliche Kurse). Die Kurse werden je Anlage mit dem letzten Wert fortgeschrieben
#' (fuehrende Luecken bleiben leer), auf die letzte vorhandene Zeile jeder
#' Periode reduziert (\code{"week"}: ISO-Woche, \code{"month"}:
#' Kalendermonat, \code{"day"}: jede Zeile) und in Log-Renditen
#' \eqn{\log(P_t / P_{t-1})} (Anteile, keine Prozent) umgerechnet. Zeilen mit
#' fehlenden Renditen entfallen; bei \code{"day"} auch Zeilen, in denen alle
#' Anlagen die Rendite 0 haben (z. B. Feiertage). Zustandsvariablen werden
#' ebenfalls fortgeschrieben und gehen mit ihrem Wert am Ende der Vorperiode
#' ein.
#'
#' @param data data.frame mit Spalte \code{date} (Klasse Date oder in Date
#'   umwandelbar), Kursspalten (Kursniveaus, keine Renditen) und
#'   Zustandsspalten (z. B. mit [align_series()] und [align_macro()]
#'   vorbereitet).
#' @param assets Zeichenvektor der Kursspalten (mindestens zwei).
#' @param conditions Zeichenvektor der Zustandsspalten (Drittvariablen, in
#'   ihrer eigenen Einheit); gehen um eine Periode verzoegert ein.
#'   \code{NULL} (Standard) = keine bedingte Analyse.
#' @param frequency Renditefrequenz: \code{"week"} (Standard; ISO-Woche,
#'   vermeidet Effekte unterschiedlicher Handelszeiten), \code{"day"} oder
#'   \code{"month"}.
#' @param quantiles Numerischer Vektor von Tail-Wahrscheinlichkeiten als
#'   Anteil (Standard \code{c(0.05, 0.10)}) fuer die Tail-Kennzahlen ueber
#'   die ganze Stichprobe (siehe [tail_dependence()]).
#' @param breaks Optional benannte Liste von Grenzen je Zustandsvariable in
#'   deren Einheit, z. B. \code{list(inflation = c(-Inf, 2, 4, Inf))};
#'   Intervalle links geschlossen, rechts offen. \code{NULL} (Standard) bzw.
#'   fehlender Eintrag = \code{n_regimes} gleich besetzte Quantilsgruppen.
#' @param n_regimes Anzahl Regime ohne \code{breaks} (ganze Zahl, Standard 3:
#'   niedrig, mittel, hoch). Fallen Quantilsgrenzen zusammen oder bliebe eine
#'   Quantilsgruppe leer (diskrete Zustaende wie 1/2 aus [regime_states()]),
#'   entstehen weniger Regime. Leere Regime aus vorgegebenen \code{breaks}
#'   erscheinen mit \code{n = 0} und \code{NA}-Kennzahlen.
#' @param window Fenster der rollierenden Pearson-Korrelation in Perioden der
#'   gewaehlten Frequenz. \code{NULL} (Standard) = Anzahl Perioden je Jahr
#'   (aus den Daten ermittelt, mindestens 10).
#' @param dcc Logisch: DCC(1,1) mit [dcc_fit()] schaetzen (nur bei
#'   mindestens 100 Perioden; Fehler werden als Meldung ausgegeben).
#' @param copulas Logisch: Copula-Fits mit [fit_copula()] je Paar (und je
#'   Regime ab 40 Perioden).
#' @param B Anzahl Bootstrap-Wiederholungen fuer die Regime-Vergleiche
#'   (ganze Zahl, Standard 499; 0 = aus).
#' @param block Mittlere Blocklaenge des stationaeren Bootstraps in Perioden.
#'   \code{NULL} (Standard) = Politis-White-Schaetzung auf dem Produkt der
#'   standardisierten Renditen (Maximum ueber die Paare, begrenzt auf 2 bis
#'   n / 10).
#' @param tail_q Tail-Wahrscheinlichkeit als Anteil (Standard 0.10) fuer die
#'   Tail-Kennzahlen je Regime.
#' @param seed Startwert fuer den Bootstrap. Mit Startwert ist das Ergebnis reproduzierbar und der
#'   Zufallszustand der Sitzung bleibt unveraendert; mit `NULL` wird der
#'   Zufallsstrom der Sitzung normal weitergezogen.
#' @return Objekt der Klasse \code{SimLevDependence}, eine Liste mit
#'   \describe{
#'     \item{returns}{data.frame mit \code{date} (Periodenende), den
#'       Log-Renditen der Anlagen (Anteile je Periode) und den verzoegerten
#'       Zustandsvariablen.}
#'     \item{correlation}{Liste der Matrizen \code{pearson},
#'       \code{spearman}, \code{kendall}.}
#'     \item{pairs}{data.frame je Paar: \code{pair}, \code{pearson},
#'       \code{spearman}, \code{kendall}, je Wert von \code{quantiles}
#'       \code{lambda_lower_}q und \code{lambda_upper_}q (z. B.
#'       \code{lambda_lower_0.05}); mit
#'       \code{copulas = TRUE} zusaetzlich \code{copula} (beste Familie nach
#'       AIC), \code{copula_lambda_lower}, \code{copula_lambda_upper},
#'       \code{t_rho}, \code{t_nu} (Parameter der t-Copula).}
#'     \item{tail}{Ergebnis von [tail_dependence()] je Paar (Spalte
#'       \code{pair}) und Quantil.}
#'     \item{copulas}{Benannte Liste der [fit_copula()]-Tabellen je Paar oder
#'       \code{NULL}.}
#'     \item{rolling}{data.frame mit \code{date} und der rollierenden
#'       Korrelation je Paar (\code{NULL}, wenn die Historie nicht laenger als
#'       \code{window} ist).}
#'     \item{dcc}{Ergebnis von [dcc_fit()] oder \code{NULL}.}
#'     \item{conditional}{Liste je Zustandsvariable: data.frame je Paar und
#'       Regime mit \code{n}, \code{vol_1}, \code{vol_2} (annualisierte
#'       Volatilitaet der Log-Renditen als Anteil), \code{pearson},
#'       \code{spearman}, \code{kendall}, \code{lambda_lower},
#'       \code{lambda_upper}, \code{exceed_lower} (bei \code{tail_q}),
#'       \code{t_rho}, \code{t_nu}, \code{copula},
#'       \code{copula_lambda_lower} und mit Bootstrap \code{pearson_lo},
#'       \code{pearson_hi} (90-%-Intervall).}
#'     \item{regimes}{Liste je Zustandsvariable: \code{regime}, \code{n},
#'       \code{mean_state} (mittlerer Zustand im Regime).}
#'     \item{differences}{data.frame (oder \code{NULL}): oberstes minus
#'       unterstes Regime je Paar und Zustandsvariable, \code{diff_pearson},
#'       \code{diff_spearman} mit 95-%-Bootstrap-Intervall
#'       (\code{lo_}, \code{hi_}) und zweiseitigem p-Wert (\code{p_}).}
#'   }
#'   sowie \code{assets}, \code{conditions}, \code{frequency}, \code{ppy}
#'   (Perioden je Jahr, aus den Daten), \code{window}, \code{block},
#'   \code{B}, \code{tail_q}. Methoden \code{print} und \code{plot}.
#' @seealso [align_series()], [align_macro()] zur Vorbereitung;
#'   [tail_regression()], [covar_analysis()], [regime_subset()].
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
               kendall = .kendall(X))
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
      cv <- .roll_cov(x, y, window); vx <- .roll_var(x, window); vy <- .roll_var(y, window)
      roll[[pn[i]]] <- cv / sqrt(pmax(vx * vy, 1e-300))
    }
  }
  dc <- if (dcc && n >= 100) tryCatch(dcc_fit(X), error = function(e) { message("DCC nicht gesch\u00e4tzt: ", conditionMessage(e)); NULL }) else NULL
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
        fams <- if (length(s) >= 2 && isTRUE(.kendall(x, y) < 0)) c("t", "gaussian", "clayton_90", "clayton_270")
                else c("t", "gaussian", "clayton", "gumbel")
        tc <- if (copulas && length(s) >= 40) tryCatch(fit_copula(x, y, fams), error = function(e) NULL) else NULL
        tt <- if (!is.null(tc)) tc[tc$family == "t", ] else NULL
        rows[[length(rows) + 1L]] <- data.frame(
          pair = pn[i], regime = l, n = length(s),
          vol_1 = stats::sd(x) * sqrt(ppy), vol_2 = stats::sd(y) * sqrt(ppy),
          pearson = if (length(s) >= 10) stats::cor(x, y) else NA_real_,
          spearman = if (length(s) >= 10) stats::cor(x, y, method = "spearman") else NA_real_,
          kendall = if (length(s) >= 10) .kendall(x, y) else NA_real_,
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
        boot <- .with_rng_restore(seed = seed, {
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
  cat(sprintf("SimLev Abh\u00e4ngigkeitsanalyse: %d Perioden (%s), %s bis %s\n\n", nrow(rd), x$frequency,
              format(rd$date[1]), format(rd$date[nrow(rd)])))
  cat("Korrelation (Pearson unten links, Kendall oben rechts)\n")
  M <- x$correlation$pearson; M[upper.tri(M)] <- x$correlation$kendall[upper.tri(M)]
  print(round(M, 3))
  p <- x$pairs
  cat("\nTail-Abh\u00e4ngigkeit je Paar\n")
  qs <- grep("^lambda_lower_", names(p), value = TRUE)
  y <- data.frame(Paar = p$pair, Kendall = sprintf("%.3f", p$kendall), check.names = FALSE)
  for (k in qs) { q <- sub("lambda_lower_", "", k)
    y[[sprintf("lamL %s", q)]] <- sprintf("%.2f", p[[k]]); y[[sprintf("lamU %s", q)]] <- sprintf("%.2f", p[[sub("lower", "upper", k)]]) }
  if (!is.null(p$copula)) {
    y$Copula <- p$copula; y$`Cop. lamL` <- sprintf("%.2f", p$copula_lambda_lower); y$`Cop. lamU` <- sprintf("%.2f", p$copula_lambda_upper)
    y$`t: rho/nu` <- sprintf("%.2f / %.1f", p$t_rho, p$t_nu)
  }
  print(y, row.names = FALSE)
  cat("  (Unabh\u00e4ngigkeit: lam(q) ~ q; Gau\u00df-Abh\u00e4ngigkeit: lam -> 0 f\u00fcr kleine q)\n")
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
  if (!is.null(x$differences)) cat(sprintf("  (station\u00e4rer Block-Bootstrap, B = %d, mittlere Blockl\u00e4nge %.1f Perioden)\n", x$B, x$block))
  invisible(x)
}

#' @rdname dependence_analysis
#' @param x Objekt der Klasse \code{SimLevDependence}.
#' @param type Grafik: \code{"overview"} (Standard; die vier folgenden in
#'   einem 2 x 2-Raster), \code{"rolling"} (rollierende und DCC-Korrelation),
#'   \code{"tail"} (\eqn{\hat\lambda(q)} ueber q mit Copula-Werten),
#'   \code{"conditional"} (Pearson-Korrelation je Regime mit Intervall und
#'   unterem Tail-Koeffizienten) oder \code{"scatter"}
#'   (Pseudo-Beobachtungen, Tail-Bereiche bei \code{tail_q} markiert).
#' @param pair Paar als Nummer (Zeile in \code{x$pairs}, Standard 1) oder
#'   Name wie \code{"stocks ~ bonds"}.
#' @param condition Zustandsvariable als Nummer (Standard 1) oder Name.
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
                   ylab = expression(hat(lambda)(q)), main = sprintf("%s: Tail-Abh\u00e4ngigkeit", pn[i]))
    graphics::lines(qg, td$upper, type = "b", pch = 17, col = "#2C6E9B")
    graphics::lines(qg, qg, lty = 3, col = "grey40")
    if (!is.null(x$copulas)) { cp <- x$copulas[[pn[i]]][1, ]
      graphics::abline(h = cp$lambda_lower, col = "#B5562B", lty = 2); graphics::abline(h = cp$lambda_upper, col = "#2C6E9B", lty = 2) }
    graphics::legend("topright", c("unten (gemeinsame Verluste)", "oben (gemeinsame Gewinne)", "Unabh\u00e4ngigkeit",
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
#' Schaetzt die Koeffizienten des bedingten \eqn{\tau}-Quantils von \code{y}
#' (Koenker & Bassett 1978), d. h. minimiert
#' \eqn{\sum_i \rho_\tau(y_i - x_i'\beta)} mit
#' \eqn{\rho_\tau(r) = r(\tau - 1\{r < 0\})}. Geliefert wird die exakte
#' Loesung dieses linearen Programms mit Optimalitaetsnachweis (Ausnahme:
#' entartete Faelle, siehe unten), berechnet in zwei Schritten (Kern in
#' C++):
#' \enumerate{
#'   \item MM-Algorithmus von Hunter & Lange (2000), ausgehend von der
#'     KQ-Loesung: iterativ gewichtete kleinste Quadrate mit
#'     \deqn{\beta \leftarrow (X'WX)^{-1}(X'Wy + (\tau - 1/2) X'1),\quad
#'       W = \mathrm{diag}(1 / (2(\epsilon + |r_i|)))}
#'     in vier Stufen mit \eqn{\epsilon} = sd(y) mal 1e-2, 1e-4, 1e-6, 1e-8.
#'   \item Ecken-Politur: Aus den p Beobachtungen mit den kleinsten Residuen
#'     der Naeherung (linear unabhaengig gewaehlt) wird die Ecke des linearen
#'     Programms berechnet, die diese Beobachtungen exakt interpoliert, und
#'     ueber die Subgradientenbedingung auf Optimalitaet geprueft (an
#'     entarteten Ecken wie unten per linearem Programm). Ist der
#'     Nachweis erbracht (nach jeder Stufe und alle 25 Iterationen
#'     geprueft), ist diese Ecke das Ergebnis.
#' }
#' Gelingt der Nachweis bis zur letzten Stufe nicht (z. B. bei \eqn{\tau}
#' nahe 0 oder 1, wenn die Naeherung noch weit von der Ecke entfernt ist),
#' folgen von dieser Ecke aus Austauschschritten wie im Simplex-Verfahren von
#' Barrodale & Roberts (1974): Solange eine Kante der Ecke abwaerts fuehrt,
#' wird entlang der steilsten bis zum Minimum gegangen; die Zielfunktion
#' faellt dabei streng. Ohne Abstiegskante wird die Optimalitaet exakt
#' nachgewiesen; an entarteten Ecken (weitere Residuen exakt 0, z. B. bei
#' diskreten Regressoren, gerundeten Werten oder doppelten Beobachtungen)
#' ueber die Bedingung, dass 0 im Teildifferential liegt: Es muss
#' \eqn{\lambda_j \in [\tau - 1, \tau]} fuer die Beobachtungen mit
#' Residuum 0 geben mit \eqn{\sum_j \lambda_j x_j = -\sum_{r_i \neq 0}
#' \psi_\tau(r_i) x_i}; geprueft als lineares Zulaessigkeitsproblem (Phase 1
#' des Simplex-Verfahrens mit beschraenkten Variablen, gleiche Zeilen
#' \eqn{x_j} zusammengefasst). Scheitert der Nachweis, erscheint eine
#' Warnung, und geliefert wird die gefundene Ecke, sofern ihr Zielwert nicht
#' groesser ist als der der MM-Naeherung, sonst die MM-Naeherung. Ist die Loesung nicht eindeutig (z. B. ohne Regressoren,
#' wenn n * tau ganzzahlig ist), wird eine der optimalen Loesungen
#' geliefert.
#'
#' @param y Numerischer Vektor, Zielvariable (beliebige Einheit).
#' @param X Regressoren als numerischer Vektor, Matrix oder data.frame (ohne
#'   Konstante). \code{NULL} (Standard) = nur Konstante, d. h. das
#'   empirische \eqn{\tau}-Quantil von \code{y}. Zeilen mit nicht endlichen
#'   Werten in \code{y} oder \code{X} werden entfernt. Erwartet werden
#'   \code{length(y)} Zeilen, nur numerische Spalten (Faktoren vorher in
#'   Indikatorspalten umwandeln) und linear unabhaengige Regressoren
#'   einschliesslich der Konstante; sonst bricht die Funktion mit Fehler ab.
#' @param tau Quantil als Anteil, echt zwischen 0 und 1 (Standard 0.5 =
#'   Median-Regression).
#' @param intercept Logisch: Konstante aufnehmen (Standard \code{TRUE}).
#' @param tol Konvergenzschwelle der MM-Stufen: Eine Stufe endet, wenn sich
#'   kein Koeffizient um mehr als \code{tol * (1 + max|beta|)} aendert (in
#'   den ersten drei Stufen wird hoechstens 1e-7 verlangt). Standard 1e-10.
#' @param maxit Hoechstzahl der Iterationen je MM-Stufe (ganze Zahl,
#'   Standard 2000).
#' @return Benannter numerischer Koeffizientenvektor in der Einheit von
#'   \code{y} je Einheit des Regressors: \code{"(Intercept)"} (falls
#'   \code{intercept = TRUE}) und je Spalte von \code{X} deren Name (sonst
#'   \code{x1}, \code{x2}, ...).
#' @seealso [tail_regression()] und [covar_analysis()] nutzen
#'   \code{quantile_reg()} fuer Renditen.
#' @references Koenker, R. & Bassett, G. (1978), Econometrica 46(1);
#'   Hunter, D. R. & Lange, K. (2000), Journal of Computational and Graphical
#'   Statistics 9(1); Barrodale, I. & Roberts, F. D. K. (1974), Communications
#'   of the ACM 17(6).
#' @examples
#' set.seed(1); x <- rnorm(500); y <- 1 + 2 * x + rnorm(500) * (1 + abs(x))
#' quantile_reg(y, x, 0.9)
#' @export
quantile_reg <- function(y, X = NULL, tau = 0.5, intercept = TRUE, tol = 1e-10, maxit = 2000L) {
  if (!is.numeric(tau) || length(tau) != 1 || !is.finite(tau) || tau <= 0 || tau >= 1)
    stop(sprintf("quantile_reg: tau muss eine Zahl echt zwischen 0 und 1 sein (erhalten: %s).", paste(format(tau), collapse = ", ")))
  if (!is.numeric(y)) stop("quantile_reg: y muss numerisch sein.")
  y <- as.numeric(y)
  if (is.data.frame(X)) {
    nn <- names(X)[!vapply(X, is.numeric, TRUE)]
    if (length(nn)) stop(sprintf("quantile_reg: Spalte(n) %s von X nicht numerisch (Faktoren vorher z. B. mit model.matrix() in Indikatorspalten umwandeln).",
                                 paste0("'", nn, "'", collapse = ", ")))
  }
  X <- if (is.null(X)) matrix(0, length(y), 0) else as.matrix(X)
  if (!is.numeric(X)) stop("quantile_reg: X muss numerisch sein.")
  if (nrow(X) != length(y)) stop(sprintf("quantile_reg: X hat %d Zeilen, y aber %d Werte.", nrow(X), length(y)))
  nm <- colnames(X) %||% if (ncol(X)) paste0("x", seq_len(ncol(X))) else character(0)
  if (intercept) { X <- cbind(1, X); nm <- c("(Intercept)", nm) }
  ok <- is.finite(y) & rowSums(!is.finite(X)) == 0; y <- y[ok]; X <- X[ok, , drop = FALSE]
  if (!ncol(X)) stop("quantile_reg: keine Regressoren (X = NULL und intercept = FALSE).")
  if (length(y) < ncol(X)) stop(sprintf("quantile_reg: %d vollst\u00e4ndige Beobachtungen f\u00fcr %d Koeffizienten.", length(y), ncol(X)))
  qx <- qr(X)
  if (qx$rank < ncol(X))
    stop(sprintf("quantile_reg: Regressoren linear abh\u00e4ngig (%s); doppelte oder konstante Spalten entfernen (die Konstante ist bei intercept = TRUE schon enthalten).",
                 paste0("'", nm[qx$pivot[(qx$rank + 1):ncol(X)]], "'", collapse = ", ")))
  beta <- qr.coef(qx, y)
  sc <- max(stats::sd(y), 1e-12)
  storage.mode(X) <- "double"
  beta <- .quantile_reg_core(y, X, tau, as.numeric(beta), sc, tol, as.integer(maxit))
  if (!isTRUE(attr(beta, "optimal")))
    warning("quantile_reg: Optimalit\u00e4t nicht nachgewiesen; Ergebnis ist eine Ecke mit nicht gr\u00f6\u00dferem Zielwert als die MM-N\u00e4herung (bzw. die MM-N\u00e4herung selbst, falls keine solche Ecke gefunden wurde).")
  stats::setNames(as.numeric(beta), nm)
}

#' Renditequantile in Abhaengigkeit von Drittvariablen
#'
#' Schaetzt fuer mehrere Quantile, wie sich die Verteilung der Periodenrendite
#' einer Anlage mit dem (verzoegerten) Zustand von Drittvariablen verschiebt
#' (lineare Quantilsregression mit [quantile_reg()], zum Vergleich OLS fuer
#' den Mittelwert). Ein negativer Koeffizient der Inflation im 5-%-Quantil
#' heisst z. B.: Bei hoeherer Inflation fallen die schlechten Perioden
#' schlechter aus, auch wenn sich der Median kaum bewegt. Standardfehler per
#' stationaerem Block-Bootstrap der Perioden.
#'
#' Zielgroesse ist die Log-Rendite der Periode in Prozent,
#' \eqn{100 \log(P_t / P_{t-1})}; die Kurse werden wie in
#' [dependence_analysis()] aufbereitet (Fortschreiben fehlender Werte,
#' letzte Zeile je ISO-Woche bzw. Monat). Die Treiber gehen mit ihrem Wert am
#' Ende der Vorperiode in ihrer eigenen Einheit ein.
#'
#' @param data data.frame mit Spalte \code{date} (Date), Kursspalte
#'   (Kursniveaus, keine Renditen) und Zustandsspalten.
#' @param asset Name der Kursspalte (Zeichenkette).
#' @param drivers Zeichenvektor der Zustandsspalten (Drittvariablen).
#' @param quantiles Numerischer Vektor der Quantile als Anteil (Standard
#'   \code{c(0.05, 0.25, 0.5, 0.75, 0.95)}).
#' @param frequency Renditefrequenz: \code{"week"} (Standard, ISO-Woche),
#'   \code{"day"} oder \code{"month"}.
#' @param B Anzahl Bootstrap-Wiederholungen (ganze Zahl, Standard 199; 0 =
#'   keine Standardfehler und Intervalle).
#' @param block Mittlere Blocklaenge des stationaeren Bootstraps in Perioden.
#'   \code{NULL} (Standard) = Politis-White-Schaetzung auf den absoluten
#'   Abweichungen der Rendite vom Mittel (begrenzt auf 2 bis n / 10).
#' @param seed Startwert fuer den Bootstrap. Mit Startwert ist das Ergebnis reproduzierbar und der
#'   Zufallszustand der Sitzung bleibt unveraendert; mit `NULL` wird der
#'   Zufallsstrom der Sitzung normal weitergezogen.
#' @return Objekt der Klasse \code{SimLevTailRegression} mit
#'   \code{coefficients} (data.frame: \code{quantile}, \code{term},
#'   \code{estimate}, \code{se} (Bootstrap-Standardabweichung),
#'   \code{lower}, \code{upper} (90-%-Bootstrap-Intervall, 5- und
#'   95-%-Quantil); Koeffizienten in Prozentpunkten Log-Rendite je Periode
#'   bzw. je Einheit des Treibers), \code{ols} (OLS-Koeffizienten, gleiche
#'   Einheit), \code{data} (aufbereitete Perioden: \code{date}, Log-Rendite
#'   als Anteil, verzoegerte Treiber) sowie \code{asset}, \code{drivers},
#'   \code{quantiles}, \code{n} (Anzahl Perioden), \code{frequency},
#'   \code{B}, \code{B_failed} (Anzahl Bootstrap-Stichproben, die nicht
#'   schaetzbar waren, z. B. weil ein Treiber in der Stichprobe konstant ist;
#'   sie fehlen in Standardfehlern und Intervallen, mit Warnung),
#'   \code{block}. Methoden \code{print} und \code{plot}.
#' @seealso [align_macro()] zur Vorbereitung der Treiber,
#'   [dependence_analysis()], [covar_analysis()], [quantile_reg()].
#' @examples
#' set.seed(1); n <- 3 * 365
#' d <- data.frame(date = seq.Date(as.Date("2015-01-01"), by = "day", length.out = n))
#' d$inflation <- 2 + cumsum(rnorm(n, 0, 0.05))
#' d$aktien <- 100 * cumprod(1 + rnorm(n, 3e-4, 0.01))
#' tr <- tail_regression(d, "aktien", "inflation", quantiles = c(0.05, 0.5, 0.95),
#'                       B = 49, seed = 1)
#' tr
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
  X1 <- cbind(1, X); storage.mode(X1) <- "double"
  qfit <- function(yb, Xb, k)                                   # Bootstrap: Start bei der Punktschaetzung
    as.numeric(.quantile_reg_core(yb, Xb, quantiles[k], est[, k], max(stats::sd(yb), 1e-12), 1e-10, 2000L))
  terms <- c("(Intercept)", drivers)
  se <- lo <- hi <- matrix(NA_real_, nrow(est), ncol(est))
  n_failed <- 0L
  if (B > 0) {
    block <- block %||% min(max(2, .pw_block(abs(y - mean(y)))[["stationary"]]), n / 10)
    bs <- .with_rng_restore(seed = seed, {
      lapply(seq_len(B), function(b) { idx <- .boot_idx_stationary(n, n, block)
        yb <- y[idx]; Xb <- X1[idx, , drop = FALSE]
        # z. B. Treiber in der Stichprobe konstant -> singulaer: Wiederholung als NA
        tryCatch(vapply(seq_along(quantiles), function(k) qfit(yb, Xb, k), numeric(ncol(X) + 1)),
                 error = function(e) matrix(NA_real_, ncol(X) + 1, length(quantiles))) })
    })
    n_failed <- sum(vapply(bs, anyNA, TRUE))
    if (n_failed == B) warning(sprintf("tail_regression: keine der %d Bootstrap-Stichproben sch\u00e4tzbar (singul\u00e4re Regressoren); keine Standardfehler.", B))
    else if (n_failed > 0) warning(sprintf("tail_regression: %d von %d Bootstrap-Stichproben nicht sch\u00e4tzbar (singul\u00e4re Regressoren, z. B. Treiber in der Stichprobe konstant); Standardfehler und Intervalle aus den \u00fcbrigen %d.",
                                           n_failed, B, B - n_failed))
    A <- simplify2array(bs); if (length(dim(A)) == 2) A <- array(A, c(1, dim(A)))
    se <- apply(A, c(1, 2), stats::sd, na.rm = TRUE)
    lo <- apply(A, c(1, 2), stats::quantile, 0.05, na.rm = TRUE); hi <- apply(A, c(1, 2), stats::quantile, 0.95, na.rm = TRUE)
  }
  coefs <- data.frame(quantile = rep(quantiles, each = length(terms)), term = rep(terms, length(quantiles)),
                      estimate = as.vector(est), se = as.vector(se), lower = as.vector(lo), upper = as.vector(hi),
                      stringsAsFactors = FALSE)
  ols <- stats::coef(stats::lm(y ~ X)); names(ols) <- terms
  structure(list(coefficients = coefs, ols = ols, asset = asset, drivers = drivers, quantiles = quantiles,
                 n = n, frequency = frequency, B = B, B_failed = n_failed, block = block, data = rd), class = "SimLevTailRegression")
}

#' @export
print.SimLevTailRegression <- function(x, ...) {
  cat(sprintf("Quantilsregression: Rendite '%s' (%% je %s) auf verz\u00f6gerte %s; %d Perioden\n\n",
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
#' Dabei ist \eqn{VaR^i_t(p)} das per [quantile_reg()] geschaetzte
#' (bei \code{state = NULL} konstante) p-Quantil der Rendite der Anlage, also
#' eine Rendite mit Vorzeichen (Verluste negativ), und
#' \eqn{CoVaR_t = \alpha + \beta VaR^i_t(q) + \gamma' M_{t-1}}.
#' Renditen sind Log-Renditen der Periode in Prozent,
#' \eqn{100 \log(P_t / P_{t-1})}, aufbereitet wie in
#' [dependence_analysis()] (Fortschreiben fehlender Kurse, letzte Zeile je
#' ISO-Woche bzw. Monat); Zustandsvariablen gehen mit dem Wert am Ende der
#' Vorperiode ein. Perioden mit fehlenden Werten entfallen.
#'
#' @param data data.frame mit Spalte \code{date} (Date), Kursspalten
#'   (Kursniveaus, keine Renditen) und gegebenenfalls Zustandsspalten.
#' @param system Name der Kursspalte des Systems bzw. Portfolios
#'   (Zeichenkette).
#' @param assets Zeichenvektor der Kursspalten der einzelnen Anlagen.
#' @param state Optionaler Zeichenvektor der Zustandsspalten (in ihrer
#'   eigenen Einheit). \code{NULL} (Standard) = zeitkonstante Quantile.
#' @param q Quantil als Anteil (Standard 0.05 = 5-%-Quantil).
#' @param frequency Renditefrequenz: \code{"week"} (Standard, ISO-Woche),
#'   \code{"day"} oder \code{"month"}.
#' @return Objekt der Klasse \code{SimLevCoVaR} mit
#'   \describe{
#'     \item{summary}{data.frame je Anlage: \code{asset}, \code{beta}
#'       (Steigung der Systemrendite auf die Anlagerendite im q-Quantil,
#'       ohne Einheit), \code{var}, \code{covar}, \code{delta_covar} (Mittel
#'       ueber die Zeit) und \code{delta_covar_min} (kleinster Wert), alle
#'       ausser \code{beta} in Prozent je Periode (Renditen mit Vorzeichen,
#'       Verluste negativ).}
#'     \item{series}{data.frame mit \code{date}, \code{asset}, \code{var},
#'       \code{covar}, \code{delta_covar} je Periode und Anlage (Prozent je
#'       Periode).}
#'   }
#'   sowie \code{system}, \code{state}, \code{q}, \code{frequency} und
#'   \code{n} (Anzahl Perioden). Methoden \code{print} und \code{plot}.
#' @seealso [quantile_reg()], [tail_regression()], [dependence_analysis()],
#'   [risk_contributions()].
#' @examples
#' set.seed(1); n <- 3 * 365
#' d <- data.frame(date = seq.Date(as.Date("2015-01-01"), by = "day", length.out = n))
#' e <- rnorm(n)
#' d$aktien <- 100 * cumprod(1 + 0.01 * e)
#' d$anleihen <- 100 * cumprod(1 + 0.004 * (0.3 * e + rnorm(n)))
#' d$portfolio <- 0.6 * d$aktien + 0.4 * d$anleihen
#' covar_analysis(d, "portfolio", c("aktien", "anleihen"), q = 0.05)
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
  cat(sprintf("CoVaR (q = %g) f\u00fcr System '%s'%s; %d Perioden (%s), Werte in %% je Periode\n\n", x$q, x$system,
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
                 main = sprintf("Delta-CoVaR f\u00fcr '%s' (q = %g)", x$system, x$q))
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
#' Alle Kennzahlen werden auf Log-Renditen berechnet, die ueber
#' nicht ueberlappende Bloecke von \code{agg} Zeilen summiert werden (ein
#' unvollstaendiger Rest am Ende entfaellt; mindestens 20 Bloecke noetig).
#' Historie: Renditen der Indizes aus \code{data} gemaess
#' \code{boot$config} (Brutto-Renditen bzw. Kurse bei
#' \code{input = "prices"}); Pfade: Log-Differenzen der Indexspalten der
#' Pfade. Hebelprodukte und Zusatzreihen gehen nicht ein.
#'
#' @param boot Objekt der Klasse \code{bootstrap_result} aus [bootstrap()]
#'   mit mindestens zwei Indizes in der Konfiguration.
#' @param data Historische Daten wie fuer [bootstrap()] (data.frame oder
#'   Matrix mit den Spalten der Konfiguration).
#' @param agg Zeilen je Periode fuer die Aggregation (ganze Zahl, Standard 5;
#'   z. B. 5 Handelstage oder 7 Kalendertage ergibt Wochen; 1 = keine
#'   Aggregation).
#' @param q Tail-Wahrscheinlichkeit als Anteil fuer die Tail-Kennzahlen
#'   (Standard 0.10, siehe [tail_dependence()]).
#' @param max_paths Hoechstens so viele Pfade auswerten (die ersten
#'   \code{max_paths} Pfade; Standard 200).
#' @return data.frame mit einer Zeile je Indexpaar und Kennzahl:
#'   \code{pair}, \code{metric} (\code{"kendall"}, \code{"pearson"},
#'   \code{"lambda_lower"}, \code{"lambda_upper"}, \code{"exceed_lower"}),
#'   \code{historical} (Wert der Historie), \code{median}, \code{p05},
#'   \code{p95} (Median und 5-/95-%-Quantil ueber die Pfade) und
#'   \code{percentile} (Anteil der Pfade mit Wert <= Historie, 0 bis 1;
#'   Werte nahe 0 oder 1 zeigen, dass die Pfade die Kennzahl nicht
#'   wiedergeben).
#' @seealso [bootstrap()], [validate_bootstrap()], [tail_dependence()],
#'   [dependence_analysis()].
#' @examples
#' set.seed(2)
#' d <- data.frame(us = 1 + rnorm(1500, 3e-4, 0.01))
#' d$eu <- d$us * (1 + rnorm(1500, 0, 0.004))
#' cfg <- bootstrap_config(c(us = "us", eu = "eu"))
#' b <- bootstrap(d, cfg, "stationary", n = 20, params = list(L = 20), seed = 1,
#'                progress = FALSE)
#' validate_dependence(b, d, agg = 5, q = 0.10)
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
      c(kendall = .kendall(x, y), pearson = stats::cor(x, y),
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
#' Zusatzreihen wie Zinsen). Die Episoden werden ohne Trennung
#' aneinandergehaengt; Bootstrap-Bloecke koennen daher ueber
#' Episodengrenzen hinwegreichen.
#'
#' @param data data.frame, eine Zeile je Beobachtung (fuer [bootstrap()]
#'   typischerweise Tage mit Brutto-Renditen wie 1.002 und Zusatzreihen).
#'   Eine Spalte \code{date} ist optional.
#' @param condition Logischer Vektor der Laenge \code{nrow(data)} (NA =
#'   FALSE) oder Ausdruck als Zeichenkette, der in \code{data} ausgewertet
#'   wird, z. B. \code{"inflation >= 4"}.
#' @param min_run Mindestlaenge einer Episode in Zeilen (ganze Zahl,
#'   Standard 1); kuerzere zusammenhaengende Abschnitte werden verworfen.
#' @return Teilmenge von \code{data} (Zeilen der behaltenen Episoden in
#'   urspruenglicher Reihenfolge) mit Attribut \code{episodes}: data.frame
#'   mit \code{start}, \code{end} (Zeilennummern in \code{data}),
#'   \code{length} (Zeilen) und, falls \code{data} eine Spalte \code{date}
#'   hat, \code{start_date}, \code{end_date}. Fehler, wenn keine Episode
#'   die Bedingung erfuellt.
#' @seealso [bootstrap()], [bootstrap_study()], [bootstrap_config()],
#'   [dependence_analysis()] (Regime nach Zustandsvariablen).
#' @examples
#' set.seed(1)
#' d <- data.frame(r = 1 + rnorm(100, 0, 0.01), infl = c(rep(1, 40), rep(5, 30), rep(1, 30)))
#' s <- regime_subset(d, "infl >= 4", min_run = 10)
#' attr(s, "episodes")
#' @export
regime_subset <- function(data, condition, min_run = 1L) {
  cond <- if (is.character(condition)) eval(parse(text = condition), data, parent.frame()) else condition
  cond <- as.logical(cond); cond[is.na(cond)] <- FALSE
  if (length(cond) != nrow(data)) stop("condition muss die L\u00e4nge nrow(data) haben.")
  r <- rle(cond); ends <- cumsum(r$lengths); starts <- ends - r$lengths + 1L
  keep <- r$values & r$lengths >= min_run
  if (!any(keep)) stop("regime_subset: keine Episode erf\u00fcllt condition und min_run.")
  rows <- unlist(Map(seq.int, starts[keep], ends[keep]))
  out <- data[rows, , drop = FALSE]
  ep <- data.frame(start = starts[keep], end = ends[keep], length = r$lengths[keep])
  if ("date" %in% names(data)) { d <- .to_date(data$date, "regime_subset: data$date")
                                 ep$start_date <- d[ep$start]; ep$end_date <- d[ep$end] }
  attr(out, "episodes") <- ep
  out
}

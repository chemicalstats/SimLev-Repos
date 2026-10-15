# =============================================================================
#  bootstrap.R  —  Bootstrap-Pfade fuer Indizes, Hebelprodukte und Signale
# -----------------------------------------------------------------------------
#  Portierung und Verallgemeinerung von '00 Bootstraps' (boot_helper.R und
#  C++-Kerne) sowie der Studienlogik aus '06 Bootstraps':
#
#    bootstrap_config()   Spezifikation: Indizes, Hebelprodukte, Zusatzreihen
#    bootstrap()          erzeugt Preis-Pfade (im Speicher)
#    bootstrap_study()    erzeugt Pfade, berechnet Signale, simuliert
#                         Strategien mit simulation() und behaelt nur Kennzahlen
#                         (streamend, parallel, fortsetzbar)
#    block_length()       automatische Blocklaenge (Politis & White 2004,
#                         Korrektur Patton, Politis & White 2009)
#
#  Verfahren: raw, block, circular, stationary, wild, regime, evt, tails,
#  reset, garch, gjr_garch, ms_garch, ms_ar_garch_m, tvtp_ms_garch.
#
#  Neu gegenueber dem Original:
#    * beliebig viele Indizes (nicht nur USD/EUR), Zusatzreihen (Zins,
#      Inflation, Kalendertage) werden ueber denselben Zeilenindex mitgezogen
#    * Filtered Historical Simulation: ein gemeinsames historisches Datum je
#      Tag fuer alle Residuen (Korrelation Index/FX bleibt erhalten)
#    * Pfadlaenge frei waehlbar (length), zirkulaerer Block-Bootstrap
#    * Hebelprodukte nach MSCI-Formel mit Zinsreihe statt konstantem Satz
#    * reproduzierbare Zufallsstroeme je Pfad (unabhaengig von der Kernzahl)
# =============================================================================


# ─────────────────────────────────────────────────────────────────────────────
# Konfiguration
# ─────────────────────────────────────────────────────────────────────────────

#' Bootstrap-Konfiguration erstellen
#'
#' Beschreibt, welche Reihen gebootstrappt werden, welche Hebelprodukte daraus
#' abgeleitet werden und welche Zusatzreihen (Zinsen, Inflation, ...) jeweils
#' aus derselben historischen Zeile mitgezogen werden.
#'
#' @param indices Benannter Vektor oder benannte Liste: Pfadname -> Spaltenname,
#'   z. B. \code{c(us = "us_index_l1_return", eu = "eu_index_l1_return")}.
#' @param letfs Liste von Hebelprodukten. Jedes Element ist eine Liste mit
#'   \describe{
#'     \item{base}{Name des Basisindex (aus \code{indices}), Pflicht}
#'     \item{leverage}{Hebel L (Standard 2; negativ fuer Short)}
#'     \item{finance}{Finanzierungszins in Prozent p. a. (Skalar) oder Name
#'       einer Zusatzreihe aus \code{aux} (Standard 3.5)}
#'     \item{expense}{TER in Prozent p. a. (Standard 0.5)}
#'     \item{spread}{Spread auf den finanzierten bzw. leerverkauften Anteil in
#'       Prozent p. a. (Standard 0)}
#'     \item{days}{Kalendertage je Zeile: Skalar (Standard 1) oder Name einer
#'       Zusatzreihe (z. B. Datumsabstand bei Handelstagsdaten)}
#'     \item{rate_basis, ter_basis}{Tagesbasis (Standard 360 bzw. 365)}
#'     \item{name}{Spaltenname im Pfad (Standard z. B. "eu_l2", "us_inv1")}
#'   }
#'   Tagesrendite (MSCI Daily Leveraged/Short, plus Fondskosten):
#'   \deqn{r = 1 + L (R - 1) + (1 - L) i \cdot d / 360 - TER \cdot d / 365
#'         - s \cdot m(L) \cdot d / 360}
#'   mit \eqn{m(L) = \max(L-1,0) + \max(-L,0)}. Fuer L = 2 und konstantem
#'   Zins entspricht das dem Original (Finanzierung auf L - 1); fuer Short-
#'   Produkte wird - anders als im Original - der Zinsertrag auf Kapital und
#'   Leerverkaufserloes gutgeschrieben (MSCI-Methodik: \eqn{-R + 2i}).
#' @param regime_index Name des Referenzindex fuer Regime-/GARCH-Verfahren
#'   (Standard: erster Index).
#' @param aux Optional benannter Vektor Zusatzreihen: Pfadname -> Spaltenname,
#'   z. B. \code{c(rate = "eu_rate", cpi = "eu_cpi")}. Werte werden nicht
#'   simuliert, sondern aus der jeweils gezogenen historischen Zeile uebernommen.
#' @param cross Kopplung der Nicht-Referenzreihen bei EVT/GARCH-Verfahren:
#'   \code{"ratio"} (Standard, wie Original: Reihe = Referenz x Verhaeltnis,
#'   z. B. EUR-Index = USD-Index x Wechselkurs) oder \code{"joint"} (eigene
#'   GARCH-Dynamik je Reihe, Kopplung nur ueber das gemeinsame Residuendatum).
#' @param input \code{"returns"} (Brutto-Renditen > 0, wie im Original) oder
#'   \code{"prices"} (Kursniveaus; Renditen werden intern gebildet).
#'
#' @return Objekt der Klasse \code{bootstrap_config}.
#' @examples
#' cfg <- bootstrap_config(
#'   indices = c(us = "us_ret", eu = "eu_ret"), regime_index = "us",
#'   letfs = list(list(base = "eu", leverage = 2, finance = "rate", expense = 0.5)),
#'   aux = c(rate = "eu_rate"))
#' cfg
#' @seealso [bootstrap()], [bootstrap_study()]
#' @export
bootstrap_config <- function(indices, letfs = list(), regime_index = NULL, aux = NULL,
                             cross = c("ratio", "joint"), input = c("returns", "prices")) {
  cross <- match.arg(cross); input <- match.arg(input)
  if (is.null(names(indices)) || any(names(indices) == ""))
    stop("indices muss vollstaendig benannt sein: c(name1 = 'spalte1', ...)")
  index_names <- names(indices)
  if (anyDuplicated(index_names)) stop("Doppelte Index-Namen: ", paste(index_names[duplicated(index_names)], collapse = ", "))
  if (!is.null(aux) && (is.null(names(aux)) || any(names(aux) == ""))) stop("aux muss benannt sein.")
  aux_names <- names(aux) %||% character(0)

  letf_list <- lapply(seq_along(letfs), function(i) {
    l <- letfs[[i]]
    if (is.null(l$base)) stop(sprintf("LETF %d: 'base' muss angegeben werden", i))
    if (!l$base %in% index_names)
      stop(sprintf("LETF %d: base '%s' nicht in indices. Verfuegbar: %s", i, l$base, paste(index_names, collapse = ", ")))
    lev <- l$leverage %||% 2
    if (lev == 0) stop(sprintf("LETF %d: leverage darf nicht 0 sein", i))
    fin <- l$finance %||% 3.5
    if (is.character(fin) && !fin %in% aux_names) stop(sprintf("LETF %d: finance-Reihe '%s' nicht in aux.", i, fin))
    if (is.numeric(fin) && fin < 0) warning(sprintf("LETF %d: negativer Finanzierungszins.", i))
    exp_ <- l$expense %||% 0.5
    if (exp_ < 0) stop(sprintf("LETF %d: expense muss >= 0 sein", i))
    days <- l$days %||% 1
    if (is.character(days) && !days %in% aux_names) stop(sprintf("LETF %d: days-Reihe '%s' nicht in aux.", i, days))
    name <- l$name %||% (if (lev > 0) paste0(l$base, "_l", lev) else paste0(l$base, "_inv", abs(lev)))
    list(name = name, base = l$base, leverage = lev, finance = fin, expense = exp_,
         spread = l$spread %||% 0, days = days,
         rate_basis = l$rate_basis %||% 360, ter_basis = l$ter_basis %||% 365)
  })
  letf_names <- vapply(letf_list, function(x) x$name, "")
  if (anyDuplicated(c(index_names, letf_names, aux_names))) stop("Namen von Indizes, LETFs und aux muessen eindeutig sein.")

  if (is.null(regime_index)) regime_index <- index_names[1]
  else if (!regime_index %in% index_names) stop(sprintf("regime_index '%s' nicht in indices", regime_index))

  structure(list(
    indices = lapply(index_names, function(nm) list(name = nm, col = indices[[nm]])),
    letfs = letf_list, regime_index = regime_index, aux = aux, cross = cross, input = input,
    n_indices = length(index_names), n_letfs = length(letf_list), n_aux = length(aux_names),
    index_names = index_names, letf_names = letf_names, aux_names = aux_names
  ), class = "bootstrap_config")
}

#' @rdname bootstrap_config
#' @details \code{create_config()} ist ein Alias fuer Skripte, die die
#'   urspruengliche Hilfsfunktion aus '00 Bootstraps' verwenden.
#' @export
create_config <- function(indices, letfs = list(), regime_index = NULL, aux = NULL,
                          cross = c("ratio", "joint"), input = c("returns", "prices")) {
  bootstrap_config(indices, letfs = letfs, regime_index = regime_index, aux = aux,
                   cross = cross, input = input)
}

#' @rdname SimLevBootstrap-methods
#' @export
print.bootstrap_config <- function(x, ...) {
  cat("SimLev Bootstrap-Konfiguration\n------------------------------\n")
  cat(sprintf("  Indizes:      %s\n", paste(sprintf("%s=%s", x$index_names, vapply(x$indices, `[[`, "", "col")), collapse = ", ")))
  cat(sprintf("  Referenz:     %s (Kopplung: %s, Eingabe: %s)\n", x$regime_index, x$cross, x$input))
  if (x$n_aux) cat(sprintf("  Zusatzreihen: %s\n", paste(sprintf("%s=%s", x$aux_names, x$aux), collapse = ", ")))
  for (l in x$letfs) cat(sprintf("  Produkt %-8s Basis %s, L = %g, Zins = %s, TER = %g %%, Spread = %g %%\n",
                                 l$name, l$base, l$leverage, format(l$finance), l$expense, l$spread))
  invisible(x)
}


# ─────────────────────────────────────────────────────────────────────────────
# Interne Daten- und Parameterhelfer
# ─────────────────────────────────────────────────────────────────────────────

.boot_methods <- c("raw", "block", "circular", "stationary", "wild", "regime", "evt",
                   "tails", "reset", "garch", "gjr_garch", "ms_garch",
                   "ms_ar_garch_m", "tvtp_ms_garch")

#' Renditematrix und Zusatzreihen extrahieren
#' @keywords internal
.extract_returns <- function(data, config) {
  if (!is.data.frame(data) && !is.matrix(data)) stop("data muss ein data.frame oder eine Matrix sein")
  if (nrow(data) == 0) stop("data darf nicht leer sein")
  get_col <- function(col) {
    nms <- if (is.data.frame(data)) names(data) else colnames(data)
    if (!col %in% nms) stop(sprintf("Spalte '%s' nicht gefunden. Verfuegbar: %s", col, paste(nms, collapse = ", ")))
    as.numeric(if (is.data.frame(data)) data[[col]] else data[, col])
  }
  ret <- vapply(config$indices, function(ix) get_col(ix$col), numeric(nrow(data)))
  if (!is.matrix(ret)) ret <- matrix(ret, nrow = nrow(data))
  colnames(ret) <- config$index_names
  aux <- NULL
  if (config$n_aux) {
    aux <- vapply(unname(config$aux), get_col, numeric(nrow(data)))
    if (!is.matrix(aux)) aux <- matrix(aux, nrow = nrow(data))
    colnames(aux) <- config$aux_names
  }
  if (config$input == "prices") {
    ret <- ret[-1, , drop = FALSE] / ret[-nrow(ret), , drop = FALSE]
    if (!is.null(aux)) aux <- aux[-1, , drop = FALSE]
  }
  ok <- stats::complete.cases(ret) & (if (is.null(aux)) TRUE else stats::complete.cases(aux))
  if (!all(ok)) {
    message(sprintf("Hinweis: %d unvollstaendige Zeilen entfernt.", sum(!ok)))
    ret <- ret[ok, , drop = FALSE]; if (!is.null(aux)) aux <- aux[ok, , drop = FALSE]
  }
  if (any(ret <= 0)) stop("Renditen <= 0 gefunden (erwartet: Brutto-Renditen > 0, z. B. 1.002).")
  if (stats::median(abs(ret - 1)) > 0.5)
    warning("Renditen sehen nicht wie Brutto-Tagesrenditen aus (Median |R - 1| > 0.5). input = 'prices' vergessen?")
  list(ret = ret, aux = aux)
}

#' Standardparameter je Verfahren
#' @keywords internal
.get_base_params <- function(method, params, n) {
  defaults <- list(
    L = 20, block_length = 20, wild_type = 0, n_regimes = 2, vol_window = 20,
    tail_prob = 0.05, both_tails = TRUE, p_break = 0.02, garch_order = c(1, 1),
    ms_n_regimes = 2, ms_garch_model = "gjrGARCH", ms_ar_n_regimes = 2,
    ms_ar_garch_model = "gjrGARCH", tvtp_n_regimes = 2, tvtp_garch_model = "gjrGARCH")
  for (nm in names(defaults)) if (is.null(params[[nm]])) params[[nm]] <- defaults[[nm]]
  params
}

#' Standard-ESS-Gitter je Verfahren
#' @keywords internal
.get_ess_grid <- function(method, n) {
  grids <- list(
    raw = NULL, stationary = list(L = c(5, 10, 20, 30, 50, 75, 100)),
    block = list(block_length = c(5, 10, 20, 30, 50, 75, 100)),
    circular = list(block_length = c(5, 10, 20, 30, 50, 75, 100)),
    wild = list(wild_type = c(0, 1, 2)), regime = list(n_regimes = c(2, 3, 4)),
    evt = list(tail_prob = c(0.01, 0.025, 0.05, 0.10)),
    tails = list(tail_prob = c(0.01, 0.025, 0.05, 0.10)),
    reset = list(p_break = c(0.01, 0.02, 0.05, 0.10)), garch = NULL, gjr_garch = NULL,
    ms_garch = list(ms_n_regimes = c(2, 3)), ms_ar_garch_m = list(ms_ar_n_regimes = c(2, 3)),
    tvtp_ms_garch = list(tvtp_n_regimes = c(2, 3)))
  g <- grids[[method]]
  for (nm in c("L", "block_length")) if (!is.null(g[[nm]])) {
    g[[nm]] <- g[[nm]][g[[nm]] <= n / 2]
    if (!length(g[[nm]])) g[[nm]] <- min(5, floor(n / 4))
  }
  g
}

#' Effektive Stichprobengroesse je Konfiguration
#' @keywords internal
.calculate_ess <- function(n, method, params, info = NULL) {
  ess <- switch(method,
    raw = n, wild = n, reset = n, garch = n, gjr_garch = n,
    stationary = n / (params$L %||% 20),
    block = n / (params$block_length %||% 20), circular = n / (params$block_length %||% 20),
    regime = {
      K <- params$n_regimes %||% 2; ms <- 1
      if (!is.null(info$trans)) ms <- mean(1 / pmax(1e-6, 1 - diag(info$trans)))
      n / (K * ms)
    },
    evt = n * (1 - 2 * (params$tail_prob %||% 0.05)),
    tails = n * (1 - 2 * (params$tail_prob %||% 0.05)),
    ms_garch = n / ((params$ms_n_regimes %||% 2) * 2),
    ms_ar_garch_m = n / ((params$ms_ar_n_regimes %||% 2) * 2),
    tvtp_ms_garch = n / ((params$tvtp_n_regimes %||% 2) * 2), n)
  max(1, ess)
}


# ─────────────────────────────────────────────────────────────────────────────
# Automatische Blocklaenge
# ─────────────────────────────────────────────────────────────────────────────

#' Optimale Blocklaenge nach Politis & White (2004)
#'
#' Schaetzt die optimale (erwartete) Blocklaenge fuer den stationaeren und den
#' zirkulaeren Block-Bootstrap nach Politis & White (2004) mit der Korrektur von
#' Patton, Politis & White (2009) (Flat-Top-Lagfenster, \eqn{c = 2},
#' \eqn{K_N = \max(5, \sqrt{\log_{10} n})}).
#'
#' Hinweis: Das Verfahren optimiert die Varianzschaetzung des Mittelwerts.
#' Fuer taegliche Aktienrenditen ergeben sich oft sehr kurze Bloecke, weil die
#' Renditen kaum autokorreliert sind. Fuer Pfad-Simulationen mit
#' Trendfolge-Signalen ist daher \code{transform = "abs"} (Volatilitaets-
#' Clustering) und eine Sensitivitaetsanalyse ueber mehrere Blocklaengen zu
#' empfehlen; die Blocklaenge sollte die Signal-Lookback-Laenge nicht weit
#' unterschreiten.
#'
#' @param x Numerischer Vektor oder Matrix (Spalten = Reihen), z. B. Renditen.
#' @param transform \code{"none"}, \code{"abs"} (|x - mean|) oder \code{"squared"}.
#' @return Matrix mit Spalten \code{stationary} und \code{circular} (eine Zeile
#'   je Reihe).
#' @references Politis, D.N. & White, H. (2004), Econometric Reviews 23(1);
#'   Patton, A., Politis, D.N. & White, H. (2009), Econometric Reviews 28(4).
#' @examples
#' set.seed(1); x <- arima.sim(list(ar = 0.5), 2000)
#' block_length(x)
#' @export
block_length <- function(x, transform = c("none", "abs", "squared")) {
  transform <- match.arg(transform)
  x <- as.matrix(x)
  res <- t(apply(x, 2, function(v) {
    v <- v[is.finite(v)]
    v <- switch(transform, none = v, abs = abs(v - mean(v)), squared = (v - mean(v))^2)
    .pw_block(v)
  }))
  rownames(res) <- colnames(x) %||% paste0("V", seq_len(ncol(x)))
  res
}

#' @keywords internal
.pw_block <- function(x) {
  n <- length(x)
  if (n < 20) return(c(stationary = 1, circular = 1))
  KN <- max(5, sqrt(log10(n)))
  mmax <- ceiling(sqrt(n)) + KN
  bmax <- ceiling(min(3 * sqrt(n), n / 3))
  crit <- 2 * sqrt(log10(n) / n)
  xc <- x - mean(x)
  acov <- function(k) sum(xc[1:(n - k)] * xc[(1 + k):n]) / n
  r0 <- acov(0)
  if (r0 <= 0) return(c(stationary = 1, circular = 1))
  lags <- seq_len(floor(mmax))
  rho <- vapply(lags, acov, 0) / r0
  insig <- abs(rho) < crit
  KNi <- ceiling(KN)
  mhat <- NA
  for (k in seq_len(max(0, length(insig) - KNi + 1))) if (all(insig[k:(k + KNi - 1)])) { mhat <- k; break }
  if (is.na(mhat)) {
    sig <- which(!insig)
    mhat <- if (length(sig)) max(sig) else 1
  }
  M <- min(2 * mhat, floor(mmax))
  kk <- seq_len(M)
  lam <- function(t) ifelse(abs(t) <= 0.5, 1, ifelse(abs(t) <= 1, 2 * (1 - abs(t)), 0))
  Rk <- vapply(kk, acov, 0)
  G <- 2 * sum(lam(kk / M) * kk * Rk)
  g0 <- r0 + 2 * sum(lam(kk / M) * Rk)
  if (g0 <= 0) return(c(stationary = 1, circular = 1))
  b_sb <- (2 * G^2 / (2 * g0^2))^(1 / 3) * n^(1 / 3)
  b_cb <- (2 * G^2 / ((4 / 3) * g0^2))^(1 / 3) * n^(1 / 3)
  c(stationary = min(max(1, b_sb), bmax), circular = min(max(1, b_cb), bmax))
}

#' "auto"-Parameter aufloesen (L, block_length)
#' @keywords internal
.resolve_auto <- function(params, returns, config, method) {
  for (nm in c("L", "block_length")) if (identical(params[[nm]], "auto")) {
    base <- which(config$index_names == config$regime_index)
    lr <- log(returns)
    b <- rbind(block_length(lr), block_length(lr, "abs"))
    col <- if (nm == "L") "stationary" else "circular"
    params[[nm]] <- max(1, round(max(b[, col])))
    message(sprintf("Automatische Blocklaenge (%s, Politis-White, max. ueber Reihen und |r|): %d", nm, params[[nm]]))
  }
  params
}


# ─────────────────────────────────────────────────────────────────────────────
# Modellanpassung (GARCH-Familie, Regime, EVT)
# ─────────────────────────────────────────────────────────────────────────────

#' GARCH(1,1) / GJR-GARCH(1,1) schaetzen (rugarch -> optim -> Momente)
#' @keywords internal
.fit_garch11 <- function(e, gjr = FALSE, quiet = FALSE) {
  n <- length(e)
  mu <- mean(e); omega <- alpha <- beta <- NULL; gamma <- 0; method <- "none"
  if (stats::var(e) < 1e-16) {
    return(list(mu = mu, omega = 1e-20, alpha = 0, beta = 0, gamma = 0, s2 = rep(1e-20, n),
                z = rep(0, n), method = "konstant", s2_init = 1e-20))
  }
  if (requireNamespace("rugarch", quietly = TRUE)) tryCatch({
    spec <- rugarch::ugarchspec(variance.model = list(model = if (gjr) "gjrGARCH" else "sGARCH", garchOrder = c(1, 1)),
                                mean.model = list(armaOrder = c(0, 0), include.mean = TRUE),
                                distribution.model = "norm")
    fit <- rugarch::ugarchfit(spec = spec, data = e, solver = "hybrid")
    cf <- rugarch::coef(fit)
    mu <- unname(cf["mu"]); omega <- unname(cf["omega"]); alpha <- unname(cf["alpha1"]); beta <- unname(cf["beta1"])
    if (gjr) gamma <- unname(cf["gamma1"])
    method <- "rugarch"
  }, error = function(err) NULL)
  filt <- function(om, al, be, ga, m) {
    s2 <- numeric(n); v <- om / max(1e-6, 1 - al - be - ga / 2); ep <- e - m
    for (t in seq_len(n)) {
      s2[t] <- v
      v <- om + (al + ga * (ep[t] < 0)) * ep[t]^2 + be * v
      if (v < 1e-14) v <- 1e-14
    }
    s2
  }
  if (is.null(omega)) tryCatch({
    sv <- stats::var(e); ep <- e - mu
    nll <- function(th) {
      om <- exp(th[1]); al <- 0.5 / (1 + exp(-th[2])); be <- 0.999 / (1 + exp(-th[3]))
      ga <- if (gjr) 0.5 / (1 + exp(-th[4])) else 0
      if (al + be + ga / 2 >= 0.9999) return(1e10)
      s2 <- filt(om, al, be, ga, mu)
      0.5 * sum(log(s2) + ep^2 / s2)
    }
    lg <- function(p) log(p / (1 - p))
    st <- c(log(sv * 0.05), lg(0.05 / 0.5), lg(0.90 / 0.999), if (gjr) lg(0.04 / 0.5))
    if (gjr) st[2] <- lg(0.02 / 0.5)
    o <- stats::optim(st, nll, method = "Nelder-Mead", control = list(maxit = 4000))
    om <- exp(o$par[1]); al <- 0.5 / (1 + exp(-o$par[2])); be <- 0.999 / (1 + exp(-o$par[3]))
    ga <- if (gjr) 0.5 / (1 + exp(-o$par[4])) else 0
    if (o$value < 1e9 && al + be + ga / 2 < 0.9999) {
      omega <- om; alpha <- al; beta <- be; gamma <- ga; method <- "optim"
    }
  }, error = function(err) NULL)
  if (is.null(omega)) {
    sv <- stats::var(e); alpha <- 0.08; beta <- 0.88; gamma <- if (gjr) 0.04 else 0
    omega <- sv * (1 - alpha - beta - gamma / 2); method <- "momente"
    if (!quiet) warning("GARCH: rugarch und optim fehlgeschlagen, verwende Moment-Schaetzer")
  }
  s2 <- filt(omega, alpha, beta, gamma, mu)
  z <- (e - mu) / sqrt(s2)
  z[!is.finite(z)] <- 0
  if (stats::sd(z) > 0) z <- (z - mean(z)) / stats::sd(z)
  pers <- alpha + beta + gamma / 2
  list(mu = mu, omega = omega, alpha = alpha, beta = beta, gamma = gamma, s2 = s2, z = z,
       method = method, persistence = pers,
       s2_init = if (pers < 0.9999) omega / (1 - pers) else stats::var(e))
}

#' Nicht-Referenzreihen als GARCH(1,1) modellieren (ratio oder joint)
#' @keywords internal
.fit_cross <- function(returns, config, base) {
  k <- ncol(returns); others <- setdiff(seq_len(k), base); n <- nrow(returns)
  if (!length(others))
    return(list(cols = integer(0), mu = numeric(0), om = numeric(0), al = numeric(0), be = numeric(0),
                ratio = logical(0), s2 = numeric(0), z = matrix(0, n, 0)))
  ratio <- config$cross == "ratio"
  fits <- lapply(others, function(j) {
    e <- if (ratio) returns[, j] / returns[, base] - 1 else returns[, j] - 1
    f <- .fit_garch11(e, gjr = FALSE, quiet = TRUE)
    message(sprintf("  Kopplung %s (%s): mu=%.2e, omega=%.2e, alpha=%.4f, beta=%.4f [%s]",
                    colnames(returns)[j], config$cross, f$mu, f$omega, f$alpha, f$beta, f$method))
    f
  })
  list(cols = as.integer(others - 1L),
       mu = vapply(fits, `[[`, 0, "mu"), om = vapply(fits, `[[`, 0, "omega"),
       al = vapply(fits, `[[`, 0, "alpha"), be = vapply(fits, `[[`, 0, "beta"),
       ratio = rep(ratio, length(others)), s2 = vapply(fits, `[[`, 0, "s2_init"),
       z = do.call(cbind, lapply(fits, `[[`, "z")))
}

#' Tail-Schaetzung (GPD via evd -> Momente -> empirisch -> Default)
#' @keywords internal
.fit_tail <- function(base_ret, prob, side) {
  thr <- as.numeric(stats::quantile(base_ret, if (side == "left") prob else 1 - prob))
  mask <- if (side == "left") base_ret < thr else base_ret > thr
  exc <- if (side == "left") thr - base_ret[mask] else base_ret[mask] - thr
  ne <- length(exc); scale <- shape <- NULL; method <- "none"
  if (ne >= 30 && requireNamespace("evd", quietly = TRUE)) tryCatch({
    f <- evd::fpot(exc, threshold = 0, std.err = FALSE)
    scale <- unname(f$estimate["scale"]); shape <- unname(f$estimate["shape"]); method <- "MLE"
  }, error = function(e) NULL)
  if (is.null(scale) && ne >= 20) {
    m <- mean(exc); v <- stats::var(exc)
    if (v > 0 && m > 0) { ratio <- m^2 / v; shape <- max(-0.5, min(1, 0.5 * (1 - ratio)))
      scale <- max(1e-3, 0.5 * m * (1 + ratio)); method <- "Momente" }
  }
  if (is.null(scale) && ne >= 5) { scale <- max(1e-3, stats::sd(exc)); shape <- 0.1; method <- "empirisch" }
  if (is.null(scale)) { scale <- max(0.005, 2 * stats::sd(base_ret - 1)); shape <- 0.1; method <- "Default"
    warning(sprintf("Tail-Fit: Default-Parameter (nur %d Tail-Beobachtungen)", ne)) }
  if (shape >= 0.5) warning(sprintf("GPD shape = %.3f (%s): unendliche Varianz", shape, side))
  list(prob = prob, thresh = thr, scale = scale, shape = shape, pool = which(mask), method = method)
}

#' Regime aus rollierender Volatilitaet
#' @keywords internal
.prepare_regime_info <- function(base_ret, vol_window, n_regimes) {
  vol <- .rolling_vol(base_ret, as.integer(vol_window))
  th <- stats::quantile(vol, probs = seq(0, 1, length.out = n_regimes + 1))
  th[length(th)] <- th[length(th)] + 1e-10
  reg <- .assign_regimes(vol, th)
  list(regimes = reg, trans = .estimate_trans_mat(reg, as.integer(n_regimes)), vol = vol)
}

#' MS-GARCH-Familie vorbereiten (benoetigt MSGARCH)
#' @keywords internal
.prepare_ms_info <- function(returns, config, base, K, garch_model, ar_gm, tvtp) {
  if (!requireNamespace("MSGARCH", quietly = TRUE))
    stop("MS-GARCH-Verfahren erfordern das Paket 'MSGARCH' (install.packages('MSGARCH')).")
  ex <- returns[, base] - 1; n <- length(ex)
  spec <- MSGARCH::CreateSpec(variance.spec = list(model = rep(garch_model, K)),
                              distribution.spec = list(distribution = rep("norm", K)),
                              switch.spec = list(do.mix = FALSE))
  fit <- tryCatch(MSGARCH::FitML(spec = spec, data = ex),
                  error = function(e) stop(sprintf("MS-GARCH(%d, %s) Fit fehlgeschlagen: %s", K, garch_model, e$message)))
  cf <- fit$par
  g <- function(p) vapply(seq_len(K), function(r) { v <- cf[paste0(p, "_", r)]; if (is.na(v)) 0 else unname(v) }, 0)
  om <- g("alpha0"); al <- g("alpha1"); be <- g("beta"); ga <- if (garch_model == "gjrGARCH") g("alpha2") else rep(0, K)
  P <- MSGARCH::TransMat(fit)
  P <- P / rowSums(P)
  st <- MSGARCH::State(fit)
  reg <- if (!is.null(st$Viterbi)) as.integer(if (is.matrix(st$Viterbi) || is.array(st$Viterbi)) st$Viterbi[, 1] else st$Viterbi)
         else if (!is.null(st$SmoothProb)) apply(st$SmoothProb[-1, 1, , drop = TRUE], 1, which.max) else rep(1L, n)
  reg <- reg[seq_len(n)]
  mu <- vapply(seq_len(K), function(r) { i <- which(reg == r); if (length(i) >= 10) mean(ex[i]) else mean(ex) }, 0)
  s2 <- tryCatch(as.numeric(MSGARCH::Volatility(fit))^2, error = function(e) NULL)
  if (is.null(s2) || length(s2) != n) {
    s2 <- numeric(n); s2[1] <- stats::var(ex); res <- ex - mean(ex)
    for (t in 2:n) { r <- reg[t]; s2[t] <- max(1e-14, om[r] + (al[r] + ga[r] * (res[t - 1] < 0)) * res[t - 1]^2 + be[r] * s2[t - 1]) }
  }
  sig <- sqrt(pmax(s2, 1e-14))
  phi <- lam <- rep(0, K)
  lag_ex <- c(0, ex[-n])
  if (ar_gm) for (r in seq_len(K)) {
    i <- which(reg == r); if (length(i) < 30) next
    b <- tryCatch(stats::lm.fit(cbind(1, lag_ex[i]), ex[i])$coefficients[2], error = function(e) NA)
    if (is.finite(b)) phi[r] <- max(-0.5, min(0.5, b))
    l <- tryCatch(stats::lm.fit(cbind(sig[i]), ex[i] - mu[r] - phi[r] * lag_ex[i])$coefficients[1], error = function(e) NA)
    if (is.finite(l)) lam[r] <- max(-5, min(5, l))
  }
  unc <- vapply(seq_len(K), function(r) {
    p <- al[r] + be[r] + ga[r] / 2
    if (p < 0.9999 && om[r] > 0) om[r] / (1 - p) else { i <- which(reg == r); if (length(i) >= 10) stats::var(ex[i]) else stats::var(ex) }
  }, 0)
  delta <- matrix(0, K, K)
  if (tvtp) for (i in seq_len(K)) {
    from <- which(reg[-n] == i); if (length(from) < 50) next
    x <- s2[from] / unc[i] - 1; to <- reg[from + 1]
    for (j in seq_len(K)) if (j != i && sum(to == j) >= 5) {
      d <- tryCatch(stats::coef(stats::glm(as.integer(to == j) ~ x, family = stats::binomial()))["x"], error = function(e) NA)
      if (is.finite(d)) delta[i, j] <- max(-3, min(3, d))
    }
  }
  cm <- mu[reg] + phi[reg] * lag_ex + lam[reg] * sig
  z <- (ex - cm) / sig; z[!is.finite(z)] <- 0
  pools <- lapply(seq_len(K), function(r) { i <- which(reg == r); if (length(i) < 10) seq_len(n) else i })
  for (r in seq_len(K)) { i <- pools[[r]]; s <- stats::sd(z[i]); if (is.finite(s) && s > 0) z[i] <- (z[i] - mean(z[i])) / s }
  pi_ <- rep(1 / K, K); for (it in 1:1000) { p2 <- as.numeric(pi_ %*% P); if (max(abs(p2 - pi_)) < 1e-12) break; pi_ <- p2 }
  message(sprintf("MS-GARCH(%d, %s%s%s): P(stay) = %s", K, garch_model, if (ar_gm) ", AR-M" else "",
                  if (tvtp) ", TVTP" else "", paste(sprintf("%.3f", diag(P)), collapse = "/")))
  list(K = K, mu = mu, omega = om, alpha = al, beta = be, gamma = ga, phi = phi, lambda = lam,
       trans = P, delta = delta, unc = unc, stat = pi_ / sum(pi_), pools = lapply(pools, as.integer),
       z = z, regimes = reg, cross = .fit_cross(returns, config, base))
}

#' Verfahrensspezifische Vorberechnung
#' @keywords internal
.prepare_method_info <- function(returns, config, method, params) {
  p <- .get_base_params(method, params, nrow(returns))
  base <- which(config$index_names == config$regime_index)
  br <- returns[, base]
  info <- list(base = base)
  if (method == "regime") info <- c(info, .prepare_regime_info(br, p$vol_window, p$n_regimes))
  if (method == "evt") {
    info$left <- .fit_tail(br, p$tail_prob, "left")
    info$right <- if (isTRUE(p$both_tails)) .fit_tail(br, p$tail_prob, "right") else NULL
    bulk <- br >= info$left$thresh
    if (!is.null(info$right)) bulk <- bulk & br <= info$right$thresh
    info$bulk <- which(bulk); if (!length(info$bulk)) info$bulk <- seq_along(br)
  }
  if (method == "tails") {
    lt <- stats::quantile(br, p$tail_prob); rt <- stats::quantile(br, 1 - p$tail_prob)
    info$left <- which(br < lt); info$right <- which(br > rt)
    info$bulk <- which(br >= lt & br <= rt); if (!length(info$bulk)) info$bulk <- seq_along(br)
    info$p <- p$tail_prob
  }
  if (method %in% c("garch", "gjr_garch")) {
    f <- .fit_garch11(br - 1, gjr = method == "gjr_garch")
    message(sprintf("%s(1,1) [%s]: mu=%.2e, omega=%.2e, alpha=%.4f, beta=%.4f, gamma=%.4f, Persistenz=%.4f",
                    toupper(method), f$method, f$mu, f$omega, f$alpha, f$beta, f$gamma, f$persistence))
    if (f$persistence >= 0.999) warning(sprintf("GARCH: Persistenz %.4f (nahe IGARCH)", f$persistence))
    info$garch <- f
    info$cross <- .fit_cross(returns, config, base)
  }
  if (method == "ms_garch") info$ms <- .prepare_ms_info(returns, config, base, p$ms_n_regimes, p$ms_garch_model, FALSE, FALSE)
  if (method == "ms_ar_garch_m") info$ms <- .prepare_ms_info(returns, config, base, p$ms_ar_n_regimes, p$ms_ar_garch_model, TRUE, FALSE)
  if (method == "tvtp_ms_garch") info$ms <- .prepare_ms_info(returns, config, base, p$tvtp_n_regimes, p$tvtp_garch_model, TRUE, TRUE)
  info
}


# ─────────────────────────────────────────────────────────────────────────────
# Pfaderzeugung
# ─────────────────────────────────────────────────────────────────────────────

#' Eine Renditematrix samt Quellzeilen erzeugen
#' @keywords internal
.generate_returns <- function(returns, method, p, info, n_out) {
  n <- nrow(returns); k <- ncol(returns)
  from_idx <- function(idx) list(ret = returns[idx, , drop = FALSE], idx = idx)
  g <- switch(method,
    raw        = from_idx(.boot_idx_iid(n, n_out)),
    block      = from_idx(.boot_idx_block(n, n_out, as.integer(p$block_length), FALSE)),
    circular   = from_idx(.boot_idx_block(n, n_out, as.integer(p$block_length), TRUE)),
    stationary = from_idx(.boot_idx_stationary(n, n_out, as.numeric(p$L))),
    regime     = from_idx(.boot_idx_regime(info$regimes, info$trans, n_out)),
    tails      = from_idx(.boot_idx_tails(n_out, info$p, info$p, info$bulk, info$left, info$right)),
    wild       = list(ret = .boot_wild(returns, as.integer(p$wild_type)), idx = seq_len(n)),
    reset      = list(ret = .boot_reset(returns, p$p_break), idx = seq_len(n)),
    evt = {
      l <- info$left; r <- info$right
      .boot_evt(returns, info$base - 1L, n_out, l$prob, l$thresh, l$scale, l$shape, as.integer(l$pool),
                if (is.null(r)) 0 else r$prob, if (is.null(r)) Inf else r$thresh,
                if (is.null(r)) 0 else r$scale, if (is.null(r)) 0 else r$shape,
                if (is.null(r)) integer(0) else as.integer(r$pool), as.integer(info$bulk))
    },
    garch = , gjr_garch = {
      f <- info$garch; cr <- info$cross
      .boot_garch(n_out, info$base - 1L, k, f$mu, f$omega, f$alpha, f$beta, f$gamma, f$s2_init,
                  f$z, seq_len(n), cr$cols, cr$mu, cr$om, cr$al, cr$be, cr$ratio, cr$s2, cr$z)
    },
    ms_garch = , ms_ar_garch_m = , tvtp_ms_garch = {
      m <- info$ms; cr <- m$cross
      .boot_ms_garch(n_out, info$base - 1L, k, as.integer(m$K), m$mu, m$omega, m$alpha, m$beta, m$gamma,
                     m$phi, m$lambda, m$trans, m$delta, m$unc, m$stat, m$pools, m$z,
                     cr$cols, cr$mu, cr$om, cr$al, cr$be, cr$ratio, cr$s2, cr$z)
    },
    stop(sprintf("Unbekannte Methode: %s", method)))
  colnames(g$ret) <- colnames(returns)
  g
}

#' Hebelprodukt-Renditen (MSCI-Formel plus Fondskosten)
#' @keywords internal
.letf_returns <- function(rb, letf, aux_rows) {
  L <- letf$leverage
  rate <- if (is.character(letf$finance)) aux_rows[, letf$finance] else letf$finance
  d <- if (is.character(letf$days)) aux_rows[, letf$days] else letf$days
  m <- max(L - 1, 0) + max(-L, 0)
  1 + L * (rb - 1) + (1 - L) * rate / 100 * d / letf$rate_basis -
    letf$expense / 100 * d / letf$ter_basis - letf$spread / 100 * m * d / letf$rate_basis
}

#' Preis-Pfad aus Renditen bauen (Index-Knockout = ungueltig, LETF-Knockout = Totalverlust)
#' @keywords internal
.build_path <- function(g, aux, config, start = 100) {
  ret <- g$ret; idx <- g$idx
  if (!is.matrix(ret) || any(!is.finite(ret)) || any(ret <= 0)) return(NULL)
  n_out <- nrow(ret)
  cp <- function(r) start * cumprod(c(1, r))
  P <- apply(ret, 2, cp)
  if (!is.matrix(P)) P <- matrix(P, ncol = ncol(ret))
  colnames(P) <- config$index_names
  aux_rows <- if (!is.null(aux)) aux[idx, , drop = FALSE] else NULL
  if (config$n_letfs) {
    L <- vapply(config$letfs, function(l) {
      r <- .letf_returns(ret[, l$base], l, aux_rows)
      if (any(!is.finite(r))) return(rep(NA_real_, n_out + 1))
      ko <- which(r <= 0)
      if (length(ko)) r[ko[1]:n_out] <- 0
      cp(pmax(r, 0))
    }, numeric(n_out + 1))
    if (!is.matrix(L)) L <- matrix(L, ncol = config$n_letfs)
    if (anyNA(L)) return(NULL)
    colnames(L) <- config$letf_names
    P <- cbind(P, L)
  }
  if (!is.null(aux)) {
    A <- aux[c(idx[1], idx), , drop = FALSE]
    P <- cbind(P, A)
  }
  P
}

#' Zufallsstroeme je Pfad (L'Ecuyer-CMRG), unabhaengig von Kernen/Chunks
#' @keywords internal
.make_streams <- function(seed, n) {
  if (exists(".Random.seed", envir = globalenv(), inherits = FALSE)) {
    old <- get(".Random.seed", envir = globalenv())
    on.exit(assign(".Random.seed", old, envir = globalenv()), add = TRUE)
  } else {
    old_kind <- RNGkind()
    on.exit({ RNGkind(old_kind[1], old_kind[2], old_kind[3])
              if (exists(".Random.seed", envir = globalenv(), inherits = FALSE)) rm(".Random.seed", envir = globalenv()) }, add = TRUE)
  }
  RNGkind("L'Ecuyer-CMRG")
  set.seed(seed)
  s <- get(".Random.seed", envir = globalenv())
  out <- vector("list", n)
  for (i in seq_len(n)) { out[[i]] <- s; s <- parallel::nextRNGStream(s) }
  out
}

#' Zufallszustand sichern und wiederherstellen
#' @keywords internal
.with_rng_restore <- function(expr) {
  has <- exists(".Random.seed", envir = globalenv(), inherits = FALSE)
  old <- if (has) get(".Random.seed", envir = globalenv()) else NULL
  kind <- RNGkind()
  on.exit({
    if (has) assign(".Random.seed", old, envir = globalenv())
    else { RNGkind(kind[1], kind[2], kind[3]); if (exists(".Random.seed", envir = globalenv(), inherits = FALSE)) rm(".Random.seed", envir = globalenv()) }
  })
  force(expr)
}

#' ESS-Design: Simulationsbudget auf Hyperparameter-Kombinationen verteilen
#' @keywords internal
.ess_design <- function(method, params, grid, budget, n_obs) {
  if (is.null(grid)) grid <- .get_ess_grid(method, n_obs)
  if (is.null(grid) || !length(grid)) return(NULL)
  ess_params <- c("L", "block_length", "n_regimes", "tail_prob", "ms_n_regimes", "ms_ar_n_regimes", "tvtp_n_regimes")
  non_ess <- c("vol_window", "wild_type", "both_tails", "p_break", "garch_order", "ms_garch_model")
  nm <- names(grid)
  design <- expand.grid(grid, stringsAsFactors = FALSE, KEEP.OUT.ATTRS = FALSE)
  design$ess_per_boot <- apply(design[, nm, drop = FALSE], 1, function(row)
    .calculate_ess(n_obs, method, as.list(row)))
  if (any(nm %in% non_ess)) {
    ec <- nm[nm %in% ess_params]
    design$ess_group <- if (length(ec)) apply(design[, ec, drop = FALSE], 1, paste, collapse = "_") else "all"
    design$n_variants <- as.numeric(table(design$ess_group)[design$ess_group])
    design$weight_alloc <- (1 / design$ess_per_boot) / design$n_variants
  } else {
    design$n_variants <- 1; design$weight_alloc <- 1 / design$ess_per_boot
  }
  design$n_sims <- pmax(1, round(budget * design$weight_alloc / sum(design$weight_alloc)))
  while (sum(design$n_sims) > budget) { i <- which.max(design$n_sims); design$n_sims[i] <- design$n_sims[i] - 1 }
  design$total_ESS <- design$ess_per_boot * design$n_sims
  target <- stats::median(design$total_ESS[design$total_ESS > 0])
  design$weight <- ifelse(design$total_ESS > 0, target / design$total_ESS, 0)
  attr(design, "param_names") <- nm
  design
}

#' Gemeinsame Vorbereitung fuer bootstrap() und bootstrap_study()
#' @keywords internal
.boot_setup <- function(data, config, method, n, params, ess, ess_grid, path_length) {
  if (!inherits(config, "bootstrap_config")) stop("config muss mit bootstrap_config() erstellt werden")
  if (!method %in% .boot_methods) stop("Unbekannte Methode '", method, "'. Verfuegbar: ", paste(.boot_methods, collapse = ", "))
  if (!is.numeric(n) || length(n) != 1 || n < 1) stop("n muss eine positive Zahl sein")
  ex <- .extract_returns(data, config)
  n_obs <- nrow(ex$ret)
  n_out <- as.integer(path_length %||% n_obs)
  if (method %in% c("wild", "reset") && n_out != n_obs)
    stop(sprintf("Verfahren '%s' erhaelt die Chronologie; path_length muss %d sein.", method, n_obs))
  params <- .resolve_auto(params, ex$ret, config, method)
  design <- if (ess) .ess_design(method, params, ess_grid, as.integer(n), n_obs) else NULL
  if (ess && is.null(design)) message("Keine Hyperparameter fuer ESS - nutze Standard-Bootstrap")
  combos <- if (is.null(design)) list(params) else lapply(seq_len(nrow(design)), function(i) {
    gp <- as.list(design[i, attr(design, "param_names"), drop = FALSE])
    utils::modifyList(params, gp)
  })
  combo_of_path <- if (is.null(design)) rep(1L, n) else rep(seq_len(nrow(design)), design$n_sims)
  n_paths <- length(combo_of_path)
  infos <- lapply(combos, function(cp) tryCatch(.prepare_method_info(ex$ret, config, method, cp),
                                               error = function(e) stop(sprintf("Vorberechnung fehlgeschlagen: %s", e$message))))
  base_p <- lapply(combos, function(cp) .get_base_params(method, cp, n_obs))
  weights <- if (is.null(design)) rep(1, n_paths) else design$weight[combo_of_path]
  weights <- weights / sum(weights) * length(weights)
  list(ex = ex, n_obs = n_obs, n_out = n_out, design = design, combos = combos, base_p = base_p,
       infos = infos, combo_of_path = combo_of_path, n_paths = n_paths, weights = weights)
}

#' Einen gueltigen Pfad mit eigenem Zufallsstrom erzeugen (mit Wiederholungen)
#' @keywords internal
.draw_path <- function(setup, i, stream, config, method, max_tries) {
  assign(".Random.seed", stream, envir = globalenv())
  c_id <- setup$combo_of_path[i]
  for (try in seq_len(max_tries)) {
    g <- tryCatch(.generate_returns(setup$ex$ret, method, setup$base_p[[c_id]], setup$infos[[c_id]], setup$n_out),
                  error = function(e) NULL)
    if (!is.null(g)) {
      P <- .build_path(g, setup$ex$aux, config)
      if (!is.null(P)) return(list(path = P, tries = try))
    }
  }
  list(path = NULL, tries = max_tries)
}

#' Parallele Ausfuehrung (fork auf Unix, PSOCK auf Windows)
#' @keywords internal
.par_lapply <- function(X, FUN, cores) {
  if (cores <= 1 || length(X) <= 1) return(lapply(X, FUN))
  if (.Platform$OS.type == "unix") {
    return(parallel::mclapply(X, FUN, mc.cores = cores, mc.preschedule = FALSE, mc.set.seed = FALSE))
  }
  cl <- parallel::makePSOCKcluster(cores)
  on.exit(parallel::stopCluster(cl))
  parallel::clusterEvalQ(cl, suppressPackageStartupMessages(library(SimLev)))
  parallel::parLapplyLB(cl, X, FUN)
}


# ─────────────────────────────────────────────────────────────────────────────
# Oeffentliche Funktionen
# ─────────────────────────────────────────────────────────────────────────────

#' Bootstrap-Pfade erzeugen
#'
#' Erzeugt \code{n} simulierte Preis-Pfade fuer alle Indizes der Konfiguration,
#' leitet daraus die Hebelprodukte ab und zieht Zusatzreihen mit.
#'
#' @param data data.frame oder Matrix mit den Spalten aus \code{config}.
#' @param config Objekt aus [bootstrap_config()].
#' @param method Verfahren:
#'   \describe{
#'     \item{"raw"}{IID-Zeilen-Bootstrap (Efron 1979); zerstoert Zeitabhaengigkeit (Nullmodell)}
#'     \item{"block"}{Moving Block Bootstrap (Kuensch 1989), Parameter \code{block_length}}
#'     \item{"circular"}{Circular Block Bootstrap (Politis & Romano 1992), \code{block_length}}
#'     \item{"stationary"}{Stationaerer Bootstrap (Politis & Romano 1994), erwartete Blocklaenge \code{L}}
#'     \item{"wild"}{Wild Bootstrap, \code{wild_type} 0 = Rademacher, 1 = Mammen, 2 = normal}
#'     \item{"regime"}{Volatilitaetsregime-Markov-Bootstrap, \code{n_regimes}, \code{vol_window}}
#'     \item{"evt"}{GPD-Tails plus empirischer Bulk, \code{tail_prob}, \code{both_tails}}
#'     \item{"tails"}{Empirische Tail-Schichtung, \code{tail_prob}}
#'     \item{"reset"}{Chronologie mit zufaellig gespiegelten Segmenten, \code{p_break}}
#'     \item{"garch", "gjr_garch"}{(GJR-)GARCH(1,1) mit Filtered Historical Simulation}
#'     \item{"ms_garch", "ms_ar_garch_m", "tvtp_ms_garch"}{Markov-Switching-GARCH-Familie (Paket MSGARCH)}
#'   }
#'   \code{L} bzw. \code{block_length} duerfen \code{"auto"} sein ([block_length()]).
#' @param n Anzahl Pfade (bei ESS: Gesamtbudget).
#' @param params Liste von Verfahrensparametern.
#' @param ess,ess_grid ESS-gewichtete Gittersuche ueber Hyperparameter (wie
#'   im Original): Das Budget wird invers zur effektiven Stichprobengroesse
#'   verteilt, die Pfade erhalten Gewichte (Mittel 1).
#' @param progress Fortschritt melden.
#' @param path_length Pfadlaenge in Zeilen (Standard: Laenge der Historie). Damit
#'   lassen sich z. B. 50-jaehrige Pfade aus 30 Jahren Historie erzeugen.
#' @param seed Startwert; jeder Pfad erhaelt einen eigenen L'Ecuyer-Strom, so
#'   dass Pfad i unabhaengig von \code{cores} und identisch zu
#'   [bootstrap_study()] mit gleichem Seed ist. Der globale Zufallszustand
#'   bleibt unveraendert.
#' @param cores Anzahl Prozesse.
#' @param max_tries Wiederholungen je Pfad bei ungueltigem Pfad (Index <= 0).
#'
#' @return Objekt der Klasse \code{bootstrap_result} mit \code{paths} (Liste
#'   von Matrizen: Zeile 1 = Startwert 100, danach je Simulationstag; Spalten
#'   Indizes, Hebelprodukte, Zusatzreihen), \code{weights}, \code{param_values},
#'   \code{ess_design}, \code{stats}.
#' @examples
#' set.seed(2)
#' d <- data.frame(us = 1 + rnorm(1500, 3e-4, 0.01))
#' d$eu <- d$us * (1 + rnorm(1500, 0, 0.004))
#' d$rate <- 2
#' cfg <- bootstrap_config(c(us = "us", eu = "eu"), aux = c(rate = "rate"),
#'   letfs = list(list(base = "eu", leverage = 2, finance = "rate")))
#' b <- bootstrap(d, cfg, "stationary", n = 5, params = list(L = 50), seed = 1)
#' dim(b$paths[[1]])
#' @seealso [bootstrap_study()], [bootstrap_config()], [block_length()]
#' @export
bootstrap <- function(data, config, method = "raw", n = 1000, params = list(), ess = FALSE,
                      ess_grid = NULL, progress = TRUE, path_length = NULL, seed = NULL,
                      cores = 1L, max_tries = 10L) {
  t0 <- Sys.time()
  setup <- .boot_setup(data, config, method, n, params, ess, ess_grid, path_length)
  if (is.null(seed)) seed <- sample.int(.Machine$integer.max, 1L)
  streams <- .with_rng_restore(.make_streams(seed, setup$n_paths))
  res <- .with_rng_restore(.par_lapply(seq_len(setup$n_paths), function(i)
    .draw_path(setup, i, streams[[i]], config, method, max_tries), cores))
  ok <- !vapply(res, function(r) is.null(r$path), TRUE)
  tries <- vapply(res, `[[`, 0, "tries")
  if (!any(ok)) stop("Keine gueltigen Pfade erzeugt.")
  w <- setup$weights[ok]; w <- w / sum(w) * length(w)
  if (progress) message(sprintf("Bootstrap '%s': %d Pfade x %d Tage in %.1f s (Knockout-Rate %.2f %%).",
                                method, sum(ok), setup$n_out, as.numeric(difftime(Sys.time(), t0, units = "secs")),
                                100 * sum(tries - 1) / sum(tries)))
  structure(list(
    paths = lapply(res[ok], `[[`, "path"), weights = w, method = method, config = config,
    params = setup$base_p[[1]], ess = !is.null(setup$design), ess_design = setup$design,
    param_values = if (!is.null(setup$design)) setup$combos[setup$combo_of_path[ok]] else NULL,
    seed = seed, knockout_rate = 100 * sum(tries - 1) / sum(tries),
    stats = list(attempts = sum(tries), success = sum(ok), null = sum(tries) - sum(ok),
                 knockout_rate = (sum(tries) - sum(ok)) / sum(tries))
  ), class = "bootstrap_result")
}

#' @rdname SimLevBootstrap-methods
#' @export
print.bootstrap_result <- function(x, ...) {
  cat(sprintf("SimLev Bootstrap '%s': %d Pfade, je %d Zeilen x %d Spalten (%s)%s\n",
              x$method, length(x$paths), nrow(x$paths[[1]]), ncol(x$paths[[1]]),
              paste(colnames(x$paths[[1]]), collapse = ", "),
              if (isTRUE(x$ess)) sprintf(", ESS-gewichtet (%d Kombinationen)", nrow(x$ess_design)) else ""))
  invisible(x)
}

#' Bootstrap-Ergebnis validieren und bereinigen
#'
#' Entfernt leere, unvollstaendige oder unplausible Pfade und normiert die
#' Gewichte neu (wie im Original).
#' @param result \code{bootstrap_result}.
#' @param min_rows Mindestzeilenzahl.
#' @param verbose Meldungen ausgeben.
#' @return Bereinigtes \code{bootstrap_result}.
#' @export
validate_bootstrap <- function(result, min_rows = NULL, verbose = TRUE) {
  if (!inherits(result, "bootstrap_result")) stop("result muss ein bootstrap_result-Objekt sein")
  if (!length(result$paths)) stop("Keine Pfade im Ergebnis vorhanden")
  P <- result$paths
  ok <- vapply(P, function(p) !is.null(p) && (is.matrix(p) || is.data.frame(p)) && nrow(p) > 0 &&
                 !anyNA(p) && all(is.finite(as.matrix(p))), TRUE)
  if (any(ok)) {
    len <- vapply(P, function(p) if (is.null(p)) NA_integer_ else nrow(p), 0L)
    mode_len <- as.numeric(names(sort(table(len[ok]), decreasing = TRUE))[1])
    ok <- ok & len == mode_len
    if (!is.null(min_rows)) ok <- ok & len >= min_rows
  }
  if (!any(ok)) stop("Keine gueltigen Pfade nach Validierung uebrig")
  if (verbose && any(!ok)) cat(sprintf("%d von %d Pfaden entfernt\n", sum(!ok), length(ok)))
  result$paths <- P[ok]
  if (!is.null(result$weights)) { w <- result$weights[ok]; result$weights <- w / sum(w) * length(w) }
  if (!is.null(result$param_values)) result$param_values <- result$param_values[ok]
  if (verbose) cat(sprintf("%d valide Pfade, je %d Zeilen\n", length(result$paths), nrow(result$paths[[1]])))
  result
}

#' Bootstrap-Pfad als data.frame fuer simulation()
#'
#' @param result \code{bootstrap_result} oder eine einzelne Pfadmatrix.
#' @param i Pfadnummer.
#' @param dates Datumsvektor passender Laenge; sonst Kalendertage ab \code{start_date}.
#' @param start_date Startdatum (Standard 2000-01-01).
#' @return data.frame mit \code{date} und allen Pfadspalten.
#' @export
bootstrap_data <- function(result, i = 1L, dates = NULL, start_date = "2000-01-01") {
  P <- if (inherits(result, "bootstrap_result")) result$paths[[i]] else result
  if (is.null(dates)) dates <- seq.Date(as.Date(start_date), by = "day", length.out = nrow(P))
  if (length(dates) != nrow(P)) stop(sprintf("dates hat Laenge %d, Pfad hat %d Zeilen.", length(dates), nrow(P)))
  data.frame(date = as.Date(dates), as.data.frame(P), check.names = FALSE)
}

#' Standard-Kennzahlen fuer bootstrap_study()
#'
#' @param res \code{SimLevResult}.
#' @return Benannter numerischer Vektor.
#' @export
study_metrics <- function(res) {
  s <- res$statistics
  dq <- stats::quantile(res$drawdowns, c(0.5, 0.9), names = FALSE)
  c(cagr = res$cagr, ttwror = res$ttwror, final_value = utils::tail(res$worth, 1),
    max_drawdown = s$max_drawdown, avg_drawdown = s$average_drawdown, dd_q50 = dq[1], dd_q90 = dq[2],
    ulcer_index = s$ulcer_index, longest_drawdown = s$longest_drawdown,
    sharpe = s$sharpe, sortino = s$sortino, calmar = s$calmar, omega = s$omega,
    mean = s$mean, sd = s$sd, skewness = s$skewness, kurtosis = s$kurtosis, lpm = s$lpm, hpm = s$hpm,
    taxes = res$tax_report$total_taxes_paid %||% 0,
    trades = sum(res$buys) + sum(res$sells))
}

#' Strategien auf Bootstrap-Pfaden auswerten
#'
#' Erzeugt Bootstrap-Pfade, berechnet je Pfad die Signale, simuliert alle
#' Strategien mit [simulation()] auf DEMSELBEN Pfad (Common Random Numbers,
#' gepaarter Vergleich) und speichert nur Kennzahlen. Pfade werden nach der
#' Auswertung verworfen; der Speicherbedarf ist daher unabhaengig von \code{n}.
#' Entspricht der Pipeline aus '06 Bootstraps' (Chunks, Parallelisierung),
#' ohne die Pfade zwischenzuspeichern.
#'
#' @inheritParams bootstrap
#' @param strategies Benannte Liste. Jedes Element ist entweder direkt eine
#'   Strategie (\code{create_strategy()} bzw. Liste von Assets) oder eine Liste
#'   mit \code{strategy}, optional \code{signal} (Funktion data.frame ->
#'   data.frame oder Liste von Spalten, z. B. \code{list(buy = ..., sell = ...)}),
#'   \code{args} (Argumente fuer \code{simulation()}, ueberschreiben
#'   \code{sim_args}) und \code{map} (Spalten-Aliase, z. B.
#'   \code{c(letf = "eu_l2")}).
#' @param sim_args Gemeinsame Argumente fuer [simulation()].
#' @param dates,start_date Kalender der Pfade (siehe [bootstrap_data()]).
#' @param burn_in Anzahl Anfangszeilen, die nach der Signalberechnung verworfen
#'   werden (Signal-Vorlauf, z. B. 730 Tage fuer eine 430-Tage-SMA).
#' @param metrics Funktion \code{SimLevResult -> benannter numerischer Vektor}
#'   (Standard [study_metrics()]).
#' @param benchmark Name der Vergleichsstrategie fuer gepaarte Auswertungen.
#' @param chunk_size Pfade je Arbeitspaket.
#' @param chunk_dir Optional Verzeichnis fuer Zwischenergebnisse je Chunk; ein
#'   abgebrochener Lauf wird mit gleichem Seed fortgesetzt.
#' @param keep_paths Erste k Pfade zusaetzlich zurueckgeben (Diagnose).
#' @param keep_returns \code{"none"} (Standard) oder \code{"year"},
#'   \code{"quarter"}, \code{"month"}: speichert je Strategie und Pfad die
#'   zeitgewichteten Periodenrenditen (aus [result_index()]). Die Studie kann
#'   dann direkt an [withdrawal_simulation()] bzw. [withdrawal_paths()]
#'   uebergeben werden (Entnahmephase auf den simulierten Strategiepfaden).
#' @param keep_aux Namen von Zusatzreihen (z. B. ein CPI-Niveau), deren
#'   Periodenverhaeltnisse ebenfalls gespeichert werden (Inflation fuer die
#'   Entnahmephase).
#'
#' @return Objekt der Klasse \code{SimLevBootstrapStudy}: \code{results}
#'   (data.frame mit path, weight, strategy und Kennzahlen), Metadaten und ggf.
#'   ESS-Design. Auswertung mit \code{summary()} und [bootstrap_probability()].
#' @examples
#' \dontrun{
#' cfg <- bootstrap_config(c(us = "us_ret", eu = "eu_ret"), regime_index = "us",
#'   letfs = list(list(base = "eu", leverage = 2, finance = "rate", expense = 0.5)),
#'   aux = c(rate = "eu_rate"))
#' sma_signal <- function(df, n = 310) {
#'   s <- stats::filter(df$eu, rep(1 / n, n), sides = 1)
#'   list(buy = df$eu >= s, sell = df$eu < s)
#' }
#' st <- bootstrap_study(hist, cfg, "stationary", n = 1000, params = list(L = 250),
#'   strategies = list(
#'     bnh = create_strategy(eu_l2 = asset_config("etf", "bnh", asset_bonus = 30)),
#'     sma = list(strategy = create_strategy(eu_l2 = asset_config("etf", "signal",
#'                  asset_bonus = 30, signal_buy = "buy", signal_sell = "sell")),
#'                signal = sma_signal)),
#'   sim_args = list(start_value = 1000, tax_mode = "person"),
#'   burn_in = 730, benchmark = "bnh", cores = 8, seed = 42)
#' summary(st)
#' bootstrap_probability(st, ttwror >= 0.10 & max_drawdown <= 0.6)
#' }
#' @seealso [bootstrap()], [bootstrap_probability()], [simulation()]
#' @export
bootstrap_study <- function(data, config, method = "stationary", n = 1000, strategies,
                            params = list(), ess = FALSE, ess_grid = NULL, path_length = NULL,
                            dates = NULL, start_date = "2000-01-01", burn_in = 0L,
                            sim_args = list(), metrics = study_metrics, benchmark = NULL,
                            cores = 1L, chunk_size = 25L, seed = NULL, chunk_dir = NULL,
                            max_tries = 10L, keep_paths = 0L,
                            keep_returns = c("none", "year", "quarter", "month"), keep_aux = NULL,
                            progress = TRUE) {
  keep_returns <- match.arg(keep_returns)
  if (!is.null(keep_aux) && !all(keep_aux %in% config$aux_names))
    stop("keep_aux muss Namen aus config$aux enthalten.")
  t0 <- Sys.time()
  if (missing(strategies) || !length(strategies) || is.null(names(strategies)) || any(names(strategies) == ""))
    stop("'strategies' muss eine benannte, nicht-leere Liste sein.")
  specs <- lapply(strategies, function(s) {
    if (is.list(s) && !is.null(s$strategy) && !inherits(s, "strategy")) s else list(strategy = s)
  })
  if (!is.null(benchmark) && !benchmark %in% names(specs)) stop("benchmark muss einer der Strategienamen sein.")
  setup <- .boot_setup(data, config, method, n, params, ess, ess_grid, path_length)
  if (is.null(dates)) dates <- seq.Date(as.Date(start_date), by = "day", length.out = setup$n_out + 1L)
  if (length(dates) != setup$n_out + 1L) stop(sprintf("dates braucht Laenge %d (Pfadlaenge + 1).", setup$n_out + 1L))
  if (burn_in >= setup$n_out) stop("burn_in ist laenger als der Pfad.")
  if (is.null(seed)) seed <- sample.int(.Machine$integer.max, 1L)
  streams <- .with_rng_restore(.make_streams(seed, setup$n_paths))
  chunks <- split(seq_len(setup$n_paths), ceiling(seq_len(setup$n_paths) / chunk_size))
  if (!is.null(chunk_dir)) dir.create(chunk_dir, showWarnings = FALSE, recursive = TRUE)
  sim_rows <- (burn_in + 1L):(setup$n_out + 1L)
  ret_ends <- if (keep_returns != "none") .anniv_ends(as.Date(dates)[sim_rows], keep_returns) else NULL
  if (!is.null(ret_ends) && length(ret_ends) < 2) stop("Pfad nach burn_in zu kurz fuer eine volle Periode in keep_returns.")
  per_ret <- function(v) { v <- v[ret_ends]; v[-1] / v[-length(v)] }

  eval_path <- function(i) {
    dp <- .draw_path(setup, i, streams[[i]], config, method, max_tries)
    if (is.null(dp$path)) return(NULL)
    df0 <- data.frame(date = as.Date(dates), as.data.frame(dp$path), check.names = FALSE)
    rows <- lapply(names(specs), function(nm) {
      sp <- specs[[nm]]; df <- df0
      if (!is.null(sp$signal)) {
        sg <- tryCatch(sp$signal(df), error = function(e) NULL)
        if (is.null(sg)) return(NULL)
        if (is.data.frame(sg)) df <- sg else for (k in names(sg)) {
          v <- sg[[k]]; if (is.logical(v)) v[is.na(v)] <- FALSE; df[[k]] <- v }
      }
      if (!is.null(sp$map)) for (a in names(sp$map)) df[[a]] <- df[[sp$map[[a]]]]
      if (burn_in > 0) df <- df[(burn_in + 1L):nrow(df), , drop = FALSE]
      args <- utils::modifyList(sim_args, sp$args %||% list())
      res <- tryCatch(suppressWarnings(suppressMessages(
        do.call(simulation, c(list(data = df, strategy = sp$strategy), args)))), error = function(e) e)
      if (inherits(res, "error")) return(NULL)
      m <- tryCatch(metrics(res), error = function(e) NULL)
      if (is.null(m)) return(NULL)
      list(row = c(path = i, weight = setup$weights[i], combo = setup$combo_of_path[i], tries = dp$tries, m),
           ret = if (!is.null(ret_ends)) per_ret(result_index(res)$value) else NULL)
    })
    names(rows) <- names(specs)
    aux_ret <- if (!is.null(ret_ends) && length(keep_aux))
      lapply(stats::setNames(keep_aux, keep_aux), function(a) per_ret(df0[[a]][sim_rows])) else NULL
    list(id = i, rows = rows, aux = aux_ret, path = if (i <= keep_paths) dp$path else NULL)
  }
  run_chunk <- function(ci) {
    f <- if (!is.null(chunk_dir)) file.path(chunk_dir, sprintf("chunk_%05d_seed%d%s.rds", ci, seed,
                                                           if (keep_returns != "none") paste0("_", keep_returns) else "")) else NULL
    if (!is.null(f) && file.exists(f)) return(readRDS(f))
    out <- lapply(chunks[[ci]], eval_path)
    if (!is.null(f)) saveRDS(out, f)
    if (progress && cores <= 1) message(sprintf("  Chunk %d/%d fertig (%.0f s)", ci, length(chunks),
                                                as.numeric(difftime(Sys.time(), t0, units = "secs"))))
    out
  }
  if (progress) message(sprintf("Bootstrap-Studie '%s': %d Pfade x %d Strategien, %d Chunks, %d Kern(e)",
                                method, setup$n_paths, length(specs), length(chunks), cores))
  res <- .with_rng_restore(.par_lapply(seq_along(chunks), run_chunk, cores))
  failed_chunks <- vapply(res, function(r) inherits(r, "try-error") || !is.list(r), TRUE)
  if (any(failed_chunks)) warning(sprintf("%d Chunks mit Fehler: %s", sum(failed_chunks),
                                          paste(unique(unlist(res[failed_chunks])), collapse = "; ")))
  res <- unlist(res[!failed_chunks], recursive = FALSE)
  tab <- do.call(rbind, lapply(names(specs), function(nm) {
    m <- do.call(rbind, lapply(res, function(r) r$rows[[nm]]$row))
    if (is.null(m)) return(NULL)
    data.frame(strategy = nm, m, check.names = FALSE, stringsAsFactors = FALSE)
  }))
  if (is.null(tab)) stop("Keine Strategie-Ergebnisse - Strategie, Signale und sim_args pruefen.")
  rownames(tab) <- NULL
  n_fail <- setup$n_paths * length(specs) - nrow(tab)
  if (n_fail > 0) warning(sprintf("%d Pfad-Strategie-Kombinationen ohne Ergebnis (Simulation/Signal fehlgeschlagen).", n_fail))
  returns <- aux_returns <- NULL
  if (!is.null(ret_ends)) {
    n_per <- length(ret_ends) - 1L
    ids <- vapply(res, function(r) if (is.null(r)) NA_integer_ else as.integer(r$id), 0L)
    fill_mat <- function(get) {
      M <- matrix(NA_real_, n_per, setup$n_paths)
      for (j in seq_along(res)) if (!is.na(ids[j])) { v <- get(res[[j]]); if (!is.null(v)) M[, ids[j]] <- v }
      M
    }
    returns <- lapply(stats::setNames(names(specs), names(specs)), function(nm) fill_mat(function(r) r$rows[[nm]]$ret))
    if (length(keep_aux)) aux_returns <- lapply(stats::setNames(keep_aux, keep_aux), function(a) fill_mat(function(r) r$aux[[a]]))
  }
  elapsed <- as.numeric(difftime(Sys.time(), t0, units = "secs"))
  if (progress) message(sprintf("Fertig: %d Ergebniszeilen in %.1f s.", nrow(tab), elapsed))
  structure(list(
    results = tab, method = method, n_paths = setup$n_paths, strategies = names(specs),
    benchmark = benchmark, config = config, params = setup$base_p[[1]], ess_design = setup$design,
    seed = seed, burn_in = burn_in, path_length = setup$n_out, elapsed = elapsed,
    paths = Filter(Negate(is.null), lapply(res, `[[`, "path")),
    returns = returns, aux_returns = aux_returns, returns_frequency = if (keep_returns != "none") keep_returns else NULL,
    returns_dates = if (!is.null(ret_ends)) as.Date(dates)[sim_rows][ret_ends] else NULL,
    path_weights = setup$weights
  ), class = "SimLevBootstrapStudy")
}

#' Gewichtete Quantile
#' @keywords internal
.wquantile <- function(x, w, probs) {
  ok <- is.finite(x) & is.finite(w); x <- x[ok]; w <- w[ok]
  if (!length(x)) return(rep(NA_real_, length(probs)))
  if (length(unique(w)) == 1L) return(stats::quantile(x, probs, names = FALSE, type = 7))
  o <- order(x); x <- x[o]; cw <- cumsum(w[o]) / sum(w)
  vapply(probs, function(p) x[which(cw >= p)[1]], 0)
}

#' Wahrscheinlichkeiten aus einer Bootstrap-Studie
#'
#' Wertet beliebige logische Bedingungen je Strategie aus (ESS-gewichtet), z. B.
#' die gemeinsame Wahrscheinlichkeit, eine Mindestrendite zu erreichen und
#' einen maximalen Drawdown nicht zu ueberschreiten (wie \code{calc_metrics} in
#' '06 Bootstraps').
#'
#' @param study \code{SimLevBootstrapStudy}.
#' @param ... Benannte oder unbenannte Bedingungen in Kennzahlnamen, z. B.
#'   \code{ttwror >= 0.13}, \code{joint = ttwror >= 0.13 & max_drawdown <= 0.95}.
#' @param thresholds Optional Liste je Strategie mit Bedingungen als
#'   Ausdrucksliste (fuer strategiespezifische Schwellen).
#' @return data.frame: Strategie x Bedingung, mit Monte-Carlo-Standardfehler.
#' @export
bootstrap_probability <- function(study, ..., thresholds = NULL) {
  if (!inherits(study, "SimLevBootstrapStudy")) stop("study muss ein SimLevBootstrapStudy-Objekt sein.")
  conds <- as.list(substitute(list(...)))[-1]
  if (is.null(names(conds))) names(conds) <- vapply(conds, function(e) paste(deparse(e), collapse = ""), "")
  names(conds)[names(conds) == ""] <- vapply(conds[names(conds) == ""], function(e) paste(deparse(e), collapse = ""), "")
  tab <- study$results
  out <- do.call(rbind, lapply(unique(tab$strategy), function(s) {
    d <- tab[tab$strategy == s, , drop = FALSE]
    cl <- if (!is.null(thresholds[[s]])) thresholds[[s]] else conds
    do.call(rbind, lapply(names(cl), function(cn) {
      v <- as.logical(eval(cl[[cn]], d, parent.frame(3)))
      w <- d$weight; ok <- !is.na(v)
      p <- sum(w[ok] * v[ok]) / sum(w[ok])
      neff <- sum(w[ok])^2 / sum(w[ok]^2)
      data.frame(strategy = s, condition = cn, probability = p, se = sqrt(p * (1 - p) / neff), n = sum(ok))
    }))
  }))
  rownames(out) <- NULL
  out
}

#' Methoden fuer Bootstrap-Objekte
#'
#' Ausgabe-, Zusammenfassungs- und Grafikmethoden.
#'
#' @param x Ein \code{bootstrap_config}-, \code{bootstrap_result}-, \code{SimLevBootstrapStudy}- oder Zusammenfassungsobjekt.
#' @param object Ein \code{SimLevBootstrapStudy}-Objekt.
#' @param metrics Kennzahlen fuer die Zusammenfassung.
#' @param probs Quantile.
#' @param metric Kennzahl fuer die Dichtegrafik.
#' @param ... Weitere Argumente.
#' @return Das Objekt (unsichtbar) bzw. eine Zusammenfassung.
#' @name SimLevBootstrap-methods
#' @keywords internal
NULL

#' @rdname SimLevBootstrap-methods
#' @export
summary.SimLevBootstrapStudy <- function(object, metrics = c("cagr", "ttwror", "max_drawdown", "sharpe", "ulcer_index", "final_value"),
                                         probs = c(0.05, 0.25, 0.5, 0.75, 0.95), ...) {
  tab <- object$results
  metrics <- intersect(metrics, names(tab))
  dist <- do.call(rbind, lapply(object$strategies, function(s) {
    d <- tab[tab$strategy == s, , drop = FALSE]
    do.call(rbind, lapply(metrics, function(m) {
      q <- .wquantile(d[[m]], d$weight, probs)
      data.frame(strategy = s, metric = m, mean = stats::weighted.mean(d[[m]], d$weight, na.rm = TRUE),
                 t(setNames(q, sprintf("q%02d", round(100 * probs)))), check.names = FALSE)
    }))
  }))
  paired <- NULL
  if (!is.null(object$benchmark)) {
    b <- tab[tab$strategy == object$benchmark, , drop = FALSE]
    paired <- do.call(rbind, lapply(setdiff(object$strategies, object$benchmark), function(s) {
      d <- tab[tab$strategy == s, , drop = FALSE]
      mm <- merge(d, b, by = "path", suffixes = c("", ".bench"))
      do.call(rbind, lapply(metrics, function(m) {
        dif <- mm[[m]] - mm[[paste0(m, ".bench")]]
        better <- if (m %in% c("max_drawdown", "ulcer_index", "avg_drawdown", "longest_drawdown")) dif < 0 else dif > 0
        w <- mm$weight; ok <- is.finite(dif)
        p <- sum(w[ok] * better[ok]) / sum(w[ok])
        q <- .wquantile(dif, w, c(0.05, 0.5, 0.95))
        data.frame(strategy = s, metric = m, p_better = p,
                   se = sqrt(p * (1 - p) / (sum(w[ok])^2 / sum(w[ok]^2))),
                   diff_q05 = q[1], diff_median = q[2], diff_q95 = q[3])
      }))
    }))
  }
  out <- list(distribution = dist, paired = paired, n_paths = object$n_paths, method = object$method,
              benchmark = object$benchmark, path_length = object$path_length)
  class(out) <- "summary.SimLevBootstrapStudy"
  out
}

#' @rdname SimLevBootstrap-methods
#' @export
print.summary.SimLevBootstrapStudy <- function(x, ...) {
  fmt <- function(v, m) {
    pct <- m %in% c("cagr", "ttwror", "max_drawdown", "avg_drawdown", "dd_q50", "dd_q90", "p_better")
    if (pct) sprintf("%8.2f%%", 100 * v) else if (m %in% c("final_value", "taxes")) sprintf("%10.0f", v) else sprintf("%9.3f", v)
  }
  cat("\n\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\n")
  cat("                 SimLev Bootstrap-Studie                       \n")
  cat("\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\n")
  cat(sprintf("  Verfahren: %s | Pfade: %d | Pfadlaenge: %d Tage\n", x$method, x$n_paths, x$path_length))
  d <- x$distribution
  qc <- grep("^q[0-9]", names(d), value = TRUE)
  for (m in unique(d$metric)) {
    dm <- d[d$metric == m, , drop = FALSE]
    cat(sprintf("\n  %s\n  %-14s %10s %s\n", m, "Strategie", "Mittel", paste(sprintf("%10s", qc), collapse = "")))
    for (i in seq_len(nrow(dm)))
      cat(sprintf("  %-14s %10s %s\n", dm$strategy[i], fmt(dm$mean[i], m),
                  paste(vapply(qc, function(q) sprintf("%10s", fmt(dm[[q]][i], m)), ""), collapse = "")))
  }
  if (!is.null(x$paired)) {
    cat(sprintf("\n  Gepaarter Vergleich gegen '%s' (gleiche Pfade)\n", x$benchmark))
    cat(sprintf("  %-14s %-14s %10s %8s %11s %11s %11s\n", "Strategie", "Kennzahl", "P(besser)", "SE", "Diff q05", "Diff Median", "Diff q95"))
    p <- x$paired
    for (i in seq_len(nrow(p)))
      cat(sprintf("  %-14s %-14s %9.1f%% %7.1f%% %11s %11s %11s\n", p$strategy[i], p$metric[i], 100 * p$p_better[i], 100 * p$se[i],
                  fmt(p$diff_q05[i], p$metric[i]), fmt(p$diff_median[i], p$metric[i]), fmt(p$diff_q95[i], p$metric[i])))
  }
  cat("\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\n")
  invisible(x)
}

#' @rdname SimLevBootstrap-methods
#' @export
print.SimLevBootstrapStudy <- function(x, ...) {
  cat(sprintf("SimLev Bootstrap-Studie '%s': %d Pfade, Strategien: %s, %d Ergebniszeilen, %.1f s\n",
              x$method, x$n_paths, paste(x$strategies, collapse = ", "), nrow(x$results), x$elapsed))
  print(summary(x))
  invisible(x)
}

#' @rdname SimLevBootstrap-methods
#' @export
plot.SimLevBootstrapStudy <- function(x, metric = "cagr", ...) {
  tab <- x$results
  dl <- lapply(x$strategies, function(s) tab[[metric]][tab$strategy == s])
  rng <- range(unlist(dl), finite = TRUE)
  cols <- grDevices::hcl.colors(length(dl), "Dark 3")
  dens <- lapply(dl, function(v) stats::density(v[is.finite(v)]))
  plot(NULL, xlim = rng, ylim = c(0, max(vapply(dens, function(d) max(d$y), 0))),
       xlab = metric, ylab = "Dichte", main = sprintf("Verteilung %s (%s, %d Pfade)", metric, x$method, x$n_paths), ...)
  for (i in seq_along(dens)) graphics::lines(dens[[i]], col = cols[i], lwd = 1.5)
  graphics::legend("topright", legend = x$strategies, col = cols, lwd = 1.5, bty = "n")
  invisible(x)
}

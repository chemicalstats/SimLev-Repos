# =============================================================================
#  backcast.R  —  Rueckrechnung (Backcast) von Produkt-Kursreihen
# -----------------------------------------------------------------------------
#  Verlaengert die Historie eines ETF/ETP (auch gehebelt oder invers) ueber
#  dessen Auflegung hinaus in die Vergangenheit:
#
#    1. backcast_fit()  passt die Modellparameter auf dem Ueberlappungszeitraum
#                       von Produkt und Basisindex an (Abweichungsminimierung),
#    2. backcast()      rechnet das Produkt vor der Auflegung zurueck und
#                       verkettet (Chain-Linking) mit der echten Kursreihe.
#
#  Strukturmodell (MSCI Daily Leveraged/Short Index, Aug 2021, plus Fondskosten):
#
#    r_t = beta * L * x_t                       Index-Exposure (x_t = I_t/I_{t-1} - 1)
#        + (1 - L) * rate_t * T_t / rate_basis  Finanzierung / Zinsertrag (Act/360)
#        - TER_t * T_t / ter_basis              laufende Kosten (taeglich, Act/365)
#        - spread * m(L) * T_t / rate_basis     Swap-/Finanzierungs-Spread auf m(L)
#        - drag * T_t / 365                     gefittete Restabweichung p. a.
#
#  mit T_t = Kalendertage seit der Vorzeile und m(L) = max(L-1, 0) + max(-L, 0).
#  Fuer L = 1 und rate = 0 reduziert sich das Modell auf "Index minus TER minus
#  Drag" (Skript '02 Funds Data'), fuer L = 2 auf die MSCI-Hebelformel und fuer
#  L = -1 auf die Short-Formel  -x + 2 * rate (Skript '01 Base Indices').
#
#  PROZENT-KONVENTION: ter, rate, spread und drag werden in Prozent p. a.
#  uebergeben (0.5 = 0,5 % p. a.), wie im restlichen Paket.
# =============================================================================


# ─────────────────────────────────────────────────────────────────────────────
# Interne Helfer
# ─────────────────────────────────────────────────────────────────────────────

#' Zeitreihe aus flexibler Nutzerangabe aufloesen
#'
#' @param x NULL, Skalar, Vektor der Laenge n, Spaltenname in \code{data},
#'   data.frame(date, value) als Stufenfunktion oder benannter Vektor mit
#'   Datumsnamen (Wert gilt ab diesem Datum).
#' @param data data.frame mit Spalte \code{date}.
#' @param what Bezeichnung fuer Fehlermeldungen.
#' @param default Wert fuer NULL.
#' @return numerischer Vektor der Laenge nrow(data).
#' @keywords internal
#' @noRd
.resolve_series <- function(x, data, what, default = 0) {
  n <- nrow(data)
  if (is.null(x)) return(rep(default, n))
  if (is.data.frame(x)) {
    if (ncol(x) < 2) stop(sprintf("%s: data.frame braucht die Spalten date und Wert.", what))
    dcol <- if ("date" %in% names(x)) "date" else names(x)[1]
    vcol <- setdiff(names(x), dcol)[1]
    return(.step_series(.to_date(x[[dcol]], sprintf("%s: Datum", what)), as.numeric(x[[vcol]]), .to_date(data$date, what)))
  }
  if (is.character(x) && length(x) == 1L) {
    if (!x %in% names(data)) stop(sprintf("%s: Spalte '%s' fehlt im Datensatz.", what, x))
    v <- as.numeric(data[[x]])
    if (anyNA(v)) v <- .fill_na(v, "locf")
    return(v)
  }
  if (is.numeric(x) && !is.null(names(x)) && length(x) >= 1L &&
      all(!is.na(suppressWarnings(as.Date(names(x), optional = TRUE))))) {
    return(.step_series(as.Date(names(x)), as.numeric(x), .to_date(data$date, what)))
  }
  if (is.numeric(x) && length(x) == 1L) return(rep(as.numeric(x), n))
  if (is.numeric(x) && length(x) == n) return(as.numeric(x))
  stop(sprintf("%s: nicht interpretierbare Angabe (Skalar, Vektor der L\u00e4nge %d, Spaltenname, data.frame(date, Wert) oder benannter Vektor mit Datumsnamen).", what, n))
}

#' Stufenfunktion: Wert gilt ab Datum (vor dem ersten Datum: erster Wert)
#' @keywords internal
#' @noRd
.step_series <- function(from, value, dates) {
  o <- order(from); from <- from[o]; value <- value[o]
  k <- findInterval(as.numeric(dates), as.numeric(from))
  k[k == 0L] <- 1L
  value[k]
}

#' Fehlende Werte fuellen
#'
#' @param v numerischer Vektor.
#' @param method "none", "locf", "linear" oder "stine" (Stineman, benoetigt
#'   imputeTS; sonst Rueckfall auf "linear" mit Hinweis).
#' @param keep_leading Fuehrende NAs beibehalten (TRUE) oder rueckwaerts fuellen.
#' @keywords internal
#' @noRd
.fill_na <- function(v, method = c("locf", "linear", "stine", "none"), keep_leading = FALSE) {
  method <- match.arg(method)
  ok <- which(!is.na(v))
  if (method == "none" || length(ok) == 0L || length(ok) == length(v)) return(v)
  first <- ok[1]; last <- ok[length(ok)]
  if (method == "stine" && !requireNamespace("imputeTS", quietly = TRUE)) {
    message("Hinweis: Paket 'imputeTS' nicht installiert, verwende lineare Interpolation statt Stineman.")
    method <- "linear"
  }
  if (method == "locf") {
    idx <- integer(length(v)); idx[ok] <- ok; idx <- cummax(idx)
    idx[idx == 0L] <- first
    out <- v[idx]
  } else if (method == "linear") {
    out <- v
    inner <- first:last
    out[inner] <- stats::approx(ok, v[ok], xout = inner)$y
    if (last < length(v)) out[(last + 1L):length(v)] <- v[last]
    if (first > 1L) out[1:(first - 1L)] <- v[first]
  } else {
    out <- v
    inner <- first:last
    out[inner] <- as.numeric(imputeTS::na_interpolation(v[inner], option = "stine"))
    if (last < length(v)) out[(last + 1L):length(v)] <- v[last]
    if (first > 1L) out[1:(first - 1L)] <- v[first]
  }
  if (keep_leading && first > 1L) out[1:(first - 1L)] <- NA_real_
  out
}

#' Verlustfunktionen fuer den Fit
#' @keywords internal
#' @noRd
.bc_loss <- function(e, loss) {
  e <- e[is.finite(e)]
  if (!length(e)) return(Inf)
  switch(loss,
         rmse   = sqrt(mean(e^2)),
         mse    = mean(e^2),
         mae    = mean(abs(e)),
         median = stats::median(abs(e)),
         max    = max(abs(e)),
         stop(sprintf("Unbekannte loss-Funktion '%s'.", loss)))
}

#' Grid-Search-Metriken (korrigierte Fassung von search_metrics aus '02 Funds Data')
#'
#' Die Prozent-Metriken des Skripts teilten den Fehler durch sich selbst
#' (x / (x + 1e-8) ~ 1) und waren daher konstant. Hier beziehen sich die
#' Fehler auf das Verhaeltnis Simulation/Produkt (relative Abweichung).
#' @keywords internal
#' @noRd
.bc_metric_table <- function(err_mat, grid) {
  metrics <- list(
    median_absolute_error  = function(x) stats::median(abs(x), na.rm = TRUE),
    mean_absolute_error    = function(x) mean(abs(x), na.rm = TRUE),
    mean_squared_error     = function(x) mean(x^2, na.rm = TRUE),
    root_mean_squared_error = function(x) sqrt(mean(x^2, na.rm = TRUE)),
    max_absolute_error     = function(x) max(abs(x), na.rm = TRUE),
    final_absolute_error   = function(x) abs(x[max(which(is.finite(x)))])
  )
  vapply(metrics, function(f) grid[which.min(apply(err_mat, 2, f))], numeric(1))
}

#' Ueberlappung, Komponenten und Hilfsgroessen vorbereiten
#' @keywords internal
#' @noRd
.bc_prepare <- function(data, product, index, ter, leverage, rate, fx, rate_lag,
                        ter_basis, rate_basis, accrual, index_fill, lag) {
  if (!is.data.frame(data)) stop("'data' muss ein data.frame sein.")
  if (!"date" %in% names(data)) stop("'data' braucht eine Spalte 'date'.")
  data$date <- .to_date(data$date, "'data$date'")
  if (anyNA(data$date)) stop("'data$date' enth\u00e4lt fehlende Daten.")
  if (is.unsorted(data$date) || anyDuplicated(data$date))
    stop("'data$date' muss streng aufsteigend und ohne Duplikate sein.")
  for (col in c(product, index)) if (!col %in% names(data))
    stop(sprintf("Spalte '%s' fehlt im Datensatz.", col))
  if (!is.numeric(leverage) || length(leverage) != 1L || leverage == 0)
    stop("'leverage' muss eine Zahl ungleich 0 sein.")

  idx <- as.numeric(data[[index]])
  if (!is.null(fx)) idx <- idx * .resolve_series(fx, data, "fx")
  if (anyNA(idx)) idx <- .fill_na(idx, index_fill, keep_leading = TRUE)
  if (any(idx <= 0, na.rm = TRUE)) stop("Indexwerte m\u00fcssen positiv sein.")
  prod <- as.numeric(data[[product]])
  prod[!is.na(prod) & prod <= 0] <- NA_real_

  n  <- nrow(data)
  dd <- c(1, as.numeric(diff(data$date)))                 # Kalendertage T_t
  x  <- c(NA_real_, idx[-1] / idx[-n] - 1)                # Indexrendite
  if (lag != 0L) x <- .shift(x, lag)

  ter_v  <- .resolve_series(ter, data, "ter")
  rate_v <- .resolve_series(rate, data, "rate")
  if (rate_lag != 0L) rate_v <- .fill_na(.shift(rate_v, rate_lag), "locf")

  ter_cost <- if (accrual == "geometric") (1 + ter_v / 100)^(dd / ter_basis) - 1 else ter_v / 100 * dd / ter_basis
  fin      <- (1 - leverage) * rate_v / 100 * dd / rate_basis
  m_lev    <- max(leverage - 1, 0) + max(-leverage, 0)

  list(data = data, n = n, dates = data$date, idx = idx, prod = prod, x = x, dd = dd,
       leverage = leverage, ter = ter_v, rate = rate_v, ter_cost = ter_cost, fin = fin,
       sp_unit = m_lev / 100 * dd / rate_basis, dr_unit = dd / 100 / 365)
}

#' Vektor um k Zeilen verschieben (k > 0: Verzoegerung)
#' @keywords internal
#' @noRd
.shift <- function(v, k) {
  n <- length(v)
  if (k == 0L) return(v)
  if (k > 0L) c(rep(NA_real_, k), v[seq_len(n - k)]) else c(v[(1 - k):n], rep(NA_real_, -k))
}

#' Modellrenditen fuer einen Parametersatz
#' @keywords internal
#' @noRd
.bc_model_returns <- function(prep, par, model, reg = NULL) {
  base <- if (model == "structural") {
    par[["beta"]] * prep$leverage * prep$x + prep$fin - prep$ter_cost
  } else if (model == "linear") {
    reg$coef[1] + reg$coef[2] * prep$x
  } else {
    out <- rep(NA_real_, prep$n); ok <- is.finite(prep$x)
    out[ok] <- stats::predict(reg$fit, prep$x[ok])$y
    out
  }
  base - par[["spread"]] * prep$sp_unit - par[["drag"]] * prep$dr_unit
}

#' Abweichungsvektor(en) im Fit-Fenster
#' @keywords internal
#' @noRd
.bc_errors <- function(r, win, obs, objective, horizon) {
  rr <- r[win]; rr[1] <- 0
  if (any(!is.finite(rr))) rr[!is.finite(rr)] <- 0
  ls <- cumsum(log1p(pmax(rr, -0.999999)))               # log-Level der Simulation
  so <- ls[obs$pos]; po <- obs$logp
  e_lvl <- (so - so[1]) - (po - po[1])
  if (objective == "level") return(e_lvl)
  m <- length(so)
  h <- max(1L, as.integer(horizon))
  e_ret <- if (m > h) (so[(1 + h):m] - so[1:(m - h)]) - (po[(1 + h):m] - po[1:(m - h)]) else numeric(0)
  if (objective == "return") return(e_ret)
  list(level = e_lvl, ret = e_ret)
}

#' Zielfunktion
#' @keywords internal
#' @noRd
.bc_objective <- function(r, win, obs, objective, horizon, loss, hybrid_weight) {
  e <- .bc_errors(r, win, obs, objective, horizon)
  if (objective != "hybrid") return(.bc_loss(e, loss))
  # Hybrid: gewichtete Summe der quadrierten RMS-Fehler (Tracking Error + Tracking Difference)
  sqrt(hybrid_weight * mean(e$ret^2) + (1 - hybrid_weight) * mean(e$level^2))
}

#' Kennzahlen Simulation vs. Produkt
#' @keywords internal
#' @noRd
.bc_diagnostics <- function(r, win, obs, dates) {
  rr <- r[win]; rr[1] <- 0; rr[!is.finite(rr)] <- 0
  ls <- cumsum(log1p(pmax(rr, -0.999999)))
  so <- ls[obs$pos] - ls[obs$pos[1]]
  po <- obs$logp - obs$logp[1]
  m  <- length(so)
  d_obs <- dates[win][obs$pos]
  yrs <- as.numeric(d_obs[m] - d_obs[1]) / 365.25
  ret_s <- exp(diff(so)) - 1; ret_p <- exp(diff(po)) - 1
  diffs <- ret_s - ret_p
  per_year <- if (yrs > 0) (m - 1) / yrs else 252
  rel <- 1 - exp(so - po)                                  # wie Skript: 1 - sim/real
  list(
    n_obs = m, years = yrs, start = d_obs[1], end = d_obs[m],
    tracking_error = stats::sd(diffs) * sqrt(per_year) * 100,       # % p. a.
    tracking_difference = if (yrs > 0) (exp(so[m] / yrs) - exp(po[m] / yrs)) * 100 else NA_real_,
    cagr_sim = if (yrs > 0) expm1(so[m] / yrs) * 100 else NA_real_,
    cagr_product = if (yrs > 0) expm1(po[m] / yrs) * 100 else NA_real_,
    final_deviation = expm1(so[m] - po[m]) * 100,
    max_abs_deviation = max(abs(rel)) * 100,
    rmse_level = sqrt(mean((so - po)^2)) * 100,
    correlation = if (length(diffs) > 2) stats::cor(ret_s, ret_p) else NA_real_,
    r_squared = if (length(diffs) > 2) stats::cor(ret_s, ret_p)^2 else NA_real_,
    deviation = data.frame(date = d_obs, deviation = rel)
  )
}


# ─────────────────────────────────────────────────────────────────────────────
# Oeffentliche Funktionen
# ─────────────────────────────────────────────────────────────────────────────

#' Backcast-Modell an ein Produkt anpassen
#'
#' Passt das Rueckrechnungsmodell eines ETF/ETP (auch gehebelt oder invers)
#' auf dem Zeitraum an, in dem sowohl das Produkt als auch sein Basisindex
#' vorliegen. Die freien Parameter werden so gewaehlt, dass die Abweichung
#' zwischen simuliertem und echtem Produkt minimal wird (taeglich, kumuliert
#' oder beides). Eingabe ist ein data.frame mit Datum, Produktkursen (vor der
#' Auflegung \code{NA}) und Indexniveaus; das Ergebnis wird mit [backcast()]
#' in eine verlaengerte Kursreihe umgerechnet.
#'
#' Strukturmodell (\code{model = "structural"}) je Zeile t mit
#' Kalendertagen \eqn{T_t} seit der Vorzeile und Indexrendite \eqn{x_t}:
#' \deqn{r_t = \beta L x_t + (1 - L)\, i_t T_t / B_r - TER_t T_t / B_T
#'       - s\, m(L) T_t / B_r - drag\, T_t / 365}
#' mit \eqn{m(L) = \max(L-1, 0) + \max(-L, 0)}, \eqn{B_r} =
#' \code{rate_basis}, \eqn{B_T} = \code{ter_basis}; \eqn{i}, \eqn{TER},
#' \eqn{s} und \eqn{drag} gehen als Prozent p. a. / 100 ein. Bei den
#' Regressionsmodellen ersetzt die geschaetzte Regression die ersten drei
#' Terme (\code{ter} und \code{rate} gehen dann nicht ein); \code{spread} und
#' \code{drag} werden zusaetzlich abgezogen.
#'
#' @param data data.frame mit Spalte \code{date} (Date oder umwandelbar,
#'   streng aufsteigend, ohne Duplikate) sowie den Spalten fuer Produkt und
#'   Basisindex. Typisch ein Kalendertagsraster (wie in den Projekt-Skripten)
#'   oder Handelstage; Luecken im Produkt (Feiertage, Boersenschluss) sind
#'   erlaubt.
#' @param product Spaltenname der Produkt-Kursreihe (NAV oder Boersenkurs;
#'   Niveaus, \code{NA} vor der Auflegung; Werte <= 0 gelten als fehlend).
#' @param index Spaltenname der Basisindex-Reihe (Niveau > 0, nicht Rendite;
#'   Luecken werden nach \code{index_fill} gefuellt).
#' @param ter Laufende Kosten in Prozent p. a. (0.5 = 0,5 Prozent; Standard 0):
#'   Skalar, Vektor der Laenge \code{nrow(data)}, Spaltenname,
#'   data.frame(date, ter) (Stufenfunktion, gueltig ab Datum) oder benannter
#'   Vektor mit Datumsnamen, z. B.
#'   \code{c("2010-02-24" = 0.35, "2023-10-10" = 0.50)}.
#' @param leverage Hebel L des Produkts relativ zum Index als Zahl ungleich 0
#'   (Standard 1; z. B. 2, -1, -2). Ist der Index bereits ein Hebelindex
#'   (z. B. MSCI USA Leveraged 2x Daily), ist \code{leverage = 1} zu setzen.
#' @param rate Finanzierungszins in Prozent p. a. (Tagesgeld, z. B. ESTR,
#'   EONIA, SOFR, EFFR) in denselben Formen wie \code{ter}; \code{NULL}
#'   (Standard) = 0. Wirkt nur fuer \code{leverage != 1} (Faktor 1 - L).
#' @param fx Optional (Standard \code{NULL} = keine Umrechnung):
#'   Umrechnungsfaktor Indexwaehrung -> Produktwaehrung in denselben Formen wie
#'   \code{ter} (z. B. Spaltenname). Der Index wird mit \code{fx} multipliziert.
#' @param model \code{"structural"} (Standard, Hebel-/Kostenmodell oben),
#'   \code{"linear"} (Regression Produktrendite ~ Indexrendite, Stambaugh-
#'   Backfill) oder \code{"spline"} (Glaettungsspline, Ersatz fuer das GAM aus
#'   '01 Base Indices'). Die Regressionsmodelle werden auf Renditen direkt
#'   aufeinanderfolgender Produktbeobachtungen geschaetzt und eignen sich fuer
#'   Proxy-Rueckrechnungen (z. B. MSCI USA aus S&P 500).
#' @param fit Zeichenvektor der zu schaetzenden Parameter (Standard
#'   \code{"drag"}): Teilmenge von \code{"drag"} (Restabweichung in Prozent
#'   p. a.), \code{"spread"} (Spread auf den finanzierten Anteil in Prozent
#'   p. a., nur fuer L != 1, sonst mit Warnung ignoriert) und \code{"beta"}
#'   (effektiver Hebel-Multiplikator, Faktor; nur Strukturmodell).
#'   \code{character(0)} schaetzt nichts (reine Kostenrechnung).
#' @param fixed Benannte Liste fester Parameterwerte, z. B.
#'   \code{list(spread = 0.4)}; nicht genannte Parameter: drag = 0,
#'   spread = 0 (Prozent p. a.), beta = 1. Die Werte dienen auch als
#'   Startwerte der Optimierung.
#' @param objective \code{"level"} (Standard; kumulierte Pfadabweichung der
#'   Log-Niveaus, wie im Skript '02 Funds Data'; bestimmt die Tracking
#'   Difference), \code{"return"} (Log-Renditeabweichungen ueber
#'   \code{horizon} Beobachtungen; Tracking Error) oder \code{"hybrid"}
#'   (gewichtete Kombination beider RMS-Fehler).
#' @param loss Fehlermass fuer "level" und "return": "rmse" (Standard),
#'   "mse", "mae", "median" (Median der Betraege) oder "max". Bei "hybrid"
#'   ohne Wirkung (immer RMS).
#' @param horizon Renditehorizont in Produktbeobachtungen fuer "return"/"hybrid"
#'   (ganze Zahl >= 1, Standard 1). Werte > 1 (z. B. 5) daempfen asynchrone
#'   Schlusskurse (Xetra vs. US-Index).
#' @param hybrid_weight Gewicht des Renditeterms bei "hybrid" als Anteil
#'   (0..1, Standard 0.5); der Niveauterm erhaelt 1 - \code{hybrid_weight}.
#' @param lag Verzoegerung des Index gegenueber dem Produkt in Zeilen
#'   (ganzzahlig, Standard 0; bei k > 0 wird die Produktrendite in Zeile t mit
#'   der Indexrendite aus Zeile t - k modelliert) oder \code{"auto"} (Lag aus
#'   -2..2 mit der hoechsten Korrelation, bei negativem Hebel der niedrigsten).
#' @param rate_lag Verzoegerung des Zinssatzes in Zeilen (Standard 0 = Satz
#'   des Tages t; k > 0 = Satz aus Zeile t - k).
#' @param start,end Optionales Fit-Fenster (Datum oder Zeichenkette
#'   "JJJJ-MM-TT"); \code{NULL} (Standard) = gesamte Ueberlappung. Mindestens
#'   20 gemeinsame Beobachtungen.
#' @param method \code{"optimize"} (Standard; ein Parameter mit
#'   \code{stats::optimize()} (Brent), mehrere mit L-BFGS-B innerhalb von
#'   \code{bounds}) oder \code{"grid"} (Gittersuche fuer genau einen Parameter,
#'   wie im Skript).
#' @param grid Gitterwerte fuer \code{method = "grid"} in der Einheit des
#'   Parameters (drag, spread: Prozent p. a.; beta: Faktor); Standard
#'   \code{seq(-3, 3, by = 0.005)}.
#' @param bounds Benannte Liste von Suchintervallen \code{c(unten, oben)} je
#'   Parameter fuer \code{method = "optimize"}, in der Einheit des Parameters;
#'   Standard \code{list(drag = c(-10, 10), spread = c(-5, 10),
#'   beta = c(0.5, 1.5)}. Eine eigene Liste ergaenzt die Standardliste:
#'   Nicht genannte Parameter behalten ihr Standardintervall (je Eintrag
#'   \code{c(unten, oben)} mit unten < oben).
#' @param ter_basis,rate_basis Tagesbasis fuer TER (Standard 365) und fuer
#'   Zins und Spread (Standard 360, Act/360).
#' @param accrual Abgrenzung der TER: \code{"linear"} (Standard,
#'   TER * T / 365, Fondsbuchhaltung) oder \code{"geometric"}
#'   ((1 + TER)^(T/365) - 1, wie in den Skripten).
#' @param index_fill Fuellmethode fuer Indexluecken: "locf" (Standard),
#'   "linear" oder "stine" (Stineman, benoetigt imputeTS, sonst linear).
#'   Fuehrende Luecken bleiben \code{NA}.
#' @param validate Logisch (Standard \code{TRUE}): Out-of-Sample-Pruefung
#'   (Fit auf der juengeren Haelfte der Produktbeobachtungen, Test auf der
#'   aelteren, also in Backcast-Richtung); erst ab 80 Beobachtungen.
#'
#' @return Objekt der Klasse \code{SimLevBackcastFit}, eine Liste mit u. a.
#'   \describe{
#'     \item{params}{Liste \code{drag}, \code{spread} (Prozent p. a.) und
#'       \code{beta} (Faktor).}
#'     \item{fitted, model, objective, loss, loss_value, method, horizon, lag}{Fit-Einstellungen,
#'       Wert der Zielfunktion und verwendeter Lag (Zeilen).}
#'     \item{diagnostics, diagnostics_unfitted}{Kennzahlen Simulation vs.
#'       Produkt mit bzw. ohne gefittete Parameter: \code{n_obs},
#'       \code{years}, \code{start}, \code{end}, \code{tracking_error}
#'       (Prozent p. a.), \code{tracking_difference} (Prozentpunkte p. a.),
#'       \code{cagr_sim}, \code{cagr_product}, \code{final_deviation},
#'       \code{max_abs_deviation} (jeweils Prozent), \code{rmse_level}
#'       (RMSE der Log-Niveaus x 100), \code{correlation}, \code{r_squared}
#'       und \code{deviation} (data.frame date, deviation = 1 - Sim/Produkt
#'       als Anteil).}
#'     \item{grid, grid_metrics}{Bei \code{method = "grid"}: data.frame
#'       (value, loss) und bestes Gitterelement je Fehlermetrik, sonst \code{NULL}.}
#'     \item{validation}{Out-of-Sample-Ergebnis (Zeitraeume \code{train},
#'       \code{test}, Parameter \code{par}, Testkennzahlen in Prozent) oder
#'       \code{NULL}.}
#'     \item{regression}{Regressionsfit (nur "linear"/"spline").}
#'     \item{inception, window}{Erstes Produktdatum und Fit-Fenster.}
#'     \item{drag_per_day}{Drag in Prozent je Kalendertag.}
#'     \item{call_args}{Daten und Modellangaben fuer [backcast()].}
#'   }
#'
#' @examples
#' set.seed(1)
#' n <- 3000
#' d <- seq.Date(as.Date("2010-01-01"), by = "day", length.out = n)
#' idx <- 100 * cumprod(1 + rnorm(n, 3e-4, 0.01))
#' rate <- rep(2, n)
#' etf_ret <- 2 * c(0, diff(idx) / head(idx, -1)) - 1 * rate / 100 / 360 -
#'   0.6 / 100 / 365
#' etf <- 50 * cumprod(1 + etf_ret)
#' etf[1:1500] <- NA                          # Produkt erst ab Tag 1501
#' df <- data.frame(date = d, etf = etf, idx = idx, rate = rate)
#' fit <- backcast_fit(df, product = "etf", index = "idx", ter = 0.5,
#'                     leverage = 2, rate = "rate")
#' fit
#' fit$params$drag                            # ca. 0.1 (Prozent p. a.)
#' bc <- backcast(fit)
#' head(bc)
#'
#' @seealso [backcast()], [leveraged_series()], [simulation()]
#' @export
backcast_fit <- function(data, product, index,
                         ter = 0, leverage = 1, rate = NULL, fx = NULL,
                         model = c("structural", "linear", "spline"),
                         fit = "drag", fixed = list(),
                         objective = c("level", "return", "hybrid"),
                         loss = c("rmse", "mse", "mae", "median", "max"),
                         horizon = 1L, hybrid_weight = 0.5,
                         lag = 0L, rate_lag = 0L,
                         start = NULL, end = NULL,
                         method = c("optimize", "grid"),
                         grid = seq(-3, 3, by = 0.005),
                         bounds = list(drag = c(-10, 10), spread = c(-5, 10), beta = c(0.5, 1.5)),
                         ter_basis = 365, rate_basis = 360,
                         accrual = c("linear", "geometric"),
                         index_fill = c("locf", "linear", "stine"),
                         validate = TRUE) {
  model     <- match.arg(model)
  objective <- match.arg(objective)
  loss      <- match.arg(loss)
  method    <- match.arg(method)
  accrual   <- match.arg(accrual)
  index_fill <- match.arg(index_fill)
  fit <- unique(as.character(fit))
  if (length(fit) && !all(fit %in% c("drag", "spread", "beta")))
    stop("'fit' darf nur 'drag', 'spread' und 'beta' enthalten.")
  # Eigene Suchintervalle ergaenzen die Standardliste (fehlende Parameter behalten ihr Intervall)
  if (!is.list(bounds) || (length(bounds) && (is.null(names(bounds)) || !all(names(bounds) %in% c("drag", "spread", "beta")))))
    stop("'bounds' muss eine benannte Liste mit Eintr\u00e4gen drag, spread und/oder beta sein, z. B. list(drag = c(-5, 5)).")
  bounds <- utils::modifyList(list(drag = c(-10, 10), spread = c(-5, 10), beta = c(0.5, 1.5)), bounds)
  for (k in names(bounds)) { b <- bounds[[k]]
    if (!is.numeric(b) || length(b) != 2L || anyNA(b) || b[1] >= b[2])
      stop(sprintf("bounds$%s muss c(unten, oben) mit unten < oben sein (ist: %s).", k, paste(format(b), collapse = ", "))) }
  if (model != "structural" && "beta" %in% fit) {
    warning("'beta' wird bei Regressionsmodellen \u00fcber die Regression gesch\u00e4tzt und hier ignoriert.")
    fit <- setdiff(fit, "beta")
  }
  if (leverage == 1 && "spread" %in% fit) {
    warning("'spread' ist bei leverage = 1 nicht identifizierbar und wird ignoriert.")
    fit <- setdiff(fit, "spread")
  }

  # Lag automatisch bestimmen
  lag_auto <- identical(lag, "auto")
  prep <- .bc_prepare(data, product, index, ter, leverage, rate, fx, as.integer(rate_lag),
                      ter_basis, rate_basis, accrual, index_fill, if (lag_auto) 0L else as.integer(lag))
  if (lag_auto) {
    pr <- c(NA_real_, prep$prod[-1] / prep$prod[-prep$n] - 1)
    cand <- -2:2
    cors <- vapply(cand, function(k) {
      xs <- .shift(prep$x, k); ok <- is.finite(xs) & is.finite(pr)
      if (sum(ok) < 30) NA_real_ else stats::cor(xs[ok], pr[ok])
    }, numeric(1))
    lag <- cand[which.max(sign(leverage) * cors)]
    prep <- .bc_prepare(data, product, index, ter, leverage, rate, fx, as.integer(rate_lag),
                        ter_basis, rate_basis, accrual, index_fill, as.integer(lag))
  }

  # Fit-Fenster: Ueberlappung Produkt & Index
  has <- !is.na(prep$prod) & !is.na(prep$idx)
  if (!is.null(start)) has <- has & prep$dates >= as.Date(start)
  if (!is.null(end))   has <- has & prep$dates <= as.Date(end)
  if (sum(has) < 20) stop("Zu wenige gemeinsame Beobachtungen von Produkt und Index (mindestens 20).")
  w0 <- min(which(has)); w1 <- max(which(has))
  win <- w0:w1
  inception <- prep$dates[min(which(!is.na(prep$prod)))]

  make_obs <- function(rows) {
    pos <- which(has[rows])
    list(pos = pos, logp = log(prep$prod[rows][pos]))
  }
  obs <- make_obs(win)

  # Regression (nur Regressionsmodelle), auf 1-Schritt-Renditen der Beobachtungen
  fit_reg <- function(rows) {
    if (model == "structural") return(NULL)
    o <- which(has[rows]) + rows[1] - 1L
    o <- o[o > 1]
    y <- prep$prod[o] / prep$prod[o - 1L] - 1            # nur direkt aufeinanderfolgende Zeilen
    xx <- prep$x[o]
    ok <- is.finite(y) & is.finite(xx) & !is.na(prep$prod[o - 1L])
    if (sum(ok) < 20) stop("Zu wenige aufeinanderfolgende Beobachtungen f\u00fcr das Regressionsmodell.")
    if (model == "linear") list(coef = stats::coef(stats::lm.fit(cbind(1, xx[ok]), y[ok])))
    else list(fit = stats::smooth.spline(xx[ok], y[ok], cv = FALSE))
  }
  reg <- fit_reg(win)

  par0 <- utils::modifyList(list(drag = 0, spread = 0, beta = 1), fixed)
  obj_fun <- function(theta, rows, ob, rg) {
    p <- par0; p[fit] <- as.list(theta)
    .bc_objective(.bc_model_returns(prep, p, model, rg)[rows], seq_along(rows), ob,
                  objective, horizon, loss, hybrid_weight)
  }
  # .bc_objective erwartet win als Index in r; wir uebergeben r[rows] und 1..length
  run_fit <- function(rows, ob, rg) {
    if (!length(fit)) return(list(par = par0, value = obj_fun(numeric(0), rows, ob, rg), grid = NULL))
    if (method == "grid") {
      if (length(fit) != 1L) stop("method = 'grid' unterst\u00fctzt genau einen Parameter in 'fit'.")
      vals <- vapply(grid, function(g) obj_fun(g, rows, ob, rg), numeric(1))
      best <- grid[which.min(vals)]
      # Fehlermatrix fuer die Metriktabelle (relative Abweichung 1 - sim/real)
      err_mat <- vapply(grid, function(g) {
        p <- par0; p[[fit]] <- g
        e <- .bc_errors(.bc_model_returns(prep, p, model, rg)[rows], seq_along(rows), ob, "level", 1L)
        1 - exp(e)
      }, numeric(length(ob$pos)))
      p <- par0; p[[fit]] <- best
      return(list(par = p, value = min(vals), grid = data.frame(value = grid, loss = vals),
                  metrics = .bc_metric_table(err_mat, grid)))
    }
    if (length(fit) == 1L) {
      b <- bounds[[fit]]
      o <- stats::optimize(function(t) obj_fun(t, rows, ob, rg), lower = b[1], upper = b[2], tol = 1e-8)
      p <- par0; p[[fit]] <- o$minimum
      return(list(par = p, value = o$objective, grid = NULL))
    }
    st <- unlist(par0[fit])
    lo <- vapply(fit, function(k) bounds[[k]][1], 0); hi <- vapply(fit, function(k) bounds[[k]][2], 0)
    o <- stats::optim(st, function(t) obj_fun(t, rows, ob, rg), method = "L-BFGS-B", lower = lo, upper = hi)
    p <- par0; p[fit] <- as.list(o$par)
    list(par = p, value = o$value, grid = NULL, convergence = o$convergence)
  }

  res <- run_fit(win, obs, reg)
  r_all <- .bc_model_returns(prep, res$par, model, reg)
  diag <- .bc_diagnostics(r_all[win], seq_along(win), obs, prep$dates[win])
  diag_naive <- .bc_diagnostics(.bc_model_returns(prep, par0, model, reg)[win], seq_along(win), obs, prep$dates[win])

  # Out-of-Sample: Fit auf juengerer Haelfte, Test auf aelterer Haelfte
  oos <- NULL
  if (validate && length(obs$pos) >= 80) {
    cut_row <- win[obs$pos[floor(length(obs$pos) / 2)]]
    tr_rows <- cut_row:w1; te_rows <- w0:cut_row
    ob_tr <- make_obs(tr_rows); ob_te <- make_obs(te_rows)
    rg_tr <- tryCatch(fit_reg(tr_rows), error = function(e) NULL)
    if (model == "structural" || !is.null(rg_tr)) {
      res_tr <- run_fit(tr_rows, ob_tr, rg_tr)
      d_te <- .bc_diagnostics(.bc_model_returns(prep, res_tr$par, model, rg_tr)[te_rows],
                              seq_along(te_rows), ob_te, prep$dates[te_rows])
      d_te0 <- .bc_diagnostics(.bc_model_returns(prep, par0, model, rg_tr)[te_rows],
                               seq_along(te_rows), ob_te, prep$dates[te_rows])
      oos <- list(train = c(prep$dates[tr_rows[1]], prep$dates[w1]),
                  test = c(prep$dates[w0], prep$dates[cut_row]),
                  par = res_tr$par,
                  test_rmse_level = d_te$rmse_level, test_tracking_difference = d_te$tracking_difference,
                  test_tracking_error = d_te$tracking_error,
                  naive_rmse_level = d_te0$rmse_level, naive_tracking_difference = d_te0$tracking_difference)
    }
  }

  out <- list(
    params = res$par, fitted = fit, model = model, objective = objective, loss = loss,
    loss_value = res$value, method = method, horizon = horizon, lag = as.integer(lag),
    diagnostics = diag, diagnostics_unfitted = diag_naive,
    grid = res$grid, grid_metrics = res$metrics, validation = oos,
    regression = reg, inception = inception, window = c(prep$dates[w0], prep$dates[w1]),
    drag_per_day = res$par$drag / 100 / 365 * 100,   # Prozent je Kalendertag (Skript-Einheit)
    call_args = list(data = data, product = product, index = index, ter = ter,
                     leverage = leverage, rate = rate, fx = fx, rate_lag = as.integer(rate_lag),
                     ter_basis = ter_basis, rate_basis = rate_basis, accrual = accrual,
                     index_fill = index_fill)
  )
  class(out) <- "SimLevBackcastFit"
  out
}


#' Produkt-Kursreihe zurueckrechnen und verketten
#'
#' Rechnet ein Produkt mit den Parametern aus [backcast_fit()] (oder fest
#' vorgegebenen Parametern) ueber die gesamte Indexhistorie und verkettet die
#' Simulation renditebasiert (Chain-Linking) mit der echten Produktreihe ab
#' Auflegung. Es entsteht kein Sprung am Verkettungstag; ab dem
#' Verkettungstag stimmt \code{value} (ohne \code{rebase}) an allen
#' Beobachtungstagen mit den echten Kursen ueberein. Das Ergebnis kann z. B.
#' nach Umbenennen von \code{value} als Kursspalte fuer [simulation()]
#' dienen.
#'
#' @param fit Ein \code{SimLevBackcastFit}-Objekt aus [backcast_fit()].
#'   Alternativ \code{NULL} (Standard), dann werden \code{data},
#'   \code{product}, \code{index} und die Modellangaben ueber \code{...}
#'   uebergeben und \code{params} direkt verwendet (nur Strukturmodell).
#' @param data Bei \code{fit}: optional anderer Datensatz (z. B. laengere
#'   Indexhistorie) mit denselben Spaltennamen; \code{NULL} (Standard) =
#'   Datensatz des Fits. Bei \code{fit = NULL} Pflicht (Format wie in
#'   [backcast_fit()]).
#' @param params Optional Liste mit \code{drag}, \code{spread} (Prozent p. a.)
#'   und/oder \code{beta} (Faktor). Ueberschreibt einzelne Parameter des Fits;
#'   ohne Fit gelten fuer fehlende Eintraege drag = 0, spread = 0, beta = 1.
#' @param splice \code{"inception"} (Standard: echte Renditen ab dem ersten
#'   Produktkurs), \code{"none"} (reine Modellreihe) oder ein Datum: echte
#'   Renditen ab dem ersten Produktkurs an oder nach diesem Datum (Fehler,
#'   wenn danach kein Produktkurs vorliegt).
#' @param fill Fuellmethode fuer Produktluecken nach der Verkettung:
#'   "locf" (Standard, wie die Engine), "linear", "stine" (imputeTS) oder "model"
#'   (Lueckentage mit Modellrenditen, Endpunkte aus echten Kursen; erhaelt die
#'   echten Kurse an allen Beobachtungstagen).
#' @param rebase \code{NULL} (Standard; Produkteinheiten, echte Kurse bleiben
#'   erhalten) oder Startwert der Reihe am ersten Indextag, z. B. 100
#'   (\code{value} und \code{model} werden skaliert, \code{product} nicht).
#' @param ... Bei \code{fit = NULL}: Argumente wie in [backcast_fit()]
#'   (\code{product}, \code{index} als Pflicht; \code{ter} (Standard 0),
#'   \code{leverage} (1), \code{rate} (\code{NULL} = 0), \code{fx},
#'   \code{rate_lag}, \code{ter_basis}, \code{rate_basis}, \code{accrual},
#'   \code{index_fill}, \code{lag}; \code{model} nur "structural").
#'
#' @return data.frame der Klasse \code{c("SimLevBackcast", "data.frame")} mit
#'   einer Zeile je Zeile von \code{data}: \code{date}, \code{value}
#'   (verkettete Reihe; \code{NA} vor dem ersten Indexwert), \code{return}
#'   (einfache Rendite von \code{value} als Anteil), \code{model} (reine
#'   Modellreihe auf gleichem Niveau), \code{product} (Rohdaten) und
#'   \code{source} ("backcast", "product" oder "filled"). Attribute
#'   \code{"fit"} (Fit-Objekt oder \code{NULL}), \code{"params"} (verwendete
#'   Parameter) und \code{"splice_date"} (Verkettungsdatum oder \code{NA}).
#' @examples
#' # Ohne Fit: Hebelprodukt mit bekannten Kosten zurueckrechnen
#' set.seed(1); n <- 1000
#' d <- data.frame(date = seq.Date(as.Date("2015-01-01"), by = "day", length.out = n))
#' d$idx <- 100 * cumprod(1 + rnorm(n, 3e-4, 0.01))
#' d$etf <- leveraged_series(d, "idx", leverage = 2, rate = 2, expense = 0.6)
#' d$etf[1:600] <- NA                       # Produkt erst ab Tag 601
#' bc <- backcast(data = d, product = "etf", index = "idx", leverage = 2,
#'                rate = 2, ter = 0.6, rebase = 100)
#' bc[599:602, ]
#' table(bc$source)
#' attr(bc, "splice_date")
#' @seealso [backcast_fit()], [leveraged_series()], [simulation()]
#' @export
backcast <- function(fit = NULL, data = NULL, params = NULL,
                     splice = "inception",
                     fill = c("locf", "linear", "stine", "model"),
                     rebase = NULL, ...) {
  fill <- match.arg(fill)
  if (is.null(fit)) {
    dots <- list(...)
    if (is.null(data)) stop("Ohne 'fit' muss 'data' angegeben werden.")
    a <- utils::modifyList(list(ter = 0, leverage = 1, rate = NULL, fx = NULL, rate_lag = 0L,
                                ter_basis = 365, rate_basis = 360, accrual = "linear",
                                index_fill = "locf"), dots)
    if (is.null(a$product) || is.null(a$index)) stop("'product' und 'index' m\u00fcssen angegeben werden.")
    a$data <- data
    model <- dots$model %||% "structural"
    if (model != "structural") stop("Ohne Fit ist nur model = 'structural' m\u00f6glich.")
    reg <- NULL
    par <- utils::modifyList(list(drag = 0, spread = 0, beta = 1), params %||% list())
    lag <- as.integer(dots$lag %||% 0L)
  } else {
    if (!inherits(fit, "SimLevBackcastFit")) stop("'fit' muss ein SimLevBackcastFit-Objekt sein.")
    a <- fit$call_args
    if (!is.null(data)) a$data <- data
    model <- fit$model; reg <- fit$regression; lag <- fit$lag
    par <- utils::modifyList(fit$params, params %||% list())
  }

  prep <- .bc_prepare(a$data, a$product, a$index, a$ter, a$leverage, a$rate, a$fx,
                      as.integer(a$rate_lag), a$ter_basis, a$rate_basis, a$accrual,
                      a$index_fill, lag)
  r_mod <- .bc_model_returns(prep, par, model, reg)
  n <- prep$n
  prod <- prep$prod
  first_idx <- min(which(!is.na(prep$idx)))
  obs <- which(!is.na(prod))

  # Verkettungszeitpunkt
  if (identical(splice, "none") || !length(obs)) {
    k0 <- NA_integer_
  } else if (identical(splice, "inception")) {
    k0 <- obs[1]
  } else {
    sd0 <- .to_date(splice, "splice")
    if (length(sd0) != 1L || is.na(sd0)) stop("splice: \"inception\", \"none\" oder ein Datum ('JJJJ-MM-TT').")
    k0 <- obs[prep$dates[obs] >= sd0][1]
    if (is.na(k0)) stop(sprintf("Kein Produktkurs ab dem Verkettungsdatum %s vorhanden (letzter Produktkurs am %s).",
                                format(sd0), format(prep$dates[max(obs)])))
  }

  # Produktrenditen ab Verkettung (mit Lueckenbehandlung)
  r_out <- r_mod
  source <- rep("backcast", n)
  if (!is.na(k0)) {
    seg <- k0:n
    last_obs <- max(obs)
    pv <- prod[seg]
    if (fill == "model") {
      # Lueckentage per Modellrendite, auf echte Endpunkte skaliert (Brownian-Bridge-artig)
      po <- which(!is.na(pv))
      lv <- rep(NA_real_, length(seg)); lv[po] <- log(pv[po])
      lr <- log1p(pmax(ifelse(is.finite(r_mod[seg]), r_mod[seg], 0), -0.999999))
      for (j in seq_len(length(po) - 1L)) {
        a0 <- po[j]; a1 <- po[j + 1L]
        if (a1 - a0 > 1L) {
          step <- lr[(a0 + 1L):a1]
          adj <- ((lv[a1] - lv[a0]) - sum(step)) / length(step)
          lv[(a0 + 1L):(a1 - 1L)] <- lv[a0] + cumsum(step + adj)[seq_len(a1 - a0 - 1L)]
        }
      }
      if (max(po) < length(seg)) lv[(max(po) + 1L):length(seg)] <- lv[max(po)]
      pf <- exp(lv)
    } else {
      pf <- .fill_na(pv, fill)
    }
    source[seg] <- ifelse(is.na(pv), "filled", "product")
    if (last_obs < n) source[(last_obs + 1L):n] <- "filled"
    r_seg <- c(NA_real_, pf[-1] / pf[-length(pf)] - 1)
    r_out[seg[-1]] <- r_seg[-1]
    r_out[k0] <- r_mod[k0]
  }

  # Niveau: Anker = erster echter Produktkurs (oder 100 am Indexbeginn)
  lr_all <- log1p(pmax(ifelse(is.finite(r_out), r_out, 0), -0.999999))
  lr_mod <- log1p(pmax(ifelse(is.finite(r_mod), r_mod, 0), -0.999999))
  lr_all[seq_len(first_idx)] <- 0; lr_mod[seq_len(first_idx)] <- 0
  cl <- cumsum(lr_all); cm <- cumsum(lr_mod)
  if (!is.na(k0)) {
    value <- prod[k0] * exp(cl - cl[k0])
    model_v <- prod[k0] * exp(cm - cm[k0])
  } else {
    value <- 100 * exp(cl); model_v <- 100 * exp(cm)
  }
  if (first_idx > 1L) { value[seq_len(first_idx - 1L)] <- NA_real_; model_v[seq_len(first_idx - 1L)] <- NA_real_ }
  if (!is.null(rebase)) {
    s <- rebase / value[first_idx]
    value <- value * s; model_v <- model_v * s
  }
  out <- data.frame(date = prep$dates, value = value,
                    return = c(NA_real_, value[-1] / value[-n] - 1),
                    model = model_v, product = prod, source = source,
                    stringsAsFactors = FALSE)
  attr(out, "fit") <- fit
  attr(out, "params") <- par
  attr(out, "splice_date") <- if (!is.na(k0)) prep$dates[k0] else NA
  class(out) <- c("SimLevBackcast", "data.frame")
  out
}


# ─────────────────────────────────────────────────────────────────────────────
# Methoden
# ─────────────────────────────────────────────────────────────────────────────

#' Methoden fuer Backcast-Objekte
#'
#' Ausgabe-, Zusammenfassungs- und Grafikmethoden fuer Ergebnisse von
#' [backcast_fit()] (\code{SimLevBackcastFit}) und [backcast()]
#' (\code{SimLevBackcast}). \code{print()} eines Fits zeigt Parameter und
#' Abweichungskennzahlen ohne und mit Fit (in Prozent);
#' \code{plot()} eines Fits zeigt die Pfadabweichung im Fit-Fenster (und bei
#' Gittersuche die Verlustkurve), \code{plot()} eines Backcasts die
#' verkettete Reihe, die durchgehende Modellreihe und das Verkettungsdatum.
#'
#' @param x Ein \code{SimLevBackcastFit}- bzw. \code{SimLevBackcast}-Objekt.
#' @param object Ein \code{SimLevBackcastFit}-Objekt.
#' @param log Logisch: logarithmische y-Achse (Standard \code{TRUE}; nur
#'   \code{plot()} eines \code{SimLevBackcast}).
#' @param ... Weitere Argumente: bei \code{plot()} an \code{plot()} der ersten
#'   Grafik weitergereicht, bei \code{print()} eines \code{SimLevBackcast} an
#'   \code{print()} der ersten Zeilen; sonst ohne Wirkung.
#' @return \code{print()} und \code{plot()}: das Objekt (unsichtbar).
#'   \code{summary()} eines Fits druckt den Fit und gibt unsichtbar eine Liste
#'   mit \code{params}, \code{diagnostics} (ohne \code{deviation}) und
#'   \code{validation} zurueck.
#' @name SimLevBackcast-methods
#' @keywords internal
NULL

#' @rdname SimLevBackcast-methods
#' @export
print.SimLevBackcastFit <- function(x, ...) {
  d <- x$diagnostics; d0 <- x$diagnostics_unfitted
  cat("\n")
  cat("\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\n")
  cat("                    SimLev Backcast-Fit                        \n")
  cat("\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\n\n")
  cat(sprintf("  Modell:           %s (Ziel: %s, Verlust: %s, Methode: %s)\n",
              x$model, x$objective, x$loss, x$method))
  cat(sprintf("  Fit-Fenster:      %s bis %s (%d Beobachtungen, %.1f Jahre)\n",
              format(d$start), format(d$end), d$n_obs, d$years))
  cat(sprintf("  Hebel / Lag:      %s / %d Zeilen\n", format(x$call_args$leverage), x$lag))
  cat("\n  Parameter\n  \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\n")
  p <- x$params
  mark <- function(k) if (k %in% x$fitted) "(gefittet)" else "(fest)"
  if (x$model == "structural") cat(sprintf("  Beta:             %.5f %s\n", p$beta, mark("beta")))
  if (x$call_args$leverage != 1) cat(sprintf("  Spread:           %+.4f %% p. a. %s\n", p$spread, mark("spread")))
  cat(sprintf("  Drag:             %+.4f %% p. a. %s  (= %+.6f %% je Tag)\n", p$drag, mark("drag"), x$drag_per_day))
  if (!is.null(x$regression$coef))
    cat(sprintf("  Regression:       a = %.3e, b = %.5f\n", x$regression$coef[1], x$regression$coef[2]))
  cat("\n  Abweichung Simulation vs. Produkt     ohne Fit     mit Fit\n  \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\n")
  row <- function(lbl, a, b, unit = "%") cat(sprintf("  %-34s %9.4f%s %9.4f%s\n", lbl, a, unit, b, unit))
  row("Tracking Error p. a.", d0$tracking_error, d$tracking_error)
  row("Tracking Difference p. a.", d0$tracking_difference, d$tracking_difference)
  row("Endabweichung kumuliert", d0$final_deviation, d$final_deviation)
  row("Max. Pfadabweichung", d0$max_abs_deviation, d$max_abs_deviation)
  row("RMSE Log-Niveau", d0$rmse_level, d$rmse_level)
  cat(sprintf("  %-34s %10.4f  %10.4f\n", "Korrelation Tagesrenditen", d0$correlation, d$correlation))
  if (!is.null(x$validation)) {
    v <- x$validation
    cat("\n  Out-of-Sample (Fit j\u00fcngere, Test \u00e4ltere H\u00e4lfte)\n  \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\n")
    cat(sprintf("  Test-Zeitraum:    %s bis %s\n", format(v$test[1]), format(v$test[2])))
    cat(sprintf("  RMSE Log-Niveau:  %.4f %% (ohne Fit: %.4f %%)\n", v$test_rmse_level, v$naive_rmse_level))
    cat(sprintf("  Tracking Diff.:   %+.4f %% p. a. (ohne Fit: %+.4f %%)\n",
                v$test_tracking_difference, v$naive_tracking_difference))
  }
  if (!is.null(x$grid_metrics)) {
    cat("\n  Gittersuche: bestes Gitterelement je Metrik\n  \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\n")
    for (k in names(x$grid_metrics)) cat(sprintf("  %-26s %+.4f\n", k, x$grid_metrics[[k]]))
  }
  cat("\n\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\n")
  invisible(x)
}

#' @rdname SimLevBackcast-methods
#' @export
summary.SimLevBackcastFit <- function(object, ...) {
  print(object)
  invisible(list(params = object$params, diagnostics = object$diagnostics[setdiff(names(object$diagnostics), "deviation")],
                 validation = object$validation))
}

#' @rdname SimLevBackcast-methods
#' @export
plot.SimLevBackcastFit <- function(x, ...) {
  dev <- x$diagnostics$deviation
  old <- graphics::par(no.readonly = TRUE); on.exit(graphics::par(old))
  graphics::par(mfrow = c(if (is.null(x$grid)) 1 else 2, 1), mar = c(4, 4.6, 2.5, 1), mgp = c(2.9, 0.7, 0), las = 1)
  plot(dev$date, dev$deviation * 100, type = "l", col = "#2C6E9B", lwd = 1,
       xlab = "Datum", ylab = "1 - Sim/Produkt (%)", main = "Pfadabweichung im Fit-Fenster", ...)
  graphics::abline(h = 0, col = "grey50", lty = 2)
  if (!is.null(x$grid)) {
    plot(x$grid$value, x$grid$loss, type = "l", col = "#B5562B",
         xlab = sprintf("%s (%% p. a.)", x$fitted[1]), ylab = x$loss, main = "Gittersuche")
    graphics::abline(v = x$params[[x$fitted[1]]], col = "grey40", lty = 3)
  }
  invisible(x)
}

#' @rdname SimLevBackcast-methods
#' @export
plot.SimLevBackcast <- function(x, log = TRUE, ...) {
  old <- graphics::par(no.readonly = TRUE); on.exit(graphics::par(old))
  graphics::par(mar = c(4, 4.6, 2.5, 1), mgp = c(2.9, 0.7, 0), las = 1)
  ok <- is.finite(x$value)
  plot(x$date[ok], x$value[ok], type = "n", log = if (log) "y" else "", xlab = "Datum",
       ylab = if (log) "Wert (log. Skala)" else "Wert", main = "Backcast und Produkt", yaxt = "n", ...)
  at <- graphics::axTicks(2)
  graphics::axis(2, at = at, labels = formatC(at, format = "fg", big.mark = " "))   # R9-07: Dezimalpunkt, Leerzeichen als Tausendertrenner
  bc <- x$source == "backcast" & ok
  graphics::lines(x$date[ok], x$model[ok], col = "grey65", lwd = 1)
  graphics::lines(x$date[bc], x$value[bc], col = "#B5562B", lwd = 1.2)
  graphics::lines(x$date[!bc & ok], x$value[!bc & ok], col = "#2C6E9B", lwd = 1.2)
  sd0 <- attr(x, "splice_date")
  if (!is.null(sd0) && !is.na(sd0)) graphics::abline(v = sd0, lty = 3, col = "grey40")
  graphics::legend("topleft", bty = "n", lwd = 1.2, col = c("#B5562B", "#2C6E9B", "grey65"),
                   legend = c("Backcast", "Produkt", "Modell durchgehend"))
  invisible(x)
}

#' @rdname SimLevBackcast-methods
#' @export
print.SimLevBackcast <- function(x, ...) {
  n_bc <- sum(x$source == "backcast" & is.finite(x$value))
  cat(sprintf("SimLev Backcast: %d Zeilen, %s bis %s; %d Backcast-Tage, Verkettung am %s\n",
              nrow(x), format(min(x$date)), format(max(x$date)), n_bc,
              format(attr(x, "splice_date"))))
  print(utils::head(as.data.frame(x)), ...)
  invisible(x)
}

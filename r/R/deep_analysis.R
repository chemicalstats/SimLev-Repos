# =============================================================================
#  deep_analysis.R  —  Vertiefte Auswertung gespeicherter Ergebnisse
# -----------------------------------------------------------------------------
#  result_analysis() analysiert ein oder mehrere Ergebnisse von simulation()
#  (oder beliebige Kursreihen) nachtraeglich, im Umfang von Portfolio-
#  Backtestern wie testfol.io: Benchmark-Kennzahlen (Alpha, Beta, Capture,
#  Tracking Error, Information Ratio, M2), VaR/CVaR, Rendite- und
#  Monatstabellen, Saisonalitaet, Drawdown-Tabelle, rollierende Kennzahlen und
#  geldgewichtete Rendite (MWRR). simulation() selbst bleibt unveraendert.
# =============================================================================

#' Eine Reihe fuer die Analyse aufbereiten
#' @keywords internal
#' @noRd
.da_series <- function(x, name) {
  if (inherits(x, "SimLevResult")) {
    ix <- result_index(x); n <- length(ix$value)
    fl <- as.logical(x$filled); if (length(fl) != n) fl <- rep(FALSE, n)   # aeltere Ergebnisse ohne 'filled'
    fl[is.na(fl)] <- FALSE
    return(list(name = name, date = .to_date(ix$date, sprintf("'%s'", name)), value = ix$value, filled = fl,
                worth = ix$worth, flows = ix$flows, result = x,
                start_gross = if (length(x$invested)) x$invested[1] else NULL))   # Startbetrag brutto
  }
  if (is.data.frame(x)) {
    if (!"date" %in% names(x))
      stop(sprintf("'%s': data.frame braucht eine Spalte 'date' (vorhanden: %s)%s.", name, paste(names(x), collapse = ", "),
                   if (ncol(x) == 1L) "; nur eine Spalte: Trennzeichen pr\u00fcfen, Semikolon-Dateien mit read.csv2() einlesen" else ""))
    vc <- if ("value" %in% names(x)) "value" else {
      txt <- .num_text_cols(x, "date"); if (length(txt)) .num_text_stop(x, txt, name)
      num <- setdiff(names(x)[vapply(x, is.numeric, TRUE)], "date")
      if (!length(num)) stop(sprintf("'%s': keine numerische Wertspalte gefunden.", name))
      if (length(num) > 1L) message(sprintf("Hinweis: '%s': Wertspalte '%s' verwendet (weitere numerische Spalten: %s).",
                                            name, num[1], paste(num[-1], collapse = ", ")))
      num[1]
    }
    if (!is.numeric(x[[vc]])) {
      if (length(.num_text_cols(x[vc]))) .num_text_stop(x, vc, name)
      stop(sprintf("'%s': Wertspalte '%s' ist nicht numerisch (Klasse %s).", name, vc, class(x[[vc]])[1]))
    }
    v <- as.numeric(x[[vc]]); d <- .to_date(x$date, sprintf("'%s': Spalte 'date'", name))
    fm <- attr(x, "filled")                                   # gefuellte Tage aus series_align()
    j <- if (is.matrix(fm) && nrow(fm) == length(v)) { if (vc %in% colnames(fm)) vc else if (ncol(fm) == 1L) 1L else NULL } else NULL
    fl <- if (is.null(j)) rep(FALSE, length(v)) else as.logical(fm[, j]) %in% TRUE
    idx <- which(!is.na(d)); idx <- idx[order(d[idx])]          # Zeilen ohne Datum weg, nach Datum sortieren
    d <- d[idx]; v <- v[idx]; fl <- fl[idx]
    dup <- duplicated(d, fromLast = TRUE)
    if (any(dup)) {
      message(sprintf("Hinweis: '%s' hat %d doppelte Daten; der letzte Wert je Datum wird verwendet.", name, sum(dup)))
      d <- d[!dup]; v <- v[!dup]; fl <- fl[!dup]
    }
    has <- which(!is.na(v))
    if (!length(has)) stop(sprintf("'%s': Wertspalte '%s' hat keine Werte.", name, vc))
    r <- has[1]:has[length(has)]                              # fuehrende und nachlaufende NA abschneiden
    d <- d[r]; v <- v[r]; fl <- fl[r]
    if (anyNA(v)) { fl <- fl | is.na(v); v <- .fill_na(v, "locf") }   # innere Luecken: LOCF, als gefuellt markiert
    bad <- which(!is.finite(v) | v <= 0)
    if (length(bad)) stop(sprintf("'%s': Wertspalte '%s' muss positive Niveaus enthalten (Kurse oder Indexst\u00e4nde, keine Renditen); %d Werte <= 0, z. B. %s am %s.",
                                  name, vc, length(bad), format(v[bad[1]]), format(d[bad[1]])))
    if (length(v) < 2L) stop(sprintf("'%s': mindestens zwei Daten mit Wert n\u00f6tig.", name))
    return(list(name = name, date = d, value = v, filled = fl, worth = NULL, flows = NULL, result = NULL))
  }
  stop(sprintf("'%s' muss ein SimLevResult oder ein data.frame(date, value) sein.", name))
}

#' Risikoloser Zins je ausgewerteter Rendite
#'
#' Je Zeile aus dem Kalenderabstand zur Vorzeile, \eqn{(1 + rf)^{dt/365.25} - 1},
#' aufgezinst ueber alle Zeilen seit der vorigen ausgewerteten Zeile \code{kk}
#' (gefuellte Tage zaehlen also mit); real mit dem Deflator \code{defl}.
#' \code{cum} = kumulierter Log-Zins je Zeile (fuer Teilzeitraeume).
#' @keywords internal
#' @noRd
.da_rf <- function(date, rate, kk, defl = NULL) {
  g <- c(0, log1p(rate[-1] / 100) * as.numeric(diff(date)) / 365.25)
  if (!is.null(defl)) g <- g - c(0, diff(log(defl)))
  L <- cumsum(g)
  list(r = expm1(diff(L[kk])),                                # je ausgewerteter Rendite
       ann = expm1((L[length(L)] - L[1]) / max(as.numeric(date[length(date)] - date[1]) / 365.25, 1e-9)),    # p. a. (geometrisch)
       cum = L)
}

#' Reihe deflationieren (Kaufkraft des Startdatums)
#' @keywords internal
#' @noRd
.da_deflate <- function(s, inflation) {
  cpi <- if (is.numeric(inflation) && length(inflation) == 1L) (1 + inflation / 100)^(as.numeric(s$date - s$date[1]) / 365.25)
         else .cpi_level(inflation, data.frame(date = s$date), s$date, "inflation")
  if (anyNA(cpi)) stop(sprintf("inflation: Preisindex erst ab %s bekannt, die Reihe '%s' beginnt am %s.",
                               format(s$date[which(!is.na(cpi))[1]]), s$name, format(s$date[1])))
  f <- cpi / cpi[1]
  s$defl <- f                                                 # fuer den realen risikolosen Zins
  s$value <- s$value / f
  if (!is.null(s$worth)) s$worth <- s$worth / f
  if (!is.null(s$flows)) s$flows <- s$flows / f
  s
}

#' Wertreihe auf Perioden-Endwerte reduzieren (letzter verfuegbarer Tag)
#' @keywords internal
#' @noRd
.da_period_values <- function(date, value, unit) {
  key <- switch(unit, month = format(date, "%Y-%m"), year = format(date, "%Y"))
  last <- which(c(key[-1] != key[-length(key)], TRUE))
  list(key = key[last], date = date[last], value = value[last],
       start_value = value[1], start_date = date[1])
}

#' Interne-Zinsfuss-Rendite (MWRR, p. a.) eines Ergebnisses
#' @keywords internal
#' R4-03: gleiche Konvention und gleiches Verfahren wie die Engine (simulation()$cagr): mit
#' Einzahlungen nach dem Starttag XIRR ueber .xirr_rate() (Startbetrag brutto, Kalendertage /
#' 365,25, adaptive Klammer, auch bei Beinahe-Totalverlust und sehr hohen Renditen), sonst die
#' CAGR aus dem Depotwert am Starttag.
#' @noRd
.da_mwrr <- function(s) {
  if (is.null(s$worth)) return(NA_real_)
  n <- length(s$worth); if (n < 2L) return(NA_real_)
  t <- as.numeric(s$date - s$date[1]) / 365.25; horizon <- t[n]
  fl <- as.numeric(s$flows); if (length(fl) != n) fl <- numeric(n); fl[is.na(fl)] <- 0
  fi <- which(seq_len(n) > 1L & fl != 0)
  if (!length(fi))
    return(if (s$worth[1] > 0 && horizon > 0 && s$worth[n] >= 0) (s$worth[n] / s$worth[1])^(1 / horizon) - 1 else NA_real_)
  start <- if (length(s$start_gross)) s$start_gross else s$worth[1]   # Start brutto wie cagr der Engine
  .xirr_rate(c(0, t[fi]), c(start, fl[fi]), s$worth[n], horizon)
}

#' Drawdown-Episoden
#' @keywords internal
#' @noRd
.da_drawdowns <- function(date, value, top = 10) {
  peak <- cummax(value); dd <- value / peak - 1
  n <- length(value); neg <- dd < 0
  st <- which(neg & !c(FALSE, neg[-n]))                      # erste Zeile unter dem Hoch
  if (!length(st)) return(data.frame(start = as.Date(character(0)), trough = as.Date(character(0)),
                                     end = as.Date(character(0)), depth = numeric(0), days_to_trough = numeric(0),
                                     days_to_recover = numeric(0), days_total = numeric(0)))
  en <- which(neg & !c(neg[-1], FALSE))                      # letzte Zeile unter dem Hoch
  seg <- cumsum(neg & !c(FALSE, neg[-n]))[neg]
  rows <- which(neg)
  tr <- vapply(split(rows, seg), function(r) r[which.min(dd[r])], 1L)
  s0 <- pmax(1L, st - 1L); rec <- en + 1L; open <- rec > n
  tab <- data.frame(start = date[s0], trough = date[tr], end = replace(date[pmin(rec, n)], open, NA),
                    depth = dd[tr], days_to_trough = as.numeric(date[tr] - date[s0]),
                    days_to_recover = ifelse(open, NA_real_, as.numeric(date[pmin(rec, n)] - date[tr])),
                    days_total = ifelse(open, as.numeric(date[n] - date[s0]), as.numeric(date[pmin(rec, n)] - date[s0])))
  tab <- tab[order(tab$depth), , drop = FALSE]
  rownames(tab) <- NULL
  utils::head(tab, top)
}

#' Kennzahlen einer Reihe
#' @keywords internal
#' @noRd
.da_metrics <- function(s, rate, ppy, var_levels) {
  kk <- c(1L, which(!s$filled[-1]) + 1L)                      # Zeilen mit echten Werten (erste als Basis)
  vk <- s$value[kk]
  r <- vk[-1] / vk[-length(vk)] - 1                           # Renditen von echtem zu echtem Wert
  rfl <- .da_rf(s$date, rate, kk, s$defl); rf <- rfl$r
  yrs <- as.numeric(s$date[length(s$date)] - s$date[1]) / 365.25
  cagr <- (s$value[length(s$value)] / s$value[1])^(1 / yrs) - 1
  vol <- stats::sd(r) * sqrt(ppy)
  ex <- r - rf
  down <- ex[ex < 0]
  peak <- cummax(s$value); dd <- 1 - s$value / peak
  mdd <- max(dd)
  ulcer <- sqrt(mean(dd^2))
  m <- .da_period_values(s$date, s$value, "month")
  mr <- c(m$value[1] / m$start_value, m$value[-1] / m$value[-length(m$value)]) - 1
  y <- .da_period_values(s$date, s$value, "year")
  yr <- c(y$value[1] / y$start_value, y$value[-1] / y$value[-length(y$value)]) - 1
  var_d <- vapply(var_levels, function(a) -stats::quantile(r, a, names = FALSE), 0)
  cvar_d <- vapply(var_levels, function(a) { q <- stats::quantile(r, a, names = FALSE); -mean(r[r <= q]) }, 0)
  var_m <- vapply(var_levels, function(a) -stats::quantile(mr, a, names = FALSE), 0)
  cvar_m <- vapply(var_levels, function(a) { q <- stats::quantile(mr, a, names = FALSE); -mean(mr[mr <= q]) }, 0)
  ddt <- .da_drawdowns(s$date, s$value, top = 1e6)
  rf_ann <- rfl$ann
  out <- c(
    start_value = s$value[1], end_value = s$value[length(s$value)],
    years = yrs, total_return = s$value[length(s$value)] / s$value[1] - 1,
    cagr = cagr, mwrr = .da_mwrr(s), volatility = vol,
    sharpe = if (isTRUE(stats::sd(ex) > 0)) mean(ex) * ppy / (stats::sd(ex) * sqrt(ppy)) else NA_real_,
    sortino = if (length(down)) mean(ex) * ppy / (sqrt(mean(pmin(ex, 0)^2)) * sqrt(ppy)) else NA_real_,
    calmar = if (mdd > 0) cagr / mdd else NA_real_,
    max_drawdown = mdd, avg_drawdown = if (nrow(ddt)) mean(-ddt$depth) else 0,
    ulcer_index = ulcer, upi = if (ulcer > 0) (cagr - rf_ann) / ulcer else NA_real_,
    longest_drawdown_days = if (nrow(ddt)) max(ddt$days_total) else 0,
    recovery_factor = if (mdd > 0) (s$value[length(s$value)] / s$value[1] - 1) / mdd else NA_real_,
    required_to_recover = if (dd[length(dd)] > 0) 1 / (1 - dd[length(dd)]) - 1 else 0,
    skewness = calculate_skewness(r), excess_kurtosis = calculate_kurtosis(r),
    best_day = max(r), worst_day = min(r), best_month = max(mr), worst_month = min(mr),
    best_year = max(yr), worst_year = min(yr), positive_months = mean(mr > 0),
    avg_gain = mean(r[r > 0]), avg_loss = mean(r[r < 0]),
    gain_loss_ratio = if (any(r < 0)) mean(r[r > 0]) / abs(mean(r[r < 0])) else NA_real_,
    stats::setNames(var_d, sprintf("var_daily_%g", 100 * var_levels)),
    stats::setNames(cvar_d, sprintf("cvar_daily_%g", 100 * var_levels)),
    stats::setNames(var_m, sprintf("var_monthly_%g", 100 * var_levels)),
    stats::setNames(cvar_m, sprintf("cvar_monthly_%g", 100 * var_levels)))
  tr <- if (!is.null(s$result)) s$result$tax_report else NULL
  c(out, taxes = if (!is.null(s$result)) tr$total_taxes_paid %||% 0 else NA_real_,
    trades_per_year = if (!is.null(s$result)) sum(s$result$buys) + sum(s$result$sells) else NA_real_)
}

#' Benchmark-Kennzahlen (auf gemeinsamen Tagen)
#' @keywords internal
#' @noRd
.da_benchmark <- function(s, b, rate, ppy, cagr_s, cagr_b) {
  common <- as.Date(sort(intersect(as.numeric(s$date), as.numeric(b$date))), origin = "1970-01-01")
  is <- match(as.numeric(common), as.numeric(s$date)); ib <- match(as.numeric(common), as.numeric(b$date))
  vs <- s$value[is]; vb <- b$value[ib]
  keep <- !(s$filled[is][-1] | b$filled[ib][-1])
  if (sum(keep) < 3L)
    stop(sprintf("Benchmark '%s' und Reihe '%s' haben zu wenige gemeinsame Daten (%d gemeinsame Renditen, mindestens 3).",
                 b$name, s$name, sum(keep)), call. = FALSE)
  kk <- c(1L, which(keep) + 1L)
  rs <- vs[kk][-1] / vs[kk][-length(kk)] - 1; rb <- vb[kk][-1] / vb[kk][-length(kk)] - 1
  rfl <- .da_rf(common, rate[is], kk, if (!is.null(s$defl)) s$defl[is] else NULL); rf <- rfl$r
  es <- rs - rf; eb <- rb - rf
  beta <- stats::cov(es, eb) / stats::var(eb)
  alpha <- (mean(es) - beta * mean(eb)) * ppy
  te <- stats::sd(rs - rb) * sqrt(ppy)
  ms <- .da_period_values(common, vs, "month"); mb <- .da_period_values(common, vb, "month")
  mrs <- c(ms$value[1] / ms$start_value, ms$value[-1] / ms$value[-length(ms$value)]) - 1
  mrb <- c(mb$value[1] / mb$start_value, mb$value[-1] / mb$value[-length(mb$value)]) - 1
  gm <- function(x) prod(1 + x)^(1 / length(x)) - 1
  up <- mrb > 0; dn <- mrb < 0
  upc <- if (any(up)) gm(mrs[up]) / gm(mrb[up]) else NA_real_
  dnc <- if (any(dn)) gm(mrs[dn]) / gm(mrb[dn]) else NA_real_
  sharpe_s <- mean(es) * ppy / (stats::sd(es) * sqrt(ppy))
  rf_ann <- rfl$ann
  c(alpha = alpha, beta = beta, correlation = stats::cor(rs, rb), r_squared = stats::cor(rs, rb)^2,
    correlation_up = if (sum(rb > 0) > 2) stats::cor(rs[rb > 0], rb[rb > 0]) else NA_real_,
    correlation_down = if (sum(rb < 0) > 2) stats::cor(rs[rb < 0], rb[rb < 0]) else NA_real_,
    up_capture = upc, down_capture = dnc, capture_spread = upc - dnc,
    active_return = cagr_s - cagr_b, tracking_error = te,
    information_ratio = if (te > 0) mean(rs - rb) * ppy / te else NA_real_,
    m2 = sharpe_s * stats::sd(rb) * sqrt(ppy) + rf_ann,
    treynor = if (beta != 0) (mean(es) * ppy) / beta else NA_real_)
}

#' Monatsrenditen-Tabelle (Jahr x Monat, plus Jahr)
#' @keywords internal
#' @noRd
.da_monthly_table <- function(s) {
  m <- .da_period_values(s$date, s$value, "month")
  mr <- c(m$value[1] / m$start_value, m$value[-1] / m$value[-length(m$value)]) - 1
  yy <- as.integer(substr(m$key, 1, 4)); mm <- as.integer(substr(m$key, 6, 7))
  years <- sort(unique(yy))
  M <- matrix(NA_real_, length(years), 12, dimnames = list(years, month.abb))
  M[cbind(match(yy, years), mm)] <- mr
  y <- .da_period_values(s$date, s$value, "year")
  yr <- c(y$value[1] / y$start_value, y$value[-1] / y$value[-length(y$value)]) - 1
  cbind(M, Year = yr[match(years, as.integer(y$key))])
}

#' Rollierende Kennzahlen auf Monatsbasis; \code{rf_cum} = kumulierter Log-Zins je
#' Zeile von \code{s} (.da_rf()$cum), die Sharpe Ratio zieht den Zins des Fensters ab
#' @keywords internal
#' @noRd
.da_rolling <- function(s, b, window_m, rf_cum) {
  m <- .da_period_values(s$date, s$value, "month")
  v <- c(m$start_value, m$value); d <- c(m$start_date, m$date)
  Lk <- rf_cum[match(as.numeric(d), as.numeric(s$date))]
  n <- length(v)
  if (n <= window_m) return(NULL)
  idx <- (window_m + 1):n
  vb <- if (!is.null(b)) {
    kb <- findInterval(as.numeric(d), as.numeric(b$date))     # letzter Benchmarkwert am oder vor dem Monatsende
    vv <- ifelse(kb > 0, b$value[pmax(kb, 1L)], NA_real_)     # vor dem Benchmarkstart NA (Index 0 nicht verwerfen)
    vv[!is.finite(vv) | vv <= 0] <- NA; vv
  } else NULL
  out <- t(vapply(idx, function(k) {
    seg <- v[(k - window_m):k]; r <- seg[-1] / seg[-length(seg)] - 1
    yrs <- as.numeric(d[k] - d[k - window_m]) / 365.25
    cg <- (seg[length(seg)] / seg[1])^(1 / yrs) - 1
    vo <- stats::sd(r) * sqrt(12)
    mdd <- max(1 - seg / cummax(seg))
    bt <- ex <- NA_real_
    if (!is.null(vb) && !anyNA(vb[(k - window_m):k])) {
      sb <- vb[(k - window_m):k]; rb <- sb[-1] / sb[-length(sb)] - 1
      bt <- stats::cov(r, rb) / stats::var(rb)
      ex <- cg - ((sb[length(sb)] / sb[1])^(1 / yrs) - 1)
    }
    rf_w <- expm1((Lk[k] - Lk[k - window_m]) / yrs)           # Zins im Fenster p. a. (geometrisch)
    c(cagr = cg, volatility = vo, sharpe = if (isTRUE(vo > 0)) (cg - rf_w) / vo else NA_real_,
      max_drawdown = mdd, beta = bt, excess_cagr = ex)
  }, numeric(6)))
  data.frame(date = d[idx], out)
}


#' Vertiefte Analyse von Simulationsergebnissen
#'
#' Wertet ein oder mehrere gespeicherte Ergebnisse von [simulation()] (oder
#' Kursreihen) aus, im Umfang gaengiger Portfolio-Backtester wie testfol.io.
#' Bei \code{SimLevResult} ist Grundlage der zeitgewichtete Wertindex
#' ([result_index()]); Sparplaene und Entnahmen verzerren die Renditen daher
#' nicht. Tage, die [simulation()] per LOCF aufgefuellt hat, werden aus den
#' Tagesrenditen fuer Volatilitaet, Sharpe, VaR usw. ausgeschlossen.
#'
#' Akzeptierte Eingaben (je Reihe):
#' \itemize{
#'   \item ein \code{SimLevResult} aus [simulation()], [tactical_simulation()]
#'     usw.; nur hier gibt es MWRR, Steuern und Transaktionen (aeltere
#'     Ergebnisse ohne Element \code{filled} gelten als ungefuellt);
#'   \item ein \code{data.frame} mit Spalte \code{date} (Date, POSIXct mit
#'     dem Kalendertag in seiner Zeitzone oder \code{"JJJJ-MM-TT"}) und einer
#'     Wertspalte (positive Niveaus, keine Renditen): \code{value}, sonst die
#'     erste numerische Spalte ausser \code{date} (bei mehreren mit Hinweis
#'     auf die gewaehlte); weitere Spalten werden ignoriert. Zahlen als Text
#'     oder Faktor (etwa mit Dezimalkomma eingelesen) sind ein Fehler. Die
#'     Zeilen werden nach Datum sortiert, bei doppeltem Datum gilt der letzte
#'     Wert (mit Hinweis). Fuehrende und nachlaufende NA werden abgeschnitten,
#'     innere NA per LOCF gefuellt und wie gefuellte Tage behandelt. Traegt
#'     der data.frame das Attribut \code{filled} aus [series_align()] (Spalte
#'     der Wertspalte bzw. einzige Spalte), werden diese Tage aus den
#'     Tagesrenditen ausgeschlossen. Handelstagsdaten ohne Wochenenden sind
#'     zulaessig; z. B. eine eigene Kursreihe, ein Ergebnis von
#'     [series_splice()] oder [result_index()];
#'   \item eine Liste solcher Objekte (auch gemischt); Namen werden zu
#'     Spaltennamen; ist die Liste nicht vollstaendig benannt, heissen alle
#'     Reihen \code{S1}, \code{S2}, ... Ein einzelnes Objekt heisst
#'     \code{Strategie}.
#' }
#' Numerische Vektoren werden nicht akzeptiert (vorher als
#' \code{data.frame(date, value)} aufbereiten).
#'
#' Die Annualisierung (\code{ppy}) wird je Reihe aus den Daten ermittelt:
#' Anzahl nicht aufgefuellter Tagesrenditen je Jahr (rund 365 bei
#' Kalendertagen, rund 252 bei Handelstagen). Tagesrenditen laufen von
#' einem echten (nicht gefuellten) Wert zum naechsten. Monats- und Jahreswerte sind
#' die letzten vorhandenen Werte je Kalendermonat bzw. -jahr; das erste
#' Jahr und der erste Monat koennen daher unvollstaendig sein.
#'
#' Kennzahlen je Reihe: Gesamtrendite, CAGR, geldgewichtete Rendite (MWRR,
#' interner Zinsfuss der Ein- und Auszahlungen), Volatilitaet, Sharpe,
#' Sortino, Calmar, maximaler und mittlerer Drawdown, Ulcer Index, UPI,
#' laengste Drawdown-Dauer, Recovery Factor, noetige Rendite zur Erholung,
#' Schiefe, Kurtosis, beste und schlechteste Tage, Monate und Jahre, Anteil
#' positiver Monate, Gewinn/Verlust-Verhaeltnis, historischer VaR und CVaR
#' (taeglich und monatlich), bei SimLev-Ergebnissen auch Steuern und
#' Transaktionen.
#'
#' Gegen einen Benchmark: Alpha (annualisiert, CAPM auf Ueberschussrenditen),
#' Beta, Korrelation gesamt sowie in Auf- und Abwaertsphasen, R²,
#' Up-/Down-Capture (Monatsbasis), Capture Spread, aktive Rendite, Tracking
#' Error, Information Ratio, M² (Modigliani) und Treynor.
#'
#' @param x Ein \code{SimLevResult}, ein \code{data.frame(date, value)} oder
#'   eine (benannte) Liste davon, z. B. mehrere gespeicherte Laeufe (siehe
#'   Details).
#' @param benchmark Benchmark fuer die Benchmark-Kennzahlen: \code{NULL}
#'   (Standard; keine), ein Name aus \code{x} (Zeichenkette) oder ein
#'   eigenes \code{SimLevResult} bzw. \code{data.frame(date, value)}; dieses
#'   wird unter dem Namen \code{"Benchmark"} als weitere Reihe aufgenommen.
#'   Verglichen wird auf den gemeinsamen Daten (mindestens 3 gemeinsame
#'   Renditen). Enthaelt \code{x} schon eine Reihe \code{"Benchmark"}, ist
#'   ein eigenes Objekt hier ein Fehler.
#' @param risk_free Risikoloser Zins in Prozent p. a. (1 = 1 %): Skalar
#'   (Standard 0), \code{data.frame(date, rate)} oder benannter Vektor mit
#'   Datumsnamen (jeweils Stufenfunktion: Wert gilt ab seinem Datum).
#'   Je ausgewerteter Rendite gilt der Zins ueber den Kalenderabstand zur
#'   vorigen ausgewerteten Zeile, \eqn{(1 + Zins/100)^{Tage/365.25} - 1}
#'   (Handels- und Kalendertagsdaten ergeben so dieselbe Ueberschussrendite;
#'   im frueheren Stand (Commit 54b5b4f) je Zeile Zins / 100 / 365.25, bei Handelstagen also
#'   nur rund 69 % des Zinses). Mit \code{inflation} wird auch der Zins
#'   deflationiert (real). \code{upi}, rollierende Sharpe und M² verwenden
#'   den daraus aufgezinsten Zins p. a.
#' @param rolling_years Fensterlaenge der rollierenden Kennzahlen in Jahren
#'   (auf ganze Monate gerundet, mindestens 2 Monate; Standard 3).
#' @param var_levels Wahrscheinlichkeiten fuer VaR und CVaR als Anteile
#'   (Standard \code{c(0.01, 0.05, 0.10)}); historisch aus Tages- und
#'   Monatsrenditen.
#' @param top_drawdowns Anzahl Eintraege der Drawdown-Tabelle je Reihe
#'   (Standard 10, nach Tiefe sortiert).
#' @param inflation Optional: Inflation in Prozent p. a. (Skalar, 2 = 2 %)
#'   oder ein Preisindex-Niveau als \code{data.frame(date, value)} bzw.
#'   benannter Vektor mit Datumsnamen (z. B. mit [series_align_macro()]
#'   vorbereitet). Dann werden alle Kennzahlen real (in Kaufkraft des
#'   Startdatums) berechnet, auch die MWRR und der risikolose Zins. Ein
#'   Preisindex muss am Start jeder Reihe bekannt sein. Standard
#'   \code{NULL} = nominal.
#' @return Objekt der Klasse \code{SimLevAnalysis}, eine Liste mit
#'   \describe{
#'     \item{metrics}{Matrix Kennzahl x Reihe. Renditen, Volatilitaet,
#'       Drawdowns, VaR/CVaR (\code{var_daily_5}, \code{cvar_monthly_5} usw.)
#'       als Anteile (0.07 = 7 %), Drawdowns positiv; \code{years} in
#'       Jahren, \code{longest_drawdown_days} in Kalendertagen;
#'       \code{taxes} in Waehrungseinheiten und \code{trades_per_year} nur bei
#'       \code{SimLevResult}, sonst NA (ebenso \code{mwrr}).}
#'     \item{benchmark_metrics}{Matrix Kennzahl x Reihe (ohne Benchmark):
#'       \code{alpha}, \code{beta}, \code{correlation}, \code{r_squared},
#'       \code{correlation_up}, \code{correlation_down}, \code{up_capture},
#'       \code{down_capture}, \code{capture_spread}, \code{active_return},
#'       \code{tracking_error}, \code{information_ratio}, \code{m2},
#'       \code{treynor}; \code{NULL} ohne Benchmark.}
#'     \item{benchmark}{Name der Benchmark-Reihe oder \code{NULL}.}
#'     \item{annual}{Matrix Jahr x Reihe der Jahresrenditen (Anteile); Zeilen
#'       = alle Jahre aller Reihen, NA, wo eine Reihe kein Jahr hat.}
#'     \item{monthly}{Liste je Reihe: Matrix Jahr x Monat (\code{Jan} bis
#'       \code{Dec}) plus Spalte \code{Year} (Anteile).}
#'     \item{seasonality}{Matrix Monat x Reihe: mittlere Monatsrendite.}
#'     \item{drawdowns}{Liste je Reihe: data.frame mit \code{start},
#'       \code{trough}, \code{end} (NA, solange nicht erholt), \code{depth}
#'       (negativer Anteil), \code{days_to_trough}, \code{days_to_recover},
#'       \code{days_total} (Kalendertage).}
#'     \item{rolling}{Liste je Reihe: data.frame (Monatsende) mit
#'       \code{cagr}, \code{volatility}, \code{sharpe}, \code{max_drawdown},
#'       \code{beta}, \code{excess_cagr} ueber \code{rolling_years}
#'       (\code{sharpe} = (CAGR - risikoloser Zins im Fenster p. a.) /
#'       Volatilitaet); \code{NULL}, wenn die Reihe zu kurz ist.}
#'     \item{rolling_years, risk_free, var_levels}{die Eingaben.}
#'     \item{correlation}{Liste \code{daily} und \code{monthly}:
#'       Korrelationsmatrizen der Renditen auf gemeinsamen Daten (bei
#'       mindestens zwei Reihen und mehr als 30 gemeinsamen Tagen, sonst
#'       \code{NULL}).}
#'     \item{series}{Liste je Reihe: \code{data.frame(date, value)} der
#'       ausgewerteten (ggf. realen) Wertreihe.}
#'     \item{real}{\code{TRUE}, wenn \code{inflation} gesetzt war.}
#'   }
#'   Ausgabe mit \code{print()}, \code{summary()} und \code{plot()}, siehe
#'   [SimLevAnalysis-methods].
#' @examples
#' set.seed(1)
#' d <- data.frame(date = seq.Date(as.Date("2010-01-01"), by = "day", length.out = 3000))
#' d$A <- 100 * cumprod(1 + rnorm(3000, 3e-4, 0.010))
#' d$B <- 100 * cumprod(1 + rnorm(3000, 2e-4, 0.006))
#' a <- simulation(d, create_strategy(A = asset_config("etf", "bnh")))
#' b <- simulation(d, create_strategy(A = asset_config("etf", "bnh", 0.6), B = asset_config("etf", "bnh", 0.4)),
#'                 balance_mode = TRUE, balance_span = 1, balance_unit = "year")
#' da <- result_analysis(list(Aktien = a, Mischung = b), benchmark = "Aktien", risk_free = 1)
#' da
#' # Eigene Kursreihe als Benchmark (data.frame mit date und Wertspalte), real mit 2 % Inflation
#' da2 <- result_analysis(a, benchmark = d[, c("date", "B")], inflation = 2)
#' da2$benchmark_metrics[c("beta", "tracking_error"), ]
#' head(da2$drawdowns$Strategie, 3)
#' plot(da, type = "annual")
#' @seealso [result_index()], [simulation()], [tactical_simulation()],
#'   [series_align()] fuer eigene Kursreihen
#' @export
result_analysis <- function(x, benchmark = NULL, risk_free = 0, rolling_years = 3,
                          var_levels = c(0.01, 0.05, 0.10), top_drawdowns = 10, inflation = NULL) {
  if (inherits(x, "SimLevResult") || is.data.frame(x)) x <- list(Strategie = x)
  if (!is.list(x) || !length(x)) stop("x muss ein SimLevResult, ein data.frame oder eine Liste davon sein.")
  if (is.null(names(x)) || any(names(x) == "")) names(x) <- paste0("S", seq_along(x))
  if (!is.numeric(rolling_years) || length(rolling_years) != 1L || is.na(rolling_years) || round(12 * rolling_years) < 2)
    stop(sprintf("rolling_years muss mindestens 2/12 (zwei Monate) betragen (ist: %s).", format(rolling_years)))
  if (!is.numeric(var_levels) || !length(var_levels) || anyNA(var_levels) || any(var_levels <= 0 | var_levels >= 1))
    stop("var_levels: Wahrscheinlichkeiten als Anteile zwischen 0 und 1, z. B. c(0.01, 0.05).")
  ser <- mapply(.da_series, x, names(x), SIMPLIFY = FALSE)
  bname <- NULL; bser <- NULL
  if (!is.null(benchmark)) {
    if (is.character(benchmark)) {
      if (length(benchmark) != 1L || !benchmark %in% names(ser))
        stop(sprintf("benchmark muss ein Name aus x sein (%s).", paste(names(ser), collapse = ", ")))
      bname <- benchmark; bser <- ser[[benchmark]]
    } else {
      bname <- "Benchmark"
      if (bname %in% names(ser)) stop("x enth\u00e4lt bereits eine Reihe 'Benchmark'; benchmark = \"Benchmark\" w\u00e4hlen oder die Reihe in x umbenennen.")
      bser <- .da_series(benchmark, bname); ser[[bname]] <- bser
    }
  }
  for (s in ser) if (sum(!s$filled[-1]) < 2L)
    stop(sprintf("'%s': zu kurz (%d Renditen ohne gef\u00fcllte Tage, mindestens 2).", s$name, sum(!s$filled[-1])))
  if (!is.null(inflation)) {
    ser <- lapply(ser, .da_deflate, inflation = inflation)
    if (!is.null(bname)) bser <- ser[[bname]]
  }
  rf_of <- function(s) .resolve_series(risk_free, data.frame(date = s$date), "risk_free")   # Prozent p. a. je Zeile
  ppy_of <- function(s) { k <- sum(!s$filled[-1]); k / (as.numeric(s$date[length(s$date)] - s$date[1]) / 365.25) }
  met <- vapply(ser, function(s) .da_metrics(s, rf_of(s), ppy_of(s), var_levels),
                .da_metrics(ser[[1]], rf_of(ser[[1]]), ppy_of(ser[[1]]), var_levels))
  bm <- NULL
  if (!is.null(bser)) {
    others <- setdiff(names(ser), bname)
    bm <- vapply(others, function(nm) .da_benchmark(ser[[nm]], bser, rf_of(ser[[nm]]), ppy_of(ser[[nm]]),
                                                    met["cagr", nm], met["cagr", bname]), numeric(14))
    if (!is.matrix(bm)) bm <- matrix(bm, ncol = length(others), dimnames = list(NULL, others))
    rownames(bm) <- c("alpha", "beta", "correlation", "r_squared", "correlation_up", "correlation_down",
                      "up_capture", "down_capture", "capture_spread", "active_return", "tracking_error",
                      "information_ratio", "m2", "treynor")
  }
  monthly <- lapply(ser, .da_monthly_table)
  yrs_all <- sort(unique(unlist(lapply(monthly, rownames))))   # Jahre aller Reihen, je Reihe per Jahr zugeordnet
  annual <- vapply(monthly, function(M) unname(M[, "Year"])[match(yrs_all, rownames(M))], numeric(length(yrs_all)))
  if (!is.matrix(annual)) annual <- matrix(annual, ncol = length(ser))
  dimnames(annual) <- list(yrs_all, names(ser))
  seasonality <- vapply(monthly, function(M) colMeans(M[, 1:12, drop = FALSE], na.rm = TRUE), numeric(12))
  dds <- lapply(ser, function(s) .da_drawdowns(s$date, s$value, top_drawdowns))
  rolling <- lapply(ser, function(s) .da_rolling(s, if (!is.null(bser) && !identical(s, bser)) bser else NULL,
                                                 round(12 * rolling_years), .da_rf(s$date, rf_of(s), 1L, s$defl)$cum))
  common <- Reduce(intersect, lapply(ser, function(s) as.numeric(s$date)))
  cor_d <- cor_m <- NULL
  if (length(ser) > 1 && length(common) > 30) {
    R <- vapply(ser, function(s) { v <- s$value[match(common, as.numeric(s$date))]; v[-1] / v[-length(v)] - 1 },
                numeric(length(common) - 1))
    cor_d <- stats::cor(R)
    dts <- as.Date(common, origin = "1970-01-01")
    Rm <- vapply(ser, function(s) { m <- .da_period_values(dts, s$value[match(common, as.numeric(s$date))], "month")
                                    m$value[-1] / m$value[-length(m$value)] - 1 },
                 numeric(length(unique(format(dts, "%Y-%m"))) - 1))
    cor_m <- stats::cor(Rm)
  }
  structure(list(metrics = met, benchmark_metrics = bm, benchmark = bname, annual = annual,
                 monthly = monthly, seasonality = seasonality, drawdowns = dds, rolling = rolling,
                 rolling_years = rolling_years, correlation = list(daily = cor_d, monthly = cor_m),
                 series = lapply(ser, function(s) data.frame(date = s$date, value = s$value)),
                 risk_free = risk_free, var_levels = var_levels, real = !is.null(inflation)),
            class = "SimLevAnalysis")
}

#' Methoden fuer SimLevAnalysis
#'
#' Ausgabe eines Ergebnisses von [result_analysis()]. \code{print()} zeigt die
#' wichtigsten Kennzahlen je Reihe (Renditen in Prozent) und, falls
#' vorhanden, die Benchmark-Kennzahlen. \code{summary()} druckt zusaetzlich
#' die Jahresrenditen in Prozent und je Reihe die fuenf groessten
#' Drawdowns. \code{plot()} zeichnet Wertentwicklung (logarithmisch, Start =
#' 1), Drawdowns, rollierende Kennzahlen, Jahresrenditen oder eine
#' Monats-Heatmap.
#'
#' @param x,object Ein \code{SimLevAnalysis}-Objekt.
#' @param type Grafik: \code{"overview"} (Standard; 2x2 aus Wachstum,
#'   Drawdown, rollierend und Jahresrenditen), \code{"growth"},
#'   \code{"drawdown"}, \code{"rolling"}, \code{"annual"} oder
#'   \code{"monthly"} (Heatmap der Monatsrenditen von \code{series}).
#' @param series Reihe fuer die Monats-Heatmap: Nummer oder Name (Standard
#'   1 = erste Reihe).
#' @param metric Kennzahl der rollierenden Grafik: \code{"cagr"} (Standard),
#'   \code{"volatility"}, \code{"sharpe"}, \code{"max_drawdown"},
#'   \code{"beta"} oder \code{"excess_cagr"} (\code{beta} und
#'   \code{excess_cagr} nur mit Benchmark).
#' @param ... Nicht verwendet.
#' @return \code{print()} und \code{plot()}: das Objekt (unsichtbar);
#'   \code{summary()}: unsichtbar eine Liste mit \code{metrics},
#'   \code{benchmark}, \code{annual} und \code{drawdowns}.
#' @name SimLevAnalysis-methods
#' @keywords internal
NULL

.da_fmt <- function(k, v) {
  pct <- c("total_return", "cagr", "mwrr", "volatility", "max_drawdown", "avg_drawdown", "ulcer_index",
           "required_to_recover", "best_day", "worst_day", "best_month", "worst_month", "best_year", "worst_year",
           "positive_months", "avg_gain", "avg_loss", "alpha", "active_return", "tracking_error", "m2", "treynor")
  if (is.na(v)) return("\u2013")
  if (k %in% pct || grepl("^c?var_", k)) return(sprintf("%.2f %%", 100 * v))
  if (k %in% c("start_value", "end_value", "taxes")) return(formatC(v, format = "f", digits = 0, big.mark = " "))   # R9-07: Tabelle, Leerzeichen als Tausendertrenner
  if (k %in% c("longest_drawdown_days")) return(sprintf("%.0f T.", v))
  sprintf("%.3f", v)
}

.da_labels <- c(
  total_return = "Gesamtrendite", cagr = "CAGR (TWR)", mwrr = "MWRR (geldgewichtet)", volatility = "Volatilit\u00e4t p. a.",
  sharpe = "Sharpe", sortino = "Sortino", calmar = "Calmar", max_drawdown = "Max. Drawdown",
  avg_drawdown = "Mittlerer Drawdown", ulcer_index = "Ulcer Index", upi = "Ulcer Performance Index",
  longest_drawdown_days = "L\u00e4ngster Drawdown", recovery_factor = "Recovery Factor",
  best_year = "Bestes Jahr", worst_year = "Schlechtestes Jahr", worst_month = "Schlechtester Monat",
  positive_months = "Positive Monate", var_daily_5 = "VaR 5 % (Tag)", cvar_daily_5 = "CVaR 5 % (Tag)",
  var_monthly_5 = "VaR 5 % (Monat)", cvar_monthly_5 = "CVaR 5 % (Monat)", taxes = "Steuern",
  alpha = "Alpha p. a.", beta = "Beta", correlation = "Korrelation", r_squared = "R\u00B2",
  up_capture = "Up-Capture", down_capture = "Down-Capture", capture_spread = "Capture Spread",
  active_return = "Aktive Rendite p. a.", tracking_error = "Tracking Error", information_ratio = "Information Ratio",
  m2 = "M\u00B2 (Modigliani)", treynor = "Treynor")

#' @rdname SimLevAnalysis-methods
#' @export
print.SimLevAnalysis <- function(x, ...) {
  M <- x$metrics
  show <- intersect(c("total_return", "cagr", "mwrr", "volatility", "sharpe", "sortino", "calmar", "max_drawdown",
                      "avg_drawdown", "ulcer_index", "upi", "longest_drawdown_days", "best_year", "worst_year",
                      "worst_month", "positive_months", "var_daily_5", "cvar_daily_5", "var_monthly_5",
                      "cvar_monthly_5", "taxes"), rownames(M))
  w <- max(12, max(nchar(colnames(M))) + 1)
  cat("\n\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\n")
  cat("                    SimLev Detailanalyse                       \n")
  cat("\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\n")
  s1 <- x$series[[1]]
  cat(sprintf("  Zeitraum: %s bis %s (%.1f Jahre)%s\n\n", format(min(s1$date)), format(max(s1$date)), M["years", 1],
              if (isTRUE(x$real)) ", real (Kaufkraft zu Beginn)" else ""))
  cat(sprintf("  %-26s%s\n", "", paste(formatC(colnames(M), width = w), collapse = "")))
  for (k in show) cat(sprintf("  %s%s\n", format(.da_labels[[k]], width = 26),
                              paste(formatC(vapply(M[k, ], function(v) .da_fmt(k, v), ""), width = w), collapse = "")))
  if (!is.null(x$benchmark_metrics)) {
    B <- x$benchmark_metrics
    cat(sprintf("\n  Gegen Benchmark '%s'\n", x$benchmark))
    cat(sprintf("  %-26s%s\n", "", paste(formatC(colnames(B), width = w), collapse = "")))
    for (k in c("alpha", "beta", "correlation", "r_squared", "up_capture", "down_capture", "capture_spread",
                "active_return", "tracking_error", "information_ratio", "m2"))
      cat(sprintf("  %s%s\n", format(.da_labels[[k]], width = 26),
                  paste(formatC(vapply(B[k, ], function(v) .da_fmt(k, v), ""), width = w), collapse = "")))
  }
  cat("\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\n")
  invisible(x)
}

#' @rdname SimLevAnalysis-methods
#' @export
summary.SimLevAnalysis <- function(object, ...) {
  print(object)
  cat("\n  Jahresrenditen (%)\n")
  print(round(100 * object$annual, 2))
  for (nm in names(object$drawdowns)) {
    cat(sprintf("\n  Gr\u00f6\u00dfte Drawdowns: %s\n", nm))
    d <- object$drawdowns[[nm]]; d$depth <- sprintf("%.2f %%", 100 * d$depth)
    print(utils::head(d, 5), row.names = FALSE)
  }
  invisible(list(metrics = object$metrics, benchmark = object$benchmark_metrics, annual = object$annual,
                 drawdowns = object$drawdowns))
}

#' @rdname SimLevAnalysis-methods
#' @export
plot.SimLevAnalysis <- function(x, type = c("overview", "growth", "drawdown", "rolling", "annual", "monthly"),
                                series = 1, metric = "cagr", ...) {
  type <- match.arg(type)
  if (type == "monthly" && (length(series) != 1L || (is.character(series) && !series %in% names(x$monthly)) ||
                            (is.numeric(series) && !(series >= 1 && series <= length(x$monthly)))))
    stop(sprintf("series: Name oder Nummer einer Reihe (%s).", paste(names(x$monthly), collapse = ", ")))
  if (type %in% c("overview", "rolling") && !metric %in% c("cagr", "volatility", "sharpe", "max_drawdown", "beta", "excess_cagr"))
    stop("metric: 'cagr', 'volatility', 'sharpe', 'max_drawdown', 'beta' oder 'excess_cagr'.")
  old <- graphics::par(no.readonly = TRUE); on.exit(graphics::par(old))
  cols <- c("#2C6E9B", "#B5562B", "#3E8E5A", "#8A5BA8", "#C49A2C", "#4A4A4A")[seq_along(x$series)]
  nms <- names(x$series)
  base_par <- function() graphics::par(mar = c(3.6, 4.4, 2.4, 1), mgp = c(2.5, 0.6, 0), las = 1, cex.axis = 0.85)
  p_growth <- function() {
    rng <- range(unlist(lapply(x$series, function(s) s$value / s$value[1])), finite = TRUE)
    plot(range(do.call(c, lapply(x$series, `[[`, "date"))), rng, type = "n", log = "y",
         xlab = "", ylab = "Wachstum (log)", main = "Wertentwicklung (TWR, Start = 1)")
    for (i in seq_along(x$series)) graphics::lines(x$series[[i]]$date, x$series[[i]]$value / x$series[[i]]$value[1], col = cols[i], lwd = 1.3)
    graphics::legend("topleft", legend = nms, col = cols, lwd = 1.5, bty = "n", cex = 0.85)
  }
  p_dd <- function() {
    dd <- lapply(x$series, function(s) 100 * (s$value / cummax(s$value) - 1))
    plot(range(do.call(c, lapply(x$series, `[[`, "date"))), c(min(unlist(dd)), 0), type = "n",
         xlab = "", ylab = "Drawdown (%)", main = "Drawdowns")
    for (i in seq_along(dd)) graphics::lines(x$series[[i]]$date, dd[[i]], col = cols[i], lwd = 1)
  }
  p_roll <- function() {
    rl <- Filter(Negate(is.null), x$rolling)
    if (!length(rl)) { plot.new(); graphics::title("Rollierend: Zeitraum zu kurz"); return(invisible()) }
    yl <- range(unlist(lapply(rl, function(r) r[[metric]])), na.rm = TRUE) * (if (metric %in% c("beta", "sharpe")) 1 else 100)
    plot(range(do.call(c, lapply(rl, `[[`, "date"))), yl, type = "n", xlab = "",
         ylab = if (metric %in% c("beta", "sharpe")) metric else paste(metric, "(%)"),
         main = sprintf("Rollierend %g J.: %s", x$rolling_years, metric))
    for (nm in names(rl)) graphics::lines(rl[[nm]]$date, rl[[nm]][[metric]] * (if (metric %in% c("beta", "sharpe")) 1 else 100),
                                           col = cols[match(nm, nms)], lwd = 1.2)
    graphics::abline(h = 0, col = "grey60", lty = 3)
  }
  p_annual <- function() {
    A <- t(100 * x$annual); A[is.na(A)] <- 0
    graphics::barplot(A, beside = TRUE, col = cols, border = NA, ylab = "Rendite (%)", main = "Jahresrenditen",
                      names.arg = colnames(A), cex.names = 0.7)
    graphics::abline(h = 0, col = "grey40")
  }
  p_monthly <- function() {
    M <- 100 * x$monthly[[series]][, 1:12, drop = FALSE]
    lim <- max(abs(M), na.rm = TRUE)
    pal <- grDevices::colorRampPalette(c("#B5562B", "#F7F3EE", "#2C6E9B"))(41)
    graphics::image(1:12, seq_len(nrow(M)), t(M), col = pal, zlim = c(-lim, lim), axes = FALSE,
                    xlab = "", ylab = "", main = sprintf("Monatsrenditen: %s", if (is.character(series)) series else names(x$monthly)[series]))
    graphics::axis(1, 1:12, .monate_kurz, cex.axis = 0.75); graphics::axis(2, seq_len(nrow(M)), rownames(M), cex.axis = 0.6)
    if (nrow(M) <= 30) graphics::text(rep(1:12, each = nrow(M)), rep(seq_len(nrow(M)), 12),
                                      ifelse(is.na(M), "", sprintf("%.1f", M)), cex = 0.5)
  }
  if (type == "overview") {
    graphics::par(mfrow = c(2, 2)); base_par()
    p_growth(); p_dd(); p_roll(); p_annual()
  } else {
    base_par()
    switch(type, growth = p_growth(), drawdown = p_dd(), rolling = p_roll(), annual = p_annual(), monthly = p_monthly())
  }
  invisible(x)
}

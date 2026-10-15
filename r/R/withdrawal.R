# =============================================================================
#  withdrawal.R  —  Entnahme-Simulationen (Ruhestand / Decumulation)
# -----------------------------------------------------------------------------
#  withdrawal_rule()        Regel-Objekt (wie asset_config()), 14 Regeln
#  withdrawal_cohorts()     historische rollierende Kohorten (Bengen/Trinity)
#  withdrawal_paths()       Perioden-Renditen aus bootstrap()-Pfaden, Listen von
#                           simulation()-Ergebnissen oder bootstrap_study()
#  result_index()           zeitgewichteter Wertindex eines simulation()-Ergebnisses
#  withdrawal_simulation()  schneller C++-Kern ueber viele Pfade, optional mit
#                           vereinfachter deutscher Besteuerung
#  perfect_withdrawal_rate() PWR nach Suarez, Suarez & Walz (2015)
#  withdrawal_max_rate()    maximale Anfangsrate fuer eine Ziel-Erfolgsquote
#
#  Die Entnahmephase ist bewusst von simulation() getrennt: Ein Ergebnis von
#  simulation() (z. B. per saveRDS() gespeichert) oder einer Bootstrap-Studie
#  liefert die Renditen, withdrawal_simulation() rechnet darauf die Entnahmen.
#
#  PROZENT-KONVENTION: rate, ceiling, floor, cut, raise, exp_return usw. in
#  Prozent (rate = 4 bedeutet 4 % p. a.), wie im restlichen Paket.
# =============================================================================

.wd_rules <- c(constant = 1L, percent = 2L, vanguard = 3L, guyton_klinger = 4L,
               floor_ceiling = 5L, clyatt = 6L, ratchet = 7L, endowment = 8L,
               one_over_n = 9L, vpw = 10L, abw = 11L, cape = 12L, sensible = 13L,
               hebeler = 14L)

.wd_labels <- c(constant = "Konstante reale Entnahme (Bengen/Trinity)",
                percent = "Fester Prozentsatz des Depots",
                vanguard = "Vanguard Dynamic Spending (Ceiling/Floor)",
                guyton_klinger = "Guyton-Klinger-Entscheidungsregeln",
                floor_ceiling = "Floor-and-Ceiling (Bengen 2001)",
                clyatt = "Clyatt 95-%-Regel",
                ratchet = "Kitces-Ratchet",
                endowment = "Endowment-/Yale-Regel (Tobin)",
                one_over_n = "1/N (Restlaufzeit)",
                vpw = "Variable Percentage Withdrawal (Bogleheads)",
                abw = "Amortisationsbasierte Entnahme (ABW)",
                cape = "CAPE-basierte Regel",
                sensible = "Sensible Withdrawals",
                hebeler = "Hebeler Autopilot II")

#' Entnahmeregel definieren
#'
#' Erzeugt eine validierte Entnahmeregel fuer [withdrawal_simulation()].
#' Die Jahresentnahme wird zu Beginn
#' jedes Planjahres festgelegt (Guyton & Klinger 2006; Suarez et al. 2015) und
#' bei unterjaehrigen Perioden gleichmaessig ausgezahlt. Alle Betraege sind
#' Netto-Konsum; Steuern werden zusaetzlich aus dem Depot verkauft.
#'
#' @param type Regel:
#'   \describe{
#'     \item{"constant"}{Bengen (1994) / Trinity-Studie: \eqn{W_1 = rate \cdot P_1}, danach jaehrlich um die Inflation erhoeht.}
#'     \item{"percent"}{Fester Prozentsatz des aktuellen Depots.}
#'     \item{"vanguard"}{Vanguard Dynamic Spending: \eqn{rate \cdot P}, Veraenderung zum Vorjahr real begrenzt auf +\code{ceiling} / -\code{floor} (Standard 5 / 2,5).}
#'     \item{"guyton_klinger"}{Guyton & Klinger (2006): kein Inflationsausgleich nach Verlustjahr, wenn die aktuelle Rate ueber der Anfangsrate liegt; Kuerzung um \code{cut} bei Rate > (1 + \code{ceiling}) x Anfangsrate (nicht in den letzten \code{cpr_years} Jahren); Erhoehung um \code{raise} bei Rate < (1 - \code{floor}) x Anfangsrate. Standard 20/20/10/10, 15 Jahre.}
#'     \item{"floor_ceiling"}{Bengen (2001): \eqn{rate \cdot P}, begrenzt auf [1 - floor, 1 + ceiling] x reale Erstentnahme (Standard 15 / 20).}
#'     \item{"clyatt"}{Clyatt: \eqn{\max(rate \cdot P, 0.95 \cdot W_{t-1})}, nominal.}
#'     \item{"ratchet"}{Kitces: konstant real, +\code{raise} (10) wenn das reale Depot \code{ratchet_threshold} (1,5) x Startdepot uebersteigt, hoechstens alle \code{ratchet_gap} (3) Jahre.}
#'     \item{"endowment"}{Yale/Tobin: \eqn{\lambda W_{t-1}(1+\pi) + (1-\lambda) rate \cdot P}, \code{smoothing} = 70.}
#'     \item{"one_over_n"}{\eqn{P / (N - t + 1)}; leert das Depot planmaessig.}
#'     \item{"vpw"}{Bogleheads VPW: \eqn{P \cdot PMT(r, max\_age - Alter)}, r = \code{exp_return} (Standard: 5 x Aktienquote + 1,9 x Rest).}
#'     \item{"abw"}{Amortisation: reale Annuitaet ueber die Restlaufzeit mit Zielvermoegen \code{fv}.}
#'     \item{"cape"}{\eqn{(a + b / CAPE) \cdot P}, Standard a = 1,75, b = 0,5 (ERN); CAPE-Reihe noetig.}
#'     \item{"sensible"}{Basis \code{rate} x Startdepot real plus \code{extra} (10) des realen Vorjahresgewinns.}
#'     \item{"hebeler"}{Autopilot II: 75 \% Vorjahresentnahme (inflationiert) + 25 \% Annuitaet.}
#'   }
#' @param rate Entnahmerate in Prozent (Anfangs- bzw. Zielrate).
#' @param ceiling,floor Obere/untere Schranke in Prozent (Bedeutung je Regel).
#' @param cut,raise Kuerzung/Erhoehung in Prozent (Guyton-Klinger, Ratchet).
#' @param cpr_years Guyton-Klinger: Capital-Preservation-Rule endet so viele
#'   Jahre vor Planende.
#' @param inflation_cap Guyton-Klinger: maximale Inflationsanpassung in
#'   Prozent (Standard \code{Inf}, wie in der Fassung von 2006).
#' @param skip_inflation Guyton-Klinger: Withdrawal-Rule aktiv.
#' @param smoothing Glaettungsgewicht in Prozent (Endowment 70, Hebeler 75).
#' @param exp_return Erwartete reale Rendite in Prozent (VPW, ABW, Hebeler).
#' @param stock_share Aktienquote in Prozent fuer den VPW-Standard von
#'   \code{exp_return}.
#' @param age,max_age Alter bei Rentenbeginn und Planungsalter (VPW).
#' @param horizon Planungshorizont in Jahren (1/N, ABW, Hebeler, Guyton-Klinger);
#'   Standard: Laenge der Simulation.
#' @param fv Reales Zielvermoegen am Ende (ABW).
#' @param cape_a,cape_b CAPE-Regel: Konstante (Prozent) und Multiplikator.
#' @param ratchet_threshold,ratchet_gap Ratchet-Parameter.
#' @param extra Sensible Withdrawals: Anteil des realen Gewinns in Prozent.
#' @param floor95 Clyatt: Mindestanteil der Vorjahresentnahme in Prozent.
#' @param min_real,max_real Absolute Unter-/Obergrenze der Jahresentnahme in
#'   Kaufkraft des Startzeitpunkts (fuer alle Regeln).
#' @param max_rate VPW: Hoechstsatz in Prozent (Standard 100).
#' @return Objekt der Klasse \code{withdrawal_rule}.
#' @references Bengen (1994, 2001); Cooley, Hubbard & Walz (1998);
#'   Guyton & Klinger (2006), Journal of Financial Planning 19(3);
#'   Vanguard (2021), Sustainable spending rates in turbulent markets;
#'   Bogleheads Wiki, Variable percentage withdrawal; Kitces (2015);
#'   Suarez, Suarez & Walz (2015), Financial Services Review 24.
#' @examples
#' withdrawal_rule("constant", rate = 4)
#' withdrawal_rule("guyton_klinger", rate = 5.2)
#' withdrawal_rule("vanguard", rate = 5, ceiling = 5, floor = 2.5)
#' @export
withdrawal_rule <- function(type = names(.wd_rules), rate = 4,
                            ceiling = NULL, floor = NULL, cut = 10, raise = 10,
                            cpr_years = 15, inflation_cap = Inf, skip_inflation = TRUE,
                            smoothing = NULL, exp_return = NULL, stock_share = 60,
                            age = 65, max_age = 100, horizon = NULL, fv = 0,
                            cape_a = 1.75, cape_b = 0.5, ratchet_threshold = 1.5,
                            ratchet_gap = 3, extra = 10, floor95 = 95,
                            min_real = 0, max_real = Inf, max_rate = 100) {
  type <- match.arg(type)
  if (!is.numeric(rate) || rate < 0 || rate > 100) stop("rate muss zwischen 0 und 100 Prozent liegen (z. B. 4).")
  if (rate > 0 && rate < 0.2 && type %in% c("constant", "percent", "vanguard", "guyton_klinger"))
    warning("rate wirkt wie eine Dezimalzahl. PROZENT-KONVENTION: 4 bedeutet 4 %.")
  dflt <- switch(type,
    vanguard = list(ceiling = 5, floor = 2.5),
    guyton_klinger = list(ceiling = 20, floor = 20),
    floor_ceiling = list(ceiling = 20, floor = 15),
    list(ceiling = 0, floor = 0))
  ceiling <- ceiling %||% dflt$ceiling
  floor <- floor %||% dflt$floor
  smoothing <- smoothing %||% (if (type == "hebeler") 75 else 70)
  exp_return <- exp_return %||% (5.0 * stock_share / 100 + 1.9 * (1 - stock_share / 100))
  if (any(c(ceiling, floor, cut, raise) < 0)) stop("ceiling, floor, cut und raise muessen >= 0 sein.")
  if (smoothing < 0 || smoothing > 100) stop("smoothing muss zwischen 0 und 100 liegen.")
  structure(list(type = type, rate = rate, ceiling = ceiling, floor = floor, cut = cut, raise = raise,
                 cpr_years = cpr_years, inflation_cap = inflation_cap, skip_inflation = skip_inflation,
                 smoothing = smoothing, exp_return = exp_return, age = age, max_age = max_age,
                 horizon = horizon, fv = fv, cape_a = cape_a, cape_b = cape_b,
                 ratchet_threshold = ratchet_threshold, ratchet_gap = ratchet_gap, extra = extra,
                 floor95 = floor95, min_real = min_real, max_real = max_real, max_rate = max_rate),
            class = c("withdrawal_rule", "list"))
}

#' @rdname SimLevWithdrawal-methods
#' @export
print.withdrawal_rule <- function(x, ...) {
  cat("Entnahmeregel\n-------------\n")
  cat(sprintf("  Typ:       %s (%s)\n", x$type, .wd_labels[[x$type]]))
  if (!x$type %in% c("one_over_n", "vpw", "abw", "cape", "hebeler")) cat(sprintf("  Rate:      %.2f %%\n", x$rate))
  extra <- switch(x$type,
    vanguard = sprintf("  Ceiling/Floor (real): +%.2f %% / -%.2f %%\n", x$ceiling, x$floor),
    guyton_klinger = sprintf("  Guardrails: +%.0f %% / -%.0f %%, Kuerzung %.0f %%, Erhoehung %.0f %%, CPR bis %d J. vor Ende\n",
                             x$ceiling, x$floor, x$cut, x$raise, as.integer(x$cpr_years)),
    floor_ceiling = sprintf("  Korridor:  -%.0f %% / +%.0f %% um reale Erstentnahme\n", x$floor, x$ceiling),
    endowment = sprintf("  Glaettung: %.0f %%\n", x$smoothing),
    hebeler = sprintf("  Glaettung: %.0f %%, erwartete Realrendite %.2f %%\n", x$smoothing, x$exp_return),
    vpw = sprintf("  Alter %d bis %d, erwartete Realrendite %.2f %%\n", as.integer(x$age), as.integer(x$max_age), x$exp_return),
    abw = sprintf("  Erwartete Realrendite %.2f %%, Zielvermoegen %.0f\n", x$exp_return, x$fv),
    cape = sprintf("  Rate = %.2f %% + %.2f / CAPE\n", x$cape_a, x$cape_b),
    ratchet = sprintf("  +%.0f %% bei Depot > %.2f x Start, alle %d Jahre\n", x$raise, x$ratchet_threshold, as.integer(x$ratchet_gap)),
    sensible = sprintf("  Zusatz: %.0f %% des realen Vorjahresgewinns\n", x$extra),
    clyatt = sprintf("  Mindestens %.0f %% der Vorjahresentnahme\n", x$floor95), "")
  cat(extra)
  if (x$min_real > 0 || is.finite(x$max_real)) cat(sprintf("  Grenzen:   %.0f bis %s (real)\n", x$min_real, format(x$max_real)))
  invisible(x)
}

#' Parametervektor fuer den C++-Kern (Reihenfolge = enum in withdrawal_core.cpp)
#' @keywords internal
.wd_param_vector <- function(rule, horizon) {
  r <- rule
  c(r$rate / 100, r$ceiling / 100, r$floor / 100, r$cut / 100, r$raise / 100, r$cpr_years,
    r$inflation_cap / 100, r$smoothing / 100, r$exp_return / 100, r$horizon %||% horizon,
    r$cape_a / 100, r$cape_b, r$ratchet_threshold, r$ratchet_gap, r$extra / 100,
    r$min_real, r$max_real, r$age, r$max_age, r$fv, r$floor95 / 100,
    as.numeric(isTRUE(r$skip_inflation)), r$max_rate / 100)
}

.wd_ppy <- function(frequency) switch(frequency, year = 1L, quarter = 4L, month = 12L,
                                      stop("frequency muss 'year', 'quarter' oder 'month' sein."))

#' Perioden-Kennzahl aus einer Tagesreihe ueber Kalendergrenzen
#' @keywords internal
.period_ends <- function(dates, frequency) {
  key <- switch(frequency, year = format(dates, "%Y"),
                quarter = paste(format(dates, "%Y"), (as.integer(format(dates, "%m")) - 1L) %/% 3L),
                month = format(dates, "%Y-%m"))
  which(c(key[-1] != key[-length(key)], TRUE))
}


#' Historische Entnahme-Kohorten bilden
#'
#' Erzeugt rollierende Start-Kohorten (wie Bengen 1994 und die Trinity-Studie)
#' aus einer historischen Kursreihe: Fuer jeden Startmonat bzw. jedes Startjahr
#' entsteht ein Pfad ueber \code{years} Jahre.
#'
#' @param data data.frame mit \code{date} und Kursspalte(n) oder ein
#'   \code{SimLevResult} (dann wird dessen zeitgewichteter Wertindex
#'   [result_index()] verwendet und \code{price} ignoriert).
#' @param price Name der Kursspalte des Portfolios (Total Return, nach Kosten),
#'   z. B. eine Backcast-Reihe.
#' @param inflation \code{NULL} (keine Inflation), Prozent p. a. (Skalar) oder
#'   Name einer Preisindex-Spalte (CPI-Niveau, z. B. HVPI).
#' @param years Laenge jeder Kohorte in Jahren.
#' @param frequency Periodenlaenge der Simulation: "year", "quarter", "month".
#' @param step Abstand der Kohortenstarts: "month" oder "year".
#' @param wrap Kohorten ueber das Datenende hinaus durch Fortsetzung am
#'   Datenanfang verlaengern (wie FI Calc, Option "loop").
#' @param cape Optional Spalte mit CAPE-Werten (fuer die CAPE-Regel).
#' @param base_rate Optional Spalte mit dem Basiszins (Prozent) fuer die
#'   Vorabpauschale; sonst gilt der Wert aus [withdrawal_simulation()].
#' @return Objekt der Klasse \code{withdrawal_paths} (Matrizen Periode x Kohorte).
#' @export
withdrawal_cohorts <- function(data, price = "value", inflation = NULL, years = 30,
                               frequency = c("year", "quarter", "month"),
                               step = c("month", "year"), wrap = FALSE,
                               cape = NULL, base_rate = NULL) {
  frequency <- match.arg(frequency); step <- match.arg(step)
  if (inherits(data, "SimLevResult")) {
    if (is.character(inflation) || !is.null(cape) || !is.null(base_rate))
      stop("Bei einem SimLevResult sind nur numerische Inflation und keine Zusatzspalten moeglich.")
    data <- result_index(data); price <- "value"
  }
  if (!all(c("date", price) %in% names(data))) stop("data braucht 'date' und die Kursspalte.")
  data <- data[order(as.Date(data$date)), , drop = FALSE]
  dates <- as.Date(data$date)
  px <- .fill_na(as.numeric(data[[price]]), "locf")
  ends <- .period_ends(dates, "month")                     # Monatsraster als Basis
  mdates <- dates[ends]; mpx <- px[ends]
  cpi <- if (is.null(inflation)) rep(1, length(ends))
         else if (is.character(inflation)) .fill_na(as.numeric(data[[inflation]]), "locf")[ends]
         else (1 + inflation / 100)^(as.numeric(mdates - mdates[1]) / 365.25)
  capev <- if (!is.null(cape)) .fill_na(as.numeric(data[[cape]]), "locf")[ends] else NULL
  brv <- if (!is.null(base_rate)) .fill_na(as.numeric(data[[base_rate]]), "locf")[ends] else NULL
  mret <- mpx[-1] / mpx[-length(mpx)]; minf <- cpi[-1] / cpi[-length(cpi)]
  nm <- length(mret)
  ppy <- .wd_ppy(frequency); mpp <- 12L / ppy
  len_m <- years * 12L
  starts <- if (step == "month") seq_len(nm) else seq(1L, nm, by = 12L)
  if (!wrap) starts <- starts[starts + len_m - 1L <= nm]
  if (!length(starts)) stop("Zu kurze Historie fuer die gewaehlte Kohortenlaenge.")
  take <- function(v, s) v[((s - 1L + seq_len(len_m) - 1L) %% nm) + 1L]
  agg <- function(m) {                                     # Monate -> Perioden (Produkt)
    if (mpp == 1L) return(m)
    apply(m, 2, function(col) apply(matrix(col, nrow = mpp), 2, prod))
  }
  R <- agg(vapply(starts, function(s) take(mret, s), numeric(len_m)))
  I <- agg(vapply(starts, function(s) take(minf, s), numeric(len_m)))
  pick_start <- function(v) if (is.null(v)) NULL else {
    m <- vapply(starts, function(s) take(v[-length(v)], s), numeric(len_m))
    m[seq(1L, len_m, by = mpp), , drop = FALSE]            # Wert zu Periodenbeginn
  }
  structure(list(returns = matrix(R, ncol = length(starts)), inflation = matrix(I, ncol = length(starts)),
                 cape = pick_start(capev), base_rate = pick_start(brv),
                 frequency = frequency, start_dates = mdates[starts], historical = TRUE, wrap = wrap,
                 source = price), class = "withdrawal_paths")
}

#' Zeitgewichteter Wertindex eines Simulationsergebnisses
#'
#' Bildet aus einem \code{SimLevResult} den um Ein- und Auszahlungen bereinigten
#' Wertindex (Basis der TTWROR): \eqn{I_t = I_{t-1} (W_t - F_t) / W_{t-1}}.
#' Damit laesst sich jedes gespeicherte Ergebnis von [simulation()] als
#' Renditequelle fuer [withdrawal_simulation()] verwenden.
#'
#' @param x \code{SimLevResult}.
#' @param base Startwert des Index.
#' @return data.frame mit \code{date}, \code{value} (Index), \code{worth}
#'   (Depotwert) und \code{flows} (Ein-/Auszahlungen je Tag).
#' @examples
#' d <- data.frame(date = seq.Date(as.Date("2020-01-01"), by = "day", length.out = 400),
#'                 ETF = 100 * cumprod(1 + rnorm(400, 3e-4, 0.01)))
#' res <- simulation(d, create_strategy(ETF = asset_config("etf", "bnh")),
#'                   dca_mode = TRUE, dca_value = 100, dca_span = 1)
#' head(result_index(res))
#' @export
result_index <- function(x, base = 100) {
  if (!inherits(x, "SimLevResult")) stop("x muss ein SimLevResult (Ergebnis von simulation()) sein.")
  w <- as.numeric(x$worth)
  fl <- vapply(x$report, function(a) as.numeric(a$flows), numeric(length(w)))
  fl <- if (is.matrix(fl)) rowSums(fl) else as.numeric(fl)
  g <- c(1, (w[-1] - fl[-1]) / w[-length(w)])
  g[!is.finite(g)] <- 1
  data.frame(date = as.Date(x$dates), value = base * cumprod(g), worth = w, flows = fl)
}

#' Periodenenden als Jahrestage ab Startdatum
#' @keywords internal
.anniv_ends <- function(dates, frequency) {
  by <- switch(frequency, year = "1 year", quarter = "3 months", month = "1 month")
  tg <- seq.Date(as.Date(dates[1]), as.Date(dates[length(dates)]), by = by)
  unique(findInterval(as.numeric(tg), as.numeric(dates)))
}

#' Pfade in Perioden-Renditen fuer Entnahmen umwandeln
#'
#' Wandelt simulierte Pfade in die Periodenmatrizen von [withdrawal_simulation()]
#' um. Perioden beginnen am Startdatum der Pfade (Jahrestage).
#'
#' @param x \code{bootstrap_result} aus [bootstrap()], eine Liste von
#'   \code{SimLevResult} (je Element ein Pfad, z. B. gespeicherte
#'   simulation()-Laeufe auf Bootstrap-Pfaden) oder eine
#'   \code{SimLevBootstrapStudy}, die mit \code{keep_returns} gerechnet wurde.
#' @param column Bei \code{bootstrap_result}: Kursspalte im Pfad (Index,
#'   Hebelprodukt).
#' @param strategy Bei \code{SimLevBootstrapStudy}: Strategiename (Standard:
#'   erste Strategie).
#' @param inflation \code{NULL}, Prozent p. a. oder Name einer Zusatzreihe
#'   (\code{aux} bei \code{bootstrap_result}, \code{keep_aux} bei Studien) mit
#'   CPI-Niveau bzw. Inflationsrate. Mit \code{inflation_type} "level"
#'   (Niveau) oder "rate_pa" (Prozent p. a., je Zeile anteilig).
#' @param inflation_type Interpretation einer Inflations-Zusatzreihe.
#' @param frequency "year", "quarter" oder "month" (bei Studien die
#'   gespeicherte Frequenz).
#' @param dates,start_date Kalender der Bootstrap-Pfade (siehe [bootstrap_data()]).
#' @param cape Optional aux-Spalte mit CAPE-Werten.
#' @return \code{withdrawal_paths}.
#' @export
withdrawal_paths <- function(x, column = NULL, strategy = NULL, inflation = NULL,
                             inflation_type = c("level", "rate_pa"),
                             frequency = c("year", "quarter", "month"), dates = NULL,
                             start_date = "2000-01-01", cape = NULL) {
  frequency <- match.arg(frequency); inflation_type <- match.arg(inflation_type)
  infl_from <- function(n_per, n_paths, ends_dates) {
    if (is.null(inflation)) return(matrix(1, n_per, n_paths))
    if (!is.numeric(inflation)) return(NULL)
    matrix((1 + inflation / 100)^(as.numeric(diff(ends_dates)) / 365.25), n_per, n_paths)
  }
  mk <- function(R, I, C, w, src) structure(list(returns = as.matrix(R), inflation = as.matrix(I),
    cape = if (!is.null(C)) as.matrix(C) else NULL, base_rate = NULL, frequency = frequency,
    start_dates = NULL, historical = FALSE, weights = w, source = src), class = "withdrawal_paths")

  # 1) Gespeicherte Bootstrap-Studie
  if (inherits(x, "SimLevBootstrapStudy")) {
    if (is.null(x$returns)) stop("Die Studie enthaelt keine Periodenrenditen; bootstrap_study(..., keep_returns = 'year') verwenden.")
    strategy <- strategy %||% names(x$returns)[1]
    if (!strategy %in% names(x$returns)) stop(sprintf("Strategie '%s' nicht gespeichert. Verfuegbar: %s", strategy, paste(names(x$returns), collapse = ", ")))
    frequency <- x$returns_frequency
    R <- x$returns[[strategy]]
    ok <- colSums(is.na(R)) == 0
    I <- if (is.character(inflation)) {
      if (is.null(x$aux_returns[[inflation]])) stop(sprintf("Zusatzreihe '%s' nicht gespeichert (keep_aux).", inflation))
      x$aux_returns[[inflation]]
    } else infl_from(nrow(R), ncol(R), x$returns_dates)
    w <- x$path_weights
    return(mk(R[, ok, drop = FALSE], I[, ok, drop = FALSE], NULL, w[ok], paste0("study:", strategy)))
  }
  # 2) Liste von simulation()-Ergebnissen
  if (is.list(x) && !inherits(x, "bootstrap_result") && length(x) && all(vapply(x, inherits, TRUE, "SimLevResult"))) {
    if (is.character(inflation)) stop("Bei Ergebnislisten ist 'inflation' ein Prozentsatz p. a.")
    idx <- lapply(x, result_index)
    ends <- .anniv_ends(idx[[1]]$date, frequency)
    if (length(ends) < 2) stop("Ergebnisse zu kurz fuer eine volle Periode.")
    R <- vapply(idx, function(d) {
      if (nrow(d) != nrow(idx[[1]])) stop("Alle Ergebnisse muessen gleich lang sein.")
      v <- d$value[ends]; v[-1] / v[-length(v)] }, numeric(length(ends) - 1L))
    R <- as.matrix(R)
    return(mk(R, infl_from(nrow(R), ncol(R), idx[[1]]$date[ends]), NULL, NULL, "results"))
  }
  # 3) bootstrap()-Pfade
  if (!inherits(x, "bootstrap_result")) stop("x muss ein bootstrap_result, eine Liste von SimLevResult oder eine SimLevBootstrapStudy sein.")
  if (is.null(column)) stop("Bei bootstrap_result muss 'column' angegeben werden.")
  P1 <- x$paths[[1]]
  if (!column %in% colnames(P1)) stop(sprintf("Spalte '%s' nicht im Pfad. Verfuegbar: %s", column, paste(colnames(P1), collapse = ", ")))
  if (is.null(dates)) dates <- seq.Date(as.Date(start_date), by = "day", length.out = nrow(P1))
  ends <- .anniv_ends(dates, frequency)
  per <- function(v) v[ends[-1]] / v[ends[-length(ends)]]
  R <- as.matrix(vapply(x$paths, function(P) per(P[, column]), numeric(length(ends) - 1L)))
  I <- infl_from(nrow(R), ncol(R), dates[ends])
  if (is.null(I)) I <- as.matrix(vapply(x$paths, function(P) {
    v <- P[, inflation]
    if (inflation_type == "level") per(v)
    else { lvl <- cumprod(c(1, (1 + v[-1] / 100)^(as.numeric(diff(dates)) / 365.25))); per(lvl) }
  }, numeric(length(ends) - 1L)))
  C <- if (!is.null(cape)) vapply(x$paths, function(P) P[ends[-length(ends)], cape], numeric(length(ends) - 1L)) else NULL
  mk(R, I, C, x$weights, column)
}

#' Perfect Withdrawal Rate (PWR)
#'
#' Exakte konstante reale Entnahmerate, die ein Depot bei gegebener Renditefolge
#' genau aufbraucht bzw. das Zielvermoegen hinterlaesst (Suarez, Suarez & Walz
#' 2015; Entnahme jeweils zu Jahresbeginn):
#' \deqn{PWR = (R_n - K_E/K_S) \cdot S_n, \quad R_n = \prod (1+r_i), \quad
#'       S_n = 1 / \sum_{i=1}^{n} \prod_{j=i}^{n} (1 + r_j)}
#'
#' @param real_returns Matrix (Jahre x Pfade) realer Brutto-Jahresrenditen
#'   (z. B. 1.05) oder \code{withdrawal_paths}.
#' @param legacy Zielvermoegen als Anteil des Startvermoegens (K_E / K_S).
#' @return Vektor der PWR je Pfad in Prozent.
#' @export
perfect_withdrawal_rate <- function(real_returns, legacy = 0) {
  if (inherits(real_returns, "withdrawal_paths")) real_returns <- .annual_real(real_returns)
  R <- as.matrix(real_returns)
  apply(R, 2, function(r) {
    tail_prod <- rev(cumprod(rev(r)))                     # prod_{j=i..n}
    (prod(r) - legacy) / sum(tail_prod) * 100
  })
}

#' Reale Jahresrenditen aus Perioden-Matrizen
#' @keywords internal
.annual_real <- function(wp) {
  ppy <- .wd_ppy(wp$frequency)
  real <- wp$returns / wp$inflation
  if (ppy == 1L) return(real)
  np <- nrow(real); ny <- np %/% ppy
  apply(real[seq_len(ny * ppy), , drop = FALSE], 2, function(col) apply(matrix(col, nrow = ppy), 2, prod))
}


#' Entnahme-Simulation ueber viele Pfade
#'
#' Simuliert eine Entnahmeregel auf historischen Kohorten ([withdrawal_cohorts()]),
#' Bootstrap-Pfaden ([withdrawal_paths()]) oder einer beliebigen Renditematrix.
#' Der C++-Kern rechnet 100.000 Pfade x 30 Jahre in Sekundenbruchteilen.
#'
#' Besteuerung (\code{tax_mode = "person"}): vereinfachtes Modell eines
#' einzelnen thesaurierenden Fondsbestands nach heutiger Rechtslage
#' (Modellphilosophie des Pakets): Verkaufsgewinne mit Teilfreistellung,
#' Verlustverrechnung vor Sparer-Pauschbetrag, Abgeltungsteuer;
#' Vorabpauschale zum Jahresende (faellig zu Beginn des Folgejahres, durch
#' Anteilsverkauf beglichen und beim spaeteren Verkauf angerechnet). Bei einer
#' Einmalanlage ohne Zukaeufe ist die Durchschnittskostenmethode identisch mit
#' FIFO. Das Planjahr wird als Steuerjahr behandelt.
#'
#' Renditequellen: Die Entnahmephase ist bewusst von [simulation()] getrennt.
#' Ein gespeichertes Ergebnis von [simulation()] (etwa per \code{saveRDS()})
#' liefert ueber seinen zeitgewichteten Wertindex ([result_index()]) die
#' Renditen; bei einem Einzelergebnis werden daraus historische Kohorten
#' gebildet, eine Liste von Ergebnissen (z. B. je Bootstrap-Pfad) oder eine
#' [bootstrap_study()] mit \code{keep_returns} liefert je Element einen Pfad.
#' Wurde das Quellergebnis bereits mit \code{tax_mode = "person"} gerechnet,
#' enthaelt der Index schon Vorabpauschalen; dann hier \code{vorabpauschale =
#' FALSE} setzen oder die Quelle ohne Steuern rechnen.
#'
#' @param x \code{withdrawal_paths}, Matrix (Perioden x Pfade) von
#'   Brutto-Periodenrenditen nach Produktkosten, ein \code{SimLevResult}
#'   (historische Kohorten ueber dessen Verlauf, Laenge \code{years}, Standard
#'   30), eine Liste von \code{SimLevResult} oder eine \code{SimLevBootstrapStudy}
#'   (mit \code{keep_returns}; Strategie ueber \code{strategy}).
#' @param rule Objekt aus [withdrawal_rule()].
#' @param start_value Startvermoegen oder ein \code{SimLevResult} der
#'   Ansparphase: dann gelten dessen Endwert als Startvermoegen und
#'   (Startwert + Einzahlungen) / Endwert als Anschaffungskostenquote
#'   (\code{cost_basis}), sofern \code{cost_basis} nicht gesetzt ist.
#' @param strategy Bei \code{SimLevBootstrapStudy}: Name der Strategie.
#' @param inflation Bei Matrix-, Ergebnis- oder Studien-Eingabe: Prozent p. a.,
#'   bei Matrix-Eingabe auch eine Matrix gleicher Dimension mit
#'   Brutto-Periodeninflation, bei Studien auch der Name einer gespeicherten
#'   Zusatzreihe (\code{keep_aux}).
#' @param frequency Bei Matrix-, Ergebnis- oder Studien-Eingabe: Periodenlaenge.
#' @param years Optional Kuerzung auf die ersten \code{years} Jahre.
#' @param timing "start" (Entnahme zu Periodenbeginn, Standard) oder "end".
#' @param income Optional weitere Einkommen (z. B. gesetzliche Rente): Liste
#'   von \code{list(start = Jahr, end = Jahr, amount = realer Jahresbetrag)};
#'   sie mindern die Depotentnahme (Entnahme = max(0, Regelbetrag - Einkommen)).
#' @param tax_mode "none" oder "person".
#' @param tax_rate Abgeltungsteuer inkl. Soli in Prozent (26.375).
#' @param asset_bonus Teilfreistellung in Prozent (30 Aktienfonds, 15 Mischfonds).
#' @param sparer_pauschbetrag Jaehrlicher Sparer-Pauschbetrag (1000 / 2000).
#' @param base_rate Basiszins in Prozent (Standard 3.20 fuer 2026), Skalar oder
#'   Matrix; bei Kohorten mit Basiszins-Spalte wird diese verwendet.
#' @param vorabpauschale Vorabpauschale beruecksichtigen.
#' @param sale_cost Verkaufskosten in Prozent je Verkauf (z. B. halber Spread).
#' @param cost_basis Anschaffungskosten in Prozent des Startwerts (100 = frisch
#'   gekauft; kleiner bei Altbestand mit stillen Reserven).
#' @param loss_carryforward Anfangsbestand Verlusttopf.
#' @param gamma Relative Risikoaversion fuer das Sicherheitsaequivalent
#'   (CRRA) der realen Konsumreihe.
#' @param keep_paths Vermoegensmatrix zurueckgeben.
#'
#' @return \code{SimLevWithdrawal} mit Kennzahlen je Pfad (\code{paths}:
#'   Erfolg, Erschoepfungsjahr, reales Endvermoegen, PWR, Konsumkennzahlen,
#'   Steuern), Matrizen \code{spending}, \code{planned}, \code{wealth} (real,
#'   Startkaufkraft) und Zusammenfassung. Auswertung mit \code{print},
#'   \code{summary}, \code{plot}.
#' @examples
#' set.seed(1)
#' R <- matrix(exp(rnorm(30 * 500, 0.05, 0.15)), 30)    # 30 Jahre, 500 Pfade
#' ws <- withdrawal_simulation(R, withdrawal_rule("guyton_klinger", rate = 5),
#'                             start_value = 1e6, inflation = 2)
#' ws
#' # Ansparphase mit simulation(), speichern, dann Entnahmephase:
#' set.seed(2)
#' d <- data.frame(date = seq.Date(as.Date("1980-01-01"), as.Date("2019-12-31"), by = "day"))
#' d$ETF <- 100 * cumprod(1 + rnorm(nrow(d), 3e-4, 0.01))
#' res <- simulation(d, create_strategy(ETF = asset_config("etf", "bnh")), start_value = 1e5)
#' # saveRDS(res, "ansparphase.rds"); res <- readRDS("ansparphase.rds")
#' wr <- withdrawal_simulation(res, withdrawal_rule("vanguard", rate = 4),
#'                             years = 25, inflation = 2, start_value = 1e6)
#' summary(wr)
#' @seealso [withdrawal_rule()], [withdrawal_cohorts()], [withdrawal_paths()],
#'   [result_index()], [withdrawal_max_rate()], [simulation()], [bootstrap_study()]
#' @export
withdrawal_simulation <- function(x, rule = withdrawal_rule("constant"), start_value = 1e6,
                                  inflation = 0, frequency = c("year", "quarter", "month"),
                                  strategy = NULL,
                                  years = NULL, timing = c("start", "end"), income = NULL,
                                  tax_mode = c("none", "person"), tax_rate = 26.375,
                                  asset_bonus = 30, sparer_pauschbetrag = 1000, base_rate = 3.20,
                                  vorabpauschale = TRUE, sale_cost = 0, cost_basis = 100,
                                  loss_carryforward = 0, gamma = 2, keep_paths = TRUE) {
  timing <- match.arg(timing); tax_mode <- match.arg(tax_mode)
  if (!inherits(rule, "withdrawal_rule")) stop("rule muss mit withdrawal_rule() erstellt werden.")
  # Startvermoegen aus einer Ansparphase uebernehmen
  if (inherits(start_value, "SimLevResult")) {
    acc <- result_index(start_value)
    sv <- utils::tail(acc$worth, 1)
    if (missing(cost_basis)) {
      invested <- acc$worth[1] + sum(pmax(acc$flows[-1], 0))
      cost_basis <- 100 * invested / sv
    }
    start_value <- sv
  }
  # Renditequellen aus simulation()/bootstrap_study()
  src_taxed <- FALSE
  if (inherits(x, "SimLevResult")) {
    src_taxed <- isTRUE(x$tax_report$total_taxes_paid > 0)
    if (!is.numeric(inflation) || length(inflation) != 1L) stop("Bei einem SimLevResult ist 'inflation' ein Prozentsatz p. a.")
    x <- withdrawal_cohorts(x, inflation = inflation, years = years %||% 30, frequency = match.arg(frequency))
  } else if (inherits(x, "SimLevBootstrapStudy") || (is.list(x) && length(x) && all(vapply(x, inherits, TRUE, "SimLevResult")))) {
    if (is.list(x) && !inherits(x, "SimLevBootstrapStudy"))
      src_taxed <- any(vapply(x, function(r) isTRUE(r$tax_report$total_taxes_paid > 0), TRUE))
    x <- withdrawal_paths(x, strategy = strategy, inflation = inflation, frequency = match.arg(frequency))
  }
  if (src_taxed && tax_mode == "person" && isTRUE(vorabpauschale))
    warning("Das Quellergebnis wurde mit Steuern gerechnet (Vorabpauschale im Index enthalten); ",
            "vorabpauschale = FALSE oder eine Quelle mit tax_mode = 'none' vermeidet Doppelzaehlung.")
  if (!inherits(x, "withdrawal_paths")) {
    frequency <- match.arg(frequency)
    R <- as.matrix(x)
    if (any(R < 0, na.rm = TRUE) || stats::median(R) < 0.5)
      stop("x muss Brutto-Periodenrenditen enthalten (z. B. 1.05 fuer +5 %).")
    I <- if (is.matrix(inflation)) inflation else matrix((1 + inflation / 100)^(1 / .wd_ppy(frequency)), nrow(R), ncol(R))
    x <- structure(list(returns = R, inflation = I, cape = NULL, base_rate = NULL, frequency = frequency,
                        historical = FALSE, start_dates = NULL, weights = NULL, source = "matrix"),
                   class = "withdrawal_paths")
  }
  ppy <- .wd_ppy(x$frequency)
  R <- x$returns; I <- x$inflation
  if (anyNA(R) || anyNA(I)) stop("Renditen/Inflation enthalten NA.")
  if (!is.null(years)) {
    keep_rows <- seq_len(min(nrow(R), years * ppy))
    R <- R[keep_rows, , drop = FALSE]; I <- I[keep_rows, , drop = FALSE]
    if (!is.null(x$cape)) x$cape <- x$cape[keep_rows, , drop = FALSE]
    if (!is.null(x$base_rate)) x$base_rate <- x$base_rate[keep_rows, , drop = FALSE]
  }
  if (nrow(R) %% ppy != 0) warning("Periodenzahl ist kein Vielfaches eines Jahres; letztes Planjahr unvollstaendig.")
  ny <- ceiling(nrow(R) / ppy)
  if (rule$type == "cape" && is.null(x$cape)) stop("Die CAPE-Regel braucht eine CAPE-Reihe (Argument cape in withdrawal_cohorts/withdrawal_paths).")
  CAPE <- if (!is.null(x$cape)) as.matrix(x$cape) else matrix(0, nrow(R), 0)
  BASE <- if (!is.null(x$base_rate)) as.matrix(x$base_rate)
          else if (is.matrix(base_rate)) base_rate else matrix(base_rate, nrow(R), ncol(R))
  inc <- rep(0, ny)
  for (e in income) {
    yrs <- seq(max(1, e$start %||% 1), min(ny, e$end %||% ny))
    inc[yrs] <- inc[yrs] + e$amount
  }
  rp <- .wd_param_vector(rule, ny)
  t0 <- Sys.time()
  core <- .wd_simulate(R, I, CAPE, BASE, as.integer(ppy), .wd_rules[[rule$type]], rp, timing == "start",
                       start_value, inc, tax_mode == "person", tax_rate / 100, asset_bonus / 100,
                       sparer_pauschbetrag, isTRUE(vorabpauschale), sale_cost / 100, cost_basis / 100,
                       loss_carryforward, isTRUE(keep_paths))
  sp <- core$spending
  w0 <- sp[1, ]
  ce <- apply(sp, 2, function(c) {
    c <- pmax(c, 1e-9 * start_value)
    if (abs(gamma - 1) < 1e-12) exp(mean(log(c))) else mean(c^(1 - gamma))^(1 / (1 - gamma))
  })
  pwr <- if (ppy == 1L || nrow(R) >= ppy) perfect_withdrawal_rate(.annual_real(list(returns = R, inflation = I, frequency = x$frequency))) else NA
  drawdown_spend <- apply(sp, 2, function(c) { m <- cummax(c); max(1 - c / m) })
  paths <- data.frame(
    success = core$failed == 0,
    depletion_year = ceiling(core$depletion_period / ppy),
    terminal_real = core$terminal_real,
    terminal_nominal = core$terminal_nominal,
    first_withdrawal = w0,
    mean_spending = colMeans(sp),
    min_spending = apply(sp, 2, min),
    spending_drawdown = drawdown_spend,
    ce_spending = ce,
    total_spending = colSums(sp),
    taxes = core$taxes_real,
    pwr = pwr)
  if (!is.null(x$start_dates)) paths$start <- x$start_dates
  w <- x$weights %||% rep(1, ncol(R))
  out <- list(paths = paths, spending = sp, planned = core$planned,
              wealth = if (keep_paths) core$wealth else NULL,
              rule = rule, start_value = start_value, frequency = x$frequency, years = ny,
              historical = isTRUE(x$historical), weights = w, tax_mode = tax_mode, gamma = gamma,
              timing = timing, source = x$source, elapsed = as.numeric(difftime(Sys.time(), t0, units = "secs")))
  class(out) <- "SimLevWithdrawal"
  out
}

#' Maximale Anfangsrate fuer eine Ziel-Erfolgsquote
#'
#' Bestimmt per Bisektion die hoechste Entnahmerate (\code{rate} der Regel),
#' bei der der Anteil erfolgreicher Pfade mindestens \code{success} betraegt.
#' Fuer die konstante Regel ohne Steuern entspricht das dem Quantil der
#' Perfect Withdrawal Rate (historisch: Minimum ueber alle Kohorten = SWR).
#'
#' @param x \code{withdrawal_paths} oder Renditematrix.
#' @param rule \code{withdrawal_rule}; \code{rate} wird variiert.
#' @param success Ziel-Erfolgsquote (0..1), z. B. 0.95; 1 = historische SWR.
#' @param lower,upper Suchintervall in Prozent.
#' @param tol Genauigkeit in Prozentpunkten.
#' @param ... weitere Argumente fuer [withdrawal_simulation()].
#' @return Rate in Prozent (Attribut \code{"success"}: erreichte Quote).
#' @export
withdrawal_max_rate <- function(x, rule = withdrawal_rule("constant"), success = 0.95,
                                lower = 0.5, upper = 20, tol = 0.005, ...) {
  f <- function(rate) {
    rl <- rule; rl$rate <- rate
    s <- withdrawal_simulation(x, rl, keep_paths = FALSE, ...)
    stats::weighted.mean(s$paths$success, s$weights)
  }
  if (f(lower) < success) return(structure(NA_real_, success = f(lower)))
  if (f(upper) >= success) return(structure(upper, success = f(upper)))
  while (upper - lower > tol) {
    mid <- (lower + upper) / 2
    if (f(mid) >= success) lower <- mid else upper <- mid
  }
  structure(lower, success = f(lower))
}

#' Methoden fuer Entnahme-Objekte
#'
#' Ausgabe-, Zusammenfassungs- und Grafikmethoden.
#'
#' @param x Ein \code{withdrawal_rule}-, \code{SimLevWithdrawal}- oder Zusammenfassungsobjekt.
#' @param object Ein \code{SimLevWithdrawal}-Objekt.
#' @param probs Quantile bzw. Quantilsbaender.
#' @param ... Weitere Argumente.
#' @return Das Objekt (unsichtbar) bzw. eine Zusammenfassung.
#' @name SimLevWithdrawal-methods
#' @keywords internal
NULL

#' @rdname SimLevWithdrawal-methods
#' @export
summary.SimLevWithdrawal <- function(object, probs = c(0.05, 0.25, 0.5, 0.75, 0.95), ...) {
  p <- object$paths; w <- object$weights
  wq <- function(v) .wquantile(v, w, probs)
  wm <- function(v) stats::weighted.mean(v, w, na.rm = TRUE)
  yrs <- object$years
  pick <- function(y) if (y <= nrow(object$spending)) wq(object$spending[y, ]) else rep(NA, length(probs))
  out <- list(
    rule = object$rule, n_paths = nrow(p), years = yrs, historical = object$historical,
    success_rate = wm(p$success),
    depletion = if (any(!p$success)) .wquantile(p$depletion_year[!p$success], w[!p$success], probs) else NULL,
    terminal_real = wq(p$terminal_real),
    preserve_rate = wm(p$terminal_real >= object$start_value),
    first_withdrawal = wq(p$first_withdrawal),
    mean_spending = wq(p$mean_spending), min_spending = wq(p$min_spending),
    spending_drawdown = wq(p$spending_drawdown), ce_spending = wq(p$ce_spending),
    spending_by_year = rbind(`Jahr 1` = pick(1), `Jahr 10` = pick(10), `Jahr 20` = pick(20), `Jahr 30` = pick(30)),
    taxes = wq(p$taxes), pwr = wq(p$pwr),
    swr = if (object$historical) min(p$pwr, na.rm = TRUE) else .wquantile(p$pwr, w, 0.05),
    probs = probs, start_value = object$start_value, tax_mode = object$tax_mode, gamma = object$gamma)
  class(out) <- "summary.SimLevWithdrawal"
  out
}

#' @rdname SimLevWithdrawal-methods
#' @export
print.summary.SimLevWithdrawal <- function(x, ...) {
  q <- function(v, pct = FALSE) paste(vapply(v, function(z) if (is.na(z)) sprintf("%10s", "\u2013")
                                             else if (pct) sprintf("%9.2f%%", z) else sprintf("%10.0f", z), ""), collapse = "")
  hdr <- paste(sprintf("%10s", sprintf("q%02d", round(100 * x$probs))), collapse = "")
  cat("\n\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\n")
  cat("                 SimLev Entnahme-Simulation                    \n")
  cat("\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\n\n")
  cat(sprintf("  Regel:            %s\n", .wd_labels[[x$rule$type]]))
  cat(sprintf("  Pfade:            %d %s ueber %d Jahre, Startvermoegen %.0f\n", x$n_paths,
              if (x$historical) "historische Kohorten" else "Pfade", x$years, x$start_value))
  cat(sprintf("  Steuern:          %s\n\n", if (x$tax_mode == "person") "deutsche Privatperson (vereinfacht)" else "keine"))
  cat(sprintf("  Erfolgsquote:     %.1f %% (Depot reicht fuer alle geplanten Entnahmen)\n", 100 * x$success_rate))
  cat(sprintf("  Kapitalerhalt:    %.1f %% (reales Endvermoegen >= Start)\n", 100 * x$preserve_rate))
  if (!is.null(x$depletion)) cat(sprintf("  Erschoepfung:     Median im Jahr %.0f (bei gescheiterten Pfaden)\n", x$depletion[ceiling(length(x$probs) / 2)]))
  cat(sprintf("  %s: %.2f %% der Startsumme\n",
              if (x$historical) "SWR historisch (min. PWR)" else "SWR (5-%-Quantil PWR)", x$swr))
  cat(sprintf("\n  %-28s%s\n", "real, in Startkaufkraft", hdr))
  cat(sprintf("  %-28s%s\n", "Endvermoegen", q(x$terminal_real)))
  cat(sprintf("  %-28s%s\n", "Entnahme Jahr 1", q(x$first_withdrawal)))
  for (r in rownames(x$spending_by_year)) cat(sprintf("  %-28s%s\n", paste("Konsum", r), q(x$spending_by_year[r, ])))
  cat(sprintf("  %-28s%s\n", "Konsum Durchschnitt", q(x$mean_spending)))
  cat(sprintf("  %-28s%s\n", "Konsum Minimum", q(x$min_spending)))
  cat(sprintf("  %-28s%s\n", sprintf("Sicherheitsaequiv. (g=%g)", x$gamma), q(x$ce_spending)))
  cat(sprintf("  %-28s%s\n", "Max. Konsumrueckgang", q(100 * x$spending_drawdown, TRUE)))
  cat(sprintf("  %-28s%s\n", "PWR", q(x$pwr, TRUE)))
  if (x$tax_mode == "person") cat(sprintf("  %-28s%s\n", "Steuern gesamt", q(x$taxes)))
  cat("\n\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\n")
  invisible(x)
}

#' @rdname SimLevWithdrawal-methods
#' @export
print.SimLevWithdrawal <- function(x, ...) { print(summary(x, ...)); invisible(x) }

#' @rdname SimLevWithdrawal-methods
#' @export
plot.SimLevWithdrawal <- function(x, probs = c(0.05, 0.25, 0.5, 0.75, 0.95), ...) {
  old <- graphics::par(no.readonly = TRUE); on.exit(graphics::par(old))
  graphics::par(mfrow = c(1, if (is.null(x$wealth)) 1 else 2), mar = c(4, 4.6, 2.5, 1),
                mgp = c(2.9, 0.7, 0), las = 1)
  fan <- function(M, main, xs) {
    Q <- apply(M, 1, function(r) .wquantile(r, x$weights, probs)) / 1000
    plot(range(xs), range(Q, finite = TRUE), type = "n", xlab = "Jahr",
         ylab = "Tsd. (Startkaufkraft)", main = main, ...)
    k <- length(probs)
    cols <- grDevices::adjustcolor("#2C6E9B", alpha.f = 0.18)
    for (i in seq_len(floor(k / 2))) graphics::polygon(c(xs, rev(xs)), c(Q[i, ], rev(Q[k + 1 - i, ])), col = cols, border = NA)
    graphics::lines(xs, Q[ceiling(k / 2), ], col = "#2C6E9B", lwd = 2)
  }
  if (!is.null(x$wealth)) fan(x$wealth, "Reales Vermoegen", 0:(nrow(x$wealth) - 1))
  fan(x$spending, "Realer Konsum je Jahr", seq_len(nrow(x$spending)))
  invisible(x)
}

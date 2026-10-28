# =============================================================================
#  sensitivity.R  —  Parameterstudien um simulation()
# -----------------------------------------------------------------------------
#  sensitivity_grid()         beliebige simulation()-Argumente im Raster
#  sensitivity_rebalancing()  Rebalancing-Frequenz, Versatz und Baender
#  planning_lumpsum_vs_dca()           Einmalanlage gegen gestreckten Einstieg
#  series_leverage()         Hebelreihe aus einem Index (MSCI-Formel)
#  sensitivity_leverage()     Kennzahlen ueber den Hebel, optimaler Hebel
# =============================================================================

#' simulation() ueber ein Parameterraster
#'
#' Ruft [simulation()] fuer jede Kombination von \code{grid} auf denselben
#' Daten und derselben Strategie auf und sammelt die Kennzahlen in einem
#' data.frame (eine Zeile je Lauf). Grundlage der speziellen Studien in
#' diesem Abschnitt ([sensitivity_rebalancing()], [sensitivity_leverage()]).
#'
#' @param data,strategy Wie in [simulation()]: data.frame mit Spalte
#'   \code{date} und Kursspalten (Niveaus) bzw. Strategie aus
#'   [create_strategy()].
#' @param grid Benannte Liste von Argumentwerten fuer [simulation()]; alle
#'   Kombinationen werden gerechnet, z. B.
#'   \code{list(balance_unit = c("month", "year"), balance_thresh = c(5, 10))}.
#'   Alternativ ein data.frame mit einer Zeile je Lauf. Listen-Spalten
#'   (z. B. \code{split_thresh}) sind erlaubt. \code{NA} laesst das Argument
#'   weg (Standardwert von [simulation()] bzw. Wert aus \code{sim_args}).
#' @param sim_args Benannte Liste gemeinsamer Argumente fuer alle Laeufe
#'   (Standard \code{list()}); Werte aus \code{grid} haben Vorrang.
#' @param metrics Funktion \code{SimLevResult -> benannter numerischer Vektor}
#'   (Standard [bootstrap_study_metrics()]).
#' @param cores Anzahl Prozesse (Standard 1; Fork auf Unix, PSOCK auf Windows).
#' @param keep_results Logisch (Standard \code{FALSE}): Ergebnisse der Laeufe
#'   zusaetzlich als Attribut \code{results} zurueckgeben.
#' @return data.frame: Rasterspalten (Listen-Spalten als Text "a/b"), die
#'   Kennzahlen aus \code{metrics} (bei [bootstrap_study_metrics()] z. B. \code{cagr}
#'   als Anteil; mit Sparplan geldgewichtet, XIRR) und, falls ein Lauf
#'   fehlschlug, eine Spalte \code{error} (Fehlermeldung, Kennzahlen dann \code{NA}); schlagen alle Laeufe fehl,
#'   ein Fehler mit den Meldungen der Laeufe. Bei
#'   \code{keep_results = TRUE} Attribut \code{results} (Liste der
#'   \code{SimLevResult}).
#' @examples
#' set.seed(1)
#' d <- data.frame(date = seq.Date(as.Date("2015-01-01"), by = "day", length.out = 1500))
#' d$A <- 100 * cumprod(1 + rnorm(1500, 3e-4, 0.01)); d$B <- 100 * cumprod(1 + rnorm(1500, 1e-4, 0.004))
#' st <- create_strategy(A = asset_config("etf", "bnh", 0.6), B = asset_config("etf", "bnh", 0.4))
#' sensitivity_grid(d, st, list(balance_unit = c("month", "year")),
#'                  sim_args = list(balance_mode = TRUE, balance_span = 1))[, c("balance_unit", "cagr", "trades")]
#' @seealso [sensitivity_rebalancing()], [sensitivity_leverage()],
#'   [bootstrap_study_metrics()], [simulation()]
#' @export
sensitivity_grid <- function(data, strategy, grid, sim_args = list(), metrics = bootstrap_study_metrics,
                             keep_results = FALSE, cores = 1L) {
  design <- if (is.data.frame(grid)) grid else expand.grid(grid, stringsAsFactors = FALSE, KEEP.OUT.ATTRS = FALSE)
  if (!nrow(design)) stop("Leeres Raster.")
  .sim_check_names(names(design), "sensitivity_grid")   # Argumente von simulation() bzw. Pfade wie "dca.value"
  sim_args <- .sim_args_set(list(), sim_args, "sensitivity_grid")
  run <- function(i) {
    a <- lapply(design[i, , drop = FALSE], function(v) if (is.list(v)) v[[1]] else v)
    a <- a[!vapply(a, function(v) length(v) == 1L && is.atomic(v) && is.na(v), TRUE)]   # NA = Argument weglassen
    res <- tryCatch(suppressWarnings(suppressMessages(.sim_call(data, strategy, .sim_args_set(sim_args, a, "sensitivity_grid")))),
                    error = function(e) e)
    if (inherits(res, "error")) return(list(m = NULL, err = conditionMessage(res), res = NULL))
    list(m = metrics(res), err = NA_character_, res = if (keep_results) res else NULL)
  }
  out <- .par_lapply(seq_len(nrow(design)), run, cores)
  okm <- Filter(Negate(is.null), lapply(out, `[[`, "m"))
  if (!length(okm)) {
    err <- table(vapply(out, `[[`, "", "err"))
    stop(sprintf("sensitivity_grid: Alle %d L\u00e4ufe fehlgeschlagen: %s", length(out),
                 paste(sprintf("%s (%d x)", names(err), as.integer(err)), collapse = "; ")), call. = FALSE)
  }
  mnames <- names(okm[[1]])
  M <- t(vapply(out, function(o) if (is.null(o$m)) rep(NA_real_, length(mnames)) else o$m[mnames], numeric(length(mnames))))
  if (length(mnames) == 1) M <- t(M)
  colnames(M) <- mnames
  disp <- design
  for (k in names(disp)) if (is.list(disp[[k]])) disp[[k]] <- vapply(disp[[k]], function(v) paste(v, collapse = "/"), "")
  tab <- data.frame(disp, M, error = vapply(out, `[[`, "", "err"), check.names = FALSE, stringsAsFactors = FALSE)
  if (all(is.na(tab$error))) tab$error <- NULL
  if (keep_results) attr(tab, "results") <- lapply(out, `[[`, "res")
  tab
}

#' Rebalancing-Sensitivitaet
#'
#' Vergleicht Rebalancing-Frequenzen, Versatz vor dem Periodenende und
#' Toleranzbaender (absolut oder relativ) fuer eine Strategie, wie die
#' Rebalancing-Sensitivity von testfol.io. Jede Kombination aus
#' \code{frequencies}, \code{offsets} und \code{bands} wird mit [simulation()]
#' (\code{balance_mode = TRUE}) gerechnet. Baender werden an den
#' Kalenderterminen der jeweiligen Frequenz geprueft. Termine, die nicht als
#' Zeile in \code{data} vorkommen (bei Handelstagsdaten z. B. Wochenenden),
#' entfallen.
#'
#' @inheritParams sensitivity_grid
#' @param frequencies Benannte Liste von \code{c(unit, span)} mit
#'   \code{unit} "month", "quarter" oder "year" und \code{span} = Anzahl
#'   Einheiten zwischen den Terminen (\code{balance_unit} und
#'   \code{balance_span} in [simulation()]). Standard: monatlich,
#'   zweimonatlich, quartalsweise, viermonatlich, halbjaehrlich, jaehrlich
#'   (Namen monthly, bimonthly, quarterly, four_monthly, semiannual, yearly).
#' @param offsets Numerischer Vektor: Kalendertage vor dem Ende des Monats,
#'   Dreimonatsblocks bzw. Jahres, in dem der Termin liegt (0 = letzter Tag;
#'   \code{balance_anchor = "end"}, \code{balance_days = offset + 1}).
#'   \code{NULL} (Standard) rebalanciert am Periodenanfang.
#' @param bands Toleranzbaender in Prozent (5 = 5 Prozent); \code{NA} (Standard) =
#'   an jedem Termin rebalancieren. Mehrere Werte, auch gemischt mit \code{NA},
#'   sind moeglich.
#' @param band_type "absolute" (Standard; Prozentpunkte Abweichung vom
#'   Zielgewicht) oder "relative" (Prozent des Zielgewichts), siehe
#'   \code{balance_thresh_type} in [simulation()].
#' @param include_none Logisch (Standard \code{TRUE}): zusaetzlich einen Lauf
#'   ohne Rebalancing (Zeile \code{frequency = "none"}).
#' @return data.frame der Klasse \code{SimLevSensitivity} mit den Spalten
#'   \code{frequency}, \code{offset}, \code{band}, \code{band_type} und den
#'   Kennzahlen aus \code{metrics}; fehlgeschlagene Laeufe fehlen. Attribut
#'   \code{kind = "rebalancing"}. Ausgabe und Grafik ueber \code{print()} und
#'   \code{plot()}. Mit Sparplan (\code{sim_args}) ist \code{cagr}
#'   geldgewichtet (XIRR); \code{print()} weist darauf hin.
#' @examples
#' set.seed(1)
#' d <- data.frame(date = seq.Date(as.Date("2015-01-01"), by = "day", length.out = 1500))
#' d$A <- 100 * cumprod(1 + rnorm(1500, 3e-4, 0.01)); d$B <- 100 * cumprod(1 + rnorm(1500, 1e-4, 0.004))
#' st <- create_strategy(A = asset_config("etf", "bnh", 0.6), B = asset_config("etf", "bnh", 0.4))
#' sensitivity_rebalancing(d, st,
#'   frequencies = list(monthly = c("month", 1), yearly = c("year", 1)), bands = c(NA, 5))
#' sensitivity_rebalancing(d, st, frequencies = list(quarterly = c("quarter", 1)),
#'   offsets = c(0, 5), include_none = FALSE)
#' @seealso [sensitivity_grid()], [simulation()]
#' @export
sensitivity_rebalancing <- function(data, strategy,
                                    frequencies = list(monthly = c("month", 1), bimonthly = c("month", 2),
                                                       quarterly = c("quarter", 1), four_monthly = c("month", 4),
                                                       semiannual = c("month", 6), yearly = c("year", 1)),
                                    offsets = NULL, bands = NA, band_type = c("absolute", "relative"),
                                    include_none = TRUE, sim_args = list(), metrics = bootstrap_study_metrics, cores = 1L) {
  band_type <- match.arg(band_type)
  sim_args <- .sim_args_set(list(), sim_args, "sensitivity_rebalancing")
  rows <- list()
  for (fn in names(frequencies)) {
    f <- frequencies[[fn]]
    for (off in (if (is.null(offsets)) NA else offsets)) for (b in bands) {
      # Rebalancing ueber Pfade: weitere Angaben eines rebalance_plan() aus sim_args bleiben erhalten
      a <- list(rebalance.unit = f[[1]], rebalance.span = as.numeric(f[[2]]), rebalance.thresh_type = band_type)
      if (!is.na(off)) { a$rebalance.anchor <- "end"; a$rebalance.days <- off + 1 }
      if (!is.na(b)) a$rebalance.thresh <- b
      rows[[length(rows) + 1L]] <- list(label = data.frame(frequency = fn, offset = off, band = b, band_type = band_type),
                                         args = a)
    }
  }
  if (include_none) rows[[length(rows) + 1L]] <- list(label = data.frame(frequency = "none", offset = NA, band = NA, band_type = NA),
                                                      args = list(rebalance = NULL))
  run <- function(i) {
    res <- tryCatch(suppressWarnings(suppressMessages(
      .sim_call(data, strategy, .sim_args_set(sim_args, rows[[i]]$args, "sensitivity_rebalancing")))), error = function(e) e)
    if (inherits(res, "error")) return(conditionMessage(res))
    metrics(res)
  }
  out <- .par_lapply(seq_along(rows), run, cores)
  ok <- !vapply(out, is.character, TRUE)
  if (!any(ok)) { err <- table(unlist(out))
    stop(sprintf("sensitivity_rebalancing: Alle %d L\u00e4ufe fehlgeschlagen: %s", length(out),
                 paste(sprintf("%s (%d x)", names(err), as.integer(err)), collapse = "; ")), call. = FALSE) }
  M <- do.call(rbind, out[ok])
  tab <- data.frame(do.call(rbind, lapply(rows[ok], `[[`, "label")), M, check.names = FALSE, stringsAsFactors = FALSE)
  rownames(tab) <- NULL
  class(tab) <- c("SimLevSensitivity", "data.frame")
  attr(tab, "kind") <- "rebalancing"
  tab
}

#' Einmalanlage gegen gestreckten Einstieg (Lump Sum vs. DCA)
#'
#' Vergleicht fuer rollierende Starttermine (jeweils am Monatsersten) die
#' sofortige Anlage eines Betrags mit einem Einstieg in \code{months} gleichen
#' Monatsraten. Verglichen wird das Vermoegen nach \code{horizon} Jahren.
#'
#' Die Einmalanlage wird ueber den ganzen Horizont mit [simulation()]
#' gerechnet, der gestreckte Einstieg ueber die \code{months} Monate der
#' Einstiegsphase (Sparplan). Danach wird das DCA-Depot fortgeschrieben:
#' \describe{
#'   \item{exakt}{Handelt die Strategie nach der Einstiegsphase nicht mehr
#'     (in der Einmalanlage bleibt die Stueckzahl jedes Assets bis zum
#'     Horizont gleich, z. B. Buy-and-Hold ohne Rebalancing, ohne Steuern),
#'     haelt auch das DCA-Depot seine Stueckzahlen: Endwert = Summe der
#'     Stueckzahlen am Ende der Einstiegsphase x Kurs am Horizont plus Cash.
#'     Jedes Asset behaelt so seine eigenen Gewichte.}
#'   \item{Naeherung}{Sonst (Rebalancing, Signale, Steuern mit
#'     Vorabpauschale oder Kosten, die Stueck verkaufen) waechst das DCA-Depot
#'     mit dem zeitgewichteten Index der Einmalanlage ([result_index()]),
#'     als haette es ab dem Ende der Einstiegsphase deren Gewichte; mit
#'     \code{tax_mode = "person"} erscheint dazu eine Warnung.}
#' }
#' Welche Variante verwendet wurde, steht je Start in der Spalte
#' \code{exact}.
#'
#' Als Starttermine dienen nur Monatserste, die als Zeile in \code{data}
#' vorkommen (bei Handelstagsdaten entfallen Monate, deren Erster kein
#' Handelstag ist), und nur solche, nach denen noch \code{horizon} Jahre
#' Daten folgen.
#'
#' @inheritParams sensitivity_grid
#' @param amount Anlagebetrag in Waehrungseinheiten (Standard 10000); bei DCA
#'   in \code{months} Raten von \code{amount / months} aufgeteilt.
#' @param months Anzahl Monatsraten des gestreckten Einstiegs (Standard 12).
#' @param horizon Vergleichshorizont in Jahren ab Start (Standard 10).
#' @param step Jeder wievielte moegliche Starttermin verwendet wird (Standard
#'   1 = jeder Monat; 12 = jaehrlich).
#' @param sim_args Benannte Liste weiterer Argumente fuer [simulation()]
#'   (z. B. \code{tax_mode}); \code{start_value}, \code{dca_mode},
#'   \code{dca_value}, \code{dca_span}, \code{dca_unit} und \code{dca_skip}
#'   setzt die Funktion selbst (in \code{sim_args} ein Fehler).
#' @return data.frame der Klasse \code{SimLevLumpSum} mit einer Zeile je
#'   Start: \code{start} (Datum), \code{lump_sum} und \code{dca}
#'   (Endvermoegen nach \code{horizon} Jahren in Waehrungseinheiten),
#'   \code{advantage} (Lump Sum / DCA - 1, als Anteil) und \code{exact}
#'   (logisch: DCA-Depot exakt ueber Stueckzahlen fortgeschrieben, siehe
#'   oben). Attribut
#'   \code{summary}: \code{win_rate} (Anteil der Starttermine mit Vorsprung
#'   der Einmalanlage), \code{mean_advantage}, \code{median_advantage},
#'   \code{mlsa} (mittlerer Vorsprung bei Gewinn) und \code{mlsd} (mittlerer
#'   Rueckstand bei Verlust), alle als Anteil; Attribut \code{settings}.
#' @examples
#' set.seed(1); n <- 6 * 365
#' d <- data.frame(date = seq.Date(as.Date("2010-01-01"), by = "day", length.out = n))
#' d$ETF <- 100 * cumprod(1 + rnorm(n, 3e-4, 0.01))
#' ld <- planning_lumpsum_vs_dca(d, create_strategy(ETF = asset_config("etf", "bnh")),
#'   amount = 12000, months = 12, horizon = 3, step = 6)
#' ld
#' attr(ld, "summary")
#' @seealso [simulation()], [sensitivity_grid()]
#' @export
planning_lumpsum_vs_dca <- function(data, strategy, amount = 10000, months = 12, horizon = 10, step = 1,
                           sim_args = list(), cores = 1L) {
  nm <- names(sim_args) %||% character(0)
  own <- nm[nm %in% c("start_value", "dca", "dca_mode", "dca_value", "dca_span", "dca_unit", "dca_skip") | startsWith(nm, "dca.")]
  if (length(own)) stop(sprintf("planning_lumpsum_vs_dca setzt %s selbst; aus sim_args entfernen (Betrag \u00fcber amount, Raten \u00fcber months).",
                                paste(own, collapse = ", ")))
  sim_args <- .sim_args_set(list(), sim_args, "planning_lumpsum_vs_dca")
  data$date <- .to_date(data$date, "planning_lumpsum_vs_dca: data$date")
  data <- data[order(data$date), , drop = FALSE]
  d <- data$date
  if (!is.null(sim_args$tax) && is.null(sim_args$funds))
    warning("Mit Steuern ist die Fortschreibung des DCA-Depots nach der Einstiegsphase eine N\u00e4herung (Index der Einmalanlage).")
  firsts <- d[format(d, "%d") == "01"]
  last_ok <- seq.Date(max(d), by = paste0("-", horizon, " years"), length.out = 2)[2]
  starts <- firsts[firsts <= last_ok]
  starts <- starts[seq(1, length(starts), by = step)]
  if (!length(starts)) stop("Historie zu kurz f\u00fcr den Horizont.")
  run <- function(s) {
    e <- seq.Date(s, by = paste(horizon, "years"), length.out = 2)[2] - 1
    e_dca <- seq.Date(s, by = paste(months, "months"), length.out = 2)[2] - 1
    w <- data[d >= s & d <= e, , drop = FALSE]
    ls <- suppressWarnings(suppressMessages(.sim_call(w, strategy, c(list(start_value = amount), sim_args))))
    wd <- data[d >= s & d <= e_dca, , drop = FALSE]
    dca <- suppressWarnings(suppressMessages(.sim_call(wd, strategy, c(list(start_value = amount / months,
              dca = dca_plan(value = amount / months, span = 1, unit = "month", skip = TRUE)), sim_args))))
    ix <- result_index(ls)
    k <- match(max(wd$date), ix$date)
    # Kurse der Assets an den Ergebnistagen (letzter Datenwert bis zum Tag), Stueck = Wert / Kurs
    assets <- names(dca$report)
    px <- function(a, dates) {
      v <- .fill_na(as.numeric(data[[a]]), "locf"); v[findInterval(as.numeric(dates), as.numeric(d))] }
    rows <- k:nrow(ix)
    const <- all(vapply(assets, function(a) {
      p <- px(a, ix$date[rows]); u <- ls$report[[a]]$worth[rows] / p
      all(is.finite(u)) && all(abs(u - u[1]) <= 1e-9 * max(1, abs(u[1])))
    }, TRUE))
    if (const) {                       # Einmalanlage handelt nicht mehr: DCA-Depot haelt seine Stueckzahlen
      nd <- length(dca$worth)
      dca_end <- sum(vapply(assets, function(a) {
        dca$report[[a]]$worth[nd] / px(a, dca$dates[nd]) * px(a, ix$date[nrow(ix)]) + dca$report[[a]]$money[nd] }, 0))
    } else dca_end <- utils::tail(dca$worth, 1) * ix$value[nrow(ix)] / ix$value[k]
    c(lump_sum = utils::tail(ls$worth, 1), dca = dca_end, exact = const)
  }
  res <- .par_lapply(as.list(starts), run, cores)
  tab <- data.frame(start = starts, do.call(rbind, res))
  tab$exact <- as.logical(tab$exact)
  tab$advantage <- tab$lump_sum / tab$dca - 1
  tab <- tab[c("start", "lump_sum", "dca", "advantage", "exact")]
  win <- tab$advantage > 0
  structure(tab, class = c("SimLevLumpSum", "data.frame"),
            summary = c(win_rate = mean(win), mean_advantage = mean(tab$advantage), median_advantage = stats::median(tab$advantage),
                        mlsa = if (any(win)) mean(tab$advantage[win]) else NA_real_,
                        mlsd = if (any(!win)) mean(tab$advantage[!win]) else NA_real_),
            settings = list(amount = amount, months = months, horizon = horizon))
}

#' @rdname SimLevAnalysis-methods
#' @export
print.SimLevLumpSum <- function(x, ...) {
  s <- attr(x, "summary"); st <- attr(x, "settings")
  cat(sprintf("Lump Sum vs. DCA: %d Starttermine, %s in %d Monatsraten, Horizont %g Jahre\n",
              nrow(x), formatC(st$amount, format = "f", digits = 0, big.mark = " "), st$months, st$horizon))
  cat(sprintf("  Einmalanlage vorn:          %.1f %% der Starttermine\n", 100 * s["win_rate"]))
  cat(sprintf("  Vorsprung Mittel / Median:  %+.2f %% / %+.2f %%\n", 100 * s["mean_advantage"], 100 * s["median_advantage"]))
  cat(sprintf("  MLSA (wenn vorn):           %+.2f %%\n", 100 * s["mlsa"]))
  cat(sprintf("  MLSD (wenn hinten):         %+.2f %%\n", 100 * s["mlsd"]))
  invisible(x)
}

#' Gehebelte Reihe aus einem Index erzeugen
#'
#' Bildet eine taeglich zurueckgesetzte Hebelreihe (Niveau) nach der
#' MSCI-Formel plus Fondskosten (wie die Ticker-Parameter L, E, SP und FR bei
#' testfol.io):
#' \deqn{r = L x + (1 - L) i T/360 - TER\cdot T/365 - s\cdot m(L) T/360}
#' mit Indexrendite \eqn{x}, Kalendertagen \eqn{T} seit der Vorzeile,
#' \eqn{m(L) = \max(L-1, 0) + \max(-L, 0)} und \eqn{i}, \eqn{TER}, \eqn{s}
#' als Anteil (Prozentangabe / 100); der Zins gilt fuer den Tag der Rendite.
#' Das Ergebnis kann als Kursspalte in [simulation()] dienen; fuer die
#' Anpassung an ein echtes Produkt siehe [backcast_fit()].
#'
#' @param data data.frame mit Spalte \code{date} und der Indexspalte.
#' @param index Spaltenname des Index (Niveau, nicht Rendite; Luecken werden
#'   mit dem letzten Wert gefuellt).
#' @param leverage Hebel L als Zahl (Standard 2; negativ fuer Short).
#' @param rate Finanzierungszins in Prozent p. a. (Standard 0): Skalar,
#'   Spaltenname, Vektor der Laenge \code{nrow(data)},
#'   \code{data.frame(date, value)} oder benannter Vektor mit Datumsnamen.
#' @param expense TER in Prozent p. a. (Standard 0).
#' @param spread Spread auf den finanzierten bzw. leerverkauften Anteil
#'   \eqn{m(L)} in Prozent p. a. (Standard 0).
#' @param start Startwert der Reihe in der ersten Zeile (Standard 100).
#' @return Numerischer Vektor (Niveau, Laenge \code{nrow(data)}); faellt eine
#'   Tagesrendite auf -100 Prozent oder darunter, bleibt die Reihe ab dort bei 0.
#' @examples
#' set.seed(1)
#' x <- data.frame(date = seq.Date(as.Date("2015-01-01"), by = "day", length.out = 1500))
#' x$idx <- 100 * cumprod(1 + rnorm(1500, 3e-4, 0.01))
#' x$zins <- 2                                    # Prozent p. a.
#' x$l2 <- series_leverage(x, "idx", leverage = 2, rate = "zins", expense = 0.6, spread = 0.3)
#' x$short <- series_leverage(x, "idx", leverage = -1, rate = "zins", expense = 0.6)
#' tail(x, 2)
#' @seealso [sensitivity_leverage()], [backcast_fit()], [bootstrap_config()]
#' @export
series_leverage <- function(data, index, leverage = 2, rate = 0, expense = 0, spread = 0, start = 100) {
  idx <- .fill_na(as.numeric(data[[index]]), "locf")
  dd <- c(1, as.numeric(diff(.to_date(data$date, "data$date"))))
  x <- c(0, idx[-1] / idx[-length(idx)] - 1)
  rt <- .resolve_series(rate, data, "rate")
  m <- max(leverage - 1, 0) + max(-leverage, 0)
  r <- leverage * x + (1 - leverage) * rt / 100 * dd / 360 - expense / 100 * dd / 365 - spread / 100 * m * dd / 360
  r[1] <- 0
  ko <- which(r <= -1)
  if (length(ko)) r[ko[1]:length(r)] <- -1
  v <- start * cumprod(1 + r)
  v[v < 0] <- 0
  v
}

#' Kennzahlen ueber den Hebel
#'
#' Erzeugt fuer jeden Hebel eine Reihe mit [series_leverage()], simuliert
#' sie als Buy-and-Hold (oder mit einer eigenen Strategie fuer das Asset
#' \code{"LEV"}) und bestimmt den Hebel mit der hoechsten CAGR bzw. Sharpe
#' Ratio, wie die LETF-Analyse von testfol.io. An [simulation()] wird ein
#' data.frame mit den Spalten \code{date} und \code{LEV} uebergeben.
#'
#' @inheritParams series_leverage
#' @param leverages Numerischer Vektor der zu pruefenden Hebel (Standard
#'   \code{seq(0.5, 4, by = 0.25)}).
#' @param strategy Optional Strategie mit dem Asset \code{"LEV"}; \code{NULL}
#'   (Standard) = Buy-and-Hold-ETF mit 30 Prozent Teilfreistellung
#'   (\code{asset_config("etf", "bnh", partial_exemption = 30)}).
#' @inheritParams sensitivity_grid
#' @return data.frame der Klasse \code{SimLevSensitivity} mit \code{leverage}
#'   und den Kennzahlen aus \code{metrics} (fehlgeschlagene Laeufe fehlen);
#'   Attribut \code{optimal} (benannter Vektor \code{cagr}, \code{sharpe}:
#'   Hebel mit maximaler CAGR bzw. Sharpe Ratio) und \code{kind = "leverage"}.
#'   Mit Sparplan (\code{sim_args}) ist \code{cagr} geldgewichtet (XIRR).
#'   Ausgabe und Grafik ueber \code{print()} und \code{plot()}.
#' @examples
#' set.seed(1)
#' x <- data.frame(date = seq.Date(as.Date("2015-01-01"), by = "day", length.out = 1500))
#' x$idx <- 100 * cumprod(1 + rnorm(1500, 3e-4, 0.01))
#' lv <- sensitivity_leverage(x, "idx", leverages = c(1, 1.5, 2, 3), rate = 2, expense = 0.5)
#' lv
#' attr(lv, "optimal")
#' @seealso [series_leverage()], [sensitivity_grid()], [simulation()]
#' @export
sensitivity_leverage <- function(data, index, leverages = seq(0.5, 4, by = 0.25), rate = 0, expense = 0,
                                 spread = 0, strategy = NULL, sim_args = list(), metrics = bootstrap_study_metrics, cores = 1L) {
  strategy <- strategy %||% create_strategy(LEV = asset_config("etf", "bnh", partial_exemption = 30))
  sim_args <- .sim_args_set(list(), sim_args, "sensitivity_leverage")
  run <- function(L) {
    df <- data.frame(date = .to_date(data$date, "data$date"), LEV = series_leverage(data, index, L, rate, expense, spread))
    if (any(df$LEV <= 0)) df$LEV[df$LEV <= 0] <- 1e-8
    res <- tryCatch(suppressWarnings(suppressMessages(.sim_call(df, strategy, sim_args))), error = function(e) NULL)
    if (is.null(res)) return(NULL)
    metrics(res)
  }
  out <- .par_lapply(as.list(leverages), run, cores)
  ok <- !vapply(out, is.null, TRUE)
  tab <- data.frame(leverage = leverages[ok], do.call(rbind, out[ok]), check.names = FALSE)
  class(tab) <- c("SimLevSensitivity", "data.frame")
  attr(tab, "kind") <- "leverage"
  attr(tab, "optimal") <- c(cagr = tab$leverage[which.max(tab$cagr)],
                            sharpe = if ("sharpe" %in% names(tab)) tab$leverage[which.max(tab$sharpe)] else NA)
  tab
}

#' @rdname SimLevAnalysis-methods
#' @export
plot.SimLevSensitivity <- function(x, metric = "cagr", ...) {
  old <- graphics::par(no.readonly = TRUE); on.exit(graphics::par(old))
  graphics::par(mar = c(4, 4.6, 2.5, 1), mgp = c(2.9, 0.7, 0), las = 1)
  kind <- attr(x, "kind") %||% "grid"
  y <- x[[metric]] * (if (metric %in% c("cagr", "ttwror", "max_drawdown", "avg_drawdown")) 100 else 1)
  if (kind == "leverage") {
    plot(x$leverage, y, type = "b", pch = 19, col = "#2C6E9B", xlab = "Hebel", ylab = metric,
         main = sprintf("%s nach Hebel", metric), ...)
    graphics::abline(v = x$leverage[which.max(x[[metric]])], lty = 3, col = "#B5562B")
  } else {
    lab <- paste(x$frequency, ifelse(is.na(x$band), "", paste0("\u00B1", x$band)),
                 ifelse(is.na(x$offset), "", paste0("-", x$offset, "d")))
    graphics::par(mar = c(4, 9, 2.5, 1))
    graphics::barplot(rev(y), names.arg = rev(lab), horiz = TRUE, col = "#2C6E9B", border = NA,
                      xlab = metric, main = sprintf("Rebalancing-Varianten: %s", metric), cex.names = 0.7, ...)
  }
  invisible(x)
}

#' @rdname SimLevAnalysis-methods
#' @export
print.SimLevSensitivity <- function(x, ...) {
  keep <- intersect(c("frequency", "offset", "band", "band_type", "leverage", "cagr", "ttwror", "max_drawdown",
                      "sharpe", "ulcer_index", "taxes", "trades"), names(x))
  y <- as.data.frame(unclass(x))[, keep, drop = FALSE]
  # Platz sparen: TTWROR nur zeigen, wenn sie von der CAGR abweicht; konstanten Bandtyp weglassen
  if (all(c("cagr", "ttwror") %in% names(y)) && isTRUE(all.equal(y$cagr, y$ttwror))) y$ttwror <- NULL
  bt <- if ("band_type" %in% names(y)) unique(y$band_type[!is.na(y$band)]) else character(0)
  if ("band_type" %in% names(y) && length(bt) <= 1) {
    y$band_type <- NULL
    if (length(bt) == 1) cat(sprintf("Toleranzb\u00e4nder: %s\n", if (bt == "relative") "relativ (% des Zielgewichts)" else "absolut (Prozentpunkte)"))
  }
  if ("band" %in% names(y)) y$band <- ifelse(is.na(y$band), "-", format(y$band))
  for (k in intersect(c("cagr", "ttwror", "max_drawdown"), names(y))) y[[k]] <- sprintf("%.2f %%", 100 * y[[k]])
  for (k in intersect(c("sharpe", "ulcer_index"), names(y))) y[[k]] <- sprintf("%.3f", y[[k]])
  for (k in intersect(c("taxes", "trades"), names(y))) y[[k]] <- sprintf("%.1f", y[[k]])
  print(y, row.names = FALSE)
  if ("cagr" %in% names(y)) cat("cagr: mit Sparplan geldgewichtet (XIRR), sonst CAGR des Depotwerts\n")
  if (!is.null(attr(x, "optimal"))) cat(sprintf("Optimaler Hebel: CAGR %.2f, Sharpe %.2f\n", attr(x, "optimal")[1], attr(x, "optimal")[2]))
  invisible(x)
}

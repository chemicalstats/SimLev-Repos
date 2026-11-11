# =============================================================================
#  param_search.R  —  Parametersuche ueber Strategie- und Simulationsraeume
# -----------------------------------------------------------------------------
#  param_space() / param_range()   Suchraum (diskret oder kontinuierlich)
#  param_search()                  Raster, Zufallssuche oder Latin Hypercube;
#                                  ruft simulation() je Punkt auf, speichert
#                                  Kennzahlen und taegliche TWR-Renditen
#  param_plateau()                       Nachbarschafts-Glaettung der Zielgroesse
#                                  (robuste Wahl statt Spitze)
#
#  Die gespeicherten Renditen sind die Grundlage fuer overfit_pbo(), sharpe_deflated()
#  und overfit_walk_forward() (overfitting.R). Strategien werden ueber eine
#  'builder'-Funktion beschrieben, die aus einem Parametersatz dieselbe
#  Spezifikation liefert wie ein Element von bootstrap_study(strategies = ...):
#  list(strategy, signal, args, map). Damit laesst sich jeder Rasterpunkt ohne
#  Umbau auch auf Bootstrap-Pfaden pruefen (param_bootstrap()).
# =============================================================================

#' Suchraum fuer param_search()
#'
#' \code{param_space()} beschreibt den Suchraum fuer [param_search()]: je
#' Parameter eine benannte Dimension mit diskreten Werten oder einem
#' stetigen Bereich aus \code{param_range()}. Bei \code{method = "grid"}
#' werden alle Kombinationen der Rasterwerte ausgewertet; bei
#' \code{"random"} und \code{"lhs"} werden diskrete Werte gleichverteilt
#' ausgewaehlt und Bereiche stetig zwischen \code{lower} und \code{upper}
#' gezogen (\code{n} und \code{step} spielen dann keine Rolle).
#'
#' @param ... Benannte Dimensionen (alle Namen Pflicht; sie werden zu den
#'   Namen der Liste \code{p} im \code{builder}, ohne \code{builder} zu
#'   Argumentnamen von \code{\link[=simulation]{simulation()}} bzw. Pfaden zu Parametern der
#'   Bausteine wie \code{dca.value} oder \code{rebalance.thresh}). Jede ist entweder ein nicht leerer
#'   atomarer Vektor diskreter Werte (numerisch, Zeichen, logisch) oder ein
#'   Bereich aus \code{param_range()}. Bei \code{print()} ungenutzt.
#' @param lower,upper Bereichsgrenzen (Zahlen in der Einheit des Parameters,
#'   \code{lower <= upper}; bei \code{log = TRUE} \code{lower > 0}).
#' @param n Anzahl Rasterpunkte des Bereichs bei \code{method = "grid"}
#'   (ganze Zahl von 1 bis 1e6, Standard 5); wird ignoriert, wenn \code{step}
#'   angegeben ist.
#' @param step Schrittweite des Rasters in der Einheit des Parameters
#'   (\code{seq(lower, upper, by = step)}, > 0); hat Vorrang vor \code{n} und
#'   \code{log} (\code{log} gilt dann nur fuer Zufallsziehungen).
#'   \code{NULL} (Standard) = \code{n} Punkte.
#' @param integer Logisch (Standard \code{FALSE}): Raster- und Zufallswerte
#'   auf ganze Zahlen runden; doppelte Rasterwerte entfallen.
#' @param log Logisch (Standard \code{FALSE}): Raster gleichabstaendig auf
#'   der Log-Skala und Ziehung log-gleichverteilt, z. B. fuer
#'   Fensterlaengen.
#' @param x Objekt der Klasse \code{SimLevParamSpace} (fuer \code{print()}).
#' @return \code{param_space}: Objekt der Klasse \code{SimLevParamSpace}
#'   (benannte Liste der Dimensionen); \code{param_range}: Objekt der Klasse
#'   \code{SimLevParamRange} (Liste mit \code{lower}, \code{upper}, \code{n},
#'   \code{step}, \code{integer}, \code{log}).
#' @seealso [param_search()], [param_plateau()]
#' @examples
#' sp <- param_space(n = param_range(50, 400, n = 8, integer = TRUE, log = TRUE),
#'                   band = c(0, 1, 2), w = param_range(0.3, 0.9, step = 0.1))
#' sp
#' @export
param_space <- function(...) {
  d <- list(...)
  if (!length(d) || is.null(names(d)) || any(names(d) == "")) stop(chk_msg("b2b.m_param_space"))
  # seit 1.6.5 (CR2-O-4): doppelte Namen sind ein Fehler (bis 1.6.4 zwei Spalten gleichen Namens im Raster)
  dup <- names(d)[duplicated(names(d))]
  if (length(dup)) chk_stop("b2b.dim_doppelt", "param_space", dup[1])
  # seit 1.6.5 (CR2-W2-4, Entscheidung 189): Datum als Rasterwert in allen Sprachen abgelehnt (bis 1.6.4 nahmen R und
  # Python ein Datum an, Julia nicht)
  for (k in names(d)) if (inherits(d[[k]], c("Date", "POSIXt", "difftime"))) chk_stop("b2b.dim_datum", "param_space", k)
  for (k in names(d)) if (!inherits(d[[k]], "SimLevParamRange") && (!is.atomic(d[[k]]) || !length(d[[k]])))
    stop(chk_msg("b2b.m_param_space_2", k))
  for (k in names(d)) chk_nofactor(d[[k]], "param_space", k)   # seit 1.6.4 (Entscheidung 15)
  structure(d, class = "SimLevParamSpace")
}

#' @rdname param_space
#' @export
param_range <- function(lower, upper, n = 5, step = NULL, integer = FALSE, log = FALSE) {
  # seit 1.6.4: Grenzen je eine endliche Zahl (vorher NaN/Inf in Python/Julia als Stufe), integer/log TRUE/FALSE,
  # Meldungen ohne Eingabewert
  if (!is.numeric(lower) || !is.numeric(upper)) stop("param_range: lower <= upper erforderlich.")
  chk_num1(lower, "param_range", "lower")
  chk_num1(upper, "param_range", "upper")
  if (upper < lower) stop("param_range: lower <= upper erforderlich.")
  chk_bool1(integer, "param_range", "integer")
  chk_bool1(log, "param_range", "log")
  if (log && lower <= 0) stop("param_range: log = TRUE erfordert lower > 0.")
  if (is.null(step) && (!is.numeric(n) || length(n) != 1 || !is.finite(n) || n < 1 || n != round(n)))
    stop(chk_msg("b2b.m_param_range"))
  if (is.null(step)) chk_max(n, SL_MAX_GITTER, "param_range", "n")   # seit 1.6.4 (B-004, wie n_grid; Entscheidung 16)
  if (!is.null(step) && (!is.numeric(step) || length(step) != 1 || !is.finite(step) || step <= 0))
    stop(chk_msg("b2b.m_param_range_2"))
  if (!is.null(step)) {
    # seit 1.6.5 (CR2-M-5): Stufenzahl des Rasters mit step hoechstens 1e6 wie n (bis 1.6.4 unbegrenzt); n wird mit
    # step nicht verwendet und nur als ganze Zahl von 1 bis 1e6 abgelegt, sonst NA (bis 1.6.4 as.integer(n) mit Warnung)
    ns <- floor((upper - lower) / step + 1e-10) + 1
    if (ns > SL_MAX_GITTER) chk_stop("b2b.step_punkte", "param_range", sprintf("%.0f", ns), sprintf("%.0f", SL_MAX_GITTER))
    n <- if (is.numeric(n) && length(n) == 1L && is.finite(n) && n >= 1 && n == round(n) && n <= SL_MAX_GITTER) n
         else NA_integer_
  }
  structure(list(lower = lower, upper = upper, n = as.integer(n), step = step, integer = integer, log = log),
            class = "SimLevParamRange")
}

# Zahl im Druck des Suchraums ohne Exponentenschreibweise (seit 1.6.5, CR2-W2-3; .blk_fmt aus sim_blocks.R)
.ps_fmt_num <- function(v) if (is.numeric(v) && length(v) && all(is.finite(v))) vapply(v, .blk_fmt, "") else format(v)
.ps_range_text <- function(d)
  sprintf("Bereich [%s, %s]%s%s, Raster %s", .blk_fmt(d$lower), .blk_fmt(d$upper),
          if (d$integer) " ganzzahlig" else "", if (d$log) " log" else "",
          if (!is.null(d$step)) paste("Schritt", .blk_fmt(d$step)) else paste(d$n, "Punkte"))

#' @rdname param_space
#' @export
print.SimLevParamRange <- function(x, ...) {
  # seit 1.6.5 (CR2-W4-3): eine Zeile wie im Parameterraum (bis 1.6.4 die rohe Liste)
  cat(sprintf("SimLev-Parameterbereich: %s\n", .ps_range_text(x)))
  invisible(x)
}

#' @rdname param_space
#' @export
print.SimLevParamSpace <- function(x, ...) {
  cat("SimLev-Parameterraum\n")
  for (k in names(x)) {
    d <- x[[k]]
    # seit 1.6.5 (CR2-W2-3): Grenzen und Zahlen einzeln ohne Exponentenschreibweise (bis 1.6.4 %g bzw. format(d)
    # gemeinsam, z. B. "1.23457e+06", "1.0e+00, 2.5e+00")
    if (inherits(d, "SimLevParamRange")) cat(sprintf("  %-14s %s\n", k, .ps_range_text(d)))
    else cat(sprintf("  %-14s %s\n", k, paste(utils::head(.ps_fmt_num(d), 12), collapse = ", ")))
  }
  invisible(x)
}

#' Rasterwerte einer Dimension
#' @keywords internal
#' @noRd
.ps_levels <- function(d) {
  if (!inherits(d, "SimLevParamRange")) return(d)
  v <- if (!is.null(d$step)) seq(d$lower, d$upper, by = d$step)
       else if (d$log) exp(seq(log(d$lower), log(d$upper), length.out = d$n))
       else seq(d$lower, d$upper, length.out = d$n)
  if (d$integer) v <- round(v)
  unique(v)
}

#' Werte einer Dimension aus gleichverteilten u in (0, 1) abbilden
#' @keywords internal
#' @noRd
.ps_map <- function(d, u) {
  if (!inherits(d, "SimLevParamRange")) return(d[pmin(length(d), floor(u * length(d)) + 1L)])
  v <- if (d$log) exp(log(d$lower) + u * (log(d$upper) - log(d$lower))) else d$lower + u * (d$upper - d$lower)
  if (d$integer) v <- round(v)
  v
}

#' Versuchsplan erzeugen
#' @keywords internal
#' @noRd
.ps_design <- function(space, method, n, constraint, stream = NULL) {
  ok_rows <- function(D) {
    if (is.null(constraint)) return(rep(TRUE, nrow(D)))
    vapply(seq_len(nrow(D)), function(i) isTRUE(constraint(as.list(D[i, , drop = FALSE]))), TRUE)
  }
  if (method == "grid") {
    D <- expand.grid(lapply(space, .ps_levels), stringsAsFactors = FALSE, KEEP.OUT.ATTRS = FALSE)
    D <- D[ok_rows(D), , drop = FALSE]
  } else {
    D <- NULL; tries <- 0L
    while ((is.null(D) || nrow(D) < n) && tries < 20L) {
      m <- if (is.null(D)) n else max(n, 2L * (n - nrow(D)))
      U <- vapply(seq_along(space), function(j)
        if (method == "lhs") (.sl_sample(m, stream = stream) - .sl_runif(m, stream = stream)) / m
        else .sl_runif(m, stream = stream), numeric(m))
      if (!is.matrix(U)) U <- matrix(U, nrow = m)
      Dn <- as.data.frame(lapply(seq_along(space), function(j) .ps_map(space[[j]], U[, j])),
                          stringsAsFactors = FALSE, col.names = names(space))
      Dn <- Dn[ok_rows(Dn), , drop = FALSE]
      D <- unique(rbind(D, Dn)); tries <- tries + 1L
    }
    D <- utils::head(D, n)
    # seit 1.6.5 (CR2-A-7, Entscheidung 185 K22): Hinweis, wenn der Plan weniger als n verschiedene zulaessige Punkte hat
    if (nrow(D) && nrow(D) < n) message(chk_msg("b2b.weniger_punkte", "param_search", nrow(D), as.integer(n)))
  }
  if (!nrow(D)) stop(chk_msg("b2b.m_ok_rows"))
  rownames(D) <- NULL
  D
}

#' Eine Strategie-Spezifikation auf einem data.frame auswerten
#' @keywords internal
#' @noRd
.run_spec <- function(df, sp, sim_args, burn_in) {
  if (!is.null(sp$signal)) {
    sg <- sp$signal(df)
    if (is.data.frame(sg)) df <- sg else for (k in names(sg)) {
      v <- sg[[k]]; if (is.logical(v)) v[is.na(v)] <- FALSE; df[[k]] <- v }
  }
  if (!is.null(sp$data)) df <- sp$data(df)
  if (!is.null(sp$map)) for (a in names(sp$map)) df[[a]] <- df[[sp$map[[a]]]]
  if (burn_in > 0) df <- df[(burn_in + 1L):nrow(df), , drop = FALSE]
  args <- .sim_args_set(sim_args, sp$args, "param_search")
  suppressWarnings(suppressMessages(.sim_call(df, sp$strategy, args)))
}

#' Builder-Ergebnis in eine Spezifikation umwandeln
#' @keywords internal
#' @noRd
.as_spec <- function(s) if (is.list(s) && !is.null(s$strategy) && !inherits(s, "strategy")) s else list(strategy = s)

#' Parametersuche ueber Strategie- und Simulationsparameter
#'
#' Wertet eine Strategie fuer jeden Punkt eines Parameterraums mit
#' [simulation()] aus. Neben den Kennzahlen werden die taeglichen
#' zeitgewichteten Renditen jedes Punkts gespeichert; darauf bauen die
#' Ueberanpassungs-Pruefungen [overfit_pbo()], [sharpe_deflated()] und
#' [overfit_walk_forward()] auf.
#'
#' Je Punkt wird die Spezifikation in dieser Reihenfolge angewandt:
#' \code{signal(df)} auf dem vollen Datensatz, dann \code{data(df)}, dann
#' \code{map}, dann das Verwerfen der ersten \code{burn_in} Zeilen und
#' schliesslich [simulation()] mit \code{sim_args}, ueberschrieben durch
#' \code{args}. Fehler einzelner Punkte brechen die Suche nicht ab, sondern
#' stehen in \code{results$error}. Das Ergebnis laesst sich auch mit
#' [overfit_reality_check()] und [sharpe_haircut()] weiterverarbeiten.
#'
#' @param data data.frame wie in [simulation()] (Spalte \code{date} und
#'   Kursspalten als Niveaus), inklusive Vorlauf fuer Signale (siehe
#'   \code{burn_in}).
#'   Seit 1.6.4 mindestens eine Datenzeile (vorab geprueft).
#' @param builder Funktion \code{function(p)}, die aus einer benannten Liste
#'   \code{p} (ein Punkt des Raums) entweder eine Strategie oder eine Liste
#'   \code{list(strategy, signal, args, map, data)} liefert:
#'   \code{signal} wie in \code{\link[=bootstrap_study]{bootstrap_study()}} (Funktion \code{df ->}
#'   data.frame oder Liste von Spalten, z. B. mit \code{\link[=signal_sma]{signal_sma()}}),
#'   \code{args} (Liste, wie \code{sim_args}, auch mit Pfaden wie \code{"rebalance.thresh"})
#'   ueberschreibt \code{sim_args}, \code{map} (benannter
#'   Zeichenvektor) legt Spalten-Aliase an, \code{data} ist optional eine
#'   Funktion \code{df -> df} (z. B. eine Hebelreihe mit \code{\link[=series_leverage]{series_leverage()}}
#'   anlegen). \code{NULL} (Standard) = ohne \code{builder}: die Parameter
#'   werden als Argumente von \code{\link[=simulation]{simulation()}} fuer \code{strategy} verwendet;
#'   Parameter der Bausteine dann mit Pfad, z. B.
#'   \code{param_space(rebalance.thresh = c(2, 5), dca.value = c(100, 200))} (wie in
#'   \code{\link{sensitivity_grid}}); die Spalten von \code{results} heissen wie die Pfade.
#' @param space Suchraum aus [param_space()] (oder benannte Liste, die an
#'   [param_space()] weitergegeben wird).
#' @param strategy Feste Strategie (z. B. aus [create_strategy()]), wenn
#'   \code{builder} fehlt; sonst ungenutzt.
#' @param method \code{"grid"} (Standard, volles Raster), \code{"random"}
#'   (Zufallssuche) oder \code{"lhs"} (Latin Hypercube; gleichmaessige
#'   Abdeckung bei vielen Dimensionen).
#' @param n Anzahl Punkte bei \code{"random"} und \code{"lhs"} (ganze Zahl,
#'   Standard 50); bei \code{"grid"} ignoriert. Doppelte Punkte werden
#'   entfernt und in hoechstens 20 Runden nachgezogen; es koennen weniger
#'   Punkte entstehen.
#'   Seit 1.6.4 hoechstens 10^8.
#' @param constraint Optional \code{function(p)}, die \code{TRUE} fuer
#'   zulaessige Punkte liefert (z. B. Gewichte summieren sich hoechstens zu
#'   1); Punkte ohne \code{TRUE} entfallen. \code{NULL} (Standard) = alle
#'   Punkte.
#' @param sim_args Benannte Liste gemeinsamer Argumente fuer \code{\link[=simulation]{simulation()}}
#'   (Standard: keine): Argumente von \code{\link[=simulation]{simulation()}} ausser \code{data} und \code{strategy},
#'   also auch Bausteine (z. B. \code{dca = dca_plan(100, 1)}, \code{tax = tax_profile()}) und
#'   Pfade zu Parametern der Bausteine (\code{"dca.value"}, siehe
#'   \code{\link{sensitivity_grid}}). Alte Einzelargumente (bis 0.8.0, vor den Bausteinen, z. B.
#'   \code{dca_value}) ergeben einen Fehler, der den Baustein nennt.
#' @param burn_in Anzahl Zeilen am Anfang von \code{data} (bei Tagesdaten:
#'   Tage), die nach der Signalberechnung verworfen werden (Signal-Vorlauf;
#'   ganze Zahl, Standard 0).
#' @param metrics Funktion \code{SimLevResult ->} benannter numerischer
#'   Vektor (Standard [bootstrap_study_metrics()]: u. a. \code{cagr},
#'   \code{max_drawdown} als Anteil, \code{sharpe}; \code{cagr} ist mit
#'   Sparplan geldgewichtet, XIRR).
#'   Seit 1.6.4 muessen die Namen der Kennzahlen eindeutig und nicht leer sein und duerfen keiner festen Spalte des
#'   Ergebnisses gleichen (sonst Fehler nach dem Rechnen).
#' @param objective Name der Zielgroesse (Element von \code{metrics}, Standard
#'   \code{"sharpe"}) fuer Ranking, Plateau und [param_bootstrap()].
#' @param maximize Logisch: Zielgroesse maximieren (Standard \code{TRUE};
#'   \code{FALSE} z. B. fuer \code{max_drawdown}).
#' @param cores Anzahl paralleler Prozesse (unter Unix per Fork, unter Windows per PSOCK-Cluster):
#'   \code{"auto"} (Standard seit 1.6.4; bis 1.6.3 1) oder eine ganze Zahl >= 1.
#'   Mit \code{"auto"} rechnet SimLev die ersten Einheiten nacheinander, misst ihre Rechenzeit und waehlt
#'   dann die Zahl der Prozesse und der Kern-Threads je Prozess selbst (Planer, gleiche Regel in R,
#'   Python und Julia): hoechstens Zahl der freien Prozessoren (Prozessoren minus andere laufende Prozesse gleicher oder hoeherer Prioritaet), so
#'   viele, wie der freie Speicher traegt, und
#'   nur, wenn die Startkosten der Prozesse kleiner sind als der Gewinn (kleine Rechnungen bleiben bei
#'   einem Prozess; unter Windows immer einer). Ausgaben, Meldungen, Warnungen und Fehler der Einheiten
#'   erscheinen dabei wie mit \code{cores = 1}, in Einheitenreihenfolge.
#'   Eine feste Zahl rechnet wie bis 1.6.3; hoechstens Zahl der Prozessoren: mehr wird mit einem Hinweis
#'   begrenzt.
#'   Das Ergebnis haengt nicht von cores ab.
#'   Je paralleler Einheit rechnen die Kerne mit hoechstens Zahl der Prozessoren / Prozesse Threads (mindestens 1).
#' @param seed Startwert fuer den Versuchsplan bei \code{"random"}/\code{"lhs"} (Standard
#'   \code{NULL}; bei \code{"grid"} ohne Bedeutung). Mit Startwert (ganze Zahl, \eqn{|seed| < 2^{53}}) ist das Ergebnis reproduzierbar und der
#'   Zufallszustand von SimLev bleibt unveraendert; mit \code{NULL} wird genau einmal ein
#'   Startwert aus dem Zufallszustand von SimLev gezogen (siehe [simlev_seed()]), wiederholte
#'   Aufrufe liefern dann verschiedene Ergebnisse. \code{set.seed()} wirkt nicht.
#'   Die Auswertung der Punkte ist deterministisch, das Ergebnis haengt nicht von \code{cores} ab.
#' @param keep_returns \code{"day"} (Standard): taegliche Renditen je
#'   Punkt speichern (noetig fuer \code{\link[=overfit_pbo]{overfit_pbo()}}, \code{\link[=sharpe_deflated]{sharpe_deflated()}},
#'   \code{\link[=overfit_walk_forward]{overfit_walk_forward()}}, \code{\link[=overfit_reality_check]{overfit_reality_check()}}, \code{\link[=sharpe_haircut]{sharpe_haircut()}});
#'   \code{"none"}: keine. \code{TRUE}/\code{FALSE} (bis 1.0.0) ergeben einen Fehler.
#' @return Objekt der Klasse \code{SimLevParamSearch}, eine Liste mit
#'   \describe{
#'     \item{\code{results}}{data.frame je Punkt: \code{id}, eine Spalte je
#'       Parameter, die Kennzahlen aus \code{metrics} (\code{NA} bei Fehler)
#'       und \code{error} (Fehlermeldung oder \code{NA}).}
#'     \item{\code{returns}}{Matrix Tage x Punkte der taeglichen
#'       zeitgewichteten Renditen als Anteil (aus [result_index()]); Zeilen =
#'       Tage nach \code{burn_in} ohne den ersten, Spalten \code{p1},
#'       \code{p2}, ... (Nummer = \code{id}); \code{NA} fuer fehlgeschlagene
#'       Punkte. \code{NULL} bei \code{keep_returns = "none"}.}
#'     \item{\code{dates}}{Datum je Zeile von \code{returns} (Kalender des
#'       ersten erfolgreichen Punkts).}
#'     \item{\code{space}, \code{params}, \code{method}, \code{objective},
#'       \code{maximize}, \code{builder}, \code{sim_args},
#'       \code{burn_in}}{Einstellungen (\code{params} = Parameternamen).}
#'     \item{\code{metrics}}{Namen der Kennzahlen.}
#'     \item{\code{elapsed}}{Laufzeit in Sekunden.}
#'   }
#'   Methoden \code{print}, \code{summary}, \code{plot}; Weiterverarbeitung
#'   mit [param_plateau()], [overfit_pbo()], [sharpe_deflated()], [overfit_walk_forward()],
#'   [param_bootstrap()].
#' @examples
#' \donttest{
#' set.seed(1)
#' d <- data.frame(date = seq.Date(as.Date("2010-01-01"), by = "day", length.out = 3000))
#' d$A <- 100 * cumprod(1 + rnorm(3000, 3e-4, 0.011))
#' st <- create_strategy(A = asset_config("etf", "signal", signal_buy = "buy", signal_sell = "sell"))
#' ps <- param_search(d, function(p) list(strategy = st, signal = function(df) signal_sma(df$A, p$n, p$band)),
#'                    param_space(n = c(50, 100, 200), band = c(0, 2)), burn_in = 250)
#' summary(ps)
#' ps$results[, c("id", "n", "band", "cagr", "sharpe", "error")]
#' dim(ps$returns)    # Tage x Punkte
#' plot(ps)           # Heatmap der Zielgroesse ueber n und band
#' }
#' @seealso [param_plateau()], [overfit_pbo()], [sharpe_deflated()], [overfit_walk_forward()], [sensitivity_grid()]
#' @export
param_search <- function(data, builder = NULL, space, strategy = NULL,
                         method = c("grid", "random", "lhs"), n = 50L, constraint = NULL,
                         sim_args = list(), burn_in = 0L, metrics = bootstrap_study_metrics,
                         objective = "sharpe", maximize = TRUE, keep_returns = c("day", "none"), seed = NULL,
                         cores = "auto") {
  own_cache <- .sim_study(); on.exit(.sim_study_end(own_cache), add = TRUE)   # Pruef-Cache je Studie (seit 1.5.1)
  .e5_choice(method, c("grid", "random", "lhs"), "param_search", "method")   # seit 1.6.4 (K43 T2-N4) Pruefung vor match.arg (Meldung auswahl)
  method <- match.arg(method)
  # Text statt Logisch (bis 1.0.0), ohne Alias
  if (is.logical(keep_returns))
    chk_stop("b2b.m_param_search")
  .e5_choice(keep_returns, c("day", "none"), "param_search", "keep_returns")
  keep_returns <- match.arg(keep_returns)
  keep_ret <- keep_returns == "day"
  # einheitliche Eingabepruefung (seit 1.6.4); data/strategy mit den Meldungen von simulation()
  fn <- "param_search"
  if (!is.data.frame(data))
    stop(chk_msg("a.m_sim_check_inputs", chk_msg("tabelle.formen")))
  if (!nrow(data)) chk_stop("zeilen_keine", fn, "data")   # seit 1.6.4 vorab (Entscheidung 38)
  if (!is.null(builder) && !is.function(builder)) chk_stop("e2.funktion", fn, "builder")
  if (missing(space)) chk_stop("fehlt", fn, "space")
  if (!inherits(space, "SimLevParamSpace") && !is.list(space) && !is.atomic(space)) chk_stop("liste", fn, "space")
  if (is.null(builder) && !is.null(strategy)) .e2_check_strategy(strategy)
  chk_int1(n, fn, "n")
  chk_max(n, SL_MAX_N, fn, "n")   # seit 1.6.4 (Entscheidungen 16 und 36)
  if (!is.null(constraint) && !is.function(constraint)) chk_stop("e2.funktion", fn, "constraint")
  if (!is.null(sim_args) && !is.list(sim_args)) chk_stop("liste", fn, "sim_args")
  chk_int1(burn_in, fn, "burn_in", lo = 0)
  # seit 1.6.5 (CR2-A-7): burn_in kleiner als die Zahl der Datenzeilen, vorab (bis 1.6.4 nach der Rechnung "alle Punkte
  # fehlgeschlagen" mit einer Meldung zu NA im Datum)
  if (burn_in >= nrow(data)) chk_stop("b2b.burn_in", fn, as.integer(burn_in), nrow(data))
  if (!is.function(metrics)) chk_stop("e2.funktion", fn, "metrics")
  chk_name1(objective, fn, "objective")
  chk_bool1(maximize, fn, "maximize")
  cores <- chk_cores(cores, fn)   # seit 1.6.4 hoechstens Zahl der Prozessoren, mit Hinweis (Entscheidung 41b)
  if (!inherits(space, "SimLevParamSpace")) space <- do.call(param_space, as.list(space))
  if (is.null(builder)) {
    if (is.null(strategy)) stop(chk_msg("b2b.m_param_search_3"))
    .sim_check_names(names(space), "param_search")   # Dimensionen = Argumente von simulation() bzw. Pfade
    builder <- function(p) list(strategy = strategy, args = p)
  }
  sim_run_args <- .sim_args_set(list(), sim_args, "param_search")
  # Zufall nur im Versuchsplan (Hauptstrom); die Auswertung je Punkt ist deterministisch
  design <- .ps_design(space, method, n, constraint, if (method == "grid") NULL else .sl_main_stream(seed, "param_search"))
  t0 <- Sys.time()
  run <- function(i) {
    p <- as.list(design[i, , drop = FALSE])
    res <- tryCatch(.run_spec(data, .as_spec(builder(p)), sim_run_args, burn_in), error = function(e) e)
    if (inherits(res, "error")) return(list(m = NULL, err = conditionMessage(res)))
    m <- tryCatch(metrics(res), error = function(e) NULL)
    if (is.null(m)) return(list(m = NULL, err = "metrics() fehlgeschlagen"))
    ix <- if (keep_ret) result_index(res) else NULL
    list(m = m, err = NA_character_, date = if (keep_ret) ix$date else NULL,
         ret = if (keep_ret) ix$value[-1] / ix$value[-nrow(ix)] - 1 else NULL)
  }
  # seit 1.6.5 (CR2-W1-3): der erste Punkt vorab, damit Namen der Kennzahlen und objective vor der ganzen Rechnung
  # geprueft werden (bis 1.6.4 erst nach allen Punkten); Ergebnis und Reihenfolge der Meldungen unveraendert
  first <- run(1L)
  if (!is.null(first$m)) {
    chk_kennzahlen(names(first$m), length(first$m), c("id", names(design), "error"), fn)
    if (!objective %in% names(first$m)) chk_stop("rs.objective", fn, objective, paste(names(first$m), collapse = ", "))
  }
  out <- c(list(first), if (nrow(design) > 1L) .par_lapply(seq_len(nrow(design))[-1L], run, cores))
  okm <- Filter(function(o) !is.null(o$m), out)
  if (!length(okm)) stop(sprintf("param_search: alle Punkte fehlgeschlagen, z. B.: %s", out[[1]]$err))
  # seit 1.6.4 (Entscheidung 43, Regel 28 wie bootstrap_study): Namen der Kennzahlen eindeutig, nicht leer und keine
  # feste Spalte (id, Parameter, error); geprueft nach dem Rechnen, bei jedem cores gleich
  for (o in okm) chk_kennzahlen(names(o$m), length(o$m), c("id", names(design), "error"), fn)
  mnames <- names(okm[[1]]$m)
  if (!objective %in% mnames) chk_stop("rs.objective", fn, objective, paste(mnames, collapse = ", "))
  M <- t(vapply(out, function(o) if (is.null(o$m)) rep(NA_real_, length(mnames)) else as.numeric(o$m[mnames]),
                numeric(length(mnames))))
  if (length(mnames) == 1L) M <- t(M)
  colnames(M) <- mnames
  tab <- data.frame(id = seq_len(nrow(design)), design, M, error = vapply(out, `[[`, "", "err"),
                    check.names = FALSE, stringsAsFactors = FALSE)
  R <- dates <- NULL
  if (keep_ret) {
    ref <- okm[[1]]$date; dates <- ref[-1]
    R <- matrix(NA_real_, length(dates), nrow(design))
    for (i in seq_along(out)) if (!is.null(out[[i]]$ret)) {
      k <- match(as.numeric(out[[i]]$date[-1]), as.numeric(dates))
      R[k[!is.na(k)], i] <- out[[i]]$ret[!is.na(k)]
    }
    colnames(R) <- paste0("p", seq_len(nrow(design)))
  }
  structure(list(results = tab, returns = R, dates = dates, space = space, params = names(space),
                 method = method, objective = objective, maximize = maximize, builder = builder,
                 sim_args = sim_args, burn_in = burn_in, metrics = mnames,
                 elapsed = as.numeric(difftime(Sys.time(), t0, units = "secs"))),
            class = "SimLevParamSearch")
}

#' Nachbarschaften im Parameterraum
#' @keywords internal
#' @noRd
.ps_neighbours <- function(x, radius = 1L, k = 5L) {
  P <- x$results[, x$params, drop = FALSE]
  if (x$method == "grid") {
    lev <- lapply(x$params, function(p) .ps_levels(x$space[[p]]))
    L <- do.call(cbind, lapply(seq_along(lev), function(j) match(P[[x$params[j]]], lev[[j]])))
    n <- nrow(L); d <- ncol(L); nl <- lengths(lev)
    # seit 1.6.4 (B-074) ueber die Zellen der (2 radius + 1)^d Nachbarversaetze statt paarweise, wenn es weniger
    # Versaetze als Punkte gibt: dieselben Zeilen (alle Stufen vorhanden, Abstand <= radius je Dimension) in
    # aufsteigender Folge; Zeilen mit fehlender Stufe bleiben ohne Nachbarn wie bisher
    if (n > 0L && (2 * radius + 1)^d <= n && prod(as.numeric(nl)) <= 2^52) {
      mult <- cumprod(c(1, as.numeric(nl)[-d]))
      lin <- rep(1, n); for (j in seq_len(d)) lin <- lin + (L[, j] - 1) * mult[j]   # Zellnummer, NA bei fehlender Stufe
      oi <- which(!is.na(lin)); ukey <- unique(lin[oi])
      cells <- split(oi, match(lin[oi], ukey)); names(cells) <- NULL
      Lk <- L[oi, , drop = FALSE]; nk <- length(oi)
      offs <- as.matrix(expand.grid(rep(list(-radius:radius), d)))
      I <- J <- vector("list", nrow(offs))
      for (o in seq_len(nrow(offs))) {
        Lo <- Lk + rep(unname(offs[o, ]), each = nk)
        inb <- rowSums(Lo >= 1 & Lo <= rep(nl, each = nk)) == d
        cl <- rep(1, sum(inb)); for (j in seq_len(d)) cl <- cl + (Lo[inb, j] - 1) * mult[j]
        hit <- cells[match(cl, ukey)]
        I[[o]] <- rep(oi[inb], lengths(hit)); J[[o]] <- unlist(hit, use.names = FALSE)
      }
      I <- as.integer(unlist(I)); J <- as.integer(unlist(J)); o <- order(I, J)
      out <- split(J[o], factor(I[o], levels = seq_len(n))); names(out) <- NULL
      return(out)
    }
    # je Punkt die Zeilen mit Abstand <= radius in jeder Dimension; seit 1.6.3 spaltenweise mit & statt apply(, 1, all)
    # je Zeile (gleiche Treffer: NA verknuepft sich wie in all(), which() laesst NA weg)
    return(lapply(seq_len(nrow(L)), function(i) {
      ok <- rep(TRUE, nrow(L))
      for (j in seq_len(ncol(L))) ok <- ok & abs(L[, j] - L[i, j]) <= radius
      which(ok)
    }))
  }
  Z <- vapply(P, function(col) { r <- rank(if (is.numeric(col)) col else as.numeric(factor(col)))
                                  if (max(r) > min(r)) (r - min(r)) / (max(r) - min(r)) else r * 0 }, numeric(nrow(P)))
  # seit 1.6.5 (CR2-X1-1): eine Zeile je Punkt auch bei genau einem Punkt (bis 1.6.4 matrix(Z, ncol = 1): p Zeilen)
  if (!is.matrix(Z)) Z <- matrix(Z, nrow = nrow(P))
  D <- as.matrix(.sl_dist(Z))
  lapply(seq_len(nrow(Z)), function(i) order(D[i, ])[seq_len(min(k, nrow(Z)))])
}

#' Plateau-Wert: Zielgroesse ueber die Nachbarschaft eines Punkts
#'
#' Eine einzelne Spitze im Parameterraum ist oft Zufall. Robuster ist ein
#' Punkt, dessen Nachbarn ebenfalls gut abschneiden. Beim Raster sind Nachbarn
#' alle Punkte, die sich in jeder Dimension um hoechstens \code{radius}
#' Rasterstufen unterscheiden; bei Zufallssuche/LHS die \code{k} naechsten
#' Punkte im rangskalierten Raum.
#'
#' Rasterstufen sind die Positionen in den Rasterwerten jeder Dimension des
#' Suchraums. Im rangskalierten Raum wird jede Dimension ueber ihre Raenge
#' auf 0 bis 1 abgebildet (nicht numerische Parameter ueber ihre
#' Faktorcodes) und der euklidische Abstand verwendet. Der Punkt selbst
#' gehoert immer zu seiner Nachbarschaft.
#'
#' @param x \code{SimLevParamSearch} aus [param_search()] (gespeicherte
#'   Renditen sind nicht noetig).
#' @param metric Name einer Kennzahlspalte von \code{x$results} (Standard:
#'   Zielgroesse der Suche, \code{x$objective}).
#' @param radius Maximaler Abstand in Rasterstufen je Dimension (ganze Zahl,
#'   Standard 1); nur \code{method = "grid"}.
#' @param k Anzahl Nachbarn inklusive Punkt selbst (ganze Zahl, Standard 5);
#'   nur \code{method = "random"} und \code{"lhs"}.
#' @return data.frame je Punkt mit \code{id}, \code{value} (Kennzahl des
#'   Punkts), \code{plateau_mean} (Mittel der Kennzahl ueber die
#'   Nachbarschaft, fehlende Werte ignoriert), \code{plateau_min}
#'   (unguenstigster Wert der Nachbarschaft: bei der Zielgroesse je nach
#'   \code{x$maximize} das Minimum bzw. Maximum; bei anderen Kennzahlen das
#'   Maximum fuer \code{max_drawdown}, \code{avg_drawdown}, \code{dd_q50},
#'   \code{dd_q90}, \code{ulcer_index} und \code{longest_drawdown}
#'   (kleiner = besser), sonst das Minimum) und \code{neighbours} (Anzahl Punkte der Nachbarschaft). Die
#'   Einheit entspricht der Kennzahl.
#' @seealso [param_search()], [overfit_walk_forward()] (\code{select = "plateau"}),
#'   [param_bootstrap()] (\code{by = "plateau"})
#' @examples
#' set.seed(1)
#' d <- data.frame(date = seq.Date(as.Date("2010-01-01"), by = "day", length.out = 3000))
#' d$A <- 100 * cumprod(1 + rnorm(3000, 3e-4, 0.011))
#' st <- create_strategy(A = asset_config("etf", "signal", signal_buy = "buy", signal_sell = "sell"))
#' ps <- param_search(d, function(p) list(strategy = st, signal = function(df) signal_sma(df$A, p$n, p$band)),
#'                    param_space(n = c(50, 100, 200), band = c(0, 2)), burn_in = 250)
#' pl <- param_plateau(ps)
#' cbind(ps$results[, c("n", "band")], pl[, -1])
#' param_plateau(ps, metric = "cagr")
#' @export
param_plateau <- function(x, metric = x$objective, radius = 1L, k = 5L) {
  if (!inherits(x, "SimLevParamSearch")) chk_stop("klasse", "param_plateau", "x", "param_search()")
  # seit 1.6.4: metric als Spalte der Ergebnisse (vorher still NULL), radius und k als ganze Zahlen
  chk_name1(metric, "param_plateau", "metric")
  if (!metric %in% names(x$results)) chk_stop("e2.spalte_von", "param_plateau", "metric", "x$results")
  chk_int1(radius, "param_plateau", "radius", lo = 0)
  chk_int1(k, "param_plateau", "k")
  tab <- x$results; v <- tab[[metric]]
  nb <- .ps_neighbours(x, radius, k)
  # unguenstigster Wert: Zielgroesse nach x$maximize, sonst kleiner = besser bei Drawdown-Kennzahlen
  lower_better <- if (metric == x$objective) !isTRUE(x$maximize) else metric %in% .lower_better
  worst <- if (lower_better) max else min
  # seit 1.6.5 (CR2-R-1, Entscheidung 189): Punkte ohne eigenen Wert haben kein Plateau (NA; bis 1.6.4 Mittel der
  # Nachbarn, ein fehlgeschlagener Punkt konnte "Bestes Plateau" sein); Spalte valid = Nachbarn mit Wert
  own <- !is.na(v)
  data.frame(id = tab$id, value = v,
             plateau_mean = ifelse(own, vapply(nb, function(j) mean(v[j], na.rm = TRUE), 0), NA_real_),
             plateau_min = ifelse(own, vapply(nb, function(j) suppressWarnings(worst(v[j], na.rm = TRUE)), 0), NA_real_),
             neighbours = lengths(nb), valid = vapply(nb, function(j) sum(!is.na(v[j])), 0L))
}

#' @rdname param_search
#' @param object,x Objekt der Klasse \code{SimLevParamSearch}.
#' @param top Anzahl der in \code{summary()} bzw. \code{print()} gezeigten
#'   besten Punkte nach der Zielgroesse (ganze Zahl, Standard 10).
#'   \code{summary()} liefert ein Objekt der Klasse
#'   \code{summary.SimLevParamSearch} mit \code{top} (Tabelle mit Spalte
#'   \code{plateau} = \code{plateau_mean} aus [param_plateau()]), \code{best},
#'   \code{best_plateau} (Zeilen von \code{results}), \code{n},
#'   \code{n_failed}, \code{objective}, \code{method}, \code{params} und
#'   \code{elapsed}.
#' @param ... Bei \code{summary()} ungenutzt; bei \code{print()} an
#'   \code{summary()} weitergereicht (z. B. \code{top}); bei \code{plot()}
#'   an [graphics::plot()] bzw. [graphics::image()].
#' @export
summary.SimLevParamSearch <- function(object, top = 10L, ...) {
  tab <- object$results; obj <- object$objective
  pl <- param_plateau(object)
  tab$plateau <- pl$plateau_mean
  ord <- order(tab[[obj]], decreasing = isTRUE(object$maximize), na.last = TRUE)
  ordp <- order(tab$plateau, decreasing = isTRUE(object$maximize), na.last = TRUE)
  structure(list(top = tab[utils::head(ord, top), c("id", object$params, intersect(c("cagr", "max_drawdown", "sharpe", "ulcer_index", "trades"), names(tab)), if (!obj %in% c("cagr", "max_drawdown", "sharpe", "ulcer_index", "trades")) obj, "plateau"), drop = FALSE],
                 best = tab[ord[1], , drop = FALSE], best_plateau = tab[ordp[1], , drop = FALSE],
                 n = nrow(tab), n_failed = sum(!is.na(tab$error)), objective = obj, method = object$method,
                 params = object$params, elapsed = object$elapsed), class = "summary.SimLevParamSearch")
}

#' @export
print.summary.SimLevParamSearch <- function(x, ...) {
  cat(sprintf("SimLev-Parametersuche (%s): %d Punkte, %d fehlgeschlagen, %.1f s\n", x$method, x$n, x$n_failed, x$elapsed))
  cat(sprintf("Zielgr\u00f6\u00dfe: %s\n\n", x$objective))
  y <- x$top
  for (k in intersect(c("cagr", "max_drawdown"), names(y))) y[[k]] <- sprintf("%.2f %%", 100 * y[[k]])
  for (k in setdiff(names(y), c("id", x$params, "cagr", "max_drawdown"))) if (is.numeric(y[[k]])) y[[k]] <- sprintf("%.3f", y[[k]])
  print(y, row.names = FALSE)
  if ("cagr" %in% names(y) || identical(x$objective, "cagr"))
    cat("cagr: mit Sparplan geldgewichtet (XIRR), sonst CAGR des Depotwerts\n")
  fmtp <- function(r) paste(sprintf("%s = %s", x$params, vapply(x$params, function(p) format(r[[p]]), "")), collapse = ", ")
  cat(sprintf("\nBester Punkt:   #%d (%s), %s = %.3f\n", x$best$id, fmtp(x$best), x$objective, x$best[[x$objective]]))
  cat(sprintf("Bestes Plateau: #%d (%s), %s = %.3f, Nachbarschaft = %.3f\n", x$best_plateau$id, fmtp(x$best_plateau),
              x$objective, x$best_plateau[[x$objective]], x$best_plateau$plateau))
  invisible(x)
}

#' @rdname param_search
#' @export
print.SimLevParamSearch <- function(x, ...) { print(summary(x, ...)); invisible(x) }

#' @rdname param_search
#' @param metric Name der Kennzahl (Spalte von \code{results}) fuer die
#'   Grafik (Standard: Zielgroesse). Beim Raster werden die Zellen
#'   beschriftet, \code{cagr}, \code{ttwror}, \code{max_drawdown} und
#'   \code{avg_drawdown} in Prozent.
#'   Seit 1.6.4 ein Fehler, wenn die Spalte keinen endlichen Wert hat (vorher R Grafikfehler, Python und Julia ein
#'   leeres Bild).
#' @param params Ein oder zwei Parameternamen fuer die Achsen (Standard: die
#'   ersten beiden); weitere Dimensionen werden mit \code{fun}
#'   zusammengefasst. Ein Parameter: Linie; zwei: Heatmap (Raster) bzw.
#'   farbiges Streudiagramm (\code{"random"}, \code{"lhs"}).
#' @param fun Funktion zur Zusammenfassung ueber die uebrigen Dimensionen
#'   (Standard \code{max}; bei Minimierung z. B. \code{min}).
#' @export
plot.SimLevParamSearch <- function(x, metric = x$objective, params = utils::head(x$params, 2), fun = max, ...) {
  tab <- x$results
  # seit 1.6.4 (Entscheidung 40): ohne endlichen Wert der Zielgroesse ein Fehler in allen Sprachen (bis 1.6.3 R mit
  # Grafikfehler, Python und Julia ein leeres Bild)
  if (!any(is.finite(suppressWarnings(as.numeric(tab[[metric]]))))) chk_stop("grafik_leer", "plot", metric)
  old <- graphics::par(no.readonly = TRUE); on.exit(graphics::par(old))
  graphics::par(mar = c(4.2, 4.6, 2.6, 1), mgp = c(2.6, 0.6, 0), las = 1, cex.axis = 0.85)
  agg_fun <- function(v) { v <- v[is.finite(v)]; if (length(v)) fun(v) else NA_real_ }
  if (length(params) == 1L) {
    a <- stats::aggregate(tab[[metric]], list(p = tab[[params]]), agg_fun)
    graphics::plot(a$p, a$x, type = "b", pch = 19, col = "#2C6E9B", xlab = params, ylab = metric,
                   main = sprintf("%s nach %s", metric, params), ...)
    graphics::grid(col = "grey88")
    return(invisible(a))
  }
  if (x$method != "grid") {
    pal <- grDevices::colorRampPalette(c("#B5562B", "#F2E9DC", "#2C6E9B"))(64)
    v <- tab[[metric]]; r <- range(v, na.rm = TRUE)
    col <- pal[pmax(1, pmin(64, round(1 + 63 * (v - r[1]) / max(diff(r), 1e-12))))]
    graphics::plot(tab[[params[1]]], tab[[params[2]]], pch = 19, col = col, xlab = params[1], ylab = params[2],
                   main = sprintf("%s (Farbe; blau = hoch)", metric), ...)
    return(invisible(NULL))
  }
  a <- stats::aggregate(tab[[metric]], list(p1 = tab[[params[1]]], p2 = tab[[params[2]]]), agg_fun)
  l1 <- sort(unique(a$p1)); l2 <- sort(unique(a$p2))
  M <- matrix(NA_real_, length(l1), length(l2))
  M[cbind(match(a$p1, l1), match(a$p2, l2))] <- a$x
  pal <- grDevices::colorRampPalette(c("#B5562B", "#F2E9DC", "#2C6E9B"))(64)
  graphics::image(seq_along(l1), seq_along(l2), M, col = pal, axes = FALSE, xlab = params[1], ylab = params[2],
                  main = sprintf("%s (blau = hoch)", metric), ...)
  graphics::axis(1, seq_along(l1), format(l1)); graphics::axis(2, seq_along(l2), format(l2))
  if (length(M) <= 300) {
    sc <- if (metric %in% c("cagr", "ttwror", "max_drawdown", "avg_drawdown")) 100 else 1
    graphics::text(rep(seq_along(l1), length(l2)), rep(seq_along(l2), each = length(l1)),
                   ifelse(is.na(M), "", formatC(sc * M, digits = if (sc == 100) 1 else 2, format = "f")), cex = 0.7)
  }
  graphics::box()
  invisible(M)
}

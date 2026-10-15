# =============================================================================
#  param_search.R  —  Parametersuche ueber Strategie- und Simulationsraeume
# -----------------------------------------------------------------------------
#  param_space() / param_range()   Suchraum (diskret oder kontinuierlich)
#  param_search()                  Raster, Zufallssuche oder Latin Hypercube;
#                                  ruft simulation() je Punkt auf, speichert
#                                  Kennzahlen und taegliche TWR-Renditen
#  plateau()                       Nachbarschafts-Glaettung der Zielgroesse
#                                  (robuste Wahl statt Spitze)
#
#  Die gespeicherten Renditen sind die Grundlage fuer pbo(), deflated_sharpe()
#  und walk_forward() (overfitting.R). Strategien werden ueber eine
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
#'   Argumentnamen von [simulation()]). Jede ist entweder ein nicht leerer
#'   atomarer Vektor diskreter Werte (numerisch, Zeichen, logisch) oder ein
#'   Bereich aus \code{param_range()}. Bei \code{print()} ungenutzt.
#' @param lower,upper Bereichsgrenzen (Zahlen in der Einheit des Parameters,
#'   \code{lower <= upper}; bei \code{log = TRUE} \code{lower > 0}).
#' @param n Anzahl Rasterpunkte des Bereichs bei \code{method = "grid"}
#'   (ganze Zahl >= 1, Standard 5); wird ignoriert, wenn \code{step}
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
#' @seealso [param_search()], [plateau()]
#' @examples
#' sp <- param_space(n = param_range(50, 400, n = 8, integer = TRUE, log = TRUE),
#'                   band = c(0, 1, 2), w = param_range(0.3, 0.9, step = 0.1))
#' sp
#' @export
param_space <- function(...) {
  d <- list(...)
  if (!length(d) || is.null(names(d)) || any(names(d) == "")) stop("param_space: alle Dimensionen m\u00fcssen benannt sein.")
  for (k in names(d)) if (!inherits(d[[k]], "SimLevParamRange") && (!is.atomic(d[[k]]) || !length(d[[k]])))
    stop(sprintf("param_space: Dimension '%s' muss ein Vektor oder param_range() sein.", k))
  structure(d, class = "SimLevParamSpace")
}

#' @rdname param_space
#' @export
param_range <- function(lower, upper, n = 5, step = NULL, integer = FALSE, log = FALSE) {
  if (!is.numeric(lower) || !is.numeric(upper) || upper < lower) stop("param_range: lower <= upper erforderlich.")
  if (log && lower <= 0) stop("param_range: log = TRUE erfordert lower > 0.")
  if (is.null(step) && (!is.numeric(n) || length(n) != 1 || !is.finite(n) || n < 1 || n != round(n)))
    stop(sprintf("param_range: n (Anzahl Rasterpunkte) muss eine ganze Zahl >= 1 sein (erhalten: %s).", paste(format(n), collapse = ", ")))
  if (!is.null(step) && (!is.numeric(step) || length(step) != 1 || !is.finite(step) || step <= 0))
    stop(sprintf("param_range: step muss eine Zahl > 0 sein (erhalten: %s).", paste(format(step), collapse = ", ")))
  structure(list(lower = lower, upper = upper, n = as.integer(n), step = step, integer = integer, log = log),
            class = "SimLevParamRange")
}

#' @rdname param_space
#' @export
print.SimLevParamSpace <- function(x, ...) {
  cat("SimLev-Parameterraum\n")
  for (k in names(x)) {
    d <- x[[k]]
    if (inherits(d, "SimLevParamRange"))
      cat(sprintf("  %-14s Bereich [%g, %g]%s%s, Raster %s\n", k, d$lower, d$upper,
                  if (d$integer) " ganzzahlig" else "", if (d$log) " log" else "",
                  if (!is.null(d$step)) paste("Schritt", d$step) else paste(d$n, "Punkte")))
    else cat(sprintf("  %-14s %s\n", k, paste(utils::head(format(d), 12), collapse = ", ")))
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
.ps_design <- function(space, method, n, constraint) {
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
        if (method == "lhs") (sample.int(m) - stats::runif(m)) / m else stats::runif(m), numeric(m))
      if (!is.matrix(U)) U <- matrix(U, nrow = m)
      Dn <- as.data.frame(lapply(seq_along(space), function(j) .ps_map(space[[j]], U[, j])),
                          stringsAsFactors = FALSE, col.names = names(space))
      Dn <- Dn[ok_rows(Dn), , drop = FALSE]
      D <- unique(rbind(D, Dn)); tries <- tries + 1L
    }
    D <- utils::head(D, n)
  }
  if (!nrow(D)) stop("param_search: kein zul\u00e4ssiger Punkt im Suchraum (constraint pr\u00fcfen).")
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
  args <- utils::modifyList(sim_args, sp$args %||% list())
  suppressWarnings(suppressMessages(do.call(simulation, c(list(data = df, strategy = sp$strategy), args))))
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
#' Ueberanpassungs-Pruefungen [pbo()], [deflated_sharpe()] und
#' [walk_forward()] auf.
#'
#' Je Punkt wird die Spezifikation in dieser Reihenfolge angewandt:
#' \code{signal(df)} auf dem vollen Datensatz, dann \code{data(df)}, dann
#' \code{map}, dann das Verwerfen der ersten \code{burn_in} Zeilen und
#' schliesslich [simulation()] mit \code{sim_args}, ueberschrieben durch
#' \code{args}. Fehler einzelner Punkte brechen die Suche nicht ab, sondern
#' stehen in \code{results$error}. Das Ergebnis laesst sich auch mit
#' [reality_check()] und [sharpe_haircut()] weiterverarbeiten.
#'
#' @param data data.frame wie in [simulation()] (Spalte \code{date} und
#'   Kursspalten als Niveaus), inklusive Vorlauf fuer Signale (siehe
#'   \code{burn_in}).
#' @param builder Funktion \code{function(p)}, die aus einer benannten Liste
#'   \code{p} (ein Punkt des Raums) entweder eine Strategie oder eine Liste
#'   \code{list(strategy, signal, args, map, data)} liefert:
#'   \code{signal} wie in [bootstrap_study()] (Funktion \code{df ->}
#'   data.frame oder Liste von Spalten, z. B. mit [signal_sma()]),
#'   \code{args} (Liste) ueberschreibt \code{sim_args}, \code{map} (benannter
#'   Zeichenvektor) legt Spalten-Aliase an, \code{data} ist optional eine
#'   Funktion \code{df -> df} (z. B. eine Hebelreihe mit [leveraged_series()]
#'   anlegen). \code{NULL} (Standard) = ohne \code{builder}: die Parameter
#'   werden als Argumente von [simulation()] fuer \code{strategy} verwendet.
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
#' @param constraint Optional \code{function(p)}, die \code{TRUE} fuer
#'   zulaessige Punkte liefert (z. B. Gewichte summieren sich hoechstens zu
#'   1); Punkte ohne \code{TRUE} entfallen. \code{NULL} (Standard) = alle
#'   Punkte.
#' @param sim_args Benannte Liste gemeinsamer Argumente fuer [simulation()]
#'   (Standard: keine).
#' @param burn_in Anzahl Zeilen am Anfang von \code{data} (bei Tagesdaten:
#'   Tage), die nach der Signalberechnung verworfen werden (Signal-Vorlauf;
#'   ganze Zahl, Standard 0).
#' @param metrics Funktion \code{SimLevResult ->} benannter numerischer
#'   Vektor (Standard [study_metrics()]: u. a. \code{cagr},
#'   \code{max_drawdown} als Anteil, \code{sharpe}; \code{cagr} ist mit
#'   Sparplan geldgewichtet, XIRR).
#' @param objective Name der Zielgroesse (Element von \code{metrics}, Standard
#'   \code{"sharpe"}) fuer Ranking, Plateau und [param_bootstrap()].
#' @param maximize Logisch: Zielgroesse maximieren (Standard \code{TRUE};
#'   \code{FALSE} z. B. fuer \code{max_drawdown}).
#' @param cores Anzahl paralleler Prozesse (ganze Zahl, Standard 1); unter
#'   Unix per Fork (\code{parallel::mclapply}), unter Windows per
#'   PSOCK-Cluster.
#' @param seed Startwert (ganze Zahl) fuer den Versuchsplan bei
#'   \code{"random"}/\code{"lhs"}; der Zufallszustand der Sitzung wird danach
#'   wiederhergestellt. \code{NULL} (Standard) = aktueller Zufallszustand,
#'   der dabei normal weiterlaeuft (wiederholte Aufrufe ziehen andere Punkte).
#' @param keep_returns Logisch (Standard \code{TRUE}): taegliche Renditen je
#'   Punkt speichern (noetig fuer [pbo()], [deflated_sharpe()],
#'   [walk_forward()], [reality_check()], [sharpe_haircut()]).
#' @return Objekt der Klasse \code{SimLevParamSearch}, eine Liste mit
#'   \describe{
#'     \item{\code{results}}{data.frame je Punkt: \code{id}, eine Spalte je
#'       Parameter, die Kennzahlen aus \code{metrics} (\code{NA} bei Fehler)
#'       und \code{error} (Fehlermeldung oder \code{NA}).}
#'     \item{\code{returns}}{Matrix Tage x Punkte der taeglichen
#'       zeitgewichteten Renditen als Anteil (aus [result_index()]); Zeilen =
#'       Tage nach \code{burn_in} ohne den ersten, Spalten \code{p1},
#'       \code{p2}, ... (Nummer = \code{id}); \code{NA} fuer fehlgeschlagene
#'       Punkte. \code{NULL} bei \code{keep_returns = FALSE}.}
#'     \item{\code{dates}}{Datum je Zeile von \code{returns} (Kalender des
#'       ersten erfolgreichen Punkts).}
#'     \item{\code{space}, \code{params}, \code{method}, \code{objective},
#'       \code{maximize}, \code{builder}, \code{sim_args},
#'       \code{burn_in}}{Einstellungen (\code{params} = Parameternamen).}
#'     \item{\code{metrics}}{Namen der Kennzahlen.}
#'     \item{\code{elapsed}}{Laufzeit in Sekunden.}
#'   }
#'   Methoden \code{print}, \code{summary}, \code{plot}; Weiterverarbeitung
#'   mit [plateau()], [pbo()], [deflated_sharpe()], [walk_forward()],
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
#' @seealso [plateau()], [pbo()], [deflated_sharpe()], [walk_forward()], [sensitivity_grid()]
#' @export
param_search <- function(data, builder = NULL, space, strategy = NULL,
                         method = c("grid", "random", "lhs"), n = 50L, constraint = NULL,
                         sim_args = list(), burn_in = 0L, metrics = study_metrics,
                         objective = "sharpe", maximize = TRUE, cores = 1L, seed = NULL,
                         keep_returns = TRUE) {
  method <- match.arg(method)
  if (!inherits(space, "SimLevParamSpace")) space <- do.call(param_space, as.list(space))
  if (is.null(builder)) {
    if (is.null(strategy)) stop("param_search: 'builder' oder 'strategy' angeben.")
    builder <- function(p) list(strategy = strategy, args = p)
  }
  design <- .with_rng_restore(.ps_design(space, method, n, constraint), seed = seed)
  t0 <- Sys.time()
  run <- function(i) {
    p <- as.list(design[i, , drop = FALSE])
    res <- tryCatch(.run_spec(data, .as_spec(builder(p)), sim_args, burn_in), error = function(e) e)
    if (inherits(res, "error")) return(list(m = NULL, err = conditionMessage(res)))
    m <- tryCatch(metrics(res), error = function(e) NULL)
    if (is.null(m)) return(list(m = NULL, err = "metrics() fehlgeschlagen"))
    ix <- if (keep_returns) result_index(res) else NULL
    list(m = m, err = NA_character_, date = if (keep_returns) ix$date else NULL,
         ret = if (keep_returns) ix$value[-1] / ix$value[-nrow(ix)] - 1 else NULL)
  }
  out <- .par_lapply(seq_len(nrow(design)), run, cores)
  okm <- Filter(function(o) !is.null(o$m), out)
  if (!length(okm)) stop(sprintf("param_search: alle Punkte fehlgeschlagen, z. B.: %s", out[[1]]$err))
  mnames <- names(okm[[1]]$m)
  if (!objective %in% mnames) stop(sprintf("objective '%s' nicht in metrics(): %s", objective, paste(mnames, collapse = ", ")))
  M <- t(vapply(out, function(o) if (is.null(o$m)) rep(NA_real_, length(mnames)) else as.numeric(o$m[mnames]),
                numeric(length(mnames))))
  if (length(mnames) == 1L) M <- t(M)
  colnames(M) <- mnames
  tab <- data.frame(id = seq_len(nrow(design)), design, M, error = vapply(out, `[[`, "", "err"),
                    check.names = FALSE, stringsAsFactors = FALSE)
  R <- dates <- NULL
  if (keep_returns) {
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
    L <- do.call(cbind, lapply(x$params, function(p) match(P[[p]], .ps_levels(x$space[[p]]))))
    return(lapply(seq_len(nrow(L)), function(i) which(apply(abs(sweep(L, 2, L[i, ])) <= radius, 1, all))))
  }
  Z <- vapply(P, function(col) { r <- rank(if (is.numeric(col)) col else as.numeric(factor(col)))
                                  if (max(r) > min(r)) (r - min(r)) / (max(r) - min(r)) else r * 0 }, numeric(nrow(P)))
  if (!is.matrix(Z)) Z <- matrix(Z, ncol = 1)
  D <- as.matrix(stats::dist(Z))
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
#' @seealso [param_search()], [walk_forward()] (\code{select = "plateau"}),
#'   [param_bootstrap()] (\code{by = "plateau"})
#' @examples
#' set.seed(1)
#' d <- data.frame(date = seq.Date(as.Date("2010-01-01"), by = "day", length.out = 3000))
#' d$A <- 100 * cumprod(1 + rnorm(3000, 3e-4, 0.011))
#' st <- create_strategy(A = asset_config("etf", "signal", signal_buy = "buy", signal_sell = "sell"))
#' ps <- param_search(d, function(p) list(strategy = st, signal = function(df) signal_sma(df$A, p$n, p$band)),
#'                    param_space(n = c(50, 100, 200), band = c(0, 2)), burn_in = 250)
#' pl <- plateau(ps)
#' cbind(ps$results[, c("n", "band")], pl[, -1])
#' plateau(ps, metric = "cagr")
#' @export
plateau <- function(x, metric = x$objective, radius = 1L, k = 5L) {
  if (!inherits(x, "SimLevParamSearch")) stop("x muss ein SimLevParamSearch sein.")
  tab <- x$results; v <- tab[[metric]]
  nb <- .ps_neighbours(x, radius, k)
  # unguenstigster Wert: Zielgroesse nach x$maximize, sonst kleiner = besser bei Drawdown-Kennzahlen
  lower_better <- if (metric == x$objective) !isTRUE(x$maximize) else metric %in% .lower_better
  worst <- if (lower_better) max else min
  data.frame(id = tab$id, value = v,
             plateau_mean = vapply(nb, function(j) mean(v[j], na.rm = TRUE), 0),
             plateau_min = vapply(nb, function(j) suppressWarnings(worst(v[j], na.rm = TRUE)), 0),
             neighbours = lengths(nb))
}

#' @rdname param_search
#' @param object,x Objekt der Klasse \code{SimLevParamSearch}.
#' @param top Anzahl der in \code{summary()} bzw. \code{print()} gezeigten
#'   besten Punkte nach der Zielgroesse (ganze Zahl, Standard 10).
#'   \code{summary()} liefert ein Objekt der Klasse
#'   \code{summary.SimLevParamSearch} mit \code{top} (Tabelle mit Spalte
#'   \code{plateau} = \code{plateau_mean} aus [plateau()]), \code{best},
#'   \code{best_plateau} (Zeilen von \code{results}), \code{n},
#'   \code{n_failed}, \code{objective}, \code{method}, \code{params} und
#'   \code{elapsed}.
#' @param ... Bei \code{summary()} ungenutzt; bei \code{print()} an
#'   \code{summary()} weitergereicht (z. B. \code{top}); bei \code{plot()}
#'   an [graphics::plot()] bzw. [graphics::image()].
#' @export
summary.SimLevParamSearch <- function(object, top = 10L, ...) {
  tab <- object$results; obj <- object$objective
  pl <- plateau(object)
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
#' @param params Ein oder zwei Parameternamen fuer die Achsen (Standard: die
#'   ersten beiden); weitere Dimensionen werden mit \code{fun}
#'   zusammengefasst. Ein Parameter: Linie; zwei: Heatmap (Raster) bzw.
#'   farbiges Streudiagramm (\code{"random"}, \code{"lhs"}).
#' @param fun Funktion zur Zusammenfassung ueber die uebrigen Dimensionen
#'   (Standard \code{max}; bei Minimierung z. B. \code{min}).
#' @export
plot.SimLevParamSearch <- function(x, metric = x$objective, params = utils::head(x$params, 2), fun = max, ...) {
  tab <- x$results
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

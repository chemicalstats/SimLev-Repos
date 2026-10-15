# =============================================================================
#  planning.R  —  Renditeannahmen, Laender-Bootstrap und Zielplanung
# -----------------------------------------------------------------------------
#  set_expected_return()  verschiebt historische Renditen auf eine eigene
#                         Renditeannahme (Streuung, Abhaengigkeiten und
#                         Verlaufsmuster bleiben erhalten); vor bootstrap()
#  pooled_bootstrap()     stationaerer Block-Bootstrap ueber mehrere Laender:
#                         je Block wird ein Land gezogen (Anarkulova,
#                         Cederburg & O'Doherty 2022); liefert Pfade fuer
#                         withdrawal_simulation()
#  portfolio_returns()    Periodenrenditen von Kandidaten-Portfolios
#  goal_optimize()        dynamische Programmierung: welches Portfolio
#                         maximiert je Zeitpunkt und Vermoegen die
#                         Wahrscheinlichkeit, ein Ziel zu erreichen (Das,
#                         Ostrov, Radhakrishnan & Srivastav 2020)
# =============================================================================

#' Historische Renditen auf eine Renditeannahme verschieben
#'
#' Historische Mittelwerte sind fuer die Zukunft oft zu optimistisch (z. B.
#' US-Aktien des 20. Jahrhunderts). Diese Funktion verschiebt die
#' logarithmierten Renditen jeder Spalte um eine Konstante, so dass die
#' geometrische Rendite der Historie der Annahme entspricht. Streuung der
#' Log-Renditen, Schiefe, Abhaengigkeiten und zeitliche Muster bleiben
#' unveraendert; ein anschliessender [bootstrap()] zieht dann Pfade mit der
#' gewuenschten Renditeerwartung. Eingabe ist ein data.frame mit
#' Brutto-Renditen je Zeile oder mit Kursniveaus; zurueck kommt derselbe
#' data.frame mit verschobenen Spalten.
#'
#' @param data data.frame mit den Spalten aus \code{columns}; die Spalte
#'   \code{date} (Klasse Date oder in Date umwandelbar) wird fuer den
#'   Standardwert von \code{ppy} und bei \code{type = "prices"} fuer die
#'   zeitliche Reihenfolge gebraucht (Zeilen muessen nicht sortiert sein, die
#'   Zeilenreihenfolge des Ergebnisses bleibt erhalten; ohne \code{date} gilt
#'   die Zeilenreihenfolge als Zeitfolge). Eine Matrix ist nicht zulaessig.
#' @param columns Zeichenvektor mit den Namen der zu verschiebenden Spalten.
#' @param target Geometrische Zielrendite in Prozent p. a. (4 = 4 % p. a.):
#'   Skalar (gilt fuer alle \code{columns}) oder benannter Vektor mit einem
#'   Eintrag je Spalte aus \code{columns} (z. B. \code{c(us = 5, eu = 5)});
#'   fehlt eine Spalte, bricht die Funktion ab.
#' @param type Art der Spalten: \code{"returns"} (Standard; Brutto-Renditen je
#'   Zeile, z. B. 1.001 fuer +0,1 %, wie fuer [bootstrap()]) oder
#'   \code{"prices"} (Kursniveaus; die Verschiebung wird dann als
#'   Trend ueber die Zeilen aufmultipliziert).
#' @param ppy Renditen (Zeilen) je Jahr. \code{NULL} (Standard): bei einem
#'   data.frame mit \code{date} Anzahl der Renditen geteilt durch die Spanne
#'   von \code{date} in Jahren (Tage / 365.25), sonst 252.
#' @return \code{data} mit angepassten Spalten. Attribut \code{shift}:
#'   benannter Vektor der angewendeten Verschiebung je Spalte in Prozent p. a.
#'   (geometrisch; negativ = Rendite abgesenkt). Fehlende Werte werden bei der
#'   Mittelwertbildung ignoriert.
#' @seealso [bootstrap()], [pooled_bootstrap()] (Argument \code{target})
#' @examples
#' set.seed(1)
#' d <- data.frame(date = seq.Date(as.Date("2000-01-01"), by = "day", length.out = 3650))
#' d$us <- exp(rnorm(3650, 3e-4, 0.01))
#' d2 <- set_expected_return(d, "us", 4)
#' prod(d2$us)^(365.25 / 3650) - 1      # etwa 0.04 = 4 % p. a.
#' attr(d2, "shift")
#' @export
set_expected_return <- function(data, columns, target, type = c("returns", "prices"), ppy = NULL) {
  type <- match.arg(type)
  if (!is.data.frame(data)) stop("data muss ein data.frame sein.")
  miss <- setdiff(columns, names(data))
  if (length(miss)) stop(sprintf("Spalte(n) nicht in data: %s.", paste(miss, collapse = ", ")))
  if (!is.numeric(target) || anyNA(target)) stop("target muss numerisch sein (Prozent p. a., z. B. 4).")
  if (length(target) == 1 && is.null(names(target))) target <- stats::setNames(rep(target, length(columns)), columns)
  else if (is.null(names(target)) || length(setdiff(columns, names(target))))
    stop(sprintf("target braucht einen Skalar oder einen benannten Eintrag je Spalte aus columns; fehlt f\u00fcr: %s.",
                 paste(if (is.null(names(target))) columns else setdiff(columns, names(target)), collapse = ", ")))
  n <- nrow(data)
  # Reihenfolge der Zeilen: bei Kursniveaus zaehlt die zeitliche Abfolge (nach date, falls vorhanden)
  dd <- if ("date" %in% names(data)) .to_date(data$date, "set_expected_return: data$date") else NULL
  o <- if (!is.null(dd)) order(dd) else seq_len(n)
  if (type == "prices" && !is.null(dd) && anyDuplicated(dd))
    stop("type = 'prices': date enth\u00e4lt doppelte Daten; Kursniveaus brauchen eine eindeutige Zeitfolge.")
  if (is.null(ppy)) ppy <- if (!is.null(dd))
    (n - (type == "prices")) / (as.numeric(max(dd, na.rm = TRUE) - min(dd, na.rm = TRUE)) / 365.25) else 252
  shift <- stats::setNames(numeric(length(columns)), columns)
  for (k in columns) {
    v <- as.numeric(data[[k]])
    lr <- if (type == "returns") log(v) else diff(log(v[o]))
    g_hist <- mean(lr, na.rm = TRUE); g_tgt <- log1p(target[[k]] / 100) / ppy
    delta <- g_tgt - g_hist
    if (type == "returns") data[[k]] <- v * exp(delta)
    else { pos <- integer(n); pos[o] <- seq_len(n); data[[k]] <- v * exp(delta * (pos - 1)) }   # Trend nach Zeitfolge
    shift[k] <- 100 * expm1(delta * ppy)
  }
  attr(data, "shift") <- shift
  data
}

#' Periodenrenditen aus Kursreihen
#' @keywords internal
#' @noRd
.period_gross <- function(df, columns, frequency) {
  d <- .to_date(df$date, "data$date")
  key <- switch(frequency, month = format(d, "%Y-%m"), quarter = paste(format(d, "%Y"), (as.integer(format(d, "%m")) - 1) %/% 3),
                year = format(d, "%Y"))
  end <- which(c(key[-1] != key[-length(key)], TRUE))
  V <- vapply(columns, function(k) .fill_na(as.numeric(df[[k]]), "locf", keep_leading = TRUE)[end], numeric(length(end)))
  if (!is.matrix(V)) V <- matrix(V, ncol = length(columns), dimnames = list(NULL, columns))
  G <- V[-1, , drop = FALSE] / V[-nrow(V), , drop = FALSE]
  G[stats::complete.cases(G), , drop = FALSE]
}

#' Laender-Bootstrap fuer lange Horizonte
#'
#' Stationaerer Block-Bootstrap ueber mehrere Laender: Jeder Block stammt aus
#' einem zufaellig gezogenen Land (Standard: gleich wahrscheinlich) und
#' beginnt an einer zufaelligen Stelle seiner Historie; Blockgrenzen sind
#' geometrisch verteilt (Politis & Romano 1994). Innerhalb eines Blocks
#' bleiben alle Spalten eines Landes gemeinsam (Aktien, Anleihen, Inflation).
#' So gehen auch Maerkte mit schlechten Phasen (Kriege, Hyperinflation,
#' lange Baissen) in die Planung ein - US-Daten allein ueberschaetzen
#' langfristige Renditen (Anarkulova, Cederburg & O'Doherty 2022).
#'
#' Die Kursreihen jedes Landes werden zuerst auf Periodenrenditen der
#' gewaehlten \code{frequency} verdichtet (Wert am letzten Datum jeder
#' Kalenderperiode; eine unvollstaendige letzte Periode zaehlt mit; nur
#' Perioden ohne fehlende Werte). Ein Block beginnt an einer zufaelligen
#' Periode und laeuft am Ende der Landeshistorie zyklisch am Anfang weiter.
#' Das Ergebnis ist ein \code{withdrawal_paths}-Objekt und kann direkt an
#' [withdrawal_simulation()], [withdrawal_max_rate()] oder
#' [perfect_withdrawal_rate()] uebergeben werden.
#'
#' @param datasets Benannte Liste von data.frames (Name = Land), jeweils mit
#'   Spalte \code{date} (Klasse Date oder umwandelbar), den Kursspalten aus
#'   \code{columns} (Total-Return-Niveaus, keine Renditen) und ggf. der
#'   Preisindex-Spalte aus \code{inflation}. Jedes Land braucht mindestens
#'   2 vollstaendige Periodenrenditen.
#' @param columns Zeichenvektor der Kursspalten (in allen Laendern gleich benannt).
#' @param weights Vektor der Portfolio-Gewichte (>= 0) mit einem Eintrag je
#'   Spalte aus \code{columns}: benannt mit genau diesen Spaltennamen oder
#'   unbenannt in der Reihenfolge von \code{columns} (wird auf Summe 1
#'   normiert; Rebalancing auf die Gewichte in jeder Periode). \code{NULL}
#'   (Standard) = gleiche Gewichte. Die
#'   Portfoliorendite ist die Renditequelle fuer [withdrawal_simulation()].
#' @param inflation \code{NULL} (Standard; keine Inflation, Faktor 1) oder Name
#'   einer Preisindex-Spalte (Niveau, z. B. CPI), die in allen Laendern
#'   vorhanden ist. Sie wird im selben Block wie die Kurse gezogen.
#' @param frequency Periodenlaenge: \code{"year"} (Standard), \code{"quarter"}
#'   oder \code{"month"}.
#' @param n Anzahl simulierter Pfade (Standard 1000).
#' @param years Laenge jedes Pfads in Jahren (Standard 30); ergibt
#'   \code{years} x Perioden je Jahr (1, 4 bzw. 12) Perioden.
#' @param L Mittlere Blocklaenge in Perioden der gewaehlten \code{frequency}
#'   (Blocklaenge = 1 + geometrisch verteilte Zahl mit Mittel \code{L} - 1).
#'   \code{NULL} (Standard) = 10 Jahre, also 10 Jahre, 40 Quartale bzw.
#'   120 Monate.
#' @param country_weights Numerischer Vektor der Ziehungswahrscheinlichkeiten
#'   je Land in der Reihenfolge von \code{datasets} (wird auf Summe 1
#'   normiert). \code{NULL} (Standard) = alle Laender gleich wahrscheinlich.
#' @param target Optional Renditeannahmen in Prozent p. a. (geometrisch):
#'   Skalar fuer alle \code{columns} oder benannter Vektor je Spalte. Die
#'   Verschiebung wird ueber die gepoolten Renditen aller Laender bestimmt und
#'   fuer alle Laender gleich angewendet (wie [set_expected_return()]).
#'   \code{NULL} (Standard) = historische Renditen.
#' @param seed Startwert fuer den Zufallsgenerator; der globale
#'   Zufallszustand wird danach wiederhergestellt. \code{NULL} (Standard) =
#'   aktueller Zufallszustand, der dabei normal weiterlaeuft (wiederholte
#'   Aufrufe liefern verschiedene Pfade).
#' @return Objekt der Klasse \code{withdrawal_paths} (Liste) mit
#'   \code{returns} (Matrix Perioden x Pfade der Brutto-Portfoliorenditen),
#'   \code{inflation} (Matrix gleicher Form, Brutto-Inflation je Periode;
#'   ohne \code{inflation} ueberall 1), \code{frequency},
#'   \code{source = "pooled_bootstrap"}, \code{historical = FALSE},
#'   \code{cape}, \code{base_rate}, \code{start_dates}, \code{weights} (alle
#'   \code{NULL}) sowie den zusaetzlichen Elementen \code{assets} (benannte
#'   Liste der Brutto-Renditematrizen je Spalte aus \code{columns}),
#'   \code{countries} (Zeichenmatrix Perioden x Pfade: gezogenes Land) und
#'   \code{country_names}.
#' @seealso [withdrawal_simulation()], [withdrawal_max_rate()],
#'   [set_expected_return()], [portfolio_returns()]
#' @references Anarkulova, A., Cederburg, S. & O'Doherty, M. S. (2022), Stocks
#'   for the long run? Evidence from a broad sample of developed markets,
#'   Journal of Financial Economics 143(1), 409-433.
#' @examples
#' set.seed(1)
#' land <- function(mu) {
#'   d <- data.frame(date = seq.Date(as.Date("1950-12-31"), by = "year", length.out = 70))
#'   d$aktien <- 100 * cumprod(exp(rnorm(70, mu, 0.18)))
#'   d$anleihen <- 100 * cumprod(exp(rnorm(70, 0.02, 0.06)))
#'   d$cpi <- 100 * cumprod(exp(rnorm(70, 0.025, 0.02)))
#'   d
#' }
#' pb <- pooled_bootstrap(list(de = land(0.05), us = land(0.07)), c("aktien", "anleihen"),
#'                        weights = c(aktien = 0.6, anleihen = 0.4), inflation = "cpi",
#'                        n = 200, years = 30, L = 5, seed = 1)
#' dim(pb$returns)                 # 30 Jahre x 200 Pfade
#' table(pb$countries[, 1])        # Laender im ersten Pfad
#' ws <- withdrawal_simulation(pb, withdrawal_rule("constant", rate = 4))
#' mean(ws$paths$success)
#' @export
pooled_bootstrap <- function(datasets, columns, weights = NULL, inflation = NULL,
                             frequency = c("year", "quarter", "month"), n = 1000L, years = 30L, L = NULL,
                             country_weights = NULL, target = NULL, seed = NULL) {
  frequency <- match.arg(frequency)
  if (is.null(names(datasets)) || any(names(datasets) == "")) stop("datasets muss eine benannte Liste sein (Land -> data.frame).")
  ppy <- .wd_ppy(frequency)
  if (!is.null(weights)) {
    if (!is.numeric(weights) || length(weights) != length(columns) || anyNA(weights) || any(weights < 0) || sum(weights) <= 0)
      stop(sprintf("weights muss je Spalte aus columns (%d) ein Gewicht >= 0 enthalten (Summe > 0).", length(columns)))
    if (is.null(names(weights))) names(weights) <- columns
    else if (!setequal(names(weights), columns))
      stop(sprintf("Namen von weights (%s) passen nicht zu columns (%s).", paste(names(weights), collapse = ", "),
                   paste(columns, collapse = ", ")))
  }
  cols <- c(columns, inflation)
  G <- lapply(datasets, function(df) .period_gross(df, cols, frequency))
  if (any(vapply(G, nrow, 0L) < 2)) stop("Ein Land hat zu wenige Perioden.")
  if (!is.null(target)) {
    tg <- if (length(target) == 1 && is.null(names(target))) stats::setNames(rep(target, length(columns)), columns) else target
    for (k in names(tg)) {
      all_lr <- unlist(lapply(G, function(g) log(g[, k])))
      delta <- log1p(tg[[k]] / 100) / ppy - mean(all_lr)
      G <- lapply(G, function(g) { g[, k] <- g[, k] * exp(delta); g })
    }
  }
  L <- L %||% (10 * ppy)
  nper <- as.integer(years * ppy); nc <- length(G)
  cw <- country_weights %||% rep(1 / nc, nc); cw <- cw / sum(cw)
  draw <- .with_rng_restore(seed = seed, {
    lapply(seq_len(n), function(i) {
      ctry <- integer(nper); row <- integer(nper); t <- 1L
      while (t <= nper) {
        cidx <- sample.int(nc, 1L, prob = cw); len <- 1L + stats::rgeom(1L, 1 / L)
        nr <- nrow(G[[cidx]]); st <- sample.int(nr, 1L)
        idx <- ((st - 1L + seq_len(len) - 1L) %% nr) + 1L
        take <- seq_len(min(len, nper - t + 1L))
        ctry[t - 1L + take] <- cidx; row[t - 1L + take] <- idx[take]; t <- t + length(take)
      }
      list(c = ctry, r = row)
    })
  })
  Gall <- do.call(rbind, lapply(G, function(g) as.matrix(g[, cols, drop = FALSE])))   # alle Laender untereinander
  off <- c(0L, cumsum(vapply(G, nrow, 0L)))[seq_len(nc)]
  gi <- vapply(draw, function(dr) off[dr$c] + dr$r, numeric(nper))                 # Zeile in Gall je Periode und Pfad
  A <- lapply(stats::setNames(cols, cols), function(k) matrix(Gall[gi, k], nper, n))
  w <- if (is.null(weights)) stats::setNames(rep(1 / length(columns), length(columns)), columns) else weights / sum(weights)
  Rp <- Reduce(`+`, lapply(names(w), function(k) w[[k]] * A[[k]]))
  Inf_m <- if (!is.null(inflation)) A[[inflation]] else matrix(1, nper, n)
  structure(list(returns = Rp, inflation = Inf_m, cape = NULL, base_rate = NULL, frequency = frequency,
                 historical = FALSE, start_dates = NULL, weights = NULL, source = "pooled_bootstrap",
                 assets = A[columns], countries = matrix(names(datasets)[vapply(draw, `[[`, integer(nper), "c")], nper),
                 country_names = names(datasets)),
            class = "withdrawal_paths")
}

#' Periodenrenditen von Kandidaten-Portfolios
#'
#' Berechnet aus Kursreihen die Brutto-Periodenrenditen mehrerer
#' Kandidaten-Portfolios mit festen Gewichten (Rebalancing auf die Gewichte zu
#' Beginn jeder Periode). Eingabe ist ein data.frame mit Spalte \code{date}
#' (Klasse Date) und Kursspalten (Niveaus, keine Renditen); Periodenwerte
#' sind die Kurse am letzten Datum jeder Kalenderperiode (fehlende Kurse
#' werden fortgeschrieben, eine unvollstaendige letzte Periode zaehlt mit).
#' Das Ergebnis dient als Szenario-Stichprobe fuer [goal_optimize()].
#'
#' @param data data.frame mit Spalte \code{date} und allen in
#'   \code{candidates} genannten Kursspalten (Niveaus).
#' @param candidates Liste von benannten Gewichtsvektoren (Namen =
#'   Kursspalten; je Kandidat auf Summe 1 normiert), z. B. aus
#'   \code{lapply(seq(0, 1, 0.1), function(a) c(aktien = a, anleihen = 1 - a))}.
#'   Die Listennamen werden Spaltennamen des Ergebnisses; ohne Namen
#'   \code{"P1"}, \code{"P2"}, ...
#' @param frequency Periodenlaenge und Rebalancing-Rhythmus: \code{"year"}
#'   (Standard), \code{"quarter"} oder \code{"month"}.
#' @return Numerische Matrix Perioden x Kandidaten mit Brutto-Renditen (z. B.
#'   1.05 = +5 %); nur Perioden, in denen alle beteiligten Kursspalten Werte
#'   haben.
#' @seealso [goal_optimize()], [pooled_bootstrap()]
#' @examples
#' set.seed(1)
#' n <- 10 * 365
#' d <- data.frame(date = seq.Date(as.Date("2010-01-01"), by = "day", length.out = n))
#' d$aktien <- 100 * cumprod(1 + rnorm(n, 3e-4, 0.01))
#' d$anleihen <- 100 * cumprod(1 + rnorm(n, 1e-4, 0.002))
#' cand <- lapply(c(a20 = 0.2, a60 = 0.6, a100 = 1),
#'                function(a) c(aktien = a, anleihen = 1 - a))
#' round(portfolio_returns(d, cand), 3)
#' @export
portfolio_returns <- function(data, candidates, frequency = c("year", "quarter", "month")) {
  frequency <- match.arg(frequency)
  a <- unique(unlist(lapply(candidates, names)))
  G <- .period_gross(data, a, frequency)
  M <- vapply(candidates, function(w) drop(G[, names(w), drop = FALSE] %*% (w / sum(w))), numeric(nrow(G)))
  if (!is.matrix(M)) M <- matrix(M, ncol = length(candidates))
  colnames(M) <- names(candidates) %||% paste0("P", seq_along(candidates))
  M
}

#' Zielbasierte Allokation per dynamischer Programmierung
#'
#' Bestimmt fuer jeden Zeitpunkt und jedes Vermoegen das Portfolio aus einer
#' Kandidatenliste, das die Wahrscheinlichkeit maximiert, zum Horizont ein
#' Zielvermoegen zu erreichen (Das et al. 2020). Ein- und Auszahlungen je
#' Periode sind moeglich; mit Auszahlungen und \code{goal = 0} wird die
#' Wahrscheinlichkeit maximiert, dass das Geld bis zum Horizont reicht.
#' Die Renditen werden je Periode aus der Stichprobe \code{returns} gezogen
#' (unabhaengig ueber die Zeit; Zeilen = Szenarien, gemeinsam ueber die
#' Kandidaten). Die Wertfunktion wird auf einem logarithmischen
#' Vermoegensraster gespeichert und dazwischen linear in log(Vermoegen) auf
#' der Probit-Skala (\code{qnorm} der Wahrscheinlichkeit) interpoliert; in
#' der letzten Periode wird die 0/1-Zielbedingung exakt ausgewertet.
#'
#' Das Raster reicht logarithmisch gleichabstaendig von
#' \code{max(1e-6, m / 1000)} (m = kleinster positiver Wert von \code{goal}
#' und \code{start_value}) bis \code{20 * max(goal, start_value)};
#' \code{goal} (falls > 0) und \code{start_value} sind zusaetzlich exakte
#' Rasterpunkte. Faellt das Vermoegen nach einer Zahlung auf 0 oder darunter,
#' gilt der Pfad als gescheitert. Bei Gleichstand (Unterschied unter 1e-9)
#' waehlt die Politik den Kandidaten mit der geringsten Streuung der
#' Log-Renditen. Die Vorwaertssimulation wendet die Politik auf \code{n_sim}
#' zufaellige Pfade an (Kandidat des naechstniedrigeren Rasterpunkts des
#' Vermoegens vor der Zahlung).
#'
#' Verzerrung: Der DP-Wert (\code{probability_dp}) ist eine Naeherung des
#' Optimums und liegt typischerweise darueber, weil die interpolierte
#' Wertfunktion die Zielstufe zwischen den Rasterpunkten glaettet und das
#' Maximum ueber Kandidaten diese Fehler bevorzugt (bei grobem Raster einige
#' Prozentpunkte). Gemeldet wird daher als \code{probability} die in der
#' Vorwaertssimulation erreichte Erfolgsquote der gefundenen Politik: eine
#' unverzerrte Schaetzung der Zielwahrscheinlichkeit einer tatsaechlich
#' umsetzbaren Politik, also im Erwartungswert hoechstens das Optimum
#' (Stichprobenfehler \code{probability_se}). Weicht der DP-Wert um mehr als
#' 4 Standardfehler plus 1 Prozentpunkt davon ab, warnt die Funktion
#' (\code{n_grid} erhoehen). Auch \code{static} beruht auf der
#' interpolierten Wertfunktion und kann leicht ueberschaetzt sein.
#'
#' @param returns Numerische Matrix (Szenarien x Kandidaten) von
#'   Brutto-Periodenrenditen (z. B. 1.05 = +5 %), z. B. aus
#'   [portfolio_returns()] (historische Perioden) oder aus Bootstrap-Pfaden.
#'   Jede Zeile ist ein gleich wahrscheinliches Szenario fuer eine Periode.
#'   Spaltennamen benennen die Kandidaten (fehlen sie: \code{"P1"},
#'   \code{"P2"}, ...); fuer die Grafik aufsteigend nach Risiko sortieren.
#' @param start_value Startvermoegen (Geldbetrag, > 0).
#' @param goal Zielvermoegen zum Horizont (Geldbetrag in denselben Einheiten
#'   wie \code{start_value}; real oder nominal, passend zu den Renditen).
#'   Erfolg heisst Endvermoegen >= \code{goal}.
#' @param horizon Anzahl Perioden bis zum Ziel (ganze Zahl >= 1; Periodenlaenge
#'   wie die Zeilen von \code{returns}, z. B. Jahre bei Jahresrenditen).
#'   Nicht zu verwechseln mit \code{horizon} in [withdrawal_simulation()]
#'   (Objekt aus [horizon_model()] oder Jahre).
#' @param contributions Zahlung je Periode als Geldbetrag (Standard 0):
#'   Skalar oder Vektor (wird mit \code{rep_len()} auf \code{horizon}
#'   Perioden gebracht); positiv = Einzahlung, negativ = Entnahme, jeweils
#'   zu Periodenbeginn vor der Rendite.
#' @param n_grid Anzahl Punkte des logarithmischen Vermoegensrasters
#'   (Standard 301, mindestens 2; dazu Ziel und Startwert); mehr Punkte =
#'   genauer, aber langsamer.
#' @param n_sim Anzahl Pfade der Vorwaertssimulation der optimalen Politik
#'   (Standard 5000).
#' @param seed Startwert fuer die Vorwaertssimulation; der globale
#'   Zufallszustand wird danach wiederhergestellt. \code{NULL} (Standard) =
#'   aktueller Zufallszustand, der dabei normal weiterlaeuft (wiederholte
#'   Aufrufe simulieren andere Pfade).
#' @return Objekt der Klasse \code{SimLevGoalPlan} (Liste):
#'   \describe{
#'     \item{\code{probability}}{Zielwahrscheinlichkeit der gefundenen
#'       Politik als Anteil (0.8 = 80 Prozent): Erfolgsquote der
#'       Vorwaertssimulation (\code{mean(simulation$success)}, siehe Details,
#'       Verzerrung).}
#'     \item{\code{probability_se}}{Standardfehler von \code{probability}
#'       (Anteil, aus \code{n_sim}).}
#'     \item{\code{probability_dp}}{Wert der dynamischen Programmierung
#'       (Anteil; Naeherung, meist ueber dem Optimum).}
#'     \item{\code{static}}{Benannter Vektor: Zielwahrscheinlichkeit (Anteil),
#'       wenn durchgehend derselbe Kandidat gehalten wird.}
#'     \item{\code{policy}}{Ganzzahlige Matrix Perioden x Rasterpunkte:
#'       Nummer des optimalen Kandidaten (Spalte von \code{returns}).}
#'     \item{\code{grid}}{Vermoegensraster (Geldbetraege, aufsteigend; Laenge
#'       \code{n_grid} plus Ziel und Startwert).}
#'     \item{\code{value}}{Liste der Laenge \code{horizon + 1}: Element
#'       \code{t} ist die Zielwahrscheinlichkeit je Rasterpunkt zu Beginn von
#'       Periode \code{t} (letztes Element: 0/1 am Horizont).}
#'     \item{\code{simulation}}{Liste mit \code{terminal} (Endvermoegen je
#'       Pfad), \code{choice} (Matrix Perioden x Pfade: gewaehlter Kandidat)
#'       und \code{success} (logisch: nie ruiniert und Endvermoegen >=
#'       \code{goal}).}
#'     \item{\code{goal}, \code{start_value}, \code{horizon}}{Eingaben.}
#'     \item{\code{contributions}}{Zahlungen je Periode (Laenge \code{horizon}).}
#'     \item{\code{candidates}}{Namen der Kandidaten.}
#'   }
#'   Ausgabe mit \code{print()}, Grafik der Politik mit \code{plot()}.
#' @seealso [portfolio_returns()], [pooled_bootstrap()],
#'   [withdrawal_simulation()]
#' @references Das, S. R., Ostrov, D., Radhakrishnan, A. & Srivastav, D.
#'   (2020), Dynamic portfolio allocation in goals-based wealth management,
#'   Computational Management Science 17, 613-640.
#' @examples
#' set.seed(1)
#' R <- sapply(c(a20 = 0.2, a60 = 0.6, a100 = 1),
#'             function(a) exp(rnorm(500, 0.01 + 0.04 * a, 0.02 + 0.16 * a)))
#' gp <- goal_optimize(R, start_value = 100000, goal = 150000, horizon = 10,
#'                     contributions = 2000, n_grid = 101, n_sim = 1000, seed = 1)
#' gp
#' gp$probability          # Anteil, z. B. 0.79 = 79 %
#' plot(gp)
#' @export
goal_optimize <- function(returns, start_value, goal, horizon, contributions = 0, n_grid = 301L,
                          n_sim = 5000L, seed = NULL) {
  R <- as.matrix(returns); K <- ncol(R); S <- nrow(R)
  num1 <- function(v) is.numeric(v) && length(v) == 1L && is.finite(v)
  fmt <- function(v) paste(format(v), collapse = ", ")
  if (!is.numeric(R) || !S || !K || any(!is.finite(R)) || any(R < 0))
    stop("returns muss eine Matrix (Szenarien x Kandidaten) endlicher Brutto-Renditen >= 0 ohne NA sein (z. B. 1.05).")
  if (!num1(start_value) || start_value <= 0) stop(sprintf("start_value muss ein Geldbetrag > 0 sein (erhalten: %s).", fmt(start_value)))
  if (!num1(goal) || goal < 0) stop(sprintf("goal muss ein Geldbetrag >= 0 sein (erhalten: %s).", fmt(goal)))
  if (!num1(horizon) || horizon < 1 || horizon != round(horizon))
    stop(sprintf("horizon muss eine ganze Zahl >= 1 sein (Anzahl Perioden; erhalten: %s).", fmt(horizon)))
  if (!num1(n_grid) || n_grid < 2) stop(sprintf("n_grid muss eine ganze Zahl >= 2 sein (erhalten: %s).", fmt(n_grid)))
  if (!num1(n_sim) || n_sim < 1) stop(sprintf("n_sim muss eine ganze Zahl >= 1 sein (erhalten: %s).", fmt(n_sim)))
  if (!is.numeric(contributions) || !length(contributions) || any(!is.finite(contributions)))
    stop("contributions muss ein endlicher Geldbetrag oder Vektor von Geldbetr\u00e4gen sein.")
  horizon <- as.integer(horizon)
  if (is.null(colnames(R))) colnames(R) <- paste0("P", seq_len(K))
  cf <- rep_len(contributions, horizon)
  wmax <- max(goal, start_value) * 20
  wmin <- max(1e-6, min(c(goal, start_value)[c(goal, start_value) > 0]) / 1000)
  # Ziel und Startwert als exakte Rasterpunkte (Stufe der Zielfunktion liegt auf dem Raster)
  grid <- sort(unique(c(exp(seq(log(wmin), log(wmax), length.out = n_grid)), if (goal > 0) goal, start_value)))
  ng <- length(grid)
  term <- function(W) as.numeric(W >= goal)
  V <- term(grid)
  pol <- matrix(NA_integer_, horizon, ng); Vt <- vector("list", horizon + 1L); Vt[[horizon + 1L]] <- V
  # Interpolation linear in log(W) auf der Probit-Skala: Wahrscheinlichkeiten der Form
  # Phi((log W - a) / b) werden exakt getroffen (lineare Interpolation der 0/1-nahen Stufe
  # ueberschaetzt sonst kleine Wahrscheinlichkeiten). Unter wmin: 0 (bei goal = 0 Wert bei wmin).
  interp <- function(Vn, W) {
    out <- numeric(length(W)); out[W >= wmax] <- 1 * (wmax >= goal); out[W <= 0] <- 0
    mid <- W > 0 & W < wmax
    z <- stats::qnorm(pmin(1 - 1e-12, pmax(1e-12, Vn)))
    out[mid] <- ifelse(W[mid] < wmin, if (goal > 0) 0 else Vn[1], stats::pnorm(stats::approx(log(grid), z, log(W[mid]), rule = 2)$y))
    out
  }
  expect <- function(Vn, base, k, last) {                 # E[V(base * R_k)] je Rasterpunkt
    X <- outer(base, R[, k])
    v <- matrix(if (last) term(as.vector(X)) else interp(Vn, as.vector(X)), length(base))   # letzte Periode: 0/1 exakt
    e <- rowMeans(v); e[base <= 0] <- 0; e
  }
  static <- stats::setNames(numeric(K), colnames(R))
  for (k in seq_len(K)) {
    Vs <- V
    for (t in horizon:1) Vs <- expect(Vs, grid + cf[t], k, t == horizon)
    static[k] <- interp(Vs, start_value)
  }
  # Gleichstand (innerhalb 1e-9): Kandidat mit der geringsten Streuung der Log-Renditen
  risk_rank <- rank(apply(log(pmax(R, 1e-300)), 2, stats::sd), ties.method = "first")
  tie_score <- matrix(K + 1 - risk_rank, ng, K, byrow = TRUE)
  for (t in horizon:1) {
    base <- grid + cf[t]
    E <- vapply(seq_len(K), function(k) expect(V, base, k, t == horizon), numeric(ng))
    if (!is.matrix(E)) E <- matrix(E, ncol = K)
    best <- E >= apply(E, 1, max) - 1e-9
    pol[t, ] <- max.col(ifelse(best, tie_score, 0), ties.method = "first")
    V <- E[cbind(seq_len(ng), pol[t, ])]
    Vt[[t]] <- V
  }
  p_dp <- interp(V, start_value)
  sim <- .with_rng_restore(seed = seed, {
    W <- rep(start_value, n_sim); choice <- matrix(NA_integer_, horizon, n_sim); ruined <- rep(FALSE, n_sim)
    for (t in seq_len(horizon)) {
      base <- W + cf[t]; alive <- base > 0 & !ruined; ruined <- ruined | !alive
      g <- pmax(1L, pmin(ng, findInterval(log(pmax(W, wmin)), log(grid))))   # Politik je Vermoegen vor der Zahlung
      k <- pol[t, g]; choice[t, ] <- k
      draw <- sample.int(S, n_sim, replace = TRUE)
      W <- ifelse(alive, base * R[cbind(draw, k)], 0)
    }
    list(terminal = W, choice = choice, success = !ruined & W >= goal)
  })
  # Kontrolle gegen die Vorwaertssimulation: weicht der DP-Wert deutlich ab, gilt der simulierte
  # gemeldet wird die erreichte Erfolgsquote der Politik (unverzerrt, im Mittel <= Optimum), nicht der
  # nach oben verzerrte DP-Wert; grosse Abweichung = Raster zu grob
  p_sim <- mean(sim$success); se <- sqrt(p_sim * (1 - p_sim) / n_sim)
  tol <- 4 * sqrt(max(p_sim * (1 - p_sim), 1 / n_sim) / n_sim) + 0.01
  if (abs(p_dp - p_sim) > tol)
    warning(sprintf(paste0("goal_optimize: DP-Wert %.1f %% weicht von der Vorw\u00e4rtssimulation %.1f %% ab; ",
                           "probability ist der simulierte Wert (n_grid erh\u00f6hen)."), 100 * p_dp, 100 * p_sim))
  structure(list(probability = p_sim, probability_se = se, probability_dp = p_dp, static = static, policy = pol, grid = grid, value = Vt,
                 simulation = sim, goal = goal, start_value = start_value, horizon = horizon,
                 contributions = cf, candidates = colnames(R)), class = "SimLevGoalPlan")
}

#' Methoden fuer Zielplanungs-Objekte
#'
#' \code{print()} zeigt Ziel, Horizont, Zahlungen, die Zielwahrscheinlichkeit
#' der dynamischen Politik (simuliert mit Standardfehler, dazu der DP-Wert, in Prozent), die
#' Zielwahrscheinlichkeit jedes festen Kandidaten und die haeufigste Wahl im
#' ersten Schritt. \code{plot()} zeichnet die optimale Kandidatenwahl je
#' Periode und Vermoegen (Vermoegen log10, Ausschnitt von \code{goal / 20}
#' bis \code{3 * goal}; gestrichelte Linie = Ziel).
#'
#' @param x Objekt der Klasse \code{SimLevGoalPlan} aus [goal_optimize()].
#' @param ... Bei \code{plot()} weitere Argumente fuer
#'   [graphics::image()]; bei \code{print()} ohne Wirkung.
#' @return \code{x} (unsichtbar).
#' @seealso [goal_optimize()]
#' @rdname SimLevGoalPlan-methods
#' @keywords internal
#' @export
print.SimLevGoalPlan <- function(x, ...) {
  eur <- function(v) formatC(round(v), format = "d", big.mark = " ")   # R9-07: Leerzeichen als Tausendertrenner
  cat(sprintf("Zielplanung: Ziel %s in %d Perioden, Start %s%s\n", eur(x$goal), x$horizon, eur(x$start_value),
              if (any(x$contributions != 0)) sprintf(", Zahlungen %s je Periode", paste(eur(unique(x$contributions)), collapse = "/")) else ""))
  cat(sprintf("Zielwahrscheinlichkeit dynamisch: %.1f %% (Vorw\u00e4rtssimulation, SE %.1f Prozentpunkte; DP-Wert %.1f %%)\n",
              100 * x$probability, 100 * (x$probability_se %||% NA_real_), 100 * x$probability_dp))
  best <- which.max(x$static)
  cat(sprintf("Bester fester Kandidat: %s mit %.1f %%\n\n", names(x$static)[best], 100 * x$static[best]))
  print(round(100 * x$static, 1))
  ch <- table(factor(x$candidates[x$simulation$choice[1, ]], levels = x$candidates))
  cat(sprintf("\nWahl im ersten Schritt: %s\n", names(ch)[which.max(ch)]))
  invisible(x)
}

#' @rdname SimLevGoalPlan-methods
#' @export
plot.SimLevGoalPlan <- function(x, ...) {
  old <- graphics::par(no.readonly = TRUE); on.exit(graphics::par(old))
  graphics::par(mar = c(4, 4.6, 2.6, 6), mgp = c(2.6, 0.6, 0), las = 1, cex.axis = 0.8)
  keep <- x$grid >= x$goal / 20 & x$grid <= x$goal * 3
  K <- length(x$candidates); pal <- grDevices::colorRampPalette(c("#2C6E9B", "#F2E9DC", "#B5562B"))(K)
  graphics::image(seq_len(x$horizon), log10(x$grid[keep]), x$policy[, keep, drop = FALSE], col = pal, zlim = c(1, K),
                  xlab = "Periode", ylab = "Verm\u00f6gen (log10)", main = "Optimale Wahl je Zeit und Verm\u00f6gen", ...)
  graphics::abline(h = log10(x$goal), lty = 2)
  graphics::par(xpd = TRUE)
  graphics::legend(graphics::par("usr")[2], graphics::par("usr")[4], x$candidates, fill = pal, bty = "n", cex = 0.7, border = NA)
  invisible(x)
}

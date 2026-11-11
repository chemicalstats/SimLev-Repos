# =============================================================================
#  scenarios.R  —  Szenarien mit eigenen Annahmen und Stresstests
# -----------------------------------------------------------------------------
#  scenario_entropy_pooling()    gewichtet historische (oder simulierte) Szenarien so
#                       um, dass sie eigene Annahmen ("Views") erfuellen, bei
#                       minimaler relativer Entropie zur Ausgangsverteilung
#                       (Meucci 2008, Fully Flexible Probabilities)
#  view_mean(), view_prob(), view_vol()   Bausteine fuer Annahmen
#  scenario_copula()   Szenarien aus t- bzw. Gauss-Copula mit empirischen
#                       Raendern, optional unter Stress (bedingt auf ein
#                       Quantilband einzelner Anlagen)
#  scenario_risk()      Portfolio-Kennzahlen auf (gewichteten) Szenarien
#  scenario_crisis()      ein Portfolio durch historische Krisenfenster
# =============================================================================

#' Annahmen fuer Entropy Pooling
#'
#' Bausteine fuer die Annahmen ("Views") von [scenario_entropy_pooling()]. Jede
#' Funktion beschreibt nur die Annahme; geprueft und umgesetzt wird sie erst
#' in [scenario_entropy_pooling()] auf der Szenario-Tabelle. Werte stehen in der
#' Einheit der Szenario-Spalten: Bei Kursdaten sind das einfache Renditen in
#' Prozent je Periode (-5 = -5 %), Zustandsvariablen in ihrer eigenen
#' Einheit.
#' \describe{
#'   \item{view_mean}{Erwartungswert einer Spalte (Rendite in Prozent je
#'     Periode oder Zustandsvariable in ihrer Einheit).}
#'   \item{view_prob}{Wahrscheinlichkeit eines Ereignisses, als Ausdruck ueber
#'     die Spalten (z. B. \code{"aktien < -5"}).}
#'   \item{view_vol}{Standardabweichung einer Spalte (um ihren Erwartungswert
#'     unter der Ausgangsverteilung bzw. einer \code{view_mean}-Annahme mit
#'     \code{op = "="} fuer dieselbe Spalte). Umgesetzt wird die Bedingung
#'     an das zweite Moment um diesen festen Wert; verschiebt sich der
#'     Mittelwert durch andere Annahmen, kann die Standardabweichung nach
#'     der Umgewichtung davon abweichen.}
#'   \item{view_cor}{(seit 1.6.5, Meucci 2008) Korrelation zweier Spalten,
#'     umgesetzt als Bedingung an \eqn{E[(x_1 - m_1)(x_2 - m_2)] = \rho s_1 s_2}
#'     mit festen Mitteln \eqn{m} und Standardabweichungen \eqn{s} (aus
#'     Annahmen \code{view_mean}/\code{view_vol} mit \code{op = "="} fuer
#'     dieselbe Spalte, sonst aus der Ausgangsverteilung). Seit der
#'     Pruefrunde 1.6.5 (Entscheidung 199) haelt
#'     [scenario_entropy_pooling()] dazu Mittel und Standardabweichung beider
#'     Spalten als Gleichungen fest (Mittel \eqn{m}, zweites Moment um
#'     \eqn{m} gleich \eqn{s^2}), damit die Korrelation nach der
#'     Umgewichtung die Annahme trifft. Eigene Annahmen gehen vor: kein
#'     festes Mittel fuer eine Spalte mit \code{view_mean} oder
#'     \code{view_rank}, keine feste Streuung fuer eine Spalte mit
#'     \code{view_vol}; verschieben diese Mittel oder Streuung, kann die
#'     Korrelation danach abweichen.}
#'   \item{view_rank}{(seit 1.6.5, Meucci 2008) Rangfolge der
#'     Erwartungswerte, je benachbartes Paar eine Ungleichung an die Mittel.}
#' }
#' @param var Spaltenname der Szenario-Tabelle (Zeichenkette, Anlage oder
#'   Zustandsvariable).
#' @param value Zielwert: bei \code{view_mean} und \code{view_vol} in der
#'   Einheit der Spalte (bei Kursdaten Prozent je Periode), bei
#'   \code{view_prob} eine Wahrscheinlichkeit als Anteil (0.2 = 20 %). Eine
#'   endliche Zahl; bei \code{view_vol} >= 0, bei \code{view_prob} zwischen 0
#'   und 1 (sonst Fehler).
#' @param expr Ereignis als Zeichenkette, ein R-Ausdruck ueber die
#'   Spaltennamen der Szenario-Tabelle, der einen logischen Wert je
#'   Szenario liefert (z. B. \code{"aktien < -5 & inflation > 3"}).
#'   Seit 1.6.4 in R, Python und Julia gleich im gemeinsamen Ausdrucksumfang wie
#'   die Regeltexte von [tactical_rules()]; auch eine Funktion der
#'   Szenario-Tabelle (Ergebnis ein Wert je Szenario).
#' @param op Art der Bedingung: \code{"="} (Standard), \code{"<="} oder
#'   \code{">="}. Seit 1.6.5 genau einer dieser Texte (bis 1.6.4 wurde z. B.
#'   \code{"<"} still als \code{"<="} genommen).
#' @param var1,var2 \code{view_cor} (seit 1.6.5): zwei verschiedene
#'   Spaltennamen; \code{value} ist dort eine Korrelation zwischen -1 und 1.
#' @param vars \code{view_rank} (seit 1.6.5): mindestens zwei Spaltennamen,
#'   absteigend nach Erwartungswert (\code{vars[1] >= vars[2] >= ...}).
#' @return Liste mit \code{type} (\code{"mean"}, \code{"prob"}, \code{"vol"},
#'   \code{"cor"} oder \code{"rank"}), \code{var} bzw. \code{expr},
#'   \code{value} und \code{op}. \code{view_vol} mit \code{value = 0} gibt
#'   seit 1.6.5 einen Hinweis (die Gewichte fallen auf Szenarien mit genau dem
#'   Mittelwert); die Korrelation im Ergebnis ist fuer eine Spalte ohne
#'   Streuung \code{NA} (ohne englische Rohwarnung).
#' @seealso [scenario_entropy_pooling()], [scenario_risk()].
#' @examples
#' set.seed(1); X <- data.frame(aktien = rnorm(1000, 0.15, 2), anleihen = rnorm(1000, 0.05, 0.6))
#' v <- list(view_mean("aktien", -0.2), view_prob("aktien < -2", 0.15, ">="),
#'           view_vol("anleihen", 0.8))
#' ep <- scenario_entropy_pooling(X, c("aktien", "anleihen"), v)
#' ep$summary
#' @name views
NULL

#' @rdname views
#' @export
view_mean <- function(var, value, op = c("=", "<=", ">=")) {
  chk_name1(var, "view_mean", "var")                              # seit 1.6.4 (K42 E4)
  list(type = "mean", var = var, value = .view_value(value, "view_mean"), op = .view_op(op, "view_mean"))
}

# op der Annahmen: genau einer von "=", "<=", ">=" (seit 1.6.5, CR2-V3-4 Punkt 2: bis 1.6.4 match.arg mit
# Teilabgleich, "<" wurde still "<=", und englische Rohmeldungen)
.view_op <- function(op, fn) {
  if (identical(op, c("=", "<=", ">="))) return("=")
  chk_choice(op, fn, "op", c("=", "<=", ">="))
  op
}

#' Zielwert einer Annahme pruefen (eine endliche Zahl, ggf. mit Bereich)
#' @keywords internal
#' @noRd
.view_value <- function(value, what, lo = -Inf, hi = Inf) {
  if (is.factor(value) || !is.numeric(value) || length(value) != 1 || !is.finite(value) || value < lo || value > hi)   # seit 1.6.4 ohne Wert
    stop(chk_msg("c.m_view_value", what, if (is.finite(lo) && is.finite(hi)) sprintf(" zwischen %g und %g", lo, hi) else if (is.finite(lo)) sprintf(" >= %g", lo) else ""))
  value
}

#' @rdname views
#' @export
view_prob <- function(expr, value, op = c("=", "<=", ">=")) {
  if (!is.function(expr)) chk_name1(expr, "view_prob", "expr")   # seit 1.6.4 (K42 E4); Funktion: Entscheidung 72
  list(type = "prob", expr = expr, value = .view_value(value, "view_prob", 0, 1), op = .view_op(op, "view_prob"))
}

#' @rdname views
#' @export
view_vol <- function(var, value, op = c("=", "<=", ">=")) {
  chk_name1(var, "view_vol", "var")                               # seit 1.6.4 (K42 E4)
  value <- .view_value(value, "view_vol", 0); op <- .view_op(op, "view_vol")
  if (value == 0) message(chk_msg("c.view_vol0", "view_vol"))     # seit 1.6.5 (CR2-V3-4 Punkt 1, Entscheidung 189)
  list(type = "vol", var = var, value = value, op = op)
}

#' @rdname views
#' @export
view_cor <- function(var1, var2, value, op = c("=", "<=", ">=")) {
  # seit 1.6.5 (E-T3-3, Meucci 2008): Korrelation zweier Spalten bei festen Mitteln und Standardabweichungen
  fn <- "view_cor"
  chk_name1(var1, fn, "var1"); chk_name1(var2, fn, "var2")
  if (identical(var1, var2)) chk_stop("c.view_gleich", fn)
  list(type = "cor", var = c(var1, var2), value = .view_value(value, fn, -1, 1), op = .view_op(op, fn))
}

#' @rdname views
#' @export
view_rank <- function(vars) {
  # seit 1.6.5 (E-T3-3, Meucci 2008): Rangfolge der Erwartungswerte, vars[1] >= vars[2] >= ...
  fn <- "view_rank"
  .e4_names(vars, fn, "vars", no_date = FALSE)
  if (length(vars) < 2L) chk_stop("c.view_rang", fn)
  list(type = "rank", var = vars, value = 0, op = ">=")
}

#' Szenario-Matrix aus Daten (Renditen in Prozent je Periode, Zustaende verzoegert)
#' @keywords internal
#' @noRd
.scen_frame <- function(x, assets, states, frequency, fn) {
  # seit 1.6.4 vor der Rechnung (K42 E4): Namen ohne NA, doppelte und 'date', keine gemeinsame Spalte; Kursdaten wie
  # .e4_data, eine fertige Tabelle bzw. Matrix nur mit Zahlenspalten (B-009, B-040, B-052)
  .e4_names(assets, fn, "assets")
  .e4_names(states, fn, "states", null_ok = TRUE)
  .e4_disjoint(assets, states, fn, "assets", "states")
  if (is.data.frame(x) && "date" %in% names(x)) .e4_data(x, c(assets, states), fn)
  else if (is.data.frame(x)) { chk_cols(x, c(assets, states), fn); for (k in c(assets, states)) .e4_numcol(x, k, fn) }
  else if (is.matrix(x) && is.numeric(x)) chk_cols(as.data.frame(x), c(assets, states), fn)   # seit 1.6.5 auch ohne Namen (V1, ...)
  else chk_stop("e4.szenarien", fn)
  if (is.data.frame(x) && "date" %in% names(x)) {
    if (nrow(x) < 2L) chk_stop("e4.wenige", fn)                   # seit 1.6.4 (0 oder 1 Zeile)
    rd <- .dep_returns(x, assets, states, frequency)
    for (a in assets) rd[[a]] <- 100 * expm1(rd[[a]])
    rd <- rd[stats::complete.cases(rd), , drop = FALSE]
    if (nrow(rd) < 2L) chk_stop("e4.wenige", fn)
    return(rd)
  }
  S <- as.data.frame(x)
  # seit 1.6.5 (CR2-P-6): fertige Szenario-Tabelle nur mit endlichen Werten (bis 1.6.4 Rohfehler bzw. still Inf/NaN)
  for (k in c(assets, states)) if (!all(is.finite(S[[k]]))) chk_stop("e3.werte", fn, sprintf("Spalte '%s'", k))
  S
}

#' Entropy Pooling: Szenarien auf eigene Annahmen umgewichten
#'
#' Sucht die Szenario-Wahrscheinlichkeiten \eqn{q}, die alle Annahmen erfuellen
#' und dabei der Ausgangsverteilung \eqn{p} (Standard: gleichgewichtete
#' Historie) am naechsten kommen,
#' \deqn{\min_q \sum_j q_j \log(q_j / p_j)\quad\text{u. d. N.}\quad Aq = b,\; Gq \le h,\; \textstyle\sum q = 1.}
#' Geloest ueber das duale Problem (projizierter BFGS der C-Bibliothek von SimLev). Damit lassen sich Fragen
#' stellen wie: "Wie sieht die gemeinsame Verteilung von Aktien und Anleihen
#' aus, wenn die Inflation im Mittel 5 % betraegt?" - alle Abhaengigkeiten
#' bleiben aus der Historie erhalten, nur die Gewichte der Szenarien aendern
#' sich. Sind die Annahmen nicht (genau genug) erfuellbar, gibt die Funktion
#' eine Warnung aus.
#'
#' Szenarien: Bei einem data.frame mit Spalte \code{date} wird je Periode
#' ein Szenario gebildet. Die Kurse werden wie in [dependence_analysis()]
#' aufbereitet (Fortschreiben fehlender Werte, letzte Zeile je ISO-Woche
#' bzw. Kalendermonat) und in einfache Renditen in Prozent je Periode
#' umgerechnet, \eqn{100 (P_t / P_{t-1} - 1)}; Zustandsspalten gehen mit dem
#' Wert am Ende der Vorperiode ein, Perioden mit fehlenden Werten entfallen.
#' Jede andere Eingabe wird unveraendert als Szenario-Tabelle verwendet
#' (eine Zeile je Szenario, Einheiten wie geliefert).
#'
#' @param x data.frame mit Spalte \code{date} (Date) und Kursspalten
#'   (Kursniveaus; Renditen werden gebildet) oder eine fertige
#'   Szenario-Tabelle (data.frame oder Matrix ohne \code{date}, z. B.
#'   simulierte Renditen).
#' @param assets Zeichenvektor der Anlagespalten (bei Kursdaten Kursspalten).
#' @param views Liste von Annahmen aus [view_mean()], [view_prob()],
#'   [view_vol()]; eine leere Liste liefert die Ausgangsverteilung.
#' @param states Zeichenvektor der Zustandsspalten (z. B. Inflation, in ihrer
#'   eigenen Einheit), bei Kursdaten verzoegert wie in
#'   [dependence_analysis()]. \code{NULL} (Standard) = keine.
#' @param frequency Renditefrequenz bei Kursdaten: \code{"week"} (Standard,
#'   ISO-Woche), \code{"day"} oder \code{"month"}; bei einer fertigen
#'   Tabelle nur Beschriftung.
#' @param prior Ausgangswahrscheinlichkeiten als numerischer Vektor mit
#'   einem Wert je Szenario (also je Zeile nach der Aufbereitung; andere
#'   Laengen, negative oder nicht endliche Werte sind ein Fehler), wird auf
#'   Summe 1 normiert. \code{NULL} (Standard) = gleichverteilt.
#' @return Objekt der Klasse \code{SimLevScenarios}, eine Liste mit
#'   \code{scenarios} (Szenario-Tabelle; bei Kursdaten mit \code{date},
#'   Renditen in Prozent je Periode und Zustaenden), \code{prob} (neue
#'   Wahrscheinlichkeiten, Summe 1), \code{prior}, \code{effective_n}
#'   (effektive Szenarioanzahl \eqn{\exp(H)}, H = Entropie von
#'   \code{prob}), \code{summary} (data.frame je Anlage und Zustand:
#'   \code{var}, \code{mean_prior}, \code{mean_post}, \code{sd_prior},
#'   \code{sd_post}, in der Einheit der Spalte), \code{correlation}
#'   (Korrelationsmatrix der Anlagen nachher), \code{assets}, \code{states},
#'   \code{views}, \code{frequency} und \code{kind} (\code{"entropy_pooling"}).
#'   Methode \code{print}.
#' @seealso [view_mean()], [view_prob()], [view_vol()],
#'   [scenario_risk()], [scenario_copula()], [dependence_analysis()].
#' @references Meucci, A. (2008), Fully Flexible Views: Theory and Practice,
#'   Risk 21(10), 97-102.
#' @examples
#' set.seed(1); X <- data.frame(aktien = rnorm(1000, 0.15, 2), anleihen = rnorm(1000, 0.05, 0.6))
#' ep <- scenario_entropy_pooling(X, c("aktien", "anleihen"), list(view_mean("aktien", -0.2)))
#' ep
#' @export
scenario_entropy_pooling <- function(x, assets, views, states = NULL, frequency = c("week", "day", "month"), prior = NULL) {
  frequency <- match.arg(frequency)
  fn <- "scenario_entropy_pooling"
  env <- parent.frame()                                           # freie Namen der Ausdruecke (Entscheidung 72)
  if (!is.list(views) || is.data.frame(views) || !all(vapply(views, function(v) is.list(v) && length(v$type) == 1L &&
                                                                 isTRUE(v$type %in% c("mean", "prob", "vol", "cor", "rank")), TRUE)))
    chk_stop("e4.views", fn)                                      # seit 1.6.4 (K42 E4)
  S <- .scen_frame(x, assets, states, frequency, fn)
  Tn <- nrow(S)
  if (!is.null(prior) && (is.factor(prior) || !is.numeric(prior) || length(prior) != Tn || any(!is.finite(prior)) || any(prior < 0) || sum(prior) <= 0))
    stop(sprintf("scenario_entropy_pooling: prior muss %d endliche Werte >= 0 mit positiver Summe haben (einer je Szenario).", Tn))   # seit 1.6.4 ohne Wert
  p <- prior %||% rep(1 / Tn, Tn); p <- p / sum(p)
  vars <- intersect(c(assets, states), names(S))
  m0 <- vapply(vars, function(v) sum(p * S[[v]]), 0)
  mean_view <- vol_view <- stats::setNames(rep(NA_real_, length(vars)), vars)
  for (v in views) if (v$type == "mean" && v$op == "=") mean_view[v$var] <- v$value
  for (v in views) if (v$type == "vol" && v$op == "=") vol_view[v$var] <- v$value
  # seit 1.6.5 (E-T3-3): Korrelation mit festen Mitteln und Standardabweichungen (aus Annahmen mit op "=", sonst
  # aus der Ausgangsverteilung); Rangfolge als Ungleichungen der Mittel benachbarter Spalten
  mu_of <- function(k) if (is.na(mean_view[k])) m0[k] else mean_view[k]
  sd_of <- function(k) if (!is.na(vol_view[k])) vol_view[k] else sqrt(sum(p * (S[[k]] - mu_of(k))^2))
  views0 <- views
  views <- unlist(lapply(views, function(v) {
    if (identical(v$type, "rank")) lapply(seq_len(length(v$var) - 1L), function(j)
      list(type = "rank", var = v$var[j:(j + 1L)], value = 0, op = ">=")) else list(v) }), recursive = FALSE)
  for (v in views) if (v$type %in% c("cor", "rank")) { miss <- setdiff(v$var, vars)
    if (length(miss)) stop(chk_msg("c.m_sd_of", miss[1])) }
  # seit 1.6.5 (PR2-2, Entscheidung 199): view_cor haelt Mittel und Streuung beider Spalten fest (Gleichungen an das
  # Mittel mu_of und das zweite Moment um mu_of mit sd_of wie in der Korrelationsbedingung), sonst verschieben sich
  # Mittel und Streuungen und die Korrelation danach trifft die Annahme nicht; eigene Annahmen gehen vor (Mittel:
  # view_mean oder view_rank mit der Spalte, Streuung: view_vol); angehaengt nach allen Annahmen, je Spalte in der
  # Reihenfolge des ersten Auftretens erst alle Mittel, dann alle Streuungen
  cv <- unique(unlist(lapply(views, function(v) if (v$type == "cor") v$var)))
  if (length(cv)) {
    own_m <- unlist(lapply(views, function(v) if (v$type %in% c("mean", "rank")) v$var))
    own_v <- unlist(lapply(views, function(v) if (v$type == "vol") v$var))
    views <- c(views,
      lapply(setdiff(cv, own_m), function(k) list(type = "mean", var = k, value = unname(mu_of(k)), op = "=")),
      lapply(setdiff(cv, own_v), function(k) list(type = "vol", var = k, value = unname(sd_of(k)), op = "=")))
  }
  rx <- if (any(vapply(views, function(v) v$type == "prob" && is.character(v$expr), TRUE))) .e5_rexpr_env(env)
  rows <- lapply(views, function(v) {
    f <- switch(v$type,
      mean = S[[v$var]],
      cor = (S[[v$var[1]]] - mu_of(v$var[1])) * (S[[v$var[2]]] - mu_of(v$var[2])),
      rank = S[[v$var[1]]] - S[[v$var[2]]],
      prob = as.numeric(if (is.function(v$expr)) v$expr(S)               # seit 1.6.4 auch eine Funktion (Entscheidung 72)
                        else eval(.e5_rexpr_parse(v$expr), .sp_rexpr_data(S, rx), rx)),   # RExpr-Umfang wie tactical_rules (59)
      vol = { mu <- if (is.na(mean_view[v$var])) m0[v$var] else mean_view[v$var]; (S[[v$var]] - mu)^2 },
      stop("Unbekannter View-Typ."))
    if (is.null(f) || length(f) != Tn) stop(chk_msg("c.m_sd_of", v$var %||% (if (is.function(v$expr)) "<Funktion>" else v$expr)))
    if (v$type == "vol" && !(is.numeric(v$value) && v$value >= 0)) stop(chk_msg("c.m_sd_of_2"))
    val <- if (v$type == "vol") v$value^2 else if (v$type == "cor") v$value * sd_of(v$var[1]) * sd_of(v$var[2]) else v$value
    sg <- switch(v$op, "=" = 0, "<=" = 1, ">=" = -1)
    list(f = if (sg == -1) -f else f, b = if (sg == -1) -val else val, ineq = sg != 0)
  })
  if (!length(rows)) { q <- p } else {
  A <- do.call(rbind, lapply(rows, `[[`, "f")); b <- vapply(rows, `[[`, 0, "b"); ineq <- vapply(rows, `[[`, TRUE, "ineq")
  dual <- function(l) {
    e <- -drop(.sl_crossprod(A, l)); mx <- max(e); w <- p * exp(e - mx); Z <- sum(w)
    list(val = log(Z) + mx + sum(l * b), q = w / Z)
  }
  fn <- function(l) dual(l)$val
  gr <- function(l) { q <- dual(l)$q; b - drop(A %m% q) }
  lower <- ifelse(ineq, 0, -Inf)
  o <- .sl_optim(rep(0, length(b)), fn, gr, method = "L-BFGS-B", lower = lower,
                 control = list(maxit = 5000, factr = 1e3, pgtol = 1e-12))   # projizierter BFGS (slc)
  q <- dual(o$par)$q
  viol <- drop(A %m% q) - b; viol[ineq] <- pmax(viol[ineq], 0)
  if (max(abs(viol)) > 1e-4 * max(1, abs(b))) warning(sprintf("Annahmen nicht vollst\u00e4ndig erf\u00fcllbar (Abweichung %.2e).", max(abs(viol))))
  }
  wsd <- function(v, w) { m <- sum(w * v); sqrt(sum(w * (v - m)^2)) }
  summ <- data.frame(var = vars, mean_prior = m0, mean_post = vapply(vars, function(v) sum(q * S[[v]]), 0),
                     sd_prior = vapply(vars, function(v) wsd(S[[v]], p), 0), sd_post = vapply(vars, function(v) wsd(S[[v]], q), 0),
                     row.names = NULL, stringsAsFactors = FALSE)
  Xa <- as.matrix(S[, assets, drop = FALSE]); mu <- colSums(Xa * q); C <- .sl_crossprod(sweep(Xa, 2, mu) * sqrt(q))
  # seit 1.6.5 (CR2-V3-4 Punkt 1): Varianz 0 in der Korrelation als NA ohne die englische Rohwarnung von cov2cor
  dv <- diag(C); okv <- is.finite(dv) & dv > 0
  Cr <- if (all(okv)) stats::cov2cor(C) else {
    Cr <- matrix(NA_real_, nrow(C), ncol(C), dimnames = dimnames(C))
    if (any(okv)) Cr[okv, okv] <- stats::cov2cor(C[okv, okv, drop = FALSE])
    Cr }
  structure(list(scenarios = S, prob = q, prior = p, assets = assets, states = states, views = views0,
                 effective_n = exp(-sum(q[q > 0] * log(q[q > 0]))), summary = summ,
                 correlation = Cr, frequency = frequency, kind = "entropy_pooling"),
            class = "SimLevScenarios")
}

#' Szenarien aus einer Copula mit empirischen Raendern
#'
#' Passt eine t-Copula (oder Gauss-Copula) an die Periodenrenditen an:
#' Korrelationsmatrix aus Kendalls Tau (\eqn{\rho = \sin(\pi\tau/2)}),
#' Freiheitsgrade per Profil-Likelihood auf den Raengen, Raender empirisch.
#' Mit \code{stress} wird bedingt simuliert: Die genannten Anlagen werden in
#' ein Quantilband gezwungen (z. B. Aktien in ihre schlechtesten 5 % der
#' Wochen), die uebrigen folgen der bedingten Copula-Verteilung - so zeigt
#' sich, was die Abhaengigkeitsstruktur fuer die anderen Anlagen in solchen
#' Phasen erwarten laesst (einschliesslich gemeinsamer Abstuerze bei der
#' t-Copula).
#'
#' Die Periodenrenditen werden wie bei [scenario_entropy_pooling()] gebildet
#' (einfache Renditen in Prozent je Periode aus Kursdaten; eine fertige
#' Tabelle ohne \code{date} wird unveraendert verwendet). Die Raender sind
#' die empirischen Quantilfunktionen mit linearer Interpolation; simulierte
#' Werte liegen daher nie ausserhalb der historischen Spannweite. Die
#' Freiheitsgrade werden im Bereich 2.1 bis 100 gesucht. Bei einer Anlage in
#' \code{stress} wird ihr Quantil gleichverteilt im Band gezogen; bei mehreren
#' werden deren Werte gemeinsam aus der Copula gezogen und nur Ziehungen
#' behalten, die in allen Baendern liegen (Verwerfungsverfahren, exakt
#' bedingt; bei einer gemeinsamen Trefferquote, die nach 5e7 Ziehungen keine
#' \code{n} Treffer liefert, bricht die Funktion ab).
#'
#' @param x data.frame mit Spalte \code{date} (Date) und Kursspalten
#'   (Kursniveaus) oder fertige Tabelle von Periodenrenditen ohne
#'   \code{date}.
#' @param assets Zeichenvektor der Kurs- bzw. Renditespalten.
#' @param n Anzahl Szenarien (ganze Zahl, Standard 10000).
#'   Seit 1.6.4 hoechstens 10^8.
#' @param family Copula: \code{"t"} (Standard) oder \code{"gaussian"}.
#' @param stress Optional benannte Liste von Quantilbaendern je Anlage als
#'   Anteile \code{c(von, bis)} mit 0 <= von < bis <= 1, z. B.
#'   \code{list(aktien = c(0, 0.05))} (schlechteste 5 % der Perioden).
#'   Unbenannte Eintraege, unbekannte Anlagen und ungueltige Baender sind ein
#'   Fehler.
#'   \code{NULL} (Standard) = unbedingte Simulation.
#' @param frequency Renditefrequenz bei Kursdaten: \code{"week"} (Standard,
#'   ISO-Woche), \code{"day"} oder \code{"month"}.
#' @param seed Startwert der Ziehung. Mit Startwert (ganze Zahl, \eqn{|seed| < 2^{53}}) ist das Ergebnis reproduzierbar und der
#'   Zufallszustand von SimLev bleibt unveraendert; mit \code{NULL} wird genau einmal ein
#'   Startwert aus dem Zufallszustand von SimLev gezogen (siehe [simlev_seed()]), wiederholte
#'   Aufrufe liefern dann verschiedene Ergebnisse. \code{set.seed()} wirkt nicht.
#' @return Objekt der Klasse \code{SimLevScenarios} mit \code{scenarios}
#'   (data.frame mit \code{n} Zeilen, eine Spalte je Anlage, in der Einheit
#'   der Eingangsrenditen, bei Kursdaten Prozent je Periode), \code{prob}
#'   und \code{prior} (je 1 / n), \code{effective_n} (= n), \code{copula}
#'   (Liste: \code{family}, \code{correlation}, \code{df}; \code{Inf} bei
#'   \code{"gaussian"}), \code{stress}, \code{summary} (\code{var},
#'   \code{mean_prior}, \code{sd_prior} der Historie, \code{mean_post},
#'   \code{sd_post} der Szenarien), \code{correlation} (Pearson-Korrelation
#'   der Szenarien), \code{assets}, \code{frequency}, \code{kind}
#'   (\code{"copula"}). Methode \code{print}; weiter mit [scenario_risk()].
#' @seealso [scenario_risk()], [scenario_entropy_pooling()], [copula_fit()],
#'   [scenario_crisis()].
#' @examples
#' set.seed(1); n <- 3 * 365
#' d <- data.frame(date = seq.Date(as.Date("2015-01-01"), by = "day", length.out = n))
#' e <- rnorm(n)
#' d$aktien <- 100 * cumprod(1 + 0.01 * e)
#' d$anleihen <- 100 * cumprod(1 + 0.004 * (0.3 * e + rnorm(n)))
#' cs <- scenario_copula(d, c("aktien", "anleihen"), n = 2000,
#'                        stress = list(aktien = c(0, 0.05)), seed = 1)
#' cs
#' scenario_risk(cs, c(aktien = 0.6, anleihen = 0.4))
#' @export
scenario_copula <- function(x, assets, n = 10000L, family = c("t", "gaussian"), stress = NULL,
                             frequency = c("week", "day", "month"), seed = NULL) {
  family <- match.arg(family); frequency <- match.arg(frequency)
  fn <- "scenario_copula"
  .e4_count(n, fn, "n")                                           # B-026, Entscheidung 16
  S <- .scen_frame(x, assets, NULL, frequency, fn)
  X <- as.matrix(S[, assets, drop = FALSE]); k <- ncol(X); Tn <- nrow(X)
  U <- apply(X, 2, .pobs)
  tau <- .kendall(X); R <- sin(pi * tau / 2)
  ev <- .sl_eigen_sym(R); if (min(ev$values) < 1e-6) {
    R <- ev$vectors %m% diag(pmax(ev$values, 1e-6)) %m% t(ev$vectors); R <- stats::cov2cor(R) }
  Ri <- .sl_solve_spd(R); ldR <- .sl_logdet_spd(R)              # R positiv definit (Cholesky, slc)
  ll_t <- function(nu) {
    Z <- .sl_qt(U, nu); q <- rowSums((Z %m% Ri) * Z)
    sum(.sl_lgamma((nu + k) / 2) + (k - 1) * .sl_lgamma(nu / 2) - k * .sl_lgamma((nu + 1) / 2) - 0.5 * ldR -
          (nu + k) / 2 * log1p(q / nu) + (nu + 1) / 2 * rowSums(log1p(Z^2 / nu)))
  }
  # nu seit 1.6.0 im Kern (sl_tcop_nu, qt auf mehreren Threads); NULL bei einer nicht endlichen Auswertung oder
  # einer Warnung von qt: dann wie bisher in R (gleiche Meldungen)
  nu <- if (family != "t") Inf else if (is.double(U) && is.matrix(U) && is.double(Ri) && identical(dim(Ri), c(k, k)) &&
                                        !is.null(nk <- .Call(C_sl_tcop_nu, U, Ri, as.double(ldR), 2.1, 100,
                                                             .Machine$double.eps^0.25, .sl_nthreads()))) nk else
    .sl_optimize(function(v) -ll_t(v), c(2.1, 100))$minimum
  qmarg <- lapply(seq_len(k), function(j) { s <- sort(X[, j]); function(u) .sl_approx((seq_len(Tn) - 0.5) / Tn, s, u, rule = 2)$y })
  if (!is.null(stress)) {
    if (!is.list(stress) || !length(stress) || is.null(names(stress)) || any(names(stress) == "") || anyDuplicated(names(stress)))
      stop(chk_msg("c.m_ll_t"))
    unk <- setdiff(names(stress), assets)
    if (length(unk)) stop(sprintf("stress: unbekannte Anlage(n) %s; vorhanden: %s.", paste0("'", unk, "'", collapse = ", "), paste(assets, collapse = ", ")))
    for (a in names(stress)) { b <- stress[[a]]
      if (is.factor(b) || !is.numeric(b) || length(b) != 2 || any(!is.finite(b)) || b[1] < 0 || b[2] > 1 || b[1] >= b[2])   # seit 1.6.4 ohne Wert
        stop(chk_msg("c.m_ll_t_2", a)) }
    # seit 1.6.5 (K20, CR2-3): Hinweis, wenn ein Band in den aeussersten Rand reicht (unter 1/T bzw. ueber 1 - 1/T); die
    # Raender enden am historischen Minimum bzw. Maximum
    for (a in names(stress)) { b <- stress[[a]]
      if (b[1] < 1 / Tn || b[2] > 1 - 1 / Tn) message(chk_msg("c.copula_rand", fn, a, Tn)) }
  }
  sim <- {
    rs <- .sl_main_stream(seed, "scenario_copula")                                 # Hauptstrom
    st <- if (is.null(stress)) integer(0) else match(names(stress), assets)
    Z <- matrix(0, n, k)
    if (length(st) == 1) {
      band <- stress[[1]]; u <- .sl_runif(n, band[1], band[2], stream = rs)
      Z[, st] <- if (is.finite(nu)) .sl_qt(u, nu) else .sl_qnorm(u)
    } else if (length(st) > 1) {
      # mehrere Stress-Anlagen: gemeinsam aus ihrer Copula, bedingt auf alle Baender (Verwerfung)
      ks <- length(st); Ls <- .sl_chol(R[st, st, drop = FALSE])
      lo <- vapply(stress, `[`, 0, 1); hi <- vapply(stress, `[`, 0, 2)
      Zs <- matrix(0, 0, ks); drawn <- 0; m <- 1e5
      repeat {
        E <- matrix(.sl_rnorm(m * ks, stream = rs), m) %m% Ls
        if (is.finite(nu)) E <- E / sqrt(.sl_rchisq(m, nu, stream = rs) / nu)
        Ub <- if (is.finite(nu)) .sl_pt(E, nu) else .sl_pnorm(E)
        hit <- rowSums(Ub >= rep(lo, each = m) & Ub <= rep(hi, each = m)) == ks
        Zs <- rbind(Zs, E[hit, , drop = FALSE]); drawn <- drawn + m
        if (nrow(Zs) >= n) break
        if (drawn >= 5e7) stop(sprintf("stress: B\u00e4nder gemeinsam zu unwahrscheinlich (Trefferquote %.1e bei %.0e Ziehungen); B\u00e4nder erweitern oder weniger Anlagen stressen.",
                                       nrow(Zs) / drawn, drawn))
        m <- min(1e6, max(1e5, ceiling(1.2 * (n - nrow(Zs)) / max(nrow(Zs) / drawn, 1e-7))))
      }
      Z[, st] <- Zs[seq_len(n), , drop = FALSE]
    }
    if (length(st)) {
      rest <- setdiff(seq_len(k), st)
      if (length(rest)) {
        Rss <- R[st, st, drop = FALSE]; Rrs <- R[rest, st, drop = FALSE]; Rss_i <- .sl_solve_spd(Rss)
        M <- Z[, st, drop = FALSE] %m% t(Rrs %m% Rss_i)
        Sc <- R[rest, rest, drop = FALSE] - Rrs %m% Rss_i %m% t(Rrs)
        L <- .sl_chol(Sc + diag(1e-12, length(rest)))
        E <- matrix(.sl_rnorm(n * length(rest), stream = rs), n) %m% L
        if (is.finite(nu)) {
          dq <- rowSums((Z[, st, drop = FALSE] %m% Rss_i) * Z[, st, drop = FALSE])
          scale <- sqrt((nu + dq) / (nu + length(st)) / (.sl_rchisq(n, nu + length(st), stream = rs) / (nu + length(st))))
          Z[, rest] <- M + E * scale
        } else Z[, rest] <- M + E
      }
    } else {
      Z <- matrix(.sl_rnorm(n * k, stream = rs), n) %m% .sl_chol(R)
      if (is.finite(nu)) Z <- Z / sqrt(.sl_rchisq(n, nu, stream = rs) / nu)
    }
    Z
  }
  V <- if (is.finite(nu)) .sl_pt(sim, if (length(stress)) nu + 0 else nu) else .sl_pnorm(sim)
  if (length(stress) && is.finite(nu)) {
    rest <- setdiff(seq_len(k), match(names(stress), assets))
    V[, rest] <- .sl_pt(sim[, rest], nu)
  }
  Y <- vapply(seq_len(k), function(j) qmarg[[j]](V[, j]), numeric(n))
  if (!is.matrix(Y)) Y <- matrix(Y, ncol = k)
  colnames(Y) <- assets
  out <- as.data.frame(Y)
  structure(list(scenarios = out, prob = rep(1 / n, n), prior = rep(1 / n, n), assets = assets, states = NULL,
                 effective_n = n, copula = list(family = family, correlation = R, df = nu), stress = stress,
                 summary = data.frame(var = assets, mean_prior = colMeans(X), mean_post = colMeans(Y),
                                      sd_prior = apply(X, 2, .sl_sd), sd_post = apply(Y, 2, .sl_sd), row.names = NULL),
                 correlation = .sl_cor(Y), frequency = frequency, kind = "copula"),
            class = "SimLevScenarios")
}

#' @export
print.SimLevScenarios <- function(x, ...) {
  cat(sprintf("SimLev-Szenarien (%s): %d Szenarien, effektiv %.0f, Renditen in %% je %s\n", x$kind,
              nrow(x$scenarios), x$effective_n, switch(x$frequency, week = "Woche", day = "Tag", month = "Monat")))
  if (!is.null(x$copula)) cat(sprintf("Copula: %s, Freiheitsgrade %.1f%s\n", x$copula$family, x$copula$df,
                                      if (length(x$stress)) paste0(", Stress: ", paste(sprintf("%s in [%g, %g]", names(x$stress),
                                        vapply(x$stress, `[`, 0, 1), vapply(x$stress, `[`, 0, 2)), collapse = "; ")) else ""))
  s <- x$summary
  print(data.frame(Variable = s$var, `Mittel vorher` = sprintf("%.3f", s$mean_prior), `Mittel nachher` = sprintf("%.3f", s$mean_post),
                   `Sd vorher` = sprintf("%.3f", s$sd_prior), `Sd nachher` = sprintf("%.3f", s$sd_post), check.names = FALSE), row.names = FALSE)
  cat("\nKorrelation nachher\n"); print(round(x$correlation, 3))
  invisible(x)
}

#' Portfolio-Kennzahlen auf Szenarien
#'
#' Berechnet die Portfoliorendite \eqn{r_j = \sum_i w_i X_{ji}} je Szenario
#' und daraus Kennzahlen, gewichtet mit den Szenario-Wahrscheinlichkeiten
#' \code{x$prob} (z. B. nach [scenario_entropy_pooling()]). Quantile sind die
#' kleinste Szenariorendite, bei der die kumulierte Wahrscheinlichkeit den
#' Wert erreicht. Der CVaR ist der erwartete Verlust in der
#' Wahrscheinlichkeitsmasse \code{alpha} der schlechtesten Szenarien
#' (Rockafellar & Uryasev 2002): Szenarien unterhalb des VaR zaehlen voll,
#' das Grenzszenario (das den VaR bestimmt) mit dem Teil seiner
#' Wahrscheinlichkeit, der die Masse auf \code{alpha} auffuellt. Damit ist
#' der CVaR kohaerent und faellt monoton in \code{alpha}.
#'
#' @param x Objekt der Klasse \code{SimLevScenarios} aus
#'   [scenario_entropy_pooling()] oder [scenario_copula()].
#' @param weights Benannter Gewichtsvektor (Anteile, Namen = Anlagespalten
#'   der Szenarien); wird nicht normiert.
#' @param alpha Tail-Wahrscheinlichkeit als Anteil fuer VaR und CVaR
#'   (Standard 0.05).
#' @return Benannter numerischer Vektor: \code{mean}, \code{volatility},
#'   \code{var}, \code{cvar} (Verluste positiv), \code{q05}, \code{q50},
#'   \code{q95} (Quantile der Portfoliorendite mit Vorzeichen) in der Einheit
#'   der Szenarien (bei Kursdaten Prozent je Periode) sowie
#'   \code{prob_loss} (Wahrscheinlichkeit einer negativen Rendite als Anteil
#'   0 bis 1).
#' @seealso [scenario_entropy_pooling()], [scenario_copula()], [scenario_crisis()],
#'   [portfolio_risk_contributions()].
#' @references Rockafellar, R. T. & Uryasev, S. (2002), Conditional
#'   value-at-risk for general loss distributions, Journal of Banking &
#'   Finance 26(7), 1443-1471.
#' @examples
#' set.seed(1); X <- data.frame(aktien = rnorm(1000, 0.15, 2), anleihen = rnorm(1000, 0.05, 0.6))
#' ep <- scenario_entropy_pooling(X, c("aktien", "anleihen"), list(view_mean("aktien", -0.2)))
#' scenario_risk(ep, c(aktien = 0.6, anleihen = 0.4))
#' @export
scenario_risk <- function(x, weights, alpha = 0.05) {
  if (!inherits(x, "SimLevScenarios")) stop(chk_msg("c.m_scenario_risk"))
  if (is.factor(alpha) || !is.numeric(alpha) || length(alpha) != 1 || !is.finite(alpha) || alpha <= 0 || alpha >= 1)   # seit 1.6.4 ohne Wert
    stop(chk_msg("c.m_scenario_risk_2"))
  if (is.factor(weights) || !is.numeric(weights) || !is.null(dim(weights)) || is.null(names(weights)) || any(names(weights) == ""))
    stop(chk_msg("c.m_scenario_risk_3"))
  if (!all(is.finite(weights))) chk_stop("e3.werte", "scenario_risk", "weights")   # seit 1.6.4 (B-026)
  if (anyDuplicated(names(weights))) chk_stop("e2.doppelt", "scenario_risk", "weights")
  unk <- setdiff(names(weights), names(x$scenarios))
  if (length(unk)) stop(sprintf("scenario_risk: unbekannte Anlage(n) %s.", paste0("'", unk, "'", collapse = ", ")))
  X <- as.matrix(x$scenarios[, names(weights), drop = FALSE]); q <- x$prob
  r <- unname(drop(X %m% weights))
  o <- order(r); cw <- cumsum(q[o])
  # seit 1.6.5 (CR2-4): Vergleich mit Toleranz wie quantile(type = 1) (bis 1.6.4 ein Szenario daneben, wenn die
  # Summe der Gewichte knapp unter a blieb)
  qf <- function(a) r[o][which(cw >= a - 4 * .Machine$double.eps * a)[1]]
  var_a <- -qf(alpha)
  # CVaR nach Rockafellar & Uryasev (2002): Masse alpha der schlechtesten Szenarien, Grenzszenario anteilig
  take <- pmin(q[o], pmax(0, alpha - c(0, cw[-length(cw)])))
  cvar <- -sum(take * r[o]) / sum(take)
  m <- sum(q * r)
  c(mean = m, volatility = sqrt(sum(q * (r - m)^2)), var = var_a, cvar = cvar, q05 = qf(0.05), q50 = qf(0.5),
    q95 = qf(0.95), prob_loss = sum(q[r < 0]))
}

#' Historische Krisenfenster
#' @keywords internal
#' @noRd
.default_crises <- data.frame(
  crisis = c("\u00d6lkrise 1973/74", "Schwarzer Montag 1987", "Dotcom 2000-02", "Finanzkrise 2007-09",
             "Eurokrise 2011", "Covid 2020", "Inflation/Zinsen 2022"),
  start = as.Date(c("1973-01-11", "1987-08-25", "2000-03-24", "2007-10-09", "2011-04-29", "2020-02-19", "2022-01-03")),
  end = as.Date(c("1974-10-03", "1987-12-04", "2002-10-09", "2009-03-09", "2011-10-03", "2020-03-23", "2022-10-12")),
  stringsAsFactors = FALSE)

#' Portfolio durch historische Krisen fuehren
#'
#' Rechnet ein heutiges Portfolio durch historische Krisenfenster
#' (Standard: grosse Aktienkrisen von 1973 bis 2022, Hoch bis Tief des
#' US-Aktienmarkts) und meldet Rendite, maximalen Drawdown und die
#' Erholungsdauer nach dem Fensterende, je Anlage und fuer das Portfolio.
#' Das Fenster beginnt an der ersten Datenzeile ab \code{start} und endet an
#' der letzten Zeile bis \code{end}; fehlende Kurse werden mit dem letzten
#' Wert fortgeschrieben. Krisen ausserhalb des Datenzeitraums (oder mit
#' fehlendem Startkurs einer Anlage) werden uebersprungen; liegt keine im
#' Zeitraum, bricht die Funktion ab.
#'
#' Eingebaute Krisen (\code{crises = NULL}): Oelkrise 1973/74
#' (1973-01-11 bis 1974-10-03), Schwarzer Montag 1987 (1987-08-25 bis
#' 1987-12-04), Dotcom 2000-02 (2000-03-24 bis 2002-10-09), Finanzkrise
#' 2007-09 (2007-10-09 bis 2009-03-09), Eurokrise 2011 (2011-04-29 bis
#' 2011-10-03), Covid 2020 (2020-02-19 bis 2020-03-23), Inflation/Zinsen
#' 2022 (2022-01-03 bis 2022-10-12).
#'
#' @param data data.frame mit Spalte \code{date} (Date) und Kursspalten
#'   (Kursniveaus, keine Renditen, positiv), typischerweise taeglich. Die
#'   Zeilen werden nach \code{date} sortiert (mit Hinweis, falls noetig);
#'   fehlende oder doppelte Daten sind ein Fehler.
#' @param weights Benannter Gewichtsvektor (Namen = Kursspalten), wird auf
#'   Summe 1 normiert (Summe muss positiv sein; unbekannte Namen sind ein
#'   Fehler).
#' @param crises data.frame mit \code{crisis} (Name), \code{start},
#'   \code{end} (Date). \code{NULL} (Standard) = eingebaute Liste (siehe
#'   oben).
#' @param rebalance Logisch: \code{FALSE} (Standard, Kaufen und Halten ab
#'   Fensterbeginn) oder \code{TRUE} (an jeder Datenzeile auf die Gewichte
#'   zurueck).
#' @return data.frame je Krise im Datenzeitraum: \code{crisis}, \code{start},
#'   \code{end} (tatsaechlich verwendete Datenzeilen), \code{portfolio}
#'   (Portfoliorendite im Fenster in Prozent), \code{max_drawdown}
#'   (maximaler Drawdown des Portfolios im Fenster in Prozent, negativ),
#'   \code{days_to_recover} (Kalendertage ab Fensterende, bis der
#'   Kaufen-und-Halten-Wert des Portfolios (auch bei \code{rebalance =
#'   TRUE}) wieder den Wert bei Fensterbeginn erreicht; 0 = am Fensterende
#'   nicht darunter; \code{NA} =
#'   nicht erholt bzw. Daten enden) und je Anlage deren Rendite im Fenster in
#'   Prozent.
#' @seealso [scenario_copula()], [scenario_risk()], [regime_subset()],
#'   [series_align()].
#' @examples
#' set.seed(1); n <- 4 * 365
#' d <- data.frame(date = seq.Date(as.Date("2018-01-01"), by = "day", length.out = n))
#' d$aktien <- 100 * cumprod(1 + rnorm(n, 3e-4, 0.012))
#' d$anleihen <- 100 * cumprod(1 + rnorm(n, 1e-4, 0.003))
#' scenario_crisis(d, c(aktien = 0.6, anleihen = 0.4))
#' kr <- data.frame(crisis = "Test", start = as.Date("2019-05-01"), end = as.Date("2019-09-30"))
#' scenario_crisis(d, c(aktien = 0.6, anleihen = 0.4), crises = kr, rebalance = TRUE)
#' @export
scenario_crisis <- function(data, weights, crises = NULL, rebalance = FALSE) {
  crises <- crises %||% .default_crises
  fn <- "scenario_crisis"
  if (!is.data.frame(data) || !"date" %in% names(data)) stop(chk_msg("c.m_scenario_crisis"))
  if (!is.data.frame(crises) || !all(c("crisis", "start", "end") %in% names(crises)))
    stop(chk_msg("c.m_scenario_crisis_2"))
  if (is.factor(weights) || !is.numeric(weights) || !is.null(dim(weights)) || is.null(names(weights)) || any(names(weights) == "") ||
      any(!is.finite(weights)))
    stop(chk_msg("c.m_scenario_crisis_3"))
  if (anyDuplicated(names(weights))) chk_stop("e2.doppelt", fn, "weights")   # seit 1.6.4 (B-052)
  unk <- setdiff(names(weights), setdiff(names(data), "date"))
  if (length(unk)) stop(sprintf("scenario_crisis: Kursspalte(n) %s fehlen in data.", paste0("'", unk, "'", collapse = ", ")))
  chk_col_nofactor(data, "date", fn)                              # seit 1.6.4 (Entscheidung 15, B-009)
  for (k in names(weights)) .e4_numcol(data, k, fn)
  for (k in c("start", "end")) chk_col_nofactor(crises, k, fn)
  chk_bool1(rebalance, fn, "rebalance")
  if (sum(weights) <= 0) chk_stop("ut3.krise_summe", fn)          # seit 1.6.4 ohne Wert und Zusatz (Entscheidung 8, T3-B2)
  # seit 1.6.5 (K31, CR2-E-1): Anlage mit dem Namen einer Ergebnisspalte ist ein Fehler
  res_cols <- c("crisis", "start", "end", "portfolio", "max_drawdown", "days_to_recover", if (rebalance) "days_to_recover_rebalanced")
  if (length(kol <- intersect(names(weights), res_cols))) chk_stop("c.krise_name", fn, paste0("'", kol, "'", collapse = ", "))
  data <- .dep_sort_dates(data)
  d <- data$date; a <- names(weights); w <- weights / sum(weights)
  crises$start <- .to_date(crises$start, "scenario_crisis: crises$start"); crises$end <- .to_date(crises$end, "scenario_crisis: crises$end")
  P <- vapply(a, function(k) .fill_na(.dep_check_prices(as.numeric(data[[k]]), k, d), "locf", keep_leading = TRUE), numeric(nrow(data)))
  if (!is.matrix(P)) P <- matrix(P, ncol = length(a), dimnames = list(NULL, a))
  rows <- lapply(seq_len(nrow(crises)), function(i) {
    s <- which(d >= crises$start[i])[1]; e <- utils::tail(which(d <= crises$end[i]), 1)
    # seit 1.6.5 (CR2-E-2): Anlagen mit Gewicht 0 zaehlen bei der Pruefung auf fehlende Startkurse nicht
    if (is.na(s) || !length(e) || e <= s || anyNA(P[s, w != 0])) return(NULL)
    # seit 1.6.5 (CR2-E-2): Hinweis bei angeschnittener Krise (Daten beginnen mehr als 7 Tage nach dem Start bzw. enden
    # mehr als 7 Tage vor dem Ende)
    if (as.numeric(d[s] - crises$start[i]) > 7 || as.numeric(crises$end[i] - d[e]) > 7)
      message(chk_msg("c.krise_teil", fn, crises$crisis[i], format(d[s]), format(d[e]), format(crises$start[i]), format(crises$end[i])))
    rel <- sweep(P[s:e, , drop = FALSE], 2, P[s, ], "/")
    nz <- w != 0; Pw <- P[, nz, drop = FALSE]; wn <- w[nz]; relw <- rel[, nz, drop = FALSE]   # Gewicht 0 rechnet nicht mit
    port <- if (rebalance) cumprod(c(1, drop((relw[-1, , drop = FALSE] / relw[-nrow(relw), , drop = FALSE]) %m% wn))) else drop(relw %m% wn)
    dd <- min(port / cummax(port) - 1)
    # seit 1.6.5 (CR2-E-2) auch, wenn das Fenster an der letzten Datenzeile endet (Wert dort >= Start: 0)
    relx <- sweep(Pw[e:length(d), , drop = FALSE], 2, Pw[s, ], "/")
    px <- drop(relx %m% wn)
    k <- which(px >= 1)[1]; after <- if (is.na(k)) NA_real_ else as.numeric(d[e + k - 1] - d[e])
    out_i <- data.frame(crisis = crises$crisis[i], start = d[s], end = d[e], portfolio = 100 * (port[length(port)] - 1),
                        max_drawdown = 100 * dd, days_to_recover = after, stringsAsFactors = FALSE)
    if (rebalance) {                                 # seit 1.6.5 (E-T3-1): Erholung des umgeschichteten Portfolios
      pr <- port[length(port)] * cumprod(c(1, if (e < length(d))
        drop((Pw[(e + 1):length(d), , drop = FALSE] / Pw[e:(length(d) - 1), , drop = FALSE]) %m% wn)))
      kr <- which(pr >= 1)[1]
      out_i$days_to_recover_rebalanced <- if (is.na(kr)) NA_real_ else as.numeric(d[e + kr - 1] - d[e])
    }
    cbind(out_i, data.frame(as.list(stats::setNames(100 * (rel[nrow(rel), ] - 1), a)), check.names = FALSE))
  })
  out <- do.call(rbind, rows)
  if (is.null(out)) chk_stop("c.krise_keine", fn)                 # seit 1.6.5 mit Funktionsnamen (CR2-E-2)
  rownames(out) <- NULL
  out
}

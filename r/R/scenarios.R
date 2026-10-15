# =============================================================================
#  scenarios.R  —  Szenarien mit eigenen Annahmen und Stresstests
# -----------------------------------------------------------------------------
#  entropy_pooling()    gewichtet historische (oder simulierte) Szenarien so
#                       um, dass sie eigene Annahmen ("Views") erfuellen, bei
#                       minimaler relativer Entropie zur Ausgangsverteilung
#                       (Meucci 2008, Fully Flexible Probabilities)
#  view_mean(), view_prob(), view_vol()   Bausteine fuer Annahmen
#  copula_scenarios()   Szenarien aus t- bzw. Gauss-Copula mit empirischen
#                       Raendern, optional unter Stress (bedingt auf ein
#                       Quantilband einzelner Anlagen)
#  scenario_risk()      Portfolio-Kennzahlen auf (gewichteten) Szenarien
#  crisis_replay()      ein Portfolio durch historische Krisenfenster
# =============================================================================

#' Annahmen fuer Entropy Pooling
#'
#' Bausteine fuer die Annahmen ("Views") von [entropy_pooling()]. Jede
#' Funktion beschreibt nur die Annahme; geprueft und umgesetzt wird sie erst
#' in [entropy_pooling()] auf der Szenario-Tabelle. Werte stehen in der
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
#' @param op Art der Bedingung: \code{"="} (Standard), \code{"<="} oder
#'   \code{">="}.
#' @return Liste mit \code{type} (\code{"mean"}, \code{"prob"} oder
#'   \code{"vol"}), \code{var} bzw. \code{expr}, \code{value} und \code{op}.
#' @seealso [entropy_pooling()], [scenario_risk()].
#' @examples
#' set.seed(1); X <- data.frame(aktien = rnorm(1000, 0.15, 2), anleihen = rnorm(1000, 0.05, 0.6))
#' v <- list(view_mean("aktien", -0.2), view_prob("aktien < -2", 0.15, ">="),
#'           view_vol("anleihen", 0.8))
#' ep <- entropy_pooling(X, c("aktien", "anleihen"), v)
#' ep$summary
#' @name views
NULL

#' @rdname views
#' @export
view_mean <- function(var, value, op = c("=", "<=", ">=")) list(type = "mean", var = var, value = .view_value(value, "view_mean"), op = match.arg(op))

#' Zielwert einer Annahme pruefen (eine endliche Zahl, ggf. mit Bereich)
#' @keywords internal
#' @noRd
.view_value <- function(value, what, lo = -Inf, hi = Inf) {
  if (!is.numeric(value) || length(value) != 1 || !is.finite(value) || value < lo || value > hi)
    stop(sprintf("%s: value muss eine endliche Zahl%s sein (erhalten: %s).", what,
                 if (is.finite(lo) && is.finite(hi)) sprintf(" zwischen %g und %g", lo, hi) else if (is.finite(lo)) sprintf(" >= %g", lo) else "",
                 paste(format(value), collapse = ", ")))
  value
}

#' @rdname views
#' @export
view_prob <- function(expr, value, op = c("=", "<=", ">=")) list(type = "prob", expr = expr, value = .view_value(value, "view_prob", 0, 1), op = match.arg(op))

#' @rdname views
#' @export
view_vol <- function(var, value, op = c("=", "<=", ">=")) list(type = "vol", var = var, value = .view_value(value, "view_vol", 0), op = match.arg(op))

#' Szenario-Matrix aus Daten (Renditen in Prozent je Periode, Zustaende verzoegert)
#' @keywords internal
#' @noRd
.scen_frame <- function(x, assets, states, frequency) {
  if (is.data.frame(x) && "date" %in% names(x)) {
    rd <- .dep_returns(x, assets, states, frequency)
    for (a in assets) rd[[a]] <- 100 * expm1(rd[[a]])
    return(rd[stats::complete.cases(rd), , drop = FALSE])
  }
  as.data.frame(x)
}

#' Entropy Pooling: Szenarien auf eigene Annahmen umgewichten
#'
#' Sucht die Szenario-Wahrscheinlichkeiten \eqn{q}, die alle Annahmen erfuellen
#' und dabei der Ausgangsverteilung \eqn{p} (Standard: gleichgewichtete
#' Historie) am naechsten kommen,
#' \deqn{\min_q \sum_j q_j \log(q_j / p_j)\quad\text{u. d. N.}\quad Aq = b,\; Gq \le h,\; \textstyle\sum q = 1.}
#' Geloest ueber das duale Problem (L-BFGS-B). Damit lassen sich Fragen
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
#'   [scenario_risk()], [copula_scenarios()], [dependence_analysis()].
#' @references Meucci, A. (2008), Fully Flexible Views: Theory and Practice,
#'   Risk 21(10), 97-102.
#' @examples
#' set.seed(1); X <- data.frame(aktien = rnorm(1000, 0.15, 2), anleihen = rnorm(1000, 0.05, 0.6))
#' ep <- entropy_pooling(X, c("aktien", "anleihen"), list(view_mean("aktien", -0.2)))
#' ep
#' @export
entropy_pooling <- function(x, assets, views, states = NULL, frequency = c("week", "day", "month"), prior = NULL) {
  frequency <- match.arg(frequency)
  S <- .scen_frame(x, assets, states, frequency)
  Tn <- nrow(S)
  if (!is.null(prior) && (!is.numeric(prior) || length(prior) != Tn || any(!is.finite(prior)) || any(prior < 0) || sum(prior) <= 0))
    stop(sprintf("entropy_pooling: prior muss %d endliche Werte >= 0 mit positiver Summe haben (einer je Szenario; erhalten: L\u00e4nge %d%s).",
                 Tn, length(prior), if (is.numeric(prior) && any(prior < 0, na.rm = TRUE)) ", negative Werte" else ""))
  p <- prior %||% rep(1 / Tn, Tn); p <- p / sum(p)
  vars <- intersect(c(assets, states), names(S))
  m0 <- vapply(vars, function(v) sum(p * S[[v]]), 0)
  mean_view <- stats::setNames(rep(NA_real_, length(vars)), vars)
  for (v in views) if (v$type == "mean" && v$op == "=") mean_view[v$var] <- v$value
  rows <- lapply(views, function(v) {
    f <- switch(v$type,
      mean = S[[v$var]],
      prob = as.numeric(eval(parse(text = v$expr), S, parent.frame())),
      vol = { mu <- if (is.na(mean_view[v$var])) m0[v$var] else mean_view[v$var]; (S[[v$var]] - mu)^2 },
      stop("Unbekannter View-Typ."))
    if (is.null(f) || length(f) != Tn) stop(sprintf("View '%s' passt nicht zu den Szenarien.", v$var %||% v$expr))
    if (v$type == "vol" && !(is.numeric(v$value) && v$value >= 0)) stop("view_vol: Standardabweichung muss >= 0 sein.")
    val <- if (v$type == "vol") v$value^2 else v$value
    sg <- switch(v$op, "=" = 0, "<=" = 1, ">=" = -1)
    list(f = if (sg == -1) -f else f, b = if (sg == -1) -val else val, ineq = sg != 0)
  })
  if (!length(rows)) { q <- p } else {
  A <- do.call(rbind, lapply(rows, `[[`, "f")); b <- vapply(rows, `[[`, 0, "b"); ineq <- vapply(rows, `[[`, TRUE, "ineq")
  dual <- function(l) {
    e <- -drop(crossprod(A, l)); mx <- max(e); w <- p * exp(e - mx); Z <- sum(w)
    list(val = log(Z) + mx + sum(l * b), q = w / Z)
  }
  fn <- function(l) dual(l)$val
  gr <- function(l) { q <- dual(l)$q; b - drop(A %*% q) }
  lower <- ifelse(ineq, 0, -Inf)
  o <- stats::optim(rep(0, length(b)), fn, gr, method = "L-BFGS-B", lower = lower,
                    control = list(maxit = 5000, factr = 1e3, pgtol = 1e-12))
  q <- dual(o$par)$q
  viol <- drop(A %*% q) - b; viol[ineq] <- pmax(viol[ineq], 0)
  if (max(abs(viol)) > 1e-4 * max(1, abs(b))) warning(sprintf("Annahmen nicht vollst\u00e4ndig erf\u00fcllbar (Abweichung %.2e).", max(abs(viol))))
  }
  wsd <- function(v, w) { m <- sum(w * v); sqrt(sum(w * (v - m)^2)) }
  summ <- data.frame(var = vars, mean_prior = m0, mean_post = vapply(vars, function(v) sum(q * S[[v]]), 0),
                     sd_prior = vapply(vars, function(v) wsd(S[[v]], p), 0), sd_post = vapply(vars, function(v) wsd(S[[v]], q), 0),
                     row.names = NULL, stringsAsFactors = FALSE)
  Xa <- as.matrix(S[, assets, drop = FALSE]); mu <- colSums(Xa * q); C <- crossprod(sweep(Xa, 2, mu) * sqrt(q))
  structure(list(scenarios = S, prob = q, prior = p, assets = assets, states = states, views = views,
                 effective_n = exp(-sum(q[q > 0] * log(q[q > 0]))), summary = summ,
                 correlation = stats::cov2cor(C), frequency = frequency, kind = "entropy_pooling"),
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
#' Die Periodenrenditen werden wie bei [entropy_pooling()] gebildet
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
#' @param family Copula: \code{"t"} (Standard) oder \code{"gaussian"}.
#' @param stress Optional benannte Liste von Quantilbaendern je Anlage als
#'   Anteile \code{c(von, bis)} mit 0 <= von < bis <= 1, z. B.
#'   \code{list(aktien = c(0, 0.05))} (schlechteste 5 % der Perioden).
#'   Unbenannte Eintraege, unbekannte Anlagen und ungueltige Baender sind ein
#'   Fehler.
#'   \code{NULL} (Standard) = unbedingte Simulation.
#' @param frequency Renditefrequenz bei Kursdaten: \code{"week"} (Standard,
#'   ISO-Woche), \code{"day"} oder \code{"month"}.
#' @param seed Startwert der Ziehung. Mit Startwert ist das Ergebnis reproduzierbar und der
#'   Zufallszustand der Sitzung bleibt unveraendert; mit `NULL` wird der
#'   Zufallsstrom der Sitzung normal weitergezogen.
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
#' @seealso [scenario_risk()], [entropy_pooling()], [fit_copula()],
#'   [crisis_replay()].
#' @examples
#' set.seed(1); n <- 3 * 365
#' d <- data.frame(date = seq.Date(as.Date("2015-01-01"), by = "day", length.out = n))
#' e <- rnorm(n)
#' d$aktien <- 100 * cumprod(1 + 0.01 * e)
#' d$anleihen <- 100 * cumprod(1 + 0.004 * (0.3 * e + rnorm(n)))
#' cs <- copula_scenarios(d, c("aktien", "anleihen"), n = 2000,
#'                        stress = list(aktien = c(0, 0.05)), seed = 1)
#' cs
#' scenario_risk(cs, c(aktien = 0.6, anleihen = 0.4))
#' @export
copula_scenarios <- function(x, assets, n = 10000L, family = c("t", "gaussian"), stress = NULL,
                             frequency = c("week", "day", "month"), seed = NULL) {
  family <- match.arg(family); frequency <- match.arg(frequency)
  S <- .scen_frame(x, assets, NULL, frequency)
  X <- as.matrix(S[, assets, drop = FALSE]); k <- ncol(X); Tn <- nrow(X)
  U <- apply(X, 2, .pobs)
  tau <- .kendall(X); R <- sin(pi * tau / 2)
  ev <- eigen(R, symmetric = TRUE); if (min(ev$values) < 1e-6) {
    R <- ev$vectors %*% diag(pmax(ev$values, 1e-6)) %*% t(ev$vectors); R <- stats::cov2cor(R) }
  Ri <- solve(R); ldR <- as.numeric(determinant(R)$modulus)
  ll_t <- function(nu) {
    Z <- stats::qt(U, nu); q <- rowSums((Z %*% Ri) * Z)
    sum(lgamma((nu + k) / 2) + (k - 1) * lgamma(nu / 2) - k * lgamma((nu + 1) / 2) - 0.5 * ldR -
          (nu + k) / 2 * log1p(q / nu) + (nu + 1) / 2 * rowSums(log1p(Z^2 / nu)))
  }
  nu <- if (family == "t") stats::optimize(function(v) -ll_t(v), c(2.1, 100))$minimum else Inf
  qmarg <- lapply(seq_len(k), function(j) { s <- sort(X[, j]); function(u) stats::approx((seq_len(Tn) - 0.5) / Tn, s, u, rule = 2)$y })
  if (!is.null(stress)) {
    if (!is.list(stress) || !length(stress) || is.null(names(stress)) || any(names(stress) == "") || anyDuplicated(names(stress)))
      stop("stress: benannte Liste von Quantilb\u00e4ndern je Anlage erwartet, z. B. list(aktien = c(0, 0.05)).")
    unk <- setdiff(names(stress), assets)
    if (length(unk)) stop(sprintf("stress: unbekannte Anlage(n) %s; vorhanden: %s.", paste0("'", unk, "'", collapse = ", "), paste(assets, collapse = ", ")))
    for (a in names(stress)) { b <- stress[[a]]
      if (!is.numeric(b) || length(b) != 2 || any(!is.finite(b)) || b[1] < 0 || b[2] > 1 || b[1] >= b[2])
        stop(sprintf("stress: Band f\u00fcr '%s' muss c(von, bis) mit 0 <= von < bis <= 1 sein (Anteile, keine Prozent; erhalten: %s).",
                     a, paste(format(b), collapse = ", "))) }
  }
  sim <- .with_rng_restore(seed = seed, {
    st <- if (is.null(stress)) integer(0) else match(names(stress), assets)
    Z <- matrix(0, n, k)
    if (length(st) == 1) {
      band <- stress[[1]]; u <- stats::runif(n, band[1], band[2])
      Z[, st] <- if (is.finite(nu)) stats::qt(u, nu) else stats::qnorm(u)
    } else if (length(st) > 1) {
      # mehrere Stress-Anlagen: gemeinsam aus ihrer Copula, bedingt auf alle Baender (Verwerfung)
      ks <- length(st); Ls <- chol(R[st, st, drop = FALSE])
      lo <- vapply(stress, `[`, 0, 1); hi <- vapply(stress, `[`, 0, 2)
      Zs <- matrix(0, 0, ks); drawn <- 0; m <- 1e5
      repeat {
        E <- matrix(stats::rnorm(m * ks), m) %*% Ls
        if (is.finite(nu)) E <- E / sqrt(stats::rchisq(m, nu) / nu)
        Ub <- if (is.finite(nu)) stats::pt(E, nu) else stats::pnorm(E)
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
        Rss <- R[st, st, drop = FALSE]; Rrs <- R[rest, st, drop = FALSE]; Rss_i <- solve(Rss)
        M <- Z[, st, drop = FALSE] %*% t(Rrs %*% Rss_i)
        Sc <- R[rest, rest, drop = FALSE] - Rrs %*% Rss_i %*% t(Rrs)
        L <- chol(Sc + diag(1e-12, length(rest)))
        E <- matrix(stats::rnorm(n * length(rest)), n) %*% L
        if (is.finite(nu)) {
          dq <- rowSums((Z[, st, drop = FALSE] %*% Rss_i) * Z[, st, drop = FALSE])
          scale <- sqrt((nu + dq) / (nu + length(st)) / (stats::rchisq(n, nu + length(st)) / (nu + length(st))))
          Z[, rest] <- M + E * scale
        } else Z[, rest] <- M + E
      }
    } else {
      Z <- matrix(stats::rnorm(n * k), n) %*% chol(R)
      if (is.finite(nu)) Z <- Z / sqrt(stats::rchisq(n, nu) / nu)
    }
    Z
  })
  V <- if (is.finite(nu)) stats::pt(sim, if (length(stress)) nu + 0 else nu) else stats::pnorm(sim)
  if (length(stress) && is.finite(nu)) {
    rest <- setdiff(seq_len(k), match(names(stress), assets))
    V[, rest] <- stats::pt(sim[, rest], nu)
  }
  Y <- vapply(seq_len(k), function(j) qmarg[[j]](V[, j]), numeric(n))
  if (!is.matrix(Y)) Y <- matrix(Y, ncol = k)
  colnames(Y) <- assets
  out <- as.data.frame(Y)
  structure(list(scenarios = out, prob = rep(1 / n, n), prior = rep(1 / n, n), assets = assets, states = NULL,
                 effective_n = n, copula = list(family = family, correlation = R, df = nu), stress = stress,
                 summary = data.frame(var = assets, mean_prior = colMeans(X), mean_post = colMeans(Y),
                                      sd_prior = apply(X, 2, stats::sd), sd_post = apply(Y, 2, stats::sd), row.names = NULL),
                 correlation = stats::cor(Y), frequency = frequency, kind = "copula"),
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
#' \code{x$prob} (z. B. nach [entropy_pooling()]). Quantile sind die
#' kleinste Szenariorendite, bei der die kumulierte Wahrscheinlichkeit den
#' Wert erreicht. Der CVaR ist der erwartete Verlust in der
#' Wahrscheinlichkeitsmasse \code{alpha} der schlechtesten Szenarien
#' (Rockafellar & Uryasev 2002): Szenarien unterhalb des VaR zaehlen voll,
#' das Grenzszenario (das den VaR bestimmt) mit dem Teil seiner
#' Wahrscheinlichkeit, der die Masse auf \code{alpha} auffuellt. Damit ist
#' der CVaR kohaerent und faellt monoton in \code{alpha}.
#'
#' @param x Objekt der Klasse \code{SimLevScenarios} aus
#'   [entropy_pooling()] oder [copula_scenarios()].
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
#' @seealso [entropy_pooling()], [copula_scenarios()], [crisis_replay()],
#'   [risk_contributions()].
#' @references Rockafellar, R. T. & Uryasev, S. (2002), Conditional
#'   value-at-risk for general loss distributions, Journal of Banking &
#'   Finance 26(7), 1443-1471.
#' @examples
#' set.seed(1); X <- data.frame(aktien = rnorm(1000, 0.15, 2), anleihen = rnorm(1000, 0.05, 0.6))
#' ep <- entropy_pooling(X, c("aktien", "anleihen"), list(view_mean("aktien", -0.2)))
#' scenario_risk(ep, c(aktien = 0.6, anleihen = 0.4))
#' @export
scenario_risk <- function(x, weights, alpha = 0.05) {
  if (!inherits(x, "SimLevScenarios")) stop("x muss ein SimLevScenarios sein.")
  if (!is.numeric(alpha) || length(alpha) != 1 || !is.finite(alpha) || alpha <= 0 || alpha >= 1)
    stop(sprintf("scenario_risk: alpha muss ein Anteil echt zwischen 0 und 1 sein (erhalten: %s).", paste(format(alpha), collapse = ", ")))
  if (!is.numeric(weights) || is.null(names(weights)) || any(names(weights) == ""))
    stop("scenario_risk: weights muss ein benannter numerischer Vektor sein (Namen = Anlagespalten der Szenarien).")
  unk <- setdiff(names(weights), names(x$scenarios))
  if (length(unk)) stop(sprintf("scenario_risk: unbekannte Anlage(n) %s.", paste0("'", unk, "'", collapse = ", ")))
  X <- as.matrix(x$scenarios[, names(weights), drop = FALSE]); q <- x$prob
  r <- unname(drop(X %*% weights))
  o <- order(r); cw <- cumsum(q[o])
  qf <- function(a) r[o][which(cw >= a)[1]]
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
#' @seealso [copula_scenarios()], [scenario_risk()], [regime_subset()],
#'   [align_series()].
#' @examples
#' set.seed(1); n <- 4 * 365
#' d <- data.frame(date = seq.Date(as.Date("2018-01-01"), by = "day", length.out = n))
#' d$aktien <- 100 * cumprod(1 + rnorm(n, 3e-4, 0.012))
#' d$anleihen <- 100 * cumprod(1 + rnorm(n, 1e-4, 0.003))
#' crisis_replay(d, c(aktien = 0.6, anleihen = 0.4))
#' kr <- data.frame(crisis = "Test", start = as.Date("2019-05-01"), end = as.Date("2019-09-30"))
#' crisis_replay(d, c(aktien = 0.6, anleihen = 0.4), crises = kr, rebalance = TRUE)
#' @export
crisis_replay <- function(data, weights, crises = NULL, rebalance = FALSE) {
  crises <- crises %||% .default_crises
  if (!is.data.frame(data) || !"date" %in% names(data)) stop("crisis_replay: data.frame mit Spalte 'date' erwartet.")
  if (!is.data.frame(crises) || !all(c("crisis", "start", "end") %in% names(crises)))
    stop("crisis_replay: crises muss ein data.frame mit den Spalten crisis, start, end sein.")
  if (!is.numeric(weights) || is.null(names(weights)) || any(names(weights) == "") || any(!is.finite(weights)))
    stop("crisis_replay: weights muss ein benannter numerischer Vektor ohne NA sein (Namen = Kursspalten).")
  unk <- setdiff(names(weights), setdiff(names(data), "date"))
  if (length(unk)) stop(sprintf("crisis_replay: Kursspalte(n) %s fehlen in data.", paste0("'", unk, "'", collapse = ", ")))
  if (sum(weights) <= 0) stop(sprintf("crisis_replay: Summe der Gewichte muss positiv sein (erhalten %g); sie wird auf 1 normiert.", sum(weights)))
  data <- .dep_sort_dates(data)
  d <- data$date; a <- names(weights); w <- weights / sum(weights)
  crises$start <- .to_date(crises$start, "crisis_replay: crises$start"); crises$end <- .to_date(crises$end, "crisis_replay: crises$end")
  P <- vapply(a, function(k) .fill_na(.dep_check_prices(as.numeric(data[[k]]), k, d), "locf", keep_leading = TRUE), numeric(nrow(data)))
  if (!is.matrix(P)) P <- matrix(P, ncol = length(a), dimnames = list(NULL, a))
  rows <- lapply(seq_len(nrow(crises)), function(i) {
    s <- which(d >= crises$start[i])[1]; e <- utils::tail(which(d <= crises$end[i]), 1)
    if (is.na(s) || !length(e) || e <= s || anyNA(P[s, ])) return(NULL)
    rel <- sweep(P[s:e, , drop = FALSE], 2, P[s, ], "/")
    port <- if (rebalance) cumprod(c(1, drop((rel[-1, , drop = FALSE] / rel[-nrow(rel), , drop = FALSE]) %*% w))) else drop(rel %*% w)
    dd <- min(port / cummax(port) - 1)
    pk <- max(port)
    after <- if (e < length(d)) {
      relx <- sweep(P[e:length(d), , drop = FALSE], 2, P[s, ], "/")
      px <- drop(relx %*% w)
      k <- which(px >= 1)[1]; if (is.na(k)) NA_real_ else as.numeric(d[e + k - 1] - d[e])
    } else NA_real_
    data.frame(crisis = crises$crisis[i], start = d[s], end = d[e], portfolio = 100 * (port[length(port)] - 1),
               max_drawdown = 100 * dd, days_to_recover = after,
               as.list(stats::setNames(100 * (rel[nrow(rel), ] - 1), a)), check.names = FALSE, stringsAsFactors = FALSE)
  })
  out <- do.call(rbind, rows)
  if (is.null(out)) stop("Keine Krise liegt im Datenzeitraum.")
  rownames(out) <- NULL
  out
}

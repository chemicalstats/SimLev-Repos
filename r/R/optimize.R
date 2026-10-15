# =============================================================================
#  optimize.R  —  Portfolio-Optimierung und Risikozerlegung
# -----------------------------------------------------------------------------
#  portfolio_optimize()    Minimum-Varianz, Mean-Variance, maximale Sharpe
#                          Ratio, maximale Diversifikation, Risikoparitaet
#                          (Risikobudgets), Hierarchical Risk Parity, minimaler
#                          CVaR, inverse Volatilitaet, Gleichgewichtung; Box-
#                          Grenzen, Ledoit-Wolf-Schaetzer, Resampling (Michaud)
#  efficient_frontier()    Effizienzgrenze unter denselben Grenzen
#  rolling_optimization()  Optimierung in rollierenden Fenstern -> Zielgewichte
#                          fuer tactical_simulation() (out of sample)
#  risk_contributions()    Euler-Zerlegung von Volatilitaet bzw. CVaR
#
#  Alle Loeser ohne Zusatzpakete: beschleunigter projizierter Gradient (FISTA)
#  auf {sum w = 1, lower <= w <= upper}, gedaempftes Newton-Verfahren fuer die
#  Risikoparitaet (Spinu 2013), Glaettung fuer CVaR (Rockafellar & Uryasev
#  2000), Clusterbaum aus stats::hclust fuer HRP (Lopez de Prado 2016).
# =============================================================================

#' Periodenrenditen fuer die Optimierung (einfache Renditen)
#' @keywords internal
#' @noRd
.opt_returns <- function(x, assets = NULL, frequency = "week") {
  if (inherits(x, "SimLevOptReturns")) {                        # intern (cpcv_portfolio): Renditen mit ppy
    R <- x$R; if (!is.null(assets)) R <- R[, assets, drop = FALSE]
    return(list(R = R, ppy = x$ppy, dates = NULL))
  }
  if (is.data.frame(x) && "date" %in% names(x)) {
    assets <- assets %||% setdiff(names(x)[vapply(x, is.numeric, TRUE)], "date")
    rd <- .dep_returns(x, assets, NULL, frequency)
    R <- expm1(as.matrix(rd[, assets, drop = FALSE]))
    ppy <- (nrow(rd) - 1) / (as.numeric(rd$date[nrow(rd)] - rd$date[1]) / 365.25)
    return(list(R = R, ppy = ppy, dates = rd$date))
  }
  R <- as.matrix(x)
  if (is.null(colnames(R))) colnames(R) <- paste0("A", seq_len(ncol(R)))
  if (!is.null(assets)) {
    miss <- setdiff(assets, colnames(R))
    if (length(miss)) stop(sprintf("Spalten fehlen: %s", paste(miss, collapse = ", ")))
    R <- R[, assets, drop = FALSE]
  }
  if (!is.numeric(R)) stop("x muss Kursdaten mit Spalte 'date' oder eine numerische Renditematrix sein.")
  .opt_check_finite(R)
  list(R = R[stats::complete.cases(R), , drop = FALSE], ppy = switch(frequency, day = 252, week = 52, month = 12), dates = NULL)
}

#' Unendliche Renditen (Inf, -Inf) einer Renditematrix mit Spalte und Zeile melden
#' (Kursdaten prueft bereits .dep_returns())
#' @keywords internal
#' @noRd
.opt_check_finite <- function(R) {
  bad <- which(is.infinite(R), arr.ind = TRUE)
  if (!nrow(bad)) return(invisible())
  cols <- unique(colnames(R)[bad[, 2]])
  stop(sprintf("x: unendliche Rendite(n) (Inf/-Inf) in der Renditematrix, Spalte(n) %s (%d Wert(e), erster in Zeile %d); Renditen als endliche Anteile angeben (fehlende Werte als NA).",
               paste0("'", cols, "'", collapse = ", "), nrow(bad), min(bad[bad[, 2] == bad[1, 2], 1])))
}

#' alpha pruefen: Tail-Wahrscheinlichkeit als Anteil in (0, 0.5]
#' @keywords internal
#' @noRd
.opt_check_alpha <- function(alpha, fn) {
  if (is.numeric(alpha) && length(alpha) == 1 && is.finite(alpha) && alpha > 0 && alpha <= 0.5) return(invisible())
  hint <- if (is.numeric(alpha) && length(alpha) == 1 && is.finite(alpha)) {
    if (alpha >= 1) sprintf(" - als Anteil angeben (z. B. %g statt %g)", alpha / 100, alpha)
    else if (alpha > 0.5) sprintf(" - gemeint ist der Tail-Anteil, nicht das Konfidenzniveau (%g -> alpha = %g)", alpha, 1 - alpha)
    else "" } else ""
  stop(sprintf("%s: alpha muss die Tail-Wahrscheinlichkeit als Anteil in (0, 0.5] sein, z. B. 0.05 = schlechteste 5 %% (erhalten: %s)%s.",
               fn, paste(format(alpha), collapse = ", "), hint))
}

#' Kovarianzschaetzer
#'
#' sample: Stichprobe; ledoit_wolf: Schrumpfung auf skalierte Einheitsmatrix
#' (Ledoit & Wolf 2004); ewma: exponentiell gewichtet (Halbwertszeit ein
#' Viertel der Stichprobe, hoechstens 52 Perioden); denoise: Eigenwerte der
#' Korrelationsmatrix unterhalb der Marchenko-Pastur-Grenze gemittelt (Laloux
#' et al. 1999; Lopez de Prado 2020); gerber: Gerber-Statistik (Gerber et al.
#' 2022), robust gegen kleine Bewegungen und Ausreisser.
#' @keywords internal
#' @noRd
.opt_cov <- function(R, type = c("sample", "ledoit_wolf", "ewma", "denoise", "gerber")) {
  type <- match.arg(type)
  S <- stats::cov(R); N <- ncol(R); Tn <- nrow(R)
  if (type == "sample" || N < 2) return(S)
  psd <- function(M) { e <- eigen(M, symmetric = TRUE); M2 <- e$vectors %*% diag(pmax(e$values, 1e-12), N) %*% t(e$vectors)
                       dimnames(M2) <- dimnames(S); (M2 + t(M2)) / 2 }
  if (type == "ledoit_wolf") {
    X <- sweep(R, 2, colMeans(R))
    S1 <- crossprod(X) / Tn
    m <- sum(diag(S1)) / N
    nrm <- function(A) sum(A^2) / N
    d2 <- nrm(S1 - diag(m, N))
    b2 <- min(d2, sum(vapply(seq_len(Tn), function(t) nrm(tcrossprod(X[t, ]) - S1), 0)) / Tn^2)
    a2 <- d2 - b2
    Sh <- (b2 / d2) * diag(m, N) + (a2 / d2) * S1
    dimnames(Sh) <- dimnames(S)
    return(Sh * Tn / (Tn - 1))
  }
  if (type == "ewma") {
    hl <- min(52, max(5, Tn / 4)); lam <- 0.5^(1 / hl)
    w <- lam^((Tn - 1):0); w <- w / sum(w)
    mu <- colSums(R * w); X <- sweep(R, 2, mu)
    return(psd(crossprod(X * sqrt(w)) / (1 - sum(w^2))))
  }
  sd <- sqrt(diag(S))
  if (type == "denoise") {
    pos <- sd > 0
    if (!all(pos)) {                                 # Anlagen ohne Schwankung: Kovarianz 0, Rest entrauschen
      out <- S * 0
      if (sum(pos) > 0) out[pos, pos] <- .opt_cov(R[, pos, drop = FALSE], "denoise")
      return(out)
    }
    C <- stats::cov2cor(S); e <- eigen(C, symmetric = TRUE)
    lmax <- (1 + sqrt(N / Tn))^2
    noise <- e$values < lmax
    if (sum(noise) > 1) e$values[noise] <- mean(e$values[noise])
    C2 <- e$vectors %*% diag(e$values, N) %*% t(e$vectors); C2 <- stats::cov2cor(C2)
    return(psd(C2 * outer(sd, sd)))
  }
  # Gerber-Statistik (GS2): (n_konkordant - n_diskordant) / (n_konkordant + n_diskordant)
  H <- 0.5 * sd
  Up <- sweep(R, 2, H, ">="); Dn <- sweep(R, 2, -H, "<=")
  Uu <- crossprod(Up * 1); Dd <- crossprod(Dn * 1); Ud <- crossprod(Up * 1, Dn * 1)
  nc <- Uu + Dd; nd <- Ud + t(Ud)
  G <- ifelse(nc + nd > 0, (nc - nd) / (nc + nd), 0); diag(G) <- 1
  psd(G * outer(sd, sd))
}

#' Projektion auf {sum w = 1, lo <= w <= hi}
#' @keywords internal
#' @noRd
.proj_capped_simplex <- function(v, lo, hi) .proj_box_simplex(as.numeric(v), as.numeric(lo), as.numeric(hi))

#' FISTA mit adaptivem Neustart fuer min 0.5 w'Qw + c'w auf dem beschraenkten
#' Simplex (Kern in C++: .qp_box_simplex)
#' @keywords internal
#' @noRd
.qp_simplex <- function(Q, cvec, lo, hi, w0 = NULL, maxit = 20000L, tol = 1e-12) {
  N <- ncol(Q); Q <- as.matrix(Q); storage.mode(Q) <- "double"
  L <- max(eigen(Q, symmetric = TRUE, only.values = TRUE)$values, 1e-12)
  .qp_box_simplex(Q, as.numeric(cvec), as.numeric(lo), as.numeric(hi), as.numeric(w0 %||% rep(1 / N, N)),
                  L, as.integer(maxit), tol)
}

#' Risikoparitaet mit Risikobudgets (Spinu 2013, gedaempftes Newton)
#' @keywords internal
#' @noRd
.risk_parity <- function(S, b) {
  N <- ncol(S); y <- 1 / sqrt(diag(S)); y <- y / sum(y)
  f <- function(y) 0.5 * drop(t(y) %*% S %*% y) - sum(b * log(y))
  for (it in 1:200) {
    g <- drop(S %*% y) - b / y
    H <- S + diag(b / y^2, N)
    dx <- solve(H, g)
    step <- 1
    while (any(y - step * dx <= 0) || f(y - step * dx) > f(y) - 1e-4 * step * sum(g * dx)) { step <- step / 2; if (step < 1e-12) break }
    y <- y - step * dx
    if (max(abs(dx * step)) < 1e-14) break
  }
  y / sum(y)
}

#' Hierarchical Risk Parity (Lopez de Prado 2016)
#' @keywords internal
#' @noRd
.hrp <- function(S) {
  N <- ncol(S); if (N == 1) return(1)
  C <- stats::cov2cor(S)
  Dm <- (1 - C) / 2; Dm[Dm < 0] <- 0
  D <- stats::as.dist(sqrt(Dm))
  ord <- stats::hclust(D, method = "single")$order
  w <- rep(1, N)
  clusters <- list(ord)
  while (length(clusters)) {
    nxt <- list()
    for (cl in clusters) if (length(cl) > 1) {
      h <- floor(length(cl) / 2); c1 <- cl[1:h]; c2 <- cl[(h + 1):length(cl)]
      cv <- function(ix) { s <- S[ix, ix, drop = FALSE]; iv <- 1 / diag(s); iv <- iv / sum(iv); drop(t(iv) %*% s %*% iv) }
      v1 <- cv(c1); v2 <- cv(c2); a <- 1 - v1 / (v1 + v2)
      w[c1] <- w[c1] * a; w[c2] <- w[c2] * (1 - a)
      nxt <- c(nxt, list(c1), list(c2))
    }
    clusters <- nxt
  }
  w / sum(w)
}

#' Minimaler CVaR (geglaettete Rockafellar-Uryasev-Formulierung, FISTA mit
#' Schrittweitensuche und Neustart)
#' @keywords internal
#' @noRd
.min_cvar <- function(R, alpha, lo, hi) {
  N <- ncol(R); R <- as.matrix(R); storage.mode(R) <- "double"; sc <- stats::sd(as.vector(R))
  w <- .proj_capped_simplex(rep(1 / N, N), lo, hi)
  zeta <- stats::quantile(-drop(R %*% w), 1 - alpha, names = FALSE)
  .min_cvar_core(R, alpha, as.numeric(lo), as.numeric(hi), w, zeta, sc * c(0.05, 0.005), 2000L)
}

#' Conditional Drawdown at Risk (Mittel der schlechtesten alpha-Anteile der
#' Drawdowns der kumulierten, nicht aufgezinsten Rendite; Chekhlov et al. 2005)
#' @keywords internal
#' @noRd
.cdar_hist <- function(r, alpha) {
  C <- c(0, cumsum(r)); D <- cummax(C) - C; D <- D[-1]
  v <- stats::quantile(D, 1 - alpha, names = FALSE); mean(D[D >= v])
}

#' Minimaler CDaR (projizierter Subgradient mit Mittelung)
#' @keywords internal
#' @noRd
.min_cdar <- function(R, alpha, lo, hi, iters = 3000L) {
  R <- as.matrix(R); storage.mode(R) <- "double"
  .min_cdar_core(R, alpha, as.numeric(lo), as.numeric(hi), as.integer(iters))
}

#' Historischer CVaR (erwarteter Verlust jenseits des VaR, positiv)
#' @keywords internal
#' @noRd
.cvar_hist <- function(r, alpha) { L <- -r; v <- stats::quantile(L, 1 - alpha, names = FALSE); mean(L[L >= v]) }

#' Grenzen auf Anlagen abbilden: Skalar, benannter Vektor (nicht genannte
#' Anlagen = default) oder unbenannter Vektor mit einem Wert je Anlage
#' (positionsweise)
#' @keywords internal
#' @noRd
.opt_bounds <- function(b, nm, default, what = "upper") {
  if (!is.numeric(b) || !length(b) || anyNA(b))
    stop(sprintf("%s: numerischer Wert bzw. Vektor ohne NA erwartet (erhalten: %s).", what, paste(format(b), collapse = ", ")))
  if (is.null(names(b))) {
    if (length(b) == 1) return(rep(as.numeric(b), length(nm)))
    if (length(b) == length(nm)) return(as.numeric(b))
    stop(sprintf("%s: unbenannter Vektor der L\u00e4nge %d passt nicht zu %d Anlagen (Skalar, benannter Vektor oder ein Wert je Anlage in Spaltenreihenfolge).",
                 what, length(b), length(nm)))
  }
  unk <- setdiff(names(b), nm)
  if (length(unk)) stop(sprintf("%s: unbekannte Anlage(n) %s; vorhanden: %s.", what, paste0("'", unk, "'", collapse = ", "),
                                paste(nm, collapse = ", ")))
  v <- stats::setNames(rep(default, length(nm)), nm); v[names(b)] <- b; unname(v)
}

#' Unter- und Obergrenzen pruefen (Long-only, erfuellbar)
#' @keywords internal
#' @noRd
.opt_check_bounds <- function(lower, upper, nm) {
  lo <- .opt_bounds(lower, nm, 0, "lower"); hi <- .opt_bounds(upper, nm, 1, "upper")
  hi[hi == Inf] <- 1                                # Inf = keine Obergrenze; bei Long-only mit Summe 1 gleichwertig zu 1
  if (any(hi > 1)) {                                # vermutlich Prozent statt Anteil (26 statt 0.26)
    big <- which(hi > 1)
    w <- simpleWarning(sprintf("upper: Obergrenze(n) > 1 (%s); Grenzen sind Anteile (0.26 = 26 %%), Werte > 1 wirken wie 1. Prozentangabe? Dann durch 100 teilen.",
                               paste(sprintf("%s = %s", nm[big], format(hi[big])), collapse = ", ")))
    class(w) <- c("SimLevBoundsPercent", class(w)); warning(w)
  }
  if (any(lo < 0)) stop(sprintf("lower: Untergrenzen m\u00fcssen >= 0 sein (Long-only; erhalten %s).", paste(format(lo[lo < 0]), collapse = ", ")))
  if (sum(lo) > 1 + 1e-12 || sum(hi) < 1 - 1e-12 || any(lo > hi))
    stop(sprintf("Grenzen nicht erf\u00fcllbar (sum(lower) <= 1 <= sum(upper) und lower <= upper; hier sum(lower) = %g, sum(upper) = %g).", sum(lo), sum(hi)))
  list(lo = lo, hi = hi)
}

#' Anlagen ohne Schwankung (Volatilitaet 0, z. B. Geldmarkt mit festem Zins)
#' @keywords internal
#' @noRd
.opt_flat <- function(S, nm) nm[sqrt(pmax(diag(S), 0)) <= 1e-10]

#' Ein Optimierungsschritt auf einer Renditematrix
#' @keywords internal
#' @noRd
.opt_core <- function(R, method, lo, hi, cov_type, mu, risk_free, risk_aversion, budget, alpha, ppy) {
  nm <- colnames(R); N <- ncol(R)
  S <- .opt_cov(R, cov_type) * ppy
  m <- if (is.null(mu)) colMeans(R) * ppy else { v <- stats::setNames(rep(NA_real_, N), nm); v[names(mu)] <- mu / 100; v }
  mu_miss <- function() if (anyNA(m))
    stop(sprintf("%s: mu f\u00fcr alle Anlagen angeben; es fehlt ein Wert f\u00fcr %s (benannter Vektor mit allen Anlagen oder ein Wert je Spalte in Spaltenreihenfolge).",
                 method, paste0("'", nm[is.na(m)], "'", collapse = ", ")))
  rf <- risk_free / 100
  sharpe_of <- function(w, mm) (sum(w * mm) - rf) / sqrt(drop(t(w) %*% S %*% w))
  best_sharpe <- function(mm) {
    lg <- seq(log(500), log(0.05), length.out = 30)
    ws <- vector("list", length(lg)); prev <- NULL
    for (k in seq_along(lg)) { ws[[k]] <- .qp_simplex(exp(lg[k]) * S, -mm, lo, hi, prev, tol = 1e-10); prev <- ws[[k]] }
    sh <- vapply(ws, sharpe_of, 0, mm = mm); k <- which.max(sh)
    a <- lg[min(length(lg), k + 1)]; b <- lg[max(1, k - 1)]; w0 <- ws[[k]]
    fx <- function(x) { w <- .qp_simplex(exp(x) * S, -mm, lo, hi, w0, tol = 1e-11); list(w = w, s = sharpe_of(w, mm)) }
    gr <- (sqrt(5) - 1) / 2
    x1 <- b - gr * (b - a); x2 <- a + gr * (b - a); f1 <- fx(x1); f2 <- fx(x2)
    for (i in 1:25) {
      if (f1$s > f2$s) { b <- x2; x2 <- x1; f2 <- f1; x1 <- b - gr * (b - a); f1 <- fx(x1) }
      else { a <- x1; x1 <- x2; f1 <- f2; x2 <- a + gr * (b - a); f2 <- fx(x2) }
    }
    best <- list(ws[[k]], f1$w, f2$w)[[which.max(c(sh[k], f1$s, f2$s))]]
    best
  }
  default_bounds <- all(lo == 0) && all(hi == 1)
  if (method %in% c("inverse_vol", "risk_parity", "hrp") && N > 1 && length(fl <- .opt_flat(S, nm)))
    stop(sprintf("%s: Anlage(n) %s ohne Schwankung (Volatilit\u00e4t 0); das Verfahren ist daf\u00fcr nicht definiert. Anlage entfernen oder z. B. min_variance verwenden.",
                 method, paste0("'", fl, "'", collapse = ", ")))
  w <- switch(method,
    equal = { if (!default_bounds) warning("equal: Grenzen werden ignoriert."); rep(1 / N, N) },
    inverse_vol = { if (!default_bounds) warning("inverse_vol: Grenzen werden ignoriert."); v <- 1 / sqrt(diag(S)); v / sum(v) },
    min_variance = .qp_simplex(S, rep(0, N), lo, hi),
    mean_variance = { mu_miss(); .qp_simplex(risk_aversion * S, -m, lo, hi) },
    max_sharpe = { mu_miss(); best_sharpe(m) },
    max_diversification = { rf <- 0; best_sharpe(sqrt(diag(S))) },
    risk_parity = { if (!default_bounds) warning("risk_parity: Grenzen werden ignoriert.")
                    b <- if (is.null(budget)) rep(1 / N, N) else {
                      v <- .opt_bounds(budget, nm, 0, "budget")
                      if (any(v < 0) || sum(v) <= 0) stop("budget: Risikobudgets m\u00fcssen >= 0 sein, mit positiver Summe.")
                      v / sum(v) }
                    .risk_parity(S, b) },
    hrp = { if (!default_bounds) warning("hrp: Grenzen werden ignoriert."); .hrp(S) },
    min_cvar = .min_cvar(R, alpha, lo, hi),
    min_cdar = .min_cdar(R, alpha, lo, hi),
    stop(sprintf("Unbekannte Methode '%s'.", method)))
  w[abs(w) < 1e-12] <- 0
  stats::setNames(w / sum(w), nm)
}

#' Portfolio optimieren
#'
#' Bestimmt Gewichte fuer ein Long-only-Portfolio (Summe 1) mit optionalen
#' Grenzen je Anlage aus historischen Periodenrenditen. Eingabe ist entweder
#' ein data.frame mit Kursen oder eine fertige Renditematrix; Ergebnis sind
#' Gewichte, Kennzahlen und Risikobeitraege.
#'
#' Renditen: Bei einem data.frame mit Spalte \code{date} werden die Kurse
#' wie in [dependence_analysis()] aufbereitet (Fortschreiben fehlender Werte,
#' letzte Zeile je ISO-Woche bzw. Kalendermonat, bei \code{"day"} jede Zeile
#' ausser Tagen, an denen sich keine Anlage bewegt) und in einfache Renditen
#' \eqn{P_t / P_{t-1} - 1} (Anteile) umgerechnet; die Perioden je Jahr
#' werden aus den Daten ermittelt. Jede andere Eingabe wird als Matrix
#' einfacher Periodenrenditen als Anteil (0.01 = 1 %) behandelt; Zeilen mit
#' fehlenden Werten entfallen, unendliche Renditen (\code{Inf}) sind ein
#' Fehler (mit Spalte und Zeile), die Perioden je Jahr sind dann fest 252
#' (\code{"day"}), 52 (\code{"week"}) bzw. 12 (\code{"month"}). Erwartete
#' Renditen und Kovarianz werden mit diesen Perioden je Jahr annualisiert.
#'
#' \tabular{ll}{
#'   \code{min_variance} \tab minimale Varianz \cr
#'   \code{mean_variance} \tab \eqn{\max \mu'w - \frac{\gamma}{2} w'\Sigma w} mit Risikoaversion \code{risk_aversion} \cr
#'   \code{max_sharpe} \tab maximale Sharpe Ratio (Suche entlang der Effizienzgrenze) \cr
#'   \code{max_diversification} \tab maximales Diversifikationsverhaeltnis \eqn{w'\sigma / \sqrt{w'\Sigma w}} (Choueifaty & Coignard 2008) \cr
#'   \code{risk_parity} \tab gleiche (oder vorgegebene, \code{budget}) Risikobeitraege (Spinu 2013) \cr
#'   \code{hrp} \tab Hierarchical Risk Parity (Lopez de Prado 2016) \cr
#'   \code{min_cvar} \tab minimaler historischer CVaR (Rockafellar & Uryasev 2000, geglaettet) \cr
#'   \code{min_cdar} \tab minimaler Conditional Drawdown at Risk (Chekhlov, Uryasev & Zabarankin 2005) \cr
#'   \code{inverse_vol}, \code{equal} \tab einfache Heuristiken
#' }
#'
#' Erwartete Renditen aus der Historie sind sehr unsicher; Verfahren, die sie
#' nutzen (\code{max_sharpe}, \code{mean_variance}), reagieren stark auf
#' Schaetzfehler. \code{resample} mittelt die Gewichte ueber Block-Bootstrap-
#' Stichproben der Historie (Michaud-Resampling) und glaettet diese
#' Abhaengigkeit.
#'
#' @param x data.frame mit Spalte \code{date} (Date) und Kursspalten
#'   (Kursniveaus, keine Renditen) oder numerische Matrix bzw. data.frame
#'   ohne \code{date} mit einfachen Periodenrenditen als Anteil (Zeilen =
#'   Perioden, Spalten = Anlagen; ohne Spaltennamen \code{A1}, \code{A2},
#'   ...).
#' @param assets Zeichenvektor der zu verwendenden Spalten. \code{NULL}
#'   (Standard) = alle numerischen Spalten ausser \code{date} bzw. alle
#'   Spalten der Matrix.
#' @param method Verfahren (siehe Tabelle oben): \code{"min_variance"}
#'   (Standard), \code{"max_sharpe"}, \code{"mean_variance"},
#'   \code{"max_diversification"}, \code{"risk_parity"}, \code{"hrp"},
#'   \code{"min_cvar"}, \code{"min_cdar"}, \code{"inverse_vol"} oder
#'   \code{"equal"}. \code{risk_parity}, \code{hrp}, \code{inverse_vol} und
#'   \code{equal} ignorieren \code{lower}/\code{upper} (mit Warnung, wenn
#'   andere als die Standardgrenzen angegeben sind). \code{risk_parity},
#'   \code{hrp} und \code{inverse_vol} brechen bei Anlagen ohne Schwankung
#'   (Volatilitaet 0, z. B. Geldmarkt mit festem Zins) mit Fehler ab.
#' @param lower,upper Unter- und Obergrenzen der Gewichte als Anteil (0.6 =
#'   60 %): Skalar fuer alle Anlagen, benannter Vektor (nicht genannte
#'   Anlagen erhalten 0 bzw. 1; unbekannte Namen sind ein Fehler) oder
#'   unbenannter Vektor mit genau einem Wert je Anlage (in der Reihenfolge
#'   der Spalten; andere Laengen sind ein Fehler). Standard 0 und 1. Keine
#'   NA; \code{lower} >= 0 (Long-only). Erforderlich ist
#'   sum(lower) <= 1 <= sum(upper) und lower <= upper. \code{Inf} in
#'   \code{upper} bedeutet keine Obergrenze und wird als 1 gefuehrt (auch in
#'   \code{bounds}); andere Obergrenzen > 1 wirken ebenfalls wie 1, erzeugen
#'   aber eine Warnung (vermutlich Prozent statt Anteil, z. B. 26 statt
#'   0.26).
#' @param cov Kovarianzschaetzer: \code{"sample"} (Standard, Stichprobe),
#'   \code{"ledoit_wolf"} (Schrumpfung auf skalierte Einheitsmatrix, Ledoit &
#'   Wolf 2004), \code{"ewma"} (exponentiell gewichtet, Halbwertszeit ein
#'   Viertel der Stichprobe, 5 bis 52 Perioden), \code{"denoise"}
#'   (Marchenko-Pastur-Rauschfilter, Laloux et al. 1999) oder
#'   \code{"gerber"} (Gerber-Statistik, Gerber et al. 2022).
#' @param mu Optional erwartete Renditen in Prozent p. a. (5 = 5 %), endlich,
#'   ohne NA: benannter Vektor (unbekannte Namen sind ein Fehler), unbenannter
#'   Vektor mit genau einem Wert je Anlage (in der Reihenfolge der Spalten)
#'   oder Skalar (fuer alle Anlagen gleich); nur fuer \code{max_sharpe} und
#'   \code{mean_variance} verwendet (fehlt dort eine Anlage im benannten
#'   Vektor, bricht die Funktion mit ihrem Namen ab). \code{NULL} (Standard) =
#'   historisches arithmetisches Mittel, annualisiert.
#' @param risk_free Risikoloser Zins in Prozent p. a. (Standard 0) fuer
#'   \code{max_sharpe} und die ausgewiesene Sharpe Ratio.
#' @param risk_aversion Risikoaversion \eqn{\gamma} fuer
#'   \code{mean_variance} (Standard 4), bezogen auf Rendite und Varianz als
#'   Anteil p. a.
#' @param budget Risikobudgets fuer \code{risk_parity}: Skalar (gleiche
#'   Budgets), benannter Vektor (nicht genannte Anlagen 0) oder unbenannter
#'   Vektor mit einem Wert je Anlage (Spaltenreihenfolge); Werte >= 0, wird
#'   auf Summe 1 normiert. \code{NULL} (Standard) = gleiche Risikobeitraege.
#' @param alpha Tail-Wahrscheinlichkeit als Anteil fuer CVaR und CDaR
#'   (Standard 0.05 = schlechteste 5 % der Perioden bzw. Drawdowns), im
#'   Bereich (0, 0.5]; nicht das Konfidenzniveau (0.95) und nicht in Prozent
#'   (5) - beides ist ein Fehler. Wirkt auf \code{min_cvar},
#'   \code{min_cdar} und die ausgewiesenen Kennzahlen.
#' @param frequency Renditefrequenz: \code{"week"} (Standard), \code{"day"}
#'   oder \code{"month"}. Bei Kursdaten Aggregation (ISO-Woche,
#'   Kalendermonat); bei einer Renditematrix nur die Perioden je Jahr (52,
#'   252, 12).
#' @param resample Anzahl Block-Bootstrap-Stichproben fuer das
#'   Michaud-Resampling (ganze Zahl, Standard 0 = aus); die Gewichte sind
#'   dann das Mittel der Einzeloptimierungen.
#' @param block Mittlere Blocklaenge des stationaeren Bootstraps fuer das
#'   Resampling in Perioden. \code{NULL} (Standard) = \eqn{T^{1/3}} gerundet,
#'   mindestens 2 (T = Anzahl Perioden).
#' @param seed Startwert fuer das Resampling. Mit Startwert ist das Ergebnis reproduzierbar und der
#'   Zufallszustand der Sitzung bleibt unveraendert; mit `NULL` wird der
#'   Zufallsstrom der Sitzung normal weitergezogen.
#' @return Objekt der Klasse \code{SimLevOptimization}, eine Liste mit
#'   \describe{
#'     \item{weights}{Benannter Gewichtsvektor (Anteile, Summe 1).}
#'     \item{stats}{Benannter Vektor: \code{expected_return} (historisches
#'       Mittel, annualisiert, Anteil p. a.; auch wenn \code{mu} angegeben
#'       ist), \code{volatility} (Anteil p. a.), \code{sharpe} (bei
#'       Volatilitaet 0 wie auch \code{diversification_ratio},
#'       \code{effective_n_risk} und \code{risk_share} \code{NA}, mit Warnung),
#'       \code{cvar} (historischer CVaR je Periode, Verlust positiv, Anteil),
#'       \code{cdar} (CDaR der kumulierten, nicht aufgezinsten Rendite,
#'       Anteil), \code{diversification_ratio}, \code{effective_n}
#'       (\eqn{1 / \sum w^2}), \code{effective_n_risk} (dasselbe fuer die
#'       Risikoanteile).}
#'     \item{risk}{data.frame je Anlage: \code{asset}, \code{weight},
#'       \code{volatility_contribution} (Anteil p. a., Summe =
#'       Volatilitaet), \code{risk_share} (Anteil an der Volatilitaet).}
#'   }
#'   sowie \code{alpha}, \code{method}, \code{bounds} (Matrix der Grenzen),
#'   \code{resampled} (Gewichte je Stichprobe oder \code{NULL}),
#'   \code{cov_type}, \code{frequency}, \code{n_obs} (Anzahl Perioden).
#'   Methoden \code{print} und \code{plot}.
#' @seealso [efficient_frontier()], [risk_contributions()],
#'   [rolling_optimization()] (Zielgewichte fuer [tactical_simulation()]),
#'   [cpcv_portfolio()].
#' @references Ledoit, O. & Wolf, M. (2004), Journal of Multivariate Analysis
#'   88(2); Spinu, F. (2013), SSRN 2297383; Lopez de Prado, M. (2016), Journal
#'   of Portfolio Management 42(4); Rockafellar, R. T. & Uryasev, S. (2000),
#'   Journal of Risk 2(3); Michaud, R. (1998), Efficient Asset Management.
#' @examples
#' set.seed(1); R <- matrix(rnorm(520 * 3, c(0.002, 0.001, 0.0005), c(0.03, 0.02, 0.01)), 520, byrow = TRUE)
#' colnames(R) <- c("aktien", "reits", "anleihen")
#' portfolio_optimize(R, method = "risk_parity")
#' portfolio_optimize(R, method = "min_variance", upper = 0.6)
#' @export
portfolio_optimize <- function(x, assets = NULL,
                               method = c("min_variance", "max_sharpe", "mean_variance", "max_diversification",
                                          "risk_parity", "hrp", "min_cvar", "min_cdar", "inverse_vol", "equal"),
                               lower = 0, upper = 1, cov = c("sample", "ledoit_wolf", "ewma", "denoise", "gerber"), mu = NULL, risk_free = 0,
                               risk_aversion = 4, budget = NULL, alpha = 0.05, frequency = c("week", "day", "month"),
                               resample = 0L, block = NULL, seed = NULL) {
  method <- match.arg(method); cov <- match.arg(cov); frequency <- match.arg(frequency)
  rr <- .opt_returns(x, assets, frequency); R <- rr$R; nm <- colnames(R); N <- ncol(R)
  if (nrow(R) < N + 5) stop(sprintf("Zu wenige Beobachtungen f\u00fcr die Optimierung (%d Perioden f\u00fcr %d Anlagen, mindestens %d).", nrow(R), N, N + 5))
  b <- .opt_check_bounds(lower, upper, nm); lo <- b$lo; hi <- b$hi
  .opt_check_alpha(alpha, "portfolio_optimize")
  if (!is.null(mu)) {                               # wie lower/upper: Skalar, benannt (Namen pruefen) oder ein Wert je Spalte
    mu <- stats::setNames(.opt_bounds(mu, nm, NA_real_, "mu"), nm)
    if (any(is.infinite(mu))) stop(sprintf("mu: endliche Werte in Prozent p. a. erwartet (erhalten: %s).", paste(format(mu), collapse = ", ")))
  }
  core <- function(Rx) .opt_core(Rx, method, lo, hi, cov, mu, risk_free, risk_aversion, budget, alpha, rr$ppy)
  w <- core(R)
  wb <- NULL
  if (resample > 0) {
    block <- block %||% max(2, round(nrow(R)^(1 / 3)))
    wb <- .with_rng_restore(seed = seed, {
      matrix(vapply(seq_len(resample), function(b) core(R[.boot_idx_stationary(nrow(R), nrow(R), block), , drop = FALSE]), numeric(N)),
             ncol = N, byrow = TRUE)
    })
    colnames(wb) <- nm
    w <- colMeans(wb); w <- w / sum(w)
  }
  out <- .opt_summary(w, R, rr$ppy, cov, risk_free, alpha)
  structure(c(out, list(method = method, bounds = rbind(lower = lo, upper = hi), resampled = wb, cov_type = cov,
                        frequency = frequency, n_obs = nrow(R))), class = "SimLevOptimization")
}

#' Kennzahlen eines Gewichtsvektors
#' @keywords internal
#' @noRd
.opt_summary <- function(w, R, ppy, cov_type, risk_free, alpha) {
  S <- .opt_cov(R, cov_type) * ppy; m <- colMeans(R) * ppy
  vol <- sqrt(max(drop(t(w) %*% S %*% w), 0)); ret <- sum(w * m)
  rp <- drop(R %*% w)
  if (vol <= 1e-10) {                               # Portfolio ohne Schwankung: Quotienten nicht definiert
    warning("Portfolio ohne Schwankung (Volatilit\u00e4t 0, nur Anlagen mit konstanter Rendite): Sharpe Ratio, Diversifikationsverh\u00e4ltnis und Risikoanteile sind nicht definiert (NA).")
    vol <- 0; vq <- NA_real_
  } else vq <- vol
  rc <- w * drop(S %*% w) / vq
  list(weights = w,
       stats = c(expected_return = ret, volatility = vol, sharpe = (ret - risk_free / 100) / vq,
                 cvar = .cvar_hist(rp, alpha), cdar = .cdar_hist(rp, alpha), diversification_ratio = sum(w * sqrt(diag(S))) / vq,
                 effective_n = 1 / sum(w^2), effective_n_risk = 1 / sum((rc / vq)^2)),
       risk = data.frame(asset = names(w), weight = w, volatility_contribution = if (is.na(vq)) rep(0, length(w)) else rc, risk_share = rc / vq,
                         row.names = NULL, stringsAsFactors = FALSE),
       alpha = alpha)
}

#' @export
print.SimLevOptimization <- function(x, ...) {
  cat(sprintf("SimLev-Optimierung: %s%s (%d Perioden, %s, Kovarianz %s)\n\n", x$method,
              if (!is.null(x$resampled)) sprintf(", Resampling %d", nrow(x$resampled)) else "", x$n_obs, x$frequency, x$cov_type))
  r <- x$risk
  print(data.frame(Anlage = r$asset, Gewicht = sprintf("%.1f %%", 100 * r$weight),
                   Risikoanteil = sprintf("%.1f %%", 100 * r$risk_share), check.names = FALSE), row.names = FALSE)
  s <- x$stats
  cat(sprintf("\nErwartete Rendite %.2f %% p. a. (historisch), Volatilit\u00e4t %.2f %%, Sharpe %.3f\nCVaR(%g) %.2f %% je Periode, CDaR(%g) %.2f %% (kumuliert)\n",
              100 * s["expected_return"], 100 * s["volatility"], s["sharpe"], x$alpha, 100 * s["cvar"], x$alpha, 100 * s["cdar"]))
  cat(sprintf("Diversifikationsverh\u00e4ltnis %.2f, effektive Anzahl: Gewichte %.1f, Risiko %.1f\n",
              s["diversification_ratio"], s["effective_n"], s["effective_n_risk"]))
  invisible(x)
}

#' @export
plot.SimLevOptimization <- function(x, ...) {
  old <- graphics::par(no.readonly = TRUE); on.exit(graphics::par(old))
  graphics::par(mar = c(4, 4.2, 2.6, 1), mgp = c(2.5, 0.6, 0), las = 1, cex.axis = 0.85)
  M <- rbind(Gewicht = x$risk$weight, Risiko = x$risk$risk_share); colnames(M) <- x$risk$asset
  graphics::barplot(100 * M, beside = TRUE, col = c("#2C6E9B", "#B5562B"), border = NA, ylab = "%",
                    main = sprintf("Gewichte und Risikoanteile (%s)", x$method), legend.text = c("Gewicht", "Risikoanteil"),
                    args.legend = list(bty = "n", cex = 0.8))
  invisible(x)
}

#' Effizienzgrenze
#'
#' Berechnet Mean-Variance-effiziente Long-only-Portfolios unter denselben
#' Grenzen wie [portfolio_optimize()]: Fuer \code{n} Risikoaversionen
#' \eqn{\gamma} von 1e4 bis 0.02 (logarithmisch gestuft) wird
#' \eqn{\max \mu'w - \frac{\gamma}{2} w'\Sigma w} geloest, mit
#' historischen Mitteln und Kovarianz (annualisiert). Eingabe und
#' Renditeberechnung wie bei [portfolio_optimize()] (Kurs-data.frame mit
#' \code{date} oder Matrix einfacher Periodenrenditen als Anteil); die Grenzen
#' werden ebenso geprueft (unerfuellbare Grenzen sind ein Fehler).
#' \code{print} zeigt den Punkt mit der kleinsten Volatilitaet
#' ("Minimum-Varianz") und den mit der hoechsten Sharpe Ratio, \code{plot}
#' zeichnet die Grenze mit den Einzelanlagen und markiert den Punkt mit der
#' hoechsten Sharpe Ratio.
#'
#' @inheritParams portfolio_optimize
#' @param n Anzahl der Risikoaversionen (ganze Zahl, Standard 40). Punkte mit
#'   (auf 6 Stellen) gleicher Rendite und Volatilitaet werden nur einmal
#'   behalten; das Ergebnis kann daher weniger Zeilen haben.
#' @return Objekt der Klasse \code{SimLevFrontier} mit \code{frontier}
#'   (data.frame je Punkt: \code{expected_return}, \code{volatility} als
#'   Anteil p. a., \code{sharpe} mit \code{risk_free} (\code{NA} bei
#'   Volatilitaet 0), dann je Anlage eine
#'   Gewichtsspalte), \code{assets} (data.frame der Einzelanlagen:
#'   \code{asset}, \code{expected_return}, \code{volatility}, Anteil p. a.),
#'   \code{risk_free} und \code{frequency}. Methoden \code{print} und
#'   \code{plot}.
#' @seealso [portfolio_optimize()], [risk_contributions()].
#' @examples
#' set.seed(1); R <- matrix(rnorm(520 * 3, c(0.002, 0.001, 0.0005), c(0.03, 0.02, 0.01)), 520, byrow = TRUE)
#' colnames(R) <- c("aktien", "reits", "anleihen")
#' ef <- efficient_frontier(R, n = 20, upper = 0.7)
#' ef
#' head(ef$frontier, 3)
#' @export
efficient_frontier <- function(x, assets = NULL, n = 40L, lower = 0, upper = 1, cov = c("sample", "ledoit_wolf", "ewma", "denoise", "gerber"),
                               risk_free = 0, frequency = c("week", "day", "month")) {
  cov <- match.arg(cov); frequency <- match.arg(frequency)
  rr <- .opt_returns(x, assets, frequency); R <- rr$R; nm <- colnames(R)
  b <- .opt_check_bounds(lower, upper, nm); lo <- b$lo; hi <- b$hi
  S <- .opt_cov(R, cov) * rr$ppy; m <- colMeans(R) * rr$ppy
  W <- matrix(vapply(exp(seq(log(1e4), log(0.02), length.out = n)), function(g) .qp_simplex(g * S, -m, lo, hi), numeric(length(nm))),
              ncol = length(nm), byrow = TRUE)
  colnames(W) <- nm
  ret <- drop(W %*% m); vol <- sqrt(pmax(rowSums((W %*% S) * W), 0))
  keep <- !duplicated(round(cbind(ret, vol), 6))
  sh <- ifelse(vol > 1e-10, (ret - risk_free / 100) / vol, NA_real_)       # Volatilitaet 0: Sharpe nicht definiert
  fr <- data.frame(expected_return = ret, volatility = vol, sharpe = sh, W, check.names = FALSE)[keep, , drop = FALSE]
  structure(list(frontier = fr, assets = data.frame(asset = nm, expected_return = m, volatility = sqrt(diag(S))),
                 risk_free = risk_free, frequency = frequency), class = "SimLevFrontier")
}

#' @export
print.SimLevFrontier <- function(x, ...) {
  f <- x$frontier; k <- which.max(f$sharpe); j <- which.min(f$volatility)
  cat(sprintf("Effizienzgrenze: %d Punkte\n", nrow(f)))
  show <- f[unique(c(j, k)), , drop = FALSE]; rownames(show) <- c("Minimum-Varianz", "Max. Sharpe")[seq_len(nrow(show))]
  print(round(show, 4))
  invisible(x)
}

#' @export
plot.SimLevFrontier <- function(x, ...) {
  f <- x$frontier; a <- x$assets
  old <- graphics::par(no.readonly = TRUE); on.exit(graphics::par(old))
  graphics::par(mar = c(4, 4.4, 2.6, 1), mgp = c(2.5, 0.6, 0), las = 1, cex.axis = 0.85)
  graphics::plot(100 * f$volatility, 100 * f$expected_return, type = "l", lwd = 2, col = "#2C6E9B",
                 xlim = c(0, 1.18 * max(100 * c(f$volatility, a$volatility))),
                 ylim = range(100 * c(f$expected_return, a$expected_return)) + c(-0.3, 0.3),
                 xlab = "Volatilit\u00e4t (% p. a.)", ylab = "Rendite (% p. a., historisch)", main = "Effizienzgrenze", ...)
  graphics::points(100 * a$volatility, 100 * a$expected_return, pch = 19, col = "#B5562B")
  pos <- ifelse(rank(a$expected_return) %% 2 == 0, 3, 1)
  graphics::text(100 * a$volatility, 100 * a$expected_return, a$asset, pos = pos, cex = 0.75, offset = 0.4)
  k <- which.max(f$sharpe)
  graphics::points(100 * f$volatility[k], 100 * f$expected_return[k], pch = 17, cex = 1.3, col = "#3E8E5A")
  graphics::grid(col = "grey90")
  invisible(x)
}

#' Rollierende Optimierung (Zielgewichte ausserhalb der Stichprobe)
#'
#' Optimiert an jedem Entscheidungstermin auf den Renditen des
#' zurueckliegenden Fensters und haelt die Gewichte bis zum naechsten Termin.
#' Das Ergebnis ist eine Zielgewichtsreihe fuer [tactical_simulation()]; jede
#' Entscheidung nutzt nur Daten bis einschliesslich des Entscheidungstags
#' (gehandelt wird in [tactical_simulation()] mit dessen \code{lag}).
#'
#' Entscheidungstermine sind die letzten Zeilen jedes Monats, Quartals bzw.
#' Jahres, deren Datum mindestens \code{window} Jahre (\code{window * 365.25}
#' Tage, gerundet) nach dem ersten Datum liegt. Das Fenster umfasst die
#' Zeilen mit Datum im Zeitraum (Termin - \code{window * 365.25} Tage,
#' Termin]. Argumentfehler (unbekanntes \code{method}, unbekannte
#' Argumente in \code{...}, unerfuellbare Grenzen) brechen sofort ab.
#' Schlaegt eine Optimierung an einem Termin fehl (z. B. zu wenige Perioden
#' im Fenster), gilt dort Gleichgewichtung; die Funktion warnt mit der Anzahl
#' und der ersten Fehlermeldung. Die Zeilen von \code{x} werden nach
#' \code{date} sortiert (mit Hinweis, falls noetig).
#'
#' @param x data.frame mit Spalte \code{date} (Date) und Kursspalten
#'   (Kursniveaus, keine Renditen), z. B. aus [align_series()]. Eine
#'   Renditematrix ist hier nicht moeglich.
#' @param assets Zeichenvektor der Kursspalten (Pflicht).
#' @param method Verfahren wie in [portfolio_optimize()] (Zeichenkette,
#'   Standard \code{"min_variance"}).
#' @param window Fensterlaenge in Jahren (Standard 3).
#' @param every Entscheidungsrhythmus: \code{"month"} (Standard),
#'   \code{"quarter"} oder \code{"year"}.
#' @param frequency Renditefrequenz innerhalb des Fensters: \code{"week"}
#'   (Standard, ISO-Woche), \code{"day"} oder \code{"month"}.
#' @param ... Weitere Argumente fuer [portfolio_optimize()] (\code{lower},
#'   \code{upper}, \code{cov}, \code{mu}, \code{risk_free}, \code{budget},
#'   \code{alpha}, \code{resample}, ...).
#' @return Objekt der Klasse \code{SimLevWeights} (data.frame mit
#'   \code{date} und einer Gewichtsspalte je Anlage, Anteile mit
#'   Zeilensumme 1, eine Zeile je Zeile von \code{x}); vor dem ersten
#'   Entscheidungstermin gleich gewichtet. Attribute \code{source}
#'   (\code{"rolling <method>"}), \code{decision_rows} (Zeilennummern der
#'   Entscheidungstermine) und \code{failed_dates} (Date-Vektor der Termine
#'   mit fehlgeschlagener Optimierung, dort Gleichgewichtung; leer, wenn
#'   keine).
#' @seealso [portfolio_optimize()], [tactical_simulation()],
#'   [blend_weights()], [cpcv_portfolio()].
#' @examples
#' set.seed(1); n <- 5 * 365
#' d <- data.frame(date = seq.Date(as.Date("2015-01-01"), by = "day", length.out = n))
#' d$aktien <- 100 * cumprod(1 + rnorm(n, 3e-4, 0.01))
#' d$anleihen <- 100 * cumprod(1 + rnorm(n, 1e-4, 0.003))
#' w <- rolling_optimization(d, c("aktien", "anleihen"), window = 2, every = "quarter")
#' w
#' @export
rolling_optimization <- function(x, assets, method = "min_variance", window = 3, every = c("month", "quarter", "year"),
                                 frequency = c("week", "day", "month"), ...) {
  every <- match.arg(every); frequency <- match.arg(frequency)
  # Argumentfehler sofort melden (sonst schluege jeder Termin fehl)
  allowed <- eval(formals(portfolio_optimize)$method)
  if (!is.character(method) || length(method) != 1 || !method %in% allowed)
    stop(sprintf("rolling_optimization: unbekanntes Verfahren %s; erlaubt: %s.", paste0("'", method, "'", collapse = ", "), paste(allowed, collapse = ", ")))
  dots <- list(...)
  bad <- setdiff(names(dots), setdiff(names(formals(portfolio_optimize)), c("x", "assets", "method", "frequency")))
  if (length(bad) || (length(dots) && is.null(names(dots))) || any(names(dots) == ""))
    stop(sprintf("rolling_optimization: unbekannte bzw. unbenannte Argumente f\u00fcr portfolio_optimize() in ...: %s.",
                 if (length(bad)) paste0("'", bad, "'", collapse = ", ") else "ohne Namen"))
  if (!is.data.frame(x) || !"date" %in% names(x)) stop("rolling_optimization: data.frame mit Spalte 'date' erwartet.")
  miss <- setdiff(assets, names(x)); if (length(miss)) stop(sprintf("Spalten fehlen: %s", paste(miss, collapse = ", ")))
  .opt_check_bounds(dots$lower %||% 0, dots$upper %||% 1, assets)
  .opt_check_alpha(dots$alpha %||% 0.05, "rolling_optimization")
  if (!is.null(dots$mu)) .opt_bounds(dots$mu, assets, NA_real_, "mu")
  x <- .dep_sort_dates(x, "x")
  d <- x$date; n <- length(d); N <- length(assets)
  rows <- .period_last(d, every)
  first_ok <- d[1] + round(window * 365.25)
  rows <- rows[d[rows] >= first_ok]
  if (!length(rows)) stop("Historie k\u00fcrzer als das Fenster.")
  msg <- character(length(rows))
  M <- matrix(vapply(seq_along(rows), function(k) {
    i <- rows[k]
    sub <- x[d > d[i] - round(window * 365.25) & d <= d[i], c("date", assets), drop = FALSE]
    w <- tryCatch(withCallingHandlers(portfolio_optimize(sub, assets, method = method, frequency = frequency, ...)$weights,
                                      SimLevBoundsPercent = function(w) invokeRestart("muffleWarning")),   # schon vorab gewarnt
                  error = function(e) { msg[k] <<- conditionMessage(e); rep(NA_real_, N) })
    if (anyNA(w)) { if (!nzchar(msg[k])) msg[k] <<- "Gewichte NA"; rep(1 / N, N) } else w
  }, numeric(N)), ncol = N, byrow = TRUE)
  colnames(M) <- assets
  failed <- which(nzchar(msg))
  if (length(failed)) warning(sprintf("rolling_optimization: Optimierung an %d von %d Terminen fehlgeschlagen (erster am %s: %s); dort Gleichgewichtung. Termine im Attribut 'failed_dates'.",
                                      length(failed), length(rows), format(d[rows[failed[1]]]), msg[failed[1]]))
  H <- .hold_rows(n, rows, M); H[seq_len(rows[1] - 1L), ] <- 1 / N
  out <- .as_weights(d, H, paste("rolling", method))
  attr(out, "decision_rows") <- rows
  attr(out, "failed_dates") <- d[rows[failed]]
  out
}

#' Risikobeitraege (Euler-Zerlegung)
#'
#' Zerlegt Volatilitaet oder historischen CVaR eines Portfolios additiv auf
#' die Anlagen: \eqn{RC_i = w_i \partial \rho / \partial w_i},
#' \eqn{\sum_i RC_i = \rho}. Fuer die Volatilitaet
#' \eqn{RC_i = w_i (\Sigma w)_i / \sigma_p}, fuer den CVaR der mittlere
#' Verlustbeitrag der Anlage in den Perioden jenseits des VaR
#' (historische Perioden, in denen der Portfolioverlust mindestens das
#' (1 - \code{alpha})-Quantil der Verluste erreicht). Eingabe und
#' Renditeberechnung wie bei [portfolio_optimize()].
#'
#' @param x data.frame mit Spalte \code{date} (Date) und Kursspalten
#'   (Kursniveaus) oder Matrix einfacher Periodenrenditen als Anteil (siehe
#'   [portfolio_optimize()]).
#' @param weights Benannter Gewichtsvektor (Anteile; Namen = Spalten von
#'   \code{x}, nur diese Anlagen gehen ein; wird nicht normiert; unbenannte
#'   Vektoren oder unbekannte Namen sind ein Fehler) oder Objekt
#'   der Klasse \code{SimLevOptimization} (dessen \code{weights}).
#' @param measure Risikomass: \code{"volatility"} (Standard, annualisiert)
#'   oder \code{"cvar"} (historischer CVaR je Periode).
#' @param alpha Tail-Wahrscheinlichkeit als Anteil fuer den CVaR (Standard
#'   0.05 = schlechteste 5 % der Perioden), im Bereich (0, 0.5].
#' @param frequency,cov Siehe [portfolio_optimize()] (\code{cov} nur fuer
#'   \code{measure = "volatility"}).
#' @return data.frame je Anlage: \code{asset}, \code{weight},
#'   \code{contribution} (Beitrag \eqn{RC_i}; bei \code{"volatility"} als
#'   Anteil p. a., bei \code{"cvar"} als Anteil je Periode, Verlust
#'   positiv), \code{share} (Anteil am Gesamtrisiko), \code{marginal}
#'   (marginaler Beitrag \eqn{\partial \rho / \partial w_i}, bei
#'   \code{"cvar"} der mittlere Verlust der Anlage in den Tail-Perioden, also
#'   \code{contribution / weight}, auch fuer Gewicht 0 definiert). Attribute \code{total}
#'   (Gesamtrisiko in derselben Einheit), \code{measure},
#'   \code{effective_n} (\eqn{1 / \sum share^2}) und nur bei
#'   \code{"volatility"} \code{diversification_ratio}.
#' @seealso [portfolio_optimize()] (enthaelt die Volatilitaetsbeitraege der
#'   optimierten Gewichte), [efficient_frontier()], [covar_analysis()].
#' @examples
#' set.seed(1); R <- matrix(rnorm(520 * 3, c(0.002, 0.001, 0.0005), c(0.03, 0.02, 0.01)), 520, byrow = TRUE)
#' colnames(R) <- c("aktien", "reits", "anleihen")
#' w <- c(aktien = 0.5, reits = 0.2, anleihen = 0.3)
#' risk_contributions(R, w)
#' risk_contributions(R, w, measure = "cvar", alpha = 0.05)
#' @export
risk_contributions <- function(x, weights, measure = c("volatility", "cvar"), alpha = 0.05,
                               frequency = c("week", "day", "month"), cov = c("sample", "ledoit_wolf", "ewma", "denoise", "gerber")) {
  measure <- match.arg(measure); frequency <- match.arg(frequency); cov <- match.arg(cov)
  .opt_check_alpha(alpha, "risk_contributions")
  if (inherits(weights, "SimLevOptimization")) weights <- weights$weights
  if (!is.numeric(weights) || is.null(names(weights)) || any(names(weights) == "") || anyNA(weights))
    stop("weights: benannter numerischer Vektor ohne NA erwartet (Namen = Spalten von x).")
  avail <- if (is.data.frame(x) && "date" %in% names(x)) names(x) else colnames(as.matrix(x)) %||% paste0("A", seq_len(NCOL(x)))
  unk <- setdiff(names(weights), avail)
  if (length(unk)) stop(sprintf("weights: unbekannte Anlage(n) %s; vorhanden: %s.", paste0("'", unk, "'", collapse = ", "),
                                paste(setdiff(avail, "date"), collapse = ", ")))
  rr <- .opt_returns(x, names(weights), frequency); R <- rr$R; w <- weights[colnames(R)]
  if (measure == "volatility") {
    S <- .opt_cov(R, cov) * rr$ppy; tot <- sqrt(drop(t(w) %*% S %*% w))
    mc <- drop(S %*% w) / tot; rc <- w * mc
  } else {
    rp <- drop(R %*% w); L <- -rp; v <- stats::quantile(L, 1 - alpha, names = FALSE); tail <- L >= v
    mc <- colMeans(-R[tail, , drop = FALSE]); rc <- mc * w; tot <- sum(rc)   # Grenzbeitrag auch fuer Gewicht 0
  }
  out <- data.frame(asset = names(w), weight = unname(w), contribution = unname(rc), share = unname(rc / tot),
                    marginal = unname(mc), stringsAsFactors = FALSE)
  attr(out, "total") <- tot; attr(out, "measure") <- measure
  attr(out, "effective_n") <- 1 / sum((rc / tot)^2)
  if (measure == "volatility") attr(out, "diversification_ratio") <- sum(w * sqrt(diag(.opt_cov(R, cov) * rr$ppy))) / tot
  out
}

#' Kombinatorische Kreuzvalidierung von Optimierungsverfahren (CPCV)
#'
#' Teilt die Historie in \code{n_groups} zeitlich zusammenhaengende Gruppen
#' und bildet alle Kombinationen von \code{test_groups} Testgruppen. Je
#' Aufteilung wird auf den uebrigen Gruppen optimiert - mit einer Sperrzone
#' (\code{purge}) von Perioden an den Grenzen zu den Testgruppen und einem
#' \code{embargo} danach, damit sich Trainings- und Testdaten nicht ueber
#' Autokorrelation beeinflussen - und das Ergebnis auf den Testgruppen
#' bewertet. Statt eines einzelnen Backtests entsteht so eine Verteilung der
#' Out-of-Sample-Kennzahlen je Verfahren (Lopez de Prado 2018, Kap. 12).
#'
#' Eingabe und Renditeberechnung wie bei [portfolio_optimize()]; die
#' Gruppen sind etwa gleich lange, zusammenhaengende Abschnitte der
#' Periodenrenditen. Konkret werden vor jeder Testgruppe \code{purge}
#' Trainingsperioden entfernt und nach jeder Testgruppe
#' \code{max(purge, embargo)} Perioden (Sperrzone und Embargo beginnen beide
#' direkt nach dem Testende; bei 0 entfaellt die jeweilige Sperrzone). Trainiert
#' wird mit denselben Perioden je Jahr wie die Bewertung (bei Kursdaten aus
#' den Daten geschaetzt). Die Testgruppen einer
#' Aufteilung werden fuer die Kennzahlen aneinandergehaengt. Unbekannte
#' Verfahren oder Argumente sind sofort ein Fehler; Verfahren, deren
#' Optimierung in einer Aufteilung fehlschlaegt, fehlen dort (mit Warnung,
#' Einzelheiten in \code{failed}); schlagen alle fehl, bricht die Funktion
#' mit der ersten Fehlermeldung ab.
#'
#' @param x data.frame mit Spalte \code{date} (Date) und Kursspalten
#'   (Kursniveaus) oder Matrix einfacher Periodenrenditen als Anteil (siehe
#'   [portfolio_optimize()]).
#' @param assets Zeichenvektor der Spalten. \code{NULL} (Standard) = alle
#'   numerischen Spalten ausser \code{date} bzw. alle Spalten der Matrix.
#' @param methods Zeichenvektor von Verfahren aus [portfolio_optimize()]
#'   (Standard \code{c("equal", "inverse_vol", "min_variance",
#'   "risk_parity", "max_sharpe")}) oder benannte Liste von Argumentlisten
#'   fuer [portfolio_optimize()] (z. B.
#'   \code{list(mv = list(method = "min_variance", cov = "ledoit_wolf"))}).
#' @param n_groups Anzahl Gruppen insgesamt (ganze Zahl >= 2, Standard 6).
#' @param test_groups Anzahl Testgruppen je Aufteilung (ganze Zahl, Standard
#'   2, kleiner als \code{n_groups}); es gibt choose(n_groups, test_groups)
#'   Aufteilungen.
#' @param purge,embargo Sperrzone und Embargo in Perioden der gewaehlten
#'   Frequenz (Zeilen der Renditen, ganze Zahlen >= 0, je Standard 2).
#' @param frequency Siehe [portfolio_optimize()].
#' @return Objekt der Klasse \code{SimLevCPCV} mit
#'   \describe{
#'     \item{splits}{data.frame je Verfahren und Aufteilung: \code{method},
#'       \code{split}, \code{return} (arithmetisches Mittel, annualisiert,
#'       Anteil p. a.), \code{volatility} (Anteil p. a.), \code{sharpe}
#'       (annualisiert, ohne risikolosen Zins), \code{cdar} (CDaR bei 5 %
#'       der kumulierten, nicht aufgezinsten Testrenditen, Anteil).}
#'     \item{summary}{data.frame je Verfahren, absteigend nach mittlerer
#'       Sharpe Ratio: \code{method}, \code{mean}, \code{sd}, \code{q10},
#'       \code{q50}, \code{q90} (der Sharpe Ratio ueber die Aufteilungen),
#'       \code{volatility}, \code{cdar} (Mittel), \code{best_share} (Anteil
#'       der Aufteilungen, in denen das Verfahren die hoechste Sharpe Ratio
#'       hat, 0 bis 1).}
#'   }
#'   sowie \code{n_splits}, \code{n_groups}, \code{test_groups},
#'   \code{frequency} und \code{failed} (data.frame der fehlgeschlagenen
#'   Optimierungen mit \code{method}, \code{split}, \code{message} oder
#'   \code{NULL}). Methode \code{print}.
#' @seealso [portfolio_optimize()], [rolling_optimization()],
#'   [walk_forward()], [pbo()].
#' @examples
#' set.seed(1); R <- matrix(rnorm(520 * 3, c(0.002, 0.001, 0.0005), c(0.03, 0.02, 0.01)), 520, byrow = TRUE)
#' colnames(R) <- c("aktien", "reits", "anleihen")
#' cp <- cpcv_portfolio(R, methods = c("equal", "inverse_vol", "min_variance"),
#'                      n_groups = 5, test_groups = 2)
#' cp
#' @references Lopez de Prado, M. (2018), Advances in Financial Machine
#'   Learning, Wiley, Kap. 7 und 12.
#' @export
cpcv_portfolio <- function(x, assets = NULL, methods = c("equal", "inverse_vol", "min_variance", "risk_parity", "max_sharpe"),
                           n_groups = 6L, test_groups = 2L, purge = 2L, embargo = 2L,
                           frequency = c("week", "day", "month")) {
  frequency <- match.arg(frequency)
  rr <- .opt_returns(x, assets, frequency); R <- rr$R; Tn <- nrow(R)
  int1 <- function(v, nm, lo) if (!is.numeric(v) || length(v) != 1 || !is.finite(v) || v != round(v) || v < lo)
    stop(sprintf("cpcv_portfolio: %s muss eine ganze Zahl >= %d sein (erhalten: %s).", nm, lo, paste(format(v), collapse = ", ")))
  int1(n_groups, "n_groups", 2); int1(test_groups, "test_groups", 1); int1(purge, "purge", 0); int1(embargo, "embargo", 0)
  if (test_groups >= n_groups) stop(sprintf("cpcv_portfolio: test_groups (%d) muss kleiner als n_groups (%d) sein, sonst bleibt keine Trainingsgruppe.",
                                            test_groups, n_groups))
  specs <- if (is.character(methods)) stats::setNames(lapply(methods, function(m) list(method = m)), methods) else methods
  if (!is.list(specs) || !length(specs) || is.null(names(specs)) || any(names(specs) == ""))
    stop("cpcv_portfolio: methods muss ein Zeichenvektor oder eine benannte Liste von Argumentlisten sein.")
  allowed <- eval(formals(portfolio_optimize)$method)
  for (nm in names(specs)) {
    sp <- specs[[nm]]
    if (!is.list(sp) || (length(sp) && (is.null(names(sp)) || any(names(sp) == ""))))
      stop(sprintf("cpcv_portfolio: Eintrag '%s' von methods muss eine benannte Argumentliste sein.", nm))
    if (!is.null(sp$method) && !sp$method %in% allowed)
      stop(sprintf("cpcv_portfolio: unbekanntes Verfahren '%s'; erlaubt: %s.", sp$method, paste(allowed, collapse = ", ")))
    bad <- setdiff(names(sp), setdiff(names(formals(portfolio_optimize)), c("x", "assets", "frequency")))
    if (length(bad)) stop(sprintf("cpcv_portfolio: unbekannte Argumente f\u00fcr portfolio_optimize() in '%s': %s.", nm, paste0("'", bad, "'", collapse = ", ")))
  }
  grp <- cut(seq_len(Tn), n_groups, labels = FALSE)
  combos <- utils::combn(n_groups, test_groups)
  rows <- list(); fails <- list(); warned <- character()
  for (cidx in seq_len(ncol(combos))) {
    test <- grp %in% combos[, cidx]
    train <- !test
    drop_rows <- function(a, b) { a <- max(1L, a); b <- min(Tn, b); if (b >= a) train[a:b] <<- FALSE }
    for (s0 in which(diff(c(FALSE, test)) == 1)) drop_rows(s0 - purge, s0 - 1L)                  # Sperrzone vor dem Test
    for (e in which(diff(c(test, FALSE)) == -1)) drop_rows(e + 1L, e + max(purge, embargo))     # Sperrzone/Embargo danach
    Rtr <- structure(list(R = R[train, , drop = FALSE], ppy = rr$ppy), class = "SimLevOptReturns")   # Training mit rr$ppy
    Rte <- R[test, , drop = FALSE]
    for (nm in names(specs)) {
      w <- tryCatch(withCallingHandlers(do.call(portfolio_optimize, c(list(x = Rtr, frequency = frequency), specs[[nm]]))$weights,
                                        SimLevBoundsPercent = function(w) { if (nm %in% warned) invokeRestart("muffleWarning"); warned <<- c(warned, nm) }),
                    error = function(e) { fails[[length(fails) + 1L]] <<- data.frame(method = nm, split = cidx, message = conditionMessage(e),
                                                                                      stringsAsFactors = FALSE); NULL })
      if (is.null(w)) next
      r <- drop(Rte %*% w[colnames(R)])
      rows[[length(rows) + 1L]] <- data.frame(method = nm, split = cidx, return = mean(r) * rr$ppy,
                                              volatility = stats::sd(r) * sqrt(rr$ppy),
                                              sharpe = mean(r) / stats::sd(r) * sqrt(rr$ppy),
                                              cdar = .cdar_hist(r, 0.05), stringsAsFactors = FALSE)
    }
  }
  fl <- if (length(fails)) do.call(rbind, fails) else NULL
  if (!length(rows)) stop(sprintf("cpcv_portfolio: keine Optimierung erfolgreich (z. B. '%s' in Aufteilung %d: %s).",
                                  fl$method[1], fl$split[1], fl$message[1]))
  if (!is.null(fl)) warning(sprintf("cpcv_portfolio: %d von %d Optimierungen fehlgeschlagen (z. B. '%s' in Aufteilung %d: %s); sie fehlen in der Auswertung, Einzelheiten in $failed.",
                                    nrow(fl), ncol(combos) * length(specs), fl$method[1], fl$split[1], fl$message[1]))
  sp <- do.call(rbind, rows)
  agg <- function(v) c(mean = mean(v), sd = stats::sd(v), q10 = stats::quantile(v, 0.1, names = FALSE),
                       q50 = stats::median(v), q90 = stats::quantile(v, 0.9, names = FALSE))
  summ <- do.call(rbind, lapply(split(sp, sp$method), function(z)
    data.frame(method = z$method[1], t(agg(z$sharpe)), volatility = mean(z$volatility), cdar = mean(z$cdar),
               best_share = NA_real_, check.names = FALSE)))
  best <- tapply(seq_len(nrow(sp)), sp$split, function(i) sp$method[i][which.max(sp$sharpe[i])])
  summ$best_share <- vapply(summ$method, function(m) mean(best == m), 0)
  rownames(summ) <- NULL
  structure(list(splits = sp, summary = summ[order(-summ$mean), ], n_splits = ncol(combos), n_groups = n_groups,
                 test_groups = test_groups, frequency = frequency, failed = fl), class = "SimLevCPCV")
}

#' @export
print.SimLevCPCV <- function(x, ...) {
  cat(sprintf("CPCV: %d Gruppen, je %d Testgruppen, %d Aufteilungen (%s)\n\n", x$n_groups, x$test_groups, x$n_splits, x$frequency))
  s <- x$summary
  print(data.frame(Verfahren = s$method, `Sharpe Mittel` = sprintf("%.3f", s$mean), `Sharpe Sd` = sprintf("%.3f", s$sd),
                   `10 %` = sprintf("%.3f", s$q10), `90 %` = sprintf("%.3f", s$q90),
                   `Vola` = sprintf("%.2f %%", 100 * s$volatility), `CDaR` = sprintf("%.2f %%", 100 * s$cdar),
                   `bestes Verfahren` = sprintf("%.0f %%", 100 * s$best_share), check.names = FALSE), row.names = FALSE)
  invisible(x)
}

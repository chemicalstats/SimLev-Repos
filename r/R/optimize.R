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
.opt_returns <- function(x, assets = NULL, frequency = "week") {
  if (is.data.frame(x) && "date" %in% names(x)) {
    assets <- assets %||% setdiff(names(x)[vapply(x, is.numeric, TRUE)], "date")
    rd <- .dep_returns(x, assets, NULL, frequency)
    R <- expm1(as.matrix(rd[, assets, drop = FALSE]))
    ppy <- (nrow(rd) - 1) / (as.numeric(rd$date[nrow(rd)] - rd$date[1]) / 365.25)
    return(list(R = R, ppy = ppy, dates = rd$date))
  }
  R <- as.matrix(x); if (!is.null(assets)) R <- R[, assets, drop = FALSE]
  if (is.null(colnames(R))) colnames(R) <- paste0("A", seq_len(ncol(R)))
  list(R = R[stats::complete.cases(R), , drop = FALSE], ppy = switch(frequency, day = 252, week = 52, month = 12), dates = NULL)
}

#' Kovarianzschaetzer (Stichprobe oder Ledoit-Wolf auf skalierte Einheitsmatrix)
#' @keywords internal
.opt_cov <- function(R, type = c("sample", "ledoit_wolf")) {
  type <- match.arg(type)
  S <- stats::cov(R)
  if (type == "sample" || ncol(R) < 2) return(S)
  X <- sweep(R, 2, colMeans(R)); Tn <- nrow(X); N <- ncol(X)
  S1 <- crossprod(X) / Tn
  m <- sum(diag(S1)) / N
  nrm <- function(A) sum(A^2) / N
  d2 <- nrm(S1 - diag(m, N))
  b2 <- min(d2, sum(vapply(seq_len(Tn), function(t) nrm(tcrossprod(X[t, ]) - S1), 0)) / Tn^2)
  a2 <- d2 - b2
  Sh <- (b2 / d2) * diag(m, N) + (a2 / d2) * S1
  dimnames(Sh) <- dimnames(S)
  Sh * Tn / (Tn - 1)
}

#' Projektion auf {sum w = 1, lo <= w <= hi}
#' @keywords internal
.proj_capped_simplex <- function(v, lo, hi) {
  f <- function(t) sum(pmin(hi, pmax(lo, v - t))) - 1
  a <- min(v - hi) - 1; b <- max(v - lo) + 1
  for (i in 1:80) { mid <- (a + b) / 2; if (f(mid) > 0) a <- mid else b <- mid; if (b - a < 1e-15) break }
  pmin(hi, pmax(lo, v - (a + b) / 2))
}

#' FISTA mit adaptivem Neustart fuer min 0.5 w'Qw + c'w auf dem beschraenkten Simplex
#' @keywords internal
.qp_simplex <- function(Q, cvec, lo, hi, w0 = NULL, maxit = 20000L, tol = 1e-12) {
  N <- ncol(Q)
  L <- max(eigen(Q, symmetric = TRUE, only.values = TRUE)$values, 1e-12)
  w <- .proj_capped_simplex(w0 %||% rep(1 / N, N), lo, hi); y <- w; t <- 1
  for (it in seq_len(maxit)) {
    g <- drop(Q %*% y) + cvec
    wn <- .proj_capped_simplex(y - g / L, lo, hi)
    if (max(abs(wn - w)) < tol) { w <- wn; break }
    if (sum(g * (wn - w)) > 0) { t <- 1; y <- wn; w <- wn; next }   # Neustart (O'Donoghue & Candes 2015)
    tn <- (1 + sqrt(1 + 4 * t^2)) / 2
    y <- wn + ((t - 1) / tn) * (wn - w)
    w <- wn; t <- tn
  }
  w
}

#' Risikoparitaet mit Risikobudgets (Spinu 2013, gedaempftes Newton)
#' @keywords internal
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
.min_cvar <- function(R, alpha, lo, hi) {
  Tn <- nrow(R); N <- ncol(R); sc <- stats::sd(as.vector(R))
  w <- .proj_capped_simplex(rep(1 / N, N), lo, hi)
  zeta <- stats::quantile(-drop(R %*% w), 1 - alpha, names = FALSE)
  sp <- function(z) ifelse(z > 30, z, log1p(exp(z)))
  for (s in sc * c(0.05, 0.005)) {
    f <- function(x) x[N + 1] + s * sum(sp((-drop(R %*% x[1:N]) - x[N + 1]) / s)) / (alpha * Tn)
    gr <- function(x) { p <- stats::plogis((-drop(R %*% x[1:N]) - x[N + 1]) / s)
                        c(-drop(crossprod(R, p)) / (alpha * Tn), 1 - sum(p) / (alpha * Tn)) }
    prox <- function(x) c(.proj_capped_simplex(x[1:N], lo, hi), x[N + 1])
    x <- c(w, zeta); yv <- x; t <- 1; L <- 1 / (alpha * s)
    for (it in 1:2000) {
      g <- gr(yv); fy <- f(yv); L <- L / 2
      for (ls in 1:60) { xn <- prox(yv - g / L); dx <- xn - yv
                         if (f(xn) <= fy + sum(g * dx) + L / 2 * sum(dx^2) + 1e-15) break; L <- 2 * L }
      if (max(abs(xn - x)) < 1e-9) { x <- xn; break }
      if (sum(g * (xn - x)) > 0) { t <- 1; yv <- xn; x <- xn; next }
      tn <- (1 + sqrt(1 + 4 * t^2)) / 2
      yv <- xn + ((t - 1) / tn) * (xn - x)
      x <- xn; t <- tn
    }
    w <- x[1:N]; zeta <- x[N + 1]
  }
  w
}

#' Historischer CVaR (erwarteter Verlust jenseits des VaR, positiv)
#' @keywords internal
.cvar_hist <- function(r, alpha) { L <- -r; v <- stats::quantile(L, 1 - alpha, names = FALSE); mean(L[L >= v]) }

#' Grenzen auf Anlagen abbilden
#' @keywords internal
.opt_bounds <- function(b, nm, default) {
  if (length(b) == 1 && is.null(names(b))) return(rep(b, length(nm)))
  v <- stats::setNames(rep(default, length(nm)), nm); v[names(b)] <- b; unname(v)
}

#' Ein Optimierungsschritt auf einer Renditematrix
#' @keywords internal
.opt_core <- function(R, method, lo, hi, cov_type, mu, risk_free, risk_aversion, budget, alpha, ppy) {
  nm <- colnames(R); N <- ncol(R)
  S <- .opt_cov(R, cov_type) * ppy
  m <- if (is.null(mu)) colMeans(R) * ppy else { v <- stats::setNames(rep(NA_real_, N), nm); v[names(mu)] <- mu / 100; v }
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
  w <- switch(method,
    equal = rep(1 / N, N),
    inverse_vol = { v <- 1 / sqrt(diag(S)); v / sum(v) },
    min_variance = .qp_simplex(S, rep(0, N), lo, hi),
    mean_variance = { if (anyNA(m)) stop("mu fuer alle Anlagen angeben."); .qp_simplex(risk_aversion * S, -m, lo, hi) },
    max_sharpe = { if (anyNA(m)) stop("mu fuer alle Anlagen angeben."); best_sharpe(m) },
    max_diversification = { rf <- 0; best_sharpe(sqrt(diag(S))) },
    risk_parity = { if (!default_bounds) warning("risk_parity: Grenzen werden ignoriert.")
                    b <- if (is.null(budget)) rep(1 / N, N) else { v <- .opt_bounds(budget, nm, 0); v / sum(v) }
                    .risk_parity(S, b) },
    hrp = { if (!default_bounds) warning("hrp: Grenzen werden ignoriert."); .hrp(S) },
    min_cvar = .min_cvar(R, alpha, lo, hi),
    stop(sprintf("Unbekannte Methode '%s'.", method)))
  w[abs(w) < 1e-12] <- 0
  stats::setNames(w / sum(w), nm)
}

#' Portfolio optimieren
#'
#' Bestimmt Gewichte fuer ein Long-only-Portfolio (Summe 1) mit optionalen
#' Grenzen je Anlage.
#'
#' \tabular{ll}{
#'   \code{min_variance} \tab minimale Varianz \cr
#'   \code{mean_variance} \tab \eqn{\max \mu'w - \frac{\gamma}{2} w'\Sigma w} mit Risikoaversion \code{risk_aversion} \cr
#'   \code{max_sharpe} \tab maximale Sharpe Ratio (Suche entlang der Effizienzgrenze) \cr
#'   \code{max_diversification} \tab maximales Diversifikationsverhaeltnis \eqn{w'\sigma / \sqrt{w'\Sigma w}} (Choueifaty & Coignard 2008) \cr
#'   \code{risk_parity} \tab gleiche (oder vorgegebene, \code{budget}) Risikobeitraege (Spinu 2013) \cr
#'   \code{hrp} \tab Hierarchical Risk Parity (Lopez de Prado 2016) \cr
#'   \code{min_cvar} \tab minimaler historischer CVaR (Rockafellar & Uryasev 2000, geglaettet) \cr
#'   \code{inverse_vol}, \code{equal} \tab einfache Heuristiken
#' }
#'
#' Erwartete Renditen aus der Historie sind sehr unsicher; Verfahren, die sie
#' nutzen (\code{max_sharpe}, \code{mean_variance}), reagieren stark auf
#' Schaetzfehler. \code{resample} mittelt die Gewichte ueber Block-Bootstrap-
#' Stichproben der Historie (Michaud-Resampling) und glaettet diese
#' Abhaengigkeit.
#'
#' @param x data.frame mit \code{date} und Kursspalten oder Renditematrix.
#' @param assets Spalten (Standard: alle numerischen).
#' @param method Verfahren (siehe oben).
#' @param lower,upper Grenzen je Anlage (Skalar oder benannter Vektor, Anteile).
#' @param cov \code{"sample"} oder \code{"ledoit_wolf"} (Schrumpfung, Ledoit &
#'   Wolf 2004).
#' @param mu Optional erwartete Renditen in Prozent p. a. (benannter Vektor);
#'   sonst historische Mittel.
#' @param risk_free Prozent p. a. (fuer \code{max_sharpe}).
#' @param risk_aversion Fuer \code{mean_variance}.
#' @param budget Risikobudgets fuer \code{risk_parity} (benannter Vektor).
#' @param alpha CVaR-Niveau (Standard 0.05).
#' @param frequency \code{"week"} (Standard), \code{"day"}, \code{"month"}.
#' @param resample Anzahl Bootstrap-Stichproben (0 = aus).
#' @param block Mittlere Blocklaenge fuer das Resampling (Perioden).
#' @param seed Startwert.
#' @return Objekt der Klasse \code{SimLevOptimization}: \code{weights},
#'   \code{stats} (erwartete Rendite, Volatilitaet, Sharpe, CVaR,
#'   Diversifikationsverhaeltnis, effektive Anzahl), \code{risk}
#'   (Risikobeitraege), Eingaben.
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
                                          "risk_parity", "hrp", "min_cvar", "inverse_vol", "equal"),
                               lower = 0, upper = 1, cov = c("sample", "ledoit_wolf"), mu = NULL, risk_free = 0,
                               risk_aversion = 4, budget = NULL, alpha = 0.05, frequency = c("week", "day", "month"),
                               resample = 0L, block = NULL, seed = NULL) {
  method <- match.arg(method); cov <- match.arg(cov); frequency <- match.arg(frequency)
  rr <- .opt_returns(x, assets, frequency); R <- rr$R; nm <- colnames(R); N <- ncol(R)
  if (nrow(R) < N + 5) stop("Zu wenige Beobachtungen fuer die Optimierung.")
  lo <- .opt_bounds(lower, nm, 0); hi <- .opt_bounds(upper, nm, 1)
  if (sum(lo) > 1 + 1e-12 || sum(hi) < 1 - 1e-12 || any(lo > hi)) stop("Grenzen nicht erfuellbar (sum(lower) <= 1 <= sum(upper)).")
  core <- function(Rx) .opt_core(Rx, method, lo, hi, cov, mu, risk_free, risk_aversion, budget, alpha, rr$ppy)
  w <- core(R)
  wb <- NULL
  if (resample > 0) {
    block <- block %||% max(2, round(nrow(R)^(1 / 3)))
    wb <- .with_rng_restore({
      if (!is.null(seed)) set.seed(seed)
      t(vapply(seq_len(resample), function(b) core(R[.boot_idx_stationary(nrow(R), nrow(R), block), , drop = FALSE]), numeric(N)))
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
.opt_summary <- function(w, R, ppy, cov_type, risk_free, alpha) {
  S <- .opt_cov(R, cov_type) * ppy; m <- colMeans(R) * ppy
  vol <- sqrt(drop(t(w) %*% S %*% w)); ret <- sum(w * m)
  rp <- drop(R %*% w)
  rc <- w * drop(S %*% w) / vol
  list(weights = w,
       stats = c(expected_return = ret, volatility = vol, sharpe = (ret - risk_free / 100) / vol,
                 cvar = .cvar_hist(rp, alpha), diversification_ratio = sum(w * sqrt(diag(S))) / vol,
                 effective_n = 1 / sum(w^2), effective_n_risk = 1 / sum((rc / vol)^2)),
       risk = data.frame(asset = names(w), weight = w, volatility_contribution = rc, risk_share = rc / vol,
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
  cat(sprintf("\nErwartete Rendite %.2f %% p. a. (historisch), Volatilitaet %.2f %%, Sharpe %.3f, CVaR(%g) %.2f %% je Periode\n",
              100 * s["expected_return"], 100 * s["volatility"], s["sharpe"], x$alpha, 100 * s["cvar"]))
  cat(sprintf("Diversifikationsverhaeltnis %.2f, effektive Anzahl: Gewichte %.1f, Risiko %.1f\n",
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
#' Berechnet Mean-Variance-effiziente Portfolios unter denselben Grenzen wie
#' [portfolio_optimize()] (Sweep ueber die Risikoaversion) und markiert das
#' Portfolio mit der hoechsten Sharpe Ratio und das Minimum-Varianz-Portfolio.
#'
#' @inheritParams portfolio_optimize
#' @param n Anzahl Punkte.
#' @return Objekt der Klasse \code{SimLevFrontier}: \code{frontier}
#'   (Rendite, Volatilitaet, Sharpe, Gewichte je Punkt) und \code{assets}
#'   (Einzelanlagen).
#' @export
efficient_frontier <- function(x, assets = NULL, n = 40L, lower = 0, upper = 1, cov = c("sample", "ledoit_wolf"),
                               risk_free = 0, frequency = c("week", "day", "month")) {
  cov <- match.arg(cov); frequency <- match.arg(frequency)
  rr <- .opt_returns(x, assets, frequency); R <- rr$R; nm <- colnames(R)
  lo <- .opt_bounds(lower, nm, 0); hi <- .opt_bounds(upper, nm, 1)
  S <- .opt_cov(R, cov) * rr$ppy; m <- colMeans(R) * rr$ppy
  W <- t(vapply(exp(seq(log(1e4), log(0.02), length.out = n)), function(g) .qp_simplex(g * S, -m, lo, hi), numeric(length(nm))))
  colnames(W) <- nm
  ret <- drop(W %*% m); vol <- sqrt(rowSums((W %*% S) * W))
  keep <- !duplicated(round(cbind(ret, vol), 6))
  fr <- data.frame(expected_return = ret, volatility = vol, sharpe = (ret - risk_free / 100) / vol, W, check.names = FALSE)[keep, ]
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
                 xlab = "Volatilitaet (% p. a.)", ylab = "Rendite (% p. a., historisch)", main = "Effizienzgrenze", ...)
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
#' Entscheidung nutzt nur Daten, die zum Zeitpunkt vorlagen.
#'
#' @inheritParams portfolio_optimize
#' @param window Fensterlaenge in Jahren.
#' @param every Entscheidungsrhythmus (\code{"month"}, \code{"quarter"},
#'   \code{"year"}).
#' @param ... Weitere Argumente fuer [portfolio_optimize()] (\code{lower},
#'   \code{upper}, \code{cov}, \code{mu}, \code{budget}, ...).
#' @return \code{SimLevWeights}; vor dem ersten vollen Fenster gleich gewichtet.
#' @export
rolling_optimization <- function(x, assets, method = "min_variance", window = 3, every = c("month", "quarter", "year"),
                                 frequency = c("week", "day", "month"), ...) {
  every <- match.arg(every); frequency <- match.arg(frequency)
  d <- as.Date(x$date); n <- length(d)
  rows <- .period_last(d, every)
  first_ok <- d[1] + round(window * 365.25)
  rows <- rows[d[rows] >= first_ok]
  if (!length(rows)) stop("Historie kuerzer als das Fenster.")
  M <- t(vapply(rows, function(i) {
    sub <- x[d > d[i] - round(window * 365.25) & d <= d[i], c("date", assets), drop = FALSE]
    w <- tryCatch(portfolio_optimize(sub, assets, method = method, frequency = frequency, ...)$weights,
                  error = function(e) rep(NA_real_, length(assets)))
    if (anyNA(w)) rep(1 / length(assets), length(assets)) else w
  }, numeric(length(assets))))
  if (!is.matrix(M)) M <- matrix(M, ncol = length(assets))
  colnames(M) <- assets
  H <- .hold_rows(n, rows, M); H[seq_len(rows[1] - 1L), ] <- 1 / length(assets)
  out <- .as_weights(d, H, paste("rolling", method))
  attr(out, "decision_rows") <- rows
  out
}

#' Risikobeitraege (Euler-Zerlegung)
#'
#' Zerlegt Volatilitaet oder historischen CVaR eines Portfolios additiv auf
#' die Anlagen: \eqn{RC_i = w_i \partial \rho / \partial w_i},
#' \eqn{\sum_i RC_i = \rho}. Fuer die Volatilitaet
#' \eqn{RC_i = w_i (\Sigma w)_i / \sigma_p}, fuer den CVaR der mittlere
#' Verlustbeitrag der Anlage in den Perioden jenseits des VaR.
#'
#' @param x data.frame mit \code{date} und Kursspalten oder Renditematrix.
#' @param weights Benannter Gewichtsvektor (oder \code{SimLevOptimization}).
#' @param measure \code{"volatility"} oder \code{"cvar"}.
#' @param alpha CVaR-Niveau.
#' @param frequency,cov Siehe [portfolio_optimize()].
#' @return data.frame je Anlage: Gewicht, Beitrag, Anteil, marginaler Beitrag;
#'   Attribute \code{total}, \code{diversification_ratio}, \code{effective_n}.
#' @export
risk_contributions <- function(x, weights, measure = c("volatility", "cvar"), alpha = 0.05,
                               frequency = c("week", "day", "month"), cov = c("sample", "ledoit_wolf")) {
  measure <- match.arg(measure); frequency <- match.arg(frequency); cov <- match.arg(cov)
  if (inherits(weights, "SimLevOptimization")) weights <- weights$weights
  rr <- .opt_returns(x, names(weights), frequency); R <- rr$R; w <- weights[colnames(R)]
  if (measure == "volatility") {
    S <- .opt_cov(R, cov) * rr$ppy; tot <- sqrt(drop(t(w) %*% S %*% w))
    mc <- drop(S %*% w) / tot; rc <- w * mc
  } else {
    rp <- drop(R %*% w); L <- -rp; v <- stats::quantile(L, 1 - alpha, names = FALSE); tail <- L >= v
    rc <- colMeans(-R[tail, , drop = FALSE]) * w; tot <- sum(rc); mc <- rc / w
  }
  out <- data.frame(asset = names(w), weight = unname(w), contribution = unname(rc), share = unname(rc / tot),
                    marginal = unname(mc), stringsAsFactors = FALSE)
  attr(out, "total") <- tot; attr(out, "measure") <- measure
  attr(out, "effective_n") <- 1 / sum((rc / tot)^2)
  if (measure == "volatility") attr(out, "diversification_ratio") <- sum(w * sqrt(diag(.opt_cov(R, cov) * rr$ppy))) / tot
  out
}

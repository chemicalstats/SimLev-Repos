# =============================================================================
#  ms_garch.R  —  eigene ML-Schaetzung des MS-GARCH-Modells
# -----------------------------------------------------------------------------
#  Modell nach Haas, Mittnik und Paolella (2004): K Regime, je Regime ein
#  GARCH(1,1)- ("sGARCH") oder GJR-GARCH(1,1)-Varianzpfad ("gjrGARCH"); die
#  Varianzpfade aller Regime laufen parallel; Normalverteilung mit Mittelwert
#  0; Regimewechsel als Markov-Kette. Likelihood ueber den Hamilton-Filter im
#  C-Kern .ms_garch_filter (src/ms_garch.c), Maximierung mit optim (BFGS) auf
#  eigener Parametrisierung auf R^p, deterministische Startwerte (kein Zufall):
#  volles HMM-EM (.hmm_em) und Rangeinteilung der Volatilitaet, je mit kleinem
#  Raster; optim von beiden Familien, die hoehere Log-Likelihood zaehlt.
#  Genutzt von .prepare_ms_info (R/bootstrap.R) fuer die Verfahren "ms_garch",
#  "ms_ar_garch_m" und "tvtp_ms_garch".
#
#  Der Code ist bewusst einfach gehalten: Die Ports (Python, Julia) bilden ihn
#  Zeile fuer Zeile nach. Summen weniger Werte sind daher als fortlaufende
#  double-Additionen geschrieben (nicht sum()/rowSums(), die in R mit hoeherer
#  Genauigkeit summieren).
# =============================================================================

#' Varianzmodell und Regimezahl der MS-GARCH-Schaetzung pruefen
#' @keywords internal
#' @noRd
.ms_garch_check <- function(K, model) {
  if (!is.character(model) || length(model) != 1L || is.na(model) || !model %in% c("sGARCH", "gjrGARCH"))
    stop(sprintf("MS-GARCH: Varianzmodell je Regime (params ms_garch_model, ms_ar_garch_model bzw. tvtp_garch_model) muss \"sGARCH\" oder \"gjrGARCH\" sein (erhalten: %s).",
                 paste(format(model), collapse = ", ")))
  if (!is.numeric(K) || length(K) != 1L || !is.finite(K) || K != round(K) || K < 2)
    stop(sprintf("MS-GARCH: Anzahl Regime (params ms_n_regimes, ms_ar_n_regimes bzw. tvtp_n_regimes) muss eine ganze Zahl >= 2 sein (erhalten: %s).",
                 paste(format(K), collapse = ", ")))
  invisible(TRUE)
}

#' Stationaere Verteilung einer Uebergangsmatrix (Potenziteration wie fuer pi_
#' in .prepare_ms_info: Start gleichverteilt, hoechstens 1000 Schritte, Abbruch
#' bei maximaler Aenderung < 1e-12)
#' @keywords internal
#' @noRd
.ms_garch_stat <- function(P) {
  K <- nrow(P)
  pi_ <- rep(1 / K, K); for (it in 1:1000) { p2 <- as.numeric(pi_ %*% P); if (max(abs(p2 - pi_)) < 1e-12) break; pi_ <- p2 }
  pi_
}

#' Parametervektor auf R^p in Modellparameter umrechnen
#'
#' Reihenfolge: je Regime 1 bis K (theta_omega, a, [g], b), danach P
#' zeilenweise ohne Diagonale. omega = exp(theta_omega); sGARCH: e = exp(c(a, b)),
#' alpha = e[1] / (1 + sum(e)), beta = e[2] / (1 + sum(e)); gjrGARCH:
#' e = exp(c(a, g, b)), alpha = e[1] / d, gamma = 2 * e[2] / d, beta = e[3] / d
#' mit d = 1 + sum(e). Zeile i von P: exp(theta_i.) mit theta_ii = 0, geteilt
#' durch die Zeilensumme.
#' @keywords internal
#' @noRd
.ms_garch_unpack <- function(theta, K, gjr) {
  np <- if (gjr) 4L else 3L
  om <- al <- be <- ga <- numeric(K)
  for (k in seq_len(K)) {
    j <- (k - 1L) * np
    om[k] <- exp(theta[j + 1L])
    if (gjr) {
      e1 <- exp(theta[j + 2L]); e2 <- exp(theta[j + 3L]); e3 <- exp(theta[j + 4L])
      d <- 1 + ((e1 + e2) + e3)
      al[k] <- e1 / d; ga[k] <- 2 * e2 / d; be[k] <- e3 / d
    } else {
      e1 <- exp(theta[j + 2L]); e2 <- exp(theta[j + 3L])
      d <- 1 + (e1 + e2)
      al[k] <- e1 / d; be[k] <- e2 / d
    }
  }
  P <- matrix(0, K, K); pos <- K * np
  for (i in seq_len(K)) {
    for (j in seq_len(K)) if (j == i) P[i, j] <- 1 else { pos <- pos + 1L; P[i, j] <- exp(theta[pos]) }
    s <- 0; for (j in seq_len(K)) s <- s + P[i, j]
    for (j in seq_len(K)) P[i, j] <- P[i, j] / s
  }
  list(omega = om, alpha = al, beta = be, gamma = ga, P = P)
}

#' Modellparameter in den Parametervektor auf R^p umrechnen (Umkehrung von
#' .ms_garch_unpack; Restanteil r = 1 - alpha - gamma/2 - beta = 1 / d)
#' @keywords internal
#' @noRd
.ms_garch_pack <- function(om, al, be, ga, P, gjr) {
  K <- length(om); th <- numeric(0)
  for (k in seq_len(K)) {
    r <- 1 - al[k] - ga[k] / 2 - be[k]
    th <- c(th, log(om[k]), log(al[k] / r), if (gjr) log((ga[k] / 2) / r), log(be[k] / r))
  }
  for (i in seq_len(K)) for (j in seq_len(K)) if (j != i) th <- c(th, log(P[i, j] / P[i, i]))
  th
}

#' MS-GARCH-Modell per Maximum Likelihood schaetzen (eigene Fassung)
#'
#' @param y Numerischer Vektor (Tagesrenditen als Anteil, Mittelwert 0 angenommen).
#' @param K Anzahl Regime (ganze Zahl >= 2).
#' @param model Varianzmodell je Regime: "sGARCH" oder "gjrGARCH".
#' @return list(omega, alpha, beta, gamma, P, regimes, s2, loglik,
#'   convergence): Parameter je Regime (aufsteigend nach unbedingter Varianz
#'   omega / (1 - alpha - gamma/2 - beta) sortiert; gamma = 0 bei "sGARCH"),
#'   Uebergangsmatrix P (Zeile = von), Viterbi-Pfad (ganze Zahlen 1 bis K),
#'   vorhergesagte Mischungsvarianz s2[t] = sum_k P(s_t = k | F_{t-1}) h[t, k],
#'   Log-Likelihood und Konvergenzcode von optim.
#' @keywords internal
#' @noRd
.ms_garch_fit <- function(y, K, model) {
  .ms_garch_check(K, model)
  K <- as.integer(K); gjr <- model == "gjrGARCH"
  y <- as.numeric(y); n <- length(y)
  h1 <- stats::var(y)
  # Zielfunktion: negative Log-Likelihood, 1e10 statt -Inf
  nll <- function(theta) {
    m <- .ms_garch_unpack(theta, K, gjr)
    if (!all(is.finite(c(m$omega, m$alpha, m$beta, m$gamma, m$P)))) return(1e10)
    ll <- .ms_garch_filter(y, m$omega, m$alpha, m$beta, m$gamma, m$P, .ms_garch_stat(m$P), h1)$loglik
    if (is.finite(ll)) -ll else 1e10
  }
  # Zeilen einer Start-Uebergangsmatrix mit Nullen oder nicht endlichen Werten:
  # 0.9 auf der Diagonale, Rest gleich verteilt
  fix_P <- function(P0) {
    for (i in seq_len(K)) if (!all(is.finite(P0[i, ])) || any(P0[i, ] == 0)) {
      P0[i, ] <- 0.1 / (K - 1); P0[i, i] <- 0.9
    }
    P0
  }
  # Zweite Start-Uebergangsmatrix je Familie: 0.99 auf der Diagonale, Rest gleich verteilt
  P99 <- matrix(0.01 / (K - 1), K, K); for (i in seq_len(K)) P99[i, i] <- 0.99
  # Festes Raster (alpha, [gamma], beta), omega ueber Varianz-Targeting
  grid <- if (gjr) list(c(0.03, 0.06, 0.90), c(0.05, 0.10, 0.82), c(0.02, 0.04, 0.94))
          else list(c(0.05, 0, 0.90), c(0.10, 0, 0.85), c(0.03, 0, 0.95))
  # Bester Startpunkt einer Familie (Varianzen s2k aufsteigend, Start-Uebergangsmatrix
  # P0): Raster mit P0, danach Raster mit P99; hoechste Log-Likelihood, bei
  # Gleichstand der erste Punkt
  best_start <- function(s2k, P0) {
    par0 <- NULL; best <- Inf
    for (Pst in list(P0, P99)) for (g in grid) {
      al <- rep(g[1], K); ga <- rep(g[2], K); be <- rep(g[3], K)
      om <- s2k * (1 - g[1] - g[2] / 2 - g[3])
      p <- .ms_garch_pack(om, al, be, ga, Pst, gjr)
      v <- nll(p)
      if (is.null(par0) || v < best) { par0 <- p; best <- v }
    }
    par0
  }
  starts <- list()
  # Familie 1 (HMM-Start): volles Baum-Welch-EM des Gauss'schen HMM auf y wie in
  # regime_hmm (Startwert aus der Rangeinteilung der rollierenden Volatilitaet,
  # 21 Tage), Zustaende aufsteigend nach Varianz; bei Abbruch nur Familie 2
  X <- matrix(y)
  ridge <- diag(1e-10 + 1e-6 * mean(apply(X, 2, stats::var)), 1)
  hm <- tryCatch(.hmm_em(X, K, .hmm_init_rank(X, K, 21L, ridge), 300L, 1e-7, ridge), error = function(e) NULL)
  if (!is.null(hm)) {
    s2h <- vapply(hm$S, function(s) s[1, 1], 0)
    if (all(is.finite(s2h)) && all(s2h > 0) && all(is.finite(hm$A))) {
      o <- order(s2h)
      starts[[length(starts) + 1L]] <- best_start(s2h[o], fix_P(hm$A[o, o, drop = FALSE]))
    }
  }
  # Familie 2 (Rang-Start): Regime aus Quantilen der rollierenden Volatilitaet (wie
  # .prepare_regime_info; .rolling_vol erwartet Brutto-Renditen), Varianz je
  # Regime aufsteigend
  vol <- .rolling_vol(y + 1, 21L)
  th <- stats::quantile(vol, probs = seq(0, 1, length.out = K + 1))
  th[length(th)] <- th[length(th)] + 1e-10
  reg0 <- .assign_regimes(vol, th)
  P0 <- fix_P(.estimate_trans_mat(reg0, K))
  s2k <- vapply(seq_len(K), function(k) { i <- which(reg0 == k); if (length(i) < 30) h1 else stats::var(y[i]) }, 0)
  starts[[length(starts) + 1L]] <- best_start(sort(s2k), P0)
  # Optimierung (BFGS mit numerischem Gradienten, ohne Hesse-Matrix) von jedem
  # Startpunkt; genommen wird die hoechste Log-Likelihood, bei Gleichstand der
  # erste Lauf (HMM-Start vor Rang-Start)
  o <- NULL
  for (par0 in starts) {
    oi <- stats::optim(par0, nll, method = "BFGS", control = list(maxit = 500, reltol = 1e-10))
    if (is.null(o) || oi$value < o$value) o <- oi
  }
  if (!is.finite(o$value) || o$value >= 1e10 || !all(is.finite(o$par)))
    stop(sprintf("Log-Likelihood nicht endlich (optim-Code %d).", o$convergence))
  # Identifikation: Regime aufsteigend nach unbedingter Varianz
  m <- .ms_garch_unpack(o$par, K, gjr)
  unc <- m$omega / (1 - m$alpha - m$gamma / 2 - m$beta)
  ord <- order(unc)
  om <- m$omega[ord]; al <- m$alpha[ord]; be <- m$beta[ord]; ga <- m$gamma[ord]
  P <- m$P[ord, ord, drop = FALSE]
  # Letzter Filterlauf mit den sortierten Parametern
  xi0 <- .ms_garch_stat(P)
  f <- .ms_garch_filter(y, om, al, be, ga, P, xi0, h1)
  if (!is.finite(f$loglik)) stop("Log-Likelihood nicht endlich (letzter Filterlauf).")
  s2 <- f$pred[, 1] * f$h[, 1]
  for (k in seq_len(K)[-1]) s2 <- s2 + f$pred[, k] * f$h[, k]
  regimes <- .hmm_viterbi(f$lB, log(P), log(xi0))
  list(omega = om, alpha = al, beta = be, gamma = ga, P = P, regimes = as.integer(regimes),
       s2 = s2, loglik = f$loglik, convergence = o$convergence)
}

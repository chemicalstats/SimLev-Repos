# =============================================================================
#  ms_garch.R  —  eigene ML-Schaetzung des MS-GARCH-Modells
# -----------------------------------------------------------------------------
#  Modell nach Haas, Mittnik und Paolella (2004): K Regime, je Regime ein
#  GARCH(1,1)- ("sGARCH") oder GJR-GARCH(1,1)-Varianzpfad ("gjrGARCH"); die
#  Varianzpfade aller Regime laufen parallel; Normalverteilung mit Mittelwert
#  0; Regimewechsel als Markov-Kette. Likelihood ueber den Hamilton-Filter im
#  C-Kern, Maximierung mit BFGS auf eigener Parametrisierung auf R^p,
#  deterministische Startwerte (kein Zufall): volles HMM-EM und Rangeinteilung
#  der Volatilitaet, je mit kleinem Raster. Seit 1.0.0 rechnet die
#  Schaetzung ganz in der C-Bibliothek slc (.sl_ms_garch_fit, src/slc_msgarch.cpp);
#  hier bleibt die Pruefung (Parametrisierung, Filter und stationaere Verteilung seit 1.0.0
#  nur in C; die Ports behalten die stationaere Verteilung als Hilfe von
#  .prepare_ms_info).
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
    stop("MS-GARCH: Varianzmodell je Regime (params ms_garch_model, ms_ar_garch_model bzw. tvtp_garch_model) muss \"sGARCH\" oder \"gjrGARCH\" sein.")   # seit 1.6.4 ohne Wert (Entscheidung 8)
  # seit 1.6.4 mit Obergrenze 64 des Kerns (B-097; bis 1.6.3 je Sprache andere Meldung des Kerns)
  if (is.factor(K) || !is.numeric(K) || length(K) != 1L || !is.finite(K) || K != round(K) || K < 2 || K > 64)
    stop("MS-GARCH: Anzahl Regime (params ms_n_regimes, ms_ar_n_regimes bzw. tvtp_n_regimes) muss eine ganze Zahl >= 2 und <= 64 sein.")
  invisible(TRUE)
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
#'   Log-Likelihood und Konvergenzcode des besten BFGS-Laufs.
#'
#' Seit 1.0.0 ganz in der C-Bibliothek slc (.sl_ms_garch_fit,
#' R/slc_models.R): Starts aus HMM-EM und Rangeinteilung wie
#' bisher, BFGS (maxit 500, reltol 1e-10, mit analytischem Gradienten)
#' von allen Rasterpunkten beider Familien (die zwei bisherigen zuerst; sGARCH
#' 12, gjrGARCH 20 mit zwei Rasterpunkten gamma < 0), der beste Lauf
#' gewinnt. GJR je Regime mit alpha + gamma >= 0, also auch gamma < 0.
#' \code{cores} Threads fuer die Starts (Ergebnis unabhaengig davon; Standard 1).
#' @keywords internal
#' @noRd
.ms_garch_fit <- function(y, K, model, cores = 1L) .sl_ms_garch_fit(y, K, model, cores)

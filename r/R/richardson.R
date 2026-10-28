# =============================================================================
#  richardson.R  —  numerische Ableitungen mit Richardson-Extrapolation
# -----------------------------------------------------------------------------
#  Eigenstaendig fuer SimLev geschrieben (GPL-3) nach dem veroeffentlichten
#  Verfahren: zentrale Differenzen mit Schrittweiten h = |d x| + eps, falls
#  |x| < zero.tol (sonst |d x|), r Stufen mit jeweils um den Faktor v
#  verkleinerter Schrittweite und Richardson-Extrapolation der Stufen
#  (Beschreibung in der Dokumentation des R-Pakets numDeriv zu grad, genD,
#  hessian und jacobian; Linfield, G. R. and Penny, J. E. T. (1989)
#  Microcomputers in Numerical Analysis, Halsted Press). Es ist kein Code
#  aus numDeriv uebernommen; numDeriv diente nur als Pruef-Orakel (gleiche
#  Eingaben, identical() auf den Ergebnissen, siehe
#  golden/modules/gen_rugarch.R und tests/testthat/test-richardson.R).
#
#  Damit die Ergebnisse mit den bisherigen (mit numDeriv erzeugten) Werten
#  bitgleich sind, haelt die Rechnung eine feste Reihenfolge ein:
#    * die Zielfunktion wird an denselben Punkten in derselben Reihenfolge
#      ausgewertet (die Likelihood von rugarch merkt sich ihren letzten
#      endlichen Wert und straft damit nicht endliche Werte; jede
#      zusaetzliche oder vertauschte Auswertung aendert also das Ergebnis);
#    * die Differenzenquotienten und die Extrapolationsschritte werden mit
#      derselben Klammerung gerechnet (siehe die Kommentare unten).
#  Genutzt von .rugarch_makefitmodel() (R/vendor_rugarch.R).
# =============================================================================

# Anfangsschrittweite je Koordinate: relativ (Anteil d von |x|), bei
# Koordinaten nahe null zusaetzlich der absolute Schritt eps.
.sl_richardson_steps <- function(x, d, eps, zero.tol)
  abs(d * x) + eps * (abs(x) < zero.tol)

# Richardson-Tableau zusammenfalten. 'tab' hat eine Zeile je geschaetzter
# Groesse und eine Spalte je Stufe (grobe Schrittweite links). Der Fehler
# zentraler Differenzen enthaelt nur gerade Potenzen von h; Schritt m des
# Tableaus tilgt den Term h^(2m) mit dem Gewicht w = v^(2m):
#   neu_k = (alt_(k+1) * w - alt_k) / (w - 1)
# Nach r - 1 Schritten bleibt eine Spalte, der extrapolierte Wert.
.sl_richardson_collapse <- function(tab, v) {
  lvl <- 0
  while (ncol(tab) > 1L) {
    lvl <- lvl + 1
    w <- v^(2 * lvl)
    last <- ncol(tab)
    tab <- (tab[, -1L, drop = FALSE] * w - tab[, -last, drop = FALSE]) / (w - 1)
  }
  tab[, 1L]
}

#' Hesse-Matrix einer skalaren Funktion per Richardson-Extrapolation
#'
#' Reine zweite Ableitungen aus f(x + h e_a) - 2 f(x) + f(x - h e_a) ueber
#' h_a^2, gemischte aus den Diagonalschritten x +- (h_a e_a + h_b e_b)
#' abzueglich der reinen Anteile; jede Groesse ueber r Stufen extrapoliert.
#' @keywords internal
#' @noRd
.sl_richardson_hessian <- function(func, x, eps = 1e-4, d = 0.1,
                                   zero.tol = sqrt(.Machine$double.eps / 7e-07),
                                   r = 4, v = 2, ...) {
  p <- length(x)
  # Zwei Auswertungen im Punkt selbst: eine zur Pruefung, dass func skalar
  # ist, eine als Mittelwert der Differenzen (beide noetig, s. Kopf).
  if (length(func(x, ...)) != 1L)
    stop("Hesse-Matrix nach Richardson nur fuer skalare Funktionen")
  centre <- func(x, ...)
  start <- .sl_richardson_steps(x, d, eps, zero.tol)
  axis <- diag(p)                       # Spalte a = Einheitsvektor e_a
  tab <- matrix(0, 1L, r)

  # 1. reine zweite Ableitungen d2f/dx_a^2, Achse fuer Achse
  pure <- numeric(p)
  for (a in seq_len(p)) {
    h <- start
    for (s in seq_len(r)) {
      fwd <- func(x + h * axis[, a], ...)
      bwd <- func(x - h * axis[, a], ...)
      tab[1L, s] <- (fwd - 2 * centre + bwd) / h[a]^2
      h <- h / v
    }
    pure[a] <- .sl_richardson_collapse(tab, v)
  }

  # 2. gemischte Ableitungen d2f/(dx_a dx_b), a > b, zeilenweise im unteren
  #    Dreieck. Klammerung fest: Zaehler von links nach rechts, erst der
  #    reine Anteil der Achse a, dann der von b; Nenner (2 h_a) h_b.
  low <- matrix(0, p, p)
  for (a in seq_len(p)) {
    low[a, a] <- pure[a]
    for (b in seq_len(a - 1L)) {
      h <- start
      for (s in seq_len(r)) {
        fwd <- func(x + h * axis[, a] + h * axis[, b], ...)
        bwd <- func(x - h * axis[, a] - h * axis[, b], ...)
        tab[1L, s] <- (fwd - 2 * centre + bwd - pure[a] * h[a]^2 - pure[b] * h[b]^2) /
          (2 * h[a] * h[b])
        h <- h / v
      }
      low[a, b] <- .sl_richardson_collapse(tab, v)
    }
  }

  # 3. symmetrisch ergaenzen: unteres Dreieck plus Transponierte, die dabei
  #    verdoppelte Diagonale wieder halbieren
  hess <- low + t(low)
  diag(hess) <- diag(hess) / 2
  hess
}

#' Jacobi-Matrix per Richardson-Extrapolation
#'
#' Zentrale Differenzen (f(x + h e_a) - f(x - h e_a)) / (2 h_a) fuer jede
#' Komponente von f; Stufe fuer Stufe alle Achsen, danach extrapoliert.
#' Ergebnis: Matrix length(f(x)) x length(x).
#' @keywords internal
#' @noRd
.sl_richardson_jacobian <- function(func, x, eps = 1e-4, d = 1e-4,
                                    zero.tol = sqrt(.Machine$double.eps / 7e-07),
                                    r = 4, v = 2, ...) {
  p <- length(x)
  q <- length(func(x, ...))             # Zahl der Komponenten von f
  h <- .sl_richardson_steps(x, d, eps, zero.tol)
  axis <- diag(p)
  # Zeilen: Eintraege der Jacobi-Matrix (spaltenweise), Spalten: Stufen
  tab <- matrix(NA_real_, q * p, r)
  for (s in seq_len(r)) {
    stage <- matrix(NA_real_, q, p)
    for (a in seq_len(p)) {
      fwd <- func(x + h * axis[, a], ...)
      bwd <- func(x - h * axis[, a], ...)
      stage[, a] <- (fwd - bwd) / (2 * h[a])
    }
    tab[, s] <- stage
    h <- h / v
  }
  matrix(.sl_richardson_collapse(tab, v), q, p)
}

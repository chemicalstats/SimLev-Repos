# =============================================================================
#  vendor_truncnorm.R  —  uebernommene Teile des R-Pakets truncnorm
# -----------------------------------------------------------------------------
#  Paket:     truncnorm 1.0-9 (CRAN, 2023-03-20), Datei R/truncnorm.R
#  Autoren:   Olaf Mersmann [aut, cre], Heike Trautmann [aut],
#             Detlef Steuer [aut], Bjoern Bornkamp [aut]
#  Lizenz:    GPL (>= 2); in SimLev unter GPL-3 weitergegeben
#  Angepasst fuer SimLev (siehe inst/COPYRIGHTS):
#    * rtruncnorm() als interne Funktion .truncnorm_rtruncnorm(); der
#      Funktionsrumpf ist unveraendert bis auf den Namen der C-Routine
#      (C_truncnorm_rtruncnorm in src/vendor_truncnorm.c statt
#      C_do_rtruncnorm). dtruncnorm, ptruncnorm, qtruncnorm, etruncnorm und
#      vtruncnorm sind nicht uebernommen.
#  Genutzt von .rsolnp_distr2() (Startwerte von .rsolnp_gosolnp(),
#  R/vendor_rsolnp.R), das .rugarch_gosolnpsolver() erreicht.
# =============================================================================

#' Gestutzte Normalverteilung: Zufallszahlen (aus truncnorm 1.0-9, rtruncnorm)
#' @keywords internal
#' @noRd
.truncnorm_rtruncnorm <- function(n, a=-Inf, b=Inf, mean=0, sd=1) {
  stopifnot(length(a) > 0,
            length(b) > 0,
            length(mean) > 0,
            length(sd) > 0)
  if (length(n) > 1)
    n <- length(n)
  else if (!is.numeric(n))
    stop("non-numeric argument n.")
  else if (n == 0)
    return(NULL)
  .Call(C_truncnorm_rtruncnorm, as.integer(n),
        as.numeric(a), as.numeric(b), as.numeric(mean), as.numeric(sd))
}

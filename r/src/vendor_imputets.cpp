/*
 * vendor_imputets.cpp  --  uebernommener C++-Code des R-Pakets imputeTS
 *
 * Paket:    imputeTS 3.4 (CRAN, 2025-08-25), Datei src/locf.cpp (Funktion locf)
 * Autoren:  Steffen Moritz [aut, cre, cph], Sebastian Gatscha [aut],
 *           Earo Wang [ctb], Ron Hause [ctb]
 * Lizenz:   GPL-3
 * Angepasst fuer SimLev (siehe inst/COPYRIGHTS):
 *   - locf heisst hier imputets_locf und wird unter dem R-Namen
 *     .imputets_locf ueber .Call gerufen (wie in imputeTS); die .Call-Huelle
 *     C_imputets_locf steht am Dateiende und ist in init.c registriert.
 *   - Seit SimLev 0.5.0 ohne Rcpp: NumericVector/clone/checkUserInterrupt
 *     sind durch die gleichwertigen Hilfen aus simlev_capi.h ersetzt
 *     (sl::NumVec, sl::clone = Rf_duplicate, sl::check_interrupt); die
 *     Rechnung des Funktionsrumpfs ist unveraendert.
 *   - ma() aus imputeTS src/ma.cpp ist nicht uebernommen.
 * Gerufen von .imputets_na_locf() (R/vendor_imputets.R).
 */
#include "simlev_capi.h"


static SEXP imputets_locf(sl::NumVec x, bool reverse)
{

  sl::NumVec z = sl::clone(x);

  long n = z.size();

  if (!reverse) {
    for(long i = 0; i < n; i++ ) {

      if (i % 1024 == 0) {sl::check_interrupt();}


      if(i > 0 && !R_finite(z[i]) && R_finite(z[i-1]))
      {
        z[i] = z[i-1];
      }
    }
  }
  else {
    for(long i = n-1; i >= 0; i-- ) {

      if (i % 1024 == 0) {sl::check_interrupt();}


      if(i < n-1 && !R_finite(z[i]) && R_finite(z[i+1]))
      {
        z[i] = z[i+1];
      }
    }

  }
return z.sexp;

}

// .Call-Huelle (registriert in init.c; R-Seite .imputets_locf in R/cores.R)
extern "C" SEXP C_imputets_locf(SEXP s_x, SEXP s_reverse) {
  return sl::call([&]() {
    sl::NumVec x = sl::num_vec(s_x);
    bool reverse = sl::as_bool(s_reverse);
    return imputets_locf(x, reverse);
  });
}

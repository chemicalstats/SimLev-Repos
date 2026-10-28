/*
 * vendor_imputets.cpp  --  .Call-Huelle fuer den uebernommenen C++-Code des R-Pakets imputeTS
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
 *     Rechnung des Funktionsrumpfs ist unveraendert. Sie steht seit Etappe 7.3a in
 *     src/vendor_imputets_impl.h (gemeinsam mit Python, Einzelheiten dort).
 *   - ma() aus imputeTS src/ma.cpp ist nicht uebernommen.
 * Gerufen von .imputets_na_locf() (R/vendor_imputets.R).
 */
#include "simlev_capi.h"
#include "vendor_imputets_impl.h"


// .Call-Huelle (registriert in init.c; R-Seite .imputets_locf in R/cores.R)
extern "C" SEXP C_imputets_locf(SEXP s_x, SEXP s_reverse) {
  return sl::call([&]() {
    sl::NumVec x = sl::num_vec(s_x);
    bool reverse = sl::as_bool(s_reverse);
    return simlev::imputets_locf(x, reverse);
  });
}

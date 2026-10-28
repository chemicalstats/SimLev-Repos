// src/dependence_core.cpp
// .Call-Huelle des Kerns fuer zeitvariable Korrelationen (DCC(1,1), Engle 2002).
//
// Die Rechnung steht seit Etappe 7.3a in src/dependence_core_impl.h (ohne R-Bezug,
// Formeln siehe dort; gemeinsam mit Python: simlev._ext, Kopie in python/src/).
// Diese Datei wandelt nur die Argumente um (wie die fruehere Rcpp-Huelle) und ruft
// den Kern auf; die Sichten und Aufrufe des Kerns bindet simlev_capi.h an R
// (Abschnitt "R als Host der gemeinsamen Kerne").

#include "simlev_capi.h"
#include "dependence_core_impl.h"

// ===========================================================================
// .CALL-HUELLE (registriert in init.c; R-Seite in R/cores.R)
// ===========================================================================

extern "C" SEXP C_dcc_filter(SEXP s_Z, SEXP s_a, SEXP s_b, SEXP s_Qbar, SEXP s_keep) {
  return sl::call([&]() {
    sl::NumMat Z = sl::num_mat(s_Z);
    double a = sl::as_double(s_a);
    double b = sl::as_double(s_b);
    sl::NumMat Qbar = sl::num_mat(s_Qbar);
    bool keep = sl::as_bool(s_keep);
    return simlev::dcc_filter(Z, a, b, Qbar, keep);
  });
}

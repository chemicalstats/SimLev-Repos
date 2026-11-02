// src/withdrawal_core.cpp
// .Call-Huelle der Entnahme-Simulation (.wd_simulate)
//
// Die Rechnung steht seit Etappe 7.3a in src/withdrawal_core_impl.h (ohne R-Bezug,
// Regeln, Zeitkonvention und Steuermodell siehe dort; gemeinsam mit Python:
// simlev._ext; kanonisch in core/, F16). Diese Datei wandelt nur die Argumente um
// (wie die fruehere Rcpp-Huelle) und ruft den Kern auf; die Sichten und Aufrufe des
// Kerns bindet simlev_capi.h an R (Abschnitt "R als Host der gemeinsamen Kerne").

#include "simlev_capi.h"
#include "withdrawal_core_impl.h"

// ---------------------------------------------------------------------------
// .Call-Huelle (registriert in init.c; R-Seite mit den Standardwerten in R/cores.R)
// ---------------------------------------------------------------------------

extern "C" SEXP C_wd_simulate(SEXP s_R, SEXP s_INF, SEXP s_CAPE, SEXP s_BASE, SEXP s_ppy, SEXP s_rule,
                              SEXP s_rp, SEXP s_start_timing, SEXP s_start_value, SEXP s_income_real,
                              SEXP s_tax_on, SEXP s_tax_rate, SEXP s_tfs, SEXP s_spb_annual, SEXP s_vp_on,
                              SEXP s_cost, SEXP s_basis_ratio, SEXP s_loss0, SEXP s_keep, SEXP s_lot_n,
                              SEXP s_lot_basis, SEXP s_lot_vp, SEXP s_lot_group, SEXP s_spb_first,
                              SEXP s_horizon_end, SEXP s_tariff_par, SEXP s_zve) {
  return sl::call([&]() {
    sl::NumMat R = sl::num_mat(s_R);
    sl::NumMat INF = sl::num_mat(s_INF);
    sl::NumMat CAPE = sl::num_mat(s_CAPE);
    sl::NumMat BASE = sl::num_mat(s_BASE);
    int ppy = sl::as_int(s_ppy);
    int rule = sl::as_int(s_rule);
    sl::NumVec rp = sl::num_vec(s_rp);
    bool start_timing = sl::as_bool(s_start_timing);
    double start_value = sl::as_double(s_start_value);
    sl::NumVec income_real = sl::num_vec(s_income_real);
    bool tax_on = sl::as_bool(s_tax_on);
    double tax_rate = sl::as_double(s_tax_rate);
    double tfs = sl::as_double(s_tfs);
    double spb_annual = sl::as_double(s_spb_annual);
    bool vp_on = sl::as_bool(s_vp_on);
    double cost = sl::as_double(s_cost);
    double basis_ratio = sl::as_double(s_basis_ratio);
    double loss0 = sl::as_double(s_loss0);
    bool keep = sl::as_bool(s_keep);
    sl::NumVec lot_n = sl::num_vec(s_lot_n);
    sl::NumVec lot_basis = sl::num_vec(s_lot_basis);
    sl::NumVec lot_vp = sl::num_vec(s_lot_vp);
    sl::IntVec lot_group = sl::int_vec(s_lot_group);
    double spb_first = sl::as_double(s_spb_first);
    bool horizon_end = sl::as_bool(s_horizon_end);
    sl::NumVec tariff_par = sl::num_vec(s_tariff_par);
    sl::NumVec zve = sl::num_vec(s_zve);
    return simlev::wd_simulate(R, INF, CAPE, BASE, ppy, rule, rp, start_timing, start_value, income_real,
                               tax_on, tax_rate, tfs, spb_annual, vp_on, cost, basis_ratio, loss0, keep,
                               lot_n, lot_basis, lot_vp, lot_group, spb_first, horizon_end, tariff_par, zve);
  });
}

// T14: Pruefzugang zum Tarifkern (tariff_core_impl.h) fuer den Zufallsvergleich mit den R-Funktionen
// (tools/gleichlauf/tariff_fuzz.R ueber .wd_tariff_check): mode 1 = ESt T(x) je x, 2 = Soli S(E) je x,
// 3 = Jahresabschluss je Zeile von x (Matrix n x 5: zvE, ks_prev, g23, k_base, abg_rate) -> Matrix n x 25
// (Spalten der Jahreszeile, Jahr NA; ohne zvE alle NA).
extern "C" SEXP C_wd_tariff_check(SEXP s_par, SEXP s_x, SEXP s_mode) {
  return sl::call([&]() {
    sl::NumVec par = sl::num_vec(s_par);
    int mode = sl::as_int(s_mode);
    simlev::TariffCore TC;
    if (!TC.init(par) || !TC.on) SIMLEV_FAIL("Tarifparameter: falsche L\u00e4nge (%d)", (int) par.size());
    if (mode == 1 || mode == 2) {
      sl::NumVec x = sl::num_vec(s_x);
      auto out = SIMLEV_NUM(x.size());
      for (int i = 0; i < (int) x.size(); i++) out[i] = mode == 1 ? TC.income_tax(x[i]) : TC.soli(x[i]);
      return SIMLEV_DONE(out);
    }
    sl::NumMat X = sl::num_mat(s_x);
    if (mode != 3 || X.ncol() != 5) SIMLEV_FAIL("mode 3 braucht eine Matrix mit 5 Spalten");
    const int n = X.nrow();
    auto out = SIMLEV_MATRIX(n, (int) simlev::TR_N);
    double row[simlev::TR_N];
    for (int i = 0; i < n; i++) {
      double ks = 0.0;
      double D = TC.close(X(i, 0), X(i, 1), X(i, 2), X(i, 3), X(i, 4), SIMLEV_NA, row, ks);
      row[simlev::TR_YEAR] = SIMLEV_NA;
      for (int c = 0; c < (int) simlev::TR_N; c++) out(i, c) = std::isnan(D) ? SIMLEV_NA : row[c];
    }
    return SIMLEV_DONE(out);
  });
}

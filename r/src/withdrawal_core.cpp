// src/withdrawal_core.cpp
// .Call-Huelle der Entnahme-Simulation (.wd_simulate) und der Auswertung je Pfad (seit 1.5.0: .wd_metrics,
// .wd_pwr, .wd_annual_prod, .wd_tariff_compact)
//
// Die Rechnung steht in src/withdrawal_core_impl.h (ohne R-Bezug,
// Regeln, Zeitkonvention und Steuermodell siehe dort; gemeinsam mit Python und
// Julia; kanonisch in core/). Diese Datei wandelt nur die Argumente um
// (wie die fruehere Rcpp-Huelle) und ruft den Kern auf; die Sichten und Aufrufe des
// Kerns bindet simlev_capi.h an R (Abschnitt "R als Host der gemeinsamen Kerne").

#include "simlev_capi.h"
#include "withdrawal_core_impl.h"

// ---------------------------------------------------------------------------
// .Call-Huelle (registriert in init.cpp; R-Seite mit den Standardwerten in R/cores.R)
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

// Pruefzugang zum Tarifkern (tariff_core_impl.h) fuer den Zufallsvergleich mit den R-Funktionen
// (Gleichlauf: tariff_fuzz.R ueber .wd_tariff_check): mode 1 = ESt T(x) je x, 2 = Soli S(E) je x,
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

// ---------------------------------------------------------------------------
// Auswertung je Pfad (seit 1.5.0; Kerne wd_metrics, wd_pwr, wd_annual_prod, wd_tariff_compact)
// ---------------------------------------------------------------------------

namespace {
// Horizont je Pfad (ganze Zahlen 0..ny) oder NULL
const int* horizon_arg(SEXP s_H, int ny, int np, const char* fn) {
  if (Rf_isNull(s_H)) return nullptr;
  sl::IntVec H = sl::int_vec(s_H);
  if (H.size() != np) sl::stop("%s: Horizont hat %d statt %d Werte", fn, (int) H.size(), np);
  for (int i = 0; i < np; i++)
    if (H[i] == NA_INTEGER || H[i] < 0 || H[i] > ny) sl::stop("%s: Horizont %d ausserhalb 0..%d", fn, H[i], ny);
  return H.ptr;
}
}  // namespace

// Kennzahlen der Entnahmen je Pfad: sp (ny x np), nfy, H (NULL oder je Pfad), gamma, start_value
// -> list(mean_spending, min_spending, spending_drawdown, ce_spending, total_spending)
extern "C" SEXP C_wd_metrics(SEXP s_sp, SEXP s_nfy, SEXP s_H, SEXP s_gamma, SEXP s_sv) {
  return sl::call([&]() {
    sl::NumMat sp = sl::num_mat(s_sp);
    const int ny = sp.nrow(), np = sp.ncol();
    const int nfy = sl::as_int(s_nfy);
    if (nfy < 0 || nfy > ny) sl::stop("wd_metrics: nfy ausserhalb 0..%d", ny);
    const int* H = horizon_arg(s_H, ny, np, "wd_metrics");
    sl::NumVec mean = sl::new_num(np), mn = sl::new_num(np), dd = sl::new_num(np), ce = sl::new_num(np),
               total = sl::new_num(np);
    std::vector<double> tmp(2 * (std::size_t) ny + 1);
    simlev::wd_metrics(ny, np, sp.ptr, nfy, H, sl::as_double(s_gamma), sl::as_double(s_sv), mean.ptr, mn.ptr, dd.ptr,
                       ce.ptr, total.ptr, tmp.data());
    return sl::named_list("mean_spending", mean, "min_spending", mn, "spending_drawdown", dd, "ce_spending", ce,
                          "total_spending", total);
  });
}

// Perfect Withdrawal Rate je Pfad: AR (Jahre x Pfade), legacy, H (NULL oder je Pfad)
// -> list(pwr, status, path) (status wie simlev::wd_pwr_check; dann pwr unvollstaendig)
extern "C" SEXP C_wd_pwr(SEXP s_AR, SEXP s_legacy, SEXP s_H) {
  return sl::call([&]() {
    sl::NumMat AR = sl::num_mat(s_AR);
    const int ny = AR.nrow(), np = AR.ncol();
    const int* H = horizon_arg(s_H, ny, np, "wd_pwr");
    sl::NumVec out = sl::new_num(np);
    std::vector<double> w(std::max((std::size_t) ny * (std::size_t) np, 2 * (std::size_t) ny) + 1);
    int64_t path = 0;
    const int st = simlev::wd_pwr(ny, np, AR.ptr, sl::as_double(s_legacy), H, out.ptr, &path, w.data());
    return sl::named_list("pwr", out, "status", st, "path", (int) path);
  });
}

// Produkt je Block von ppy Zeilen: real (nr x nc) -> Matrix (nr %/% ppy) x nc
extern "C" SEXP C_wd_annual_prod(SEXP s_real, SEXP s_ppy) {
  return sl::call([&]() {
    sl::NumMat real = sl::num_mat(s_real);
    const int ppy = sl::as_int(s_ppy);
    if (ppy < 1) sl::stop("wd_annual_prod: ppy muss >= 1 sein");
    sl::NumMat out = sl::new_mat(real.nrow() / ppy, real.ncol());
    simlev::wd_annual_prod(real.nrow(), real.ncol(), real.ptr, ppy, out.ptr);
    return out.sexp;
  });
}

// Jahreszeilen des Tarifwegs: M (TR_N x N aus .wd_simulate), ny -> Matrix nkeep x (TR_N + 1) (Pfad, Zeilen von M)
extern "C" SEXP C_wd_tariff_compact(SEXP s_M, SEXP s_ny) {
  return sl::call([&]() {
    sl::NumMat M = sl::num_mat(s_M);
    if (M.nrow() != (int) simlev::TR_N) sl::stop("wd_tariff_compact: %d statt %d Zeilen", M.nrow(), (int) simlev::TR_N);
    if (sl::as_int(s_ny) < 0) sl::stop("wd_tariff_compact: Abmessungen passen nicht");   // seit 1.6.5 (CR1-Y9-1)
    const int64_t n = simlev::wd_tariff_count(M.ncol(), M.ptr);
    sl::NumMat out = sl::new_mat((int) n, (int) simlev::TR_N + 1);
    simlev::wd_tariff_compact(M.ncol(), M.ptr, sl::as_int(s_ny), n, out.ptr);
    return out.sexp;
  });
}

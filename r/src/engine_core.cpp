// src/engine_core.cpp
// .Call-Huelle der Tagesengine (Kern src/engine_core_impl.h; R-Seite R/sim_engine.R)
//
// Die Huelle liest die flache Eingabe des Kerns (struct Input) und die Angaben der Vorbereitung
// (prepare_core_impl.h: PrepFlat) aus einer benannten Liste (Aufbau in .sim_engine_run), laesst den Kern
// vorbereiten und rechnen und gibt die Tagesflags (Freibetragstage), Status, Report-Vektoren, Lots, Verkaeufe,
// Steuerbuchungen, geaenderte Kursreihen (Splits), Toepfe, Gebuehren, offene Steuer, Jahreszeilen und
// KiSt-Salden des Tarifwegs, das Ereignisprotokoll und einen etwaigen Abbruch als Liste zurueck. Lots,
// Verkaeufe und Steuerbuchungen entstehen als Listen in derselben Form wie bisher in sim_mem
// (perform_trade_buy_cpp, .perform_trade_sell, .pay_vp, .settle_p23, .sim_day_assess_vp). Die Texte der
// Warnungen und Fehler setzt R (.sim_engine_signal).
//
// C_sim_evaluate rechnet die Auswertung (Kern src/evaluate_core_impl.h; R-Seite .sim_evaluate in
// R/sim_evaluate.R), C_sim_xirr den internen Zinsfuss (.xirr_rate in R/sim_base.R).

#include "simlev_capi.h"
#include "engine_core_impl.h"
#include "evaluate_core_impl.h"

#include <vector>

namespace {

SEXP el(SEXP list, const char* name) {
  const R_xlen_t i = sl::find(list, name);
  if (i < 0) sl::stop("sim_engine_run: Eingabe '%s' fehlt", name);
  return VECTOR_ELT(list, i);
}
const double* real_of(SEXP list, const char* name, R_xlen_t len) {
  SEXP x = el(list, name);
  if (TYPEOF(x) != REALSXP || (len >= 0 && Rf_xlength(x) != len))
    sl::stop("sim_engine_run: Eingabe '%s' passt nicht", name);
  return REAL(x);
}
const int* int_of(SEXP list, const char* name, R_xlen_t len) {
  SEXP x = el(list, name);
  if (TYPEOF(x) != INTSXP || (len >= 0 && Rf_xlength(x) != len))
    sl::stop("sim_engine_run: Eingabe '%s' passt nicht", name);
  return INTEGER(x);
}

// Signal als double (logisch: 0/1, NA = NA_real_); Puffer, falls die Spalte nicht double ist
const double* signal(SEXP x, R_xlen_t n, std::vector<double>& store, int& logical) {
  logical = TYPEOF(x) == LGLSXP;
  if (Rf_xlength(x) != n) sl::stop("sim_engine_run: Signal hat %ld statt %ld Werte", (long) Rf_xlength(x), (long) n);
  if (TYPEOF(x) == REALSXP) return REAL(x);
  if (TYPEOF(x) != LGLSXP && TYPEOF(x) != INTSXP) sl::stop("sim_engine_run: Signal muss logisch oder numerisch sein");
  const int* p = TYPEOF(x) == LGLSXP ? LOGICAL(x) : INTEGER(x);
  store.resize((std::size_t) n);
  for (R_xlen_t i = 0; i < n; i++) store[i] = p[i] == NA_INTEGER ? NA_REAL : (double) p[i];
  return store.data();
}

SEXP names_of(std::initializer_list<const char*> nm) {
  SEXP x = sl::alloc(STRSXP, (R_xlen_t) nm.size());
  R_xlen_t i = 0;
  for (const char* s : nm) SET_STRING_ELT(x, i++, Rf_mkChar(s));
  return x;
}
SEXP date_scalar(double d, SEXP date_class) {
  SEXP x = sl::alloc(REALSXP, 1);
  REAL(x)[0] = d;
  Rf_setAttrib(x, R_ClassSymbol, date_class);
  return x;
}
SEXP num_scalar(double v) {
  SEXP x = sl::alloc(REALSXP, 1);
  REAL(x)[0] = v;
  return x;
}
SEXP lgl_scalar(int v) {
  SEXP x = sl::alloc(LGLSXP, 1);
  LOGICAL(x)[0] = v;
  return x;
}
SEXP num_vec(const std::vector<double>& v) {
  SEXP x = sl::alloc(REALSXP, (R_xlen_t) v.size());
  for (std::size_t i = 0; i < v.size(); i++) REAL(x)[i] = v[i];
  return x;
}
SEXP int_vec(const std::vector<int>& v) {
  SEXP x = sl::alloc(INTSXP, (R_xlen_t) v.size());
  for (std::size_t i = 0; i < v.size(); i++) INTEGER(x)[i] = v[i];
  return x;
}

// Tage eines Plans (days, dcode); NULL = ohne days
void sched_days(SEXP inp, const char* dn, const char* cn, int64_t& nd, const double*& days, const int32_t*& dcode) {
  SEXP d = el(inp, dn);
  if (Rf_isNull(d)) { nd = 0; days = nullptr; dcode = nullptr; return; }
  nd = Rf_xlength(d);
  days = real_of(inp, dn, nd);
  dcode = int_of(inp, cn, nd);
}

}  // namespace

// calculate_dates_flags() (R/sim_base.R) ueber den Kern: inp = list(dates, si, start, days, dcode, liquidate)
extern "C" SEXP C_sim_dates_flags(SEXP inp) {
  return sl::call([&]() {
    SEXP d = el(inp, "dates");
    if (TYPEOF(d) != REALSXP) sl::stop("sim_dates_flags: dates passt nicht");
    const R_xlen_t n = Rf_xlength(d);
    int64_t nd;
    const double* days;
    const int32_t* dcode;
    sched_days(inp, "days", "dcode", nd, days, dcode);
    const simlev_prepare::Sched S = simlev_prepare::sched_of(int_of(inp, "si", simlev_prepare::SI_N),
                                                             sl::as_double(el(inp, "start")), nd, days, dcode);
    std::vector<int32_t> out((std::size_t) n);
    simlev_prepare::dates_flags(n, REAL(d), S, sl::as_int(el(inp, "liquidate")), out.data());
    SEXP x = sl::alloc(LGLSXP, n);
    for (R_xlen_t i = 0; i < n; i++) LOGICAL(x)[i] = out[i];
    return x;
  });
}

extern "C" SEXP C_sim_engine_run(SEXP inp) {
  return sl::call([&]() {
    using namespace simlev_engine;
    const int n = sl::as_int(el(inp, "n"));
    SEXP prices = el(inp, "price"), sb = el(inp, "sig_buy"), ss = el(inp, "sig_sell"), ew = el(inp, "event_w"),
         br = el(inp, "base_rates");
    const int na = (int) Rf_xlength(prices);
    if (n < 1 || na < 1 || Rf_xlength(sb) != na || Rf_xlength(ss) != na || (!Rf_isNull(ew) && Rf_xlength(ew) != na) ||
        (!Rf_isNull(br) && Rf_xlength(br) != na))
      sl::stop("sim_engine_run: Asset-Listen passen nicht");
    Input I;
    I.n = n;
    I.na = na;
    I.day = real_of(inp, "day", n);
    std::vector<const double*> p_price((std::size_t) na), p_sb((std::size_t) na), p_ss((std::size_t) na),
        p_ew((std::size_t) na, nullptr), p_br((std::size_t) na, nullptr);
    std::vector<std::vector<double>> store((std::size_t) (2 * na));
    std::vector<int> ai(AI_N * (std::size_t) na);
    const int* ai_in = int_of(inp, "ai", AI_N * (R_xlen_t) na);
    for (std::size_t k = 0; k < ai.size(); k++) ai[k] = ai_in[k];
    for (int a = 0; a < na; a++) {
      SEXP p = VECTOR_ELT(prices, a);
      if (TYPEOF(p) != REALSXP || Rf_xlength(p) != n) sl::stop("sim_engine_run: Kursreihe %d passt nicht", a + 1);
      p_price[a] = REAL(p);
      p_sb[a] = signal(VECTOR_ELT(sb, a), n, store[2 * a], ai[AI_N * a + AI_BUY_LGL]);
      p_ss[a] = signal(VECTOR_ELT(ss, a), n, store[2 * a + 1], ai[AI_N * a + AI_SELL_LGL]);
      if (!Rf_isNull(ew)) {
        SEXP w = VECTOR_ELT(ew, a);
        if (!Rf_isNull(w)) {
          if (TYPEOF(w) != REALSXP || Rf_xlength(w) != n) sl::stop("sim_engine_run: event_weight-Spalte passt nicht");
          p_ew[a] = REAL(w);
        }
      }
      if (!Rf_isNull(br)) {
        SEXP w = VECTOR_ELT(br, a);
        if (!Rf_isNull(w)) {
          if (TYPEOF(w) != REALSXP || Rf_xlength(w) != n) sl::stop("sim_engine_run: Basiszins-Reihe passt nicht");
          p_br[a] = REAL(w);
        }
      }
    }
    I.price = p_price.data();
    I.sig_buy = p_sb.data();
    I.sig_sell = p_ss.data();
    I.event_w = Rf_isNull(ew) ? nullptr : p_ew.data();
    I.base_rates = Rf_isNull(br) ? nullptr : p_br.data();
    I.ai = ai.data();
    I.ad = real_of(inp, "ad", AD_N * (R_xlen_t) na);
    I.ci = int_of(inp, "ci", CI_N);
    I.cd = real_of(inp, "cd", CD_N);
    I.fees = real_of(inp, "fees", 10);
    I.tot0 = real_of(inp, "tot0", TT_N);
    SEXP tp = el(inp, "tariff_par"), zv = el(inp, "zve");
    if (TYPEOF(tp) != REALSXP || TYPEOF(zv) != REALSXP || Rf_xlength(zv) % 2 != 0)
      sl::stop("sim_engine_run: Tarifangaben passen nicht");
    I.tariff_par = REAL(tp);
    I.n_tariff_par = Rf_xlength(tp);
    I.zve = REAL(zv);
    I.n_zve = Rf_xlength(zv) / 2;
    // Report-Vektoren: R-Vektoren, die der Kern direkt beschreibt (Tag 1 setzt die Vorbereitung)
    SEXP rep_names = names_of({"worth", "money", "flows", "total", "share"});
    SEXP report = sl::alloc(VECSXP, na);
    std::vector<double*> reps(5 * (std::size_t) na);
    for (int a = 0; a < na; a++) {
      SEXP r = sl::alloc(VECSXP, 5);
      for (int k = 0; k < 5; k++) {
        SEXP x = sl::alloc(REALSXP, n);
        double* v = REAL(x);
        for (int i = 0; i < n; i++) v[i] = 0.0;
        reps[5 * a + k] = v;
        SET_VECTOR_ELT(r, k, x);
      }
      Rf_setAttrib(r, R_NamesSymbol, rep_names);
      SET_VECTOR_ELT(report, a, r);
    }
    I.reports = reps.data();
    // Vorbereitung (prepare_core_impl.h): Termine, Tagesflags, Startgewichte
    simlev_prepare::PrepFlat F;
    F.pi = int_of(inp, "pi", simlev_prepare::PI_N);
    F.pd = real_of(inp, "pd", simlev_prepare::PD_N);
    F.start = real_of(inp, "start", na);
    SEXP fi = el(inp, "filled"), evc = el(inp, "event");
    if (!Rf_isNull(fi)) F.filled = int_of(inp, "filled", n);
    if (!Rf_isNull(evc)) F.event = int_of(inp, "event", n);
    sched_days(inp, "d_days", "d_dcode", F.d_nd, F.d_days, F.d_dcode);
    sched_days(inp, "b_days", "b_dcode", F.b_nd, F.b_days, F.b_dcode);
    Engine E;
    const int bad = E.setup_prepared(I, F);
    if (bad) sl::stop("sim_engine_run: Eingabe passt nicht (%d)", bad);
    const int rc = E.run();
    // Ergebnis
    std::vector<double> buf(8 * (std::size_t) na);
    E.status_out(buf.data());
    SEXP status = num_vec(buf);
    buf.assign(TT_N, 0.0);
    E.totals_out(buf.data());
    SEXP totals = num_vec(buf);
    SEXP date_class = Rf_mkString("Date");
    sl::keep(date_class);
    SEXP lot_names = sl::keep(names_of({"date", "type", "count", "price", "remaining", "original"}));
    SEXP lot_names_vp = sl::keep(names_of({"date", "type", "count", "price", "remaining", "original", "vp"}));
    SEXP sell_names = sl::keep(names_of({"event_date", "event_type", "asset_count", "asset_price", "event_gain",
                                         "event_taxes", "tax_regime", "tax_deferred", "holding_exempt"}));
    SEXP vp_names = sl::keep(names_of({"event_date", "assessment_date", "event_type", "flat_rate_gross", "bonus_applied",
                                       "flat_rate_taxable", "spb_used", "taxes_paid"}));
    SEXP p23_names = sl::keep(names_of({"event_date", "event_type", "taxes_paid"}));
    SEXP buy_s = sl::keep(Rf_mkString("Buy")), sell_s = sl::keep(Rf_mkString("Sell"));
    SEXP vp_s = sl::keep(Rf_mkString("Vorabpauschale")), p23_s = sl::keep(Rf_mkString("Private sale tax"));
    SEXP regime_s[4] = {R_NilValue, sl::keep(Rf_mkString("investment_fund")), sl::keep(Rf_mkString("capital_gains")),
                        sl::keep(Rf_mkString("private_sale"))};
    SEXP buys = sl::alloc(VECSXP, na), sells = sl::alloc(VECSXP, na), taxes = sl::alloc(VECSXP, na),
         px_out = sl::alloc(VECSXP, na);
    for (int a = 0; a < na; a++) {
      const std::size_t nl = E.buys[a].size();
      buf.assign(7 * nl, 0.0);
      E.lots_out(a, buf.data());
      SEXP bl = sl::alloc(VECSXP, (R_xlen_t) nl);
      for (std::size_t j = 0; j < nl; j++) {
        const double* L = buf.data() + 7 * j;
        const bool vp = L[6] != 0;
        SEXP lot = sl::alloc(VECSXP, vp ? 7 : 6);
        SET_VECTOR_ELT(lot, 0, date_scalar(L[0], date_class));
        SET_VECTOR_ELT(lot, 1, buy_s);
        for (int k = 1; k <= 4; k++) SET_VECTOR_ELT(lot, k + 1, num_scalar(L[k]));
        if (vp) SET_VECTOR_ELT(lot, 6, num_scalar(L[5]));
        Rf_setAttrib(lot, R_NamesSymbol, vp ? lot_names_vp : lot_names);
        SET_VECTOR_ELT(bl, (R_xlen_t) j, lot);
      }
      SET_VECTOR_ELT(buys, a, bl);
      const std::size_t ns = E.sells[a].size();
      buf.assign(8 * ns, 0.0);
      E.sells_out(a, buf.data());
      SEXP sv = sl::alloc(VECSXP, (R_xlen_t) ns);
      for (std::size_t j = 0; j < ns; j++) {
        const double* S = buf.data() + 8 * j;
        const int rg = (int) S[5];
        SEXP e = sl::alloc(VECSXP, 9);
        SET_VECTOR_ELT(e, 0, date_scalar(S[0], date_class));
        SET_VECTOR_ELT(e, 1, sell_s);
        SET_VECTOR_ELT(e, 2, num_scalar(S[1]));
        SET_VECTOR_ELT(e, 3, num_scalar(S[2]));
        SET_VECTOR_ELT(e, 4, rg ? num_scalar(S[3]) : lgl_scalar(NA_LOGICAL));
        SET_VECTOR_ELT(e, 5, rg ? num_scalar(S[4]) : lgl_scalar(NA_LOGICAL));
        SET_VECTOR_ELT(e, 6, rg ? regime_s[rg] : lgl_scalar(NA_LOGICAL));
        SET_VECTOR_ELT(e, 7, lgl_scalar(rg == RG_PS ? 1 : 0));
        SET_VECTOR_ELT(e, 8, S[7] != 0 ? num_scalar(S[6]) : lgl_scalar(NA_LOGICAL));
        Rf_setAttrib(e, R_NamesSymbol, sell_names);
        SET_VECTOR_ELT(sv, (R_xlen_t) j, e);
      }
      SET_VECTOR_ELT(sells, a, sv);
      const std::size_t nt = E.taxes[a].size();
      buf.assign(8 * nt, 0.0);
      E.taxes_out(a, buf.data());
      SEXP tv = sl::alloc(VECSXP, (R_xlen_t) nt);
      for (std::size_t j = 0; j < nt; j++) {
        const double* X = buf.data() + 8 * j;
        SEXP e;
        if ((int) X[0] == 1) {
          e = sl::alloc(VECSXP, 8);
          SET_VECTOR_ELT(e, 0, date_scalar(X[1], date_class));
          SET_VECTOR_ELT(e, 1, date_scalar(X[2], date_class));
          SET_VECTOR_ELT(e, 2, vp_s);
          for (int k = 3; k < 8; k++) SET_VECTOR_ELT(e, k, num_scalar(X[k]));
          Rf_setAttrib(e, R_NamesSymbol, vp_names);
        } else {
          e = sl::alloc(VECSXP, 3);
          SET_VECTOR_ELT(e, 0, date_scalar(X[1], date_class));
          SET_VECTOR_ELT(e, 1, p23_s);
          SET_VECTOR_ELT(e, 2, num_scalar(X[7]));
          Rf_setAttrib(e, R_NamesSymbol, p23_names);
        }
        SET_VECTOR_ELT(tv, (R_xlen_t) j, e);
      }
      SET_VECTOR_ELT(taxes, a, tv);
      if (E.px_changed[a]) SET_VECTOR_ELT(px_out, a, num_vec(E.px[a]));
    }
    const R_xlen_t ne = (R_xlen_t) E.events.size();
    std::vector<int32_t> evi(9 * (std::size_t) ne);
    std::vector<double> evd(2 * (std::size_t) ne);
    E.events_out(evi.data(), evd.data());
    SEXP ev = sl::alloc(VECSXP, 11);
    for (int k = 0; k < 9; k++) {
      SEXP x = sl::alloc(INTSXP, ne);
      for (R_xlen_t i = 0; i < ne; i++) INTEGER(x)[i] = evi[9 * i + k] + (k == 3 ? 1 : 0);   // Asset 1-basiert
      SET_VECTOR_ELT(ev, k, x);
    }
    for (int k = 0; k < 2; k++) {
      SEXP x = sl::alloc(REALSXP, ne);
      for (R_xlen_t i = 0; i < ne; i++) REAL(x)[i] = evd[2 * i + k];
      SET_VECTOR_ELT(ev, 9 + k, x);
    }
    Rf_setAttrib(ev, R_NamesSymbol, names_of({"code", "site", "day", "asset", "aux", "y_off", "ny", "v_off", "nv",
                                              "d0", "d1"}));
    SEXP err = R_NilValue;
    if (rc != 0) {
      err = sl::alloc(VECSXP, 5);
      SET_VECTOR_ELT(err, 0, int_vec({E.err.site}));
      SET_VECTOR_ELT(err, 1, int_vec({E.err.day}));
      SET_VECTOR_ELT(err, 2, int_vec({E.err.asset + 1}));
      SET_VECTOR_ELT(err, 3, int_vec({E.err.code}));
      SET_VECTOR_ELT(err, 4, num_scalar(E.err.d0));
      Rf_setAttrib(err, R_NamesSymbol, names_of({"site", "day", "asset", "code", "d0"}));
    }
    buf.assign(simlev::TR_N * E.rows.size(), 0.0);
    E.rows_out(buf.data());
    SEXP rows = num_vec(buf);
    buf.assign(2 * E.ks.size(), 0.0);
    E.ks_out(buf.data());
    SEXP ks = num_vec(buf);
    SEXP res = sl::alloc(VECSXP, 17);
    SET_VECTOR_ELT(res, 0, status);
    SET_VECTOR_ELT(res, 1, report);
    SET_VECTOR_ELT(res, 2, buys);
    SET_VECTOR_ELT(res, 3, sells);
    SET_VECTOR_ELT(res, 4, taxes);
    SET_VECTOR_ELT(res, 5, px_out);
    SET_VECTOR_ELT(res, 6, totals);
    SET_VECTOR_ELT(res, 7, num_scalar(E.fee_paid));
    SET_VECTOR_ELT(res, 8, num_scalar(E.tax_unpaid));
    SET_VECTOR_ELT(res, 9, rows);
    SET_VECTOR_ELT(res, 10, ks);
    SET_VECTOR_ELT(res, 11, num_scalar(E.refund_due));
    SET_VECTOR_ELT(res, 12, ev);
    SET_VECTOR_ELT(res, 13, int_vec(E.ev_ints));
    SET_VECTOR_ELT(res, 14, num_vec(E.ev_vals));
    SET_VECTOR_ELT(res, 15, err);
    SET_VECTOR_ELT(res, 16, int_vec(std::vector<int>(E.prep_flags.begin(), E.prep_flags.end())));
    Rf_setAttrib(res, R_NamesSymbol, names_of({"status", "report", "buys", "sells", "taxes", "prices", "totals",
                                              "fee_paid", "tax_unpaid", "rows", "ks", "refund_due", "events",
                                              "ev_ints", "ev_vals", "error", "flags"}));
    return res;
  });
}

namespace {
// je Asset eine Zahlenreihe der Laenge n aus einer Liste
std::vector<const double*> series(SEXP inp, const char* name, R_xlen_t n, R_xlen_t na) {
  SEXP x = el(inp, name);
  if (TYPEOF(x) != VECSXP || Rf_xlength(x) != na) sl::stop("sim_evaluate: Eingabe '%s' passt nicht", name);
  std::vector<const double*> p((std::size_t) na);
  for (R_xlen_t a = 0; a < na; a++) {
    SEXP v = VECTOR_ELT(x, a);
    if (TYPEOF(v) != REALSXP || Rf_xlength(v) != n) sl::stop("sim_evaluate: Reihe '%s' %d passt nicht", name, (int) a + 1);
    p[(std::size_t) a] = REAL(v);
  }
  return p;
}
SEXP msgs_out(const std::vector<simlev_eval::Msg>& m, SEXP& vals) {
  SEXP codes = sl::alloc(INTSXP, (R_xlen_t) m.size());
  vals = sl::alloc(REALSXP, 4 * (R_xlen_t) m.size());
  for (std::size_t i = 0; i < m.size(); i++) {
    INTEGER(codes)[i] = m[i].code;
    for (int k = 0; k < 4; k++) REAL(vals)[4 * i + k] = m[i].v[k];
  }
  return codes;
}
}  // namespace

// Auswertung von simulation(): inp = list(n, total, flows, worth, money, price (je Asset Reihen),
// day, filled (0/1 oder NULL), sc = c(start_date, stopp_date, start_value, tax_unpaid), status_money, n_buys,
// n_sells (je Asset), rf (Zahlen oder NULL), rf_ok)
extern "C" SEXP C_sim_evaluate(SEXP inp) {
  return sl::call([&]() {
    using namespace simlev_eval;
    const R_xlen_t n = sl::as_int(el(inp, "n"));
    const R_xlen_t na = Rf_xlength(el(inp, "total"));
    if (n < 1 || na < 1) sl::stop("sim_evaluate: Eingabe passt nicht");
    const std::vector<const double*> total = series(inp, "total", n, na), flows = series(inp, "flows", n, na),
                                     worth = series(inp, "worth", n, na), money = series(inp, "money", n, na),
                                     price = series(inp, "price", n, na);
    In I;
    I.n = n; I.na = na;
    I.total = total.data(); I.flows = flows.data(); I.worth = worth.data(); I.money = money.data();
    I.price = price.data();
    I.day = real_of(inp, "day", n);
    if (!Rf_isNull(el(inp, "filled"))) I.filled = int_of(inp, "filled", n);
    const double* sc = real_of(inp, "sc", 4);
    I.start_date = sc[0]; I.stopp_date = sc[1]; I.start_value = sc[2]; I.tax_unpaid = sc[3];
    I.status_money = real_of(inp, "status_money", na);
    I.n_buys = real_of(inp, "n_buys", na);
    I.n_sells = real_of(inp, "n_sells", na);
    SEXP rf = el(inp, "rf");
    if (!Rf_isNull(rf)) {
      if (TYPEOF(rf) != REALSXP) sl::stop("sim_evaluate: rf passt nicht");
      I.rf = REAL(rf);
      I.n_rf = Rf_xlength(rf);
    }
    I.rf_ok = sl::as_int(el(inp, "rf_ok"));
    Result R;
    if (evaluate(I, R) == 2) sl::stop("sim_evaluate: Eingabe passt nicht");
    SEXP res = sl::alloc(VECSXP, 17);
    SET_VECTOR_ELT(res, 0, num_vec(R.total_worth));
    SET_VECTOR_ELT(res, 1, num_vec(R.twr_index));
    SET_VECTOR_ELT(res, 2, num_vec(R.invested));
    SET_VECTOR_ELT(res, 3, num_vec(R.drawdowns));
    SET_VECTOR_ELT(res, 4, num_vec({R.cagr, R.ttwror, R.open_tax_debt}));
    SET_VECTOR_ELT(res, 5, lgl_scalar(R.has_ext_flows));
    SET_VECTOR_ELT(res, 6, num_vec(std::vector<double>(R.stats, R.stats + ST_N)));
    SET_VECTOR_ELT(res, 7, int_vec({R.skew_lgl, R.kurt_lgl, R.longest_dd}));
    SET_VECTOR_ELT(res, 8, num_vec(R.buys));
    SET_VECTOR_ELT(res, 9, num_vec(R.sells));
    std::vector<int> wi;
    std::vector<double> wv;
    for (int k = 0; k < 2; k++) {
      const Row& w = R.why[k];
      wi.insert(wi.end(), {R.why_set[k], w.reason, w.detail});
      wv.insert(wv.end(), {w.v[0], w.v[1], w.v[2]});
    }
    SET_VECTOR_ELT(res, 10, int_vec(wi));
    SET_VECTOR_ELT(res, 11, num_vec(wv));
    std::vector<int> ui;
    std::vector<double> uv;
    for (const Row& u : R.um) {
      ui.insert(ui.end(), {u.metric, u.reason, u.detail});
      uv.insert(uv.end(), {u.v[0], u.v[1], u.v[2]});
    }
    SET_VECTOR_ELT(res, 12, int_vec(ui));
    SET_VECTOR_ELT(res, 13, num_vec(uv));
    SEXP mv;
    SET_VECTOR_ELT(res, 14, msgs_out(R.msgs, mv));
    SET_VECTOR_ELT(res, 15, mv);
    SET_VECTOR_ELT(res, 16, int_vec({R.err_site, R.err_phase}));
    Rf_setAttrib(res, R_NamesSymbol, names_of({"total_worth", "twr_index", "invested", "drawdowns", "scal", "has_ext",
                                              "stats", "ints", "buys", "sells", "why_i", "why_v", "um_i", "um_v",
                                              "msg_code", "msg_v", "err"}));
    return res;
  });
}

// .xirr_rate(t, amount, end_value, horizon) ueber den Kern: list(Wert, Warnungen von uniroot als Codes)
extern "C" SEXP C_sim_xirr(SEXP t, SEXP amount, SEXP end_value, SEXP horizon) {
  return sl::call([&]() {
    if (TYPEOF(t) != REALSXP || TYPEOF(amount) != REALSXP || Rf_xlength(t) != Rf_xlength(amount) ||
        TYPEOF(end_value) != REALSXP || Rf_xlength(end_value) != 1 || TYPEOF(horizon) != REALSXP ||
        Rf_xlength(horizon) != 1)
      sl::stop("sim_xirr: Eingabe passt nicht");
    std::vector<simlev_eval::Msg> m;
    const double v = simlev_eval::xirr(Rf_xlength(t), REAL(t), REAL(amount), REAL(end_value)[0], REAL(horizon)[0], &m);
    SEXP res = sl::alloc(VECSXP, 2);
    SET_VECTOR_ELT(res, 0, num_scalar(v));
    SEXP mv;
    SET_VECTOR_ELT(res, 1, msgs_out(m, mv));
    return res;
  });
}

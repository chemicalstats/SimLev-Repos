// src/engine_core.cpp
// .Call-Huelle der Tagesengine (Kern src/engine_core_impl.h; R-Seite R/sim_engine.R)
//
// Die Huelle liest die flache Eingabe des Kerns (struct Input) und die Angaben der Vorbereitung
// (prepare_core_impl.h: PrepFlat) aus einer benannten Liste (Aufbau in .sim_engine_run), laesst den Kern
// vorbereiten und rechnen und gibt die Tagesflags (Freibetragstage), Status, Report-Vektoren, geaenderte Kursreihen
// (Splits), Toepfe, Gebuehren, offene Steuer, Jahreszeilen und KiSt-Salden des Tarifwegs, das Ereignisprotokoll,
// einen etwaigen Abbruch, die Zahl der Kaeufe und Verkaeufe und die offenen Lots je Asset als Liste zurueck (seit
// 1.6.3 kompakt; bis 1.6.2 Lots, Verkaeufe und Steuerbuchungen als Listen je Objekt). Die Texte der Warnungen und
// Fehler setzt R (.sim_engine_signal).
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
  for (const char* s : nm) SET_STRING_ELT(x, i++, sl::mkchar(s));   // seit 1.6.4 unter rcall (K43 T1-B2)
  return x;
}
// Neue geschuetzte Zahlenvektoren ueber sl::num_copy (simlev_capi.h; seit 1.6.4 statt eigener Kopien;
// sl::wrap schuetzt nicht)
SEXP num_scalar(double v) { return sl::num_copy(&v, &v + 1).sexp; }
SEXP num_vec(const std::vector<double>& v) { return sl::num_copy(v.begin(), v.end()).sexp; }
SEXP lgl_scalar(int v) {
  SEXP x = sl::alloc(LGLSXP, 1);
  LOGICAL(x)[0] = v;
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

namespace {

// Eingabe der Tagesengine aus der Liste inp (Aufbau in .sim_engine_input, R/sim_engine.R) mit den Puffern, auf die
// Input und PrepFlat zeigen; report: die R-Vektoren, die der Kern beschreibt (seit 1.6.5 eigene Hilfe, gemeinsam fuer
// C_sim_engine_run und C_sim_run_prepared)
struct EngineIn {
  simlev_engine::Input I;
  simlev_prepare::PrepFlat F;
  std::vector<const double*> p_price, p_sb, p_ss, p_ew, p_br;
  std::vector<std::vector<double>> store;
  std::vector<int> ai;
  std::vector<double*> reps;
  SEXP report = R_NilValue;
  int n = 0, na = 0;
};

void engine_in(SEXP inp, EngineIn& X) {
    using namespace simlev_engine;
    const int n = sl::as_int(el(inp, "n"));
    X.n = n;
    SEXP prices = el(inp, "price"), sb = el(inp, "sig_buy"), ss = el(inp, "sig_sell"), ew = el(inp, "event_w"),
         br = el(inp, "base_rates");
    const int na = (int) Rf_xlength(prices);
    X.na = na;
    if (n < 1 || na < 1 || Rf_xlength(sb) != na || Rf_xlength(ss) != na || (!Rf_isNull(ew) && Rf_xlength(ew) != na) ||
        (!Rf_isNull(br) && Rf_xlength(br) != na))
      sl::stop("sim_engine_run: Asset-Listen passen nicht");
    Input& I = X.I;
    I.n = n;
    I.na = na;
    I.day = real_of(inp, "day", n);
    std::vector<const double*>&p_price = X.p_price, &p_sb = X.p_sb, &p_ss = X.p_ss, &p_ew = X.p_ew, &p_br = X.p_br;
    p_price.assign((std::size_t) na, nullptr); p_sb.assign((std::size_t) na, nullptr);
    p_ss.assign((std::size_t) na, nullptr); p_ew.assign((std::size_t) na, nullptr); p_br.assign((std::size_t) na, nullptr);
    std::vector<std::vector<double>>& store = X.store;
    store.assign((std::size_t) (2 * na), std::vector<double>());
    std::vector<int>& ai = X.ai;
    ai.assign(AI_N * (std::size_t) na, 0);
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
    I.fees = real_of(inp, "fees", 15);   // seit 1.6.5 mit Depotgebuehr (Entscheidung 150)
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
    SEXP report = X.report = sl::alloc(VECSXP, na);
    std::vector<double*>& reps = X.reps;
    reps.assign(5 * (std::size_t) na, nullptr);
    for (int a = 0; a < na; a++) {
      SEXP r = sl::alloc(VECSXP, 5);
      for (int k = 0; k < 5; k++) {
        SEXP x = sl::alloc(REALSXP, n);
        double* v = REAL(x);
        for (int i = 0; i < n; i++) v[i] = 0.0;
        reps[5 * a + k] = v;
        SET_VECTOR_ELT(r, k, x);
      }
      sl::set_attr_sym(r, R_NamesSymbol, rep_names);
      SET_VECTOR_ELT(report, a, r);
    }
    I.reports = reps.data();
    // Vorbereitung (prepare_core_impl.h): Termine, Tagesflags, Startgewichte
    simlev_prepare::PrepFlat& F = X.F;
    F.pi = int_of(inp, "pi", simlev_prepare::PI_N);
    F.pd = real_of(inp, "pd", simlev_prepare::PD_N);
    F.start = real_of(inp, "start", na);
    SEXP fi = el(inp, "filled"), evc = el(inp, "event");
    if (!Rf_isNull(fi)) F.filled = int_of(inp, "filled", n);
    if (!Rf_isNull(evc)) F.event = int_of(inp, "event", n);
    sched_days(inp, "d_days", "d_dcode", F.d_nd, F.d_days, F.d_dcode);
    sched_days(inp, "b_days", "b_dcode", F.b_nd, F.b_days, F.b_dcode);
}

// Ergebnisliste der Tagesengine nach dem Lauf (rc: Rueckgabe von Engine::run)
SEXP engine_out(simlev_engine::Engine& E, int rc, SEXP inp, EngineIn& X) {
    using namespace simlev_engine;
    const int na = X.na;
    // Ergebnis
    std::vector<double> buf(8 * (std::size_t) na);
    E.status_out(buf.data());
    SEXP status = num_vec(buf);
    buf.assign(TT_N, 0.0);
    E.totals_out(buf.data());
    SEXP totals = num_vec(buf);
    SEXP date_class = sl::mkstring("Date");   // gehalten (seit 1.6.4 unter rcall, K43 T1-B2)
    // compact (seit 1.6.3 Pflicht: fehlt es, gilt 0 und der Aufruf bricht unten ab; Engine::open_lots_n/open_lots_out):
    // je Asset die Zahl der Kaeufe und Verkaeufe
    // (n_buys, n_sells, double); 2 dazu open_lots: offene Lots je Asset als list(date <Date>, units, price, vp)
    // (Spalten von .sim_lots_frame, ohne Klasse und Zeilennamen), 1 open_lots = NULL. Die Listen je Lot, Verkauf und
    // Steuerbuchung (bis 1.6.2) las in R niemand ausser ihrer Laenge (R-r-1).
    const R_xlen_t i_compact = sl::find(inp, "compact");
    const int compact = i_compact < 0 ? 0 : sl::as_int(VECTOR_ELT(inp, i_compact));
    if (compact < 1 || compact > 2) sl::stop("sim_engine_run: compact muss 1 oder 2 sein");
    SEXP px_out = sl::alloc(VECSXP, na);
    for (int a = 0; a < na; a++)
      if (E.px_changed[a]) SET_VECTOR_ELT(px_out, a, num_vec(E.px[a]));
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
    sl::set_attr_sym(ev, R_NamesSymbol, names_of({"code", "site", "day", "asset", "aux", "y_off", "ny", "v_off", "nv",
                                              "d0", "d1"}));
    SEXP err = R_NilValue;
    if (rc != 0) {
      err = sl::alloc(VECSXP, 5);
      SET_VECTOR_ELT(err, 0, int_vec({E.err.site}));
      SET_VECTOR_ELT(err, 1, int_vec({E.err.day}));
      SET_VECTOR_ELT(err, 2, int_vec({E.err.asset + 1}));
      SET_VECTOR_ELT(err, 3, int_vec({E.err.code}));
      SET_VECTOR_ELT(err, 4, num_scalar(E.err.d0));
      sl::set_attr_sym(err, R_NamesSymbol, names_of({"site", "day", "asset", "code", "d0"}));
    }
    buf.assign(simlev::TR_N * E.rows.size(), 0.0);
    E.rows_out(buf.data());
    SEXP rows = num_vec(buf);
    buf.assign(2 * E.ks.size(), 0.0);
    E.ks_out(buf.data());
    SEXP ks = num_vec(buf);
    SEXP nb = sl::alloc(REALSXP, na), ns = sl::alloc(REALSXP, na);
    for (int a = 0; a < na; a++) {
      REAL(nb)[a] = (double) E.buys[a].size();
      REAL(ns)[a] = (double) E.sells[a].size();
    }
    SEXP open = R_NilValue;
    if (compact == 2) {
      open = sl::alloc(VECSXP, na);
      SEXP ol_names = sl::keep(names_of({"date", "units", "price", "vp"}));
      for (int a = 0; a < na; a++) {
        const R_xlen_t k = (R_xlen_t) E.open_lots_n(a);
        buf.assign(4 * (std::size_t) k, 0.0);
        if (k > 0) E.open_lots_out(a, buf.data());
        SEXP cols = sl::alloc(VECSXP, 4);
        for (int c = 0; c < 4; c++) {
          SEXP x = sl::alloc(REALSXP, k);
          for (R_xlen_t j = 0; j < k; j++) REAL(x)[j] = buf[(std::size_t) (c * k + j)];
          if (c == 0) sl::set_attr_sym(x, R_ClassSymbol, date_class);
          SET_VECTOR_ELT(cols, c, x);
        }
        sl::set_attr_sym(cols, R_NamesSymbol, ol_names);
        SET_VECTOR_ELT(open, a, cols);
      }
    }
    SEXP res = sl::alloc(VECSXP, 16);
    SET_VECTOR_ELT(res, 0, status);
    SET_VECTOR_ELT(res, 1, X.report);
    SET_VECTOR_ELT(res, 2, px_out);
    SET_VECTOR_ELT(res, 3, totals);
    SET_VECTOR_ELT(res, 4, num_scalar(E.fee_paid));
    SET_VECTOR_ELT(res, 5, num_scalar(E.tax_unpaid));
    SET_VECTOR_ELT(res, 6, rows);
    SET_VECTOR_ELT(res, 7, ks);
    SET_VECTOR_ELT(res, 8, ev);
    SET_VECTOR_ELT(res, 9, int_vec(E.ev_ints));
    SET_VECTOR_ELT(res, 10, num_vec(E.ev_vals));
    SET_VECTOR_ELT(res, 11, err);
    SET_VECTOR_ELT(res, 12, int_vec(E.prep_flags));
    SET_VECTOR_ELT(res, 13, nb);
    SET_VECTOR_ELT(res, 14, ns);
    SET_VECTOR_ELT(res, 15, open);
    sl::set_attr_sym(res, R_NamesSymbol, names_of({"status", "report", "prices", "totals", "fee_paid", "tax_unpaid", "rows",
                                              "ks", "events", "ev_ints", "ev_vals", "error", "flags", "n_buys",
                                              "n_sells", "open_lots"}));
    return res;
}

}  // namespace

extern "C" SEXP C_sim_engine_run(SEXP inp) {
  return sl::call([&]() {
    EngineIn X;
    engine_in(inp, X);
    simlev_engine::Engine E;
    const int bad = E.setup_prepared(X.I, X.F);
    if (bad) sl::stop("sim_engine_run: Eingabe passt nicht (%d)", bad);
    const int rc = E.run();
    return engine_out(E, rc, inp, X);
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
// Ergebnisliste der Auswertung (seit 1.6.5 eigene Hilfe, gemeinsam fuer C_sim_evaluate und C_sim_run_prepared)
SEXP eval_out(const simlev_eval::Result& R) {
    using namespace simlev_eval;
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
    sl::set_attr_sym(res, R_NamesSymbol, names_of({"total_worth", "twr_index", "invested", "drawdowns", "scal", "has_ext",
                                              "stats", "ints", "buys", "sells", "why_i", "why_v", "um_i", "um_v",
                                              "msg_code", "msg_v", "err"}));
    return res;
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
    return eval_out(R);
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

// Vorbereiteter Kernlauf (seit 1.6.5, Paket E, Entscheidung 176): Tagesengine und Auswertung in einem Aufruf
// (core/evaluate_core_impl.h, simlev_run::run_prepared; R-Seite .sim_prep_run in R/sim_prepared.R).
// inp wie C_sim_engine_run; ev = list(day, filled (0/1 oder NULL), sc = c(start_date, stopp_date, start_value),
// rf (Zahlen oder NULL), rf_ok). Rueckgabe list(engine = wie C_sim_engine_run, eval = wie C_sim_evaluate bzw. NULL
// nach einem Abbruch der Engine).
extern "C" SEXP C_sim_run_prepared(SEXP inp, SEXP ev) {
  return sl::call([&]() {
    EngineIn X;
    engine_in(inp, X);
    simlev_run::EvalStatic S;
    S.day = real_of(ev, "day", X.n);
    if (!Rf_isNull(el(ev, "filled"))) S.filled = int_of(ev, "filled", X.n);
    const double* sc = real_of(ev, "sc", 3);
    S.start_date = sc[0]; S.stopp_date = sc[1]; S.start_value = sc[2];
    SEXP rf = el(ev, "rf");
    if (!Rf_isNull(rf)) {
      if (TYPEOF(rf) != REALSXP) sl::stop("sim_run_prepared: rf passt nicht");
      S.rf = REAL(rf);
      S.n_rf = Rf_xlength(rf);
    }
    S.rf_ok = sl::as_int(el(ev, "rf_ok"));
    simlev_engine::Engine E;
    simlev_eval::Result R;
    int bad = 0;
    const int rc = simlev_run::run_prepared(E, X.I, X.F, S, R, &bad);
    if (rc == 1) sl::stop("sim_engine_run: Eingabe passt nicht (%d)", bad);
    if (rc == 3) sl::stop("sim_evaluate: Eingabe passt nicht");
    SEXP eo = engine_out(E, rc == 2 ? 1 : 0, inp, X);
    SEXP vo = rc == 0 ? eval_out(R) : R_NilValue;
    SEXP res = sl::alloc(VECSXP, 2);
    SET_VECTOR_ELT(res, 0, eo);
    SET_VECTOR_ELT(res, 1, vo);
    sl::set_attr_sym(res, R_NamesSymbol, names_of({"engine", "eval"}));
    return res;
  });
}

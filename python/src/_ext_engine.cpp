/*
 * python/src/_ext_engine.cpp -- Python-Huelle der Tagesengine von simulation()
 *
 * Kern core/engine_core_impl.h (Kopie in src/core/; gemeinsam mit R r/src/engine_core.cpp und Julia
 * core/simlev_cabi.cpp, simlev_c_engine_*): eigener Zustand im Kern, flache Eingabe (struct Input), Ergebnisse
 * ueber die Methoden *_out. Aufruf aus simlev/_sim_engine.py (sim_engine_run); mit der Vorbereitung
 * (core/prepare_core_impl.h) im selben Aufruf, dazu sim_dates_flags (calculate_dates_flags). Die frueheren Engine-Kerne
 * (simulation_core_impl.h, fifo_core_impl.h, tax_core_impl.h) mit ihrem Host auf der dict/list-Struktur sim
 * (simlev_host::Obj) und die Funktionen sim_dca_flows ... sim_sell_count sind seit 1.4.0 entfallen.
 * auch die Auswertung (core/evaluate_core_impl.h): sim_evaluate (simlev/_sim_evaluate.py) und
 * sim_xirr (xirr_rate, simlev/_sim_base.py).
 */
#include "_ext_common.h"

#include <cstdint>

#include "core/engine_core_impl.h"
#include "core/evaluate_core_impl.h"

namespace {

/* Hilfen fuer die Tagesengine (core/engine_core_impl.h); Aufruf und Rueckgabe von sim_engine_run stehen bei
 * e_engine_run (seit 1.6.4 ohne die veraltete Fassung der Argumentliste von vor 1.4.0 an dieser Stelle). */
// Puffer oder None (dann nullptr); len >= 0: Laenge pruefen
bool get_opt(PyObject* o, ext::Buf& b, char kind, const char* fn, const char* name, Py_ssize_t len = -1) {
    return o == Py_None || ext::get(o, b, kind, false, fn, name, len);
}

// Angaben der Vorbereitung (prepare_core_impl.h, PrepFlat): Tupel (pi, pd, start, filled, event, d_days, d_dcode,
// b_days, b_dcode); filled, event und die Tage eines Plans koennen None sein
bool get_prep(PyObject* o, ext::Buf* b, Py_ssize_t n, Py_ssize_t na, simlev_prepare::PrepFlat& F, const char* fn) {
    if (!PyTuple_Check(o) || PyTuple_GET_SIZE(o) != 9) {
        PyErr_SetString(PyExc_TypeError, "sim_engine_run: prep muss ein Tupel mit 9 Angaben sein");
        return false;
    }
    PyObject* x[9];
    for (int k = 0; k < 9; k++) x[k] = PyTuple_GET_ITEM(o, k);
    if (!ext::get(x[0], b[0], 'i', false, fn, "pi", simlev_prepare::PI_N) ||
        !ext::get(x[1], b[1], 'd', false, fn, "pd", simlev_prepare::PD_N) ||
        !ext::get(x[2], b[2], 'd', false, fn, "start", na) || !get_opt(x[3], b[3], 'i', fn, "filled", n) ||
        !get_opt(x[4], b[4], 'i', fn, "event", n) || !get_opt(x[5], b[5], 'd', fn, "d_days") ||
        !get_opt(x[6], b[6], 'i', fn, "d_dcode", b[5].n) || !get_opt(x[7], b[7], 'd', fn, "b_days") ||
        !get_opt(x[8], b[8], 'i', fn, "b_dcode", b[7].n))
        return false;
    F.pi = b[0].i(); F.pd = b[1].d(); F.start = b[2].d();
    F.filled = x[3] != Py_None ? b[3].i() : nullptr;
    F.event = x[4] != Py_None ? b[4].i() : nullptr;
    F.d_nd = b[5].n; F.d_days = x[5] != Py_None ? b[5].d() : nullptr; F.d_dcode = x[6] != Py_None ? b[6].i() : nullptr;
    F.b_nd = b[7].n; F.b_days = x[7] != Py_None ? b[7].d() : nullptr; F.b_dcode = x[8] != Py_None ? b[8].i() : nullptr;
    return true;
}

/* Tagesengine (core/engine_core_impl.h, flache Eingabe struct Input) mit Vorbereitung
 * (core/prepare_core_impl.h). Aufruf aus simlev/_sim_engine.py:
 *   sim_engine_run(prep, day, prices, sig_buy, sig_sell, event_w, base_rates, ai, ad, ci, cd, fees, tot0,
 *                  tariff_par, zve, reports)
 *   prep: (pi int32[PI_N], pd float64[PD_N], start float64[na], filled int32[n]/None, event int32[n]/None,
 *   d_days float64/None, d_dcode int32/None, b_days, b_dcode); day float64[n]; prices, sig_buy, sig_sell: Listen je
 *   Asset (float64[n]); event_w, base_rates: None oder Liste je Asset (None bzw. float64[n]); ai int32[AI_N na]
 *   (Startindizes setzt die Vorbereitung), ad float64[AD_N na], ci int32[CI_N], cd float64[CD_N], fees float64[10],
 *   tot0 float64[TT_N], tariff_par float64[], zve float64[2 k] (Jahr, zvE); reports: Liste von 5 na beschreibbaren
 *   float64[n] (worth, money, flows, total, share je Asset).
 * Rueckgabe: (status [8 na], totals [TT_N], lots je Asset [7 k], sells je Asset [8 k], taxes je Asset [8 k],
 *   prices je Asset (None oder [n], nach Splits), fee_paid, tax_unpaid, rows [TR_N k], ks [2 k],
 *   events [(code, site, day, asset, aux, (Jahre bzw. Assets), d0, d1, (Werte))], error (site, day, asset, code,
 *   d0) bzw. None, flags (Tagesflags, int32[n])); details-Ereignisse (code >= 200) mit Werten;
 *   Zahlenfelder als bytearray (float64). Der Kern laeuft ohne GIL.
 * Seit 1.6.4 ohne das optionale 17. Argument compact (kompakte Lot-Ausgabe von 1.6.3, ohne Aufrufer) und ohne
 *   refund_due in der Rueckgabe (ohne Leser). */
PyObject* e_engine_run(PyObject*, PyObject* a) {
    using namespace simlev_engine;
    PyObject *o_prep, *o_day, *o_prices, *o_sb, *o_ss, *o_ew, *o_br, *o_ai, *o_ad, *o_ci, *o_cd, *o_fees, *o_tot0,
        *o_tp, *o_zve, *o_rep;
    if (!PyArg_UnpackTuple(a, "sim_engine_run", 16, 16, &o_prep, &o_day, &o_prices, &o_sb, &o_ss, &o_ew, &o_br, &o_ai,
                           &o_ad, &o_ci, &o_cd, &o_fees, &o_tot0, &o_tp, &o_zve, &o_rep))
        return nullptr;
    const char* fn = "sim_engine_run";
    if (!PyList_Check(o_prices) || !PyList_Check(o_sb) || !PyList_Check(o_ss) || !PyList_Check(o_rep) ||
        (o_ew != Py_None && !PyList_Check(o_ew)) || (o_br != Py_None && !PyList_Check(o_br))) {
        PyErr_SetString(PyExc_TypeError, "sim_engine_run: Listen erwartet");
        return nullptr;
    }
    const Py_ssize_t na = PyList_GET_SIZE(o_prices);
    ext::Buf bday, bai, bad, bci, bcd, bfees, btot0, btp, bzve, bprep[9];
    if (!ext::get(o_day, bday, 'd', false, fn, "day")) return nullptr;
    const Py_ssize_t n = bday.n;
    simlev_prepare::PrepFlat F;
    if (!get_prep(o_prep, bprep, n, na, F, fn) ||
        !ext::get(o_ai, bai, 'i', false, fn, "ai", AI_N * na) || !ext::get(o_ad, bad, 'd', false, fn, "ad", AD_N * na) ||
        !ext::get(o_ci, bci, 'i', false, fn, "ci", CI_N) ||
        !ext::get(o_cd, bcd, 'd', false, fn, "cd", CD_N) || !ext::get(o_fees, bfees, 'd', false, fn, "fees", 10) ||
        !ext::get(o_tot0, btot0, 'd', false, fn, "tot0", TT_N) || !ext::get(o_tp, btp, 'd', false, fn, "tariff_par") ||
        !ext::get(o_zve, bzve, 'd', false, fn, "zve"))
        return nullptr;
    if (PyList_GET_SIZE(o_sb) != na || PyList_GET_SIZE(o_ss) != na || PyList_GET_SIZE(o_rep) != 5 * na ||
        (o_ew != Py_None && PyList_GET_SIZE(o_ew) != na) || (o_br != Py_None && PyList_GET_SIZE(o_br) != na) ||
        bzve.n % 2 != 0) {
        PyErr_SetString(PyExc_ValueError, "sim_engine_run: Listen passen nicht zur Zahl der Assets");
        return nullptr;
    }
    std::vector<ext::Buf> bufs((std::size_t) (10 * na));
    std::vector<const double*> pp((std::size_t) na), psb((std::size_t) na), pss((std::size_t) na),
        pew((std::size_t) na, nullptr), pbr((std::size_t) na, nullptr);
    std::vector<double*> prep((std::size_t) (5 * na));
    for (Py_ssize_t k = 0; k < na; k++) {
        ext::Buf* b = &bufs[(std::size_t) (10 * k)];
        PyObject *osb = PyList_GET_ITEM(o_sb, k), *oss = PyList_GET_ITEM(o_ss, k);   // None: keine Signalspalte (seit 1.6.1)
        if (!ext::get(PyList_GET_ITEM(o_prices, k), b[0], 'd', false, fn, "prices", n) ||
            (osb != Py_None && !ext::get(osb, b[1], 'd', false, fn, "sig_buy", n)) ||
            (oss != Py_None && !ext::get(oss, b[2], 'd', false, fn, "sig_sell", n)))
            return nullptr;
        pp[k] = b[0].d();
        psb[k] = osb == Py_None ? nullptr : b[1].d();
        pss[k] = oss == Py_None ? nullptr : b[2].d();
        if (o_ew != Py_None && PyList_GET_ITEM(o_ew, k) != Py_None) {
            if (!ext::get(PyList_GET_ITEM(o_ew, k), b[3], 'd', false, fn, "event_w", n)) return nullptr;
            pew[k] = b[3].d();
        }
        if (o_br != Py_None && PyList_GET_ITEM(o_br, k) != Py_None) {
            if (!ext::get(PyList_GET_ITEM(o_br, k), b[4], 'd', false, fn, "base_rates", n)) return nullptr;
            pbr[k] = b[4].d();
        }
        for (int j = 0; j < 5; j++) {
            if (!ext::get(PyList_GET_ITEM(o_rep, 5 * k + j), b[5 + j], 'd', true, fn, "reports", n)) return nullptr;
            prep[(std::size_t) (5 * k + j)] = b[5 + j].d();
        }
    }
    Input I;
    I.n = n; I.na = na; I.day = bday.d();
    I.price = pp.data(); I.sig_buy = psb.data(); I.sig_sell = pss.data();
    I.event_w = o_ew != Py_None ? pew.data() : nullptr;
    I.base_rates = o_br != Py_None ? pbr.data() : nullptr;
    I.ai = bai.i(); I.ad = bad.d(); I.ci = bci.i(); I.cd = bcd.d(); I.fees = bfees.d();
    I.tot0 = btot0.d(); I.tariff_par = btp.d(); I.n_tariff_par = btp.n; I.zve = bzve.d(); I.n_zve = bzve.n / 2;
    I.reports = prep.data();
    Engine E;
    if (E.setup_prepared(I, F) != 0) {
        PyErr_SetString(PyExc_ValueError, "sim_engine_run: Eingabe passt nicht");
        return nullptr;
    }
    int rc = 0;
    if (!ext::run([&]() { rc = E.run(); })) return nullptr;
    double* p;
    PyObject* status = ext::new_doubles(8 * na, &p);
    if (status) E.status_out(p);
    PyObject* totals = ext::new_doubles(TT_N, &p);
    if (totals) E.totals_out(p);
    PyObject* rows = ext::new_doubles(simlev::TR_N * (Py_ssize_t) E.rows.size(), &p);
    if (rows) E.rows_out(p);
    PyObject* ks = ext::new_doubles(2 * (Py_ssize_t) E.ks.size(), &p);
    if (ks) E.ks_out(p);
    PyObject* lots = PyList_New(na);
    PyObject* sells = PyList_New(na);
    PyObject* taxes = PyList_New(na);
    PyObject* prices = PyList_New(na);
    PyObject* evs = PyList_New((Py_ssize_t) E.events.size());
    auto drop = [&]() {
        Py_XDECREF(status); Py_XDECREF(totals); Py_XDECREF(rows); Py_XDECREF(ks); Py_XDECREF(lots);
        Py_XDECREF(sells); Py_XDECREF(taxes); Py_XDECREF(prices); Py_XDECREF(evs);
        return (PyObject*) nullptr;
    };
    if (!status || !totals || !rows || !ks || !lots || !sells || !taxes || !prices || !evs) return drop();
    for (Py_ssize_t k = 0; k < na; k++) {
        PyObject* bl = ext::new_doubles(7 * (Py_ssize_t) E.buys[(std::size_t) k].size(), &p);
        if (!bl) return drop();
        E.lots_out((int) k, p);
        PyList_SET_ITEM(lots, k, bl);
        PyObject* sv = ext::new_doubles(8 * (Py_ssize_t) E.sells[(std::size_t) k].size(), &p);
        if (!sv) return drop();
        E.sells_out((int) k, p);
        PyList_SET_ITEM(sells, k, sv);
        PyObject* tv = ext::new_doubles(8 * (Py_ssize_t) E.taxes[(std::size_t) k].size(), &p);
        if (!tv) return drop();
        E.taxes_out((int) k, p);
        PyList_SET_ITEM(taxes, k, tv);
        PyObject* pv;
        if (E.px_changed[(std::size_t) k]) {
            pv = ext::new_doubles(n, &p);
            if (!pv) return drop();
            const std::vector<double>& x = E.px[(std::size_t) k];
            for (Py_ssize_t i = 0; i < n; i++) p[i] = x[(std::size_t) i];
        } else {
            Py_INCREF(Py_None);
            pv = Py_None;
        }
        PyList_SET_ITEM(prices, k, pv);
    }
    for (std::size_t i = 0; i < E.events.size(); i++) {
        const Event& e = E.events[i];
        PyObject* ints = PyTuple_New(e.ny);
        if (!ints) return drop();
        // seit 1.6.4 (K43 T1-N4): jede neue Zahl geprueft; bei Speichermangel Tupel freigeben (leere Plaetze sind
        // erlaubt) und MemoryError statt eines NULL-Eintrags im Tupel
        for (int j = 0; j < e.ny; j++) {
            PyObject* o = PyLong_FromLong(E.ev_ints[(std::size_t) (e.y_off + j)]);
            if (!o) {
                Py_DECREF(ints);
                return drop();
            }
            PyTuple_SET_ITEM(ints, j, o);
        }
        PyObject* vals = PyTuple_New(e.nv);
        if (!vals) {
            Py_DECREF(ints);
            return drop();
        }
        for (int j = 0; j < e.nv; j++) {
            PyObject* o = PyFloat_FromDouble(E.ev_vals[(std::size_t) (e.v_off + j)]);
            if (!o) {
                Py_DECREF(ints);
                Py_DECREF(vals);
                return drop();
            }
            PyTuple_SET_ITEM(vals, j, o);
        }
        PyObject* t = Py_BuildValue("(iiiiiNddN)", e.code, e.site, e.day, e.asset, e.aux, ints, e.d0, e.d1, vals);
        if (!t) return drop();
        PyList_SET_ITEM(evs, (Py_ssize_t) i, t);
    }
    PyObject* err = rc != 0 ? Py_BuildValue("(iiiid)", E.err.site, E.err.day, E.err.asset, E.err.code, E.err.d0)
                            : (Py_INCREF(Py_None), Py_None);
    if (!err) return drop();
    PyObject* flags = PyByteArray_FromStringAndSize(reinterpret_cast<const char*>(E.prep_flags.data()),
                                                    (Py_ssize_t) (E.prep_flags.size() * sizeof(int32_t)));
    if (!flags) {
        Py_DECREF(err);
        return drop();
    }
    return Py_BuildValue("(NNNNNNddNNNNN)", status, totals, lots, sells, taxes, prices, E.fee_paid, E.tax_unpaid, rows,
                         ks, evs, err, flags);
}

/* calculate_dates_flags() ueber den Kern (prepare_core_impl.h, dates_flags):
 *   sim_dates_flags(dates float64[n], si int32[SI_N], start, days float64/None, dcode int32/None, liquidate)
 *   -> bytearray int32[n] (0/1) */
PyObject* e_dates_flags(PyObject*, PyObject* a) {
    PyObject *o_dates, *o_si, *o_days, *o_dcode;
    double start;
    int liquidate;
    if (!PyArg_ParseTuple(a, "OOdOOi:sim_dates_flags", &o_dates, &o_si, &start, &o_days, &o_dcode, &liquidate))
        return nullptr;
    const char* fn = "sim_dates_flags";
    ext::Buf bd, bsi, bdays, bdc;
    if (!ext::get(o_dates, bd, 'd', false, fn, "dates") ||
        !ext::get(o_si, bsi, 'i', false, fn, "si", simlev_prepare::SI_N) || !get_opt(o_days, bdays, 'd', fn, "days") ||
        !get_opt(o_dcode, bdc, 'i', fn, "dcode", bdays.n))
        return nullptr;
    const simlev_prepare::Sched S = simlev_prepare::sched_of(bsi.i(), start, bdays.n,
                                                             o_days != Py_None ? bdays.d() : nullptr,
                                                             o_dcode != Py_None ? bdc.i() : nullptr);
    PyObject* out = PyByteArray_FromStringAndSize(nullptr, bd.n * (Py_ssize_t) sizeof(int32_t));
    if (!out) return nullptr;
    simlev_prepare::dates_flags(bd.n, bd.d(), S, liquidate,
                                reinterpret_cast<int32_t*>(PyByteArray_AS_STRING(out)));
    return out;
}


PyObject* msgs_tuple(const std::vector<simlev_eval::Msg>& m) {
    PyObject* l = PyList_New((Py_ssize_t) m.size());
    if (!l) return nullptr;
    for (std::size_t i = 0; i < m.size(); i++) {
        PyObject* t = Py_BuildValue("(idddd)", m[i].code, m[i].v[0], m[i].v[1], m[i].v[2], m[i].v[3]);
        if (!t) {
            Py_DECREF(l);
            return nullptr;
        }
        PyList_SET_ITEM(l, (Py_ssize_t) i, t);
    }
    return l;
}
PyObject* doubles_of(const double* x, std::size_t n) {
    double* p;
    PyObject* o = ext::new_doubles((Py_ssize_t) n, &p);
    if (o) for (std::size_t i = 0; i < n; i++) p[i] = x[i];
    return o;
}

/* Auswertung von simulation() (core/evaluate_core_impl.h). Aufruf aus simlev/_sim_evaluate.py:
 *   sim_evaluate(total, flows, worth, money, price, day, filled, sc, status_money, n_buys, n_sells, rf, rf_ok)
 *   total ... price: Listen je Asset (float64[n]); day float64[n]; filled int32[n] oder None; sc float64[4]
 *   (start_date, stopp_date, start_value, tax_unpaid); status_money, n_buys, n_sells float64[na]; rf float64[] oder
 *   None; rf_ok 0/1.
 * Rueckgabe: (total_worth, twr_index, invested, drawdowns [bytearray float64], (cagr, ttwror, open_tax_debt),
 *   has_ext_flows, stats [20], (skew_lgl, kurt_lgl, longest_dd), buys, sells, why ((gesetzt, reason, detail, v0, v1,
 *   v2) je cagr/ttwror), um [(metric, reason, detail, v0, v1, v2)], msgs [(code, v0..v3)], (err_site, err_phase)) */
PyObject* e_evaluate(PyObject*, PyObject* a) {
    using namespace simlev_eval;
    PyObject *o_tot, *o_fl, *o_wo, *o_mo, *o_px, *o_day, *o_filled, *o_sc, *o_sm, *o_nb, *o_ns, *o_rf;
    int rf_ok;
    if (!PyArg_ParseTuple(a, "OOOOOOOOOOOOi:sim_evaluate", &o_tot, &o_fl, &o_wo, &o_mo, &o_px, &o_day, &o_filled,
                          &o_sc, &o_sm, &o_nb, &o_ns, &o_rf, &rf_ok))
        return nullptr;
    const char* fn = "sim_evaluate";
    PyObject* lists[5] = {o_tot, o_fl, o_wo, o_mo, o_px};
    for (PyObject* l : lists)
        if (!PyList_Check(l) || PyList_GET_SIZE(l) != PyList_GET_SIZE(o_tot) || PyList_GET_SIZE(l) < 1) {
            PyErr_SetString(PyExc_TypeError, "sim_evaluate: Listen je Asset erwartet");
            return nullptr;
        }
    const Py_ssize_t na = PyList_GET_SIZE(o_tot);
    ext::Buf bday, bfi, bsc, bsm, bnb, bns, brf;
    if (!ext::get(o_day, bday, 'd', false, fn, "day")) return nullptr;
    const Py_ssize_t n = bday.n;
    if (!get_opt(o_filled, bfi, 'i', fn, "filled", n) || !ext::get(o_sc, bsc, 'd', false, fn, "sc", 4) ||
        !ext::get(o_sm, bsm, 'd', false, fn, "status_money", na) || !ext::get(o_nb, bnb, 'd', false, fn, "n_buys", na) ||
        !ext::get(o_ns, bns, 'd', false, fn, "n_sells", na) || !get_opt(o_rf, brf, 'd', fn, "rf"))
        return nullptr;
    std::vector<ext::Buf> bufs((std::size_t) (5 * na));
    std::vector<const double*> ptr((std::size_t) (5 * na));
    static const char* names[5] = {"total", "flows", "worth", "money", "price"};
    for (int j = 0; j < 5; j++)
        for (Py_ssize_t k = 0; k < na; k++) {
            ext::Buf& b = bufs[(std::size_t) (j * na + k)];
            if (!ext::get(PyList_GET_ITEM(lists[j], k), b, 'd', false, fn, names[j], n)) return nullptr;
            ptr[(std::size_t) (j * na + k)] = b.d();
        }
    In I;
    I.n = n; I.na = na;
    I.total = &ptr[0]; I.flows = &ptr[(std::size_t) na]; I.worth = &ptr[(std::size_t) (2 * na)];
    I.money = &ptr[(std::size_t) (3 * na)]; I.price = &ptr[(std::size_t) (4 * na)];
    I.day = bday.d();
    I.filled = o_filled != Py_None ? bfi.i() : nullptr;
    const double* sc = bsc.d();
    I.start_date = sc[0]; I.stopp_date = sc[1]; I.start_value = sc[2]; I.tax_unpaid = sc[3];
    I.status_money = bsm.d(); I.n_buys = bnb.d(); I.n_sells = bns.d();
    if (o_rf != Py_None) {
        I.rf = brf.d();
        I.n_rf = brf.n;
    }
    I.rf_ok = rf_ok;
    Result R;
    int rc = 0;
    if (!ext::run([&]() { rc = evaluate(I, R); })) return nullptr;
    if (rc == 2) {
        PyErr_SetString(PyExc_ValueError, "sim_evaluate: Eingabe passt nicht");
        return nullptr;
    }
    PyObject* um = PyList_New((Py_ssize_t) R.um.size());
    if (!um) return nullptr;
    for (std::size_t i = 0; i < R.um.size(); i++) {
        const Row& u = R.um[i];
        PyObject* t = Py_BuildValue("(iiiddd)", u.metric, u.reason, u.detail, u.v[0], u.v[1], u.v[2]);
        if (!t) {
            Py_DECREF(um);
            return nullptr;
        }
        PyList_SET_ITEM(um, (Py_ssize_t) i, t);
    }
    return Py_BuildValue("(NNNN(ddd)NN(iii)NN((iiiddd)(iiiddd))NN(ii))",
                         doubles_of(R.total_worth.data(), R.total_worth.size()),
                         doubles_of(R.twr_index.data(), R.twr_index.size()),
                         doubles_of(R.invested.data(), R.invested.size()),
                         doubles_of(R.drawdowns.data(), R.drawdowns.size()), R.cagr, R.ttwror, R.open_tax_debt,
                         PyBool_FromLong(R.has_ext_flows), doubles_of(R.stats, ST_N), R.skew_lgl, R.kurt_lgl,
                         R.longest_dd, doubles_of(R.buys.data(), R.buys.size()),
                         doubles_of(R.sells.data(), R.sells.size()), R.why_set[0], R.why[0].reason, R.why[0].detail,
                         R.why[0].v[0], R.why[0].v[1], R.why[0].v[2], R.why_set[1], R.why[1].reason, R.why[1].detail,
                         R.why[1].v[0], R.why[1].v[1], R.why[1].v[2], um, msgs_tuple(R.msgs), R.err_site, R.err_phase);
}

/* xirr_rate (.xirr_rate) ueber den Kern: sim_xirr(t float64[k], amount float64[k], end_value, horizon)
 *   -> (Wert, [(code, v0..v3)] Warnungen von uniroot) */
PyObject* e_xirr(PyObject*, PyObject* a) {
    PyObject *o_t, *o_a;
    double end_value, horizon;
    if (!PyArg_ParseTuple(a, "OOdd:sim_xirr", &o_t, &o_a, &end_value, &horizon)) return nullptr;
    ext::Buf bt, ba;
    if (!ext::get(o_t, bt, 'd', false, "sim_xirr", "t") || !ext::get(o_a, ba, 'd', false, "sim_xirr", "amount", bt.n))
        return nullptr;
    std::vector<simlev_eval::Msg> m;
    const double v = simlev_eval::xirr(bt.n, bt.d(), ba.d(), end_value, horizon, &m);
    return Py_BuildValue("(dN)", v, msgs_tuple(m));
}

}  // namespace

PyMethodDef simlev_ext_engine_methods[] = {
    {"sim_engine_run", e_engine_run, METH_VARARGS,
     "sim_engine_run(prep, day, prices, sig_buy, sig_sell, event_w, base_rates, ai, ad, ci, cd, fees, tot0,\n"
     "               tariff_par, zve, reports) -> (status, totals, lots, sells, taxes, prices, fee_paid,\n"
     "               tax_unpaid, rows, ks, events, error, flags)  (Vorbereitung und Tagesengine)"},
    {"sim_dates_flags", e_dates_flags, METH_VARARGS,
     "sim_dates_flags(dates, si, start, days, dcode, liquidate) -> int32-Flags  (Termine)"},
    {"sim_evaluate", e_evaluate, METH_VARARGS,
     "sim_evaluate(total, flows, worth, money, price, day, filled, sc, status_money, n_buys, n_sells, rf, rf_ok)\n"
     "  -> Auswertung von simulation()"},
    {"sim_xirr", e_xirr, METH_VARARGS,
     "sim_xirr(t, amount, end_value, horizon) -> (Wert, Warnungen)  (interner Zinsfuss)"},
    {nullptr, nullptr, 0, nullptr}
};

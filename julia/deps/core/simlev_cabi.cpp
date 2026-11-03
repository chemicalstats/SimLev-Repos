/*
 * core/simlev_cabi.cpp -- C-ABI-Huelle der geteilten C++-Kerne (dritter Host: Julia)
 *
 * Die geteilten Kerne (simlev_core.h, research_core_impl.h, withdrawal_core_impl.h, tariff_core_impl.h,
 * engine_core_impl.h) rechnen in R (Huellen r/src/<kern>.cpp) und Python
 * (python/src/_ext_<kern>.cpp) aus derselben Quelle. Diese Datei stellt sie hinter einer
 * reinen C-Schnittstelle bereit (extern "C"; nur Zeiger, Laengen und Skalare), ueber die Julia sie
 * per ccall aufruft (julia/src/cabi.jl). Gebaut von julia/deps/build.jl in die Bibliothek libslc
 * (neben den C-Quellen von slc), mit denselben Gleitkomma-Schaltern wie R und Python
 * (-O2 -ffp-contract=off -fno-fast-math, SIMLEV_FP_CONTRACT_BY_FLAG wie Python). Kanonisch in core/,
 * Kopie in julia/deps/core/ (core/sync.py); R und Python bauen sie nicht.
 *
 * Host-Namen aus simlev_core.h:
 *
 *   simlev_host::NumVec, IntVec, NumMat   Sichten (Zeiger, Laenge; Matrizen spaltenweise), gleicher
 *                                         Aufbau wie in R und Python
 *   SIMLEV_NA                             NA_real_ (simlev_na_real())
 *   SIMLEV_FAIL(fmt, ...)                 C++-Ausnahme mit dem Text; die Huelle faengt sie und gibt
 *                                         SIMLEV_C_ERROR zurueck, der Text steht danach in
 *                                         simlev_c_last_error() (je Thread). Kein longjmp ueber
 *                                         Julia-Rahmen.
 *   SIMLEV_CHECK_INTERRUPT()              prueft einen prozessweiten Merker (simlev_c_interrupt);
 *                                         gesetzt -> Rueckgabe SIMLEV_C_INTERRUPT. Derzeit ruft kein
 *                                         Kern die Pruefung auf.
 *   SIMLEV_WARN(msg)                      von keinem Kern genutzt; Text in simlev_c_last_error()
 *   SIMLEV_NUM, MATRIX, COPY, CLONE, INT  Speicher je Thread (vor jedem Kern geleert); die Huelle
 *                                         kopiert die Ergebnisse in die Felder des Aufrufers
 *   SIMLEV_LIST, DONE, SET_FLAG           Tupel bzw. Merker wie in Python
 *
 * Auswertung (evaluate_core_impl.h): simlev_c_eval_* (Ergebnisobjekt je Aufrufer) und simlev_c_xirr.
 *
 * Tagesengine (engine_core_impl.h): eigener Zustand im Kern, flache Eingabe (struct Input); Julia
 * uebergibt Zeiger, Laengen und Skalare und holt die Ergebnisse ueber simlev_c_engine_* (julia/src/sim_engine.jl).
 * Die frueheren Engine-Kerne (simulation_core_impl.h, fifo_core_impl.h, tax_core_impl.h) mit ihrem Host auf
 * dem Simulationszustand von Julia (simlev_host::Obj, simlev_c_asset, simlev_c_layout) sind seit 1.4.0
 * entfallen. Geblieben sind feste Groessen und Schrittweiten der flachen Felder; simlev_c_flat_layout meldet sie,
 * Julia prueft sie beim Vorkompilieren.
 *
 * Rueckgabecodes: 0 in Ordnung, 1 Fehler des Kerns (Text), 2 Benutzerabbruch, 3 kein Speicher,
 * 4 unbekannte Ausnahme, 5 Fehlaufruf der Huelle (Laengen; Text).
 */
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <deque>
#include <new>
#include <tuple>
#include <vector>

#include "simlev_core.h"

#define SIMLEV_C_OK 0
#define SIMLEV_C_ERROR 1
#define SIMLEV_C_INTERRUPT 2
#define SIMLEV_C_NOMEM 3
#define SIMLEV_C_UNKNOWN 4
#define SIMLEV_C_BADCALL 5

#if defined(__GNUC__)
#define SIMLEV_C_EXPORT extern "C" __attribute__((visibility("default")))
#else
#define SIMLEV_C_EXPORT extern "C"
#endif

namespace cabi {

typedef std::ptrdiff_t idx_t;

template <class T> struct VecT {
    void* sexp;
    T* ptr;
    idx_t len;
    T& operator[](idx_t i) const { return ptr[i]; }
    idx_t size() const { return len; }
    T* begin() const { return ptr; }
    T* end() const { return ptr + len; }
};
typedef VecT<double> Vec;
typedef VecT<int> IVec;

struct Mat {
    void* sexp;
    double* ptr;
    int nr, nc;
    double& operator()(idx_t i, idx_t j) const { return ptr[i + (idx_t) nr * j]; }
    int nrow() const { return nr; }
    int ncol() const { return nc; }
    double* begin() const { return ptr; }
    double* end() const { return ptr + (idx_t) nr * nc; }
};

inline Vec vec(const double* p, idx_t n) { Vec v = {nullptr, const_cast<double*>(p), n}; return v; }
inline IVec ivec(const int* p, idx_t n) { IVec v = {nullptr, const_cast<int*>(p), n}; return v; }
inline Mat mat(const double* p, int nr, int nc) { Mat m = {nullptr, const_cast<double*>(p), nr, nc}; return m; }

struct KernelError {
    char msg[2048];
};
struct Interrupted {};
struct BadCall {
    char msg[512];
};

inline char* last_error() {
    static thread_local char buf[2048] = {0};
    return buf;
}
inline void set_error(const char* m) { std::snprintf(last_error(), 2048, "%s", m); }

#if defined(__GNUC__)
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wformat-security"
#pragma GCC diagnostic ignored "-Wformat-nonliteral"
#endif
template <class... A> [[noreturn]] inline void fail(const char* fmt, A... a) {
    KernelError e;
    std::snprintf(e.msg, sizeof e.msg, fmt, a...);
    throw e;
}
template <class... A> [[noreturn]] inline void badcall(const char* fmt, A... a) {
    BadCall e;
    std::snprintf(e.msg, sizeof e.msg, fmt, a...);
    throw e;
}
#if defined(__GNUC__)
#pragma GCC diagnostic pop
#endif

inline std::atomic<int>& interrupt_flag() {
    static std::atomic<int> f(0);
    return f;
}
inline void check_interrupt() {
    if (interrupt_flag().load(std::memory_order_relaxed) != 0) throw Interrupted();
}

/* Ergebnisfelder der Kerne: Speicher je Thread, vor jedem Kern geleert */
struct Alloc {
    std::deque<std::vector<double>> store;
    std::deque<std::vector<int>> istore;
    bool flag = false, has_flag = false;
    void reset() {
        store.clear();
        istore.clear();
        flag = has_flag = false;
    }
    IVec ivec(idx_t n, int fill = 0) {
        istore.emplace_back((std::size_t) n, fill);
        IVec v = {nullptr, istore.back().data(), n};
        return v;
    }
    Vec num(idx_t n, double fill = 0.0) {
        store.emplace_back((std::size_t) n, fill);
        Vec v = {nullptr, store.back().data(), n};
        return v;
    }
    Mat mat(int nr, int nc) {
        store.emplace_back((std::size_t) nr * (std::size_t) nc, 0.0);
        Mat m = {nullptr, store.back().data(), nr, nc};
        return m;
    }
    template <class It> Vec copy(It first, It last) {
        store.emplace_back(first, last);
        Vec v = {nullptr, store.back().data(), (idx_t) store.back().size()};
        return v;
    }
    void set_flag(bool f) {
        flag = f;
        has_flag = true;
    }
};
inline Alloc& alloc() {
    static thread_local Alloc a;
    return a;
}

/* Kern ausfuehren; Ausnahmen in Rueckgabecodes umsetzen (Text in last_error(), nur bei Fehler gesetzt) */
template <class F> int run(F f) {
    try {
        Alloc& al = alloc();
        if (!al.store.empty() || !al.istore.empty() || al.has_flag) al.reset();   /* meist schon leer */
        f();
        return SIMLEV_C_OK;
    } catch (const KernelError& e) {
        set_error(e.msg);
        return SIMLEV_C_ERROR;
    } catch (const BadCall& e) {
        set_error(e.msg);
        return SIMLEV_C_BADCALL;
    } catch (const Interrupted&) {
        set_error("Benutzerabbruch");
        return SIMLEV_C_INTERRUPT;
    } catch (const std::bad_alloc&) {
        set_error("kein Speicher");
        return SIMLEV_C_NOMEM;
    } catch (...) {
        set_error("unbekannte C++-Ausnahme im Kern");
        return SIMLEV_C_UNKNOWN;
    }
}

inline void put(double* out, idx_t want, const double* p, idx_t n, const char* fn, const char* what) {
    if (n != want) badcall("%s: '%s' hat %td statt %td Werte.", fn, what, n, want);
    for (idx_t k = 0; k < n; k++) out[k] = p[k];
}

}  // namespace cabi

/* ---------------------------------------------------------------------------
 * C-ABI als Host der gemeinsamen Kerne (Schnittstelle in simlev_core.h)
 * ------------------------------------------------------------------------- */
namespace simlev_host {

typedef cabi::Vec NumVec;
typedef cabi::IVec IntVec;
typedef cabi::Mat NumMat;
typedef cabi::IVec LglVec;

}  // namespace simlev_host

#define SIMLEV_NA (simlev_na_real())
#define SIMLEV_FAIL cabi::fail
#define SIMLEV_CHECK_INTERRUPT() cabi::check_interrupt()
#define SIMLEV_WARN(msg) cabi::set_error(msg)
#define SIMLEV_NUM(...) cabi::alloc().num(__VA_ARGS__)
#define SIMLEV_INT(...) cabi::alloc().ivec(__VA_ARGS__)
#define SIMLEV_MATRIX(...) cabi::alloc().mat(__VA_ARGS__)
#define SIMLEV_COPY(...) cabi::alloc().copy(__VA_ARGS__)
#define SIMLEV_COPY_VEC(...) cabi::alloc().copy(__VA_ARGS__)
#define SIMLEV_SET_FLAG(v, name, f) cabi::alloc().set_flag(f)
#define SIMLEV_DONE(v) (v)
#define SIMLEV_LIST(...) std::make_tuple(__VA_ARGS__)
#define SIMLEV_CLONE(v) cabi::alloc().copy((v).begin(), (v).end())
#define SIMLEV_R_FINITE(x) std::isfinite(x)

#include "research_core_impl.h"
#include "withdrawal_core_impl.h"
#include "engine_core_impl.h"   /* Tagesengine (eigener Zustand, ohne Host-Objekte) */
#include "evaluate_core_impl.h" /* Auswertung von simulation(), xirr */

/* ===========================================================================
 * Exportierte Funktionen (Praefix simlev_c_). Laengen als int64_t, Matrizen spaltenweise.
 * ========================================================================= */

SIMLEV_C_EXPORT const char* simlev_c_last_error(void) { return cabi::last_error(); }
SIMLEV_C_EXPORT void simlev_c_interrupt(int on) { cabi::interrupt_flag().store(on ? 1 : 0); }

/* ---- research_core_impl.h ---- */

SIMLEV_C_EXPORT int simlev_c_proj_box_simplex(const double* v, const double* lo, const double* hi, int64_t n,
                                              double* out) {
    return cabi::run([&] { simlev::proj_box_simplex(v, lo, hi, (int) n, out); });
}

SIMLEV_C_EXPORT int simlev_c_qp_box_simplex(const double* Q, int64_t nr, int64_t nc, const double* c, int64_t nc_c,
                                            const double* lo, int64_t nlo, const double* hi, int64_t nhi,
                                            const double* w0, int64_t nw0, double L, int64_t maxit, double tol,
                                            double* out) {
    return cabi::run([&] {
        cabi::Vec w = simlev::qp_box_simplex(cabi::mat(Q, (int) nr, (int) nc), cabi::vec(c, nc_c), cabi::vec(lo, nlo),
                                             cabi::vec(hi, nhi), cabi::vec(w0, nw0), L, (int) maxit, tol);
        cabi::put(out, nc, w.ptr, w.len, "qp_box_simplex", "w");
    });
}

SIMLEV_C_EXPORT int simlev_c_min_cvar_core(const double* R, int64_t T, int64_t N, double alpha, const double* lo,
                                           int64_t nlo, const double* hi, int64_t nhi, const double* w0, int64_t nw0,
                                           double zeta0, const double* sc, int64_t nsc, int64_t maxit, double* out) {
    return cabi::run([&] {
        cabi::Vec x = simlev::min_cvar_core(cabi::mat(R, (int) T, (int) N), alpha, cabi::vec(lo, nlo),
                                            cabi::vec(hi, nhi), cabi::vec(w0, nw0), zeta0, cabi::vec(sc, nsc),
                                            (int) maxit);
        cabi::put(out, N, x.ptr, x.len, "min_cvar_core", "x");
    });
}

SIMLEV_C_EXPORT int simlev_c_min_cdar_core(const double* R, int64_t T, int64_t N, double alpha, const double* lo,
                                           int64_t nlo, const double* hi, int64_t nhi, int64_t iters, double* out) {
    return cabi::run([&] {
        cabi::Vec b = simlev::min_cdar_core(cabi::mat(R, (int) T, (int) N), alpha, cabi::vec(lo, nlo),
                                            cabi::vec(hi, nhi), (int) iters);
        cabi::put(out, N, b.ptr, b.len, "min_cdar_core", "best");
    });
}

/* *optimal: -1 ohne Ergebnis (p = 0), sonst 0/1; out mit p Werten */
SIMLEV_C_EXPORT int simlev_c_quantile_reg_core(const double* y, int64_t ny, const double* X, int64_t n, int64_t p,
                                               double tau, const double* b0, int64_t nb0, double sc, double tol,
                                               int64_t maxit, double* out, int* optimal) {
    return cabi::run([&] {
        cabi::Vec b = simlev::quantile_reg_core(cabi::vec(y, ny), cabi::mat(X, (int) n, (int) p), tau, cabi::vec(b0, nb0),
                                                sc, tol, (int) maxit);
        if (!cabi::alloc().has_flag) {
            *optimal = -1;
            return;
        }
        cabi::put(out, p, b.ptr, b.len, "quantile_reg_core", "beta");
        *optimal = cabi::alloc().flag ? 1 : 0;
    });
}

SIMLEV_C_EXPORT int simlev_c_hmm_forward_backward(const double* B, int64_t T, int64_t K, const double* A,
                                                  int64_t anr, int64_t anc, const double* p0, int64_t np0,
                                                  double* al, double* ga, double* xi, double* cs) {
    return cabi::run([&] {
        auto r = simlev::hmm_forward_backward(cabi::mat(B, (int) T, (int) K), cabi::mat(A, (int) anr, (int) anc),
                                              cabi::vec(p0, np0));
        cabi::put(al, T * K, std::get<1>(r).ptr, (cabi::idx_t) T * K, "hmm_forward_backward", "filtered");
        cabi::put(ga, T * K, std::get<3>(r).ptr, (cabi::idx_t) T * K, "hmm_forward_backward", "smoothed");
        cabi::put(xi, K * K, std::get<5>(r).ptr, (cabi::idx_t) K * K, "hmm_forward_backward", "xi");
        cabi::put(cs, T, std::get<7>(r).ptr, std::get<7>(r).len, "hmm_forward_backward", "scale");
    });
}

SIMLEV_C_EXPORT int simlev_c_roll_mean_core(const double* x, int64_t m, int n, double* out) {
    return cabi::run([&] {
        cabi::Vec r = simlev::roll_mean_core(cabi::vec(x, m), n);
        cabi::put(out, m, r.ptr, r.len, "roll_mean_core", "out");
    });
}

SIMLEV_C_EXPORT int simlev_c_roll_cov_core(const double* x, int64_t mx, const double* y, int64_t my, int n,
                                           double* out) {
    return cabi::run([&] {
        cabi::Vec r = simlev::roll_cov_core(cabi::vec(x, mx), cabi::vec(y, my), n);
        cabi::put(out, mx, r.ptr, r.len, "roll_cov_core", "out");
    });
}

SIMLEV_C_EXPORT int simlev_c_kendall_tau_core(const double* x, const double* y, int64_t n, double* out) {
    return cabi::run([&] { *out = simlev::kendall_tau_core(cabi::vec(x, n), cabi::vec(y, n)); });
}

/* ---- withdrawal_core_impl.h ----
 * mats: R, INF, CAPE, BASE (Zeiger) mit dims[8] (nr, nc je Matrix). Ergebnis in out[11] (Felder in der
 * Reihenfolge wealth, spending, planned, terminal_real, terminal_nominal, taxes_real, depletion_period,
 * failed, wealth_end, taxes_end, tariff_years (25 x (ny + 1) Pfade)) mit den Laengen outlen[11]; odims[8]: ny, paths, wealth
 * (nr, nc), wealth_end (nr, nc), tariff_years (nr, nc). tariff_par/zve wie in R (leer = ohne Tarifweg). */
SIMLEV_C_EXPORT int simlev_c_wd_simulate(const double* const* mats, const int64_t* dims, int64_t ppy, int64_t rule,
                                         const double* rp, int64_t nrp, int start_timing, double start_value,
                                         const double* income, int64_t ninc, int tax_on, double tax_rate, double tfs,
                                         double spb_annual, int vp_on, double cost, double basis_ratio, double loss0,
                                         int keep, const double* lot_n, int64_t nln, const double* lot_basis,
                                         int64_t nlb, const double* lot_vp, int64_t nlv, const int* lot_group,
                                         int64_t nlg, double spb_first, int horizon_end, const double* tariff_par,
                                         int64_t ntp, const double* zve, int64_t nzv, double* const* out,
                                         const int64_t* outlen, int64_t* odims) {
    return cabi::run([&] {
        auto r = simlev::wd_simulate(
            cabi::mat(mats[0], (int) dims[0], (int) dims[1]), cabi::mat(mats[1], (int) dims[2], (int) dims[3]),
            cabi::mat(mats[2], (int) dims[4], (int) dims[5]), cabi::mat(mats[3], (int) dims[6], (int) dims[7]),
            (int) ppy, (int) rule, cabi::vec(rp, nrp), start_timing != 0, start_value, cabi::vec(income, ninc),
            tax_on != 0, tax_rate, tfs, spb_annual, vp_on != 0, cost, basis_ratio, loss0, keep != 0,
            cabi::vec(lot_n, nln), cabi::vec(lot_basis, nlb), cabi::vec(lot_vp, nlv), cabi::ivec(lot_group, nlg),
            spb_first, horizon_end != 0, cabi::vec(tariff_par, ntp), cabi::vec(zve, nzv));
        const cabi::Mat& wealth = std::get<1>(r);
        const cabi::Mat& spending = std::get<3>(r);
        const cabi::Mat& wealth_end = std::get<17>(r);
        const cabi::Mat& tariff_years = std::get<21>(r);
        odims[0] = spending.nr; odims[1] = spending.nc; odims[2] = wealth.nr; odims[3] = wealth.nc;
        odims[4] = wealth_end.nr; odims[5] = wealth_end.nc; odims[6] = tariff_years.nr; odims[7] = tariff_years.nc;
        /* Speicher in der Reihenfolge der Anlage: wealth, spending, planned, terminal, terminal_nom, taxes,
         * depl, fail, wealth_end, taxes_end, st, tariff_years (st ausgelassen) */
        std::deque<std::vector<double>>& st = cabi::alloc().store;
        if (st.size() < 12) cabi::badcall("wd_simulate: unerwartete Ergebnisse");
        for (int k = 0; k < 11; k++) {
            const std::size_t sk = (std::size_t) (k < 10 ? k : 11);
            cabi::put(out[k], outlen[k], st[sk].data(), (cabi::idx_t) st[sk].size(), "wd_simulate", "Ergebnis");
        }
    });
}

/* ---- Tagesengine (engine_core_impl.h, flache Eingabe struct Input) ----
 * Ablauf in Julia (julia/src/sim_engine.jl): h = simlev_c_engine_new(); simlev_c_engine_run(h, ...) rechnet und
 * schreibt die Report-Vektoren (Zeiger reports, 5 je Asset: worth, money, flows, total, share) an Ort und Stelle;
 * simlev_c_engine_counts und _lots/_sells/_taxes/_prices/_events/_rows holen die uebrigen Ergebnisse;
 * simlev_c_engine_free(h). Das Engine-Objekt gehoert dem Aufrufer (kein globaler Zustand; je Thread eigene
 * Objekte). Eingaben wie python/src/_ext_engine.cpp (sim_engine_run): ai[AI_N na], ad[AD_N na], ci[CI_N],
 * cd[CD_N], fees[10], tot0[TT_N], tariff_par[n_tariff_par], zve[2 n_zve] (Jahr, zvE); event_w und base_rates:
 * nullptr oder je Asset ein Zeiger (nullptr ohne Spalte). Der Kern rechnet vorher die
 * Vorbereitung (prepare_core_impl.h): pi[PI_N], pd[PD_N], start[na], filled[n] bzw. nullptr, event[n] bzw.
 * nullptr, Tage der Plaene (d_*, b_*); flags_out[n] erhaelt die Tagesflags (Freibetragstage fuer das Ergebnis).
 * Rueckgabe von simlev_c_engine_run: 0 in Ordnung, 6 Abbruch (NA in einer Bedingung bzw. Split-Verhaeltnis;
 * Angaben ueber simlev_c_engine_counts), sonst wie die uebrigen Exporte. */
SIMLEV_C_EXPORT void* simlev_c_engine_new(void) { return new (std::nothrow) simlev_engine::Engine(); }
SIMLEV_C_EXPORT void simlev_c_engine_free(void* h) { delete static_cast<simlev_engine::Engine*>(h); }

SIMLEV_C_EXPORT int simlev_c_engine_run(void* h, int64_t n, int64_t na, const double* day,
                                        const double* const* prices, const double* const* sig_buy,
                                        const double* const* sig_sell, const double* const* event_w,
                                        const double* const* base_rates, const int32_t* ai, const double* ad,
                                        const int32_t* ci, const double* cd, const double* fees,
                                        const double* tot0, const double* tariff_par, int64_t n_tariff_par,
                                        const double* zve, int64_t n_zve, double* const* reports,
                                        const int32_t* pi, const double* pd, const double* start, const int32_t* filled,
                                        const int32_t* event, int64_t d_nd, const double* d_days,
                                        const int32_t* d_dcode, int64_t b_nd, const double* b_days,
                                        const int32_t* b_dcode, int32_t* flags_out) {
    int rcode = 0;
    const int rc = cabi::run([&] {
        simlev_engine::Engine& E = *static_cast<simlev_engine::Engine*>(h);
        simlev_engine::Input I;
        I.n = n; I.na = na; I.day = day;
        I.price = prices; I.sig_buy = sig_buy; I.sig_sell = sig_sell; I.event_w = event_w; I.base_rates = base_rates;
        I.ai = ai; I.ad = ad; I.ci = ci; I.cd = cd; I.fees = fees; I.tot0 = tot0;
        I.tariff_par = tariff_par; I.n_tariff_par = n_tariff_par; I.zve = zve; I.n_zve = n_zve; I.reports = reports;
        simlev_prepare::PrepFlat F;
        F.pi = pi; F.pd = pd; F.start = start; F.filled = filled; F.event = event;
        F.d_nd = d_nd; F.d_days = d_days; F.d_dcode = d_dcode; F.b_nd = b_nd; F.b_days = b_days; F.b_dcode = b_dcode;
        const int bad = E.setup_prepared(I, F);
        if (bad) cabi::badcall("simlev_c_engine_run: Eingabe passt nicht (%d).", bad);
        for (int64_t i = 0; i < n; i++) flags_out[i] = E.prep_flags[(std::size_t) i];
        rcode = E.run();
    });
    if (rc != SIMLEV_C_OK) return rc;
    return rcode != 0 ? 6 : SIMLEV_C_OK;
}

/* calculate_dates_flags() ueber den Kern (prepare_core_impl.h, dates_flags): si[SI_N] (on, years,
 * quarter, end, skip, has_days, step), start, days/dcode (nd Werte, nullptr ohne days), out[n] 0/1 */
SIMLEV_C_EXPORT int simlev_c_dates_flags(int64_t n, const double* dates, const int32_t* si, double start, int64_t nd,
                                         const double* days, const int32_t* dcode, int32_t liquidate, int32_t* out) {
    return cabi::run([&] {
        simlev_prepare::dates_flags(n, dates, simlev_prepare::sched_of(si, start, nd, days, dcode), liquidate, out);
    });
}

/* status[8 na], totals[TT_N]; je Asset nlots, nsells, ntaxes, px_changed; cnt[5] Ereignisse, Ganzzahlen der
 * Ereignisse (Jahre, Assets), Jahreszeilen, KiSt-Salden, Werte der details-Ereignisse; scal[3] fee_paid, tax_unpaid, refund_due; err[4] Stelle, Tag, Asset (0-basiert),
 * Code; *err_d0 Wert zum Code (ohne Abbruch alles 0) */
SIMLEV_C_EXPORT void simlev_c_engine_counts(void* h, double* status, double* totals, int64_t* nlots, int64_t* nsells,
                                            int64_t* ntaxes, int32_t* px_changed, int64_t* cnt, double* scal,
                                            int32_t* err, double* err_d0) {
    const simlev_engine::Engine& E = *static_cast<simlev_engine::Engine*>(h);
    E.status_out(status);
    E.totals_out(totals);
    for (int k = 0; k < E.na; k++) {
        nlots[k] = (int64_t) E.buys[(std::size_t) k].size();
        nsells[k] = (int64_t) E.sells[(std::size_t) k].size();
        ntaxes[k] = (int64_t) E.taxes[(std::size_t) k].size();
        px_changed[k] = E.px_changed[(std::size_t) k];
    }
    cnt[0] = (int64_t) E.events.size(); cnt[1] = (int64_t) E.ev_ints.size();
    cnt[2] = (int64_t) E.rows.size(); cnt[3] = (int64_t) E.ks.size(); cnt[4] = (int64_t) E.ev_vals.size();
    scal[0] = E.fee_paid; scal[1] = E.tax_unpaid; scal[2] = E.refund_due;
    err[0] = E.err.site; err[1] = E.err.day; err[2] = E.err.asset; err[3] = E.err.code;
    *err_d0 = E.err.d0;
}

/* Lots von Asset a (0-basiert): je Lot date, count, price, remaining, original, vp, has_vp */
SIMLEV_C_EXPORT void simlev_c_engine_lots(void* h, int64_t a, double* out) {
    static_cast<simlev_engine::Engine*>(h)->lots_out((int) a, out);
}
/* Verkaeufe von Asset a: je Verkauf date, count, price, gain, taxes, regime, exempt, has_exempt */
SIMLEV_C_EXPORT void simlev_c_engine_sells(void* h, int64_t a, double* out) {
    static_cast<simlev_engine::Engine*>(h)->sells_out((int) a, out);
}
/* Steuerbuchungen von Asset a: je Eintrag kind, event_date, assessment_date, gross, bonus, taxable, spb_used, paid */
SIMLEV_C_EXPORT void simlev_c_engine_taxes(void* h, int64_t a, double* out) {
    static_cast<simlev_engine::Engine*>(h)->taxes_out((int) a, out);
}
/* Kursreihe von Asset a (n Werte; nach Splits umgerechnet) */
SIMLEV_C_EXPORT void simlev_c_engine_prices(void* h, int64_t a, double* out) {
    const std::vector<double>& x = static_cast<simlev_engine::Engine*>(h)->px[(std::size_t) a];
    for (std::size_t i = 0; i < x.size(); i++) out[i] = x[i];
}
/* Ereignisse: ints[9 k] code, site, day, asset (0-basiert, -1 ohne), aux, y_off, ny, v_off, nv; dbls[2 k] d0, d1;
 * years[cnt[1]] Ganzzahlen (Jahre der Bezeichnungen, Assets); vals[cnt[4]] Werte der details-Ereignisse */
SIMLEV_C_EXPORT void simlev_c_engine_events(void* h, int32_t* ints, double* dbls, int32_t* years, double* vals) {
    const simlev_engine::Engine& E = *static_cast<simlev_engine::Engine*>(h);
    E.events_out(ints, dbls);
    for (std::size_t j = 0; j < E.ev_ints.size(); j++) years[j] = E.ev_ints[j];
    for (std::size_t j = 0; j < E.ev_vals.size(); j++) vals[j] = E.ev_vals[j];
}
/* Jahreszeilen des Tarifwegs (TR_N je Zeile) und KiSt-Salden (Jahr, Betrag) */
SIMLEV_C_EXPORT void simlev_c_engine_rows(void* h, double* rows, double* ks) {
    const simlev_engine::Engine& E = *static_cast<simlev_engine::Engine*>(h);
    E.rows_out(rows);
    E.ks_out(ks);
}

/* ── Auswertung von simulation() (evaluate_core_impl.h; Julia: src/sim_evaluate.jl) ─────────────────
 * h = simlev_c_eval_new(); simlev_c_eval_run(h, ...) rechnet; cnt[2] = Zeilen von undefined_metrics, Warnungen;
 * simlev_c_eval_get holt die Ergebnisse; simlev_c_eval_free(h). Eingaben wie python/src/_ext_engine.cpp
 * (sim_evaluate): je Asset Zeiger auf total, flows, worth, money, price (n); filled nullptr oder n Werte 0/1;
 * sc[4] start_date, stopp_date, start_value, tax_unpaid; rf nullptr oder n_rf Werte. Rueckgabe 0 (auch bei einem
 * Abbruch des Kerns, err in simlev_c_eval_get), 5 bei fehlerhafter Eingabe. */
SIMLEV_C_EXPORT void* simlev_c_eval_new(void) { return new (std::nothrow) simlev_eval::Result(); }
SIMLEV_C_EXPORT void simlev_c_eval_free(void* h) { delete static_cast<simlev_eval::Result*>(h); }
SIMLEV_C_EXPORT int simlev_c_eval_run(void* h, int64_t n, int64_t na, const double* const* total,
                                      const double* const* flows, const double* const* worth,
                                      const double* const* money, const double* const* price, const double* day,
                                      const int32_t* filled, const double* sc, const double* status_money,
                                      const double* n_buys, const double* n_sells, const double* rf, int64_t n_rf,
                                      int32_t rf_ok, int64_t* cnt) {
    return cabi::run([&] {
        simlev_eval::Result& R = *static_cast<simlev_eval::Result*>(h);
        R = simlev_eval::Result();
        simlev_eval::In I;
        I.n = n; I.na = na; I.total = total; I.flows = flows; I.worth = worth; I.money = money; I.price = price;
        I.day = day; I.filled = filled;
        I.start_date = sc[0]; I.stopp_date = sc[1]; I.start_value = sc[2]; I.tax_unpaid = sc[3];
        I.status_money = status_money; I.n_buys = n_buys; I.n_sells = n_sells; I.rf = rf; I.n_rf = n_rf; I.rf_ok = rf_ok;
        if (simlev_eval::evaluate(I, R) == 2) cabi::badcall("simlev_c_eval_run: Eingabe passt nicht.");
        cnt[0] = (int64_t) R.um.size();
        cnt[1] = (int64_t) R.msgs.size();
    });
}
/* tw, twr, inv, dd [n]; scal[3] cagr, ttwror, open_tax_debt; ints[4] has_ext_flows, skew_lgl, kurt_lgl, longest_dd;
 * stats[20]; buys, sells [na]; why_i[6], why_v[6] (je cagr/ttwror: gesetzt, reason, detail bzw. v0..v2);
 * um_i[3 k] metric, reason, detail; um_v[3 k]; msg_c[m], msg_v[4 m]; err[2] Stelle, Phase */
SIMLEV_C_EXPORT void simlev_c_eval_get(void* h, double* tw, double* twr, double* inv, double* dd, double* scal,
                                       int32_t* ints, double* stats, double* buys, double* sells, int32_t* why_i,
                                       double* why_v, int32_t* um_i, double* um_v, int32_t* msg_c, double* msg_v,
                                       int32_t* err) {
    const simlev_eval::Result& R = *static_cast<simlev_eval::Result*>(h);
    std::copy(R.total_worth.begin(), R.total_worth.end(), tw);
    std::copy(R.twr_index.begin(), R.twr_index.end(), twr);
    std::copy(R.invested.begin(), R.invested.end(), inv);
    std::copy(R.drawdowns.begin(), R.drawdowns.end(), dd);
    scal[0] = R.cagr; scal[1] = R.ttwror; scal[2] = R.open_tax_debt;
    ints[0] = R.has_ext_flows; ints[1] = R.skew_lgl; ints[2] = R.kurt_lgl; ints[3] = R.longest_dd;
    std::copy(R.stats, R.stats + simlev_eval::ST_N, stats);
    std::copy(R.buys.begin(), R.buys.end(), buys);
    std::copy(R.sells.begin(), R.sells.end(), sells);
    for (int k = 0; k < 2; k++) {
        why_i[3 * k] = R.why_set[k]; why_i[3 * k + 1] = R.why[k].reason; why_i[3 * k + 2] = R.why[k].detail;
        for (int j = 0; j < 3; j++) why_v[3 * k + j] = R.why[k].v[j];
    }
    for (std::size_t i = 0; i < R.um.size(); i++) {
        um_i[3 * i] = R.um[i].metric; um_i[3 * i + 1] = R.um[i].reason; um_i[3 * i + 2] = R.um[i].detail;
        for (int j = 0; j < 3; j++) um_v[3 * i + j] = R.um[i].v[j];
    }
    for (std::size_t i = 0; i < R.msgs.size(); i++) {
        msg_c[i] = R.msgs[i].code;
        for (int j = 0; j < 4; j++) msg_v[4 * i + j] = R.msgs[i].v[j];
    }
    err[0] = R.err_site; err[1] = R.err_phase;
}

/* xirr (.xirr_rate): *value; Warnungen von uniroot als Codes in wcodes (hoechstens cap, *nw ihre Zahl) */
SIMLEV_C_EXPORT int simlev_c_xirr(int64_t n, const double* t, const double* amount, double end_value, double horizon,
                                  double* value, int32_t* wcodes, int64_t cap, int64_t* nw) {
    return cabi::run([&] {
        std::vector<simlev_eval::Msg> m;
        *value = simlev_eval::xirr(n, t, amount, end_value, horizon, &m);
        *nw = (int64_t) m.size();
        for (std::size_t i = 0; i < m.size() && (int64_t) i < cap; i++) wcodes[i] = m[i].code;
    });
}

/* Feldlagen der flachen Felder: Julia und die Kerne teilen keine Strukturen, wohl aber feste
 * Groessen und Schrittweiten der flachen Ein- und Ausgaben, die julia/src/sim_engine.jl und sim_evaluate.jl als
 * Zahlen annehmen (_CABI_LAYOUT). Julia vergleicht sie beim Vorkompilieren mit diesen Werten; eine Abweichung
 * (der Kern liest oder schreibt sonst neben die Felder von Julia) bricht mit Namen und Werten ab. Wert k:
 * 0 AI_N, 1 AD_N, 2 CI_N, 3 CD_N, 4 TT_N, 5 PI_N, 6 PD_N, 7 SI_N, 8 TR_N, 9 ST_N, dann die Werte je Eintrag von
 * 10 status_out, 11 lots_out, 12 sells_out, 13 taxes_out und 14, 15 events_out (Ganzzahlen, Zahlen); die
 * letzten sechs stehen dort als Zahlen und sind hier mitzufuehren. Danach -1. Als switch ohne Feld und Schleife:
 * So bleibt der Maschinencode der uebrigen Funktionen dieser Einheit unveraendert (geprueft; eine Fassung mit
 * lokalem Feld aenderte die Codeerzeugung anderer Funktionen). */
SIMLEV_C_EXPORT int64_t simlev_c_flat_layout(int64_t k) {
    switch (k) {
    case 0: return simlev_engine::AI_N; case 1: return simlev_engine::AD_N; case 2: return simlev_engine::CI_N;
    case 3: return simlev_engine::CD_N; case 4: return simlev_engine::TT_N; case 5: return simlev_prepare::PI_N;
    case 6: return simlev_prepare::PD_N; case 7: return simlev_prepare::SI_N; case 8: return simlev::TR_N;
    case 9: return simlev_eval::ST_N; case 10: return 8; case 11: return 7; case 12: return 8; case 13: return 8;
    case 14: return 9; case 15: return 2; default: return -1;
    }
}

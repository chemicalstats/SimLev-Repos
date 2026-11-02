/*
 * core/simlev_cabi.cpp -- C-ABI-Huelle der geteilten C++-Kerne (dritter Host: Julia; N7, 01.11.2026)
 *
 * Die geteilten Kerne (simlev_core.h, research_core_impl.h, withdrawal_core_impl.h,
 * simulation_core_impl.h, fifo_core_impl.h, tax_core_impl.h) rechnen in R (Huellen r/src/<kern>.cpp) und Python
 * (python/src/_ext_<kern>.cpp) seit Etappe 7.3a aus derselben Quelle. Diese Datei stellt sie hinter einer
 * reinen C-Schnittstelle bereit (extern "C"; nur Zeiger, Laengen und Skalare), ueber die Julia sie
 * per ccall aufruft (julia/src/cabi.jl). Gebaut von julia/deps/build.jl in die Bibliothek libslc
 * (neben den C-Quellen von slc), mit denselben Gleitkomma-Schaltern wie R und Python
 * (-O2 -ffp-contract=off -fno-fast-math, SIMLEV_FP_CONTRACT_BY_FLAG wie Python). Kanonisch in core/,
 * Kopie in julia/deps/core/ (tools/core_sync.py); R und Python bauen sie nicht.
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
 * Engine-Kerne: simlev_host::Obj ist ein kleiner Knoten, der direkt auf den Simulationszustand
 * von Julia zeigt (julia/src/core.jl: Status, Lot, Trades, Totals als veraenderliche Strukturen;
 * Report- und Marktvektoren). Julia uebergibt je Asset eine Zeile simlev_c_asset (Zeiger auf
 * Status und Trades, Datenzeiger der Vektoren, Lots als Feld von Objektzeigern) und haelt die
 * Objekte waehrend des Aufrufs fest (GC.@preserve). Die Feldlagen prueft Julia beim Laden gegen
 * simlev_c_layout(). Zugriffe ueber Namen wie in R; Unterlisten zurueckschreiben (set, put) ist
 * hier nichts, weil der Kern auf dem Zustand selbst arbeitet. Neue Lots (perform_trade_buy_cpp)
 * haengt Julia nach dem Aufruf an (Feld new_lot), named_list-Ergebnisse kopiert die Huelle in die
 * Ausgabefelder. Asset-Namen sind fuer den Kern Marken (Zeiger auf die Zeile der Tabelle), Text
 * ueberqueren die Grenze nicht.
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

/* ---------------------------------------------------------------------------
 * Engine: Simulationszustand von Julia (Feldlagen wie julia/src/core.jl)
 * ------------------------------------------------------------------------- */
struct JStatus {
    double count, price, worth, money, total, target, actual, differ;
};
struct JLot {
    int64_t date;
    double count, price, remaining, original, vp;
};
struct JTrades {
    void* buys;
    void* sells;
    void* taxes;
    int64_t fifo_front;
};
struct JTotals {
    double total_taxes, loss_capital_gains, loss_private_sales, private_sale_gains_ytd, private_sale_losses_ytd,
        sparer_pauschbetrag_annual, sparer_pauschbetrag_remaining, sparer_pauschbetrag_used_total;
    int64_t current_year;
    double cgt_base_taxed_ytd, cgt_loss_added_ytd, cgt_loss_used_ytd, cgt_pool_start_ytd;
    void* vp_pending;
    void* p23_due;
    void* private_sale_net_ytd_by;
};

}  // namespace cabi

/* Zeile je Asset (Julia: struct _CAsset in julia/src/cabi.jl, gleiche Feldfolge) */
extern "C" typedef struct simlev_c_asset {
    void* status;          /* Status (veraenderliche Struktur, 8 double) */
    double* worth;         /* Report-Vektoren (Laenge n_days) */
    double* money;
    double* flows;
    double* total;
    double* share;
    double* price;         /* market.asset_price */
    int64_t* day;          /* market.asset_day (Tage seit 1970-01-01) */
    void* trades;          /* Trades (veraenderliche Struktur) */
    void** buys;           /* trades.buys: Feld von Zeigern auf Lot */
    int64_t nbuys;
} simlev_c_asset;

namespace cabi {

enum Kind {
    K_NULL, K_ROOT, K_STATUS_L, K_MARKET_L, K_TRADES_L, K_REPORT_L, K_NAMES,
    K_STATUS, K_MARKET, K_TRADES, K_REPORT,
    K_DNUM, K_INUM, K_IVAL, K_DVEC, K_I64VEC, K_BUYS, K_LOT, K_TOTALS, K_RESULT
};

struct Ctx;
/* Knoten: Art, Zahl bzw. Index, Zeiger, Zustand des Aufrufs (ohne Zugriff auf thread_local je Knoten) */
struct Obj {
    int kind;
    idx_t i;
    void* p;
    Ctx* c;
};

/* Ergebnis von named_list: Zahlen der Reihe nach, dazu bis zu zwei Vektoren */
struct Result {
    double num[8];
    int nnum = 0;
    std::vector<int> ivec;
    std::vector<double> dvec;
    void clear() {
        nnum = 0;
        ivec.clear();
        dvec.clear();
    }
};

struct Ctx {
    simlev_c_asset* tab = nullptr;   /* Zeilen je Asset */
    idx_t n = 0;                      /* Zahl der Zeilen */
    idx_t n_days = 0;                 /* Laenge der Report- und Marktvektoren */
    JTotals* totals = nullptr;
    JLot** buys = nullptr;            /* Lots fuer die Kerne mit buys-Argument */
    idx_t nbuys = 0;
    double new_lot[5] = {0, 0, 0, 0, 0};   /* date, count, price, remaining, original */
    bool has_new_lot = false;
    Result res;
    std::vector<double> days;               /* asset_day als double (Puffer je Thread, bleibt stehen) */
    idx_t day_only = -1;                    /* >= 0: nur dieser Tag wird umgewandelt (sim_buy) */
};
/* Zustand des laufenden Engine-Aufrufs: Speicher je Thread */
inline Ctx& ctx_store() {
    static thread_local Ctx c;
    return c;
}

inline Obj mk(Ctx* c, int kind, idx_t i = 0, void* p = nullptr) { Obj o = {kind, i, p, c}; return o; }

inline idx_t asset_of(const Ctx& c, const char* name) {
    const simlev_c_asset* a = reinterpret_cast<const simlev_c_asset*>(name);
    const idx_t i = a - c.tab;
    if (i < 0 || i >= c.n) badcall("Engine: unbekanntes Asset");
    return i;
}
inline const char* asset_name(const Ctx& c, idx_t i) { return reinterpret_cast<const char*>(c.tab + i); }

inline bool eq(const char* a, const char* b) { return std::strcmp(a, b) == 0; }

inline double* status_field(JStatus* s, const char* f) {
    switch (f[0]) {
    case 'c': if (eq(f, "count")) return &s->count; break;
    case 'p': if (eq(f, "price")) return &s->price; break;
    case 'w': if (eq(f, "worth")) return &s->worth; break;
    case 'm': if (eq(f, "money")) return &s->money; break;
    case 't': if (eq(f, "total")) return &s->total; if (eq(f, "target")) return &s->target; break;
    case 'a': if (eq(f, "actual")) return &s->actual; break;
    case 'd': if (eq(f, "differ")) return &s->differ; break;
    }
    badcall("Engine: unbekanntes Status-Feld '%s'", f);
}
inline double* report_field(const simlev_c_asset& a, const char* f) {
    switch (f[0]) {
    case 'w': if (eq(f, "worth")) return a.worth; break;
    case 'm': if (eq(f, "money")) return a.money; break;
    case 'f': if (eq(f, "flows")) return a.flows; break;
    case 't': if (eq(f, "total")) return a.total; break;
    case 's': if (eq(f, "share")) return a.share; break;
    }
    badcall("Engine: unbekanntes Report-Feld '%s'", f);
}
inline Obj lot_field(Ctx* c, JLot* b, const char* f) {
    switch (f[0]) {
    case 'd': if (eq(f, "date")) return mk(c, K_INUM, 0, &b->date); break;
    case 'c': if (eq(f, "count")) return mk(c, K_DNUM, 0, &b->count); break;
    case 'p': if (eq(f, "price")) return mk(c, K_DNUM, 0, &b->price); break;
    case 'r': if (eq(f, "remaining")) return mk(c, K_DNUM, 0, &b->remaining); break;
    case 'o': if (eq(f, "original")) return mk(c, K_DNUM, 0, &b->original); break;
    case 'v': if (eq(f, "vp")) return mk(c, K_DNUM, 0, &b->vp); break;
    }
    badcall("Engine: unbekanntes Lot-Feld '%s'", f);
}
inline Obj totals_field(Ctx* c, JTotals* t, const char* f, bool must) {
    struct E { const char* n; std::size_t len; std::size_t off; bool isint; };
#define CABI_T(name, isint) {#name, sizeof(#name) - 1, offsetof(JTotals, name), isint}
    static const E tab[] = {
        CABI_T(total_taxes, false), CABI_T(loss_capital_gains, false), CABI_T(loss_private_sales, false),
        CABI_T(private_sale_gains_ytd, false), CABI_T(private_sale_losses_ytd, false),
        CABI_T(sparer_pauschbetrag_annual, false), CABI_T(sparer_pauschbetrag_remaining, false),
        CABI_T(sparer_pauschbetrag_used_total, false), CABI_T(current_year, true), CABI_T(cgt_base_taxed_ytd, false),
        CABI_T(cgt_loss_added_ytd, false), CABI_T(cgt_loss_used_ytd, false), CABI_T(cgt_pool_start_ytd, false),
    };
#undef CABI_T
    const std::size_t len = std::strlen(f);
    for (const E& e : tab)
        if (e.len == len && e.n[0] == f[0] && std::memcmp(f, e.n, len) == 0)
            return mk(c, e.isint ? K_INUM : K_DNUM, 0, reinterpret_cast<char*>(t) + e.off);
    if (must) badcall("Engine: unbekanntes Feld von totals '%s'", f);
    return mk(c, K_NULL);
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
typedef cabi::Obj Obj;
struct Date { double day; };

using cabi::K_NULL; using cabi::K_ROOT; using cabi::K_STATUS_L; using cabi::K_MARKET_L; using cabi::K_TRADES_L;
using cabi::K_REPORT_L; using cabi::K_NAMES; using cabi::K_STATUS; using cabi::K_MARKET; using cabi::K_TRADES;
using cabi::K_REPORT; using cabi::K_DNUM; using cabi::K_INUM; using cabi::K_IVAL; using cabi::K_DVEC;
using cabi::K_I64VEC; using cabi::K_BUYS; using cabi::K_LOT; using cabi::K_TOTALS; using cabi::K_RESULT;
using cabi::mk; using cabi::eq;

inline Obj as_list(Obj x) { return x; }

inline cabi::idx_t length(Obj x) {
    switch (x.kind) {
    case K_NAMES: return x.c->n;
    case K_BUYS: return x.i;
    case K_LOT: return 6;
    case K_NULL: return 0;
    default: return 1;
    }
}

/* oberste Ebene: Position wie .SIM_MEM_LAYOUT (1 status, 2 market, 3 trades, 4 report); Lots */
inline Obj at(Obj x, cabi::idx_t i) {
    if (x.kind == K_ROOT) {
        switch (i) {
        case 1: return mk(x.c, K_STATUS_L);
        case 2: return mk(x.c, K_MARKET_L);
        case 3: return mk(x.c, K_TRADES_L);
        case 4: return mk(x.c, K_REPORT_L);
        }
        cabi::badcall("Engine: Position %td von sim nicht belegt", i);
    }
    if (x.kind == K_BUYS) {
        if (i < 0 || i >= x.i) return mk(x.c, K_NULL);
        return mk(x.c, K_LOT, 0, static_cast<cabi::JLot**>(x.p)[i]);
    }
    cabi::badcall("Engine: at() auf Knoten %d", x.kind);
}

/* Zurueckschreiben einer Unterliste: der Kern arbeitet auf dem Zustand selbst; neues Lot merken */
inline void put(Obj x, cabi::idx_t i, Obj value) {
    if (x.kind == K_BUYS) {
        if (value.kind != K_RESULT || i != x.i) cabi::badcall("Engine: Lot nur am Ende anhaengen");
        cabi::Ctx& c = *x.c;
        if (c.res.nnum != 5) cabi::badcall("Engine: Lot unvollstaendig");
        for (int k = 0; k < 5; k++) c.new_lot[k] = c.res.num[k];
        c.has_new_lot = true;
        return;
    }
    (void) i;
}

inline bool has(Obj d, const char* name) {
    if (d.kind == K_LOT) return eq(name, "date") || eq(name, "count") || eq(name, "price") ||
                                eq(name, "remaining") || eq(name, "original") || eq(name, "vp");
    if (d.kind == K_TOTALS) return cabi::totals_field(d.c, static_cast<cabi::JTotals*>(d.p), name, false).kind != K_NULL;
    return true;
}

inline Obj get(Obj d, const char* name) {
    cabi::Ctx& c = *d.c;
    switch (d.kind) {
    case K_STATUS_L: return mk(d.c, K_STATUS, cabi::asset_of(c, name));
    case K_MARKET_L: return mk(d.c, K_MARKET, cabi::asset_of(c, name));
    case K_TRADES_L: return mk(d.c, K_TRADES, cabi::asset_of(c, name));
    case K_REPORT_L: return mk(d.c, K_REPORT, cabi::asset_of(c, name));
    case K_STATUS:
        return mk(d.c, K_DNUM, 0, cabi::status_field(static_cast<cabi::JStatus*>(c.tab[d.i].status), name));
    case K_REPORT: return mk(d.c, K_DVEC, c.n_days, cabi::report_field(c.tab[d.i], name));
    case K_MARKET:
        if (eq(name, "asset_price")) return mk(d.c, K_DVEC, c.n_days, c.tab[d.i].price);
        if (eq(name, "asset_day")) return mk(d.c, K_I64VEC, c.n_days, c.tab[d.i].day);
        cabi::badcall("Engine: unbekanntes Markt-Feld '%s'", name);
    case K_TRADES: {
        cabi::JTrades* t = static_cast<cabi::JTrades*>(c.tab[d.i].trades);
        if (eq(name, "buys")) return mk(d.c, K_BUYS, c.tab[d.i].nbuys, c.tab[d.i].buys);
        if (eq(name, "buy_count")) return mk(d.c, K_IVAL, c.tab[d.i].nbuys);
        if (eq(name, "fifo_front")) return mk(d.c, K_INUM, 0, &t->fifo_front);
        cabi::badcall("Engine: unbekanntes Trades-Feld '%s'", name);
    }
    case K_LOT: return cabi::lot_field(d.c, static_cast<cabi::JLot*>(d.p), name);
    case K_TOTALS: return cabi::totals_field(d.c, static_cast<cabi::JTotals*>(d.p), name, true);
    }
    cabi::badcall("Engine: get('%s') auf Knoten %d", name, d.kind);
}

inline double as_double(Obj x) {
    switch (x.kind) {
    case K_DNUM: return *static_cast<double*>(x.p);
    case K_INUM: return (double) *static_cast<int64_t*>(x.p);
    case K_IVAL: return (double) x.i;
    }
    cabi::badcall("Engine: as_double auf Knoten %d", x.kind);
}
inline int as_int(Obj x) {
    switch (x.kind) {
    case K_INUM: return (int) *static_cast<int64_t*>(x.p);
    case K_IVAL: return (int) x.i;
    case K_DNUM: return (int) *static_cast<double*>(x.p);
    }
    cabi::badcall("Engine: as_int auf Knoten %d", x.kind);
}

/* Datenvektor als Sicht (double) bzw. Kopie (asset_day, Int64 -> double wie Python) */
inline NumVec num_vec(Obj x) {
    if (x.kind == K_DVEC) {
        NumVec v = {nullptr, static_cast<double*>(x.p), x.i};
        return v;
    }
    if (x.kind == K_I64VEC) {
        /* Kopie wie Python (Int64 -> double), aber in einem Puffer je Thread; perform_trade_buy_cpp liest
         * nur den Tag index - 1, die Huelle sim_buy wandelt daher nur diesen um (sonst O(Tage) je Kauf) */
        cabi::Ctx& c = *x.c;
        const int64_t* s = static_cast<const int64_t*>(x.p);
        if ((cabi::idx_t) c.days.size() < x.i) c.days.resize((std::size_t) x.i);
        if (c.day_only >= 0 && c.day_only < x.i) c.days[(std::size_t) c.day_only] = (double) s[c.day_only];
        else for (cabi::idx_t k = 0; k < x.i; k++) c.days[(std::size_t) k] = (double) s[k];
        NumVec v = {nullptr, c.days.data(), x.i};
        return v;
    }
    cabi::badcall("Engine: num_vec auf Knoten %d", x.kind);
}
inline NumVec new_num(cabi::idx_t n, double fill = 0.0) { return cabi::alloc().num(n, fill); }
inline IntVec new_int(cabi::idx_t n, int fill = 0) { return cabi::alloc().ivec(n, fill); }

/* Werte setzen: Felder des Zustands schreiben; Vektoren und Unterlisten sind schon an Ort und Stelle */
inline void set(Obj&, const char*, const Obj&) {}
inline void set(Obj&, const char*, const NumVec&) {}
inline void set(Obj& d, const char* name, double v) {
    cabi::Ctx& c = *d.c;
    switch (d.kind) {
    case K_STATUS: *cabi::status_field(static_cast<cabi::JStatus*>(c.tab[d.i].status), name) = v; return;
    case K_LOT: {
        Obj f = cabi::lot_field(d.c, static_cast<cabi::JLot*>(d.p), name);
        if (f.kind != K_DNUM) cabi::badcall("Engine: Lot-Feld '%s' ist keine Zahl", name);
        *static_cast<double*>(f.p) = v;
        return;
    }
    case K_TOTALS: {
        Obj f = cabi::totals_field(d.c, static_cast<cabi::JTotals*>(d.p), name, true);
        if (f.kind == K_DNUM) *static_cast<double*>(f.p) = v;
        else *static_cast<int64_t*>(f.p) = (int64_t) v;
        return;
    }
    }
    cabi::badcall("Engine: set('%s', Zahl) auf Knoten %d", name, d.kind);
}
inline void set(Obj& d, const char* name, int v) {
    cabi::Ctx& c = *d.c;
    if (d.kind == K_TRADES) {
        if (eq(name, "fifo_front")) {
            static_cast<cabi::JTrades*>(c.tab[d.i].trades)->fifo_front = v;
            return;
        }
        if (eq(name, "buy_count")) return;   /* Julia: Zahl der Lots = length(buys) */
    }
    set(d, name, (double) v);
}

/* named_list: Ergebnis in den Speicher des Aufrufs (Zahlen der Reihe nach, Vektoren gesondert) */
inline void add(cabi::Result& r, double v) {
    if (r.nnum >= 8) cabi::badcall("Engine: zu viele Werte in named_list");
    r.num[r.nnum++] = v;
}
inline void add(cabi::Result& r, int v) { add(r, (double) v); }
inline void add(cabi::Result& r, const Date& d) { add(r, d.day); }
inline void add(cabi::Result&, const char*) {}
inline void add(cabi::Result& r, const std::vector<int>& v) { r.ivec = v; }
inline void add(cabi::Result& r, const std::vector<double>& v) { r.dvec = v; }
inline void add(cabi::Result& r, const IntVec& v) { r.ivec.assign(v.begin(), v.end()); }
inline void add(cabi::Result& r, const NumVec& v) { r.dvec.assign(v.begin(), v.end()); }
inline void fill(cabi::Result&) {}
template <class T, class... Rest> void fill(cabi::Result& r, const char*, const T& value, const Rest&... rest) {
    add(r, value);
    fill(r, rest...);
}
template <class... Args> Obj named_list(const Args&... args) {
    cabi::Ctx& c = cabi::ctx_store();
    c.res.clear();
    fill(c.res, args...);
    return mk(&c, K_RESULT);
}

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
#define SIMLEV_XLENGTH(x) simlev_host::length(x)
#define SIMLEV_LENGTH(x) simlev_host::length(x)
#define SIMLEV_IS_NULL(x) ((x).kind == cabi::K_NULL)
#define SIMLEV_STRING_AT(v, i) cabi::asset_name(*(v).c, i)
#define SIMLEV_MARK_DATE(v) ((void) 0)

#include "research_core_impl.h"
#include "withdrawal_core_impl.h"
#include "simulation_core_impl.h"
#include "fifo_core_impl.h"
#include "tax_core_impl.h"

/* ===========================================================================
 * Exportierte Funktionen (Praefix simlev_c_). Laengen als int64_t, Matrizen spaltenweise.
 * ========================================================================= */

/* Feldlagen der Julia-Strukturen (Bytes): Status (8), Lot (6), Trades (4), Totals (16),
 * simlev_c_asset (11), jeweils Groesse zuerst; Julia vergleicht beim Laden. Rueckgabe: Anzahl. */
SIMLEV_C_EXPORT int64_t simlev_c_layout(int64_t* out, int64_t n) {
    using namespace cabi;
    const int64_t v[] = {
        (int64_t) sizeof(JStatus),
        (int64_t) sizeof(JLot), (int64_t) offsetof(JLot, date), (int64_t) offsetof(JLot, count),
        (int64_t) offsetof(JLot, price), (int64_t) offsetof(JLot, remaining), (int64_t) offsetof(JLot, original),
        (int64_t) offsetof(JLot, vp),
        (int64_t) offsetof(JTrades, fifo_front),
        (int64_t) sizeof(JTotals), (int64_t) offsetof(JTotals, current_year),
        (int64_t) offsetof(JTotals, cgt_pool_start_ytd), (int64_t) offsetof(JTotals, vp_pending),
        (int64_t) sizeof(simlev_c_asset), (int64_t) offsetof(simlev_c_asset, nbuys)};
    const int64_t m = (int64_t) (sizeof v / sizeof v[0]);
    for (int64_t k = 0; k < n && k < m; k++) out[k] = v[k];
    return m;
}

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
 * (nr, nc), wealth_end (nr, nc), tariff_years (nr, nc). T14: tariff_par/zve wie in R (leer = ohne Tarifweg). */
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

/* ---- Engine: simulation_core_impl.h, fifo_core_impl.h, tax_core_impl.h ----
 * tab: Zeilen je Asset (n), n_days: Laenge der Vektoren; a: Asset (0-basiert); index 1-basiert. */
namespace cabi {
template <class F> int engine(simlev_c_asset* tab, int64_t n, int64_t n_days, F f) {
    Ctx& c = ctx_store();
    c.tab = tab;
    c.n = n;
    c.n_days = n_days;
    c.totals = nullptr;
    c.has_new_lot = false;
    c.day_only = -1;
    c.res.clear();
    const int rc = run(f);
    c.tab = nullptr;
    c.n = 0;
    c.day_only = -1;
    return rc;
}
inline simlev_host::Obj root() { return mk(&ctx_store(), K_ROOT); }
inline simlev_host::Obj names() { return mk(&ctx_store(), K_NAMES); }
inline simlev_host::Obj buys_obj(void** b, int64_t nb) { return mk(&ctx_store(), K_BUYS, nb, b); }
inline const char* asset_name(idx_t i) { return asset_name(ctx_store(), i); }
}  // namespace cabi

SIMLEV_C_EXPORT int simlev_c_sim_dca_flows(simlev_c_asset* tab, int64_t n, int64_t n_days, int64_t a, double flows,
                                           int64_t index) {
    return cabi::engine(tab, n, n_days, [&] {
        simlev::dca_flows_allocation(cabi::root(), cabi::asset_name(a), flows, (int) index);
    });
}

SIMLEV_C_EXPORT int simlev_c_sim_buy_report(simlev_c_asset* tab, int64_t n, int64_t n_days, int64_t a, int64_t index,
                                            double trade_count, double trade_price, double market_price) {
    return cabi::engine(tab, n, n_days, [&] {
        simlev::calculate_buy_report(cabi::root(), cabi::asset_name(a), (int) index, trade_count, trade_price,
                                     market_price);
    });
}

SIMLEV_C_EXPORT int simlev_c_sim_sell_report(simlev_c_asset* tab, int64_t n, int64_t n_days, int64_t a,
                                             int64_t index, double trade_count, double trade_price,
                                             double market_price, double capital_gains_tax) {
    return cabi::engine(tab, n, n_days, [&] {
        simlev::calculate_sell_report(cabi::root(), cabi::asset_name(a), (int) index, trade_count, trade_price,
                                      market_price, capital_gains_tax);
    });
}

SIMLEV_C_EXPORT int simlev_c_sim_total_report(simlev_c_asset* tab, int64_t n, int64_t n_days, int64_t index) {
    return cabi::engine(tab, n, n_days, [&] {
        simlev::calculate_total_report(cabi::root(), cabi::names(), (int) index);
    });
}

/* new_lot[5]: date, count, price, remaining, original des neuen Lots (Julia haengt es an) */
SIMLEV_C_EXPORT int simlev_c_sim_buy(simlev_c_asset* tab, int64_t n, int64_t n_days, int64_t a, int64_t index,
                                     double trade_count, double trade_price, double market_price, double* new_lot) {
    return cabi::engine(tab, n, n_days, [&] {
        cabi::ctx_store().day_only = (cabi::idx_t) index - 1;
        simlev::perform_trade_buy_cpp(cabi::root(), cabi::asset_name(a), (int) index, trade_count, trade_price,
                                      market_price);
        if (!cabi::ctx_store().has_new_lot) cabi::badcall("sim_buy: kein Lot angelegt");
        for (int k = 0; k < 5; k++) new_lot[k] = cabi::ctx_store().new_lot[k];
    });
}

SIMLEV_C_EXPORT int simlev_c_sim_market_update(simlev_c_asset* tab, int64_t n, int64_t n_days, int64_t index) {
    return cabi::engine(tab, n, n_days, [&] {
        simlev::perform_market_update(cabi::root(), cabi::names(), (int) index);
    });
}

SIMLEV_C_EXPORT int simlev_c_sim_market_update_batch(simlev_c_asset* tab, int64_t n, int64_t n_days,
                                                     int64_t start_idx, int64_t end_idx) {
    return cabi::engine(tab, n, n_days, [&] {
        simlev::batch_market_update(cabi::root(), cabi::names(), (int) start_idx, (int) end_idx);
    });
}

SIMLEV_C_EXPORT int simlev_c_sim_fifo_price(void** buys, int64_t nbuys, double units, int64_t front, double* out) {
    return cabi::engine(nullptr, 0, 0, [&] {
        *out = simlev::calculate_fifo_price(cabi::buys_obj(buys, nbuys), units, (int) front);
    });
}

SIMLEV_C_EXPORT int simlev_c_sim_fifo_vp(void** buys, int64_t nbuys, double units, int64_t front, double* out) {
    return cabi::engine(nullptr, 0, 0, [&] {
        *out = simlev::calculate_fifo_vp(cabi::buys_obj(buys, nbuys), units, (int) front);
    });
}

/* out[5]: exempt_gain, exempt_loss, taxable_gain, taxable_loss, total_gain */
SIMLEV_C_EXPORT int simlev_c_sim_private_sale_tax(void** buys, int64_t nbuys, int64_t front, double trade_count,
                                                  double sell_price, int64_t current_date, double* out) {
    return cabi::engine(nullptr, 0, 0, [&] {
        simlev::calculate_private_sale_tax(cabi::buys_obj(buys, nbuys), (int) front, trade_count, sell_price,
                                           (int) current_date);
        const cabi::Result& r = cabi::ctx_store().res;
        if (r.nnum != 5) cabi::badcall("sim_private_sale_tax: unerwartetes Ergebnis");
        for (int k = 0; k < 5; k++) out[k] = r.num[k];
    });
}

SIMLEV_C_EXPORT int simlev_c_sim_fifo_consume(simlev_c_asset* tab, int64_t n, int64_t a, double trade_count) {
    return cabi::engine(tab, n, 0, [&] {
        simlev::fifo_consume(cabi::root(), cabi::asset_name(a), trade_count);
    });
}

/* Ergebnis: *total; Indizes (1-basiert) und Betraege der aktiven Lots in idx/vps (Platz fuer
 * nbuys - front + 1 Werte), *nact Anzahl */
SIMLEV_C_EXPORT int simlev_c_sim_flat_rate(void** buys, int64_t nbuys, int64_t front, double base_rate,
                                           double year_start_price, double market_price, int64_t soy, int64_t eoy,
                                           double* total, int64_t* idx, double* vps, int64_t cap, int64_t* nact) {
    return cabi::engine(nullptr, 0, 0, [&] {
        simlev::flat_rate(cabi::buys_obj(buys, nbuys), (int) front, base_rate, year_start_price, market_price,
                          (int) soy, (int) eoy);
        const cabi::Result& r = cabi::ctx_store().res;
        const cabi::idx_t k = (cabi::idx_t) r.ivec.size();
        if (r.nnum != 1 || (cabi::idx_t) r.dvec.size() != k || k > cap) cabi::badcall("sim_flat_rate: unerwartetes Ergebnis");
        *total = r.num[0];
        for (cabi::idx_t j = 0; j < k; j++) {
            idx[j] = r.ivec[(std::size_t) j];
            vps[j] = r.dvec[(std::size_t) j];
        }
        *nact = k;
    });
}

/* out: tax, spb_used */
SIMLEV_C_EXPORT int simlev_c_sim_p20_tax(double trade_gain, double bonus, void* totals, double tax_rate, int use_spb,
                                         double* out) {
    return cabi::engine(nullptr, 0, 0, [&] {
        simlev::p20_tax(trade_gain, bonus, cabi::mk(&cabi::ctx_store(), cabi::K_TOTALS, 0, totals), tax_rate, use_spb != 0);
        const cabi::Result& r = cabi::ctx_store().res;
        if (r.nnum != 2) cabi::badcall("sim_p20_tax: unerwartetes Ergebnis");
        out[0] = r.num[0];
        out[1] = r.num[1];
    });
}

/* out: tax, spb_used, taxable_amount */
SIMLEV_C_EXPORT int simlev_c_sim_vp_tax(double flat_rate, double bonus, void* totals, double tax_rate, int use_spb,
                                        double* out) {
    return cabi::engine(nullptr, 0, 0, [&] {
        simlev::vp_tax(flat_rate, bonus, cabi::mk(&cabi::ctx_store(), cabi::K_TOTALS, 0, totals), tax_rate, use_spb != 0);
        const cabi::Result& r = cabi::ctx_store().res;
        if (r.nnum != 3) cabi::badcall("sim_vp_tax: unerwartetes Ergebnis");
        for (int k = 0; k < 3; k++) out[k] = r.num[k];
    });
}

/* out: sell_count, fifo_price */
SIMLEV_C_EXPORT int simlev_c_sim_sell_count(void** buys, int64_t nbuys, int64_t front, double target,
                                            double trade_price, double total_shares, int fractions, int64_t regime,
                                            double bonus, double loss_pool, double tax_rate, double* out) {
    return cabi::engine(nullptr, 0, 0, [&] {
        simlev::sell_count(cabi::buys_obj(buys, nbuys), (int) front, target, trade_price, total_shares,
                           fractions != 0, (int) regime, bonus, loss_pool, tax_rate);
        const cabi::Result& r = cabi::ctx_store().res;
        if (r.nnum != 2) cabi::badcall("sim_sell_count: unerwartetes Ergebnis");
        out[0] = r.num[0];
        out[1] = r.num[1];
    });
}

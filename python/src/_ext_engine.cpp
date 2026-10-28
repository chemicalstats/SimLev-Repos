/*
 * python/src/_ext_engine.cpp -- Python-Huelle der Engine-Kerne (simulation_core, fifo_core, tax_core)
 *
 * Etappe 7.3a. Gemeinsame Kerne mit R (r/src/simulation_core_impl.h, fifo_core_impl.h,
 * tax_core_impl.h, Kopien hier). Die Kerne arbeiten auf dem Simulationszustand des
 * Hosts; diese Datei stellt den Python-Host: simlev_host::Obj ist PyObject*, und die
 * Zugriffe (as_list, at, get, set, put, has, as_double, as_int, num_vec, named_list,
 * new_num, new_int, Date; SIMLEV_XLENGTH, SIMLEV_LENGTH, SIMLEV_IS_NULL,
 * SIMLEV_STRING_AT, SIMLEV_MARK_DATE) arbeiten auf der dict/list-Struktur sim aus
 * simlev/_sim_phases.py so, wie sl:: in r/src/simlev_capi.h auf sim_mem:
 *
 *   at(x, i), put(x, i, v)  dict: i-ter Eintrag (Reihenfolge der Schluessel wie
 *                           .SIM_MEM_LAYOUT: assets, status, market, trades, report,
 *                           totals); list: i-tes Element, put mit i == len haengt an
 *   get(d, name)            dict-Eintrag; fehlt er: KeyError wie der reine Python-Kern
 *   set(d, name, v)         dict-Eintrag setzen (Zahlen als float/int, Vektoren als
 *                           dasselbe Objekt, Datum als int)
 *   num_vec(x)              float64-Puffer (numpy-Array) als Sicht, Schreiben in place;
 *                           andere Puffer (asset_day int64) als Kopie wie die Umwandlung
 *                           in R
 *   named_list(...)         neues dict (Reihenfolge wie in R)
 *
 * Die Huellen pruefen vor dem Aufruf, dass die Tagesindizes in allen Feldern liegen, die
 * der Kern liest oder schreibt (IndexError statt Zugriff ausserhalb des Feldes; R prueft
 * nicht); at() und put() pruefen selbst. Die Kerne laufen mit gehaltener GIL (sie greifen auf
 * Python-Objekte zu); sie pruefen keinen Benutzerabbruch (wie in R). Fehler der
 * Zugriffe sind die Python-Ausnahmen (KeyError, IndexError, TypeError), wie sie auch
 * der reine Python-Kern (simlev/_core.py) wirft.
 *
 * Aufbau wie der R-Host, damit der Compiler die eingebetteten Kerne moeglichst wie in R
 * uebersetzt: Sichten ohne Bereichspruefung, wrap(double) legt erst das Objekt an und
 * traegt dann den Wert ein, set(Obj&, name, Obj) ist nicht eingebettet, die Huellen
 * wandeln die Argumente in derselben Reihenfolge um wie die .Call-Huellen. Das Ergebnis
 * ist bitgleich zu R (Referenz- und Golden-Faelle, Zufallsvergleich); einzige bekannte
 * Ausnahme: treffen in einer Operation zwei NaN mit verschiedener Nutzlast zusammen (NA
 * und NaN), kann Python die Nutzlast des anderen Operanden behalten als R (welcher
 * Operand bleibt, haengt auf x86-64 von der Registerbelegung ab; Wert in beiden Faellen
 * NA bzw. NaN, wie beim reinen Python-Kern).
 *
 *   sim_dca_flows(sim, name, flows, index)
 *   sim_buy_report(sim, name, index, trade_count, trade_price, market_price)
 *   sim_sell_report(sim, name, index, trade_count, trade_price, market_price, capital_gains_tax)
 *   sim_total_report(sim, assets, index)
 *   sim_buy(sim, name, index, trade_count, trade_price, market_price)
 *   sim_market_update(sim, assets, index)
 *   sim_market_update_batch(sim, assets, start_idx, end_idx)
 *   sim_fifo_price(buys, units, front_index) -> float
 *   sim_fifo_vp(buys, units, front_index) -> float
 *   sim_private_sale_tax(buys, front_index, trade_count, sell_price, current_date) -> dict
 *   sim_fifo_consume(sim, name, trade_count)
 *   sim_flat_rate(buys, front_index, base_rate, year_start_price, market_price, soy_days,
 *                 eoy_days) -> dict
 *   sim_p20_tax(trade_gain, bonus, totals, tax_rate, use_spb) -> dict
 *   sim_vp_tax(flat_rate, bonus, totals, tax_rate, use_spb) -> dict
 *   sim_sell_count(buys, front_index, target, trade_price, total_shares, fractions, regime,
 *                  bonus, loss_pool, tax_rate) -> dict
 */
#define SIMLEV_EXT_ENGINE 1
#include "_ext_common.h"

#include <cstdint>
#include <string>

#if defined(__GNUC__)
#define SLX_NOINLINE __attribute__((noinline))
#define SLX_INLINE __attribute__((always_inline)) inline
#elif defined(_MSC_VER)
#define SLX_NOINLINE __declspec(noinline)
#define SLX_INLINE __forceinline
#else
#define SLX_NOINLINE
#define SLX_INLINE inline
#endif

namespace ext {
namespace eng {

/* Speicher eines Kernaufrufs: Puffer, neue Objekte (Referenzen), Kopien */
struct State {
    std::deque<Buf> bufs;
    std::vector<PyObject*> refs;
    std::deque<std::vector<double>> nums;
    std::deque<std::vector<int>> ints;
    ~State() {
        for (PyObject* o : refs) Py_DECREF(o);
    }
};
inline State*& current() {
    static thread_local State* s = nullptr;
    return s;
}
/* je Aufruf ein eigener Speicher (auch bei verschachtelten Aufrufen) */
struct Scope {
    State st;
    State* prev;
    Scope() : prev(current()) { current() = &st; }
    ~Scope() { current() = prev; }
};
inline State& state() { return *current(); }

[[noreturn]] inline void raise() { throw PyErrorSet(); }
[[noreturn]] inline void raise(PyObject* type, const char* msg) {
    PyErr_SetString(type, msg);
    throw PyErrorSet();
}
[[noreturn]] inline void index_error() { raise(PyExc_IndexError, "index out of range"); }

/* Sicht wie ext::VecT bzw. sl::Vec (ohne Bereichspruefung wie in R; die Huellen pruefen
 * die Indizes vorher, siehe need()). sexp: Python-Objekt der Sicht (geliehen) oder nullptr
 * bei einer Kopie. Gleicher Aufbau wie in R, damit der Compiler die Schleifen der Kerne
 * wie dort uebersetzt. */
template <class T> struct CVec {
    void* sexp;
    T* ptr;
    Py_ssize_t len;
    T& operator[](Py_ssize_t i) const { return ptr[i]; }
    Py_ssize_t size() const { return len; }
    T* begin() const { return ptr; }
    T* end() const { return ptr + len; }
};

}  // namespace eng
}  // namespace ext

/* ---------------------------------------------------------------------------
 * Python als Host der Engine-Kerne (Gegenstueck zu sl:: in r/src/simlev_capi.h)
 * ------------------------------------------------------------------------- */
namespace simlev_host {

typedef PyObject* Obj;
typedef ext::eng::CVec<double> NumVec;
typedef ext::eng::CVec<int> IntVec;
struct Date { double day; };   /* Tage seit 1970-01-01 */

using ext::eng::raise;

inline Py_ssize_t length(Obj x) {
    const Py_ssize_t n = PyObject_Length(x);
    if (n < 0) raise();
    return n;
}

inline Obj as_list(Obj x) {
    if (PyDict_Check(x) || PyList_Check(x) || PyTuple_Check(x)) return x;
    if (x == Py_None) {   /* as.list(NULL) = list() */
        PyObject* l = PyList_New(0);
        if (!l) raise();
        ext::eng::state().refs.push_back(l);
        return l;
    }
    PyErr_Format(PyExc_TypeError, "expected dict or list, got %s", Py_TYPE(x)->tp_name);
    raise();
}

/* i-ter Eintrag eines dict (Reihenfolge der Schluessel) */
inline bool dict_entry(Obj d, Py_ssize_t i, PyObject** key, PyObject** value) {
    if (i < 0 || i >= PyDict_Size(d)) return false;
    Py_ssize_t pos = 0, k = 0;
    while (PyDict_Next(d, &pos, key, value)) {
        if (k == i) return true;
        ++k;
    }
    return false;
}

inline Obj at(Obj x, Py_ssize_t i) {
    if (PyList_Check(x)) {
        if (i < 0 || i >= PyList_GET_SIZE(x)) ext::eng::index_error();
        return PyList_GET_ITEM(x, i);
    }
    if (PyTuple_Check(x)) {
        if (i < 0 || i >= PyTuple_GET_SIZE(x)) ext::eng::index_error();
        return PyTuple_GET_ITEM(x, i);
    }
    if (PyDict_Check(x)) {
        PyObject *k, *v;
        if (!dict_entry(x, i, &k, &v)) ext::eng::index_error();
        return v;
    }
    PyErr_Format(PyExc_TypeError, "expected dict or list, got %s", Py_TYPE(x)->tp_name);
    raise();
}

inline void put(Obj x, Py_ssize_t i, Obj value) {
    if (PyList_Check(x)) {
        const Py_ssize_t n = PyList_GET_SIZE(x);
        if (i >= 0 && i < n) {
            if (PyList_GET_ITEM(x, i) == value) return;
            Py_INCREF(value);
            PyList_SetItem(x, i, value);
            return;
        }
        if (i == n) {
            if (PyList_Append(x, value) < 0) raise();
            return;
        }
        ext::eng::index_error();
    }
    if (PyDict_Check(x)) {
        PyObject *k, *v;
        if (!dict_entry(x, i, &k, &v)) ext::eng::index_error();
        if (v == value) return;
        Py_INCREF(k);
        const int rc = PyDict_SetItem(x, k, value);
        Py_DECREF(k);
        if (rc < 0) raise();
        return;
    }
    PyErr_Format(PyExc_TypeError, "expected dict or list, got %s", Py_TYPE(x)->tp_name);
    raise();
}

inline bool has(Obj d, const char* name) {
    return PyDict_Check(d) && PyDict_GetItemString(d, name) != nullptr;
}

inline Obj get(Obj d, const char* name) {
    if (!PyDict_Check(d)) {
        PyErr_Format(PyExc_TypeError, "expected dict, got %s", Py_TYPE(d)->tp_name);
        raise();
    }
    PyObject* v = PyDict_GetItemString(d, name);
    if (!v) {
        PyObject* key = PyUnicode_FromString(name);
        if (key) {
            PyErr_SetObject(PyExc_KeyError, key);
            Py_DECREF(key);
        }
        raise();
    }
    return v;
}

inline double as_double(Obj x) {
    if (PyFloat_Check(x)) return PyFloat_AS_DOUBLE(x);
    const double v = PyFloat_AsDouble(x);
    if (v == -1.0 && PyErr_Occurred()) raise();
    return v;
}

inline int as_int(Obj x) {
    if (PyFloat_Check(x)) {   /* Umwandlung double -> int wie in R (abschneiden) */
        const double d = PyFloat_AS_DOUBLE(x);
        if (!(d > (double) INT_MIN - 1.0 && d < (double) INT_MAX + 1.0))
            ext::eng::raise(PyExc_OverflowError, "value out of int range");
        return (int) d;
    }
    PyObject* i = PyNumber_Index(x);
    if (!i) raise();
    const long v = PyLong_AsLong(i);
    Py_DECREF(i);
    if (v == -1 && PyErr_Occurred()) raise();
    if (v < INT_MIN || v > INT_MAX) ext::eng::raise(PyExc_OverflowError, "value out of int range");
    return (int) v;
}

/* Puffer als Sicht (float64, beschreibbar) bzw. als Kopie (andere Typen, nur lesbar) */
inline NumVec num_vec(Obj x) {
    ext::eng::State& st = ext::eng::state();
    st.bufs.emplace_back();
    ext::Buf& b = st.bufs.back();
    if (PyObject_GetBuffer(x, &b.view, PyBUF_C_CONTIGUOUS | PyBUF_FORMAT | PyBUF_WRITABLE) == 0) {
        b.held = true;
        const char* f = b.view.format ? b.view.format : "B";
        if (b.view.itemsize == (Py_ssize_t) sizeof(double) && ext::is_double_format(f)) {
            NumVec v = {x, static_cast<double*>(b.view.buf), b.view.len / b.view.itemsize};
            return v;
        }
    } else {
        PyErr_Clear();
        if (PyObject_GetBuffer(x, &b.view, PyBUF_C_CONTIGUOUS | PyBUF_FORMAT) == 0)
            b.held = true;
        else
            PyErr_Clear();
    }
    st.nums.emplace_back();
    std::vector<double>& c = st.nums.back();
    if (b.held) {
        const char* f = b.view.format ? b.view.format : "B";
        const char t = f[0] == '<' || f[0] == '=' || f[0] == '@' ? f[1] : f[0];
        const Py_ssize_t n = b.view.len / b.view.itemsize, sz = b.view.itemsize;
        c.resize((std::size_t) n);
        const char* p = static_cast<const char*>(b.view.buf);
        bool ok = true;
        for (Py_ssize_t k = 0; k < n && ok; k++) {
            const char* e = p + k * sz;
            if ((t == 'q' || t == 'l') && sz == 8) { int64_t v; std::memcpy(&v, e, 8); c[(std::size_t) k] = (double) v; }
            else if ((t == 'i' || t == 'l') && sz == 4) { int32_t v; std::memcpy(&v, e, 4); c[(std::size_t) k] = (double) v; }
            else if (t == 'd' && sz == 8) { double v; std::memcpy(&v, e, 8); c[(std::size_t) k] = v; }
            else if (t == 'f' && sz == 4) { float v; std::memcpy(&v, e, 4); c[(std::size_t) k] = (double) v; }
            else ok = false;
        }
        if (!ok) {
            PyErr_Format(PyExc_TypeError, "unsupported buffer format '%s'", f);
            raise();
        }
    } else {   /* Folge von Zahlen */
        PyObject* seq = PySequence_Fast(x, "expected a numeric vector");
        if (!seq) raise();
        const Py_ssize_t n = PySequence_Fast_GET_SIZE(seq);
        c.resize((std::size_t) n);
        for (Py_ssize_t k = 0; k < n; k++) {
            const double v = PyFloat_AsDouble(PySequence_Fast_GET_ITEM(seq, k));
            if (v == -1.0 && PyErr_Occurred()) {
                Py_DECREF(seq);
                raise();
            }
            c[(std::size_t) k] = v;
        }
        Py_DECREF(seq);
    }
    NumVec v = {nullptr, c.data(), (Py_ssize_t) c.size()};
    return v;
}

inline NumVec new_num(Py_ssize_t n, double fill = 0.0) {
    ext::eng::state().nums.emplace_back((std::size_t) n, fill);
    std::vector<double>& c = ext::eng::state().nums.back();
    NumVec v = {nullptr, c.data(), n};
    return v;
}
inline IntVec new_int(Py_ssize_t n, int fill = 0) {
    ext::eng::state().ints.emplace_back((std::size_t) n, fill);
    std::vector<int>& c = ext::eng::state().ints.back();
    IntVec v = {nullptr, c.data(), n};
    return v;
}

/* wrap(): Werte als neue Python-Objekte (neue Referenz) */
/* wie sl::wrap(double) in R: erst das Objekt anlegen, dann den Wert eintragen (der Wert
 * ueberdauert den Aufruf; so uebersetzt der Compiler die Rechnung davor wie in R) */
SLX_INLINE PyObject* wrap(double v) {
    PyObject* x = PyFloat_FromDouble(0.0);
    if (x) reinterpret_cast<PyFloatObject*>(x)->ob_fval = v;
    return x;
}
inline PyObject* wrap(int v) { return PyLong_FromLong(v); }
inline PyObject* wrap(bool v) { return PyBool_FromLong(v ? 1 : 0); }
inline PyObject* wrap(const char* s) { return PyUnicode_FromString(s); }
inline PyObject* wrap(Obj x) { Py_INCREF(x); return x; }
inline PyObject* wrap(const Date& d) {
    if (!std::isfinite(d.day)) ext::eng::raise(PyExc_ValueError, "date is not finite");
    return PyLong_FromLongLong((long long) d.day);
}
inline PyObject* wrap(const NumVec& v) {
    if (v.sexp) {
        PyObject* o = static_cast<PyObject*>(v.sexp);
        Py_INCREF(o);
        return o;
    }
    PyObject* l = PyList_New(v.len);
    if (!l) return nullptr;
    for (Py_ssize_t k = 0; k < v.len; k++) {
        PyObject* f = PyFloat_FromDouble(v.ptr[k]);
        if (!f) { Py_DECREF(l); return nullptr; }
        PyList_SET_ITEM(l, k, f);
    }
    return l;
}
inline PyObject* wrap(const IntVec& v) {
    PyObject* l = PyList_New(v.len);
    if (!l) return nullptr;
    for (Py_ssize_t k = 0; k < v.len; k++) {
        PyObject* f = PyLong_FromLong(v.ptr[k]);
        if (!f) { Py_DECREF(l); return nullptr; }
        PyList_SET_ITEM(l, k, f);
    }
    return l;
}
inline PyObject* wrap(const std::vector<double>& v) {
    PyObject* l = PyList_New((Py_ssize_t) v.size());
    if (!l) return nullptr;
    for (std::size_t k = 0; k < v.size(); k++) {
        PyObject* f = PyFloat_FromDouble(v[k]);
        if (!f) { Py_DECREF(l); return nullptr; }
        PyList_SET_ITEM(l, (Py_ssize_t) k, f);
    }
    return l;
}
inline PyObject* wrap(const std::vector<int>& v) {
    PyObject* l = PyList_New((Py_ssize_t) v.size());
    if (!l) return nullptr;
    for (std::size_t k = 0; k < v.size(); k++) {
        PyObject* f = PyLong_FromLong(v[k]);
        if (!f) { Py_DECREF(l); return nullptr; }
        PyList_SET_ITEM(l, (Py_ssize_t) k, f);
    }
    return l;
}

inline void set_item(Obj d, const char* name, PyObject* v) {
    if (!PyDict_Check(d)) {
        PyErr_Format(PyExc_TypeError, "expected dict, got %s", Py_TYPE(d)->tp_name);
        raise();
    }
    if (PyDict_GetItemString(d, name) == v) return;
    if (PyDict_SetItemString(d, name, v) < 0) raise();
}
/* list[name] = value (dict in place; R: sl::set). Aufbau wie in R: set(Obj&, name, Obj)
 * nicht eingebettet, set(Obj&, name, T) bettet wrap() ein und ruft es auf. */
SLX_NOINLINE inline void set(Obj& d, const char* name, Obj v) { set_item(d, name, v); }
/* uebernimmt die Referenz o (neues Objekt aus wrap) */
SLX_NOINLINE inline void set_new(Obj& d, const char* name, PyObject* o) {
    if (!o) raise();
    if (!PyDict_Check(d)) {
        Py_DECREF(o);
        PyErr_Format(PyExc_TypeError, "expected dict, got %s", Py_TYPE(d)->tp_name);
        raise();
    }
    if (PyDict_GetItemString(d, name) == o) {
        Py_DECREF(o);
        return;
    }
    const int rc = PyDict_SetItemString(d, name, o);
    Py_DECREF(o);
    if (rc < 0) raise();
}
template <class T> SLX_INLINE void set(Obj& d, const char* name, const T& value) {
    set_new(d, name, wrap(value));
}

namespace detail {
inline void fill(PyObject*) {}
template <class T, class... Rest> void fill(PyObject* d, const char* name, const T& value, const Rest&... rest) {
    PyObject* o = wrap(value);
    if (!o) raise();
    const int rc = PyDict_SetItemString(d, name, o);
    Py_DECREF(o);
    if (rc < 0) raise();
    fill(d, rest...);
}
}  // namespace detail

/* List::create(Named(n1) = v1, ...): neues dict in dieser Reihenfolge */
template <class... Args> Obj named_list(const Args&... args) {
    PyObject* d = PyDict_New();
    if (!d) raise();
    ext::eng::state().refs.push_back(d);
    detail::fill(d, args...);
    return d;
}

inline const char* string_at(Obj v, Py_ssize_t i) {
    PyObject* s = at(v, i);
    if (!PyUnicode_Check(s)) {
        PyErr_Format(PyExc_TypeError, "expected str, got %s", Py_TYPE(s)->tp_name);
        raise();
    }
    const char* c = PyUnicode_AsUTF8(s);
    if (!c) raise();
    return c;
}

}  // namespace simlev_host

#define SIMLEV_XLENGTH(x) simlev_host::length(x)
#define SIMLEV_LENGTH(x) simlev_host::length(x)
#define SIMLEV_IS_NULL(x) ((x) == Py_None)
#define SIMLEV_STRING_AT(v, i) simlev_host::string_at(v, i)
#define SIMLEV_MARK_DATE(v) ((void) 0)   /* Python: asset_day bleibt eine Zahl (int) */

#include "simulation_core_impl.h"
#include "fifo_core_impl.h"
#include "tax_core_impl.h"

namespace {

using simlev_host::Obj;

/* Vorpruefung der Huellen: sim[part][name][field] hat mindestens hi Elemente und lo >= 1
 * (part: Position in sim wie .SIM_MEM_LAYOUT). Fehlen Teile, meldet das erst der Kern
 * (KeyError wie der reine Python-Kern). */
bool need_one(PyObject* sim, Py_ssize_t part, const char* name, const char* field, long lo, long hi) {
    if (!PyDict_Check(sim)) return true;
    PyObject *k, *p;
    if (!simlev_host::dict_entry(sim, part, &k, &p) || !PyDict_Check(p)) return true;
    PyObject* a = PyDict_GetItemString(p, name);
    if (!a || !PyDict_Check(a)) return true;
    PyObject* f = PyDict_GetItemString(a, field);
    if (!f) return true;
    const Py_ssize_t n = PyObject_Length(f);
    if (n < 0) return false;
    if (lo < 1 || hi > (long) n) {
        PyErr_Format(PyExc_IndexError, "index %ld out of range for '%s' of '%s' (length %zd)", lo < 1 ? lo : hi,
                     field, name, n);
        return false;
    }
    return true;
}
const char* const REPORT4[] = {"worth", "money", "total", "share"};
const char* const REPORT5[] = {"worth", "money", "flows", "total", "share"};
const char* const REPORT3[] = {"worth", "money", "total"};

template <std::size_t N>
bool need(PyObject* sim, const char* name, const char* const (&rep)[N], long lo, long hi, bool price, bool day = false) {
    if (!name) return false;   /* PyUnicode_AsUTF8 fehlgeschlagen (Fehler gesetzt) */
    for (const char* f : rep)
        if (!need_one(sim, 4, name, f, lo, hi)) return false;
    if (price && !need_one(sim, 2, name, "asset_price", lo, hi)) return false;
    if (day && !need_one(sim, 2, name, "asset_day", lo, hi)) return false;
    return true;
}
/* fuer alle Namen in assets (Liste von str) */
template <std::size_t N>
bool need_all(PyObject* sim, PyObject* assets, const char* const (&rep)[N], long lo, long hi) {
    if (!PyList_Check(assets) && !PyTuple_Check(assets)) return true;
    const Py_ssize_t n = PySequence_Fast_GET_SIZE(assets);
    for (Py_ssize_t i = 0; i < n; i++) {
        PyObject* s = PySequence_Fast_GET_ITEM(assets, i);
        if (!PyUnicode_Check(s)) continue;
        const char* c = PyUnicode_AsUTF8(s);
        if (!c) return false;
        if (!need(sim, c, rep, lo, hi, true)) return false;
    }
    return true;
}
const char* const FLOWS[] = {"flows", "money", "total"};

inline PyObject* sim_of(PyObject* x) { return x; }
/* Fehler der Vorpruefung (gesetzt) bzw. falscher Typ von name */
inline PyObject* arg_error() {
    if (!PyErr_Occurred()) PyErr_SetString(PyExc_TypeError, "name must be str");
    return nullptr;
}

/* Kern mit gehaltener GIL ausfuehren; Ergebnis (neue Referenz) bzw. None */
template <class F> PyObject* call_void(F f) {
    ext::eng::Scope sc;
    if (!ext::run(f, false)) return nullptr;
    Py_RETURN_NONE;
}
template <class F> PyObject* call_obj(F f) {
    ext::eng::Scope sc;
    PyObject* res = nullptr;
    if (!ext::run([&] { res = f(); Py_INCREF(res); }, false)) return nullptr;
    return res;
}
template <class F> PyObject* call_double(F f) {
    ext::eng::Scope sc;
    double res = 0.0;
    if (!ext::run([&] { res = f(); }, false)) return nullptr;
    return PyFloat_FromDouble(res);
}

/* Tagesindex fuer die Vorpruefung (die Huelle wandelt ihn danach wie R noch einmal um) */
bool index_arg(PyObject* o, int* v) { return PyArg_Parse(o, "i", v) != 0; }

}  // namespace

/* Umwandlung der Argumente wie die .Call-Huellen in R (sl::as_list, as_rstring, as_double,
 * as_int, as_bool, as_character, in derselben Reihenfolge, damit der Compiler den
 * eingebetteten Kern gleich uebersetzt) */
namespace simlev_host {
inline const char* as_rstring(Obj x) {
    if (!PyUnicode_Check(x)) {
        PyErr_Format(PyExc_TypeError, "expected str, got %s", Py_TYPE(x)->tp_name);
        raise();
    }
    const char* c = PyUnicode_AsUTF8(x);
    if (!c) raise();
    return c;
}
inline const char* as_cstring(Obj x) { return as_rstring(x); }
inline bool as_bool(Obj x) {
    const int b = PyObject_IsTrue(x);
    if (b < 0) raise();
    return b != 0;
}
inline Obj as_character(Obj x) {
    if (PyList_Check(x) || PyTuple_Check(x)) return x;
    PyErr_Format(PyExc_TypeError, "expected list of str, got %s", Py_TYPE(x)->tp_name);
    raise();
}
}  // namespace simlev_host

namespace {

namespace sl = simlev_host;

PyObject* e_dca(PyObject*, PyObject* a) {
    PyObject *s_input, *s_name, *s_flows, *s_index;
    if (!PyArg_UnpackTuple(a, "sim_dca_flows", 4, 4, &s_input, &s_name, &s_flows, &s_index)) return nullptr;
    int ix;
    if (!index_arg(s_index, &ix) || !PyUnicode_Check(s_name) || !need(sim_of(s_input), PyUnicode_AsUTF8(s_name), FLOWS, ix, ix, false))
        return arg_error();
    return call_void([&]() {
        Obj input = sl::as_list(s_input);
        const char* name = sl::as_rstring(s_name);
        double flows = sl::as_double(s_flows);
        int index = sl::as_int(s_index);
        simlev::dca_flows_allocation(input, name, flows, index);
    });
}

PyObject* e_buy_report(PyObject*, PyObject* a) {
    PyObject *s_input, *s_name, *s_index, *s_trade_count, *s_trade_price, *s_market_price;
    if (!PyArg_UnpackTuple(a, "sim_buy_report", 6, 6, &s_input, &s_name, &s_index, &s_trade_count, &s_trade_price,
                           &s_market_price))
        return nullptr;
    int ix;
    if (!index_arg(s_index, &ix) || !PyUnicode_Check(s_name) || !need(sim_of(s_input), PyUnicode_AsUTF8(s_name), REPORT3, ix, ix, false))
        return arg_error();
    return call_void([&]() {
        Obj input = sl::as_list(s_input);
        const char* name = sl::as_rstring(s_name);
        int index = sl::as_int(s_index);
        double trade_count = sl::as_double(s_trade_count);
        double trade_price = sl::as_double(s_trade_price);
        double market_price = sl::as_double(s_market_price);
        simlev::calculate_buy_report(input, name, index, trade_count, trade_price, market_price);
    });
}

PyObject* e_sell_report(PyObject*, PyObject* a) {
    PyObject *s_input, *s_name, *s_index, *s_trade_count, *s_trade_price, *s_market_price, *s_capital_gains_tax;
    if (!PyArg_UnpackTuple(a, "sim_sell_report", 7, 7, &s_input, &s_name, &s_index, &s_trade_count, &s_trade_price,
                           &s_market_price, &s_capital_gains_tax))
        return nullptr;
    int ix;
    if (!index_arg(s_index, &ix) || !PyUnicode_Check(s_name) || !need(sim_of(s_input), PyUnicode_AsUTF8(s_name), REPORT3, ix, ix, false))
        return arg_error();
    return call_void([&]() {
        Obj input = sl::as_list(s_input);
        const char* name = sl::as_rstring(s_name);
        int index = sl::as_int(s_index);
        double trade_count = sl::as_double(s_trade_count);
        double trade_price = sl::as_double(s_trade_price);
        double market_price = sl::as_double(s_market_price);
        double capital_gains_tax = sl::as_double(s_capital_gains_tax);
        simlev::calculate_sell_report(input, name, index, trade_count, trade_price, market_price, capital_gains_tax);
    });
}

PyObject* e_total_report(PyObject*, PyObject* a) {
    PyObject *s_input, *s_assets, *s_index;
    if (!PyArg_UnpackTuple(a, "sim_total_report", 3, 3, &s_input, &s_assets, &s_index)) return nullptr;
    int ix;
    if (!index_arg(s_index, &ix) || !need_all(sim_of(s_input), s_assets, REPORT4, ix, ix)) return arg_error();
    return call_void([&]() {
        Obj input = sl::as_list(s_input);
        Obj assets = sl::as_character(s_assets);
        int index = sl::as_int(s_index);
        simlev::calculate_total_report(input, assets, index);
    });
}

PyObject* e_buy(PyObject*, PyObject* a) {
    PyObject *s_input, *s_name, *s_index, *s_trade_count, *s_trade_price, *s_market_price;
    if (!PyArg_UnpackTuple(a, "sim_buy", 6, 6, &s_input, &s_name, &s_index, &s_trade_count, &s_trade_price,
                           &s_market_price))
        return nullptr;
    int ix;
    if (!index_arg(s_index, &ix) || !PyUnicode_Check(s_name) ||
        !need(sim_of(s_input), PyUnicode_AsUTF8(s_name), REPORT3, ix, ix, false, true))
        return arg_error();
    return call_void([&]() {
        Obj input = sl::as_list(s_input);
        const char* name = sl::as_rstring(s_name);
        int index = sl::as_int(s_index);
        double trade_count = sl::as_double(s_trade_count);
        double trade_price = sl::as_double(s_trade_price);
        double market_price = sl::as_double(s_market_price);
        simlev::perform_trade_buy_cpp(input, name, index, trade_count, trade_price, market_price);
    });
}

PyObject* e_market_update(PyObject*, PyObject* a) {
    PyObject *s_input, *s_assets, *s_index;
    if (!PyArg_UnpackTuple(a, "sim_market_update", 3, 3, &s_input, &s_assets, &s_index)) return nullptr;
    int ix;
    if (!index_arg(s_index, &ix) || !need_all(sim_of(s_input), s_assets, REPORT5, ix, ix)) return arg_error();
    return call_void([&]() {
        Obj input = sl::as_list(s_input);
        Obj assets = sl::as_character(s_assets);
        int index = sl::as_int(s_index);
        simlev::perform_market_update(input, assets, index);
    });
}

PyObject* e_market_update_batch(PyObject*, PyObject* a) {
    PyObject *s_input, *s_assets, *s_start_idx, *s_end_idx;
    if (!PyArg_UnpackTuple(a, "sim_market_update_batch", 4, 4, &s_input, &s_assets, &s_start_idx, &s_end_idx))
        return nullptr;
    int s0, e0;
    if (!index_arg(s_start_idx, &s0) || !index_arg(s_end_idx, &e0) ||
        (e0 >= s0 && !need_all(sim_of(s_input), s_assets, REPORT5, s0, e0)))
        return arg_error();
    return call_void([&]() {
        Obj input = sl::as_list(s_input);
        Obj assets = sl::as_character(s_assets);
        int start_idx = sl::as_int(s_start_idx);
        int end_idx = sl::as_int(s_end_idx);
        simlev::batch_market_update(input, assets, start_idx, end_idx);
    });
}

PyObject* e_fifo_price(PyObject*, PyObject* a) {
    PyObject *s_buys, *s_units, *s_front_index;
    if (!PyArg_UnpackTuple(a, "sim_fifo_price", 3, 3, &s_buys, &s_units, &s_front_index)) return nullptr;
    return call_double([&]() {
        Obj buys = sl::as_list(s_buys);
        double units = sl::as_double(s_units);
        int front_index = sl::as_int(s_front_index);
        return simlev::calculate_fifo_price(buys, units, front_index);
    });
}

PyObject* e_fifo_vp(PyObject*, PyObject* a) {
    PyObject *s_buys, *s_units, *s_front_index;
    if (!PyArg_UnpackTuple(a, "sim_fifo_vp", 3, 3, &s_buys, &s_units, &s_front_index)) return nullptr;
    return call_double([&]() {
        Obj buys = sl::as_list(s_buys);
        double units = sl::as_double(s_units);
        int front_index = sl::as_int(s_front_index);
        return simlev::calculate_fifo_vp(buys, units, front_index);
    });
}

PyObject* e_private_sale_tax(PyObject*, PyObject* a) {
    PyObject *s_buys, *s_front_index, *s_trade_count, *s_sell_price, *s_current_date;
    if (!PyArg_UnpackTuple(a, "sim_private_sale_tax", 5, 5, &s_buys, &s_front_index, &s_trade_count, &s_sell_price,
                           &s_current_date))
        return nullptr;
    return call_obj([&]() {
        Obj buys = sl::as_list(s_buys);
        int front_index = sl::as_int(s_front_index);
        double trade_count = sl::as_double(s_trade_count);
        double sell_price = sl::as_double(s_sell_price);
        int current_date = sl::as_int(s_current_date);
        return simlev::calculate_private_sale_tax(buys, front_index, trade_count, sell_price, current_date);
    });
}

PyObject* e_fifo_consume(PyObject*, PyObject* a) {
    PyObject *s_input, *s_name, *s_trade_count;
    if (!PyArg_UnpackTuple(a, "sim_fifo_consume", 3, 3, &s_input, &s_name, &s_trade_count)) return nullptr;
    return call_void([&]() {
        Obj input = sl::as_list(s_input);
        const char* name = sl::as_cstring(s_name);
        double trade_count = sl::as_double(s_trade_count);
        simlev::fifo_consume(input, name, trade_count);
    });
}

PyObject* e_flat_rate(PyObject*, PyObject* a) {
    PyObject *s_buys, *s_front_index, *s_base_rate, *s_year_start_price, *s_market_price, *s_soy_days, *s_eoy_days;
    if (!PyArg_UnpackTuple(a, "sim_flat_rate", 7, 7, &s_buys, &s_front_index, &s_base_rate, &s_year_start_price,
                           &s_market_price, &s_soy_days, &s_eoy_days))
        return nullptr;
    return call_obj([&]() {
        Obj buys = sl::as_list(s_buys);
        int front_index = sl::as_int(s_front_index);
        double base_rate = sl::as_double(s_base_rate);
        double year_start_price = sl::as_double(s_year_start_price);
        double market_price = sl::as_double(s_market_price);
        int soy_days = sl::as_int(s_soy_days);
        int eoy_days = sl::as_int(s_eoy_days);
        return simlev::flat_rate(buys, front_index, base_rate, year_start_price, market_price, soy_days, eoy_days);
    });
}

PyObject* e_p20_tax(PyObject*, PyObject* a) {
    PyObject *s_trade_gain, *s_bonus, *s_totals, *s_tax_rate, *s_use_spb;
    if (!PyArg_UnpackTuple(a, "sim_p20_tax", 5, 5, &s_trade_gain, &s_bonus, &s_totals, &s_tax_rate, &s_use_spb))
        return nullptr;
    return call_obj([&]() {
        double trade_gain = sl::as_double(s_trade_gain);
        double bonus = sl::as_double(s_bonus);
        Obj totals = sl::as_list(s_totals);
        double tax_rate = sl::as_double(s_tax_rate);
        bool use_spb = sl::as_bool(s_use_spb);
        return simlev::p20_tax(trade_gain, bonus, totals, tax_rate, use_spb);
    });
}

PyObject* e_vp_tax(PyObject*, PyObject* a) {
    PyObject *s_flat_rate, *s_bonus, *s_totals, *s_tax_rate, *s_use_spb;
    if (!PyArg_UnpackTuple(a, "sim_vp_tax", 5, 5, &s_flat_rate, &s_bonus, &s_totals, &s_tax_rate, &s_use_spb))
        return nullptr;
    return call_obj([&]() {
        double flat_rate = sl::as_double(s_flat_rate);
        double bonus = sl::as_double(s_bonus);
        Obj totals = sl::as_list(s_totals);
        double tax_rate = sl::as_double(s_tax_rate);
        bool use_spb = sl::as_bool(s_use_spb);
        return simlev::vp_tax(flat_rate, bonus, totals, tax_rate, use_spb);
    });
}

PyObject* e_sell_count(PyObject*, PyObject* a) {
    PyObject *s_buys, *s_front_index, *s_target, *s_trade_price, *s_total_shares, *s_fractions, *s_regime, *s_bonus,
        *s_loss_pool, *s_tax_rate;
    if (!PyArg_UnpackTuple(a, "sim_sell_count", 10, 10, &s_buys, &s_front_index, &s_target, &s_trade_price,
                           &s_total_shares, &s_fractions, &s_regime, &s_bonus, &s_loss_pool, &s_tax_rate))
        return nullptr;
    return call_obj([&]() {
        Obj buys = sl::as_list(s_buys);
        int front_index = sl::as_int(s_front_index);
        double target = sl::as_double(s_target);
        double trade_price = sl::as_double(s_trade_price);
        double total_shares = sl::as_double(s_total_shares);
        bool fractions = sl::as_bool(s_fractions);
        int regime = sl::as_int(s_regime);
        double bonus = sl::as_double(s_bonus);
        double loss_pool = sl::as_double(s_loss_pool);
        double tax_rate = sl::as_double(s_tax_rate);
        return simlev::sell_count(buys, front_index, target, trade_price, total_shares, fractions, regime, bonus,
                                  loss_pool, tax_rate);
    });
}

}  // namespace

PyMethodDef simlev_ext_engine_methods[] = {
    {"sim_dca_flows", e_dca, METH_VARARGS, "sim_dca_flows(sim, name, flows, index)"},
    {"sim_buy_report", e_buy_report, METH_VARARGS, "sim_buy_report(sim, name, index, trade_count, trade_price, market_price)"},
    {"sim_sell_report", e_sell_report, METH_VARARGS,
     "sim_sell_report(sim, name, index, trade_count, trade_price, market_price, capital_gains_tax)"},
    {"sim_total_report", e_total_report, METH_VARARGS, "sim_total_report(sim, assets, index)"},
    {"sim_buy", e_buy, METH_VARARGS, "sim_buy(sim, name, index, trade_count, trade_price, market_price)"},
    {"sim_market_update", e_market_update, METH_VARARGS, "sim_market_update(sim, assets, index)"},
    {"sim_market_update_batch", e_market_update_batch, METH_VARARGS, "sim_market_update_batch(sim, assets, start_idx, end_idx)"},
    {"sim_fifo_price", e_fifo_price, METH_VARARGS, "sim_fifo_price(buys, units, front_index) -> float"},
    {"sim_fifo_vp", e_fifo_vp, METH_VARARGS, "sim_fifo_vp(buys, units, front_index) -> float"},
    {"sim_private_sale_tax", e_private_sale_tax, METH_VARARGS,
     "sim_private_sale_tax(buys, front_index, trade_count, sell_price, current_date) -> dict"},
    {"sim_fifo_consume", e_fifo_consume, METH_VARARGS, "sim_fifo_consume(sim, name, trade_count)"},
    {"sim_flat_rate", e_flat_rate, METH_VARARGS,
     "sim_flat_rate(buys, front_index, base_rate, year_start_price, market_price, soy_days, eoy_days) -> dict"},
    {"sim_p20_tax", e_p20_tax, METH_VARARGS, "sim_p20_tax(trade_gain, bonus, totals, tax_rate, use_spb) -> dict"},
    {"sim_vp_tax", e_vp_tax, METH_VARARGS, "sim_vp_tax(flat_rate, bonus, totals, tax_rate, use_spb) -> dict"},
    {"sim_sell_count", e_sell_count, METH_VARARGS,
     "sim_sell_count(buys, front_index, target, trade_price, total_shares, fractions, regime, bonus, loss_pool,\n"
     "               tax_rate) -> dict"},
    {nullptr, nullptr, 0, nullptr}
};

/*
 * python/src/_ext_common.h -- gemeinsame Hilfen der Python-Huellen von simlev._ext
 *
 * Etappe 7.3a. Jede Huelle (_ext_<kern>.cpp) nimmt ihre Felder ueber das
 * Buffer-Protokoll entgegen (numpy-Arrays float64 bzw. int32, zusammenhaengend;
 * keine numpy-Header) und ruft die gemeinsame Kernfunktion (r/src/<datei>_impl.*,
 * Kopie hier) mit den Sichten ext::Vec/ext::IVec/ext::Mat auf. Am Ende dieser Datei
 * steht Python als Host der Kerne (Schnittstelle in simlev_core.h; Gegenstueck zu
 * "R als Host der gemeinsamen Kerne" in r/src/simlev_capi.h):
 *
 *   SIMLEV_FAIL             -> ext::fail: KernelError, in ext::run() zu ValueError mit
 *                              dem Text des Kerns (die Python-Seite macht daraus die
 *                              Fehlerklasse des reinen Python-Kerns)
 *   SIMLEV_CHECK_INTERRUPT  -> PyErr_CheckSignals(); bei Abbruch KeyboardInterrupt (bzw.
 *                              die Ausnahme des Signal-Handlers). Nur dort, wo auch R den
 *                              Benutzerabbruch prueft; der Kern laeuft dann mit
 *                              gehaltener GIL (ext::run(f, false)).
 *   SIMLEV_WARN             -> warnings.warn(Text, UserWarning)
 *   SIMLEV_NUM/MATRIX/COPY  -> Speicher je Thread (ext::Alloc), vor jedem Kern geleert;
 *   SIMLEV_INT                 die Huelle kopiert die Ergebnisse danach in Python-Objekte
 *   simlev_host::runif/rnorm/rgeom (Etappe 7.3b) -> C-Nachbildung von R's RNG (_rng_r.c)
 *                              auf dem Zustand von simlev._r.rng (ext::Rng, mit GIL)
 *
 * Ohne Abbruchpruefung geben die Huellen die GIL waehrend der Rechnung frei. Die
 * Engine-Kerne bringen ihren eigenen Host mit (_ext_engine.cpp, SIMLEV_EXT_ENGINE).
 *
 * Die Huellen pruefen Typ, Laenge und Beschreibbarkeit der Puffer (Schutz vor
 * Fehlaufrufen); fachliche Pruefungen und Umwandlungen wie in R macht die
 * aufrufende Python-Funktion vorher, mit denselben Meldungen wie der reine
 * Python-Kern.
 */
#ifndef SIMLEV_EXT_COMMON_H
#define SIMLEV_EXT_COMMON_H

#define PY_SSIZE_T_CLEAN
#include <Python.h>

#include <climits>
#include <cmath>
#include <cstdio>
#include <deque>
#include <new>
#include <tuple>
#include <cstring>
#include <vector>

#include "simlev_core.h"
#include "_rng_r.h"

namespace ext {

/* Pruefung vor dem Kern, deren Fehlschlag die Huelle verlaesst (Etappe 7.3b): als unwahrscheinlich
 * markiert, damit der Compiler den eingebetteten Kern als heissen Pfad uebersetzt wie in der
 * R-Huelle (dort werfen die Umwandlungen, statt zu verzweigen). Sonst gilt der Kern hinter einer
 * Kette von Pruefungen als selten, wird auf Groesse optimiert (etwa sqrt als Aufruf statt sqrtsd)
 * und bekommt andere Register; das aendert bei zwei NaN-Operanden, welche Nutzlast bleibt. */
#if defined(__GNUC__)
#define EXT_FAIL_IF(x) if (__builtin_expect(!!(x), 0))
#else
#define EXT_FAIL_IF(x) if (x)
#endif

/* Puffer mit automatischer Freigabe */
struct Buf {
    Py_buffer view;
    bool held = false;
    Py_ssize_t n = 0;          /* Anzahl Elemente */
    Buf() { std::memset(&view, 0, sizeof view); }
    ~Buf() { if (held) PyBuffer_Release(&view); }
    Buf(const Buf&) = delete;
    Buf& operator=(const Buf&) = delete;
    double* d() const { return static_cast<double*>(view.buf); }
    int* i() const { return static_cast<int*>(view.buf); }
};

inline bool is_double_format(const char* f) {
    return std::strcmp(f, "d") == 0 || std::strcmp(f, "=d") == 0 || std::strcmp(f, "@d") == 0 ||
           std::strcmp(f, "<d") == 0;
}
inline bool is_int32_format(const char* f) {
    if (std::strcmp(f, "i") == 0 || std::strcmp(f, "=i") == 0 || std::strcmp(f, "@i") == 0 ||
        std::strcmp(f, "<i") == 0) return true;
    return sizeof(long) == 4 && (std::strcmp(f, "l") == 0 || std::strcmp(f, "=l") == 0 || std::strcmp(f, "@l") == 0);
}

/* Puffer holen: double (kind 'd') oder int32 (kind 'i'), zusammenhaengend; len >= 0: Laenge pruefen */
inline bool get(PyObject* obj, Buf& b, char kind, bool writable, const char* fn, const char* name,
                Py_ssize_t len = -1) {
    int flags = PyBUF_C_CONTIGUOUS | PyBUF_FORMAT | (writable ? PyBUF_WRITABLE : 0);
    if (PyObject_GetBuffer(obj, &b.view, flags) < 0) return false;
    b.held = true;
    const char* fmt = b.view.format ? b.view.format : "B";
    const bool okt = kind == 'd' ? (b.view.itemsize == (Py_ssize_t) sizeof(double) && is_double_format(fmt))
                                 : (b.view.itemsize == 4 && is_int32_format(fmt));
    if (!okt) {
        PyErr_Format(PyExc_TypeError, "%s: '%s' muss ein %s-Puffer sein.", fn, name,
                     kind == 'd' ? "double" : "int32");
        return false;
    }
    b.n = b.view.len / b.view.itemsize;
    if (len >= 0 && b.n != len) {
        PyErr_Format(PyExc_ValueError, "%s: '%s' muss die L%snge %zd haben (erhalten: %zd).", fn, name,
                     "\303\244", len, b.n);
        return false;
    }
    if (b.n > INT_MAX) {
        PyErr_Format(PyExc_ValueError, "%s: '%s' ist zu lang.", fn, name);
        return false;
    }
    return true;
}

/* Sichten fuer die Kernvorlagen: gleicher Aufbau und gleiche Zugriffe wie sl::Vec und
 * sl::NumMat in r/src/simlev_capi.h (Zeiger, Laenge bzw. Zeilen- und Spaltenzahl,
 * Matrizen spaltenweise), damit die Vorlagen in R und Python gleich uebersetzt werden. */
template <class T> struct VecT {
    void* sexp;
    T* ptr;
    Py_ssize_t len;
    T& operator[](Py_ssize_t i) const { return ptr[i]; }
    Py_ssize_t size() const { return len; }
    T* begin() const { return ptr; }
    T* end() const { return ptr + len; }
};
typedef VecT<double> Vec;
typedef VecT<int> IVec;

struct Mat {
    void* sexp;
    double* ptr;
    int nr, nc;
    double& operator()(Py_ssize_t i, Py_ssize_t j) const { return ptr[i + (Py_ssize_t) nr * j]; }
    int nrow() const { return nr; }
    int ncol() const { return nc; }
    double* begin() const { return ptr; }
    double* end() const { return ptr + (Py_ssize_t) nr * nc; }
};

inline Vec vec(const Buf& b) { Vec v = {nullptr, b.d(), b.n}; return v; }
inline Vec vec(double* p, Py_ssize_t n) { Vec v = {nullptr, p, n}; return v; }
inline IVec ivec(const Buf& b) { IVec v = {nullptr, b.i(), b.n}; return v; }
inline Mat mat(const Buf& b, int nr, int nc) { Mat m = {nullptr, b.d(), nr, nc}; return m; }
inline Mat mat(double* p, int nr, int nc) { Mat m = {nullptr, p, nr, nc}; return m; }

/* Felder in vom Aufrufer bereitgestellte Puffer kopieren */
inline void put(const Buf& out, const double* p, Py_ssize_t n) {
    for (Py_ssize_t k = 0; k < n; k++) out.d()[k] = p[k];
}

/* Fehler und Abbruch der Kerne (H::fail, H::check_interrupt), in den Huellen gefangen */
struct KernelError {
    char msg[2048];
};
struct Interrupted {};
/* Python-Fehler ist bereits gesetzt (Zugriffe der Engine-Kerne auf Python-Objekte) */
struct PyErrorSet {};

[[noreturn]] inline void fail_msg(const char* msg) {
    KernelError e;
    std::snprintf(e.msg, sizeof e.msg, "%s", msg);
    throw e;
}
/* SIMLEV_FAIL: Format und Argumente wie stop() in R (Texte aus den Kernen) */
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
#if defined(__GNUC__)
#pragma GCC diagnostic pop
#endif

/* SIMLEV_CHECK_INTERRUPT: nur mit gehaltener GIL (Kerne mit Abbruchpruefung laufen
 * ohne Py_BEGIN_ALLOW_THREADS, siehe run(..., false)) */
inline void check_interrupt() {
    if (PyErr_CheckSignals() != 0) throw Interrupted();
}

/* Ergebnisfelder der Kerne (SIMLEV_NUM, SIMLEV_MATRIX, SIMLEV_COPY ...): C++-Speicher je
 * Thread, vor jedem Kernaufruf geleert (ext::run); die Huelle kopiert die Ergebnisse
 * danach in Python-Objekte. Ohne GIL nutzbar. */
struct Alloc {
    std::deque<std::vector<double>> store;
    std::deque<std::vector<int>> istore;
    bool flag = false, has_flag = false;
    void reset() {
        store.clear();
        istore.clear();
        flag = has_flag = false;
    }
    IVec ivec(Py_ssize_t n, int fill = 0) {
        istore.emplace_back((std::size_t) n, fill);
        IVec v = {nullptr, istore.back().data(), n};
        return v;
    }
    Vec num(Py_ssize_t n, double fill = 0.0) {
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
        Vec v = {nullptr, store.back().data(), (Py_ssize_t) store.back().size()};
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

/* Ausnahme eines Kerns in Python umsetzen (ValueError mit dem Text bzw. KeyboardInterrupt) */
inline void set_kernel_error(const KernelError& e) {
    PyObject* msg = PyUnicode_DecodeUTF8(e.msg, (Py_ssize_t) std::strlen(e.msg), "replace");
    if (msg) {
        PyErr_SetObject(PyExc_ValueError, msg);
        Py_DECREF(msg);
    }
}
inline void set_interrupted() {
    if (!PyErr_Occurred()) PyErr_SetNone(PyExc_KeyboardInterrupt);
}

/* Kern ausfuehren: f() ohne GIL (release_gil) bzw. mit GIL (Kerne mit Abbruchpruefung);
 * Ausnahmen des Kerns in Python-Fehler umsetzen. true, wenn alles in Ordnung ist. */
template <class F> bool run(F f, bool release_gil = true) {
    int st = 0;
    KernelError ke;
    ke.msg[0] = '\0';
    alloc().reset();
    PyThreadState* ts = release_gil ? PyEval_SaveThread() : nullptr;
    try {
        f();
    } catch (const KernelError& e) {
        ke = e;
        st = 1;
    } catch (const Interrupted&) {
        st = 2;
    } catch (const PyErrorSet&) {
        st = 5;
    } catch (const std::bad_alloc&) {
        st = 3;
    } catch (...) {
        st = 4;
    }
    if (ts) PyEval_RestoreThread(ts);
    switch (st) {
    case 0: return true;
    case 1: set_kernel_error(ke); return false;
    case 2: set_interrupted(); return false;
    case 3: PyErr_NoMemory(); return false;
    case 5: if (!PyErr_Occurred()) PyErr_SetString(PyExc_RuntimeError, "simlev._ext: Fehler ohne Ausnahme"); return false;
    default: PyErr_SetString(PyExc_RuntimeError, "simlev._ext: unbekannte C++-Ausnahme im Kern"); return false;
    }
}

/* Neues float64-Feld als bytearray (mit 0 gefuellt); Python macht daraus np.frombuffer(...) */
inline PyObject* new_doubles(Py_ssize_t n, double** ptr) {
    PyObject* ba = PyByteArray_FromStringAndSize(nullptr, n * (Py_ssize_t) sizeof(double));
    if (!ba) return nullptr;
    *ptr = reinterpret_cast<double*>(PyByteArray_AS_STRING(ba));
    for (Py_ssize_t k = 0; k < n; k++) (*ptr)[k] = 0.0;
    return ba;
}

/* Felder in vom Aufrufer bereitgestellte Puffer kopieren (int32) */
inline void put_int(const Buf& out, const int* p, Py_ssize_t n) {
    for (Py_ssize_t k = 0; k < n; k++) out.i()[k] = p[k];
}

/* Zustand der Zufallszahlen fuer die Kerne mit RNG (Etappe 7.3b): die Python-Seite
 * (simlev._r.rng.c_state) uebergibt drei Puffer, die Huelle bindet sie fuer die
 * C-Nachbildung von R's RNG (_rng_r.c) und schreibt den Zustand nach dem Kern zurueck
 * (auch nach einem Fehler des Kerns, wie R's PutRNGstate):
 *   ist  int32[12]: kind, n01, mti, twisted (Ausgabe), lec[0..5], rpois l, m
 *   mt   int32[624]: Mersenne-Twister-Woerter (Sicht auf simlev._r.rng._S.mt, an Ort
 *        und Stelle geaendert)
 *   pst  None oder float64[52]: rpois b1, b2, c, c0, c1, c2, c3, p0, p, q, s, d, omega,
 *        big_l, muprev, muprev2, pp[0..35] (nur Kerne, die rgeom/rpois ziehen)
 * Die Kerne laufen dazu mit gehaltener GIL (ext::run(f, false)). */
struct Rng {
    Buf ist, mt, pst;
    simlev_rng_state st;
    simlev_rpois_state ps;
    bool bound = false;
    bool open(PyObject* oist, PyObject* omt, PyObject* opst, const char* fn) {
        if (!get(oist, ist, 'i', true, fn, "rng_ist", 12) || !get(omt, mt, 'i', true, fn, "rng_mt", 624))
            return false;
        const int* v = ist.i();
        if ((v[0] != SIMLEV_RNG_MERSENNE_TWISTER && v[0] != SIMLEV_RNG_LECUYER_CMRG) || v[1] != SIMLEV_RNG_INVERSION) {
            PyErr_Format(PyExc_ValueError, "%s: RNG-Art %d mit Normalverteilung %d ist nicht nachgebildet.", fn,
                         v[0], v[1]);
            return false;
        }
        st.kind = v[0];
        st.n01 = v[1];
        st.mti = v[2];
        st.twisted = 0;
        st.mt = static_cast<uint32_t*>(mt.view.buf);
        for (int k = 0; k < 6; k++) st.lec[k] = (uint32_t) v[4 + k];
        st.pois = nullptr;
        st.pois_missing = 0;
        if (opst != Py_None) {
            if (!get(opst, pst, 'd', true, fn, "rng_pst", 52)) return false;
            const double* w = pst.d();
            ps.l = v[10];
            ps.m = v[11];
            ps.b1 = w[0]; ps.b2 = w[1]; ps.c = w[2]; ps.c0 = w[3]; ps.c1 = w[4]; ps.c2 = w[5]; ps.c3 = w[6];
            ps.p0 = w[7]; ps.p = w[8]; ps.q = w[9]; ps.s = w[10]; ps.d = w[11]; ps.omega = w[12];
            ps.big_l = w[13]; ps.muprev = w[14]; ps.muprev2 = w[15];
            for (int k = 0; k < 36; k++) ps.pp[k] = w[16 + k];
            st.pois = &ps;
        }
        simlev_rng_bind(&st);
        bound = true;
        return true;
    }
    /* Zustand zurueckschreiben; ok: Kern ohne Fehler (sonst bleibt dessen Ausnahme stehen) */
    bool close(bool ok) {
        if (!bound) return false;
        simlev_rng_bind(nullptr);
        bound = false;
        int* v = ist.i();
        v[2] = st.mti;
        v[3] = st.twisted;
        for (int k = 0; k < 6; k++) v[4 + k] = (int) st.lec[k];
        if (st.pois) {
            double* w = pst.d();
            v[10] = ps.l;
            v[11] = ps.m;
            w[0] = ps.b1; w[1] = ps.b2; w[2] = ps.c; w[3] = ps.c0; w[4] = ps.c1; w[5] = ps.c2; w[6] = ps.c3;
            w[7] = ps.p0; w[8] = ps.p; w[9] = ps.q; w[10] = ps.s; w[11] = ps.d; w[12] = ps.omega;
            w[13] = ps.big_l; w[14] = ps.muprev; w[15] = ps.muprev2;
            for (int k = 0; k < 36; k++) w[16 + k] = ps.pp[k];
        }
        if (ok && st.pois_missing) {
            PyErr_SetString(PyExc_RuntimeError, "simlev._ext: rpois ohne rpois-Zustand (pst) gezogen");
            return false;
        }
        return ok;
    }
    ~Rng() { if (bound) simlev_rng_bind(nullptr); }
};

/* std::vector<double> als bytearray */
inline PyObject* from_vector(const std::vector<double>& v) {
    return PyByteArray_FromStringAndSize(reinterpret_cast<const char*>(v.data()),
                                         (Py_ssize_t) (v.size() * sizeof(double)));
}

}  // namespace ext

/* Python als Host der gemeinsamen Kerne (Schnittstelle in simlev_core.h; Gegenstueck
 * zum Abschnitt "R als Host der gemeinsamen Kerne" in r/src/simlev_capi.h) */
#ifndef SIMLEV_EXT_ENGINE   /* die Engine-Kerne bringen ihren Host mit (_ext_engine.cpp) */
namespace simlev_host {
typedef ext::Vec NumVec;
typedef ext::IVec IntVec;
typedef ext::Mat NumMat;
/* Kerne mit Zufallszahlen (Etappe 7.3b): logische Vektoren als int32, Listen von
 * Ganzzahlvektoren, Zufallszahlen aus der C-Nachbildung von R's RNG (_rng_r.c) auf dem
 * gebundenen Zustand (ext::Rng) */
typedef ext::IVec LglVec;
typedef std::vector<ext::IVec> IntList;
inline double runif(double a, double b) { return simlev_rng_runif(a, b); }
inline double rnorm(double mu, double sigma) { return simlev_rng_rnorm(mu, sigma); }
inline double rgeom(double p) { return simlev_rng_rgeom(p); }
}  // namespace simlev_host
#define SIMLEV_RNG 1
#define SIMLEV_INT(...) ext::alloc().ivec(__VA_ARGS__)
#define SIMLEV_LIST_INT(l, i) ((l)[i])
#endif

#define SIMLEV_NA (simlev_na_real())
#define SIMLEV_FAIL ext::fail
#define SIMLEV_CHECK_INTERRUPT() ext::check_interrupt()
#define SIMLEV_WARN(msg) PyErr_WarnEx(PyExc_UserWarning, msg, 1)
#define SIMLEV_NUM(...) ext::alloc().num(__VA_ARGS__)
#define SIMLEV_MATRIX(...) ext::alloc().mat(__VA_ARGS__)
#define SIMLEV_COPY(...) ext::alloc().copy(__VA_ARGS__)
#define SIMLEV_COPY_VEC(...) ext::alloc().copy(__VA_ARGS__)
#define SIMLEV_SET_FLAG(v, name, f) ext::alloc().set_flag(f)
#define SIMLEV_DONE(v) (v)
#define SIMLEV_LIST(...) std::make_tuple(__VA_ARGS__)
#define SIMLEV_CLONE(v) ext::alloc().copy((v).begin(), (v).end())
#define SIMLEV_R_FINITE(x) std::isfinite(x)

/* Methodentabellen der Huellen (je Datei eine, zusammengefuehrt in _ext.cpp) */
extern PyMethodDef simlev_ext_ms_garch_methods[];
extern PyMethodDef simlev_ext_research_methods[];
extern PyMethodDef simlev_ext_withdrawal_methods[];
extern PyMethodDef simlev_ext_rugarch_methods[];
extern PyMethodDef simlev_ext_dependence_methods[];
extern PyMethodDef simlev_ext_evd_methods[];
extern PyMethodDef simlev_ext_imputets_methods[];
extern PyMethodDef simlev_ext_engine_methods[];
extern PyMethodDef simlev_ext_bootstrap_methods[];
extern PyMethodDef simlev_ext_truncnorm_methods[];
extern PyMethodDef simlev_ext_rng_methods[];

#endif

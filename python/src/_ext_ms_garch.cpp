/*
 * python/src/_ext_ms_garch.cpp -- Python-Huelle des MS-GARCH-Filters in simlev._ext
 *
 * Duenne Huelle um den gemeinsamen Kern simlev_ms_garch_filter (ms_garch_impl.c,
 * Byte-fuer-Byte-Kopie von r/src/ms_garch_impl.c; Etappe 7.2 als eigenes Modul
 * simlev._ext_msgarch, seit 7.3a Teil von simlev._ext).
 *
 * Aufruf (nur aus simlev._bootstrap_core.ms_garch_filter, das die Argumente wie R
 * prueft und umwandelt):
 *
 *   loglik = ms_garch_filter(y, omega, alpha, beta, gamma, P, xi0, h1, h, pred, filt, lB)
 *
 * y (n), omega/alpha/beta/gamma/xi0 (K), P (K * K, spaltenweise): double-Puffer;
 * h1: Zahl; h, pred, filt, lB: beschreibbare double-Puffer mit n * K Werten,
 * spaltenweise n x K (in numpy ein C-Array der Form (K, n)). Rueckgabe: loglik.
 */
#include "_ext_common.h"
#include "ms_garch_impl.h"

static PyObject* msg_filter(PyObject*, PyObject* args) {
    PyObject* o[11];
    double h1;
    if (!PyArg_ParseTuple(args, "OOOOOOOdOOOO:ms_garch_filter", &o[0], &o[1], &o[2], &o[3], &o[4],
                          &o[5], &o[6], &h1, &o[7], &o[8], &o[9], &o[10]))
        return nullptr;
    static const char* names[11] = {"y", "omega", "alpha", "beta", "gamma", "P", "xi0",
                                    "h", "pred", "filt", "lB"};
    const char* fn = "ms_garch_filter";
    ext::Buf v[11];
    if (!ext::get(o[0], v[0], 'd', false, fn, names[0])) return nullptr;
    const Py_ssize_t n = v[0].n;
    if (n < 1) {
        PyErr_SetString(PyExc_ValueError, "ms_garch_filter: 'y' darf nicht leer sein.");
        return nullptr;
    }
    if (!ext::get(o[1], v[1], 'd', false, fn, names[1])) return nullptr;
    const Py_ssize_t K = v[1].n;
    if (K < 1 || K > 1000) {
        PyErr_SetString(PyExc_ValueError,
                        "ms_garch_filter: 'omega' muss 1 bis 1000 Werte haben (einen je Regime).");
        return nullptr;
    }
    if (n * K > INT_MAX) {
        PyErr_SetString(PyExc_ValueError, "ms_garch_filter: 'y' ist zu lang.");
        return nullptr;
    }
    for (int i = 2; i < 11; i++) {
        const Py_ssize_t len = (i == 5) ? K * K : (i < 7 ? K : n * K);
        if (!ext::get(o[i], v[i], 'd', i >= 7, fn, names[i], len)) return nullptr;
    }
    double loglik = 0.0;
    Py_BEGIN_ALLOW_THREADS
    simlev_ms_garch_filter(v[0].d(), (int) n, (int) K, v[1].d(), v[2].d(), v[3].d(), v[4].d(),
                           v[5].d(), v[6].d(), h1, v[7].d(), v[8].d(), v[9].d(), v[10].d(), &loglik);
    Py_END_ALLOW_THREADS
    return PyFloat_FromDouble(loglik);
}

PyMethodDef simlev_ext_ms_garch_methods[] = {
    {"ms_garch_filter", msg_filter, METH_VARARGS,
     "ms_garch_filter(y, omega, alpha, beta, gamma, P, xi0, h1, h, pred, filt, lB) -> loglik\n\n"
     "Hamilton-Filter des MS-GARCH-Modells (gemeinsamer Kern mit R, ms_garch_impl.c);\n"
     "schreibt h, pred, filt, lB (je n x K spaltenweise)."},
    {nullptr, nullptr, 0, nullptr}
};

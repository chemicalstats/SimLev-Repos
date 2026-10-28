/*
 * python/src/_ext_dependence.cpp -- Python-Huelle des DCC(1,1)-Filters (.dcc_filter)
 *
 * Etappe 7.3a. Gemeinsamer Kern mit R (r/src/dependence_core_impl.h, Kopie hier);
 * aufgerufen aus simlev._dependence_core.dcc_filter, das vorher wie der reine
 * Python-Kern umwandelt.
 *
 *   dcc_filter(Z, n, k, a, b, Qbar, qnr, keep, out) -> (nll, ok)
 *
 * Z n x k und Qbar (qnr x k) spaltenweise als flache double-Puffer; out
 * beschreibbar mit keep ? n * k (k - 1) / 2 : 0 Werten (spaltenweise).
 */
#include "_ext_common.h"
#include "dependence_core_impl.h"

namespace {

PyObject* d_dcc(PyObject*, PyObject* args) {
    PyObject *oZ, *oQ, *oout;
    int n, k, qnr, keep;
    double a, b;
    const char* fn = "dcc_filter";
    if (!PyArg_ParseTuple(args, "OiiddOipO:dcc_filter", &oZ, &n, &k, &a, &b, &oQ, &qnr, &keep, &oout)) return nullptr;
    ext::Buf Z, Q, out;
    if (n < 0 || k < 0 || qnr < k) {
        PyErr_SetString(PyExc_ValueError, "dcc_filter: ungueltige Abmessungen.");
        return nullptr;
    }
    const Py_ssize_t np_ = (Py_ssize_t) k * (k - 1) / 2;
    if (!ext::get(oZ, Z, 'd', false, fn, "Z", (Py_ssize_t) n * k) ||
        !ext::get(oQ, Q, 'd', false, fn, "Qbar") ||
        !ext::get(oout, out, 'd', true, fn, "out", keep ? (Py_ssize_t) n * np_ : 0))
        return nullptr;
    if (Q.n < (Py_ssize_t) qnr * k) {
        PyErr_SetString(PyExc_ValueError, "dcc_filter: 'Qbar' ist zu kurz.");
        return nullptr;
    }
    double nll = 0.0;
    bool ok = true;
    if (!ext::run([&] {
            auto r = simlev::dcc_filter(ext::mat(Z, n, k), a, b, ext::mat(Q, qnr, k), keep != 0);
            nll = std::get<1>(r);
            ok = std::get<5>(r);
            const ext::Mat& R = std::get<3>(r);
            ext::put(out, R.ptr, (Py_ssize_t) R.nr * R.nc);
        })) return nullptr;
    return Py_BuildValue("(dO)", nll, ok ? Py_True : Py_False);
}

}  // namespace

PyMethodDef simlev_ext_dependence_methods[] = {
    {"dcc_filter", d_dcc, METH_VARARGS, "dcc_filter(Z, n, k, a, b, Qbar, qnr, keep, out) -> (nll, ok)"},
    {nullptr, nullptr, 0, nullptr}
};

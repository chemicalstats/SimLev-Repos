/*
 * python/src/_ext_evd.cpp -- Python-Huelle von nlgpd (evd 2.3-7.1) in simlev._ext
 *
 * Etappe 7.3a. Gemeinsamer Kern mit R (r/src/vendor_evd_impl.h, Kopie hier, als C
 * eingebunden in _ext_evd_c.c); aufgerufen aus simlev._r.evd.nlgpd, das vorher wie
 * .C mit NAOK = FALSE prueft.
 *
 *   evd_nlgpd(data, loc, scale, shape) -> dns     (data: Kopie, wird ueberschrieben)
 *
 * Laeuft mit gehaltener GIL (der C-Teil nutzt ein gemeinsames Arbeitsfeld).
 */
#include "_ext_common.h"

extern "C" int simlev_py_evd_nlgpd(double* data, int n, double loc, double scale, double shape, double* dns);

namespace {

PyObject* e_nlgpd(PyObject*, PyObject* args) {
    PyObject* od;
    double loc, scale, shape;
    if (!PyArg_ParseTuple(args, "Oddd:evd_nlgpd", &od, &loc, &scale, &shape)) return nullptr;
    ext::Buf d;
    if (!ext::get(od, d, 'd', true, "evd_nlgpd", "data")) return nullptr;
    double dns = 0.0;
    if (!simlev_py_evd_nlgpd(d.d(), (int) d.n, loc, scale, shape, &dns)) return PyErr_NoMemory();
    return PyFloat_FromDouble(dns);
}

}  // namespace

PyMethodDef simlev_ext_evd_methods[] = {
    {"evd_nlgpd", e_nlgpd, METH_VARARGS, "evd_nlgpd(data, loc, scale, shape) -> dns  (nlgpd aus evd 2.3-7.1)"},
    {nullptr, nullptr, 0, nullptr}
};

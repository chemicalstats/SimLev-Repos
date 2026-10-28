/*
 * python/src/_ext_imputets.cpp -- Python-Huelle von locf (imputeTS 3.4) in simlev._ext
 *
 * Etappe 7.3a. Gemeinsamer Kern mit R (r/src/vendor_imputets_impl.h, Kopie hier);
 * aufgerufen aus simlev._r.imputets._locf_core.
 *
 *   imputets_locf(x, reverse, out)      out: beschreibbar, Laenge von x
 *
 * Wie in R prueft der Kern alle 1024 Werte auf Benutzerabbruch (PyErr_CheckSignals,
 * KeyboardInterrupt); er laeuft dazu mit gehaltener GIL.
 */
#include "_ext_common.h"
#include "vendor_imputets_impl.h"

namespace {

PyObject* i_locf(PyObject*, PyObject* args) {
    PyObject *ox, *oout;
    int reverse;
    if (!PyArg_ParseTuple(args, "OpO:imputets_locf", &ox, &reverse, &oout)) return nullptr;
    ext::Buf x, out;
    if (!ext::get(ox, x, 'd', false, "imputets_locf", "x") ||
        !ext::get(oout, out, 'd', true, "imputets_locf", "out", x.n)) return nullptr;
    if (!ext::run([&] {
            ext::Vec z = simlev::imputets_locf(ext::vec(x), reverse != 0);
            ext::put(out, z.ptr, z.len);
        }, false)) return nullptr;
    Py_RETURN_NONE;
}

}  // namespace

PyMethodDef simlev_ext_imputets_methods[] = {
    {"imputets_locf", i_locf, METH_VARARGS, "imputets_locf(x, reverse, out)  (locf aus imputeTS 3.4)"},
    {nullptr, nullptr, 0, nullptr}
};

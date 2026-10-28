/*
 * python/src/_ext_truncnorm.cpp -- Python-Huelle von rtruncnorm (truncnorm 1.0-9) in simlev._ext
 *
 * Etappe 7.3b. Gemeinsamer Kern mit R (r/src/vendor_truncnorm_impl.h, Kopie hier, als C
 * eingebunden in _ext_truncnorm_c.c); aufgerufen aus simlev._r.truncnorm.rtruncnorm, das
 * vorher wie der R-Wrapper und do_rtruncnorm prueft und GetRNGstate() nachbildet.
 *
 *   truncnorm_rtruncnorm(ist, mt, pst, nn, a, b, mean, sd, out)
 *
 * a, b, mean, sd: double-Felder (Laenge >= 1, recycelt wie in R); out: beschreibbar mit nn
 * Werten. Zustand der Zufallszahlen wie bei den Bootstrap-Kernen (ext::Rng); der Kern
 * laeuft mit gehaltener GIL und prueft wie in R je Wert auf Benutzerabbruch
 * (PyErr_CheckSignals); nach einem Signal rechnet er die Schleife zu Ende und meldet dann
 * KeyboardInterrupt (der Zustand der Zufallszahlen ist der nach der ganzen Schleife).
 */
#include "_ext_common.h"

extern "C" void simlev_py_truncnorm(int nn, double* a, int n_a, double* b, int n_b, double* mean, int n_mean,
                                    double* sd, int n_sd, double* ret);

/* R_CheckUserInterrupt des Kerns: Signale pruefen; nach dem ersten Abbruch merken (die
 * Schleife laeuft zu Ende, die Huelle meldet dann KeyboardInterrupt) */
static int truncnorm_interrupted = 0;
extern "C" void simlev_py_check_interrupt(void) {
    if (!truncnorm_interrupted && PyErr_CheckSignals() != 0) truncnorm_interrupted = 1;
}

namespace {

PyObject* t_rtruncnorm(PyObject*, PyObject* args) {
    PyObject *oi, *om, *op, *oa, *ob, *omean, *osd, *oout;
    int nn;
    const char* fn = "truncnorm_rtruncnorm";
    EXT_FAIL_IF(!PyArg_ParseTuple(args, "OOOiOOOOO:truncnorm_rtruncnorm", &oi, &om, &op, &nn, &oa, &ob, &omean, &osd, &oout))
        return nullptr;
    ext::Buf a, b, mean, sd, out;
    ext::Rng rng;
    EXT_FAIL_IF(nn < 0 || !ext::get(oa, a, 'd', false, fn, "a") || !ext::get(ob, b, 'd', false, fn, "b") ||
        !ext::get(omean, mean, 'd', false, fn, "mean") || !ext::get(osd, sd, 'd', false, fn, "sd") ||
        !ext::get(oout, out, 'd', true, fn, "out", nn)) return nullptr;
    EXT_FAIL_IF(a.n < 1 || b.n < 1 || mean.n < 1 || sd.n < 1) {
        PyErr_SetString(PyExc_ValueError, "truncnorm_rtruncnorm: a, b, mean und sd brauchen mindestens einen Wert.");
        return nullptr;
    }
    EXT_FAIL_IF(!rng.open(oi, om, op, fn)) return nullptr;
    truncnorm_interrupted = 0;
    const bool ok = ext::run([&] {
        simlev_py_truncnorm(nn, a.d(), (int) a.n, b.d(), (int) b.n, mean.d(), (int) mean.n, sd.d(), (int) sd.n, out.d());
        if (truncnorm_interrupted) throw ext::Interrupted();
    }, false);
    EXT_FAIL_IF(!rng.close(ok)) return nullptr;
    Py_RETURN_NONE;
}

}  // namespace

PyMethodDef simlev_ext_truncnorm_methods[] = {
    {"truncnorm_rtruncnorm", t_rtruncnorm, METH_VARARGS,
     "truncnorm_rtruncnorm(ist, mt, pst, nn, a, b, mean, sd, out)  (do_rtruncnorm aus truncnorm 1.0-9)"},
    {nullptr, nullptr, 0, nullptr}
};

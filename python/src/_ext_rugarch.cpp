/*
 * python/src/_ext_rugarch.cpp -- Python-Huelle der Likelihood-Filter aus rugarch 1.5-6
 *
 * Etappe 7.3a. Gemeinsamer Kern mit R (r/src/vendor_rugarch_impl.h, Kopie hier,
 * als C eingebunden in _ext_rugarch_c.c);
 * aufgerufen aus simlev._r.rugarch (_LLH), das vorher wie der reine Python-Port
 * prueft (NAOK-Pruefung von .C). Argumente wie .C in rugarch, als Puffer:
 *
 *   rugarch_filter(gjr, model, pars, idx, hEst, x, res, nres, e, mexdata, vexdata, zrf,
 *                  constm, condm, m, h, z, LHT) -> llh
 *
 * model (21) und idx int32, alle uebrigen Felder double; T = len(x). res, nres, e,
 * constm, condm, h, z, LHT (je T) werden beschrieben (constm, condm, h sollten mit 0
 * beginnen wie double(T) in R); nres nur fuer gjr. Die Huelle laesst nur die
 * Modellform zu, die SimLev nutzt (ARMA(0,0) mit Mittelwert, ohne Regressoren und
 * ARFIMA, GARCH-Ordnungen <= m <= T), und prueft die Indizes, damit der Kern nur
 * innerhalb der Puffer liest.
 */
#include "_ext_common.h"

/* _ext_rugarch_c.c: die Filter aus vendor_rugarch_impl.h, als C uebersetzt wie in R */
extern "C" {
void simlev_py_sgarchfilterC(int *model, double *pars, int *idx, double *hEst, double *x, double *res,
                             double *e, double *mexdata, double *vexdata, double *zrf, double *constm,
                             double *condm, int *m, int *T, double *h, double *z, double *llh, double *LHT);
void simlev_py_gjrgarchfilterC(int *model, double *pars, int *idx, double *hEst, double *x, double *res,
                               double *nres, double *e, double *mexdata, double *vexdata, double *zrf,
                               double *constm, double *condm, int *m, int *T, double *h, double *z,
                               double *llh, double *LHT);
}

namespace {

PyObject* g_filter(PyObject*, PyObject* args) {
    int gjr, m;
    double hEst;
    PyObject *om, *op, *oi, *ox, *ores, *onres, *oe, *omex, *ovex, *ozrf, *ocm, *ocd, *oh, *oz, *olht;
    if (!PyArg_ParseTuple(args, "pOOOdOOOOOOOOOiOOO:rugarch_filter", &gjr, &om, &op, &oi, &hEst, &ox, &ores, &onres,
                          &oe, &omex, &ovex, &ozrf, &ocm, &ocd, &m, &oh, &oz, &olht))
        return nullptr;
    const char* fn = "rugarch_filter";
    ext::Buf model, pars, idx, x, res, nres, e, mex, vex, zrf, cm, cd, h, z, lht;
    if (!ext::get(om, model, 'i', false, fn, "model", 21) || !ext::get(op, pars, 'd', false, fn, "pars") ||
        !ext::get(oi, idx, 'i', false, fn, "idx") || !ext::get(ox, x, 'd', false, fn, "x"))
        return nullptr;
    const Py_ssize_t T = x.n;
    if (!ext::get(ores, res, 'd', true, fn, "res", T) || !ext::get(onres, nres, 'd', true, fn, "nres") ||
        !ext::get(oe, e, 'd', true, fn, "e", T) || !ext::get(omex, mex, 'd', false, fn, "mexdata") ||
        !ext::get(ovex, vex, 'd', false, fn, "vexdata") || !ext::get(ozrf, zrf, 'd', false, fn, "zrf") ||
        !ext::get(ocm, cm, 'd', true, fn, "constm", T) || !ext::get(ocd, cd, 'd', true, fn, "condm", T) ||
        !ext::get(oh, h, 'd', true, fn, "h", T) || !ext::get(oz, z, 'd', true, fn, "z", T) ||
        !ext::get(olht, lht, 'd', true, fn, "LHT", T))
        return nullptr;
    const int* mo = model.i();
    bool ok = T >= 1 && m >= 1 && m <= T && idx.n >= 18 && mo[1] == 0 && mo[2] == 0 && mo[3] == 0 &&
              mo[4] == 0 && mo[5] == 0 && mo[14] == 0 && mo[7] >= 0 && mo[7] <= m && mo[8] >= 0 && mo[8] <= m &&
              mo[20] == 1 && (!gjr || nres.n == T);
    for (int k = 0; ok && k < 18; k++) {
        const int last = idx.i()[k] + ((k == 7 || k == 8 || k == 9) ? (k == 8 ? mo[8] : mo[7]) - 1 : 0);
        ok = idx.i()[k] >= 0 && last < pars.n;
    }
    if (!ok) {
        PyErr_SetString(PyExc_ValueError, "rugarch_filter: Modellform oder Abmessungen nicht unterstuetzt.");
        return nullptr;
    }
    int Ti = (int) T, mi = m;
    double llh = 0.0;
    Py_BEGIN_ALLOW_THREADS
    if (gjr)
        simlev_py_gjrgarchfilterC(model.i(), pars.d(), idx.i(), &hEst, x.d(), res.d(), nres.d(), e.d(), mex.d(),
                                       vex.d(), zrf.d(), cm.d(), cd.d(), &mi, &Ti, h.d(), z.d(), &llh, lht.d());
    else
        simlev_py_sgarchfilterC(model.i(), pars.d(), idx.i(), &hEst, x.d(), res.d(), e.d(), mex.d(), vex.d(),
                                     zrf.d(), cm.d(), cd.d(), &mi, &Ti, h.d(), z.d(), &llh, lht.d());
    Py_END_ALLOW_THREADS
    return PyFloat_FromDouble(llh);
}

}  // namespace

PyMethodDef simlev_ext_rugarch_methods[] = {
    {"rugarch_filter", g_filter, METH_VARARGS,
     "rugarch_filter(gjr, model, pars, idx, hEst, x, res, nres, e, mexdata, vexdata, zrf, constm, condm, m,\n"
     "               h, z, LHT) -> llh  (sgarchfilterC bzw. gjrgarchfilterC aus rugarch 1.5-6)"},
    {nullptr, nullptr, 0, nullptr}
};

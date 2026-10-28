/*
 * python/src/_ext_rugarch_c.c -- C-Teil der Python-Huelle der rugarch-Filter (simlev._ext)
 *
 * Etappe 7.3a. Bindet den gemeinsamen Kern vendor_rugarch_impl.h (Byte-fuer-Byte-Kopie
 * von r/src/vendor_rugarch_impl.h) als C ein, genau wie src/vendor_rugarch.c in R,
 * und reicht die beiden Filter an die C++-Huelle _ext_rugarch.cpp weiter.
 */
#include "vendor_rugarch_impl.h"

void simlev_py_sgarchfilterC(int *model, double *pars, int *idx, double *hEst, double *x, double *res,
                             double *e, double *mexdata, double *vexdata, double *zrf, double *constm,
                             double *condm, int *m, int *T, double *h, double *z, double *llh, double *LHT)
{
    rugarch_sgarchfilterC(model, pars, idx, hEst, x, res, e, mexdata, vexdata, zrf, constm, condm, m, T, h, z,
                          llh, LHT);
}

void simlev_py_gjrgarchfilterC(int *model, double *pars, int *idx, double *hEst, double *x, double *res,
                               double *nres, double *e, double *mexdata, double *vexdata, double *zrf,
                               double *constm, double *condm, int *m, int *T, double *h, double *z,
                               double *llh, double *LHT)
{
    rugarch_gjrgarchfilterC(model, pars, idx, hEst, x, res, nres, e, mexdata, vexdata, zrf, constm, condm, m, T,
                            h, z, llh, LHT);
}

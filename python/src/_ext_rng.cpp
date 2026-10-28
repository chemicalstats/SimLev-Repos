/*
 * python/src/_ext_rng.cpp -- Pruefzugang zur C-Nachbildung von R's Zufallszahlen (simlev._ext)
 *
 * Etappe 7.3b. Nur fuer Tests (python/tests/test_shared_c.py, Zufallsvergleich gegen R):
 * zieht mit der C-Nachbildung (_rng_r.c) auf dem Zustand von simlev._r.rng, damit Werte
 * und Zustand mit dem reinen Python-Kern und mit R verglichen werden koennen.
 *
 *   rng_draw(ist, mt, pst, what, n, a, b, out)
 *       what: 0 unif_rand, 1 norm_rand, 2 exp_rand, 3 runif(a, b), 4 rnorm(a, b),
 *             5 rexp(a) (Skala), 6 rgeom(a), 7 rpois(a)
 *   rng_qnorm(p, out)                 qnorm5(p, 0, 1, TRUE, FALSE) je Wert
 *   rng_dnorm(x, mu, sigma, out)      dnorm4(x, mu, sigma, FALSE) je Wert
 */
#include "_ext_common.h"

namespace {

PyObject* r_draw(PyObject*, PyObject* args) {
    PyObject *oi, *om, *op, *oout;
    int what, n;
    double a, b;
    const char* fn = "rng_draw";
    EXT_FAIL_IF(!PyArg_ParseTuple(args, "OOOiiddO:rng_draw", &oi, &om, &op, &what, &n, &a, &b, &oout)) return nullptr;
    ext::Buf out;
    ext::Rng rng;
    EXT_FAIL_IF(what < 0 || what > 7 || n < 0) {
        PyErr_SetString(PyExc_ValueError, "rng_draw: ungueltige Art oder Anzahl.");
        return nullptr;
    }
    EXT_FAIL_IF(!ext::get(oout, out, 'd', true, fn, "out", n) || !rng.open(oi, om, op, fn)) return nullptr;
    const bool ok = ext::run([&] {
        double* o = out.d();
        for (int i = 0; i < n; i++) {
            switch (what) {
            case 0: o[i] = simlev_rng_unif_rand(); break;
            case 1: o[i] = simlev_rng_norm_rand(); break;
            case 2: o[i] = simlev_rng_exp_rand(); break;
            case 3: o[i] = simlev_rng_runif(a, b); break;
            case 4: o[i] = simlev_rng_rnorm(a, b); break;
            case 5: o[i] = simlev_rng_rexp(a); break;
            case 6: o[i] = simlev_rng_rgeom(a); break;
            default: o[i] = simlev_rng_rpois(a); break;
            }
        }
    }, false);
    EXT_FAIL_IF(!rng.close(ok)) return nullptr;
    Py_RETURN_NONE;
}

PyObject* r_qnorm(PyObject*, PyObject* args) {
    PyObject *op, *oout;
    EXT_FAIL_IF(!PyArg_ParseTuple(args, "OO:rng_qnorm", &op, &oout)) return nullptr;
    ext::Buf p, out;
    EXT_FAIL_IF(!ext::get(op, p, 'd', false, "rng_qnorm", "p") || !ext::get(oout, out, 'd', true, "rng_qnorm", "out", p.n))
        return nullptr;
    for (Py_ssize_t i = 0; i < p.n; i++) out.d()[i] = simlev_rng_qnorm5(p.d()[i], 0.0, 1.0, 1, 0);
    Py_RETURN_NONE;
}

PyObject* r_dnorm(PyObject*, PyObject* args) {
    PyObject *ox, *omu, *osg, *oout;
    EXT_FAIL_IF(!PyArg_ParseTuple(args, "OOOO:rng_dnorm", &ox, &omu, &osg, &oout)) return nullptr;
    ext::Buf x, mu, sg, out;
    const char* fn = "rng_dnorm";
    EXT_FAIL_IF(!ext::get(ox, x, 'd', false, fn, "x") || !ext::get(omu, mu, 'd', false, fn, "mu", x.n) ||
        !ext::get(osg, sg, 'd', false, fn, "sigma", x.n) || !ext::get(oout, out, 'd', true, fn, "out", x.n))
        return nullptr;
    for (Py_ssize_t i = 0; i < x.n; i++) out.d()[i] = simlev_rng_dnorm4(x.d()[i], mu.d()[i], sg.d()[i], 0);
    Py_RETURN_NONE;
}

}  // namespace

PyMethodDef simlev_ext_rng_methods[] = {
    {"rng_draw", r_draw, METH_VARARGS, "rng_draw(ist, mt, pst, what, n, a, b, out)  (Pruefzugang zu _rng_r.c)"},
    {"rng_qnorm", r_qnorm, METH_VARARGS, "rng_qnorm(p, out)  (qnorm5 aus _rng_r.c)"},
    {"rng_dnorm", r_dnorm, METH_VARARGS, "rng_dnorm(x, mu, sigma, out)  (dnorm4 aus _rng_r.c)"},
    {nullptr, nullptr, 0, nullptr}
};

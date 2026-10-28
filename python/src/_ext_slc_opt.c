/*
 * python/src/_ext_slc_opt.c -- Python-Huellen der Optimierer der C-Bibliothek slc im Modul
 * simlev._ext (Etappe 9.3)
 *
 * Kerne: src/core/slc_opt.c, slc_opt_test.c (Kopien aus core/, tools/core_sync.py). Die
 * Python-Seite (simlev/_lib_opt.py) legt das Arbeitsfeld (numpy float64) an und laeuft in der
 * Schleife "Anfrage -> Zielfunktion in Python -> Antwort"; der Kern ruft nie nach Python zurueck.
 *
 * Rueckmeldungen wie _ext_slc.c: Warnungen nach dem Aufruf (warnings.warn), Fehler als
 * ValueError mit dem Text des Kerns; Abbruch ueber PyErr_CheckSignals.
 */
#define PY_SSIZE_T_CLEAN
#include <Python.h>

#include <stdint.h>
#include <string.h>

#include "core/slc.h"

static int py_interrupted(void *h) { (void) h; return PyErr_CheckSignals() < 0; }

static void ctx_init(sl_ctx *cx)
{
    sl_ctx_init(cx);
    cx->interrupted = py_interrupted;
}

static int finish(sl_ctx *cx, int st)
{
    int i;
    for (i = 0; i < cx->n_warn; i++)
        if (PyErr_WarnEx(PyExc_UserWarning, cx->warn[i], 1) < 0) return -1;
    if (st == SL_OK) return 0;
    if (st == SL_EINTR && PyErr_Occurred()) return -1;
    PyErr_SetString(PyExc_ValueError, cx->msg);
    return -1;
}

/* double-Puffer (float64, zusammenhaengend); n < 0: Laenge beliebig */
static int dbuf(PyObject *o, Py_buffer *v, int writable, Py_ssize_t n, const char *what)
{
    int flags = PyBUF_C_CONTIGUOUS | PyBUF_FORMAT | (writable ? PyBUF_WRITABLE : 0);
    if (PyObject_GetBuffer(o, v, flags) < 0) return -1;
    if (v->itemsize != 8 || v->format == NULL || v->format[strlen(v->format) - 1] != 'd' ||
        (n >= 0 && v->len / 8 != n)) {
        PyBuffer_Release(v);
        PyErr_Format(PyExc_TypeError, "interner Fehler: %s muss float64 der Laenge %zd sein", what, n);
        return -1;
    }
    return 0;
}

#define NDBL(v) ((v).len / 8)

/* optionaler Puffer (None -> NULL) */
static int obuf(PyObject *o, Py_buffer *v, Py_ssize_t n, const char *what, const double **p)
{
    *p = NULL;
    if (o == Py_None) return 0;
    if (dbuf(o, v, 0, n, what) < 0) return -1;
    *p = (const double *) v->buf;
    return 1;
}

static PyObject *slc_opt_wsize(PyObject *self, PyObject *args)
{
    int m, n;
    (void) self;
    if (!PyArg_ParseTuple(args, "ii", &m, &n)) return NULL;
    return PyLong_FromLongLong((long long) sl_opt_wsize(m, n));
}

/* slc_opt_init(ws, method, x0, lo|None, hi|None, (maxit, maxfev, reltol, gtol, xtol, fnscale),
 *              parscale|None, have_grad) */
static PyObject *slc_opt_init(PyObject *self, PyObject *args)
{
    PyObject *ows, *ox, *olo, *ohi, *ops;
    int m, have_grad, rc, hl = 0, hh = 0, hp = 0;
    double c_maxit, c_maxfev;
    Py_buffer ws, x, lo, hi, ps;
    const double *plo, *phi, *pps;
    sl_opt_ctrl c;
    sl_ctx cx;
    Py_ssize_t n;
    (void) self;
    sl_opt_ctrl_default(&c, SL_OPT_BFGS);
    if (!PyArg_ParseTuple(args, "OiOOO(dddddd)Op", &ows, &m, &ox, &olo, &ohi, &c_maxit, &c_maxfev, &c.reltol,
                          &c.gtol, &c.xtol, &c.fnscale, &ops, &have_grad))
        return NULL;
    c.maxit = (int) c_maxit;
    c.maxfev = (int) c_maxfev;
    if (dbuf(ox, &x, 0, -1, "par") < 0) return NULL;
    n = NDBL(x);
    if (dbuf(ows, &ws, 1, (Py_ssize_t) sl_opt_wsize(m, (int) n), "Arbeitsfeld") < 0) { PyBuffer_Release(&x); return NULL; }
    if ((hl = obuf(olo, &lo, n, "lower", &plo)) < 0) goto fail;
    if ((hh = obuf(ohi, &hi, n, "upper", &phi)) < 0) goto fail;
    if ((hp = obuf(ops, &ps, n, "parscale", &pps)) < 0) goto fail;
    c.parscale = pps;
    ctx_init(&cx);
    rc = sl_opt_init(&cx, m, (int) n, (const double *) x.buf, plo, phi, &c, have_grad, (double *) ws.buf);
    PyBuffer_Release(&x); PyBuffer_Release(&ws);
    if (hl > 0) PyBuffer_Release(&lo);
    if (hh > 0) PyBuffer_Release(&hi);
    if (hp > 0) PyBuffer_Release(&ps);
    if (finish(&cx, rc) < 0) return NULL;
    Py_RETURN_NONE;
fail:
    PyBuffer_Release(&x); PyBuffer_Release(&ws);
    if (hl > 0) PyBuffer_Release(&lo);
    if (hh > 0) PyBuffer_Release(&hi);
    return NULL;
}

/* slc_opt_ask(ws, x_out) -> need (0 fertig, 1 f, 2 Gradient) */
static PyObject *slc_opt_ask(PyObject *self, PyObject *args)
{
    PyObject *ows, *ox;
    Py_buffer ws, x;
    sl_ctx cx;
    int need, rc;
    (void) self;
    if (!PyArg_ParseTuple(args, "OO", &ows, &ox)) return NULL;
    if (dbuf(ows, &ws, 1, -1, "Arbeitsfeld") < 0) return NULL;
    if (sl_opt_dim((const double *) ws.buf) < 1) {
        PyBuffer_Release(&ws);
        PyErr_SetString(PyExc_ValueError, "interner Fehler: Arbeitsfeld des Optimierers ungueltig");
        return NULL;
    }
    if (dbuf(ox, &x, 1, sl_opt_dim((const double *) ws.buf), "x") < 0) { PyBuffer_Release(&ws); return NULL; }
    ctx_init(&cx);
    rc = sl_opt_ask(&cx, (const double *) ws.buf, (double *) x.buf, &need);
    PyBuffer_Release(&ws); PyBuffer_Release(&x);
    if (finish(&cx, rc) < 0) return NULL;
    return PyLong_FromLong(need);
}

/* slc_opt_tell(ws, f, g|None) */
static PyObject *slc_opt_tell(PyObject *self, PyObject *args)
{
    PyObject *ows, *og;
    double f;
    Py_buffer ws, g;
    const double *pg;
    sl_ctx cx;
    int rc, hg;
    (void) self;
    if (!PyArg_ParseTuple(args, "OdO", &ows, &f, &og)) return NULL;
    if (dbuf(ows, &ws, 1, -1, "Arbeitsfeld") < 0) return NULL;
    if (sl_opt_dim((const double *) ws.buf) < 1) {
        PyBuffer_Release(&ws);
        PyErr_SetString(PyExc_ValueError, "interner Fehler: Arbeitsfeld des Optimierers ungueltig");
        return NULL;
    }
    if ((hg = obuf(og, &g, sl_opt_dim((const double *) ws.buf), "Gradient", &pg)) < 0) { PyBuffer_Release(&ws); return NULL; }
    ctx_init(&cx);
    rc = sl_opt_tell(&cx, (double *) ws.buf, f, pg);
    PyBuffer_Release(&ws);
    if (hg > 0) PyBuffer_Release(&g);
    if (finish(&cx, rc) < 0) return NULL;
    Py_RETURN_NONE;
}

/* slc_opt_result(ws, x_out) -> (value, code, iterations, nfev, ngev, evaluations, message) */
static PyObject *slc_opt_result(PyObject *self, PyObject *args)
{
    PyObject *ows, *ox;
    Py_buffer ws, x;
    double f;
    int code, iter, nfev, ngev, reason, ntot;
    (void) self;
    if (!PyArg_ParseTuple(args, "OO", &ows, &ox)) return NULL;
    if (dbuf(ows, &ws, 0, -1, "Arbeitsfeld") < 0) return NULL;
    if (sl_opt_dim((const double *) ws.buf) < 1) {
        PyBuffer_Release(&ws);
        PyErr_SetString(PyExc_ValueError, "interner Fehler: Arbeitsfeld des Optimierers ungueltig");
        return NULL;
    }
    if (dbuf(ox, &x, 1, sl_opt_dim((const double *) ws.buf), "x") < 0) { PyBuffer_Release(&ws); return NULL; }
    sl_opt_result((const double *) ws.buf, (double *) x.buf, &f, &code, &iter, &nfev, &ngev);
    sl_opt_info((const double *) ws.buf, &reason, &ntot);
    PyBuffer_Release(&ws); PyBuffer_Release(&x);
    return Py_BuildValue("(diiiiis)", f, code, iter, nfev, ngev, ntot, sl_opt_message(reason));
}

/* ── Pruefhilfen ── */

/* slc_opt_testfn(id, x, g_out|None) -> f */
static PyObject *slc_opt_testfn(PyObject *self, PyObject *args)
{
    PyObject *ox, *og;
    Py_buffer x, g;
    int id, hg = 0;
    double f;
    (void) self;
    if (!PyArg_ParseTuple(args, "iOO", &id, &ox, &og)) return NULL;
    if (dbuf(ox, &x, 0, -1, "x") < 0) return NULL;
    if (og != Py_None) {
        if (dbuf(og, &g, 1, NDBL(x), "Gradient") < 0) { PyBuffer_Release(&x); return NULL; }
        hg = 1;
    }
    f = sl_opt_testfn(id, (int) NDBL(x), (const double *) x.buf, hg ? (double *) g.buf : NULL);
    PyBuffer_Release(&x);
    if (hg) PyBuffer_Release(&g);
    return PyFloat_FromDouble(f);
}

/* slc_opt_minimize_test(id, method, x_inout, lo|None, hi|None, ctrl-Tupel, parscale|None, use_grad)
 * -> (value, code, iterations, nfev, evaluations) */
static PyObject *slc_opt_minimize_test(PyObject *self, PyObject *args)
{
    PyObject *ox, *olo, *ohi, *ops;
    int id, m, use_grad, rc, hl = 0, hh = 0, hp = 0, code = 0, iter = 0, nfev = 0, ntot = 0;
    double c_maxit, c_maxfev, f = 0.0;
    Py_buffer x, lo, hi, ps;
    const double *plo, *phi, *pps;
    sl_opt_ctrl c;
    sl_ctx cx;
    Py_ssize_t n;
    (void) self;
    sl_opt_ctrl_default(&c, SL_OPT_BFGS);
    if (!PyArg_ParseTuple(args, "iiOOO(dddddd)Op", &id, &m, &ox, &olo, &ohi, &c_maxit, &c_maxfev, &c.reltol,
                          &c.gtol, &c.xtol, &c.fnscale, &ops, &use_grad))
        return NULL;
    c.maxit = (int) c_maxit;
    c.maxfev = (int) c_maxfev;
    if (dbuf(ox, &x, 1, -1, "par") < 0) return NULL;
    n = NDBL(x);
    if ((hl = obuf(olo, &lo, n, "lower", &plo)) < 0) goto fail;
    if ((hh = obuf(ohi, &hi, n, "upper", &phi)) < 0) goto fail;
    if ((hp = obuf(ops, &ps, n, "parscale", &pps)) < 0) goto fail;
    c.parscale = pps;
    ctx_init(&cx);
    rc = sl_opt_test_minimize(&cx, id, m, (int) n, (double *) x.buf, plo, phi, &c, use_grad, &f, &code, &iter,
                              &nfev, &ntot);
    PyBuffer_Release(&x);
    if (hl > 0) PyBuffer_Release(&lo);
    if (hh > 0) PyBuffer_Release(&hi);
    if (hp > 0) PyBuffer_Release(&ps);
    if (finish(&cx, rc) < 0) return NULL;
    return Py_BuildValue("(diiii)", f, code, iter, nfev, ntot);
fail:
    PyBuffer_Release(&x);
    if (hl > 0) PyBuffer_Release(&lo);
    if (hh > 0) PyBuffer_Release(&hi);
    return NULL;
}

/* slc_numgrad_test(id, x, lo|None, hi|None, g_out) */
static PyObject *slc_numgrad_test(PyObject *self, PyObject *args)
{
    PyObject *ox, *olo, *ohi, *og;
    Py_buffer x, lo, hi, g;
    const double *plo, *phi;
    int id, rc, hl = 0, hh = 0, cnt = 0;
    sl_ctx cx;
    Py_ssize_t n;
    (void) self;
    if (!PyArg_ParseTuple(args, "iOOOO", &id, &ox, &olo, &ohi, &og)) return NULL;
    if (dbuf(ox, &x, 0, -1, "x") < 0) return NULL;
    n = NDBL(x);
    if (dbuf(og, &g, 1, n, "Gradient") < 0) { PyBuffer_Release(&x); return NULL; }
    if ((hl = obuf(olo, &lo, n, "lower", &plo)) < 0) goto fail;
    if ((hh = obuf(ohi, &hi, n, "upper", &phi)) < 0) goto fail;
    ctx_init(&cx);
    rc = sl_opt_test_numgrad(&cx, id, (int) n, (const double *) x.buf, plo, phi, (double *) g.buf, &cnt);
    PyBuffer_Release(&x); PyBuffer_Release(&g);
    if (hl > 0) PyBuffer_Release(&lo);
    if (hh > 0) PyBuffer_Release(&hi);
    if (finish(&cx, rc) < 0) return NULL;
    Py_RETURN_NONE;
fail:
    PyBuffer_Release(&x); PyBuffer_Release(&g);
    if (hl > 0) PyBuffer_Release(&lo);
    return NULL;
}

PyMethodDef simlev_ext_slc_opt_methods[] = {
    {"slc_opt_wsize", slc_opt_wsize, METH_VARARGS, "slc_opt_wsize(method, n) -> Laenge des Arbeitsfelds"},
    {"slc_opt_init", slc_opt_init, METH_VARARGS, "slc_opt_init(ws, method, x0, lo, hi, ctrl, parscale, have_grad)"},
    {"slc_opt_ask", slc_opt_ask, METH_VARARGS, "slc_opt_ask(ws, x_out) -> need"},
    {"slc_opt_tell", slc_opt_tell, METH_VARARGS, "slc_opt_tell(ws, f, g_or_None)"},
    {"slc_opt_result", slc_opt_result, METH_VARARGS, "slc_opt_result(ws, x_out) -> (value, code, iter, nfev, ngev, evaluations, message)"},
    {"slc_opt_testfn", slc_opt_testfn, METH_VARARGS, "slc_opt_testfn(id, x, g_out_or_None) -> f"},
    {"slc_opt_minimize_test", slc_opt_minimize_test, METH_VARARGS, "slc_opt_minimize_test(id, method, x, lo, hi, ctrl, parscale, use_grad)"},
    {"slc_numgrad_test", slc_numgrad_test, METH_VARARGS, "slc_numgrad_test(id, x, lo, hi, g_out)"},
    {NULL, NULL, 0, NULL}
};

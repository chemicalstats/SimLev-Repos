/*
 * python/src/_ext_slc_linalg.c -- Python-Huellen der Etappe 9.2 der C-Bibliothek slc im Modul
 * simlev._ext: lineare Algebra, Matrixprodukt, kleinste Quadrate und Logit-IRLS, Stineman,
 * Glaettungsspline, Kerndichte
 *
 * Die Kerne src/core/slc_{linalg,matmul,lsq,stine,spline,kde}.c sind Byte-fuer-Byte-Kopien der
 * kanonischen Quellen in core/ (tools/core_sync.py); nur diese Huelle gibt es nur hier. Die
 * Python-Seite (simlev/_lib_linalg.py) prueft Argumente und legt die Felder an (float64,
 * eindimensional; Matrizen spaltenweise); die Huellen pruefen Typ, Laenge und Beschreibbarkeit.
 * Rueckmeldungen wie _ext_slc.c (Entwurf C.4): Warnungen nach dem Aufruf mit warnings.warn,
 * Fehler als ValueError mit dem Text des Kerns, Abbruch ueber PyErr_CheckSignals().
 */
#define PY_SSIZE_T_CLEAN
#include <Python.h>

#include <stdint.h>
#include <string.h>

#include "core/slc.h"

/* ── Hilfen (wie _ext_slc.c) ── */

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

/* Puffer mit itemsize/Format pruefen; len >= 0: genau so viele Elemente */
static int get_buf(PyObject *o, Py_buffer *v, int writable, Py_ssize_t itemsize, const char *fmts,
                   Py_ssize_t len, const char *what)
{
    int flags = PyBUF_C_CONTIGUOUS | PyBUF_FORMAT | (writable ? PyBUF_WRITABLE : 0);
    if (PyObject_GetBuffer(o, v, flags) < 0) return -1;
    if (v->itemsize != itemsize || v->format == NULL || strchr(fmts, v->format[strlen(v->format) - 1]) == NULL) {
        PyBuffer_Release(v);
        PyErr_Format(PyExc_TypeError, "interner Fehler: %s hat den falschen Typ", what);
        return -1;
    }
    if (len >= 0 && v->len / v->itemsize != len) {
        PyBuffer_Release(v);
        PyErr_Format(PyExc_TypeError, "interner Fehler: %s hat die falsche Laenge", what);
        return -1;
    }
    return 0;
}

#define DBUF(o, v, w, len, what) get_buf((o), (v), (w), 8, "d", (len), (what))
#define NITEMS(v) ((v).len / (v).itemsize)

static void rel(Py_buffer *v) { if (v->obj) PyBuffer_Release(v); }

static int check_dim(int a, const char *what)
{
    if (a < 0) { PyErr_Format(PyExc_ValueError, "interner Fehler: %s negativ", what); return -1; }
    return 0;
}

/* ── lineare Algebra ── */

static PyObject *slc_chol(PyObject *self, PyObject *args)
{
    PyObject *a, *o;
    int n, st;
    Py_buffer va = {0}, vo = {0};
    sl_ctx cx;
    (void) self;
    if (!PyArg_ParseTuple(args, "OOi", &a, &o, &n) || check_dim(n, "n") < 0) return NULL;
    if (DBUF(a, &va, 0, (Py_ssize_t) n * n, "a") < 0) return NULL;
    if (DBUF(o, &vo, 1, (Py_ssize_t) n * n, "Ausgabe") < 0) { rel(&va); return NULL; }
    ctx_init(&cx);
    st = sl_chol(&cx, n, (const double *) va.buf, (double *) vo.buf);
    rel(&va); rel(&vo);
    if (finish(&cx, st) < 0) return NULL;
    Py_RETURN_NONE;
}

static PyObject *slc_chol_band(PyObject *self, PyObject *args)
{
    PyObject *ab;
    int n, kd, st;
    Py_buffer v = {0};
    sl_ctx cx;
    (void) self;
    if (!PyArg_ParseTuple(args, "Oii", &ab, &n, &kd) || check_dim(n, "n") < 0 || check_dim(kd, "kd") < 0) return NULL;
    if (DBUF(ab, &v, 1, (Py_ssize_t) n * (kd + 1), "ab") < 0) return NULL;
    ctx_init(&cx);
    st = sl_chol_band(&cx, n, kd, (double *) v.buf);
    rel(&v);
    if (finish(&cx, st) < 0) return NULL;
    Py_RETURN_NONE;
}

static PyObject *slc_trisolve(PyObject *self, PyObject *args)
{
    PyObject *r, *b;
    int n, nrhs, upper, trans, st;
    Py_buffer vr = {0}, vb = {0};
    sl_ctx cx;
    (void) self;
    if (!PyArg_ParseTuple(args, "OOiipp", &r, &b, &n, &nrhs, &upper, &trans) || check_dim(n, "n") < 0 || check_dim(nrhs, "nrhs") < 0) return NULL;
    if (DBUF(r, &vr, 0, (Py_ssize_t) n * n, "r") < 0) return NULL;
    if (DBUF(b, &vb, 1, (Py_ssize_t) n * nrhs, "b") < 0) { rel(&vr); return NULL; }
    ctx_init(&cx);
    st = sl_trisolve(&cx, n, nrhs, (const double *) vr.buf, upper, trans, (double *) vb.buf);
    rel(&vr); rel(&vb);
    if (finish(&cx, st) < 0) return NULL;
    Py_RETURN_NONE;
}

static PyObject *slc_solve_spd(PyObject *self, PyObject *args)
{
    PyObject *a, *b;
    int n, nrhs, st;
    Py_buffer va = {0}, vb = {0};
    sl_ctx cx;
    (void) self;
    if (!PyArg_ParseTuple(args, "OOii", &a, &b, &n, &nrhs) || check_dim(n, "n") < 0 || check_dim(nrhs, "nrhs") < 0) return NULL;
    if (DBUF(a, &va, 0, (Py_ssize_t) n * n, "a") < 0) return NULL;
    if (DBUF(b, &vb, 1, (Py_ssize_t) n * nrhs, "b") < 0) { rel(&va); return NULL; }
    ctx_init(&cx);
    st = sl_solve_spd(&cx, n, nrhs, (const double *) va.buf, (double *) vb.buf, NULL);
    rel(&va); rel(&vb);
    if (finish(&cx, st) < 0) return NULL;
    Py_RETURN_NONE;
}

static PyObject *slc_logdet_spd(PyObject *self, PyObject *args)
{
    PyObject *a;
    int n, st;
    double ld = 0.0;
    Py_buffer va = {0};
    sl_ctx cx;
    (void) self;
    if (!PyArg_ParseTuple(args, "Oi", &a, &n) || check_dim(n, "n") < 0) return NULL;
    if (DBUF(a, &va, 0, (Py_ssize_t) n * n, "a") < 0) return NULL;
    ctx_init(&cx);
    st = sl_logdet_spd(&cx, n, (const double *) va.buf, &ld);
    rel(&va);
    if (finish(&cx, st) < 0) return NULL;
    return PyFloat_FromDouble(ld);
}

static PyObject *slc_eigen_sym(PyObject *self, PyObject *args)
{
    PyObject *a, *val, *vec;
    int n, st;
    Py_buffer va = {0}, vv = {0}, vw = {0};
    sl_ctx cx;
    (void) self;
    if (!PyArg_ParseTuple(args, "OiOO", &a, &n, &val, &vec) || check_dim(n, "n") < 0) return NULL;
    if (DBUF(a, &va, 0, (Py_ssize_t) n * n, "a") < 0) return NULL;
    if (DBUF(val, &vv, 1, n, "values") < 0) { rel(&va); return NULL; }
    if (vec != Py_None && DBUF(vec, &vw, 1, (Py_ssize_t) n * n, "vectors") < 0) { rel(&va); rel(&vv); return NULL; }
    ctx_init(&cx);
    st = sl_eigen_sym(&cx, n, (const double *) va.buf, vec != Py_None, (double *) vv.buf,
                      vec != Py_None ? (double *) vw.buf : NULL);
    rel(&va); rel(&vv); rel(&vw);
    if (finish(&cx, st) < 0) return NULL;
    Py_RETURN_NONE;
}

/* ── Matrixprodukt ── */

typedef void (*mm_fn)(int, int, int, const double *, const double *, double *);

static PyObject *mm(PyObject *args, mm_fn f, int kind)
{
    PyObject *a, *b, *c;
    int m, k, n;
    Py_ssize_t la, lb, lc;
    Py_buffer va = {0}, vb = {0}, vc = {0};
    if (!PyArg_ParseTuple(args, "OOOiii", &a, &b, &c, &m, &k, &n)) return NULL;
    if (check_dim(m, "m") < 0 || check_dim(k, "k") < 0 || check_dim(n, "n") < 0) return NULL;
    la = (Py_ssize_t) m * k;
    if (kind == 0) { lb = (Py_ssize_t) k * n; lc = (Py_ssize_t) m * n; }      /* A B */
    else if (kind == 1) { lb = (Py_ssize_t) m * n; lc = (Py_ssize_t) k * n; } /* X'Y */
    else { lb = (Py_ssize_t) n * k; lc = (Py_ssize_t) m * n; }                /* X Y' */
    if (DBUF(a, &va, 0, la, "x") < 0) return NULL;
    if (DBUF(b, &vb, 0, lb, "y") < 0) { rel(&va); return NULL; }
    if (DBUF(c, &vc, 1, lc, "Ausgabe") < 0) { rel(&va); rel(&vb); return NULL; }
    f(m, k, n, (const double *) va.buf, (const double *) vb.buf, (double *) vc.buf);
    rel(&va); rel(&vb); rel(&vc);
    Py_RETURN_NONE;
}

static PyObject *slc_matmul(PyObject *s, PyObject *a) { (void) s; return mm(a, sl_matmul, 0); }
static PyObject *slc_crossprod(PyObject *s, PyObject *a) { (void) s; return mm(a, sl_crossprod, 1); }
static PyObject *slc_tcrossprod(PyObject *s, PyObject *a) { (void) s; return mm(a, sl_tcrossprod, 2); }

/* ── kleinste Quadrate, Logit-IRLS ── */

static PyObject *slc_lsfit(PyObject *self, PyObject *args)
{
    PyObject *x, *y, *w, *coef, *fit, *perm;
    int m, n, pivot, st, rank = 0;
    double tol;
    Py_buffer vx = {0}, vy = {0}, vw = {0}, vc = {0}, vf = {0}, vp = {0};
    sl_ctx cx;
    (void) self;
    if (!PyArg_ParseTuple(args, "OOOiidiOOO", &x, &y, &w, &m, &n, &tol, &pivot, &coef, &fit, &perm)) return NULL;
    if (check_dim(m, "m") < 0 || check_dim(n, "n") < 0) return NULL;
    if (DBUF(x, &vx, 0, (Py_ssize_t) m * n, "x") < 0) goto fail;
    if (DBUF(y, &vy, 0, m, "y") < 0) goto fail;
    if (w != Py_None && DBUF(w, &vw, 0, m, "w") < 0) goto fail;
    if (DBUF(coef, &vc, 1, n, "coef") < 0) goto fail;
    if (DBUF(fit, &vf, 1, m, "fitted") < 0) goto fail;
    if (get_buf(perm, &vp, 1, 4, "iIl", n, "pivot (int32)") < 0) goto fail;
    ctx_init(&cx);
    st = sl_lsfit(&cx, m, n, (const double *) vx.buf, (const double *) vy.buf,
                  w != Py_None ? (const double *) vw.buf : NULL, tol, pivot, (double *) vc.buf,
                  (double *) vf.buf, &rank, (int32_t *) vp.buf);
    rel(&vx); rel(&vy); rel(&vw); rel(&vc); rel(&vf); rel(&vp);
    if (finish(&cx, st) < 0) return NULL;
    return PyLong_FromLong(rank);
fail:
    rel(&vx); rel(&vy); rel(&vw); rel(&vc); rel(&vf); rel(&vp);
    return NULL;
}

static PyObject *slc_logit_irls(PyObject *self, PyObject *args)
{
    PyObject *x, *y, *coef;
    int m, n, maxit, st, conv = 0;
    double tol;
    Py_buffer vx = {0}, vy = {0}, vc = {0};
    sl_ctx cx;
    (void) self;
    if (!PyArg_ParseTuple(args, "OOiiidO", &x, &y, &m, &n, &maxit, &tol, &coef)) return NULL;
    if (check_dim(m, "m") < 0 || check_dim(n, "n") < 0) return NULL;
    if (DBUF(x, &vx, 0, (Py_ssize_t) m * n, "x") < 0) goto fail;
    if (DBUF(y, &vy, 0, m, "y") < 0) goto fail;
    if (DBUF(coef, &vc, 1, n, "coef") < 0) goto fail;
    ctx_init(&cx);
    st = sl_logit_irls(&cx, m, n, (const double *) vx.buf, (const double *) vy.buf, maxit, tol, (double *) vc.buf, &conv);
    rel(&vx); rel(&vy); rel(&vc);
    if (finish(&cx, st) < 0) return NULL;
    return PyBool_FromLong(conv);
fail:
    rel(&vx); rel(&vy); rel(&vc);
    return NULL;
}

/* ── Stineman ── */

static PyObject *slc_stineman(PyObject *self, PyObject *args)
{
    PyObject *x, *y, *xo, *o;
    int st;
    Py_buffer vx = {0}, vy = {0}, vxo = {0}, vo = {0};
    sl_ctx cx;
    (void) self;
    if (!PyArg_ParseTuple(args, "OOOO", &x, &y, &xo, &o)) return NULL;
    if (DBUF(x, &vx, 0, -1, "x") < 0) goto fail;
    if (DBUF(y, &vy, 0, NITEMS(vx), "y") < 0) goto fail;
    if (DBUF(xo, &vxo, 0, -1, "xout") < 0) goto fail;
    if (DBUF(o, &vo, 1, NITEMS(vxo), "Ausgabe") < 0) goto fail;
    ctx_init(&cx);
    st = sl_stineman(&cx, (int) NITEMS(vx), (const double *) vx.buf, (const double *) vy.buf, (int) NITEMS(vxo),
                     (const double *) vxo.buf, (double *) vo.buf);
    rel(&vx); rel(&vy); rel(&vxo); rel(&vo);
    if (finish(&cx, st) < 0) return NULL;
    Py_RETURN_NONE;
fail:
    rel(&vx); rel(&vy); rel(&vxo); rel(&vo);
    return NULL;
}

static PyObject *slc_stineman_slopes(PyObject *self, PyObject *args)
{
    PyObject *x, *y, *o;
    int scale, st;
    Py_buffer vx = {0}, vy = {0}, vo = {0};
    sl_ctx cx;
    (void) self;
    if (!PyArg_ParseTuple(args, "OOpO", &x, &y, &scale, &o)) return NULL;
    if (DBUF(x, &vx, 0, -1, "x") < 0) goto fail;
    if (DBUF(y, &vy, 0, NITEMS(vx), "y") < 0) goto fail;
    if (DBUF(o, &vo, 1, NITEMS(vx), "Ausgabe") < 0) goto fail;
    ctx_init(&cx);
    st = sl_stineman_slopes(&cx, (int) NITEMS(vx), (const double *) vx.buf, (const double *) vy.buf, scale, (double *) vo.buf);
    rel(&vx); rel(&vy); rel(&vo);
    if (finish(&cx, st) < 0) return NULL;
    Py_RETURN_NONE;
fail:
    rel(&vx); rel(&vy); rel(&vo);
    return NULL;
}

static PyObject *slc_stineman_eval(PyObject *self, PyObject *args)
{
    PyObject *x, *y, *yp, *xo, *o;
    int st;
    Py_buffer vx = {0}, vy = {0}, vp = {0}, vxo = {0}, vo = {0};
    sl_ctx cx;
    (void) self;
    if (!PyArg_ParseTuple(args, "OOOOO", &x, &y, &yp, &xo, &o)) return NULL;
    if (DBUF(x, &vx, 0, -1, "x") < 0) goto fail;
    if (DBUF(y, &vy, 0, NITEMS(vx), "y") < 0) goto fail;
    if (DBUF(yp, &vp, 0, NITEMS(vx), "yp") < 0) goto fail;
    if (DBUF(xo, &vxo, 0, -1, "xout") < 0) goto fail;
    if (DBUF(o, &vo, 1, NITEMS(vxo), "Ausgabe") < 0) goto fail;
    ctx_init(&cx);
    st = sl_stineman_eval(&cx, (int) NITEMS(vx), (const double *) vx.buf, (const double *) vy.buf,
                          (const double *) vp.buf, (int) NITEMS(vxo), (const double *) vxo.buf, (double *) vo.buf);
    rel(&vx); rel(&vy); rel(&vp); rel(&vxo); rel(&vo);
    if (finish(&cx, st) < 0) return NULL;
    Py_RETURN_NONE;
fail:
    rel(&vx); rel(&vy); rel(&vp); rel(&vxo); rel(&vo);
    return NULL;
}

/* ── Glaettungsspline ── */

static PyObject *slc_smspline_fit(PyObject *self, PyObject *args)
{
    PyObject *x, *y, *w, *kn, *g, *gam;
    int st, nk = 0, n;
    double lam, lo = 0.0, df = 0.0, gcv = 0.0;
    Py_buffer vx = {0}, vy = {0}, vw = {0}, vk = {0}, vg = {0}, va = {0};
    sl_ctx cx;
    (void) self;
    if (!PyArg_ParseTuple(args, "OOOdOOO", &x, &y, &w, &lam, &kn, &g, &gam)) return NULL;
    if (DBUF(x, &vx, 0, -1, "x") < 0) goto fail;
    n = (int) NITEMS(vx);
    if (DBUF(y, &vy, 0, n, "y") < 0) goto fail;
    if (w != Py_None && DBUF(w, &vw, 0, n, "w") < 0) goto fail;
    if (DBUF(kn, &vk, 1, n, "knots") < 0) goto fail;
    if (DBUF(g, &vg, 1, n, "g") < 0) goto fail;
    if (DBUF(gam, &va, 1, n, "gam") < 0) goto fail;
    ctx_init(&cx);
    st = sl_smspline_fit(&cx, n, (const double *) vx.buf, (const double *) vy.buf,
                         w != Py_None ? (const double *) vw.buf : NULL, lam, &nk, (double *) vk.buf,
                         (double *) vg.buf, (double *) va.buf, &lo, &df, &gcv);
    rel(&vx); rel(&vy); rel(&vw); rel(&vk); rel(&vg); rel(&va);
    if (finish(&cx, st) < 0) return NULL;
    return Py_BuildValue("iddd", nk, lo, df, gcv);
fail:
    rel(&vx); rel(&vy); rel(&vw); rel(&vk); rel(&vg); rel(&va);
    return NULL;
}

static PyObject *slc_smspline_predict(PyObject *self, PyObject *args)
{
    PyObject *kn, *g, *gam, *xo, *o;
    int st;
    Py_buffer vk = {0}, vg = {0}, va = {0}, vxo = {0}, vo = {0};
    sl_ctx cx;
    (void) self;
    if (!PyArg_ParseTuple(args, "OOOOO", &kn, &g, &gam, &xo, &o)) return NULL;
    if (DBUF(kn, &vk, 0, -1, "knots") < 0) goto fail;
    if (DBUF(g, &vg, 0, NITEMS(vk), "g") < 0) goto fail;
    if (DBUF(gam, &va, 0, NITEMS(vk), "gam") < 0) goto fail;
    if (DBUF(xo, &vxo, 0, -1, "x") < 0) goto fail;
    if (DBUF(o, &vo, 1, NITEMS(vxo), "Ausgabe") < 0) goto fail;
    ctx_init(&cx);
    st = sl_smspline_predict(&cx, (int) NITEMS(vk), (const double *) vk.buf, (const double *) vg.buf,
                             (const double *) va.buf, (int) NITEMS(vxo), (const double *) vxo.buf, (double *) vo.buf);
    rel(&vk); rel(&vg); rel(&va); rel(&vxo); rel(&vo);
    if (finish(&cx, st) < 0) return NULL;
    Py_RETURN_NONE;
fail:
    rel(&vk); rel(&vg); rel(&va); rel(&vxo); rel(&vo);
    return NULL;
}

/* ── Kerndichte ── */

static PyObject *slc_kde(PyObject *self, PyObject *args)
{
    PyObject *x, *w, *gx, *gy;
    double bw, from, to;
    int st;
    Py_buffer vx = {0}, vw = {0}, vgx = {0}, vgy = {0};
    sl_ctx cx;
    (void) self;
    if (!PyArg_ParseTuple(args, "OOdddOO", &x, &w, &bw, &from, &to, &gx, &gy)) return NULL;
    if (DBUF(x, &vx, 0, -1, "x") < 0) goto fail;
    if (w != Py_None && DBUF(w, &vw, 0, NITEMS(vx), "weights") < 0) goto fail;
    if (DBUF(gx, &vgx, 1, -1, "Gitter") < 0) goto fail;
    if (DBUF(gy, &vgy, 1, NITEMS(vgx), "Dichte") < 0) goto fail;
    if (NITEMS(vgx) > 2147483647) { PyErr_SetString(PyExc_ValueError, "density: zu viele Gitterpunkte"); goto fail; }
    ctx_init(&cx);
    st = sl_kde(&cx, (int64_t) NITEMS(vx), (const double *) vx.buf, w != Py_None ? (const double *) vw.buf : NULL, bw,
                (int) NITEMS(vgx), from, to, (double *) vgx.buf, (double *) vgy.buf);
    rel(&vx); rel(&vw); rel(&vgx); rel(&vgy);
    if (finish(&cx, st) < 0) return NULL;
    Py_RETURN_NONE;
fail:
    rel(&vx); rel(&vw); rel(&vgx); rel(&vgy);
    return NULL;
}

static PyObject *slc_kde_bw(PyObject *self, PyObject *args)
{
    PyObject *x;
    int st;
    double bw = 0.0;
    Py_buffer vx = {0};
    sl_ctx cx;
    (void) self;
    if (!PyArg_ParseTuple(args, "O", &x)) return NULL;
    if (DBUF(x, &vx, 0, -1, "x") < 0) return NULL;
    ctx_init(&cx);
    st = sl_kde_bw(&cx, (int64_t) NITEMS(vx), (const double *) vx.buf, &bw);
    rel(&vx);
    if (finish(&cx, st) < 0) return NULL;
    return PyFloat_FromDouble(bw);
}

PyMethodDef simlev_ext_slc_linalg_methods[] = {
    {"slc_chol", slc_chol, METH_VARARGS, "slc_chol(a, out, n): R mit R'R = a (spaltenweise)"},
    {"slc_chol_band", slc_chol_band, METH_VARARGS, "slc_chol_band(ab, n, kd): Band-Cholesky an Ort und Stelle"},
    {"slc_trisolve", slc_trisolve, METH_VARARGS, "slc_trisolve(r, b, n, nrhs, upper, trans): b <- op(T)^-1 b"},
    {"slc_solve_spd", slc_solve_spd, METH_VARARGS, "slc_solve_spd(a, b, n, nrhs): b <- a^-1 b"},
    {"slc_logdet_spd", slc_logdet_spd, METH_VARARGS, "slc_logdet_spd(a, n) -> log det a"},
    {"slc_eigen_sym", slc_eigen_sym, METH_VARARGS, "slc_eigen_sym(a, n, values, vectors_or_None)"},
    {"slc_matmul", slc_matmul, METH_VARARGS, "slc_matmul(a, b, c, m, k, n): c = a b"},
    {"slc_crossprod", slc_crossprod, METH_VARARGS, "slc_crossprod(x, y, c, m, k, n): c = x'y"},
    {"slc_tcrossprod", slc_tcrossprod, METH_VARARGS, "slc_tcrossprod(x, y, c, m, k, n): c = x y'"},
    {"slc_lsfit", slc_lsfit, METH_VARARGS, "slc_lsfit(x, y, w, m, n, tol, pivot, coef, fitted, perm) -> rank"},
    {"slc_logit_irls", slc_logit_irls, METH_VARARGS, "slc_logit_irls(x, y, m, n, maxit, tol, coef) -> converged"},
    {"slc_stineman", slc_stineman, METH_VARARGS, "slc_stineman(x, y, xout, out)"},
    {"slc_stineman_slopes", slc_stineman_slopes, METH_VARARGS, "slc_stineman_slopes(x, y, scale, out)"},
    {"slc_stineman_eval", slc_stineman_eval, METH_VARARGS, "slc_stineman_eval(x, y, yp, xout, out)"},
    {"slc_smspline_fit", slc_smspline_fit, METH_VARARGS, "slc_smspline_fit(x, y, w, lambda, knots, g, gam) -> (nk, lambda, df, gcv)"},
    {"slc_smspline_predict", slc_smspline_predict, METH_VARARGS, "slc_smspline_predict(knots, g, gam, x, out)"},
    {"slc_kde", slc_kde, METH_VARARGS, "slc_kde(x, w, bw, from, to, xgrid, y)"},
    {"slc_kde_bw", slc_kde_bw, METH_VARARGS, "slc_kde_bw(x) -> Bandbreite"},
    {NULL, NULL, 0, NULL}
};

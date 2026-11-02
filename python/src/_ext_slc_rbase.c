/*
 * python/src/_ext_slc_rbase.c -- Python-Huellen der Grundfunktionen mit R-Regeln (N8) im Modul
 * simlev._ext: Summen, Mittel, Varianz, Kumulationen, Potenz, Ordnung, Rang, partielle Sortierung,
 * Quantile, tabulate, findInterval, cov/cor
 *
 * Die Kerne src/core/slc_rbase*.c sind Byte-fuer-Byte-Kopien der kanonischen Quellen in core/
 * (tools/core_sync.py); nur diese Huelle gibt es nur hier. Die Python-Seite (simlev/_r/rnum.py,
 * base.py, stats_sort.py, stats_cor.py) prueft Argumente und legt die Felder an (float64 bzw. int64,
 * eindimensional, zusammenhaengend; Matrizen spaltenweise). Die Huellen pruefen Typ, Laenge und
 * Beschreibbarkeit. Fehler wie _ext_slc.c: ValueError mit dem Text des Kerns, MemoryError.
 */
#define PY_SSIZE_T_CLEAN
#include <Python.h>

#include <stdint.h>
#include <string.h>

#include "core/slc_rbase.h"

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
#define LBUF(o, v, w, len, what) get_buf((o), (v), (w), 8, "qlL", (len), (what))
#define NITEMS(v) ((Py_ssize_t) ((v).len / (v).itemsize))

static void rel(Py_buffer *v) { if (v->obj) PyBuffer_Release(v); }

static PyObject *nomem(void) { return PyErr_NoMemory(); }

/* sum, prod, mean, var: (x[, narm]) -> float */
static PyObject *slc_r_sum(PyObject *self, PyObject *args)
{
    PyObject *x;
    int narm = 0, kind;
    double r;
    Py_buffer v = {0};
    (void) self;
    if (!PyArg_ParseTuple(args, "Oii", &x, &kind, &narm)) return NULL;
    if (DBUF(x, &v, 0, -1, "x") < 0) return NULL;
    switch (kind) {
    case 0: r = sl_r_sum(NITEMS(v), (const double *) v.buf, narm); break;
    case 1: r = sl_r_prod(NITEMS(v), (const double *) v.buf, narm); break;
    case 2: r = sl_r_mean(NITEMS(v), (const double *) v.buf); break;
    default: r = sl_r_var(NITEMS(v), (const double *) v.buf); break;
    }
    rel(&v);
    return PyFloat_FromDouble(r);
}

static PyObject *slc_r_mean_int(PyObject *self, PyObject *args)
{
    PyObject *x;
    double r;
    Py_buffer v = {0};
    (void) self;
    if (!PyArg_ParseTuple(args, "O", &x)) return NULL;
    if (LBUF(x, &v, 0, -1, "x") < 0) return NULL;
    r = sl_r_mean_int(NITEMS(v), (const int64_t *) v.buf);
    rel(&v);
    return PyFloat_FromDouble(r);
}

/* cumsum, cumprod, cummax, cummin: (kind, x, out) */
static PyObject *slc_r_cum(PyObject *self, PyObject *args)
{
    PyObject *x, *o;
    int kind;
    Py_buffer vx = {0}, vo = {0};
    Py_ssize_t n;
    (void) self;
    if (!PyArg_ParseTuple(args, "iOO", &kind, &x, &o)) return NULL;
    if (DBUF(x, &vx, 0, -1, "x") < 0) return NULL;
    n = NITEMS(vx);
    if (DBUF(o, &vo, 1, n, "Ausgabe") < 0) { rel(&vx); return NULL; }
    switch (kind) {
    case 0: sl_r_cumsum(n, (const double *) vx.buf, (double *) vo.buf); break;
    case 1: sl_r_cumprod(n, (const double *) vx.buf, (double *) vo.buf); break;
    case 2: sl_r_cummax(n, (const double *) vx.buf, (double *) vo.buf); break;
    default: sl_r_cummin(n, (const double *) vx.buf, (double *) vo.buf); break;
    }
    rel(&vx); rel(&vo);
    Py_RETURN_NONE;
}

/* colSums/rowSums: (x, nr, nc, narm, mean, rows, out) */
static PyObject *slc_r_margsums(PyObject *self, PyObject *args)
{
    PyObject *x, *o;
    Py_ssize_t nr, nc;
    int narm, mean, rows, st = 0;
    Py_buffer vx = {0}, vo = {0};
    (void) self;
    if (!PyArg_ParseTuple(args, "OnnpppO", &x, &nr, &nc, &narm, &mean, &rows, &o)) return NULL;
    if (nr < 0 || nc < 0) { PyErr_SetString(PyExc_ValueError, "interner Fehler: Dimension negativ"); return NULL; }
    if (DBUF(x, &vx, 0, nr * nc, "x") < 0) return NULL;
    if (DBUF(o, &vo, 1, rows ? nr : nc, "Ausgabe") < 0) { rel(&vx); return NULL; }
    if (rows) st = sl_r_rowsums(nr, nc, (const double *) vx.buf, narm, mean, (double *) vo.buf);
    else sl_r_colsums(nr, nc, (const double *) vx.buf, narm, mean, (double *) vo.buf);
    rel(&vx); rel(&vo);
    if (st) return nomem();
    Py_RETURN_NONE;
}

static PyObject *slc_r_pow(PyObject *self, PyObject *args)
{
    PyObject *x, *o;
    double y;
    Py_buffer vx = {0}, vo = {0};
    (void) self;
    if (!PyArg_ParseTuple(args, "OdO", &x, &y, &o)) return NULL;
    if (DBUF(x, &vx, 0, -1, "x") < 0) return NULL;
    if (DBUF(o, &vo, 1, NITEMS(vx), "Ausgabe") < 0) { rel(&vx); return NULL; }
    sl_r_pow(NITEMS(vx), (const double *) vx.buf, y, (double *) vo.buf);
    rel(&vx); rel(&vo);
    Py_RETURN_NONE;
}

static PyObject *slc_r_pow1(PyObject *self, PyObject *args)
{
    double x, y;
    (void) self;
    if (!PyArg_ParseTuple(args, "dd", &x, &y)) return NULL;
    return PyFloat_FromDouble(sl_r_pow1(x, y));
}

/* order: (keys, n, nkey, dec (int32), nalast, out int64) -> nout */
static PyObject *slc_r_order(PyObject *self, PyObject *args)
{
    PyObject *k, *d, *o;
    Py_ssize_t n;
    int nkey, nalast, st;
    int64_t nout = 0;
    Py_buffer vk = {0}, vd = {0}, vo = {0};
    (void) self;
    if (!PyArg_ParseTuple(args, "OniOiO", &k, &n, &nkey, &d, &nalast, &o)) return NULL;
    if (n < 0 || nkey < 1) { PyErr_SetString(PyExc_ValueError, "interner Fehler: Dimension"); return NULL; }
    if (DBUF(k, &vk, 0, n * nkey, "Schluessel") < 0) return NULL;
    if (get_buf(d, &vd, 0, 4, "i", nkey, "decreasing") < 0) { rel(&vk); return NULL; }
    if (LBUF(o, &vo, 1, n, "Ausgabe") < 0) { rel(&vk); rel(&vd); return NULL; }
    st = sl_r_order(n, nkey, (const double *) vk.buf, (const int *) vd.buf, nalast, (int64_t *) vo.buf, &nout);
    rel(&vk); rel(&vd); rel(&vo);
    if (st) return nomem();
    return PyLong_FromLongLong((long long) nout);
}

static PyObject *slc_r_rank(PyObject *self, PyObject *args)
{
    PyObject *x, *o;
    int ties, st;
    Py_buffer vx = {0}, vo = {0};
    (void) self;
    if (!PyArg_ParseTuple(args, "OiO", &x, &ties, &o)) return NULL;
    if (DBUF(x, &vx, 0, -1, "x") < 0) return NULL;
    if (DBUF(o, &vo, 1, NITEMS(vx), "Ausgabe") < 0) { rel(&vx); return NULL; }
    st = sl_r_rank(NITEMS(vx), (const double *) vx.buf, ties, (double *) vo.buf);
    rel(&vx); rel(&vo);
    if (st) return nomem();
    Py_RETURN_NONE;
}

/* psort: (x beschreibbar, k int64) */
static PyObject *slc_r_psort(PyObject *self, PyObject *args)
{
    PyObject *x, *k;
    int st;
    Py_buffer vx = {0}, vk = {0};
    (void) self;
    if (!PyArg_ParseTuple(args, "OO", &x, &k)) return NULL;
    if (DBUF(x, &vx, 1, -1, "x") < 0) return NULL;
    if (LBUF(k, &vk, 0, -1, "partial") < 0) { rel(&vx); return NULL; }
    st = sl_r_psort(NITEMS(vx), (double *) vx.buf, NITEMS(vk), (const int64_t *) vk.buf);
    rel(&vx); rel(&vk);
    if (st) return nomem();
    Py_RETURN_NONE;
}

static PyObject *slc_r_quantile(PyObject *self, PyObject *args)
{
    PyObject *x, *p, *o;
    int type, st;
    Py_buffer vx = {0}, vp = {0}, vo = {0};
    (void) self;
    if (!PyArg_ParseTuple(args, "OOiO", &x, &p, &type, &o)) return NULL;
    if (DBUF(x, &vx, 0, -1, "x") < 0) return NULL;
    if (DBUF(p, &vp, 0, -1, "probs") < 0) { rel(&vx); return NULL; }
    if (DBUF(o, &vo, 1, NITEMS(vp), "Ausgabe") < 0) { rel(&vx); rel(&vp); return NULL; }
    st = sl_r_quantile(NITEMS(vx), (const double *) vx.buf, NITEMS(vp), (const double *) vp.buf, type, (double *) vo.buf);
    rel(&vx); rel(&vp); rel(&vo);
    if (st == SL_ENOMEM) return nomem();
    if (st) { PyErr_SetString(PyExc_ValueError, "interner Fehler: type"); return NULL; }
    Py_RETURN_NONE;
}

static PyObject *slc_r_tabulate(PyObject *self, PyObject *args)
{
    PyObject *b, *o;
    Py_buffer vb = {0}, vo = {0};
    (void) self;
    if (!PyArg_ParseTuple(args, "OO", &b, &o)) return NULL;
    if (DBUF(b, &vb, 0, -1, "bin") < 0) return NULL;
    if (LBUF(o, &vo, 1, -1, "Ausgabe") < 0) { rel(&vb); return NULL; }
    sl_r_tabulate(NITEMS(vb), (const double *) vb.buf, NITEMS(vo), (int64_t *) vo.buf);
    rel(&vb); rel(&vo);
    Py_RETURN_NONE;
}

static PyObject *slc_r_findinterval(PyObject *self, PyObject *args)
{
    PyObject *v, *x, *o;
    int rc, ai, lo;
    Py_buffer vv = {0}, vx = {0}, vo = {0};
    (void) self;
    if (!PyArg_ParseTuple(args, "OOpppO", &v, &x, &rc, &ai, &lo, &o)) return NULL;
    if (DBUF(v, &vv, 0, -1, "vec") < 0) return NULL;
    if (DBUF(x, &vx, 0, -1, "x") < 0) { rel(&vv); return NULL; }
    if (DBUF(o, &vo, 1, NITEMS(vx), "Ausgabe") < 0) { rel(&vv); rel(&vx); return NULL; }
    sl_r_findinterval(NITEMS(vv), (const double *) vv.buf, NITEMS(vx), (const double *) vx.buf, rc, ai, lo,
                      (double *) vo.buf);
    rel(&vv); rel(&vx); rel(&vo);
    Py_RETURN_NONE;
}

/* cov: (x, n, ncx, y oder None, ncy, use, kendall, cor, ans) -> sd0 */
static PyObject *slc_r_cov(PyObject *self, PyObject *args)
{
    PyObject *x, *y, *a;
    Py_ssize_t n, ncx, ncy;
    int use, kendall, cor, st, sd0 = 0;
    Py_buffer vx = {0}, vy = {0}, va = {0};
    sl_ctx cx;
    (void) self;
    if (!PyArg_ParseTuple(args, "OnnOniiiO", &x, &n, &ncx, &y, &ncy, &use, &kendall, &cor, &a)) return NULL;
    if (n < 0 || ncx < 0 || ncy < 0) { PyErr_SetString(PyExc_ValueError, "interner Fehler: Dimension negativ"); return NULL; }
    if (y == Py_None) ncy = ncx;
    if (DBUF(x, &vx, 0, n * ncx, "x") < 0) return NULL;
    if (y != Py_None && DBUF(y, &vy, 0, n * ncy, "y") < 0) { rel(&vx); return NULL; }
    if (DBUF(a, &va, 1, ncx * ncy, "Ausgabe") < 0) { rel(&vx); rel(&vy); return NULL; }
    sl_ctx_init(&cx);
    st = sl_r_cov(&cx, n, ncx, (const double *) vx.buf, ncy, y == Py_None ? NULL : (const double *) vy.buf,
                  use, kendall, cor, (double *) va.buf, &sd0);
    rel(&vx); rel(&vy); rel(&va);
    if (st == SL_ENOMEM) return nomem();
    if (st) { PyErr_SetString(PyExc_ValueError, cx.msg); return NULL; }
    return PyBool_FromLong(sd0);
}

PyMethodDef simlev_ext_slc_rbase_methods[] = {
    {"slc_r_sum", slc_r_sum, METH_VARARGS, "slc_r_sum(x, kind, narm) -> float (kind 0 sum, 1 prod, 2 mean, 3 var)"},
    {"slc_r_mean_int", slc_r_mean_int, METH_VARARGS, "slc_r_mean_int(x int64) -> float"},
    {"slc_r_cum", slc_r_cum, METH_VARARGS, "slc_r_cum(kind, x, out): 0 cumsum, 1 cumprod, 2 cummax, 3 cummin"},
    {"slc_r_margsums", slc_r_margsums, METH_VARARGS, "slc_r_margsums(x, nr, nc, narm, mean, rows, out)"},
    {"slc_r_pow", slc_r_pow, METH_VARARGS, "slc_r_pow(x, y, out): x ^ y wie R"},
    {"slc_r_pow1", slc_r_pow1, METH_VARARGS, "slc_r_pow1(x, y) -> x ^ y wie R"},
    {"slc_r_order", slc_r_order, METH_VARARGS, "slc_r_order(keys, n, nkey, dec, nalast, out) -> nout"},
    {"slc_r_rank", slc_r_rank, METH_VARARGS, "slc_r_rank(x, ties, out)"},
    {"slc_r_psort", slc_r_psort, METH_VARARGS, "slc_r_psort(x, k): sort(x, partial = k) an Ort und Stelle"},
    {"slc_r_quantile", slc_r_quantile, METH_VARARGS, "slc_r_quantile(x, p, type, out)"},
    {"slc_r_tabulate", slc_r_tabulate, METH_VARARGS, "slc_r_tabulate(bin, out)"},
    {"slc_r_findinterval", slc_r_findinterval, METH_VARARGS, "slc_r_findinterval(vec, x, rc, ai, lo, out)"},
    {"slc_r_cov", slc_r_cov, METH_VARARGS, "slc_r_cov(x, n, ncx, y, ncy, use, kendall, cor, ans) -> sd0"},
    {NULL, NULL, 0, NULL}
};

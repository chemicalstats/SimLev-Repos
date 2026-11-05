/*
 * python/src/_ext_slc_rbase.cpp -- Python-Huellen der Grundfunktionen mit R-Regeln im Modul
 * simlev._ext: Summen, Mittel, Varianz, Kumulationen, Potenz, libm elementweise, Ordnung, Rang,
 * partielle Sortierung, Quantile, tabulate, findInterval, approx, cov/cor; Datumsformat und -lesen (slc_rbase_date.cpp),
 * R_strtod, %% und %/% in long double (slc_rbase_num.cpp)
 *
 * Die Kerne src/core/slc_rbase*.cpp sind Byte-fuer-Byte-Kopien der kanonischen Quellen in core/
 * (core/sync.py); nur diese Huelle gibt es nur hier. Die Python-Seite (simlev/_r/rnum.py,
 * base.py, stats_sort.py, stats_cor.py) prueft Argumente und legt die Felder an (float64 bzw. int64,
 * eindimensional, zusammenhaengend; Matrizen spaltenweise). Die Huellen pruefen Typ, Laenge und
 * Beschreibbarkeit. Fehler wie _ext_slc.cpp: ValueError mit dem Text des Kerns, MemoryError.
 */
#define PY_SSIZE_T_CLEAN
#include <Python.h>

#include <math.h>
#include <stdint.h>
#include <string.h>

#include "core/slc_rbase.h"

/* Methodentabelle mit C-Bindung (Deklaration in _ext_common.h) */
extern "C" {

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
    Py_buffer v = {};
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
    Py_buffer v = {};
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
    Py_buffer vx = {}, vo = {};
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
    Py_buffer vx = {}, vo = {};
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
    Py_buffer vx = {}, vo = {};
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

/* x ^ y mit Recycling: (x, y, out), Laengen >= 1, out max(nx, ny) */
static PyObject *slc_r_pow_rec(PyObject *self, PyObject *args)
{
    PyObject *x, *y, *o;
    Py_buffer vx = {}, vy = {}, vo = {};
    Py_ssize_t nx, ny;
    (void) self;
    if (!PyArg_ParseTuple(args, "OOO", &x, &y, &o)) return NULL;
    if (DBUF(x, &vx, 0, -1, "x") < 0) return NULL;
    if (DBUF(y, &vy, 0, -1, "y") < 0) { rel(&vx); return NULL; }
    nx = NITEMS(vx); ny = NITEMS(vy);
    if (nx < 1 || ny < 1) { rel(&vx); rel(&vy); PyErr_SetString(PyExc_ValueError, "interner Fehler: Laenge 0"); return NULL; }
    if (DBUF(o, &vo, 1, nx > ny ? nx : ny, "Ausgabe") < 0) { rel(&vx); rel(&vy); return NULL; }
    sl_r_pow_rec(nx, (const double *) vx.buf, ny, (const double *) vy.buf, (double *) vo.buf);
    rel(&vx); rel(&vy); rel(&vo);
    Py_RETURN_NONE;
}

/* libm elementweise wie R's math1: (kind, x, out) */
static PyObject *slc_r_math1(PyObject *self, PyObject *args)
{
    PyObject *x, *o;
    int kind;
    Py_buffer vx = {}, vo = {};
    (void) self;
    if (!PyArg_ParseTuple(args, "iOO", &kind, &x, &o)) return NULL;
    if (kind < SL_R_EXP || kind > SL_R_LOG10) { PyErr_SetString(PyExc_ValueError, "interner Fehler: kind"); return NULL; }
    if (DBUF(x, &vx, 0, -1, "x") < 0) return NULL;
    if (DBUF(o, &vo, 1, NITEMS(vx), "Ausgabe") < 0) { rel(&vx); return NULL; }
    sl_r_math1(kind, NITEMS(vx), (const double *) vx.buf, (double *) vo.buf);
    rel(&vx); rel(&vo);
    Py_RETURN_NONE;
}

/* order: (keys, n, nkey, dec (int32), nalast, out int64) -> nout */
static PyObject *slc_r_order(PyObject *self, PyObject *args)
{
    PyObject *k, *d, *o;
    Py_ssize_t n;
    int nkey, nalast, st;
    int64_t nout = 0;
    Py_buffer vk = {}, vd = {}, vo = {};
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
    Py_buffer vx = {}, vo = {};
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
    Py_buffer vx = {}, vk = {};
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
    Py_buffer vx = {}, vp = {}, vo = {};
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
    Py_buffer vb = {}, vo = {};
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
    Py_buffer vv = {}, vx = {}, vo = {};
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

/* approx: (x, y, v, method, yleft, yright, f, out); x, y gleich lang, out wie v */
static PyObject *slc_r_approx(PyObject *self, PyObject *args)
{
    PyObject *x, *y, *v, *o;
    int method;
    double yl, yr, f;
    Py_buffer vx = {}, vy = {}, vv = {}, vo = {};
    (void) self;
    if (!PyArg_ParseTuple(args, "OOOidddO", &x, &y, &v, &method, &yl, &yr, &f, &o)) return NULL;
    if (DBUF(x, &vx, 0, -1, "x") < 0) return NULL;
    if (DBUF(y, &vy, 0, NITEMS(vx), "y") < 0) { rel(&vx); return NULL; }
    if (DBUF(v, &vv, 0, -1, "v") < 0) { rel(&vx); rel(&vy); return NULL; }
    if (DBUF(o, &vo, 1, NITEMS(vv), "Ausgabe") < 0) { rel(&vx); rel(&vy); rel(&vv); return NULL; }
    sl_r_approx(NITEMS(vx), (const double *) vx.buf, (const double *) vy.buf, NITEMS(vv), (const double *) vv.buf,
                method, yl, yr, f, (double *) vo.buf);
    rel(&vx); rel(&vy); rel(&vv); rel(&vo);
    Py_RETURN_NONE;
}

/* cov: (x, n, ncx, y oder None, ncy, use, kendall, cor, ans) -> sd0 */
static PyObject *slc_r_cov(PyObject *self, PyObject *args)
{
    PyObject *x, *y, *a;
    Py_ssize_t n, ncx, ncy;
    int use, kendall, cor, st, sd0 = 0;
    Py_buffer vx = {}, vy = {}, va = {};
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

/* format.Date für einen Vektor: (days float64, fmts list[str | None][, digits_secs int]) -> list[str | None]
 * wie fmt._format_date_list (Länge max(n, nf) mit Wiederholung; NA, NaN, ±Inf, None und |Tage| >= 1e14 -> None).
 * digits_secs = getOption("digits.secs") für %OS ohne Ziffer (0..6); Ergebnis über 2048 Bytes ist wie in R
 * ein Fehler (ValueError "output string exceeded 2048 bytes"). */
static PyObject *slc_r_format_date(PyObject *self, PyObject *args)
{
    (void) self;
    PyObject *od, *of;
    int ds = 0;
    Py_buffer d = {};
    if (!PyArg_ParseTuple(args, "OO!|i", &od, &PyList_Type, &of, &ds)) return NULL;
    if (DBUF(od, &d, 0, -1, "days") < 0) return NULL;
    const double *z = (const double *) d.buf;
    const Py_ssize_t n = NITEMS(d), nf = PyList_GET_SIZE(of);
    const Py_ssize_t nout = n == 0 ? 0 : (n > nf ? n : nf);
    PyObject *out = PyList_New(nout);
    if (!out) { rel(&d); return NULL; }
    char sbuf[2048];
    for (Py_ssize_t i = 0; i < nout; i++) {
        const double zi = z[i % n];
        PyObject *f = nf ? PyList_GET_ITEM(of, i % nf) : Py_None;
        PyObject *r = NULL;
        if (zi != zi || f == Py_None || zi >= 1e14 || zi <= -1e14) {
            r = Py_None;
            Py_INCREF(r);
        } else {
            Py_ssize_t fl;
            const char *fs = PyUnicode_AsUTF8AndSize(f, &fl);
            if (!fs) { Py_DECREF(out); rel(&d); return NULL; }
            const int64_t len = sl_r_strftime((int64_t) floor(zi), fs, (int64_t) fl, ds, sbuf, (int64_t) sizeof sbuf);
            if (len == -2) {
                Py_DECREF(out);
                rel(&d);
                PyErr_SetString(PyExc_ValueError, "output string exceeded 2048 bytes");
                return NULL;
            }
            if (len == -3) { Py_DECREF(out); rel(&d); return nomem(); }
            if (len < 0) {
                r = Py_None;
                Py_INCREF(r);
            } else {
                r = PyUnicode_DecodeUTF8(sbuf, (Py_ssize_t) len, "strict");
            }
            if (!r) { Py_DECREF(out); rel(&d); return NULL; }
        }
        PyList_SET_ITEM(out, i, r);
    }
    rel(&d);
    return out;
}

/* as.Date(s, format = "%Y<sep>%m<sep>%d"): (s str, sep str) -> int | None */
static PyObject *slc_r_strptime_ymd(PyObject *self, PyObject *args)
{
    (void) self;
    const char *s, *sep;
    Py_ssize_t ls, lsep;
    if (!PyArg_ParseTuple(args, "s#s#", &s, &ls, &sep, &lsep)) return NULL;
    int64_t z;
    if (lsep != 1 || !sl_r_strptime_ymd(s, (int64_t) ls, sep[0], &z)) Py_RETURN_NONE;
    return PyLong_FromLongLong((long long) z);
}

/* weitere long-double-Wege (slc_rbase_num.cpp), wie Julia */

/* Zahlteil von R_strtod: (s bytes) -> (Wert, gelesene Bytes oder -1, Betrag > DBL_MAX) */
static PyObject *slc_r_strtod_num(PyObject *self, PyObject *args)
{
    (void) self;
    const char *s;
    Py_ssize_t ls;
    if (!PyArg_ParseTuple(args, "y#", &s, &ls)) return NULL;
    int64_t used = 0;
    int gt = 0;
    const double v = sl_r_strtod_num(s, (int64_t) ls, &used, &gt);
    return Py_BuildValue("dLO", v, (long long) used, gt ? Py_True : Py_False);
}

/* long-double-Teil von x1 %% x2 bzw. x1 %/% x2 (endliche Operanden) */
static PyObject *slc_r_fmod_ld(PyObject *self, PyObject *args)
{
    double x1, x2;
    (void) self;
    if (!PyArg_ParseTuple(args, "dd", &x1, &x2)) return NULL;
    return PyFloat_FromDouble(sl_r_fmod_ld(x1, x2));
}

static PyObject *slc_r_idiv_ld(PyObject *self, PyObject *args)
{
    double x1, x2;
    (void) self;
    if (!PyArg_ParseTuple(args, "dd", &x1, &x2)) return NULL;
    return PyFloat_FromDouble(sl_r_idiv_ld(x1, x2));
}

PyMethodDef simlev_ext_slc_rbase_methods[] = {
    {"slc_r_sum", slc_r_sum, METH_VARARGS, "slc_r_sum(x, kind, narm) -> float (kind 0 sum, 1 prod, 2 mean, 3 var)"},
    {"slc_r_mean_int", slc_r_mean_int, METH_VARARGS, "slc_r_mean_int(x int64) -> float"},
    {"slc_r_cum", slc_r_cum, METH_VARARGS, "slc_r_cum(kind, x, out): 0 cumsum, 1 cumprod, 2 cummax, 3 cummin"},
    {"slc_r_margsums", slc_r_margsums, METH_VARARGS, "slc_r_margsums(x, nr, nc, narm, mean, rows, out)"},
    {"slc_r_pow", slc_r_pow, METH_VARARGS, "slc_r_pow(x, y, out): x ^ y wie R"},
    {"slc_r_pow1", slc_r_pow1, METH_VARARGS, "slc_r_pow1(x, y) -> x ^ y wie R"},
    {"slc_r_pow_rec", slc_r_pow_rec, METH_VARARGS, "slc_r_pow_rec(x, y, out): x ^ y wie R mit Recycling"},
    {"slc_r_math1", slc_r_math1, METH_VARARGS, "slc_r_math1(kind, x, out): exp, log, log1p, expm1, log2, log10 wie R"},
    {"slc_r_order", slc_r_order, METH_VARARGS, "slc_r_order(keys, n, nkey, dec, nalast, out) -> nout"},
    {"slc_r_rank", slc_r_rank, METH_VARARGS, "slc_r_rank(x, ties, out)"},
    {"slc_r_psort", slc_r_psort, METH_VARARGS, "slc_r_psort(x, k): sort(x, partial = k) an Ort und Stelle"},
    {"slc_r_quantile", slc_r_quantile, METH_VARARGS, "slc_r_quantile(x, p, type, out)"},
    {"slc_r_tabulate", slc_r_tabulate, METH_VARARGS, "slc_r_tabulate(bin, out)"},
    {"slc_r_findinterval", slc_r_findinterval, METH_VARARGS, "slc_r_findinterval(vec, x, rc, ai, lo, out)"},
    {"slc_r_approx", slc_r_approx, METH_VARARGS, "slc_r_approx(x, y, v, method, yleft, yright, f, out): approx wie R"},
    {"slc_r_cov", slc_r_cov, METH_VARARGS, "slc_r_cov(x, n, ncx, y, ncy, use, kendall, cor, ans) -> sd0"},
    {"slc_r_format_date", slc_r_format_date, METH_VARARGS, "slc_r_format_date(days, fmts[, digits_secs]) -> list (format.Date)"},
    {"slc_r_strptime_ymd", slc_r_strptime_ymd, METH_VARARGS, "slc_r_strptime_ymd(s, sep) -> Tage | None (as.Date)"},
    {"slc_r_strtod_num", slc_r_strtod_num, METH_VARARGS, "slc_r_strtod_num(s bytes) -> (Wert, Bytes, > DBL_MAX) (R_strtod)"},
    {"slc_r_fmod_ld", slc_r_fmod_ld, METH_VARARGS, "slc_r_fmod_ld(x1, x2) -> long-double-Teil von %%"},
    {"slc_r_idiv_ld", slc_r_idiv_ld, METH_VARARGS, "slc_r_idiv_ld(x1, x2) -> long-double-Teil von %/%"},
    {NULL, NULL, 0, NULL}
};

}  /* extern "C" */

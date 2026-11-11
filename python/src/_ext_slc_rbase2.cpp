/*
 * python/src/_ext_slc_rbase2.cpp -- Python-Huellen der Grundfunktionen mit R-Regeln, Teil 2 (seit 1.6.0), im Modul
 * simlev._ext: dist, hclust (core/slc_rbase_clust.cpp); .bincode, seq.int(length.out), median (slc_rbase_vec.cpp);
 * cor/cov mit Rangverfahren, cov2cor, scale (slc_rbase_cor.cpp); regularize.values, filter (slc_rbase_smooth.cpp);
 * p.adjust, ecdf (slc_rbase_models.cpp); round/signif, formatReal, encodeReal, as.character, formatC (str_signif),
 * sprintf (slc_rbase_fmt.cpp)
 *
 * Die Kerne src/core/slc_rbase_*.cpp sind Byte-fuer-Byte-Kopien der kanonischen Quellen in core/ (core/sync.py);
 * nur diese Huelle gibt es nur hier. Die Python-Seite (simlev/_r/) prueft Argumente und legt die Felder an (float64
 * bzw. int64, eindimensional, zusammenhaengend; Matrizen spaltenweise). Die Huellen pruefen Typ, Laenge und
 * Beschreibbarkeit. Fehler wie _ext_slc_rbase.cpp: ValueError mit dem Text des Kerns, MemoryError.
 */
#define PY_SSIZE_T_CLEAN
#include <Python.h>

#include <math.h>
#include <stdint.h>
#include <string.h>

#include <vector>

#include "core/slc_rbase2.h"

extern "C" {

#include "_ext_slc_hull.h"   /* py_interrupted, ctx_init, finish, hull_buf, rel (seit 1.6.3) */
static inline int get_buf2(PyObject *o, Py_buffer *v, int writable, Py_ssize_t itemsize, const char *fmts,
                           Py_ssize_t len, const char *what)
{ return hull_buf(o, v, writable, itemsize, fmts, len, what, 0); }


#define DBUF(o, v, w, len, what) get_buf2((o), (v), (w), 8, "d", (len), (what))
#define LBUF(o, v, w, len, what) get_buf2((o), (v), (w), 8, "qlL", (len), (what))
#define NITEMS(v) ((Py_ssize_t) ((v).len / (v).itemsize))


/* dist: (x, nr, nc, method, p, out) -> warn */
static PyObject *slc_r_dist(PyObject *self, PyObject *args)
{
    PyObject *x, *o;
    Py_ssize_t nr, nc;
    int method, warn = 0;
    double p;
    Py_buffer vx = {}, vo = {};
    (void) self;
    if (!PyArg_ParseTuple(args, "OnnidO", &x, &nr, &nc, &method, &p, &o)) return NULL;
    if (nr < 0 || nc < 0) { PyErr_SetString(PyExc_ValueError, "interner Fehler: Dimension negativ"); return NULL; }
    if (DBUF(x, &vx, 0, nr * nc, "x") < 0) return NULL;
    if (DBUF(o, &vo, 1, nr * (nr - 1) / 2, "Ausgabe") < 0) { rel(&vx); return NULL; }
    Py_BEGIN_ALLOW_THREADS
    sl_r_dist(nr, nc, (const double *) vx.buf, method, p, (double *) vo.buf, &warn);
    Py_END_ALLOW_THREADS
    rel(&vx); rel(&vo);
    return PyBool_FromLong(warn);
}

/* hclust: (n, iopt, membr, diss, merge, height, order) */
static PyObject *slc_r_hclust(PyObject *self, PyObject *args)
{
    PyObject *m, *d, *mg, *h, *o;
    Py_ssize_t n;
    int iopt, st;
    Py_buffer vm = {}, vd = {}, vmg = {}, vh = {}, vo = {};
    (void) self;
    if (!PyArg_ParseTuple(args, "niOOOOO", &n, &iopt, &m, &d, &mg, &h, &o)) return NULL;
    if (n < 2) { PyErr_SetString(PyExc_ValueError, "interner Fehler: n < 2"); return NULL; }
    if (DBUF(m, &vm, 0, n, "members") < 0) return NULL;
    if (DBUF(d, &vd, 0, n * (n - 1) / 2, "diss") < 0) { rel(&vm); return NULL; }
    if (LBUF(mg, &vmg, 1, 2 * (n - 1), "merge") < 0 || DBUF(h, &vh, 1, n - 1, "height") < 0
        || LBUF(o, &vo, 1, n, "order") < 0) {
        rel(&vm); rel(&vd); rel(&vmg); rel(&vh);
        return NULL;
    }
    Py_BEGIN_ALLOW_THREADS
    st = sl_r_hclust(n, iopt, (const double *) vm.buf, (const double *) vd.buf, (int64_t *) vmg.buf,
                     (double *) vh.buf, (int64_t *) vo.buf);
    Py_END_ALLOW_THREADS
    rel(&vm); rel(&vd); rel(&vmg); rel(&vh); rel(&vo);
    if (st == SL_ENOMEM) return PyErr_NoMemory();
    if (st) { PyErr_SetString(PyExc_ValueError, "interner Fehler: hclust"); return NULL; }
    Py_RETURN_NONE;
}

/* .bincode: (x, breaks, right, include_lowest, out) */
static PyObject *slc_r_bincode(PyObject *self, PyObject *args)
{
    PyObject *x, *b, *o;
    int right, il;
    Py_buffer vx = {}, vb = {}, vo = {};
    (void) self;
    if (!PyArg_ParseTuple(args, "OOppO", &x, &b, &right, &il, &o)) return NULL;
    if (DBUF(x, &vx, 0, -1, "x") < 0) return NULL;
    if (DBUF(b, &vb, 0, -1, "breaks") < 0) { rel(&vx); return NULL; }
    if (DBUF(o, &vo, 1, NITEMS(vx), "Ausgabe") < 0) { rel(&vx); rel(&vb); return NULL; }
    sl_r_bincode(NITEMS(vx), (const double *) vx.buf, NITEMS(vb), (const double *) vb.buf, right, il, (double *) vo.buf);
    rel(&vx); rel(&vb); rel(&vo);
    Py_RETURN_NONE;
}

/* seq.int(from, to, length.out): (from, to, out) */
static PyObject *slc_r_seq_len(PyObject *self, PyObject *args)
{
    PyObject *o;
    double from, to;
    Py_buffer vo = {};
    (void) self;
    if (!PyArg_ParseTuple(args, "ddO", &from, &to, &o)) return NULL;
    if (DBUF(o, &vo, 1, -1, "Ausgabe") < 0) return NULL;
    sl_r_seq_len(from, to, NITEMS(vo), (double *) vo.buf);
    rel(&vo);
    Py_RETURN_NONE;
}

/* median: (x, narm, isint) -> float oder None (NA) */
static PyObject *slc_r_median(PyObject *self, PyObject *args)
{
    PyObject *x;
    int narm, isint, st;
    double r;
    Py_buffer vx = {};
    (void) self;
    if (!PyArg_ParseTuple(args, "Opp", &x, &narm, &isint)) return NULL;
    if (DBUF(x, &vx, 0, -1, "x") < 0) return NULL;
    st = sl_r_median(NITEMS(vx), (const double *) vx.buf, narm, isint, &r);
    rel(&vx);
    if (st == SL_ENOMEM) return PyErr_NoMemory();
    if (st) Py_RETURN_NONE;
    return PyFloat_FromDouble(r);
}

/* cor: (x, n, ncx, xmat, y, ncy, ymat, use, method, cor, ans) -> sd0 */
static PyObject *slc_r_cor(PyObject *self, PyObject *args)
{
    PyObject *x, *y, *a;
    Py_ssize_t n, ncx, ncy;
    int xmat, ymat, use, method, cor, st, sd0 = 0;
    Py_buffer vx = {}, vy = {}, va = {};
    sl_ctx cx;
    (void) self;
    if (!PyArg_ParseTuple(args, "OnnpOnpiipO", &x, &n, &ncx, &xmat, &y, &ncy, &ymat, &use, &method, &cor, &a)) return NULL;
    if (n < 0 || ncx < 0 || ncy < 0) { PyErr_SetString(PyExc_ValueError, "interner Fehler: Dimension negativ"); return NULL; }
    if (y == Py_None) ncy = ncx;
    if (DBUF(x, &vx, 0, n * ncx, "x") < 0) return NULL;
    if (y != Py_None && DBUF(y, &vy, 0, n * ncy, "y") < 0) { rel(&vx); return NULL; }
    if (DBUF(a, &va, 1, ncx * ncy, "Ausgabe") < 0) { rel(&vx); rel(&vy); return NULL; }
    sl_ctx_init(&cx);
    st = sl_r_cor(&cx, n, ncx, (const double *) vx.buf, xmat, ncy, y == Py_None ? NULL : (const double *) vy.buf, ymat,
                  use, method, cor, (double *) va.buf, &sd0);
    rel(&vx); rel(&vy); rel(&va);
    if (st == SL_ENOMEM) return PyErr_NoMemory();
    if (st) { PyErr_SetString(PyExc_ValueError, cx.msg); return NULL; }
    return PyBool_FromLong(sd0);
}

/* cov2cor: (V, p, out) -> warn */
static PyObject *slc_r_cov2cor(PyObject *self, PyObject *args)
{
    PyObject *v, *o;
    Py_ssize_t p;
    int warn = 0;
    Py_buffer vv = {}, vo = {};
    (void) self;
    if (!PyArg_ParseTuple(args, "OnO", &v, &p, &o)) return NULL;
    if (DBUF(v, &vv, 0, p * p, "V") < 0) return NULL;
    if (DBUF(o, &vo, 1, p * p, "Ausgabe") < 0) { rel(&vv); return NULL; }
    sl_r_cov2cor(p, (const double *) vv.buf, (double *) vo.buf, &warn);
    rel(&vv); rel(&vo);
    return PyBool_FromLong(warn);
}

/* scale: (x, nr, nc, center, cen, scale, sc): x an Ort und Stelle */
static PyObject *slc_r_scale(PyObject *self, PyObject *args)
{
    PyObject *x, *c, *s;
    Py_ssize_t nr, nc;
    int center, scale, st;
    Py_buffer vx = {}, vc = {}, vs = {};
    (void) self;
    if (!PyArg_ParseTuple(args, "OnniOiO", &x, &nr, &nc, &center, &c, &scale, &s)) return NULL;
    if (DBUF(x, &vx, 1, nr * nc, "x") < 0) return NULL;
    if (DBUF(c, &vc, 1, nc, "center") < 0) { rel(&vx); return NULL; }
    if (DBUF(s, &vs, 1, nc, "scale") < 0) { rel(&vx); rel(&vc); return NULL; }
    st = sl_r_scale(nr, nc, (double *) vx.buf, center, (double *) vc.buf, scale, (double *) vs.buf);
    rel(&vx); rel(&vc); rel(&vs);
    if (st) return PyErr_NoMemory();
    Py_RETURN_NONE;
}

/* regularize.values: (x, y, narm, mode, mean, xo, yo, grp) -> (m, nout, collapsed, kept_na) */
static PyObject *slc_r_regularize(PyObject *self, PyObject *args)
{
    PyObject *x, *y, *xo, *yo, *g;
    int narm, mode, mean, st, col = 0, kna = 0;
    int64_t m = 0, nout = 0;
    Py_buffer vx = {}, vy = {}, vxo = {}, vyo = {}, vg = {};
    (void) self;
    if (!PyArg_ParseTuple(args, "OOpipOOO", &x, &y, &narm, &mode, &mean, &xo, &yo, &g)) return NULL;
    if (DBUF(x, &vx, 0, -1, "x") < 0) return NULL;
    if (DBUF(y, &vy, 0, NITEMS(vx), "y") < 0 || DBUF(xo, &vxo, 1, NITEMS(vx), "xo") < 0
        || DBUF(yo, &vyo, 1, NITEMS(vx), "yo") < 0 || LBUF(g, &vg, 1, NITEMS(vx), "grp") < 0) {
        rel(&vx); rel(&vy); rel(&vxo); rel(&vyo);
        return NULL;
    }
    st = sl_r_regularize(NITEMS(vx), (const double *) vx.buf, (const double *) vy.buf, narm, mode, mean,
                         (double *) vxo.buf, (double *) vyo.buf, (int64_t *) vg.buf, &m, &nout, &col, &kna);
    rel(&vx); rel(&vy); rel(&vxo); rel(&vyo); rel(&vg);
    if (st) return PyErr_NoMemory();
    return Py_BuildValue("LLii", (long long) m, (long long) nout, col, kna);
}

/* filter: (x, f, recursive, sides, circular, init, out) */
static PyObject *slc_r_filter(PyObject *self, PyObject *args)
{
    PyObject *x, *f, *ini, *o;
    int rec, sides, circ, st = 0;
    Py_buffer vx = {}, vf = {}, vi = {}, vo = {};
    (void) self;
    if (!PyArg_ParseTuple(args, "OOpipOO", &x, &f, &rec, &sides, &circ, &ini, &o)) return NULL;
    if (DBUF(x, &vx, 0, -1, "x") < 0) return NULL;
    if (DBUF(f, &vf, 0, -1, "filter") < 0 || DBUF(ini, &vi, 0, rec ? NITEMS(vf) : -1, "init") < 0
        || DBUF(o, &vo, 1, NITEMS(vx), "Ausgabe") < 0) {
        rel(&vx); rel(&vf); rel(&vi);
        return NULL;
    }
    if (rec)
        st = sl_r_filter_rec(NITEMS(vx), (const double *) vx.buf, NITEMS(vf), (const double *) vf.buf,
                             (const double *) vi.buf, (double *) vo.buf);
    else
        sl_r_filter_conv(NITEMS(vx), (const double *) vx.buf, NITEMS(vf), (const double *) vf.buf, sides, circ,
                         (double *) vo.buf);
    rel(&vx); rel(&vf); rel(&vi); rel(&vo);
    if (st) return PyErr_NoMemory();
    Py_RETURN_NONE;
}

/* p.adjust: (p, n, method, out) */
static PyObject *slc_r_p_adjust(PyObject *self, PyObject *args)
{
    PyObject *p, *o;
    double n;
    int method, st;
    Py_buffer vp = {}, vo = {};
    (void) self;
    if (!PyArg_ParseTuple(args, "OdiO", &p, &n, &method, &o)) return NULL;
    if (DBUF(p, &vp, 0, -1, "p") < 0) return NULL;
    if (DBUF(o, &vo, 1, NITEMS(vp), "Ausgabe") < 0) { rel(&vp); return NULL; }
    st = sl_r_p_adjust(NITEMS(vp), (const double *) vp.buf, n, method, (double *) vo.buf);
    rel(&vp); rel(&vo);
    if (st) return PyErr_NoMemory();
    Py_RETURN_NONE;
}

/* Texte des Kerns (Puffer, Grenzen) als Liste von str; Puffer freigeben */
static PyObject *str_list(char *buf, int64_t *off, int64_t n)
{
    PyObject *l = PyList_New((Py_ssize_t) n);
    int64_t i;
    if (l)
        for (i = 0; i < n; i++) {
            /* seit 1.6.4 ungültige Bytes (z. B. nach %.1s) wie R erhalten statt still verwerfen (C-054) */
            PyObject *s = PyUnicode_DecodeUTF8(buf + off[i], (Py_ssize_t) (off[i + 1] - off[i]), "surrogateescape");
            if (!s) { Py_DECREF(l); l = NULL; break; }
            PyList_SET_ITEM(l, (Py_ssize_t) i, s);
        }
    sl_r_free(buf);
    sl_r_free(off);
    return l;
}

/* round/signif eines Werts */
static PyObject *slc_r_fround(PyObject *self, PyObject *args)
{
    double x, d;
    (void) self;
    if (!PyArg_ParseTuple(args, "dd", &x, &d)) return NULL;
    return PyFloat_FromDouble(sl_r_fround(x, d));
}

static PyObject *slc_r_fprec(PyObject *self, PyObject *args)
{
    double x, d;
    (void) self;
    if (!PyArg_ParseTuple(args, "dd", &x, &d)) return NULL;
    return PyFloat_FromDouble(sl_r_fprec(x, d));
}

/* round/signif: (kind, x, digits, out) */
static PyObject *slc_r_round(PyObject *self, PyObject *args)
{
    PyObject *x, *d, *o;
    int kind;
    Py_buffer vx = {}, vd = {}, vo = {};
    (void) self;
    if (!PyArg_ParseTuple(args, "iOOO", &kind, &x, &d, &o)) return NULL;
    if (DBUF(x, &vx, 0, -1, "x") < 0) return NULL;
    if (DBUF(d, &vd, 0, -1, "digits") < 0) { rel(&vx); return NULL; }
    if (DBUF(o, &vo, 1, (NITEMS(vx) && NITEMS(vd)) ? (NITEMS(vx) > NITEMS(vd) ? NITEMS(vx) : NITEMS(vd)) : 0, "Ausgabe") < 0) {
        rel(&vx); rel(&vd);
        return NULL;
    }
    sl_r_round_vec(kind, NITEMS(vx), (const double *) vx.buf, NITEMS(vd), (const double *) vd.buf, (double *) vo.buf);
    rel(&vx); rel(&vd); rel(&vo);
    Py_RETURN_NONE;
}

/* optionale NA-Maske (bool/uint8, Länge n) */
static int na_mask(PyObject *o, Py_buffer *v, Py_ssize_t n)
{
    if (o == Py_None) return 0;
    if (PyObject_GetBuffer(o, v, PyBUF_C_CONTIGUOUS | PyBUF_FORMAT) < 0) return -1;
    if (v->itemsize != 1 || v->len != n) {
        PyBuffer_Release(v);
        PyErr_SetString(PyExc_TypeError, "interner Fehler: NA-Maske hat den falschen Typ");
        return -1;
    }
    return 0;
}

/* formatReal: (x, na, digits, nsmall, scipen) -> (w, d, e) */
static PyObject *slc_r_format_real(PyObject *self, PyObject *args)
{
    PyObject *x, *na;
    int digits, nsmall, scipen, w = 0, d = 0, e = 0;
    Py_buffer vx = {}, vn = {};
    (void) self;
    if (!PyArg_ParseTuple(args, "OOiii", &x, &na, &digits, &nsmall, &scipen)) return NULL;
    if (DBUF(x, &vx, 0, -1, "x") < 0) return NULL;
    if (na_mask(na, &vn, NITEMS(vx)) < 0) { rel(&vx); return NULL; }
    sl_r_format_real(NITEMS(vx), (const double *) vx.buf, vn.obj ? (const unsigned char *) vn.buf : NULL, digits,
                     nsmall, scipen, &w, &d, &e);
    rel(&vx); rel(&vn);
    return Py_BuildValue("iii", w, d, e);
}

/* encodeReal: (x, na, w, d, e, dec, nastr, drop0) -> list[str] */
static PyObject *slc_r_encode_real(PyObject *self, PyObject *args)
{
    PyObject *x, *na;
    int w, d, e, drop0, st;
    const char *dec, *nastr;
    char *buf = NULL;
    int64_t *off = NULL, n;
    Py_buffer vx = {}, vn = {};
    (void) self;
    if (!PyArg_ParseTuple(args, "OOiiissp", &x, &na, &w, &d, &e, &dec, &nastr, &drop0)) return NULL;
    if (DBUF(x, &vx, 0, -1, "x") < 0) return NULL;
    if (na_mask(na, &vn, NITEMS(vx)) < 0) { rel(&vx); return NULL; }
    n = NITEMS(vx);   /* seit 1.6.5 (CR1-Y17-1, gleiche Art): Länge vor der Freigabe merken */
    st = sl_r_encode_real(n, (const double *) vx.buf, vn.obj ? (const unsigned char *) vn.buf : NULL, w, d, e,
                          dec, nastr, drop0, &buf, &off);
    rel(&vx); rel(&vn);
    if (st) return PyErr_NoMemory();
    return str_list(buf, off, n);
}

/* as.character für Doubles: (x, scipen, dec) -> list[str] ("NA" für NA) */
static PyObject *slc_r_as_character_real(PyObject *self, PyObject *args)
{
    PyObject *x;
    int scipen, st;
    const char *dec;
    char *buf = NULL;
    int64_t *off = NULL, n;
    Py_buffer vx = {};
    (void) self;
    if (!PyArg_ParseTuple(args, "Ois", &x, &scipen, &dec)) return NULL;
    if (DBUF(x, &vx, 0, -1, "x") < 0) return NULL;
    n = NITEMS(vx);   /* seit 1.6.5 (CR1-Y17-1): Länge vor der Freigabe des Puffers merken */
    st = sl_r_as_character_real(n, (const double *) vx.buf, scipen, dec, &buf, &off);
    rel(&vx);
    if (st) return PyErr_NoMemory();
    return str_list(buf, off, n);
}

/* formatC: (x, isint, width, digits, format, flag, istrlen) -> list[str] */
static PyObject *slc_r_str_signif(PyObject *self, PyObject *args)
{
    PyObject *x, *il;
    int isint, width, digits, st;
    const char *format, *flag;
    char *buf = NULL;
    int64_t *off = NULL, n;
    Py_buffer vx = {}, vi = {};
    sl_ctx cx;
    (void) self;
    if (!PyArg_ParseTuple(args, "OpiissO", &x, &isint, &width, &digits, &format, &flag, &il)) return NULL;
    if (DBUF(x, &vx, 0, -1, "x") < 0) return NULL;
    if (LBUF(il, &vi, 0, NITEMS(vx), "istrlen") < 0) { rel(&vx); return NULL; }
    sl_ctx_init(&cx);
    n = NITEMS(vx);   /* seit 1.6.5 (CR1-Y17-1, gleiche Art): Länge vor der Freigabe merken */
    st = sl_r_str_signif(&cx, n, (const double *) vx.buf, isint, width, digits, format, flag,
                         (const int64_t *) vi.buf, &buf, &off);
    rel(&vx); rel(&vi);
    if (st == SL_ENOMEM) return PyErr_NoMemory();
    if (st) { PyErr_SetString(PyExc_ValueError, cx.msg); return NULL; }
    return str_list(buf, off, n);
}

/* sprintf: (fmts, args, scipen, dec) -> (list[str], nunused); fmts: Liste aus str/None; args: Liste aus
 * (typ, daten, texte) mit daten int32/float64-Puffer, float bzw. int (ein Wert) oder None (character) und texte Liste aus
 * str/None oder None */
static PyObject *slc_r_sprintf(PyObject *self, PyObject *args)
{
    PyObject *fl, *al, *res = NULL;
    int scipen, st, nunused = 0;
    const char *dec;
    Py_ssize_t nf, na, k, i;
    char *buf = NULL;
    int64_t *off = NULL, nout = 0;
    sl_ctx cx;
    (void) self;
    if (!PyArg_ParseTuple(args, "O!O!is", &PyList_Type, &fl, &PyList_Type, &al, &scipen, &dec)) return NULL;
    nf = PyList_GET_SIZE(fl);
    na = PyList_GET_SIZE(al);
    std::vector<const char *> fmts((size_t) nf + 1);
    std::vector<int> types((size_t) na + 1);
    std::vector<int64_t> lens((size_t) na + 1);
    std::vector<const void *> data((size_t) na + 1);
    std::vector<const char *const *> strs((size_t) na + 1);
    std::vector<std::vector<const char *>> sbufs((size_t) na + 1);
    std::vector<Py_buffer> views((size_t) na + 1);
    std::vector<double> dstore((size_t) na + 1);
    std::vector<int32_t> istore((size_t) na + 1);
    for (k = 0; k < na; k++) views[(size_t) k] = Py_buffer{};
    for (k = 0; k < nf; k++) {
        PyObject *o = PyList_GET_ITEM(fl, k);
        fmts[(size_t) k] = o == Py_None ? NULL : PyUnicode_AsUTF8(o);
        if (o != Py_None && !fmts[(size_t) k]) return NULL;
    }
    for (k = 0; k < na; k++) {
        PyObject *t = PyList_GET_ITEM(al, k), *d, *s;
        int ty;
        if (!PyTuple_Check(t) || PyTuple_GET_SIZE(t) != 3) { PyErr_SetString(PyExc_TypeError, "interner Fehler: Argument"); goto out; }
        ty = (int) PyLong_AsLong(PyTuple_GET_ITEM(t, 0));
        d = PyTuple_GET_ITEM(t, 1);
        s = PyTuple_GET_ITEM(t, 2);
        types[(size_t) k] = ty;
        if (PyFloat_Check(d)) {   /* Skalar ohne Puffer (schneller Weg von r_sprintf) */
            dstore[(size_t) k] = PyFloat_AS_DOUBLE(d);
            data[(size_t) k] = &dstore[(size_t) k];
            lens[(size_t) k] = 1;
        } else if (PyLong_Check(d)) {
            istore[(size_t) k] = (int32_t) PyLong_AsLong(d);
            data[(size_t) k] = &istore[(size_t) k];
            lens[(size_t) k] = 1;
        } else if (d != Py_None) {
            if (ty == SL_RS_DBL || ty == SL_RS_DATE) {
                if (DBUF(d, &views[(size_t) k], 0, -1, "Daten") < 0) goto out;
            } else if (get_buf2(d, &views[(size_t) k], 0, 4, "i", -1, "Daten") < 0) {
                goto out;
            }
            data[(size_t) k] = views[(size_t) k].buf;
            lens[(size_t) k] = NITEMS(views[(size_t) k]);
        }
        if (s != Py_None) {
            Py_ssize_t m = PyList_GET_SIZE(s);
            sbufs[(size_t) k].resize((size_t) m + 1);
            for (i = 0; i < m; i++) {
                PyObject *o = PyList_GET_ITEM(s, i);
                sbufs[(size_t) k][(size_t) i] = o == Py_None ? NULL : PyUnicode_AsUTF8(o);
                if (o != Py_None && !sbufs[(size_t) k][(size_t) i]) goto out;
            }
            strs[(size_t) k] = sbufs[(size_t) k].data();
            if (d == Py_None) lens[(size_t) k] = m;
        } else {
            strs[(size_t) k] = NULL;
        }
    }
    sl_ctx_init(&cx);
    st = sl_r_sprintf(&cx, nf, fmts.data(), (int) na, types.data(), lens.data(), data.data(), strs.data(), scipen, dec,
                      &buf, &off, &nout, &nunused);
    if (st == SL_ENOMEM) { PyErr_NoMemory(); goto out; }
    if (st) { PyErr_SetString(PyExc_ValueError, cx.msg); goto out; }
    {
        PyObject *l = str_list(buf, off, nout);
        if (l) res = Py_BuildValue("Ni", l, nunused);
    }
out:
    for (k = 0; k < na; k++) rel(&views[(size_t) k]);
    return res;
}

PyMethodDef simlev_ext_slc_rbase2_methods[] = {
    {"slc_r_dist", slc_r_dist, METH_VARARGS, "slc_r_dist(x, nr, nc, method, p, out) -> warn (dist wie R)"},
    {"slc_r_hclust", slc_r_hclust, METH_VARARGS, "slc_r_hclust(n, iopt, members, diss, merge, height, order)"},
    {"slc_r_bincode", slc_r_bincode, METH_VARARGS, "slc_r_bincode(x, breaks, right, include_lowest, out) (.bincode wie R)"},
    {"slc_r_seq_len", slc_r_seq_len, METH_VARARGS, "slc_r_seq_len(from, to, out): seq.int(from, to, length.out = len(out))"},
    {"slc_r_median", slc_r_median, METH_VARARGS, "slc_r_median(x, narm, isint) -> float | None (NA)"},
    {"slc_r_cor", slc_r_cor, METH_VARARGS, "slc_r_cor(x, n, ncx, xmat, y, ncy, ymat, use, method, cor, ans) -> sd0"},
    {"slc_r_cov2cor", slc_r_cov2cor, METH_VARARGS, "slc_r_cov2cor(V, p, out) -> warn"},
    {"slc_r_scale", slc_r_scale, METH_VARARGS, "slc_r_scale(x, nr, nc, center, cen, scale, sc)"},
    {"slc_r_regularize", slc_r_regularize, METH_VARARGS, "slc_r_regularize(x, y, narm, mode, mean, xo, yo, grp) -> (m, nout, collapsed, kept_na)"},
    {"slc_r_filter", slc_r_filter, METH_VARARGS, "slc_r_filter(x, f, recursive, sides, circular, init, out)"},
    {"slc_r_p_adjust", slc_r_p_adjust, METH_VARARGS, "slc_r_p_adjust(p, n, method, out) (p.adjust wie R)"},
    {"slc_r_fround", slc_r_fround, METH_VARARGS, "slc_r_fround(x, digits) -> round(x, digits) wie R"},
    {"slc_r_fprec", slc_r_fprec, METH_VARARGS, "slc_r_fprec(x, digits) -> signif(x, digits) wie R"},
    {"slc_r_round", slc_r_round, METH_VARARGS, "slc_r_round(kind, x, digits, out): 0 round, 1 signif wie R"},
    {"slc_r_format_real", slc_r_format_real, METH_VARARGS, "slc_r_format_real(x, na, digits, nsmall, scipen) -> (w, d, e)"},
    {"slc_r_encode_real", slc_r_encode_real, METH_VARARGS, "slc_r_encode_real(x, na, w, d, e, dec, nastr, drop0) -> list"},
    {"slc_r_as_character_real", slc_r_as_character_real, METH_VARARGS, "slc_r_as_character_real(x, scipen, dec) -> list"},
    {"slc_r_str_signif", slc_r_str_signif, METH_VARARGS, "slc_r_str_signif(x, isint, width, digits, format, flag, istrlen) -> list"},
    {"slc_r_sprintf", slc_r_sprintf, METH_VARARGS, "slc_r_sprintf(fmts, args, scipen, dec) -> (list, nunused)"},
    {NULL, NULL, 0, NULL}
};

}  /* extern "C" */

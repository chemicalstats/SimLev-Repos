/*
 * python/src/_ext_slc_prep.cpp -- Huellen der Kerne fuer Wirtsfunktionen (seit 1.6.0; core/slc_prep.h) und von
 * Brent fmin (core/slc_opt_fmin.cpp)
 *
 * Kalenderauffuellung (slc_cal_index, slc_cal_fill_real; simlev/_sim_phases.py), Momentum-Scores (slc_mom_score;
 * simlev/tactical.py), Pfadaufbau im Bootstrap (slc_boot_path; simlev/bootstrap.py; seit 1.6.3 slc_boot_path_src aus
 * der Quelle ohne Zeilenkopie), qt/pt auf mehreren Threads
 * (slc_qt_mt, slc_pt_mt; simlev/_lib.py), t-Copula (slc_tcop_fit, slc_tcop_nu; simlev/dependence.py,
 * simlev/scenarios.py) und Brent fmin als Frage/Antwort (slc_fmin_*; simlev/_r/stats_optim.py).
 * Matrizen kommen als C-Felder (Spalten, Zeilen) = spaltenweise (Zeilen x Spalten). Die Python-Seite prueft die
 * Eingaben und baut die Ergebnisobjekte.
 */
#define PY_SSIZE_T_CLEAN
#include <Python.h>

#include <stdint.h>
#include <string.h>

#include "core/slc_prep.h"
#include "core/slc_opt.h"

extern "C" {

#include "_ext_slc_hull.h"   /* py_interrupted, ctx_init, finish, hull_buf, rel (seit 1.6.3) */
static inline int buf(PyObject *o, Py_buffer *v, int writable, Py_ssize_t itemsize, const char *fmts,
                      const char *what, int opt)
{ return hull_buf(o, v, writable, itemsize, fmts, -1, what, opt); }


#define N(v) ((int64_t) ((v).len / ((v).itemsize ? (v).itemsize : 1)))

/* slc_cal_index(day float64, d0, src int64 (nd)) */
static PyObject *slc_cal_index(PyObject *self, PyObject *args)
{
    PyObject *day, *src;
    double d0;
    Py_buffer bd, bs;
    sl_ctx cx;
    int st;
    (void) self;
    if (!PyArg_ParseTuple(args, "OdO", &day, &d0, &src)) return NULL;
    if (buf(day, &bd, 0, 8, "d", "day (float64)", 0) < 0) return NULL;
    if (buf(src, &bs, 1, 8, "qlL", "src (int64)", 0) < 0) { rel(&bd); return NULL; }
    ctx_init(&cx);
    st = sl_cal_index(&cx, N(bd), (const double *) bd.buf, d0, N(bs), (int64_t *) bs.buf);
    rel(&bd); rel(&bs);
    if (finish(&cx, st) < 0) return NULL;
    Py_RETURN_NONE;
}

/* slc_cal_fill_real(src int64, x float64, out float64, locf) */
static PyObject *slc_cal_fill_real(PyObject *self, PyObject *args)
{
    PyObject *src, *x, *out;
    int locf;
    Py_buffer bs, bx, bo;
    (void) self;
    if (!PyArg_ParseTuple(args, "OOOp", &src, &x, &out, &locf)) return NULL;
    if (buf(src, &bs, 0, 8, "qlL", "src (int64)", 0) < 0) return NULL;
    if (buf(x, &bx, 0, 8, "d", "x (float64)", 0) < 0) { rel(&bs); return NULL; }
    if (buf(out, &bo, 1, 8, "d", "out (float64)", 0) < 0) { rel(&bs); rel(&bx); return NULL; }
    if (N(bo) != N(bs)) { rel(&bs); rel(&bx); rel(&bo); PyErr_SetString(PyExc_TypeError, "interner Fehler: cal_fill Laengen"); return NULL; }
    for (int64_t j = 0; j < N(bs); j++)
        if (((int64_t *) bs.buf)[j] >= N(bx)) { rel(&bs); rel(&bx); rel(&bo); PyErr_SetString(PyExc_TypeError, "interner Fehler: cal_fill Index"); return NULL; }
    sl_cal_fill_real(N(bs), (const int64_t *) bs.buf, (const double *) bx.buf, locf, (double *) bo.buf);
    rel(&bs); rel(&bx); rel(&bo);
    Py_RETURN_NONE;
}

/* slc_mom_score(d float64 (n), lb int32, X float64 (na, n), type, S float64 (na, n)) */
static PyObject *slc_mom_score(PyObject *self, PyObject *args)
{
    PyObject *d, *lb, *X, *S;
    int type, st;
    Py_buffer bd, bl, bx, bS;
    sl_ctx cx;
    int64_t n, na, *back;
    (void) self;
    if (!PyArg_ParseTuple(args, "OOOiO", &d, &lb, &X, &type, &S)) return NULL;
    if (buf(d, &bd, 0, 8, "d", "d (float64)", 0) < 0) return NULL;
    if (buf(lb, &bl, 0, 4, "il", "lb (int32)", 0) < 0) { rel(&bd); return NULL; }
    if (buf(X, &bx, 0, 8, "d", "X (float64)", 0) < 0) { rel(&bd); rel(&bl); return NULL; }
    if (buf(S, &bS, 1, 8, "d", "S (float64)", 0) < 0) { rel(&bd); rel(&bl); rel(&bx); return NULL; }
    n = N(bd); na = n > 0 ? N(bx) / n : 0;
    if (na * n != N(bx) || N(bS) != N(bx)) {
        rel(&bd); rel(&bl); rel(&bx); rel(&bS);
        PyErr_SetString(PyExc_TypeError, "interner Fehler: mom_score Laengen");
        return NULL;
    }
    back = (int64_t *) PyMem_Malloc(sizeof(int64_t) * (size_t) ((n > 0 ? n : 1) * (N(bl) > 0 ? N(bl) : 1)));
    if (!back) { rel(&bd); rel(&bl); rel(&bx); rel(&bS); return PyErr_NoMemory(); }
    ctx_init(&cx);
    st = sl_mom_back(&cx, n, (const double *) bd.buf, (int) N(bl), (const int *) bl.buf, back);
    if (st == SL_OK) st = sl_mom_score(&cx, n, na, (const double *) bx.buf, (int) N(bl), back, type, (double *) bS.buf);
    PyMem_Free(back);
    rel(&bd); rel(&bl); rel(&bx); rel(&bS);
    if (finish(&cx, st) < 0) return NULL;
    Py_RETURN_NONE;
}

/* slc_boot_path(ret (n_out, k) zeilenweise, idx int64 (n_out), aux (na, n_aux)|None, aux_ratio|None, aux_start|None,
 *               level int32 (na)|None, letf float64 (nL, 10), start, P (k+nL+na, n_out+1), lv (na, n_out+1)|None)
 * -> True (gueltig) / False */
static PyObject *slc_boot_path(PyObject *self, PyObject *args)
{
    PyObject *ret, *idx, *aux, *ar, *as, *lev, *letf, *P, *lv;
    double start;
    Py_ssize_t n_out, k, na = 0, n_aux = 0, nL;
    Py_buffer br, bi, ba, bar, bas, blev, bl, bP, blv;
    sl_letf *L = NULL;
    sl_ctx cx;
    int st, l;
    (void) self;
    if (!PyArg_ParseTuple(args, "nnOOOOOOOdOO", &n_out, &k, &ret, &idx, &aux, &ar, &as, &lev, &letf, &start, &P, &lv))
        return NULL;
    memset(&br, 0, sizeof br); memset(&bi, 0, sizeof bi); memset(&ba, 0, sizeof ba); memset(&bar, 0, sizeof bar);
    memset(&bas, 0, sizeof bas); memset(&blev, 0, sizeof blev); memset(&bl, 0, sizeof bl); memset(&bP, 0, sizeof bP);
    memset(&blv, 0, sizeof blv);
#define FAIL_REL() do { rel(&br); rel(&bi); rel(&ba); rel(&bar); rel(&bas); rel(&blev); rel(&bl); rel(&bP); rel(&blv); } while (0)
    if (buf(ret, &br, 0, 8, "d", "ret", 0) < 0 || buf(idx, &bi, 0, 8, "qlL", "idx (int64)", 0) < 0 ||
        buf(aux, &ba, 0, 8, "d", "aux", 1) < 0 || buf(ar, &bar, 0, 8, "d", "aux_ratio", 1) < 0 ||
        buf(as, &bas, 0, 8, "d", "aux_start", 1) < 0 || buf(lev, &blev, 0, 4, "il", "level (int32)", 1) < 0 ||
        buf(letf, &bl, 0, 8, "d", "letf", 0) < 0 || buf(P, &bP, 1, 8, "d", "P", 0) < 0 ||
        buf(lv, &blv, 1, 8, "d", "lv", 1) < 0) { FAIL_REL(); return NULL; }
    nL = (Py_ssize_t) (N(bl) / 10);
    if (ba.obj) { na = (Py_ssize_t) N(blev); n_aux = na > 0 ? (Py_ssize_t) (N(ba) / na) : 0; }
    if (N(br) != (int64_t) n_out * k || N(bi) != n_out || nL * 10 != N(bl) || (ba.obj && n_aux * na != N(ba)) ||
        (bar.obj && N(bar) != N(ba)) || (bas.obj && N(bas) != na) ||
        N(bP) != (int64_t) (n_out + 1) * (k + nL + na) || (blv.obj && N(blv) != (int64_t) (n_out + 1) * na)) {
        FAIL_REL(); PyErr_SetString(PyExc_TypeError, "interner Fehler: boot_path Laengen"); return NULL;
    }
    if (nL > 0) {
        const double *q = (const double *) bl.buf;
        L = (sl_letf *) PyMem_Malloc(sizeof(sl_letf) * (size_t) nL);
        if (!L) { FAIL_REL(); return PyErr_NoMemory(); }
        for (l = 0; l < nL; l++) {                 /* Zeile l: base, L, rate_col, rate, days_col, days, rb, tb, exp, spread */
            const double *z = q + 10 * l;
            L[l].base = (int) z[0]; L[l].L = z[1]; L[l].rate_col = (int) z[2]; L[l].rate = z[3];
            L[l].days_col = (int) z[4]; L[l].days = z[5]; L[l].rate_basis = z[6]; L[l].ter_basis = z[7];
            L[l].expense = z[8]; L[l].spread = z[9];
        }
    }
    /* ret kommt zeilenweise (n_out, k) wie aus numpy; der Kern erwartet spaltenweise */
    double *rt = (double *) PyMem_Malloc(sizeof(double) * (size_t) (n_out * k > 0 ? n_out * k : 1));
    if (!rt) { PyMem_Free(L); FAIL_REL(); return PyErr_NoMemory(); }
    for (Py_ssize_t i = 0; i < n_out; i++)
        for (Py_ssize_t j = 0; j < k; j++) rt[j * n_out + i] = ((const double *) br.buf)[i * k + j];
    ctx_init(&cx);
    st = sl_boot_path(&cx, n_out, (int) k, rt, (const int64_t *) bi.buf, n_aux, (int) na,
                      ba.obj ? (const double *) ba.buf : NULL, bar.obj ? (const double *) bar.buf : NULL,
                      bas.obj ? (const double *) bas.buf : NULL, blev.obj ? (const int *) blev.buf : NULL, (int) nL, L,
                      start, (double *) bP.buf, blv.obj ? (double *) blv.buf : NULL);
    PyMem_Free(L);
    PyMem_Free(rt);
    FAIL_REL();
#undef FAIL_REL
    if (st < 0) { finish(&cx, -st); return NULL; }
    return PyBool_FromLong(st);
}

/* slc_boot_path_src (seit 1.6.3, sl_boot_path_src): wie slc_boot_path, statt (n_out, k, ret) die Quellrenditen src
 * (n_src x k, zeilenweise wie aus numpy, ohne Umordnung) und idx (n_out Zeilen, 1-basiert) fuer Renditen und
 * Zusatzreihen: (n_src, k, src, idx, aux, aux_ratio, aux_start, level, letf, start, P, lv) -> True / False;
 * Bit fuer Bit wie slc_boot_path(n_out, k, src[idx - 1, :], idx, ...) */
static PyObject *slc_boot_path_src(PyObject *self, PyObject *args)
{
    PyObject *src, *idx, *aux, *ar, *as, *lev, *letf, *P, *lv;
    double start;
    Py_ssize_t n_src, k, n_out, na = 0, n_aux = 0, nL;
    Py_buffer br, bi, ba, bar, bas, blev, bl, bP, blv;
    sl_letf *L = NULL;
    sl_ctx cx;
    int st, l;
    (void) self;
    if (!PyArg_ParseTuple(args, "nnOOOOOOOdOO", &n_src, &k, &src, &idx, &aux, &ar, &as, &lev, &letf, &start, &P, &lv))
        return NULL;
    memset(&br, 0, sizeof br); memset(&bi, 0, sizeof bi); memset(&ba, 0, sizeof ba); memset(&bar, 0, sizeof bar);
    memset(&bas, 0, sizeof bas); memset(&blev, 0, sizeof blev); memset(&bl, 0, sizeof bl); memset(&bP, 0, sizeof bP);
    memset(&blv, 0, sizeof blv);
#define FAIL_REL() do { rel(&br); rel(&bi); rel(&ba); rel(&bar); rel(&bas); rel(&blev); rel(&bl); rel(&bP); rel(&blv); } while (0)
    if (buf(src, &br, 0, 8, "d", "src", 0) < 0 || buf(idx, &bi, 0, 8, "qlL", "idx (int64)", 0) < 0 ||
        buf(aux, &ba, 0, 8, "d", "aux", 1) < 0 || buf(ar, &bar, 0, 8, "d", "aux_ratio", 1) < 0 ||
        buf(as, &bas, 0, 8, "d", "aux_start", 1) < 0 || buf(lev, &blev, 0, 4, "il", "level (int32)", 1) < 0 ||
        buf(letf, &bl, 0, 8, "d", "letf", 0) < 0 || buf(P, &bP, 1, 8, "d", "P", 0) < 0 ||
        buf(lv, &blv, 1, 8, "d", "lv", 1) < 0) { FAIL_REL(); return NULL; }
    n_out = (Py_ssize_t) N(bi);
    nL = (Py_ssize_t) (N(bl) / 10);
    if (ba.obj) { na = (Py_ssize_t) N(blev); n_aux = na > 0 ? (Py_ssize_t) (N(ba) / na) : 0; }
    if (n_src < 0 || k < 0 || N(br) != (int64_t) n_src * k || nL * 10 != N(bl) || (ba.obj && n_aux * na != N(ba)) ||
        (bar.obj && N(bar) != N(ba)) || (bas.obj && N(bas) != na) ||
        N(bP) != (int64_t) (n_out + 1) * (k + nL + na) || (blv.obj && N(blv) != (int64_t) (n_out + 1) * na)) {
        FAIL_REL(); PyErr_SetString(PyExc_TypeError, "interner Fehler: boot_path_src Laengen"); return NULL;
    }
    if (nL > 0) {
        const double *q = (const double *) bl.buf;
        L = (sl_letf *) PyMem_Malloc(sizeof(sl_letf) * (size_t) nL);
        if (!L) { FAIL_REL(); return PyErr_NoMemory(); }
        for (l = 0; l < nL; l++) {                 /* Zeile l: base, L, rate_col, rate, days_col, days, rb, tb, exp, spread */
            const double *z = q + 10 * l;
            L[l].base = (int) z[0]; L[l].L = z[1]; L[l].rate_col = (int) z[2]; L[l].rate = z[3];
            L[l].days_col = (int) z[4]; L[l].days = z[5]; L[l].rate_basis = z[6]; L[l].ter_basis = z[7];
            L[l].expense = z[8]; L[l].spread = z[9];
        }
    }
    ctx_init(&cx);
    st = sl_boot_path_src(&cx, n_out, (int) k, (const double *) br.buf, n_src, k, 1, (const int64_t *) bi.buf, n_aux,
                          (int) na, ba.obj ? (const double *) ba.buf : NULL, bar.obj ? (const double *) bar.buf : NULL,
                          bas.obj ? (const double *) bas.buf : NULL, blev.obj ? (const int *) blev.buf : NULL, (int) nL,
                          L, start, (double *) bP.buf, blv.obj ? (double *) blv.buf : NULL);
    PyMem_Free(L);
    FAIL_REL();
#undef FAIL_REL
    if (st < 0) { finish(&cx, -st); return NULL; }
    return PyBool_FromLong(st);
}

/* slc_qt_mt / slc_pt_mt (x, out, df, lower, nthreads) */
typedef int (*tmt_fn)(sl_ctx *, int64_t, const double *, double, int, double *, int);
static PyObject *tdist_mt(PyObject *args, tmt_fn f)
{
    PyObject *x, *out;
    double df;
    int lower, nt, st;
    Py_buffer bx, bo;
    sl_ctx cx;
    if (!PyArg_ParseTuple(args, "OOdpi", &x, &out, &df, &lower, &nt)) return NULL;
    if (buf(x, &bx, 0, 8, "d", "x (float64)", 0) < 0) return NULL;
    if (buf(out, &bo, 1, 8, "d", "Ausgabe (float64)", 0) < 0) { rel(&bx); return NULL; }
    if (N(bx) != N(bo)) { rel(&bx); rel(&bo); PyErr_SetString(PyExc_TypeError, "interner Fehler: Ein- und Ausgabe ungleich lang"); return NULL; }
    ctx_init(&cx);
    st = f(&cx, N(bo), (const double *) bx.buf, df, lower, (double *) bo.buf, nt);
    rel(&bx); rel(&bo);
    if (finish(&cx, st) < 0) return NULL;
    Py_RETURN_NONE;
}
static PyObject *slc_qt_mt(PyObject *s, PyObject *a) { (void) s; return tdist_mt(a, sl_qt_mt); }
static PyObject *slc_pt_mt(PyObject *s, PyObject *a) { (void) s; return tdist_mt(a, sl_pt_mt); }

/* slc_tcop_fit(u, v, nthreads) -> (th, nu, obj) oder None (der Host rechnet wie bisher) */
static PyObject *slc_tcop_fit(PyObject *self, PyObject *args)
{
    PyObject *u, *v;
    int nt, st, flag = 0;
    double best[3];
    Py_buffer bu, bv;
    sl_ctx cx;
    (void) self;
    if (!PyArg_ParseTuple(args, "OOi", &u, &v, &nt)) return NULL;
    if (buf(u, &bu, 0, 8, "d", "u (float64)", 0) < 0) return NULL;
    if (buf(v, &bv, 0, 8, "d", "v (float64)", 0) < 0) { rel(&bu); return NULL; }
    if (N(bu) != N(bv) || N(bu) < 1) { rel(&bu); rel(&bv); Py_RETURN_NONE; }
    ctx_init(&cx);
    cx.interrupted = NULL;
    Py_BEGIN_ALLOW_THREADS
    st = sl_tcop_fit(&cx, N(bu), (const double *) bu.buf, (const double *) bv.buf, nt, best, &flag);
    Py_END_ALLOW_THREADS
    rel(&bu); rel(&bv);
    if (st != SL_OK || flag) Py_RETURN_NONE;
    return Py_BuildValue("(ddd)", best[0], best[1], best[2]);
}

/* slc_tcop_nu(U (k, Tn), Ri (k, k), ldR, lower, upper, tol, nthreads) -> nu oder None */
static PyObject *slc_tcop_nu(PyObject *self, PyObject *args)
{
    PyObject *U, *Ri;
    double ldR, lo, hi, tol, nu = 0;
    int k, nt, st, flag = 0;
    Py_buffer bU, bR;
    sl_ctx cx;
    (void) self;
    if (!PyArg_ParseTuple(args, "OOiddddi", &U, &Ri, &k, &ldR, &lo, &hi, &tol, &nt)) return NULL;
    if (buf(U, &bU, 0, 8, "d", "U (float64)", 0) < 0) return NULL;
    if (buf(Ri, &bR, 0, 8, "d", "Ri (float64)", 0) < 0) { rel(&bU); return NULL; }
    if (k < 1 || N(bR) != (int64_t) k * k || N(bU) % k != 0) { rel(&bU); rel(&bR); Py_RETURN_NONE; }
    ctx_init(&cx);
    cx.interrupted = NULL;
    Py_BEGIN_ALLOW_THREADS
    st = sl_tcop_nu(&cx, N(bU) / k, k, (const double *) bU.buf, (const double *) bR.buf, ldR, lo, hi, tol, nt, &nu, &flag);
    Py_END_ALLOW_THREADS
    rel(&bU); rel(&bR);
    if (st != SL_OK || flag) Py_RETURN_NONE;
    return PyFloat_FromDouble(nu);
}

/* Brent fmin: slc_fmin_init(ws, ax, bx, tol); slc_fmin_ask(ws) -> (need, x); slc_fmin_tell(ws, f) */
static double *ws_of(PyObject *o, Py_buffer *b)
{
    if (buf(o, b, 1, 8, "d", "ws (float64)", 0) < 0) return NULL;
    if (N(*b) < SL_FMIN_WS) { rel(b); PyErr_SetString(PyExc_TypeError, "interner Fehler: fmin-Arbeitsfeld zu kurz"); return NULL; }
    return (double *) b->buf;
}
static PyObject *slc_fmin_init(PyObject *self, PyObject *args)
{
    PyObject *o;
    double ax, bx, tol, *ws;
    Py_buffer b;
    (void) self;
    if (!PyArg_ParseTuple(args, "Oddd", &o, &ax, &bx, &tol) || !(ws = ws_of(o, &b))) return NULL;
    sl_fmin_init(ws, ax, bx, tol);
    rel(&b);
    Py_RETURN_NONE;
}
static PyObject *slc_fmin_ask(PyObject *self, PyObject *args)
{
    PyObject *o;
    double x, *ws;
    int need;
    Py_buffer b;
    (void) self;
    if (!PyArg_ParseTuple(args, "O", &o) || !(ws = ws_of(o, &b))) return NULL;
    need = sl_fmin_ask(ws, &x);
    rel(&b);
    return Py_BuildValue("(id)", need, x);
}
static PyObject *slc_fmin_tell(PyObject *self, PyObject *args)
{
    PyObject *o;
    double f, *ws;
    Py_buffer b;
    (void) self;
    if (!PyArg_ParseTuple(args, "Od", &o, &f) || !(ws = ws_of(o, &b))) return NULL;
    sl_fmin_tell(ws, f);
    rel(&b);
    Py_RETURN_NONE;
}

PyMethodDef simlev_ext_slc_prep_methods[] = {
    {"slc_cal_index", slc_cal_index, METH_VARARGS, "slc_cal_index(day, d0, src): Zeile je Kalendertag (-1 = keine)"},
    {"slc_cal_fill_real", slc_cal_fill_real, METH_VARARGS, "slc_cal_fill_real(src, x, out, locf)"},
    {"slc_mom_score", slc_mom_score, METH_VARARGS, "slc_mom_score(d, lb, X, type, S): Momentum-Scores"},
    {"slc_boot_path", slc_boot_path, METH_VARARGS, "slc_boot_path(n_out, k, ret, idx, aux, aux_ratio, aux_start, level, letf, start, P, lv) -> gueltig"},
    {"slc_boot_path_src", slc_boot_path_src, METH_VARARGS,
     "slc_boot_path_src(n_src, k, src, idx, aux, aux_ratio, aux_start, level, letf, start, P, lv) -> gueltig (ret = src[idx - 1])"},
    {"slc_qt_mt", slc_qt_mt, METH_VARARGS, "slc_qt_mt(p, out, df, lower, nthreads)"},
    {"slc_pt_mt", slc_pt_mt, METH_VARARGS, "slc_pt_mt(q, out, df, lower, nthreads)"},
    {"slc_tcop_fit", slc_tcop_fit, METH_VARARGS, "slc_tcop_fit(u, v, nthreads) -> (th, nu, obj) oder None"},
    {"slc_tcop_nu", slc_tcop_nu, METH_VARARGS, "slc_tcop_nu(U, Ri, k, ldR, lower, upper, tol, nthreads) -> nu oder None"},
    {"slc_fmin_init", slc_fmin_init, METH_VARARGS, "slc_fmin_init(ws, ax, bx, tol)"},
    {"slc_fmin_ask", slc_fmin_ask, METH_VARARGS, "slc_fmin_ask(ws) -> (1, x) oder (0, Ergebnis)"},
    {"slc_fmin_tell", slc_fmin_tell, METH_VARARGS, "slc_fmin_tell(ws, f)"},
    {NULL, NULL, 0, NULL}
};

}  /* extern "C" */

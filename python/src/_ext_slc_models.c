/*
 * python/src/_ext_slc_models.c -- Python-Huellen der Modelle der C-Bibliothek slc im Modul
 * simlev._ext (Etappe 9.4): GARCH/GJR, GPD, DCC, MS-GARCH und HMM, Bootstrap-Kerne.
 *
 * Kerne: src/core/slc_{garch,gpd,dcc,msgarch,boot}.c (Kopien von core/). Die Python-Seite
 * (simlev/_lib_models.py) prueft und wandelt die Argumente und legt die Ausgabefelder an
 * (float64 bzw. int32, zusammenhaengend, Matrizen spaltenweise); die Huellen pruefen nur Typ,
 * Laenge und Beschreibbarkeit. Rueckmeldungen wie _ext_slc.c: Warnungen nach dem Aufruf
 * (warnings.warn), Fehler als ValueError mit dem Text des Kerns. Zufallszustand: beschreibbarer
 * Puffer mit 32 Byte; die Huelle rechnet auf einer Kopie und schreibt ihn nur bei Erfolg zurueck.
 */
#define PY_SSIZE_T_CLEAN
#include <Python.h>

#include <stdint.h>
#include <string.h>

#include "core/slc.h"
#include "core/slc_opt.h"

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

/* ── Puffer: bis zu 40 je Aufruf, gemeinsam freigegeben ── */

typedef struct { Py_buffer b[40]; int nb; } bufs;

static void bufs_free(bufs *B)
{
    int i;
    for (i = 0; i < B->nb; i++) PyBuffer_Release(&B->b[i]);
    B->nb = 0;
}

/* kind 'd' float64, 'i' int32; n >= 0: verlangte Laenge; Ergebnis Zeiger oder NULL (Ausnahme) */
static void *buf(bufs *B, PyObject *o, int writable, char kind, Py_ssize_t n, Py_ssize_t *len, const char *what)
{
    Py_buffer *v = &B->b[B->nb];
    int flags = PyBUF_C_CONTIGUOUS | PyBUF_FORMAT | (writable ? PyBUF_WRITABLE : 0);
    char f;
    if (PyObject_GetBuffer(o, v, flags) < 0) return NULL;
    B->nb++;
    f = v->format ? v->format[strlen(v->format) - 1] : 0;
    if ((kind == 'd' && (v->itemsize != 8 || f != 'd')) || (kind == 'i' && (v->itemsize != 4 || (f != 'i' && f != 'l')))) {
        PyErr_Format(PyExc_TypeError, "interner Fehler: %s hat den falschen Typ", what);
        return NULL;
    }
    if (n >= 0 && v->len / v->itemsize != n) {
        PyErr_Format(PyExc_TypeError, "interner Fehler: %s hat die falsche Laenge", what);
        return NULL;
    }
    if (len) *len = v->len / v->itemsize;
    return v->buf;
}

#define D(o, n, w) ((const double *) buf(&B, (o), 0, 'd', (n), NULL, (w)))
#define DW(o, n, w) ((double *) buf(&B, (o), 1, 'd', (n), NULL, (w)))
#define I(o, n, w) ((const int32_t *) buf(&B, (o), 0, 'i', (n), NULL, (w)))
#define IW(o, n, w) ((int32_t *) buf(&B, (o), 1, 'i', (n), NULL, (w)))
#define FAIL_IF(c) do { if (c) { bufs_free(&B); return NULL; } } while (0)

static int get_state(bufs *B, PyObject *o, sl_rng *r, void **dst)
{
    Py_buffer *v = &B->b[B->nb];
    if (PyObject_GetBuffer(o, v, PyBUF_C_CONTIGUOUS | PyBUF_WRITABLE) < 0) return -1;
    B->nb++;
    if (v->len != 32) { PyErr_SetString(PyExc_TypeError, "interner Fehler: Zufallszustand muss 32 Byte haben"); return -1; }
    memcpy(r->s, v->buf, 32);
    *dst = v->buf;
    return 0;
}

/* ── GARCH ── */

/* (eps, out, omega, alpha, beta, gamma, s2_init) */
static PyObject *slc_garch11_filter(PyObject *self, PyObject *args)
{
    PyObject *e, *o;
    double om, al, be, ga, s0;
    Py_ssize_t n;
    bufs B = {.nb = 0};
    const double *ep;
    double *out;
    sl_ctx cx;
    int st;
    (void) self;
    if (!PyArg_ParseTuple(args, "OOddddd", &e, &o, &om, &al, &be, &ga, &s0)) return NULL;
    ep = (const double *) buf(&B, e, 0, 'd', -1, &n, "eps"); FAIL_IF(!ep);
    out = DW(o, n, "Ausgabe"); FAIL_IF(!out);
    ctx_init(&cx);
    st = sl_garch11_filter(&cx, (int) n, ep, om, al, be, ga, s0, out);
    bufs_free(&B);
    if (finish(&cx, st) < 0) return NULL;
    Py_RETURN_NONE;
}

/* (e, par5, gjr, s2_init) -> nll */
static PyObject *slc_garch11_nll(PyObject *self, PyObject *args)
{
    PyObject *e, *p;
    int gjr, st;
    double s0, v = 0.0;
    Py_ssize_t n;
    bufs B = {.nb = 0};
    const double *ep, *pp;
    sl_ctx cx;
    (void) self;
    if (!PyArg_ParseTuple(args, "OOpd", &e, &p, &gjr, &s0)) return NULL;
    ep = (const double *) buf(&B, e, 0, 'd', -1, &n, "e"); FAIL_IF(!ep);
    pp = D(p, 5, "par"); FAIL_IF(!pp);
    ctx_init(&cx);
    st = sl_garch11_nll(&cx, (int) n, ep, gjr, pp, s0, &v);
    bufs_free(&B);
    if (finish(&cx, st) < 0) return NULL;
    return PyFloat_FromDouble(v);
}

/* (e, gjr, par_out5) -> (loglik, code) */
static PyObject *slc_garch11_fit(PyObject *self, PyObject *args)
{
    PyObject *e, *p;
    int gjr, st, code = 0;
    double ll = 0.0;
    Py_ssize_t n;
    bufs B = {.nb = 0};
    const double *ep;
    double *pp;
    sl_ctx cx;
    (void) self;
    if (!PyArg_ParseTuple(args, "OpO", &e, &gjr, &p)) return NULL;
    ep = (const double *) buf(&B, e, 0, 'd', -1, &n, "e"); FAIL_IF(!ep);
    pp = DW(p, 5, "par"); FAIL_IF(!pp);
    ctx_init(&cx);
    st = sl_garch11_fit(&cx, (int) n, ep, gjr, NULL, pp, &ll, &code);
    bufs_free(&B);
    if (finish(&cx, st) < 0) return NULL;
    return Py_BuildValue("(di)", ll, code);
}

/* (e, gjr, par_out5, s2_out, z_out) -> (loglik, code, method, s2_init, persistence) */
static PyObject *slc_garch11_estimate(PyObject *self, PyObject *args)
{
    PyObject *e, *p, *s, *z;
    int gjr, st, code = 0, meth = 0;
    double ll = 0.0, s2i = 0.0, pers = 0.0;
    Py_ssize_t n;
    bufs B = {.nb = 0};
    const double *ep;
    double *pp, *sp, *zp;
    sl_ctx cx;
    (void) self;
    if (!PyArg_ParseTuple(args, "OpOOO", &e, &gjr, &p, &s, &z)) return NULL;
    ep = (const double *) buf(&B, e, 0, 'd', -1, &n, "e"); FAIL_IF(!ep);
    pp = DW(p, 5, "par"); FAIL_IF(!pp);
    sp = DW(s, n, "s2"); FAIL_IF(!sp);
    zp = DW(z, n, "z"); FAIL_IF(!zp);
    ctx_init(&cx);
    st = sl_garch11_estimate(&cx, (int) n, ep, gjr, pp, &ll, &code, &meth, sp, zp, &s2i, &pers);
    bufs_free(&B);
    if (finish(&cx, st) < 0) return NULL;
    return Py_BuildValue("(diidd)", ll, code, meth, s2i, pers);
}

/* ── GPD ── */

static PyObject *slc_gpd_nll(PyObject *self, PyObject *args)
{
    PyObject *x;
    double sc, sh, v = 0.0;
    Py_ssize_t n;
    bufs B = {.nb = 0};
    const double *xp;
    sl_ctx cx;
    int st;
    (void) self;
    if (!PyArg_ParseTuple(args, "Odd", &x, &sc, &sh)) return NULL;
    xp = (const double *) buf(&B, x, 0, 'd', -1, &n, "x"); FAIL_IF(!xp);
    ctx_init(&cx);
    st = sl_gpd_nll(&cx, (int) n, xp, sc, sh, &v);
    bufs_free(&B);
    if (finish(&cx, st) < 0) return NULL;
    return PyFloat_FromDouble(v);
}

static PyObject *slc_gpd_pwm(PyObject *self, PyObject *args)
{
    PyObject *x;
    double sc = 0.0, sh = 0.0;
    Py_ssize_t n;
    bufs B = {.nb = 0};
    const double *xp;
    sl_ctx cx;
    int st;
    (void) self;
    if (!PyArg_ParseTuple(args, "O", &x)) return NULL;
    xp = (const double *) buf(&B, x, 0, 'd', -1, &n, "x"); FAIL_IF(!xp);
    ctx_init(&cx);
    st = sl_gpd_pwm(&cx, (int) n, xp, &sc, &sh);
    bufs_free(&B);
    if (finish(&cx, st) < 0) return NULL;
    return Py_BuildValue("(dd)", sc, sh);
}

static PyObject *slc_gpd_fit(PyObject *self, PyObject *args)
{
    PyObject *x;
    double sc = 0.0, sh = 0.0, ll = 0.0;
    Py_ssize_t n;
    bufs B = {.nb = 0};
    const double *xp;
    sl_ctx cx;
    int st, code = 0;
    (void) self;
    if (!PyArg_ParseTuple(args, "O", &x)) return NULL;
    xp = (const double *) buf(&B, x, 0, 'd', -1, &n, "x"); FAIL_IF(!xp);
    ctx_init(&cx);
    st = sl_gpd_fit(&cx, (int) n, xp, NULL, &sc, &sh, &ll, &code);
    bufs_free(&B);
    if (finish(&cx, st) < 0) return NULL;
    return Py_BuildValue("(dddi)", sc, sh, ll, code);
}

/* ── DCC ── */

/* (Z, n, k, a, b, Qbar, keep, R_out or None) -> (nll, ok) */
static PyObject *slc_dcc_filter(PyObject *self, PyObject *args)
{
    PyObject *Z, *Q, *R;
    int n, k, keep, ok = 0, st;
    double a, b, nll = 0.0;
    bufs B = {.nb = 0};
    const double *zp, *qp;
    double *rp = NULL;
    sl_ctx cx;
    (void) self;
    if (!PyArg_ParseTuple(args, "OiiddOpO", &Z, &n, &k, &a, &b, &Q, &keep, &R)) return NULL;
    zp = D(Z, (Py_ssize_t) n * k, "Z"); FAIL_IF(!zp);
    qp = D(Q, (Py_ssize_t) k * k, "Qbar"); FAIL_IF(!qp);
    if (keep) { rp = DW(R, (Py_ssize_t) n * (k * (k - 1) / 2), "R"); FAIL_IF(!rp); }
    ctx_init(&cx);
    st = sl_dcc_filter(&cx, n, k, zp, a, b, qp, keep, &nll, rp, &ok);
    bufs_free(&B);
    if (finish(&cx, st) < 0) return NULL;
    return Py_BuildValue("(dO)", nll, ok ? Py_True : Py_False);
}

/* (Z, n, k, Qbar) -> (a, b, nll, code, th1, th2) */
static PyObject *slc_dcc_fit(PyObject *self, PyObject *args)
{
    PyObject *Z, *Q;
    int n, k, st, code = 0;
    double a = 0.0, b = 0.0, nll = 0.0, th[2] = {0.0, 0.0};
    bufs B = {.nb = 0};
    const double *zp, *qp;
    sl_ctx cx;
    (void) self;
    if (!PyArg_ParseTuple(args, "OiiO", &Z, &n, &k, &Q)) return NULL;
    zp = D(Z, (Py_ssize_t) n * k, "Z"); FAIL_IF(!zp);
    qp = D(Q, (Py_ssize_t) k * k, "Qbar"); FAIL_IF(!qp);
    ctx_init(&cx);
    st = sl_dcc_fit(&cx, n, k, zp, qp, NULL, &a, &b, &nll, &code, th);
    bufs_free(&B);
    if (finish(&cx, st) < 0) return NULL;
    return Py_BuildValue("(dddidd)", a, b, nll, code, th[0], th[1]);
}

/* ── MS-GARCH, HMM ── */

/* (y, K, omega, alpha, beta, gamma, P, xi0, h1, h, pred, filt, lB) -> loglik */
static PyObject *slc_ms_garch_filter(PyObject *self, PyObject *args)
{
    PyObject *y, *om, *al, *be, *ga, *P, *xi, *h, *pr, *fl, *lb;
    int K, st;
    double h1, ll = 0.0;
    Py_ssize_t n;
    bufs B = {.nb = 0};
    const double *yp, *a1, *a2, *a3, *a4, *a5, *a6;
    double *o1, *o2, *o3, *o4;
    sl_ctx cx;
    (void) self;
    if (!PyArg_ParseTuple(args, "OiOOOOOOdOOOO", &y, &K, &om, &al, &be, &ga, &P, &xi, &h1, &h, &pr, &fl, &lb)) return NULL;
    yp = (const double *) buf(&B, y, 0, 'd', -1, &n, "y"); FAIL_IF(!yp);
    a1 = D(om, K, "omega"); FAIL_IF(!a1);
    a2 = D(al, K, "alpha"); FAIL_IF(!a2);
    a3 = D(be, K, "beta"); FAIL_IF(!a3);
    a4 = D(ga, K, "gamma"); FAIL_IF(!a4);
    a5 = D(P, (Py_ssize_t) K * K, "P"); FAIL_IF(!a5);
    a6 = D(xi, K, "xi0"); FAIL_IF(!a6);
    o1 = DW(h, n * K, "h"); FAIL_IF(!o1);
    o2 = DW(pr, n * K, "pred"); FAIL_IF(!o2);
    o3 = DW(fl, n * K, "filt"); FAIL_IF(!o3);
    o4 = DW(lb, n * K, "lB"); FAIL_IF(!o4);
    ctx_init(&cx);
    st = sl_msgarch_filter(&cx, (int) n, yp, K, a1, a2, a3, a4, a5, a6, h1, o1, o2, o3, o4, &ll);
    bufs_free(&B);
    if (finish(&cx, st) < 0) return NULL;
    return PyFloat_FromDouble(ll);
}

static PyObject *slc_ms_garch_npar(PyObject *self, PyObject *args)
{
    int K, gjr;
    (void) self;
    if (!PyArg_ParseTuple(args, "ip", &K, &gjr)) return NULL;
    return PyLong_FromLong(sl_msgarch_npar(K, gjr));
}

static PyObject *slc_ms_garch_maxstart(PyObject *self, PyObject *args)
{
    (void) self; (void) args;
    return PyLong_FromLong(SL_MSGARCH_MAXSTART);
}

/* (y, theta, K, gjr, h1) -> nll */
static PyObject *slc_ms_garch_nll(PyObject *self, PyObject *args)
{
    PyObject *y, *th;
    int K, gjr, st;
    double h1, v = 0.0;
    Py_ssize_t n;
    bufs B = {.nb = 0};
    const double *yp, *tp;
    sl_ctx cx;
    (void) self;
    if (!PyArg_ParseTuple(args, "OOipd", &y, &th, &K, &gjr, &h1)) return NULL;
    if (K < 1 || K > 1000) { PyErr_SetString(PyExc_ValueError, "interner Fehler: K"); return NULL; }
    yp = (const double *) buf(&B, y, 0, 'd', -1, &n, "y"); FAIL_IF(!yp);
    tp = D(th, sl_msgarch_npar(K, gjr), "theta"); FAIL_IF(!tp);
    ctx_init(&cx);
    st = sl_msgarch_nll(&cx, (int) n, yp, K, gjr, tp, h1, &v);
    bufs_free(&B);
    if (finish(&cx, st) < 0) return NULL;
    return PyFloat_FromDouble(v);
}

/* N1: (y, theta, K, gjr, h1, out[npar]) -> nll; out = analytischer Gradient */
static PyObject *slc_ms_garch_grad(PyObject *self, PyObject *args)
{
    PyObject *y, *th, *o;
    int K, gjr, st;
    double h1, v = 0.0;
    Py_ssize_t n;
    bufs B = {.nb = 0};
    const double *yp, *tp;
    double *op;
    sl_ctx cx;
    (void) self;
    if (!PyArg_ParseTuple(args, "OOipdO", &y, &th, &K, &gjr, &h1, &o)) return NULL;
    if (K < 1 || K > 64) { PyErr_SetString(PyExc_ValueError, "interner Fehler: K"); return NULL; }
    yp = (const double *) buf(&B, y, 0, 'd', -1, &n, "y"); FAIL_IF(!yp);
    tp = D(th, sl_msgarch_npar(K, gjr), "theta"); FAIL_IF(!tp);
    op = DW(o, sl_msgarch_npar(K, gjr), "gradient"); FAIL_IF(!op);
    ctx_init(&cx);
    st = sl_msgarch_grad(&cx, (int) n, yp, K, gjr, tp, h1, &v, op);
    bufs_free(&B);
    if (finish(&cx, st) < 0) return NULL;
    return PyFloat_FromDouble(v);
}

/* (y, K, gjr, h1, all, out[npar * SL_MSGARCH_MAXSTART]) -> nstart */
static PyObject *slc_ms_garch_starts(PyObject *self, PyObject *args)
{
    PyObject *y, *o;
    int K, gjr, st, ns = 0, all;
    double h1;
    Py_ssize_t n;
    bufs B = {.nb = 0};
    const double *yp;
    double *op;
    sl_ctx cx;
    (void) self;
    if (!PyArg_ParseTuple(args, "OipdpO", &y, &K, &gjr, &h1, &all, &o)) return NULL;
    if (K < 2 || K > 64) { PyErr_Format(PyExc_ValueError, "MS-GARCH: Anzahl Regime muss zwischen 2 und 64 liegen (erhalten: %d)", K); return NULL; }
    yp = (const double *) buf(&B, y, 0, 'd', -1, &n, "y"); FAIL_IF(!yp);
    op = DW(o, SL_MSGARCH_MAXSTART * (Py_ssize_t) sl_msgarch_npar(K, gjr), "starts"); FAIL_IF(!op);
    ctx_init(&cx);
    st = sl_msgarch_starts(&cx, (int) n, yp, K, gjr, h1, all, &ns, op);
    bufs_free(&B);
    if (finish(&cx, st) < 0) return NULL;
    return PyLong_FromLong(ns);
}

/* (y, K, gjr, starts (npar x ns, spaltenweise), ns, h1, theta_out) -> (value, code) */
static PyObject *slc_ms_garch_fitstarts(PyObject *self, PyObject *args)
{
    PyObject *y, *s, *o;
    int K, gjr, ns, st, code = 0, np;
    double h1, v = 0.0;
    Py_ssize_t n;
    bufs B = {.nb = 0};
    const double *yp, *sp;
    double *op;
    sl_ctx cx;
    (void) self;
    if (!PyArg_ParseTuple(args, "OipOidO", &y, &K, &gjr, &s, &ns, &h1, &o)) return NULL;
    if (K < 1 || K > 1000 || ns < 0) { PyErr_SetString(PyExc_ValueError, "interner Fehler: K"); return NULL; }
    np = sl_msgarch_npar(K, gjr);
    yp = (const double *) buf(&B, y, 0, 'd', -1, &n, "y"); FAIL_IF(!yp);
    sp = D(s, (Py_ssize_t) np * ns, "starts"); FAIL_IF(!sp);
    op = DW(o, np, "theta"); FAIL_IF(!op);
    ctx_init(&cx);
    st = sl_msgarch_fit(&cx, (int) n, yp, K, gjr, ns, sp, h1, NULL, op, &v, &code);
    bufs_free(&B);
    if (finish(&cx, st) < 0) return NULL;
    return Py_BuildValue("(di)", v, code);
}

/* (y, K, gjr, omega, alpha, beta, gamma, P, regimes, s2) -> (loglik, code) */
static PyObject *slc_ms_garch_estimate(PyObject *self, PyObject *args)
{
    PyObject *y, *om, *al, *be, *ga, *P, *rg, *s2;
    int K, gjr, st, code = 0;
    double ll = 0.0;
    Py_ssize_t n;
    bufs B = {.nb = 0};
    const double *yp;
    double *o1, *o2, *o3, *o4, *o5, *o7;
    int32_t *o6;
    sl_ctx cx;
    (void) self;
    if (!PyArg_ParseTuple(args, "OipOOOOOOO", &y, &K, &gjr, &om, &al, &be, &ga, &P, &rg, &s2)) return NULL;
    if (K < 2 || K > 64) { PyErr_Format(PyExc_ValueError, "MS-GARCH: Anzahl Regime muss zwischen 2 und 64 liegen (erhalten: %d)", K); return NULL; }
    yp = (const double *) buf(&B, y, 0, 'd', -1, &n, "y"); FAIL_IF(!yp);
    o1 = DW(om, K, "omega"); FAIL_IF(!o1);
    o2 = DW(al, K, "alpha"); FAIL_IF(!o2);
    o3 = DW(be, K, "beta"); FAIL_IF(!o3);
    o4 = DW(ga, K, "gamma"); FAIL_IF(!o4);
    o5 = DW(P, (Py_ssize_t) K * K, "P"); FAIL_IF(!o5);
    o6 = IW(rg, n, "regimes"); FAIL_IF(!o6);
    o7 = DW(s2, n, "s2"); FAIL_IF(!o7);
    ctx_init(&cx);
    st = sl_msgarch_estimate(&cx, (int) n, yp, K, gjr, o1, o2, o3, o4, o5, o6, o7, &ll, &code);
    bufs_free(&B);
    if (finish(&cx, st) < 0) return NULL;
    return Py_BuildValue("(di)", ll, code);
}

/* (x, K, win, max_iter, tol, mu, S, A) -> (ll, iter) */
static PyObject *slc_hmm_em_univ(PyObject *self, PyObject *args)
{
    PyObject *x, *mu, *S, *A;
    int K, win, mi, st, it = 0;
    double tol, ll = 0.0;
    Py_ssize_t n;
    bufs B = {.nb = 0};
    const double *xp;
    double *o1, *o2, *o3;
    sl_ctx cx;
    (void) self;
    if (!PyArg_ParseTuple(args, "OiiidOOO", &x, &K, &win, &mi, &tol, &mu, &S, &A)) return NULL;
    if (K < 2 || K > 64) { PyErr_Format(PyExc_ValueError, "HMM: Anzahl Zustände muss zwischen 2 und 64 liegen (erhalten: %d)", K); return NULL; }
    xp = (const double *) buf(&B, x, 0, 'd', -1, &n, "x"); FAIL_IF(!xp);
    o1 = DW(mu, K, "mu"); FAIL_IF(!o1);
    o2 = DW(S, K, "S"); FAIL_IF(!o2);
    o3 = DW(A, (Py_ssize_t) K * K, "A"); FAIL_IF(!o3);
    ctx_init(&cx);
    st = sl_hmm_em_univ(&cx, (int) n, xp, K, win, mi, tol, o1, o2, o3, &ll, &it);
    bufs_free(&B);
    if (finish(&cx, st) < 0) return NULL;
    return Py_BuildValue("(di)", ll, it);
}

/* (lB, n, K, lA, lp0, path_out) */
static PyObject *slc_hmm_viterbi(PyObject *self, PyObject *args)
{
    PyObject *lB, *lA, *lp, *o;
    int n, K, st;
    bufs B = {.nb = 0};
    const double *a, *b, *c;
    int32_t *op;
    sl_ctx cx;
    (void) self;
    if (!PyArg_ParseTuple(args, "OiiOOO", &lB, &n, &K, &lA, &lp, &o)) return NULL;
    a = D(lB, (Py_ssize_t) n * K, "lB"); FAIL_IF(!a);
    b = D(lA, (Py_ssize_t) K * K, "lA"); FAIL_IF(!b);
    c = D(lp, K, "lp0"); FAIL_IF(!c);
    op = IW(o, n, "Ausgabe"); FAIL_IF(!op);
    ctx_init(&cx);
    st = sl_hmm_viterbi(&cx, n, K, a, b, c, op);
    bufs_free(&B);
    if (finish(&cx, st) < 0) return NULL;
    Py_RETURN_NONE;
}

/* ── Bootstrap-Kerne: erstes Argument der Zustand (32 Byte), Ausgaben vom Aufrufer ── */

#define BOOT_DONE(st)                                                    \
    do {                                                                 \
        if ((st) == SL_OK) memcpy(sdst, r.s, 32);                        \
        bufs_free(&B);                                                   \
        if (finish(&cx, (st)) < 0) return NULL;                          \
        Py_RETURN_NONE;                                                  \
    } while (0)

/* (state, out_int32, n_src) */
static PyObject *slc_boot_idx_iid(PyObject *self, PyObject *args)
{
    PyObject *s, *o;
    int nsrc, st;
    Py_ssize_t no;
    bufs B = {.nb = 0};
    sl_rng r; sl_ctx cx; void *sdst; int32_t *op;
    (void) self;
    if (!PyArg_ParseTuple(args, "OOi", &s, &o, &nsrc)) return NULL;
    FAIL_IF(get_state(&B, s, &r, &sdst) < 0);
    op = (int32_t *) buf(&B, o, 1, 'i', -1, &no, "Ausgabe"); FAIL_IF(!op);
    ctx_init(&cx);
    st = sl_boot_idx_iid(&cx, &r, nsrc, (int) no, op);
    BOOT_DONE(st);
}

/* (state, out, n_src, block_length, circular) */
static PyObject *slc_boot_idx_block(PyObject *self, PyObject *args)
{
    PyObject *s, *o;
    int nsrc, bl, circ, st;
    Py_ssize_t no;
    bufs B = {.nb = 0};
    sl_rng r; sl_ctx cx; void *sdst; int32_t *op;
    (void) self;
    if (!PyArg_ParseTuple(args, "OOiip", &s, &o, &nsrc, &bl, &circ)) return NULL;
    FAIL_IF(get_state(&B, s, &r, &sdst) < 0);
    op = (int32_t *) buf(&B, o, 1, 'i', -1, &no, "Ausgabe"); FAIL_IF(!op);
    ctx_init(&cx);
    st = sl_boot_idx_block(&cx, &r, nsrc, (int) no, bl, circ, op);
    BOOT_DONE(st);
}

/* (state, out, n_src, L) */
static PyObject *slc_boot_idx_stationary(PyObject *self, PyObject *args)
{
    PyObject *s, *o;
    int nsrc, st;
    double L;
    Py_ssize_t no;
    bufs B = {.nb = 0};
    sl_rng r; sl_ctx cx; void *sdst; int32_t *op;
    (void) self;
    if (!PyArg_ParseTuple(args, "OOid", &s, &o, &nsrc, &L)) return NULL;
    FAIL_IF(get_state(&B, s, &r, &sdst) < 0);
    op = (int32_t *) buf(&B, o, 1, 'i', -1, &no, "Ausgabe"); FAIL_IF(!op);
    ctx_init(&cx);
    st = sl_boot_idx_stationary(&cx, &r, nsrc, (int) no, L, op);
    BOOT_DONE(st);
}

/* (state, out, regimes_int32, K, trans) */
static PyObject *slc_boot_idx_regime(PyObject *self, PyObject *args)
{
    PyObject *s, *o, *rg, *tr;
    int K, st;
    Py_ssize_t no, n;
    bufs B = {.nb = 0};
    sl_rng r; sl_ctx cx; void *sdst; int32_t *op; const int32_t *rp; const double *tp;
    (void) self;
    if (!PyArg_ParseTuple(args, "OOOiO", &s, &o, &rg, &K, &tr)) return NULL;
    FAIL_IF(get_state(&B, s, &r, &sdst) < 0);
    op = (int32_t *) buf(&B, o, 1, 'i', -1, &no, "Ausgabe"); FAIL_IF(!op);
    rp = (const int32_t *) buf(&B, rg, 0, 'i', -1, &n, "regimes"); FAIL_IF(!rp);
    tp = D(tr, (Py_ssize_t) K * K, "trans"); FAIL_IF(!tp);
    ctx_init(&cx);
    st = sl_boot_idx_regime(&cx, &r, (int) n, rp, K, tp, (int) no, op);
    BOOT_DONE(st);
}

/* (state, out, p_l, p_r, bulk, left, right) */
static PyObject *slc_boot_idx_tails(PyObject *self, PyObject *args)
{
    PyObject *s, *o, *bk, *lf, *rt;
    int st;
    double pl, pr;
    Py_ssize_t no, nb, nl, nr;
    bufs B = {.nb = 0};
    sl_rng r; sl_ctx cx; void *sdst; int32_t *op; const int32_t *bp, *lp, *rp;
    (void) self;
    if (!PyArg_ParseTuple(args, "OOddOOO", &s, &o, &pl, &pr, &bk, &lf, &rt)) return NULL;
    FAIL_IF(get_state(&B, s, &r, &sdst) < 0);
    op = (int32_t *) buf(&B, o, 1, 'i', -1, &no, "Ausgabe"); FAIL_IF(!op);
    bp = (const int32_t *) buf(&B, bk, 0, 'i', -1, &nb, "bulk_idx"); FAIL_IF(!bp);
    lp = (const int32_t *) buf(&B, lf, 0, 'i', -1, &nl, "left_idx"); FAIL_IF(!lp);
    rp = (const int32_t *) buf(&B, rt, 0, 'i', -1, &nr, "right_idx"); FAIL_IF(!rp);
    ctx_init(&cx);
    st = sl_boot_idx_tails(&cx, &r, (int) no, pl, pr, (int) nb, bp, (int) nl, lp, (int) nr, rp, op);
    BOOT_DONE(st);
}

/* (state, ret (n x k spaltenweise), n, k, type, out) */
static PyObject *slc_boot_wild(PyObject *self, PyObject *args)
{
    PyObject *s, *x, *o;
    int n, k, type, st;
    bufs B = {.nb = 0};
    sl_rng r; sl_ctx cx; void *sdst; const double *xp; double *op;
    (void) self;
    if (!PyArg_ParseTuple(args, "OOiiiO", &s, &x, &n, &k, &type, &o)) return NULL;
    FAIL_IF(get_state(&B, s, &r, &sdst) < 0);
    xp = D(x, (Py_ssize_t) n * k, "returns"); FAIL_IF(!xp);
    op = DW(o, (Py_ssize_t) n * k, "Ausgabe"); FAIL_IF(!op);
    ctx_init(&cx);
    st = sl_boot_wild(&cx, &r, n, k, xp, type, op);
    BOOT_DONE(st);
}

static PyObject *slc_boot_reset(PyObject *self, PyObject *args)
{
    PyObject *s, *x, *o;
    int n, k, st;
    double pb;
    bufs B = {.nb = 0};
    sl_rng r; sl_ctx cx; void *sdst; const double *xp; double *op;
    (void) self;
    if (!PyArg_ParseTuple(args, "OOiidO", &s, &x, &n, &k, &pb, &o)) return NULL;
    FAIL_IF(get_state(&B, s, &r, &sdst) < 0);
    xp = D(x, (Py_ssize_t) n * k, "returns"); FAIL_IF(!xp);
    op = DW(o, (Py_ssize_t) n * k, "Ausgabe"); FAIL_IF(!op);
    ctx_init(&cx);
    st = sl_boot_reset(&cx, &r, n, k, xp, pb, op);
    BOOT_DONE(st);
}

/* (state, ret, n, k, base, n_out, par_l4, pool_l, par_r4, pool_r, bulk, out, idx) */
static PyObject *slc_boot_evt(PyObject *self, PyObject *args)
{
    PyObject *s, *x, *pl, *ql, *pr, *qr, *bk, *o, *ix;
    int n, k, base, no, st;
    Py_ssize_t nl, nr, nb;
    bufs B = {.nb = 0};
    sl_rng r; sl_ctx cx; void *sdst; const double *xp, *a, *b; const int32_t *lp, *rp, *bp; double *op; int32_t *ip;
    (void) self;
    if (!PyArg_ParseTuple(args, "OOiiiiOOOOOOO", &s, &x, &n, &k, &base, &no, &pl, &ql, &pr, &qr, &bk, &o, &ix)) return NULL;
    FAIL_IF(get_state(&B, s, &r, &sdst) < 0);
    xp = D(x, (Py_ssize_t) n * k, "returns"); FAIL_IF(!xp);
    a = D(pl, 4, "par_l"); FAIL_IF(!a);
    lp = (const int32_t *) buf(&B, ql, 0, 'i', -1, &nl, "pool_l"); FAIL_IF(!lp);
    b = D(pr, 4, "par_r"); FAIL_IF(!b);
    rp = (const int32_t *) buf(&B, qr, 0, 'i', -1, &nr, "pool_r"); FAIL_IF(!rp);
    bp = (const int32_t *) buf(&B, bk, 0, 'i', -1, &nb, "bulk_idx"); FAIL_IF(!bp);
    op = DW(o, (Py_ssize_t) no * k, "ret"); FAIL_IF(!op);
    ip = IW(ix, no, "idx"); FAIL_IF(!ip);
    ctx_init(&cx);
    st = sl_boot_evt(&cx, &r, n, k, xp, base, no, a[0], a[1], a[2], a[3], (int) nl, lp, b[0], b[1], b[2], b[3],
                     (int) nr, rp, (int) nb, bp, op, ip);
    BOOT_DONE(st);
}

/* Kopplung: (cols, mu, om, al, be, ratio, s2, z (n_src x m spaltenweise)) als Tupel */
typedef struct { int m; const int32_t *cols, *ratio; const double *mu, *om, *al, *be, *s2, *z; } cross_args;

static int get_cross(bufs *Bp, PyObject *t, int n_src, cross_args *c)
{
#define B (*Bp)
    PyObject *o[8];
    Py_ssize_t m;
    if (!PyArg_ParseTuple(t, "OOOOOOOO", &o[0], &o[1], &o[2], &o[3], &o[4], &o[5], &o[6], &o[7])) return -1;
    c->cols = (const int32_t *) buf(Bp, o[0], 0, 'i', -1, &m, "cross_cols"); if (!c->cols) return -1;
    c->m = (int) m;
    if (!(c->mu = D(o[1], m, "cmu"))) return -1;
    if (!(c->om = D(o[2], m, "com"))) return -1;
    if (!(c->al = D(o[3], m, "cal"))) return -1;
    if (!(c->be = D(o[4], m, "cbe"))) return -1;
    if (!(c->ratio = I(o[5], m, "cratio"))) return -1;
    if (!(c->s2 = D(o[6], m, "cs2"))) return -1;
    if (!(c->z = D(o[7], m * n_src, "z_cross"))) return -1;
    return 0;
#undef B
}

/* (state, n_out, base, k, garch6, z_base, valid, cross, out, idx) */
static PyObject *slc_boot_garch(PyObject *self, PyObject *args)
{
    PyObject *s, *g, *zb, *vl, *cr, *o, *ix;
    int no, base, k, st;
    Py_ssize_t ns, nv;
    bufs B = {.nb = 0};
    sl_rng r; sl_ctx cx; void *sdst; const double *gp, *zp; const int32_t *vp; double *op; int32_t *ip;
    cross_args c;
    (void) self;
    if (!PyArg_ParseTuple(args, "OiiiOOOO!OO", &s, &no, &base, &k, &g, &zb, &vl, &PyTuple_Type, &cr, &o, &ix)) return NULL;
    FAIL_IF(get_state(&B, s, &r, &sdst) < 0);
    gp = D(g, 6, "garch"); FAIL_IF(!gp);
    zp = (const double *) buf(&B, zb, 0, 'd', -1, &ns, "z_base"); FAIL_IF(!zp);
    vp = (const int32_t *) buf(&B, vl, 0, 'i', -1, &nv, "valid"); FAIL_IF(!vp);
    FAIL_IF(get_cross(&B, cr, (int) ns, &c) < 0);
    op = DW(o, (Py_ssize_t) no * k, "ret"); FAIL_IF(!op);
    ip = IW(ix, no, "idx"); FAIL_IF(!ip);
    ctx_init(&cx);
    st = sl_boot_garch(&cx, &r, no, base, k, gp[0], gp[1], gp[2], gp[3], gp[4], gp[5], (int) ns, zp, (int) nv, vp,
                       c.m, c.cols, c.mu, c.om, c.al, c.be, c.ratio, c.s2, c.z, op, ip);
    BOOT_DONE(st);
}

/* (state, n_out, base, k, K, mtuple(11), pool_off, pool_idx, z_base, cross, out, idx, regime) */
static PyObject *slc_boot_ms_garch(PyObject *self, PyObject *args)
{
    PyObject *s, *mt, *po, *pi, *zb, *cr, *o, *ix, *rg, *mo[11];
    int no, base, k, K, st, i;
    Py_ssize_t ns, npi;
    bufs B = {.nb = 0};
    sl_rng r; sl_ctx cx; void *sdst; const double *v[11], *zp; const int32_t *pop, *pip; double *op; int32_t *ip, *rp;
    cross_args c;
    (void) self;
    if (!PyArg_ParseTuple(args, "OiiiiO!OOOO!OOO", &s, &no, &base, &k, &K, &PyTuple_Type, &mt, &po, &pi, &zb,
                          &PyTuple_Type, &cr, &o, &ix, &rg)) return NULL;
    if (K < 1) { PyErr_SetString(PyExc_ValueError, "Anzahl Regime muss >= 1 sein"); return NULL; }
    if (!PyArg_ParseTuple(mt, "OOOOOOOOOOO", &mo[0], &mo[1], &mo[2], &mo[3], &mo[4], &mo[5], &mo[6], &mo[7], &mo[8],
                          &mo[9], &mo[10])) return NULL;
    FAIL_IF(get_state(&B, s, &r, &sdst) < 0);
    for (i = 0; i < 11; i++) {
        v[i] = D(mo[i], (i == 7 || i == 8) ? (Py_ssize_t) K * K : K, "Regimeparameter");
        FAIL_IF(!v[i]);
    }
    pop = I(po, K + 1, "pool_off"); FAIL_IF(!pop);
    pip = (const int32_t *) buf(&B, pi, 0, 'i', -1, &npi, "pool_idx"); FAIL_IF(!pip);
    zp = (const double *) buf(&B, zb, 0, 'd', -1, &ns, "z_base"); FAIL_IF(!zp);
    FAIL_IF(get_cross(&B, cr, (int) ns, &c) < 0);
    if (pop[K] != npi) { bufs_free(&B); PyErr_SetString(PyExc_ValueError, "interner Fehler: Grenzen der Regime-Pools"); return NULL; }
    op = DW(o, (Py_ssize_t) no * k, "ret"); FAIL_IF(!op);
    ip = IW(ix, no, "idx"); FAIL_IF(!ip);
    rp = IW(rg, no, "regime"); FAIL_IF(!rp);
    ctx_init(&cx);
    st = sl_boot_ms_garch(&cx, &r, no, base, k, K, v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7], v[8], v[9], v[10],
                          pop, pip, (int) ns, zp, c.m, c.cols, c.mu, c.om, c.al, c.be, c.ratio, c.s2, c.z, op, ip, rp);
    BOOT_DONE(st);
}

/* ── ohne Zufall ── */

static PyObject *slc_rolling_vol(PyObject *self, PyObject *args)
{
    PyObject *x, *o;
    int w, st;
    Py_ssize_t n;
    bufs B = {.nb = 0};
    const double *xp; double *op; sl_ctx cx;
    (void) self;
    if (!PyArg_ParseTuple(args, "OiO", &x, &w, &o)) return NULL;
    xp = (const double *) buf(&B, x, 0, 'd', -1, &n, "x"); FAIL_IF(!xp);
    op = DW(o, n, "Ausgabe"); FAIL_IF(!op);
    ctx_init(&cx);
    st = sl_rolling_vol(&cx, (int) n, xp, w, op);
    bufs_free(&B);
    if (finish(&cx, st) < 0) return NULL;
    Py_RETURN_NONE;
}

static PyObject *slc_assign_regimes(PyObject *self, PyObject *args)
{
    PyObject *x, *t, *o;
    int st;
    Py_ssize_t n, nt;
    bufs B = {.nb = 0};
    const double *xp, *tp; int32_t *op; sl_ctx cx;
    (void) self;
    if (!PyArg_ParseTuple(args, "OOO", &x, &t, &o)) return NULL;
    xp = (const double *) buf(&B, x, 0, 'd', -1, &n, "vol"); FAIL_IF(!xp);
    tp = (const double *) buf(&B, t, 0, 'd', -1, &nt, "thresh"); FAIL_IF(!tp);
    op = IW(o, n, "Ausgabe"); FAIL_IF(!op);
    ctx_init(&cx);
    st = sl_assign_regimes(&cx, (int) n, xp, (int) nt, tp, op);
    bufs_free(&B);
    if (finish(&cx, st) < 0) return NULL;
    Py_RETURN_NONE;
}

static PyObject *slc_estimate_trans_mat(PyObject *self, PyObject *args)
{
    PyObject *x, *o;
    int K, st;
    double a;
    Py_ssize_t n;
    bufs B = {.nb = 0};
    const int32_t *xp; double *op; sl_ctx cx;
    (void) self;
    if (!PyArg_ParseTuple(args, "OidO", &x, &K, &a, &o)) return NULL;
    if (K < 1) { PyErr_SetString(PyExc_ValueError, "K muss >= 1 sein"); return NULL; }
    xp = (const int32_t *) buf(&B, x, 0, 'i', -1, &n, "regimes"); FAIL_IF(!xp);
    op = DW(o, (Py_ssize_t) K * K, "Ausgabe"); FAIL_IF(!op);
    ctx_init(&cx);
    st = sl_estimate_trans_mat(&cx, (int) n, xp, K, a, op);
    bufs_free(&B);
    if (finish(&cx, st) < 0) return NULL;
    Py_RETURN_NONE;
}

PyMethodDef simlev_ext_slc_models_methods[] = {
    {"slc_garch11_filter", slc_garch11_filter, METH_VARARGS, "9.4: GARCH-Filter"},
    {"slc_garch11_nll", slc_garch11_nll, METH_VARARGS, "9.4: GARCH-NLL"},
    {"slc_garch11_fit", slc_garch11_fit, METH_VARARGS, "9.4: GARCH-ML"},
    {"slc_garch11_estimate", slc_garch11_estimate, METH_VARARGS, "9.4: GARCH-Stufe wie .fit_garch11"},
    {"slc_gpd_nll", slc_gpd_nll, METH_VARARGS, "9.4: GPD-NLL"},
    {"slc_gpd_pwm", slc_gpd_pwm, METH_VARARGS, "9.4: GPD-PWM"},
    {"slc_gpd_fit", slc_gpd_fit, METH_VARARGS, "9.4: GPD-ML"},
    {"slc_dcc_filter", slc_dcc_filter, METH_VARARGS, "9.4: DCC-Filter"},
    {"slc_dcc_fit", slc_dcc_fit, METH_VARARGS, "9.4: DCC-Schätzung"},
    {"slc_ms_garch_filter", slc_ms_garch_filter, METH_VARARGS, "9.4: MS-GARCH-Filter"},
    {"slc_ms_garch_npar", slc_ms_garch_npar, METH_VARARGS, "9.4: Zahl der MS-GARCH-Parameter"},
    {"slc_ms_garch_maxstart", slc_ms_garch_maxstart, METH_NOARGS, "9.4: höchste Zahl der MS-GARCH-Startpunkte"},
    {"slc_ms_garch_nll", slc_ms_garch_nll, METH_VARARGS, "9.4: MS-GARCH-NLL"},
    {"slc_ms_garch_grad", slc_ms_garch_grad, METH_VARARGS, "N1: MS-GARCH-NLL mit analytischem Gradienten"},
    {"slc_ms_garch_starts", slc_ms_garch_starts, METH_VARARGS, "9.4: MS-GARCH-Startpunkte"},
    {"slc_ms_garch_fitstarts", slc_ms_garch_fitstarts, METH_VARARGS, "9.4: MS-GARCH-BFGS ab Startpunkten"},
    {"slc_ms_garch_estimate", slc_ms_garch_estimate, METH_VARARGS, "9.4: MS-GARCH wie .ms_garch_fit"},
    {"slc_hmm_em_univ", slc_hmm_em_univ, METH_VARARGS, "9.4: univariates HMM-EM"},
    {"slc_hmm_viterbi", slc_hmm_viterbi, METH_VARARGS, "9.4: Viterbi"},
    {"slc_boot_idx_iid", slc_boot_idx_iid, METH_VARARGS, "9.4: Bootstrap iid"},
    {"slc_boot_idx_block", slc_boot_idx_block, METH_VARARGS, "9.4: Bootstrap Blöcke"},
    {"slc_boot_idx_stationary", slc_boot_idx_stationary, METH_VARARGS, "9.4: Bootstrap stationär"},
    {"slc_boot_idx_regime", slc_boot_idx_regime, METH_VARARGS, "9.4: Bootstrap Regime"},
    {"slc_boot_idx_tails", slc_boot_idx_tails, METH_VARARGS, "9.4: Bootstrap Ränder"},
    {"slc_boot_wild", slc_boot_wild, METH_VARARGS, "9.4: Wild-Bootstrap"},
    {"slc_boot_reset", slc_boot_reset, METH_VARARGS, "9.4: Reset-Bootstrap"},
    {"slc_boot_evt", slc_boot_evt, METH_VARARGS, "9.4: EVT-Bootstrap"},
    {"slc_boot_garch", slc_boot_garch, METH_VARARGS, "9.4: GARCH-Bootstrap"},
    {"slc_boot_ms_garch", slc_boot_ms_garch, METH_VARARGS, "9.4: MS-GARCH-Bootstrap"},
    {"slc_rolling_vol", slc_rolling_vol, METH_VARARGS, "9.4: rollierende Volatilität"},
    {"slc_assign_regimes", slc_assign_regimes, METH_VARARGS, "9.4: Regime über Schwellen"},
    {"slc_estimate_trans_mat", slc_estimate_trans_mat, METH_VARARGS, "9.4: Übergangsmatrix"},
    {NULL, NULL, 0, NULL}
};

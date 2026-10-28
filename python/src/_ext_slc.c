/*
 * python/src/_ext_slc.c -- Python-Huellen der C-Bibliothek slc im Modul simlev._ext (Etappe 9.1)
 *
 * Die Kerne src/core/slc*.c, slc*.h sind Byte-fuer-Byte-Kopien der kanonischen Quellen in core/
 * (tools/core_sync.py); nur diese Huelle gibt es nur hier. Die Python-Seite (simlev/_lib.py)
 * prueft Argumente und legt die Felder an; die Huellen pruefen nur Typ, Laenge und
 * Beschreibbarkeit der Puffer.
 *
 * Rueckmeldungen (Entwurf C.4): Warnungen des Kerns nach dem Aufruf in Reihenfolge mit
 * warnings.warn (UserWarning), Fehler als ValueError mit dem Text des Kerns. Abbruch:
 * PyErr_CheckSignals() < 0 (die Huelle haelt die GIL) -> SL_EINTR -> die Ausnahme des
 * Signal-Handlers (KeyboardInterrupt).
 *
 * Zufallszustand: beschreibbarer Puffer mit 32 Byte (bytearray; Host-Bytereihenfolge von
 * uint64_t[4]). Die Huelle rechnet auf einer Kopie und schreibt den Zustand nur bei Erfolg zurueck.
 */
#define PY_SSIZE_T_CLEAN
#include <Python.h>

#include <stdint.h>
#include <string.h>

#include "core/slc.h"

/* ── Hilfen ── */

static int py_interrupted(void *h) { (void) h; return PyErr_CheckSignals() < 0; }

static void ctx_init(sl_ctx *cx)
{
    sl_ctx_init(cx);
    cx->interrupted = py_interrupted;
}

/* Warnungen ausgeben, Fehler setzen; 0 = ok, -1 = Ausnahme gesetzt */
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

/* Puffer holen: itemsize und Formatzeichen pruefen (fmts = erlaubte letzte Zeichen) */
static int get_buf(PyObject *o, Py_buffer *v, int writable, Py_ssize_t itemsize, const char *fmts, const char *what)
{
    int flags = PyBUF_C_CONTIGUOUS | PyBUF_FORMAT | (writable ? PyBUF_WRITABLE : 0);
    if (PyObject_GetBuffer(o, v, flags) < 0) return -1;
    if (v->itemsize != itemsize || v->format == NULL || strchr(fmts, v->format[strlen(v->format) - 1]) == NULL) {
        PyBuffer_Release(v);
        PyErr_Format(PyExc_TypeError, "interner Fehler: %s hat den falschen Typ", what);
        return -1;
    }
    return 0;
}

static int get_state(PyObject *o, Py_buffer *v, sl_rng *r)
{
    if (PyObject_GetBuffer(o, v, PyBUF_C_CONTIGUOUS | PyBUF_WRITABLE) < 0) return -1;
    if (v->len != 32) {
        PyBuffer_Release(v);
        PyErr_SetString(PyExc_TypeError, "interner Fehler: Zufallszustand muss 32 Byte haben");
        return -1;
    }
    memcpy(r->s, v->buf, 32);
    return 0;
}

static void put_state(Py_buffer *v, const sl_rng *r) { memcpy(v->buf, r->s, 32); }

#define NITEMS(v) ((v).len / (v).itemsize)

/* ── Zustand ── */

static PyObject *slc_version(PyObject *self, PyObject *args)
{
    (void) self; (void) args;
    return PyUnicode_FromString(sl_version());
}

static PyObject *slc_seed(PyObject *self, PyObject *args)
{
    PyObject *st;
    long long seed;
    Py_buffer v;
    sl_rng r;
    (void) self;
    if (!PyArg_ParseTuple(args, "OL", &st, &seed)) return NULL;
    if (get_state(st, &v, &r) < 0) return NULL;
    sl_rng_seed(&r, (int64_t) seed);
    put_state(&v, &r);
    PyBuffer_Release(&v);
    Py_RETURN_NONE;
}

static PyObject *slc_seed_entropy(PyObject *self, PyObject *args)
{
    PyObject *st;
    unsigned long long a, b, c;
    Py_buffer v;
    sl_rng r;
    (void) self;
    if (!PyArg_ParseTuple(args, "OKKK", &st, &a, &b, &c)) return NULL;
    if (get_state(st, &v, &r) < 0) return NULL;
    sl_rng_seed_entropy(&r, (uint64_t) a, (uint64_t) b, (uint64_t) c);
    put_state(&v, &r);
    PyBuffer_Release(&v);
    Py_RETURN_NONE;
}

static PyObject *slc_jump(PyObject *self, PyObject *args)
{
    PyObject *st;
    Py_buffer v;
    sl_rng r;
    (void) self;
    if (!PyArg_ParseTuple(args, "O", &st)) return NULL;
    if (get_state(st, &v, &r) < 0) return NULL;
    sl_rng_jump(&r);
    put_state(&v, &r);
    PyBuffer_Release(&v);
    Py_RETURN_NONE;
}

static PyObject *slc_streams(PyObject *self, PyObject *args)
{
    PyObject *st, *out;
    Py_buffer v, o;
    sl_rng r;
    sl_ctx cx;
    int rc;
    (void) self;
    if (!PyArg_ParseTuple(args, "OO", &st, &out)) return NULL;
    if (get_state(st, &v, &r) < 0) return NULL;
    if (PyObject_GetBuffer(out, &o, PyBUF_C_CONTIGUOUS | PyBUF_WRITABLE) < 0) { PyBuffer_Release(&v); return NULL; }
    if (o.len % 32 != 0) {
        PyBuffer_Release(&v); PyBuffer_Release(&o);
        PyErr_SetString(PyExc_TypeError, "interner Fehler: Stromfeld muss ein Vielfaches von 32 Byte sein");
        return NULL;
    }
    ctx_init(&cx);
    rc = sl_rng_streams(&cx, &r, (int64_t) (o.len / 32), (sl_rng *) o.buf);
    PyBuffer_Release(&v);
    PyBuffer_Release(&o);
    if (finish(&cx, rc) < 0) return NULL;
    Py_RETURN_NONE;
}

static PyObject *slc_seed31(PyObject *self, PyObject *args)
{
    PyObject *st;
    Py_buffer v;
    sl_rng r;
    int32_t k;
    (void) self;
    if (!PyArg_ParseTuple(args, "O", &st)) return NULL;
    if (get_state(st, &v, &r) < 0) return NULL;
    k = sl_rng_seed31(&r);
    put_state(&v, &r);
    PyBuffer_Release(&v);
    return PyLong_FromLong((long) k);
}

static PyObject *slc_u64(PyObject *self, PyObject *args)
{
    PyObject *st, *out;
    Py_buffer v, o;
    sl_rng r;
    Py_ssize_t i, n;
    uint64_t *p;
    (void) self;
    if (!PyArg_ParseTuple(args, "OO", &st, &out)) return NULL;
    if (get_state(st, &v, &r) < 0) return NULL;
    if (get_buf(out, &o, 1, 8, "QLK", "Ausgabe (uint64)") < 0) { PyBuffer_Release(&v); return NULL; }
    n = NITEMS(o);
    p = (uint64_t *) o.buf;
    for (i = 0; i < n; i++) p[i] = sl_rng_next(&r);
    put_state(&v, &r);
    PyBuffer_Release(&v);
    PyBuffer_Release(&o);
    Py_RETURN_NONE;
}

/* ── Ziehungen ── */

typedef int (*draw2_fn)(sl_ctx *, sl_rng *, int64_t, double, double, double *);
typedef int (*draw1_fn)(sl_ctx *, sl_rng *, int64_t, double, double *);

static PyObject *draw(PyObject *args, draw1_fn f1, draw2_fn f2)
{
    PyObject *st, *out;
    double a, b = 0.0;
    Py_buffer v, o;
    sl_rng r;
    sl_ctx cx;
    int rc;
    if (f2 ? !PyArg_ParseTuple(args, "OOdd", &st, &out, &a, &b) : !PyArg_ParseTuple(args, "OOd", &st, &out, &a))
        return NULL;
    if (get_state(st, &v, &r) < 0) return NULL;
    if (get_buf(out, &o, 1, 8, "d", "Ausgabe (float64)") < 0) { PyBuffer_Release(&v); return NULL; }
    ctx_init(&cx);
    rc = f2 ? f2(&cx, &r, (int64_t) NITEMS(o), a, b, (double *) o.buf)
            : f1(&cx, &r, (int64_t) NITEMS(o), a, (double *) o.buf);
    if (rc == SL_OK) put_state(&v, &r);
    PyBuffer_Release(&v);
    PyBuffer_Release(&o);
    if (finish(&cx, rc) < 0) return NULL;
    Py_RETURN_NONE;
}

static PyObject *slc_runif(PyObject *s, PyObject *a) { (void) s; return draw(a, NULL, sl_runif); }
static PyObject *slc_rnorm(PyObject *s, PyObject *a) { (void) s; return draw(a, NULL, sl_rnorm); }
static PyObject *slc_rgamma(PyObject *s, PyObject *a) { (void) s; return draw(a, NULL, sl_rgamma); }
static PyObject *slc_rexp(PyObject *s, PyObject *a) { (void) s; return draw(a, sl_rexp, NULL); }
static PyObject *slc_rgeom(PyObject *s, PyObject *a) { (void) s; return draw(a, sl_rgeom, NULL); }
static PyObject *slc_rchisq(PyObject *s, PyObject *a) { (void) s; return draw(a, sl_rchisq, NULL); }

static PyObject *slc_sample(PyObject *self, PyObject *args)
{
    PyObject *st, *out, *prob;
    long long n;
    int replace, rc;
    Py_buffer v, o, pb;
    sl_rng r;
    sl_ctx cx;
    const double *pp = NULL;
    (void) self;
    if (!PyArg_ParseTuple(args, "OOLpO", &st, &out, &n, &replace, &prob)) return NULL;
    if (get_state(st, &v, &r) < 0) return NULL;
    if (get_buf(out, &o, 1, 4, "il", "Ausgabe (int32)") < 0) { PyBuffer_Release(&v); return NULL; }
    if (prob != Py_None) {
        if (get_buf(prob, &pb, 0, 8, "d", "prob (float64)") < 0) { PyBuffer_Release(&v); PyBuffer_Release(&o); return NULL; }
        if (NITEMS(pb) != n) {
            PyBuffer_Release(&v); PyBuffer_Release(&o); PyBuffer_Release(&pb);
            PyErr_SetString(PyExc_ValueError, "sample: Länge von prob passt nicht zu n");
            return NULL;
        }
        pp = (const double *) pb.buf;
    }
    ctx_init(&cx);
    rc = sl_sample(&cx, &r, (int64_t) n, (int64_t) NITEMS(o), replace, pp, (int32_t *) o.buf);
    if (rc == SL_OK) put_state(&v, &r);
    PyBuffer_Release(&v);
    PyBuffer_Release(&o);
    if (pp) PyBuffer_Release(&pb);
    if (finish(&cx, rc) < 0) return NULL;
    Py_RETURN_NONE;
}

/* ── Verteilungen: (x, out, Parameter ...) ── */

typedef int (*unary_fn)(sl_ctx *, int64_t, const double *, double *);
typedef int (*norm_fn)(sl_ctx *, int64_t, const double *, double, double, int, double *);
typedef int (*beta_fn)(sl_ctx *, int64_t, const double *, double, double, int, double *);
typedef int (*tdist_fn)(sl_ctx *, int64_t, const double *, double, int, double *);

static int io_bufs(PyObject *x, PyObject *out, Py_buffer *xi, Py_buffer *o)
{
    if (get_buf(x, xi, 0, 8, "d", "x (float64)") < 0) return -1;
    if (get_buf(out, o, 1, 8, "d", "Ausgabe (float64)") < 0) { PyBuffer_Release(xi); return -1; }
    if (NITEMS(*xi) != NITEMS(*o)) {
        PyBuffer_Release(xi); PyBuffer_Release(o);
        PyErr_SetString(PyExc_TypeError, "interner Fehler: Ein- und Ausgabe ungleich lang");
        return -1;
    }
    return 0;
}

static PyObject *unary(PyObject *args, unary_fn f)
{
    PyObject *x, *out;
    Py_buffer xi, o;
    sl_ctx cx;
    int rc;
    if (!PyArg_ParseTuple(args, "OO", &x, &out)) return NULL;
    if (io_bufs(x, out, &xi, &o) < 0) return NULL;
    ctx_init(&cx);
    rc = f(&cx, (int64_t) NITEMS(o), (const double *) xi.buf, (double *) o.buf);
    PyBuffer_Release(&xi);
    PyBuffer_Release(&o);
    if (finish(&cx, rc) < 0) return NULL;
    Py_RETURN_NONE;
}

static PyObject *two_par(PyObject *args, norm_fn f)
{
    PyObject *x, *out;
    double a, b;
    int flag, rc;
    Py_buffer xi, o;
    sl_ctx cx;
    if (!PyArg_ParseTuple(args, "OOddp", &x, &out, &a, &b, &flag)) return NULL;
    if (io_bufs(x, out, &xi, &o) < 0) return NULL;
    ctx_init(&cx);
    rc = f(&cx, (int64_t) NITEMS(o), (const double *) xi.buf, a, b, flag, (double *) o.buf);
    PyBuffer_Release(&xi);
    PyBuffer_Release(&o);
    if (finish(&cx, rc) < 0) return NULL;
    Py_RETURN_NONE;
}

static PyObject *one_par(PyObject *args, tdist_fn f)
{
    PyObject *x, *out;
    double a;
    int flag, rc;
    Py_buffer xi, o;
    sl_ctx cx;
    if (!PyArg_ParseTuple(args, "OOdp", &x, &out, &a, &flag)) return NULL;
    if (io_bufs(x, out, &xi, &o) < 0) return NULL;
    ctx_init(&cx);
    rc = f(&cx, (int64_t) NITEMS(o), (const double *) xi.buf, a, flag, (double *) o.buf);
    PyBuffer_Release(&xi);
    PyBuffer_Release(&o);
    if (finish(&cx, rc) < 0) return NULL;
    Py_RETURN_NONE;
}

static PyObject *slc_pnorm(PyObject *s, PyObject *a) { (void) s; return two_par(a, sl_pnorm); }
static PyObject *slc_qnorm(PyObject *s, PyObject *a) { (void) s; return two_par(a, sl_qnorm); }
static PyObject *slc_dnorm(PyObject *s, PyObject *a) { (void) s; return two_par(a, sl_dnorm); }
static PyObject *slc_pbeta(PyObject *s, PyObject *a) { (void) s; return two_par(a, sl_pbeta); }
static PyObject *slc_pt(PyObject *s, PyObject *a) { (void) s; return one_par(a, sl_pt); }
static PyObject *slc_qt(PyObject *s, PyObject *a) { (void) s; return one_par(a, sl_qt); }
static PyObject *slc_erfc(PyObject *s, PyObject *a) { (void) s; return unary(a, sl_erfc_v); }
static PyObject *slc_lgamma(PyObject *s, PyObject *a) { (void) s; return unary(a, sl_lgamma); }
static PyObject *slc_plogis(PyObject *s, PyObject *a) { (void) s; return unary(a, sl_plogis); }
static PyObject *slc_qlogis(PyObject *s, PyObject *a) { (void) s; return unary(a, sl_qlogis); }

PyMethodDef simlev_ext_slc_methods[] = {
    {"slc_version", slc_version, METH_NOARGS, "Version der C-Bibliothek slc"},
    {"slc_seed", slc_seed, METH_VARARGS, "slc_seed(state, seed): Zustand aus seed (SplitMix64)"},
    {"slc_seed_entropy", slc_seed_entropy, METH_VARARGS, "slc_seed_entropy(state, t_ns, pid, counter)"},
    {"slc_jump", slc_jump, METH_VARARGS, "slc_jump(state): 2^128 Schritte weiter"},
    {"slc_streams", slc_streams, METH_VARARGS, "slc_streams(state, out): out[i] = J^(i+1)(state), je 32 Byte"},
    {"slc_seed31", slc_seed31, METH_VARARGS, "slc_seed31(state) -> naechster Startwert 0 ... 2^31-1"},
    {"slc_u64", slc_u64, METH_VARARGS, "slc_u64(state, out): rohe 64-Bit-Ausgaben"},
    {"slc_runif", slc_runif, METH_VARARGS, "slc_runif(state, out, a, b)"},
    {"slc_rnorm", slc_rnorm, METH_VARARGS, "slc_rnorm(state, out, mu, sd)"},
    {"slc_rgamma", slc_rgamma, METH_VARARGS, "slc_rgamma(state, out, shape, scale)"},
    {"slc_rexp", slc_rexp, METH_VARARGS, "slc_rexp(state, out, rate)"},
    {"slc_rgeom", slc_rgeom, METH_VARARGS, "slc_rgeom(state, out, p)"},
    {"slc_rchisq", slc_rchisq, METH_VARARGS, "slc_rchisq(state, out, df)"},
    {"slc_sample", slc_sample, METH_VARARGS, "slc_sample(state, out_int32, n, replace, prob_or_None)"},
    {"slc_pnorm", slc_pnorm, METH_VARARGS, "slc_pnorm(x, out, mu, sd, lower)"},
    {"slc_qnorm", slc_qnorm, METH_VARARGS, "slc_qnorm(p, out, mu, sd, lower)"},
    {"slc_dnorm", slc_dnorm, METH_VARARGS, "slc_dnorm(x, out, mu, sd, log)"},
    {"slc_pbeta", slc_pbeta, METH_VARARGS, "slc_pbeta(x, out, a, b, lower)"},
    {"slc_pt", slc_pt, METH_VARARGS, "slc_pt(t, out, df, lower)"},
    {"slc_qt", slc_qt, METH_VARARGS, "slc_qt(p, out, df, lower)"},
    {"slc_erfc", slc_erfc, METH_VARARGS, "slc_erfc(x, out)"},
    {"slc_lgamma", slc_lgamma, METH_VARARGS, "slc_lgamma(x, out)"},
    {"slc_plogis", slc_plogis, METH_VARARGS, "slc_plogis(x, out)"},
    {"slc_qlogis", slc_qlogis, METH_VARARGS, "slc_qlogis(p, out)"},
    {NULL, NULL, 0, NULL}
};

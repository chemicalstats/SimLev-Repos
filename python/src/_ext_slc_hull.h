/* python/src/_ext_slc_hull.h – gemeinsame Hilfen der slc-Hüllen _ext_slc*.cpp (seit 1.6.3; bis 1.6.2 je Datei
 * eine Kopie): Abbruchhaken und Abschluss eines slc-Aufrufs (Warnungen, Fehler), Puffer mit Typ- und
 * Längenprüfung. Innerhalb von extern "C" { ... } einbinden; static inline, damit Dateien ohne einzelne Hilfen
 * keine Warnung bekommen. Meldungen wortgleich wie bisher. */
#ifndef SIMLEV_EXT_SLC_HULL_H
#define SIMLEV_EXT_SLC_HULL_H

static inline int py_interrupted(void *h) { (void) h; return PyErr_CheckSignals() < 0; }

/* Abbruchhaken für Kerne, die ohne GIL laufen (seit 1.6.5, CR1-Y6-1, Entscheidung 188): nimmt die GIL kurz; der Kern
 * ruft ihn nur aus dem aufrufenden Thread (Python behandelt Signale nur im Hauptthread). Die Ausnahme
 * (KeyboardInterrupt) bleibt gesetzt und wird nach Py_END_ALLOW_THREADS gemeldet. */
static inline int py_interrupted_nogil(void *h)
{
    int r;
    PyGILState_STATE g;
    (void) h;
    g = PyGILState_Ensure();
    r = PyErr_CheckSignals() < 0;
    PyGILState_Release(g);
    return r;
}

static inline void ctx_init(sl_ctx *cx)
{
    sl_ctx_init(cx);
    cx->interrupted = py_interrupted;
}

/* Warnungen ausgeben, Fehler setzen; 0 = ok, -1 = Ausnahme gesetzt */
static inline int finish(sl_ctx *cx, int st)
{
    int i;
    for (i = 0; i < cx->n_warn; i++)
        if (PyErr_WarnEx(PyExc_UserWarning, cx->warn[i], 1) < 0) return -1;
    if (st == SL_OK) return 0;
    if (st == SL_EINTR && PyErr_Occurred()) return -1;
    PyErr_SetString(PyExc_ValueError, cx->msg);
    return -1;
}

/* Puffer holen: itemsize und Formatzeichen pruefen (fmts = erlaubte letzte Zeichen); len >= 0: genau so viele
 * Elemente; opt: o = None erlaubt (leerer Puffer) */
static inline int hull_buf(PyObject *o, Py_buffer *v, int writable, Py_ssize_t itemsize, const char *fmts,
                           Py_ssize_t len, const char *what, int opt)
{
    if (opt && o == Py_None) { memset(v, 0, sizeof *v); return 0; }
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

static inline void rel(Py_buffer *v) { if (v->obj) PyBuffer_Release(v); }

#endif

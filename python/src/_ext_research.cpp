/*
 * python/src/_ext_research.cpp -- Python-Huellen der Kerne aus research_core_impl.h
 *
 * Etappe 7.3a. Gemeinsamer Kern mit R (r/src/research_core_impl.h, Kopie hier);
 * aufgerufen aus simlev._optimize_core, _dependence_core, _signals_core und
 * _bootstrap_core, die vorher wie der reine Python-Kern umwandeln. Matrizen
 * kommen spaltenweise als flache double-Puffer mit Zeilen- und Spaltenzahl;
 * Ergebnisse fester Laenge schreibt der Kern in vom Aufrufer bereitgestellte
 * Puffer (out), Ergebnisse veraenderlicher Laenge kommen als bytearray zurueck.
 *
 *   proj_box_simplex(v, lo, hi, out)
 *   qp_box_simplex(Q, nr, nc, cvec, lo, hi, w0, L, maxit, tol, out)
 *   min_cvar_core(R, T, N, alpha, lo, hi, w0, zeta0, scales, maxit, out)
 *   min_cdar_core(R, T, N, alpha, lo, hi, iters, out)
 *   quantile_reg_core(y, X, n, p, tau, beta0, sc, tol, maxit) -> (beta | None, optimal)
 *   hmm_forward_backward(B, T, K, A, anr, p0, al, be, ga, xi, cs)
 *   garch_filter(ep, om, al, be, ga, v0, s2)
 *   roll_mean_core(x, n, out)
 *   kendall_tau_core(x, y) -> float
 *   roll_cov_core(x, y, n, out)
 *
 * Die Huellen pruefen die Laengen so, dass der Kern nur innerhalb der Puffer liest
 * und schreibt (die R-Kerne setzen dieselben Laengen stillschweigend voraus); die
 * aufrufenden Python-Funktionen nehmen bei anderen Eingaben den reinen Python-Kern.
 */
#include "_ext_common.h"
#include "research_core_impl.h"

namespace {

bool need_len(const ext::Buf& b, Py_ssize_t len, const char* fn, const char* name) {
    if (b.n < len) {
        PyErr_Format(PyExc_ValueError, "%s: '%s' ist zu kurz (%zd statt mindestens %zd).", fn, name, b.n, len);
        return false;
    }
    return true;
}

bool mat_dims(const ext::Buf& b, int nr, int nc, const char* fn, const char* name) {
    if (nr < 0 || nc < 0 || (Py_ssize_t) nr * nc != b.n) {
        PyErr_Format(PyExc_ValueError, "%s: '%s' passt nicht zu %d x %d.", fn, name, nr, nc);
        return false;
    }
    return true;
}


PyObject* r_proj(PyObject*, PyObject* args) {
    PyObject *ov, *olo, *ohi, *oout;
    const char* fn = "proj_box_simplex";
    if (!PyArg_ParseTuple(args, "OOOO:proj_box_simplex", &ov, &olo, &ohi, &oout)) return nullptr;
    ext::Buf v, lo, hi, out;
    if (!ext::get(ov, v, 'd', false, fn, "v")) return nullptr;
    const Py_ssize_t n = v.n;
    if (!ext::get(olo, lo, 'd', false, fn, "lo", n) || !ext::get(ohi, hi, 'd', false, fn, "hi", n) ||
        !ext::get(oout, out, 'd', true, fn, "out", n)) return nullptr;
    if (!ext::run([&] { simlev::proj_box_simplex(v.d(), lo.d(), hi.d(), (int) n, out.d()); })) return nullptr;
    Py_RETURN_NONE;
}

PyObject* r_qp(PyObject*, PyObject* args) {
    PyObject *oQ, *oc, *olo, *ohi, *ow0, *oout;
    int nr, nc, maxit;
    double L, tol;
    const char* fn = "qp_box_simplex";
    if (!PyArg_ParseTuple(args, "OiiOOOOdidO:qp_box_simplex", &oQ, &nr, &nc, &oc, &olo, &ohi, &ow0, &L,
                          &maxit, &tol, &oout)) return nullptr;
    ext::Buf Q, c, lo, hi, w0, out;
    if (!ext::get(oQ, Q, 'd', false, fn, "Q") || !mat_dims(Q, nr, nc, fn, "Q") ||
        !ext::get(oc, c, 'd', false, fn, "cvec") || !ext::get(olo, lo, 'd', false, fn, "lo") ||
        !ext::get(ohi, hi, 'd', false, fn, "hi") || !ext::get(ow0, w0, 'd', false, fn, "w0") ||
        !ext::get(oout, out, 'd', true, fn, "out", nc)) return nullptr;
    if (nr < nc) {
        PyErr_Format(PyExc_ValueError, "%s: 'Q' braucht mindestens so viele Zeilen wie Spalten.", fn);
        return nullptr;
    }
    if (!need_len(c, nc, fn, "cvec") || !need_len(lo, nc, fn, "lo") || !need_len(hi, nc, fn, "hi") ||
        !need_len(w0, nc, fn, "w0")) return nullptr;
    if (!ext::run([&] {
            ext::Vec w = simlev::qp_box_simplex(ext::mat(Q, nr, nc), ext::vec(c), ext::vec(lo), ext::vec(hi),
                                                ext::vec(w0), L, maxit, tol);
            ext::put(out, w.ptr, w.len);
        })) return nullptr;
    Py_RETURN_NONE;
}

PyObject* r_cvar(PyObject*, PyObject* args) {
    PyObject *oR, *olo, *ohi, *ow0, *osc, *oout;
    int T, N, maxit;
    double alpha, zeta0;
    const char* fn = "min_cvar_core";
    if (!PyArg_ParseTuple(args, "OiidOOOdOiO:min_cvar_core", &oR, &T, &N, &alpha, &olo, &ohi, &ow0, &zeta0,
                          &osc, &maxit, &oout)) return nullptr;
    ext::Buf R, lo, hi, w0, sc, out;
    if (!ext::get(oR, R, 'd', false, fn, "R") || !mat_dims(R, T, N, fn, "R") ||
        !ext::get(olo, lo, 'd', false, fn, "lo") || !ext::get(ohi, hi, 'd', false, fn, "hi") ||
        !ext::get(ow0, w0, 'd', false, fn, "w0") || !ext::get(osc, sc, 'd', false, fn, "scales") ||
        !ext::get(oout, out, 'd', true, fn, "out", N)) return nullptr;
    if (!need_len(lo, N, fn, "lo") || !need_len(hi, N, fn, "hi") || !need_len(w0, N, fn, "w0")) return nullptr;
    if (!ext::run([&] {
            ext::Vec x = simlev::min_cvar_core(ext::mat(R, T, N), alpha, ext::vec(lo), ext::vec(hi), ext::vec(w0),
                                               zeta0, ext::vec(sc), maxit);
            ext::put(out, x.ptr, x.len);
        })) return nullptr;
    Py_RETURN_NONE;
}

PyObject* r_cdar(PyObject*, PyObject* args) {
    PyObject *oR, *olo, *ohi, *oout;
    int T, N, iters;
    double alpha;
    const char* fn = "min_cdar_core";
    if (!PyArg_ParseTuple(args, "OiidOOiO:min_cdar_core", &oR, &T, &N, &alpha, &olo, &ohi, &iters, &oout))
        return nullptr;
    ext::Buf R, lo, hi, out;
    if (!ext::get(oR, R, 'd', false, fn, "R") || !mat_dims(R, T, N, fn, "R") ||
        !ext::get(olo, lo, 'd', false, fn, "lo") || !ext::get(ohi, hi, 'd', false, fn, "hi") ||
        !ext::get(oout, out, 'd', true, fn, "out", N)) return nullptr;
    if (!need_len(lo, N, fn, "lo") || !need_len(hi, N, fn, "hi")) return nullptr;
    if (!ext::run([&] {
            ext::Vec best = simlev::min_cdar_core(ext::mat(R, T, N), alpha, ext::vec(lo), ext::vec(hi), iters);
            ext::put(out, best.ptr, best.len);
        })) return nullptr;
    Py_RETURN_NONE;
}

PyObject* r_qreg(PyObject*, PyObject* args) {
    PyObject *oy, *oX, *ob0;
    int n, p, maxit;
    double tau, sc, tol;
    const char* fn = "quantile_reg_core";
    if (!PyArg_ParseTuple(args, "OOiidOddi:quantile_reg_core", &oy, &oX, &n, &p, &tau, &ob0, &sc, &tol, &maxit))
        return nullptr;
    ext::Buf y, X, b0;
    if (!ext::get(oy, y, 'd', false, fn, "y") || !ext::get(oX, X, 'd', false, fn, "X") ||
        !mat_dims(X, n, p, fn, "X") || !ext::get(ob0, b0, 'd', false, fn, "beta0")) return nullptr;
    if (!need_len(y, n, fn, "y") || !need_len(b0, p, fn, "beta0")) return nullptr;
    ext::Vec beta = {nullptr, nullptr, 0};
    if (!ext::run([&] {
            beta = simlev::quantile_reg_core(ext::vec(y), ext::mat(X, n, p), tau, ext::vec(b0), sc, tol, maxit);
        })) return nullptr;
    const bool has_flag = ext::alloc().has_flag, flag = ext::alloc().flag;
    if (!has_flag) return Py_BuildValue("(OO)", Py_None, Py_False);      // p = 0: leeres Ergebnis ohne Attribut
    PyObject* ba = PyByteArray_FromStringAndSize(reinterpret_cast<const char*>(beta.ptr),
                                                 beta.len * (Py_ssize_t) sizeof(double));
    ext::alloc().reset();
    if (!ba) return nullptr;
    return Py_BuildValue("(NO)", ba, flag ? Py_True : Py_False);
}

PyObject* r_hmm(PyObject*, PyObject* args) {
    PyObject *oB, *oA, *op0, *oal, *obe, *oga, *oxi, *ocs;
    int T, K, anr;
    const char* fn = "hmm_forward_backward";
    if (!PyArg_ParseTuple(args, "OiiOiOOOOOO:hmm_forward_backward", &oB, &T, &K, &oA, &anr, &op0, &oal, &obe,
                          &oga, &oxi, &ocs)) return nullptr;
    ext::Buf B, A, p0, al, be, ga, xi, cs;   // be: nur fuer die Laengenpruefung (kein Ergebnis in R)
    if (!ext::get(oB, B, 'd', false, fn, "B") || !mat_dims(B, T, K, fn, "B") ||
        !ext::get(oA, A, 'd', false, fn, "A") || !ext::get(op0, p0, 'd', false, fn, "p0") ||
        !ext::get(oal, al, 'd', true, fn, "al", (Py_ssize_t) T * K) ||
        !ext::get(obe, be, 'd', true, fn, "be", (Py_ssize_t) T * K) ||
        !ext::get(oga, ga, 'd', true, fn, "ga", (Py_ssize_t) T * K) ||
        !ext::get(oxi, xi, 'd', true, fn, "xi", (Py_ssize_t) K * K) ||
        !ext::get(ocs, cs, 'd', true, fn, "cs", T)) return nullptr;
    if (T < 1 || anr < K || A.n < (Py_ssize_t) anr * K || !need_len(p0, K, fn, "p0")) {
        if (!PyErr_Occurred()) PyErr_Format(PyExc_ValueError, "%s: ungueltige Abmessungen.", fn);
        return nullptr;
    }
    if (!ext::run([&] {
            auto r = simlev::hmm_forward_backward(ext::mat(B, T, K), ext::mat(A, anr, K), ext::vec(p0));
            ext::put(al, std::get<1>(r).ptr, (Py_ssize_t) T * K);
            ext::put(ga, std::get<3>(r).ptr, (Py_ssize_t) T * K);
            ext::put(xi, std::get<5>(r).ptr, (Py_ssize_t) K * K);
            ext::put(cs, std::get<7>(r).ptr, T);
        })) return nullptr;
    Py_RETURN_NONE;
}

PyObject* r_garch(PyObject*, PyObject* args) {
    PyObject *oep, *os2;
    double om, al, be, ga, v0;
    const char* fn = "garch_filter";
    if (!PyArg_ParseTuple(args, "OdddddO:garch_filter", &oep, &om, &al, &be, &ga, &v0, &os2)) return nullptr;
    ext::Buf ep, s2;
    if (!ext::get(oep, ep, 'd', false, fn, "ep") || !ext::get(os2, s2, 'd', true, fn, "s2", ep.n)) return nullptr;
    if (!ext::run([&] {
            ext::Vec r = simlev::garch_filter(ext::vec(ep), om, al, be, ga, v0);
            ext::put(s2, r.ptr, r.len);
        })) return nullptr;
    Py_RETURN_NONE;
}

PyObject* r_rmean(PyObject*, PyObject* args) {
    PyObject *ox, *oout;
    int n;
    const char* fn = "roll_mean_core";
    if (!PyArg_ParseTuple(args, "OiO:roll_mean_core", &ox, &n, &oout)) return nullptr;
    ext::Buf x, out;
    if (!ext::get(ox, x, 'd', false, fn, "x") || !ext::get(oout, out, 'd', true, fn, "out", x.n)) return nullptr;
    if (!ext::run([&] {
            ext::Vec r = simlev::roll_mean_core(ext::vec(x), n);
            ext::put(out, r.ptr, r.len);
        })) return nullptr;
    Py_RETURN_NONE;
}

PyObject* r_kendall(PyObject*, PyObject* args) {
    PyObject *ox, *oy;
    const char* fn = "kendall_tau_core";
    if (!PyArg_ParseTuple(args, "OO:kendall_tau_core", &ox, &oy)) return nullptr;
    ext::Buf x, y;
    if (!ext::get(ox, x, 'd', false, fn, "x") || !ext::get(oy, y, 'd', false, fn, "y", x.n)) return nullptr;
    double r = 0.0;
    if (!ext::run([&] { r = simlev::kendall_tau_core(ext::vec(x), ext::vec(y)); })) return nullptr;
    return PyFloat_FromDouble(r);
}

PyObject* r_rcov(PyObject*, PyObject* args) {
    PyObject *ox, *oy, *oout;
    int n;
    const char* fn = "roll_cov_core";
    if (!PyArg_ParseTuple(args, "OOiO:roll_cov_core", &ox, &oy, &n, &oout)) return nullptr;
    ext::Buf x, y, out;
    if (!ext::get(ox, x, 'd', false, fn, "x") || !ext::get(oy, y, 'd', false, fn, "y") ||
        !ext::get(oout, out, 'd', true, fn, "out", x.n)) return nullptr;
    if (!ext::run([&] {
            ext::Vec r = simlev::roll_cov_core(ext::vec(x), ext::vec(y), n);
            ext::put(out, r.ptr, r.len);
        })) return nullptr;
    Py_RETURN_NONE;
}

}  // namespace

PyMethodDef simlev_ext_research_methods[] = {
    {"proj_box_simplex", r_proj, METH_VARARGS, "proj_box_simplex(v, lo, hi, out)"},
    {"qp_box_simplex", r_qp, METH_VARARGS, "qp_box_simplex(Q, nr, nc, cvec, lo, hi, w0, L, maxit, tol, out)"},
    {"min_cvar_core", r_cvar, METH_VARARGS, "min_cvar_core(R, T, N, alpha, lo, hi, w0, zeta0, scales, maxit, out)"},
    {"min_cdar_core", r_cdar, METH_VARARGS, "min_cdar_core(R, T, N, alpha, lo, hi, iters, out)"},
    {"quantile_reg_core", r_qreg, METH_VARARGS,
     "quantile_reg_core(y, X, n, p, tau, beta0, sc, tol, maxit) -> (beta | None, optimal)"},
    {"hmm_forward_backward", r_hmm, METH_VARARGS, "hmm_forward_backward(B, T, K, A, anr, p0, al, be, ga, xi, cs)"},
    {"garch_filter", r_garch, METH_VARARGS, "garch_filter(ep, om, al, be, ga, v0, s2)"},
    {"roll_mean_core", r_rmean, METH_VARARGS, "roll_mean_core(x, n, out)"},
    {"kendall_tau_core", r_kendall, METH_VARARGS, "kendall_tau_core(x, y) -> float"},
    {"roll_cov_core", r_rcov, METH_VARARGS, "roll_cov_core(x, y, n, out)"},
    {nullptr, nullptr, 0, nullptr}
};

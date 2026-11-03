/*
 * python/src/_ext_research.cpp -- Python-Huellen der Kerne aus research_core_impl.h
 *
 * Gemeinsamer Kern mit R und Julia (core/research_core_impl.h, Kopie in src/core/);
 * aufgerufen aus simlev._optimize_core, _dependence_core und _signals_core, die vorher
 * wie R umwandeln. Matrizen
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
 *   hmm_em(X, Tn, d, k, mu, S, A, p0, n_iter, tol, ridge, filt, smooth, lB) -> (status, ll, iter)  (seit 1.5.0;
 *     mu, S, A an Ort und Stelle; Matrizen spaltenweise)
 *   goal_dp(R, S, K, grid, cf, goal, wmin, wmax, sv, tie, static, policy, value) -> (collapsed, p_dp)  (seit 1.5.0;
 *     policy int32 horizon x ng, value ng x (horizon + 1))
 *   pbo_cscv(B, T, combos, half, metric, S, N, lam, isb, oosb, oosm)  (seit 1.5.0; B 5 x S x N, T 5 x N, combos
 *     int32 S/2 x C 1-basiert)
 *   roll_mean_core(x, n, out)
 *   kendall_tau_core(x, y) -> float
 *   roll_cov_core(x, y, n, out)
 *
 * Die Huellen pruefen die Laengen so, dass der Kern nur innerhalb der Puffer liest
 * und schreibt (die R-Kerne setzen dieselben Laengen stillschweigend voraus); andere
 * Eingaben weisen die aufrufenden Python-Funktionen vorher ab (die reinen Python-Kerne
 * als Rueckfall sind seit 1.0.0 entfallen).
 */
#include "_ext_common.h"
#include "core/research_core_impl.h"

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

PyObject* r_hmm_em(PyObject*, PyObject* args) {
    PyObject *oX, *omu, *oS, *oA, *op0, *orid, *of, *osm, *olb;
    int Tn, d, k, n_iter;
    double tol;
    const char* fn = "hmm_em";
    if (!PyArg_ParseTuple(args, "OiiiOOOOidOOOO:hmm_em", &oX, &Tn, &d, &k, &omu, &oS, &oA, &op0, &n_iter, &tol, &orid,
                          &of, &osm, &olb)) return nullptr;
    if (Tn < 1 || d < 1 || k < 1) {
        PyErr_Format(PyExc_ValueError, "%s: ungueltige Abmessungen.", fn);
        return nullptr;
    }
    ext::Buf X, mu, S, A, p0, rid, f, sm, lb;
    const Py_ssize_t TK = (Py_ssize_t) Tn * k;
    if (!ext::get(oX, X, 'd', false, fn, "X", (Py_ssize_t) Tn * d) ||
        !ext::get(omu, mu, 'd', true, fn, "mu", (Py_ssize_t) k * d) ||
        !ext::get(oS, S, 'd', true, fn, "S", (Py_ssize_t) d * d * k) ||
        !ext::get(oA, A, 'd', true, fn, "A", (Py_ssize_t) k * k) || !ext::get(op0, p0, 'd', true, fn, "p0", k) ||
        !ext::get(orid, rid, 'd', false, fn, "ridge", (Py_ssize_t) d * d) ||
        !ext::get(of, f, 'd', true, fn, "filtered", TK) || !ext::get(osm, sm, 'd', true, fn, "smoothed", TK) ||
        !ext::get(olb, lb, 'd', true, fn, "lB", TK)) return nullptr;
    int st = 0, iter = 0;
    double ll = 0.0;
    if (!ext::run([&] {
            st = simlev::hmm_em(Tn, d, k, X.d(), mu.d(), S.d(), A.d(), p0.d(), n_iter, tol, rid.d(), &ll, f.d(), sm.d(),
                                lb.d(), &iter);
        }, false)) return nullptr;                       // mit GIL: Abbruchpruefung je Iteration
    return Py_BuildValue("(idi)", st, ll, iter);
}

PyObject* r_goal_dp(PyObject*, PyObject* args) {
    PyObject *oR, *og, *ocf, *otie, *ost, *opol, *ov;
    int S, K;
    double goal, wmin, wmax, sv;
    const char* fn = "goal_dp";
    if (!PyArg_ParseTuple(args, "OiiOOddddOOOO:goal_dp", &oR, &S, &K, &og, &ocf, &goal, &wmin, &wmax, &sv, &otie, &ost,
                          &opol, &ov)) return nullptr;
    ext::Buf R, g, cf, tie, st, pol, v;
    if (S < 1 || K < 1 || !ext::get(oR, R, 'd', false, fn, "R", (Py_ssize_t) S * K) ||
        !ext::get(og, g, 'd', false, fn, "grid") || !ext::get(ocf, cf, 'd', false, fn, "cf") ||
        !ext::get(otie, tie, 'd', false, fn, "tie", K) || !ext::get(ost, st, 'd', true, fn, "static", K)) {
        if (!PyErr_Occurred()) PyErr_Format(PyExc_ValueError, "%s: ungueltige Abmessungen.", fn);
        return nullptr;
    }
    const int ng = (int) g.n, h = (int) cf.n;
    if (ng < 2 || h < 1) {
        PyErr_Format(PyExc_ValueError, "%s: ungueltige Abmessungen.", fn);
        return nullptr;
    }
    if (!ext::get(opol, pol, 'i', true, fn, "policy", (Py_ssize_t) h * ng) ||
        !ext::get(ov, v, 'd', true, fn, "value", (Py_ssize_t) ng * (h + 1))) return nullptr;
    int64_t nc = 0;
    double p_dp = 0.0;
    if (!ext::run([&] {
            nc = simlev::goal_dp(S, K, R.d(), ng, g.d(), h, cf.d(), goal, wmin, wmax, sv, tie.d(), st.d(), pol.i(), v.d(),
                                 &p_dp);
        }, false)) return nullptr;                       // mit GIL: Abbruchpruefung je Periode
    if (nc < 0) {
        PyErr_Format(PyExc_ValueError, "%s: Fehler der Normalverteilung", fn);
        return nullptr;
    }
    return Py_BuildValue("(Ld)", (long long) nc, p_dp);
}

PyObject* r_pbo_cscv(PyObject*, PyObject* args) {
    PyObject *oB, *oT, *oc, *ol, *oi, *oo, *om;
    double half;
    int metric, S, N;
    const char* fn = "pbo_cscv";
    if (!PyArg_ParseTuple(args, "OOOdiiiOOOO:pbo_cscv", &oB, &oT, &oc, &half, &metric, &S, &N, &ol, &oi, &oo, &om))
        return nullptr;
    if (S < 2 || S % 2 || N < 1) {
        PyErr_Format(PyExc_ValueError, "%s: ungueltige Abmessungen.", fn);
        return nullptr;
    }
    ext::Buf B, T, cb, lam, isb, oosb, oosm;
    if (!ext::get(oB, B, 'd', false, fn, "B", (Py_ssize_t) 5 * S * N) || !ext::get(oT, T, 'd', false, fn, "T", (Py_ssize_t) 5 * N) ||
        !ext::get(oc, cb, 'i', false, fn, "combos")) return nullptr;
    if (cb.n % (S / 2)) {
        PyErr_Format(PyExc_ValueError, "%s: ungueltige Abmessungen.", fn);
        return nullptr;
    }
    const int C = (int) (cb.n / (S / 2));
    for (Py_ssize_t i = 0; i < cb.n; i++)
        if (cb.i()[i] < 1 || cb.i()[i] > S) {
            PyErr_Format(PyExc_ValueError, "%s: Block ausserhalb 1..%d", fn, S);
            return nullptr;
        }
    if (!ext::get(ol, lam, 'd', true, fn, "lam", C) || !ext::get(oi, isb, 'd', true, fn, "isb", C) ||
        !ext::get(oo, oosb, 'd', true, fn, "oosb", C) || !ext::get(om, oosm, 'd', true, fn, "oosm", C)) return nullptr;
    if (!ext::run([&] {
            simlev::pbo_cscv(S, N, C, B.d(), T.d(), cb.i(), half, metric, lam.d(), isb.d(), oosb.d(), oosm.d());
        }, false)) return nullptr;                       // mit GIL: Abbruchpruefung je Block
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
    {"goal_dp", r_goal_dp, METH_VARARGS,
     "goal_dp(R, S, K, grid, cf, goal, wmin, wmax, sv, tie, static, policy, value) -> (collapsed, p_dp)"},
    {"pbo_cscv", r_pbo_cscv, METH_VARARGS, "pbo_cscv(B, T, combos, half, metric, S, N, lam, isb, oosb, oosm)"},
    {"hmm_em", r_hmm_em, METH_VARARGS,
     "hmm_em(X, Tn, d, k, mu, S, A, p0, n_iter, tol, ridge, filtered, smoothed, lB) -> (status, ll, iter)"},
    {"roll_mean_core", r_rmean, METH_VARARGS, "roll_mean_core(x, n, out)"},
    {"kendall_tau_core", r_kendall, METH_VARARGS, "kendall_tau_core(x, y) -> float"},
    {"roll_cov_core", r_rcov, METH_VARARGS, "roll_cov_core(x, y, n, out)"},
    {nullptr, nullptr, 0, nullptr}
};

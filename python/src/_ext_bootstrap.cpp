/*
 * python/src/_ext_bootstrap.cpp -- Python-Huellen der Bootstrap-Kerne in simlev._ext
 *
 * Etappe 7.3b. Gemeinsame Kerne mit R (r/src/bootstrap_core_impl.h, Kopie hier);
 * aufgerufen aus simlev._bootstrap_core, das vorher wie der reine Python-Kern prueft
 * und umwandelt und nur Eingaben im gueltigen Bereich hierher gibt (sonst rechnet der
 * reine Python-Kern).
 *
 * Kerne mit Zufallszahlen: die ersten drei Argumente sind der Zustand von
 * simlev._r.rng (ist, mt, pst; siehe ext::Rng in _ext_common.h). Die Kerne ziehen ueber
 * die C-Nachbildung von R's RNG (_rng_r.c) mit gehaltener GIL; danach steht der
 * Zustand wieder in den Puffern, auch nach einem Fehler.
 *
 *   boot_idx_iid(ist, mt, pst, n_src, n_out, out)
 *   boot_idx_block(ist, mt, pst, n_src, n_out, block_length, circular, out)
 *   boot_idx_stationary(ist, mt, pst, n_src, n_out, L, out)
 *   boot_idx_regime(ist, mt, pst, regimes, trans, K, n_out, out)
 *   boot_idx_tails(ist, mt, pst, n_out, p_l, p_r, bulk_idx, left_idx, right_idx, out)
 *   boot_wild(ist, mt, pst, returns, n, k, type, out)
 *   boot_reset(ist, mt, pst, returns, n, k, p_break, out)
 *   boot_evt(ist, mt, pst, returns, n, k, base, n_out, p_l, thresh_l, scale_l, shape_l,
 *            pool_l, p_r, thresh_r, scale_r, shape_r, pool_r, bulk_idx, out_ret, out_idx)
 *   boot_garch(ist, mt, pst, n_out, base, k, mu, omega, alpha, beta, gamma, s2_init,
 *              z_base, valid, cross_cols, cmu, com, cal, cbe, cratio, cs2, z_cross, zc_nr,
 *              out_ret, out_idx)
 *   boot_ms_garch(ist, mt, pst, n_out, base, k, K, mu, omega, alpha, beta, gamma, phi,
 *                 lambda, trans, delta, unc_var, stat_prob, pools, z_base, cross_cols, cmu,
 *                 com, cal, cbe, cratio, cs2, z_cross, zc_nr, out_ret, out_idx, out_reg)
 * Ohne Zufallszahlen (GIL frei waehrend der Rechnung):
 *   rolling_vol(x, window, out)
 *   assign_regimes(vol, thresh, out)
 *   estimate_trans_mat(regimes, K, alpha, out)
 *
 * Felder: double bzw. int32, zusammenhaengend; Matrizen spaltenweise (n x k als flaches
 * Feld der Laenge n * k); Ergebnisse in die beschreibbaren Puffer out*; trans und delta
 * K x K, z_cross zc_nr x Anzahl der Nebenreihen; pools eine Folge von int32-Feldern.
 */
#include "_ext_common.h"
#include "bootstrap_core_impl.h"

#include <memory>

namespace {

typedef std::vector<std::unique_ptr<ext::Buf>> Bufs;

/* Ergebnisse der Kerne in die Ausgabepuffer */
void out_ivec(const ext::Buf& out, const ext::IVec& v) { ext::put_int(out, v.ptr, v.len); }
void out_mat(const ext::Buf& out, const ext::Mat& m) { ext::put(out, m.ptr, (Py_ssize_t) m.nr * m.nc); }

/* Kern mit Zufallszahlen: Zustand binden, Kern mit GIL, Zustand zurueckschreiben */
template <class F> bool with_rng(ext::Rng& rng, F f) {
    const bool ok = ext::run(f, false);
    return rng.close(ok);
}

PyObject* b_iid(PyObject*, PyObject* args) {
    PyObject *oi, *om, *op, *oout;
    int n_src, n_out;
    const char* fn = "boot_idx_iid";
    EXT_FAIL_IF(!PyArg_ParseTuple(args, "OOOiiO:boot_idx_iid", &oi, &om, &op, &n_src, &n_out, &oout)) return nullptr;
    ext::Buf out;
    ext::Rng rng;
    EXT_FAIL_IF(n_out < 0 || !ext::get(oout, out, 'i', true, fn, "out", n_out) || !rng.open(oi, om, op, fn)) return nullptr;
    EXT_FAIL_IF(!with_rng(rng, [&] { out_ivec(out, simlev::boot_idx_iid(n_src, n_out)); })) return nullptr;
    Py_RETURN_NONE;
}

PyObject* b_block(PyObject*, PyObject* args) {
    PyObject *oi, *om, *op, *oout;
    int n_src, n_out, bl, circ;
    const char* fn = "boot_idx_block";
    EXT_FAIL_IF(!PyArg_ParseTuple(args, "OOOiiipO:boot_idx_block", &oi, &om, &op, &n_src, &n_out, &bl, &circ, &oout))
        return nullptr;
    ext::Buf out;
    ext::Rng rng;
    EXT_FAIL_IF(n_out < 0 || !ext::get(oout, out, 'i', true, fn, "out", n_out) || !rng.open(oi, om, op, fn)) return nullptr;
    EXT_FAIL_IF(!with_rng(rng, [&] { out_ivec(out, simlev::boot_idx_block(n_src, n_out, bl, circ != 0)); })) return nullptr;
    Py_RETURN_NONE;
}

PyObject* b_stationary(PyObject*, PyObject* args) {
    PyObject *oi, *om, *op, *oout;
    int n_src, n_out;
    double L;
    const char* fn = "boot_idx_stationary";
    EXT_FAIL_IF(!PyArg_ParseTuple(args, "OOOiidO:boot_idx_stationary", &oi, &om, &op, &n_src, &n_out, &L, &oout))
        return nullptr;
    ext::Buf out;
    ext::Rng rng;
    EXT_FAIL_IF(n_out < 0 || !ext::get(oout, out, 'i', true, fn, "out", n_out) || !rng.open(oi, om, op, fn)) return nullptr;
    EXT_FAIL_IF(!with_rng(rng, [&] { out_ivec(out, simlev::boot_idx_stationary(n_src, n_out, L)); })) return nullptr;
    Py_RETURN_NONE;
}

PyObject* b_regime(PyObject*, PyObject* args) {
    PyObject *oi, *om, *op, *oreg, *otr, *oout;
    int K, n_out;
    const char* fn = "boot_idx_regime";
    EXT_FAIL_IF(!PyArg_ParseTuple(args, "OOOOOiiO:boot_idx_regime", &oi, &om, &op, &oreg, &otr, &K, &n_out, &oout))
        return nullptr;
    ext::Buf reg, tr, out;
    ext::Rng rng;
    EXT_FAIL_IF(K < 1 || n_out < 0 || !ext::get(oreg, reg, 'i', false, fn, "regimes") ||
        !ext::get(otr, tr, 'd', false, fn, "trans", (Py_ssize_t) K * K) ||
        !ext::get(oout, out, 'i', true, fn, "out", n_out) || !rng.open(oi, om, op, fn)) return nullptr;
    EXT_FAIL_IF(!with_rng(rng, [&] { out_ivec(out, simlev::boot_idx_regime(ext::ivec(reg), ext::mat(tr, K, K), n_out)); }))
        return nullptr;
    Py_RETURN_NONE;
}

PyObject* b_tails(PyObject*, PyObject* args) {
    PyObject *oi, *om, *op, *ob, *ol, *orr, *oout;
    int n_out;
    double p_l, p_r;
    const char* fn = "boot_idx_tails";
    EXT_FAIL_IF(!PyArg_ParseTuple(args, "OOOiddOOOO:boot_idx_tails", &oi, &om, &op, &n_out, &p_l, &p_r, &ob, &ol, &orr, &oout))
        return nullptr;
    ext::Buf b, l, r, out;
    ext::Rng rng;
    EXT_FAIL_IF(n_out < 0 || !ext::get(ob, b, 'i', false, fn, "bulk_idx") || !ext::get(ol, l, 'i', false, fn, "left_idx") ||
        !ext::get(orr, r, 'i', false, fn, "right_idx") || !ext::get(oout, out, 'i', true, fn, "out", n_out) ||
        !rng.open(oi, om, op, fn)) return nullptr;
    EXT_FAIL_IF(!with_rng(rng, [&] {
            out_ivec(out, simlev::boot_idx_tails(n_out, p_l, p_r, ext::ivec(b), ext::ivec(l), ext::ivec(r)));
        })) return nullptr;
    Py_RETURN_NONE;
}

PyObject* b_wild(PyObject*, PyObject* args) {
    PyObject *oi, *om, *op, *ox, *oout;
    int n, k, type;
    const char* fn = "boot_wild";
    EXT_FAIL_IF(!PyArg_ParseTuple(args, "OOOOiiiO:boot_wild", &oi, &om, &op, &ox, &n, &k, &type, &oout)) return nullptr;
    ext::Buf x, out;
    ext::Rng rng;
    EXT_FAIL_IF(n < 0 || k < 0 || !ext::get(ox, x, 'd', false, fn, "returns", (Py_ssize_t) n * k) ||
        !ext::get(oout, out, 'd', true, fn, "out", (Py_ssize_t) n * k) || !rng.open(oi, om, op, fn)) return nullptr;
    EXT_FAIL_IF(!with_rng(rng, [&] { out_mat(out, simlev::boot_wild(ext::mat(x, n, k), type)); })) return nullptr;
    Py_RETURN_NONE;
}

PyObject* b_reset(PyObject*, PyObject* args) {
    PyObject *oi, *om, *op, *ox, *oout;
    int n, k;
    double pb;
    const char* fn = "boot_reset";
    EXT_FAIL_IF(!PyArg_ParseTuple(args, "OOOOiidO:boot_reset", &oi, &om, &op, &ox, &n, &k, &pb, &oout)) return nullptr;
    ext::Buf x, out;
    ext::Rng rng;
    EXT_FAIL_IF(n < 0 || k < 0 || !ext::get(ox, x, 'd', false, fn, "returns", (Py_ssize_t) n * k) ||
        !ext::get(oout, out, 'd', true, fn, "out", (Py_ssize_t) n * k) || !rng.open(oi, om, op, fn)) return nullptr;
    EXT_FAIL_IF(!with_rng(rng, [&] { out_mat(out, simlev::boot_reset(ext::mat(x, n, k), pb)); })) return nullptr;
    Py_RETURN_NONE;
}

PyObject* b_evt(PyObject*, PyObject* args) {
    PyObject *oi, *om, *op, *ox, *opl, *opr, *ob, *oret, *oidx;
    int n, k, base, n_out;
    double p_l, th_l, sc_l, sh_l, p_r, th_r, sc_r, sh_r;
    const char* fn = "boot_evt";
    EXT_FAIL_IF(!PyArg_ParseTuple(args, "OOOOiiiiddddOddddOOOO:boot_evt", &oi, &om, &op, &ox, &n, &k, &base, &n_out, &p_l,
                          &th_l, &sc_l, &sh_l, &opl, &p_r, &th_r, &sc_r, &sh_r, &opr, &ob, &oret, &oidx))
        return nullptr;
    ext::Buf x, pl, pr, b, ret, idx;
    ext::Rng rng;
    EXT_FAIL_IF(n < 0 || k < 0 || n_out < 0 || !ext::get(ox, x, 'd', false, fn, "returns", (Py_ssize_t) n * k) ||
        !ext::get(opl, pl, 'i', false, fn, "pool_l") || !ext::get(opr, pr, 'i', false, fn, "pool_r") ||
        !ext::get(ob, b, 'i', false, fn, "bulk_idx") ||
        !ext::get(oret, ret, 'd', true, fn, "out_ret", (Py_ssize_t) n_out * k) ||
        !ext::get(oidx, idx, 'i', true, fn, "out_idx", n_out) || !rng.open(oi, om, op, fn)) return nullptr;
    EXT_FAIL_IF(!with_rng(rng, [&] {
            auto r = simlev::boot_evt(ext::mat(x, n, k), base, n_out, p_l, th_l, sc_l, sh_l, ext::ivec(pl), p_r, th_r,
                                      sc_r, sh_r, ext::ivec(pr), ext::ivec(b));
            out_mat(ret, std::get<1>(r));
            out_ivec(idx, std::get<3>(r));
        })) return nullptr;
    Py_RETURN_NONE;
}

PyObject* b_garch(PyObject*, PyObject* args) {
    PyObject *oi, *om, *op, *ozb, *ova, *occ, *ocmu, *ocom, *ocal, *ocbe, *ocr, *ocs2, *ozc, *oret, *oidx;
    int n_out, base, k, zc_nr;
    double mu, omega, alpha, beta, gamma, s2;
    const char* fn = "boot_garch";
    EXT_FAIL_IF(!PyArg_ParseTuple(args, "OOOiiiddddddOOOOOOOOOOiOO:boot_garch", &oi, &om, &op, &n_out, &base, &k, &mu, &omega,
                          &alpha, &beta, &gamma, &s2, &ozb, &ova, &occ, &ocmu, &ocom, &ocal, &ocbe, &ocr, &ocs2, &ozc,
                          &zc_nr, &oret, &oidx))
        return nullptr;
    ext::Buf zb, va, cc, cmu, com, cal, cbe, cr, cs2, zc, ret, idx;
    ext::Rng rng;
    EXT_FAIL_IF(n_out < 0 || k < 0 || zc_nr < 0 || !ext::get(ozb, zb, 'd', false, fn, "z_base") ||
        !ext::get(ova, va, 'i', false, fn, "valid") || !ext::get(occ, cc, 'i', false, fn, "cross_cols") ||
        !ext::get(ocmu, cmu, 'd', false, fn, "cmu") || !ext::get(ocom, com, 'd', false, fn, "com") ||
        !ext::get(ocal, cal, 'd', false, fn, "cal") || !ext::get(ocbe, cbe, 'd', false, fn, "cbe") ||
        !ext::get(ocr, cr, 'i', false, fn, "cratio") || !ext::get(ocs2, cs2, 'd', false, fn, "cs2") ||
        !ext::get(ozc, zc, 'd', false, fn, "z_cross", (Py_ssize_t) zc_nr * cc.n) ||
        !ext::get(oret, ret, 'd', true, fn, "out_ret", (Py_ssize_t) n_out * k) ||
        !ext::get(oidx, idx, 'i', true, fn, "out_idx", n_out) || !rng.open(oi, om, op, fn)) return nullptr;
    EXT_FAIL_IF(!with_rng(rng, [&] {
            auto r = simlev::boot_garch(n_out, base, k, mu, omega, alpha, beta, gamma, s2, ext::vec(zb), ext::ivec(va),
                                        ext::ivec(cc), ext::vec(cmu), ext::vec(com), ext::vec(cal), ext::vec(cbe),
                                        ext::ivec(cr), ext::vec(cs2), ext::mat(zc, zc_nr, (int) cc.n));
            out_mat(ret, std::get<1>(r));
            out_ivec(idx, std::get<3>(r));
        })) return nullptr;
    Py_RETURN_NONE;
}

PyObject* b_ms_garch(PyObject*, PyObject* args) {
    PyObject *oi, *om, *op, *omu, *oom, *oal, *obe, *oga, *oph, *ola, *otr, *ode, *ouv, *osp, *opools, *ozb, *occ,
        *ocmu, *ocom, *ocal, *ocbe, *ocr, *ocs2, *ozc, *oret, *oidx, *oreg;
    int n_out, base, k, K, zc_nr;
    const char* fn = "boot_ms_garch";
    EXT_FAIL_IF(!PyArg_ParseTuple(args, "OOOiiii" "OOOOOOO" "OO" "OO" "O" "O" "OOOOOOOO" "i" "OOO" ":boot_ms_garch", &oi, &om, &op, &n_out, &base, &k, &K,
                          &omu, &oom, &oal, &obe, &oga, &oph, &ola, &otr, &ode, &ouv, &osp, &opools, &ozb, &occ, &ocmu,
                          &ocom, &ocal, &ocbe, &ocr, &ocs2, &ozc, &zc_nr, &oret, &oidx, &oreg))
        return nullptr;
    ext::Buf mu, omg, al, be, ga, ph, la, tr, de, uv, sp, zb, cc, cmu, com, cal, cbe, cr, cs2, zc, ret, idx, reg;
    ext::Rng rng;
    EXT_FAIL_IF(n_out < 0 || k < 0 || K < 1 || zc_nr < 0 || !ext::get(omu, mu, 'd', false, fn, "mu", K) ||
        !ext::get(oom, omg, 'd', false, fn, "omega", K) || !ext::get(oal, al, 'd', false, fn, "alpha", K) ||
        !ext::get(obe, be, 'd', false, fn, "beta", K) || !ext::get(oga, ga, 'd', false, fn, "gamma", K) ||
        !ext::get(oph, ph, 'd', false, fn, "phi", K) || !ext::get(ola, la, 'd', false, fn, "lambda", K) ||
        !ext::get(otr, tr, 'd', false, fn, "trans", (Py_ssize_t) K * K) ||
        !ext::get(ode, de, 'd', false, fn, "delta", (Py_ssize_t) K * K) ||
        !ext::get(ouv, uv, 'd', false, fn, "unc_var", K) || !ext::get(osp, sp, 'd', false, fn, "stat_prob", K) ||
        !ext::get(ozb, zb, 'd', false, fn, "z_base") || !ext::get(occ, cc, 'i', false, fn, "cross_cols") ||
        !ext::get(ocmu, cmu, 'd', false, fn, "cmu") || !ext::get(ocom, com, 'd', false, fn, "com") ||
        !ext::get(ocal, cal, 'd', false, fn, "cal") || !ext::get(ocbe, cbe, 'd', false, fn, "cbe") ||
        !ext::get(ocr, cr, 'i', false, fn, "cratio") || !ext::get(ocs2, cs2, 'd', false, fn, "cs2") ||
        !ext::get(ozc, zc, 'd', false, fn, "z_cross", (Py_ssize_t) zc_nr * cc.n) ||
        !ext::get(oret, ret, 'd', true, fn, "out_ret", (Py_ssize_t) n_out * k) ||
        !ext::get(oidx, idx, 'i', true, fn, "out_idx", n_out) || !ext::get(oreg, reg, 'i', true, fn, "out_reg", n_out))
        return nullptr;
    PyObject* seq = PySequence_Fast(opools, "boot_ms_garch: 'pools' muss eine Folge sein.");
    EXT_FAIL_IF(!seq) return nullptr;
    const Py_ssize_t np_ = PySequence_Fast_GET_SIZE(seq);
    EXT_FAIL_IF(np_ != K) {
        Py_DECREF(seq);
        PyErr_Format(PyExc_ValueError, "boot_ms_garch: 'pools' muss %d Felder haben (erhalten: %zd).", K, np_);
        return nullptr;
    }
    Bufs pb;
    simlev_host::IntList pools;
    for (Py_ssize_t r = 0; r < np_; r++) {
        pb.emplace_back(new ext::Buf());
        EXT_FAIL_IF(!ext::get(PySequence_Fast_GET_ITEM(seq, r), *pb.back(), 'i', false, fn, "pools[r]")) {
            Py_DECREF(seq);
            return nullptr;
        }
        pools.push_back(ext::ivec(*pb.back()));
    }
    Py_DECREF(seq);
    EXT_FAIL_IF(!rng.open(oi, om, op, fn)) return nullptr;
    EXT_FAIL_IF(!with_rng(rng, [&] {
            auto r = simlev::boot_ms_garch(n_out, base, k, K, ext::vec(mu), ext::vec(omg), ext::vec(al), ext::vec(be),
                                           ext::vec(ga), ext::vec(ph), ext::vec(la), ext::mat(tr, K, K),
                                           ext::mat(de, K, K), ext::vec(uv), ext::vec(sp), pools, ext::vec(zb),
                                           ext::ivec(cc), ext::vec(cmu), ext::vec(com), ext::vec(cal), ext::vec(cbe),
                                           ext::ivec(cr), ext::vec(cs2), ext::mat(zc, zc_nr, (int) cc.n));
            out_mat(ret, std::get<1>(r));
            out_ivec(idx, std::get<3>(r));
            out_ivec(reg, std::get<5>(r));
        })) return nullptr;
    Py_RETURN_NONE;
}

/* ── ohne Zufallszahlen ─────────────────────────────────────────────────── */

PyObject* b_rolling_vol(PyObject*, PyObject* args) {
    PyObject *ox, *oout;
    int window;
    const char* fn = "rolling_vol";
    EXT_FAIL_IF(!PyArg_ParseTuple(args, "OiO:rolling_vol", &ox, &window, &oout)) return nullptr;
    ext::Buf x, out;
    EXT_FAIL_IF(!ext::get(ox, x, 'd', false, fn, "x") || !ext::get(oout, out, 'd', true, fn, "out", x.n)) return nullptr;
    EXT_FAIL_IF(!ext::run([&] {
            ext::Vec v = simlev::rolling_vol(ext::vec(x), window);
            ext::put(out, v.ptr, v.len);
        })) return nullptr;
    Py_RETURN_NONE;
}

PyObject* b_assign_regimes(PyObject*, PyObject* args) {
    PyObject *ov, *oth, *oout;
    const char* fn = "assign_regimes";
    EXT_FAIL_IF(!PyArg_ParseTuple(args, "OOO:assign_regimes", &ov, &oth, &oout)) return nullptr;
    ext::Buf v, th, out;
    EXT_FAIL_IF(!ext::get(ov, v, 'd', false, fn, "vol") || !ext::get(oth, th, 'd', false, fn, "thresh") ||
        !ext::get(oout, out, 'i', true, fn, "out", v.n)) return nullptr;
    EXT_FAIL_IF(!ext::run([&] { out_ivec(out, simlev::assign_regimes(ext::vec(v), ext::vec(th))); })) return nullptr;
    Py_RETURN_NONE;
}

PyObject* b_estimate_trans_mat(PyObject*, PyObject* args) {
    PyObject *oreg, *oout;
    int K;
    double alpha;
    const char* fn = "estimate_trans_mat";
    EXT_FAIL_IF(!PyArg_ParseTuple(args, "OidO:estimate_trans_mat", &oreg, &K, &alpha, &oout)) return nullptr;
    ext::Buf reg, out;
    EXT_FAIL_IF(K < 0 || !ext::get(oreg, reg, 'i', false, fn, "regimes") ||
        !ext::get(oout, out, 'd', true, fn, "out", (Py_ssize_t) K * K)) return nullptr;
    EXT_FAIL_IF(!ext::run([&] { out_mat(out, simlev::estimate_trans_mat(ext::ivec(reg), K, alpha)); })) return nullptr;
    Py_RETURN_NONE;
}

}  // namespace

PyMethodDef simlev_ext_bootstrap_methods[] = {
    {"boot_idx_iid", b_iid, METH_VARARGS, "boot_idx_iid(ist, mt, pst, n_src, n_out, out)"},
    {"boot_idx_block", b_block, METH_VARARGS, "boot_idx_block(ist, mt, pst, n_src, n_out, block_length, circular, out)"},
    {"boot_idx_stationary", b_stationary, METH_VARARGS, "boot_idx_stationary(ist, mt, pst, n_src, n_out, L, out)"},
    {"boot_idx_regime", b_regime, METH_VARARGS, "boot_idx_regime(ist, mt, pst, regimes, trans, K, n_out, out)"},
    {"boot_idx_tails", b_tails, METH_VARARGS,
     "boot_idx_tails(ist, mt, pst, n_out, p_l, p_r, bulk_idx, left_idx, right_idx, out)"},
    {"boot_wild", b_wild, METH_VARARGS, "boot_wild(ist, mt, pst, returns, n, k, type, out)"},
    {"boot_reset", b_reset, METH_VARARGS, "boot_reset(ist, mt, pst, returns, n, k, p_break, out)"},
    {"boot_evt", b_evt, METH_VARARGS, "boot_evt(ist, mt, pst, returns, n, k, base, n_out, ..., out_ret, out_idx)"},
    {"boot_garch", b_garch, METH_VARARGS, "boot_garch(ist, mt, pst, n_out, base, k, ..., out_ret, out_idx)"},
    {"boot_ms_garch", b_ms_garch, METH_VARARGS,
     "boot_ms_garch(ist, mt, pst, n_out, base, k, K, ..., out_ret, out_idx, out_reg)"},
    {"rolling_vol", b_rolling_vol, METH_VARARGS, "rolling_vol(x, window, out)"},
    {"assign_regimes", b_assign_regimes, METH_VARARGS, "assign_regimes(vol, thresh, out)"},
    {"estimate_trans_mat", b_estimate_trans_mat, METH_VARARGS, "estimate_trans_mat(regimes, K, alpha, out)"},
    {nullptr, nullptr, 0, nullptr}
};

/*
 * python/src/_ext_withdrawal.cpp -- Python-Huelle des Entnahme-Kerns (.wd_simulate)
 *
 * Etappe 7.3a. Gemeinsamer Kern mit R (r/src/withdrawal_core_impl.h, Kopie hier);
 * aufgerufen aus simlev._withdrawal_core.wd_simulate, das die Argumente vorher
 * wie der reine Python-Kern umwandelt. Matrizen spaltenweise als flache
 * double-Puffer mit Zeilen- und Spaltenzahl, lot_group als int32-Puffer.
 *
 *   wd_simulate(R, nr, nc, INF, nr, nc, CAPE, nr, nc, BASE, nr, nc, ppy, rule, rp,
 *               start_timing, start_value, income_real, tax_on, tax_rate, tfs,
 *               spb_annual, vp_on, cost, basis_ratio, loss0, keep, lot_n, lot_basis,
 *               lot_vp, lot_group, spb_first, horizon_end)
 *     -> (shape, wealth, spending, planned, terminal_real, terminal_nominal,
 *         taxes_real, failed, depletion_period, wealth_end, taxes_end)
 *
 * shape = (ny, paths, wealth_nr, wealth_nc, end_nr, end_nc); die Felder kommen als
 * bytearray (float64, spaltenweise). Fehler des Kerns: ValueError mit dem Text
 * von R (die Python-Seite macht daraus WdError wie der reine Python-Kern).
 */
#include "_ext_common.h"
#include "withdrawal_core_impl.h"

namespace {

bool mat_arg(PyObject* o, int nr, int nc, ext::Buf& b, const char* name) {
    if (!ext::get(o, b, 'd', false, "wd_simulate", name)) return false;
    if (nr < 0 || nc < 0 || (Py_ssize_t) nr * nc != b.n) {
        PyErr_Format(PyExc_ValueError, "wd_simulate: '%s' passt nicht zu %d x %d.", name, nr, nc);
        return false;
    }
    return true;
}

PyObject* w_simulate(PyObject*, PyObject* args) {
    PyObject *oR, *oI, *oC, *oB, *orp, *oinc, *oln, *olb, *olv, *olg;
    int Rr, Rc, Ir, Ic, Cr, Cc, Br, Bc, ppy, rule, start_timing, tax_on, vp_on, keep, horizon_end;
    double start_value, tax_rate, tfs, spb_annual, cost, basis_ratio, loss0, spb_first;
    if (!PyArg_ParseTuple(args, "OiiOiiOiiOiiiiOpdOpdddpdddpOOOOdp:wd_simulate", &oR, &Rr, &Rc, &oI, &Ir, &Ic,
                          &oC, &Cr, &Cc, &oB, &Br, &Bc, &ppy, &rule, &orp, &start_timing, &start_value, &oinc,
                          &tax_on, &tax_rate, &tfs, &spb_annual, &vp_on, &cost, &basis_ratio, &loss0, &keep,
                          &oln, &olb, &olv, &olg, &spb_first, &horizon_end))
        return nullptr;
    const char* fn = "wd_simulate";
    ext::Buf bR, bI, bC, bB, brp, binc, bln, blb, blv, blg;
    if (!mat_arg(oR, Rr, Rc, bR, "R") || !mat_arg(oI, Ir, Ic, bI, "INF") || !mat_arg(oC, Cr, Cc, bC, "CAPE") ||
        !mat_arg(oB, Br, Bc, bB, "BASE") || !ext::get(orp, brp, 'd', false, fn, "rp") ||
        !ext::get(oinc, binc, 'd', false, fn, "income_real") || !ext::get(oln, bln, 'd', false, fn, "lot_n") ||
        !ext::get(olb, blb, 'd', false, fn, "lot_basis") || !ext::get(olv, blv, 'd', false, fn, "lot_vp") ||
        !ext::get(olg, blg, 'i', false, fn, "lot_group"))
        return nullptr;
    // Der Kern prueft die Abmessungen selbst (Meldungen wie in R) und liest nur in den
    // geprueften Grenzen; rp hat danach mindestens P_N Werte, income_real mindestens einen.
    PyObject* o[10] = {nullptr};
    int dims[6] = {0, 0, 0, 0, 0, 0};
    if (!ext::run([&] {
            auto r = simlev::wd_simulate(
                ext::mat(bR, Rr, Rc), ext::mat(bI, Ir, Ic), ext::mat(bC, Cr, Cc), ext::mat(bB, Br, Bc), ppy, rule,
                ext::vec(brp), start_timing != 0, start_value, ext::vec(binc), tax_on != 0, tax_rate, tfs, spb_annual,
                vp_on != 0, cost, basis_ratio, loss0, keep != 0, ext::vec(bln), ext::vec(blb), ext::vec(blv),
                ext::ivec(blg), spb_first, horizon_end != 0);
            // Liste wie in R: ("wealth", wealth, "spending", ..., "taxes_end", taxes_end)
            const ext::Mat& wealth = std::get<1>(r);
            const ext::Mat& spending = std::get<3>(r);
            const ext::Mat& wealth_end = std::get<17>(r);
            dims[0] = spending.nr; dims[1] = spending.nc; dims[2] = wealth.nr; dims[3] = wealth.nc;
            dims[4] = wealth_end.nr; dims[5] = wealth_end.nc;
        })) return nullptr;
    // Felder aus dem Speicher des Allokators (Reihenfolge der Anlage wie in R:
    // wealth, spending, planned, terminal, terminal_nom, taxes, depl, fail, wealth_end,
    // taxes_end, st)
    std::deque<std::vector<double>>& st = ext::alloc().store;
    // Rueckgabe in der Reihenfolge wealth, spending, planned, terminal_real, terminal_nominal,
    // taxes_real, depletion_period, failed, wealth_end, taxes_end
    for (int k = 0; k < 10; k++) {
        o[k] = PyByteArray_FromStringAndSize(reinterpret_cast<const char*>(st[(std::size_t) k].data()),
                                             (Py_ssize_t) (st[(std::size_t) k].size() * sizeof(double)));
        if (!o[k]) {
            for (int j = 0; j < k; j++) Py_DECREF(o[j]);
            ext::alloc().reset();
            return nullptr;
        }
    }
    ext::alloc().reset();
    return Py_BuildValue("(iiiiii)NNNNNNNNNN", dims[0], dims[1], dims[2], dims[3], dims[4], dims[5],
                         o[0], o[1], o[2], o[3], o[4], o[5], o[6], o[7], o[8], o[9]);
}

}  // namespace

PyMethodDef simlev_ext_withdrawal_methods[] = {
    {"wd_simulate", w_simulate, METH_VARARGS,
     "wd_simulate(R, nr, nc, INF, nr, nc, CAPE, nr, nc, BASE, nr, nc, ppy, rule, rp, start_timing,\n"
     "            start_value, income_real, tax_on, tax_rate, tfs, spb_annual, vp_on, cost, basis_ratio,\n"
     "            loss0, keep, lot_n, lot_basis, lot_vp, lot_group, spb_first, horizon_end)\n"
     "-> (shape, wealth, spending, planned, terminal_real, terminal_nominal, taxes_real,\n"
     "    depletion_period, failed, wealth_end, taxes_end)"},
    {nullptr, nullptr, 0, nullptr}
};

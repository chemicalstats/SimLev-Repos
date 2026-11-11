/*
 * python/src/_ext_withdrawal.cpp -- Python-Huelle des Entnahme-Kerns (.wd_simulate)
 *
 * Gemeinsamer Kern mit R und Julia (core/withdrawal_core_impl.h, Kopie in src/core/);
 * aufgerufen aus simlev._withdrawal_core.wd_simulate, das die Argumente vorher
 * wie R umwandelt. Matrizen spaltenweise als flache
 * double-Puffer mit Zeilen- und Spaltenzahl, lot_group als int32-Puffer.
 *
 *   wd_simulate(R, nr, nc, INF, nr, nc, CAPE, nr, nc, BASE, nr, nc, ppy, rule, rp,
 *               start_timing, start_value, income_real, tax_on, tax_rate, tfs,
 *               spb_annual, vp_on, cost, basis_ratio, loss0, keep, lot_n, lot_basis,
 *               lot_vp, lot_group, spb_first, horizon_end, tariff_par, zve)
 *     -> (shape, wealth, spending, planned, terminal_real, terminal_nominal,
 *         taxes_real, failed, depletion_period, wealth_end, taxes_end, tariff_years)
 *
 * shape = (ny, paths, wealth_nr, wealth_nc, end_nr, end_nc, tariff_nr, tariff_nc), tariff_years 25 x (ny + 1)
 * Pfade; die Felder kommen als
 * bytearray (float64, spaltenweise). Fehler des Kerns: ValueError mit dem Text
 * von R (die Python-Seite macht daraus WdError).
 *
 * Auswertung je Pfad (seit 1.5.0; Ergebnisfelder legt die Python-Seite an, float64, Matrizen spaltenweise):
 *   wd_metrics(sp, ny, np, nfy, H | None, gamma, start_value, mean, min, dd, ce, total)
 *   wd_pwr(AR, ny, np, legacy, H | None, out) -> (status, path)
 *   wd_annual_prod(real, nr, nc, ppy, out)
 *   wd_tariff_count(M, N) -> nkeep;  wd_tariff_compact(M, N, ny, nkeep, out)
 * H als int32-Puffer (Horizont je Pfad, 0..ny).
 */
#include "_ext_common.h"
#include "core/withdrawal_core_impl.h"

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
    PyObject *oR, *oI, *oC, *oB, *orp, *oinc, *oln, *olb, *olv, *olg, *otp, *ozv;
    int Rr, Rc, Ir, Ic, Cr, Cc, Br, Bc, ppy, rule, start_timing, tax_on, vp_on, keep, horizon_end;
    double start_value, tax_rate, tfs, spb_annual, cost, basis_ratio, loss0, spb_first;
    if (!PyArg_ParseTuple(args, "OiiOiiOiiOiiiiOpdOpdddpdddpOOOOdpOO:wd_simulate", &oR, &Rr, &Rc, &oI, &Ir, &Ic,
                          &oC, &Cr, &Cc, &oB, &Br, &Bc, &ppy, &rule, &orp, &start_timing, &start_value, &oinc,
                          &tax_on, &tax_rate, &tfs, &spb_annual, &vp_on, &cost, &basis_ratio, &loss0, &keep,
                          &oln, &olb, &olv, &olg, &spb_first, &horizon_end, &otp, &ozv))
        return nullptr;
    const char* fn = "wd_simulate";
    ext::Buf bR, bI, bC, bB, brp, binc, bln, blb, blv, blg, btp, bzv;
    if (!mat_arg(oR, Rr, Rc, bR, "R") || !mat_arg(oI, Ir, Ic, bI, "INF") || !mat_arg(oC, Cr, Cc, bC, "CAPE") ||
        !mat_arg(oB, Br, Bc, bB, "BASE") || !ext::get(orp, brp, 'd', false, fn, "rp") ||
        !ext::get(oinc, binc, 'd', false, fn, "income_real") || !ext::get(oln, bln, 'd', false, fn, "lot_n") ||
        !ext::get(olb, blb, 'd', false, fn, "lot_basis") || !ext::get(olv, blv, 'd', false, fn, "lot_vp") ||
        !ext::get(olg, blg, 'i', false, fn, "lot_group") || !ext::get(otp, btp, 'd', false, fn, "tariff_par") ||
        !ext::get(ozv, bzv, 'd', false, fn, "zve"))
        return nullptr;
    // Der Kern prueft die Abmessungen selbst (Meldungen wie in R) und liest nur in den
    // geprueften Grenzen; rp hat danach mindestens P_N Werte, income_real mindestens einen.
    PyObject* o[11] = {nullptr};
    int dims[8] = {0, 0, 0, 0, 0, 0, 0, 0};
    if (!ext::run([&] {
            auto r = simlev::wd_simulate(
                ext::mat(bR, Rr, Rc), ext::mat(bI, Ir, Ic), ext::mat(bC, Cr, Cc), ext::mat(bB, Br, Bc), ppy, rule,
                ext::vec(brp), start_timing != 0, start_value, ext::vec(binc), tax_on != 0, tax_rate, tfs, spb_annual,
                vp_on != 0, cost, basis_ratio, loss0, keep != 0, ext::vec(bln), ext::vec(blb), ext::vec(blv),
                ext::ivec(blg), spb_first, horizon_end != 0, ext::vec(btp), ext::vec(bzv));
            // Liste wie in R: ("wealth", wealth, "spending", ..., "taxes_end", taxes_end)
            const ext::Mat& wealth = std::get<1>(r);
            const ext::Mat& spending = std::get<3>(r);
            const ext::Mat& wealth_end = std::get<17>(r);
            const ext::Mat& tariff_years = std::get<21>(r);
            dims[0] = spending.nr; dims[1] = spending.nc; dims[2] = wealth.nr; dims[3] = wealth.nc;
            dims[4] = wealth_end.nr; dims[5] = wealth_end.nc; dims[6] = tariff_years.nr; dims[7] = tariff_years.nc;
        })) return nullptr;
    // Felder aus dem Speicher des Allokators in der Reihenfolge der Anlage wie in R: wealth, spending, planned,
    // terminal, terminal_nom, taxes, depl, fail, wealth_end, taxes_end, tariff_years (= Rueckgabe terminal_real,
    // terminal_nominal, taxes_real, depletion_period, failed; seit 1.6.4 ohne den Zustand st, den der Kern lokal haelt)
    std::deque<std::vector<double>>& st = ext::alloc().store;
    for (int k = 0; k < 11; k++) {
        const std::size_t sk = (std::size_t) k;
        o[k] = PyByteArray_FromStringAndSize(reinterpret_cast<const char*>(st[sk].data()),
                                             (Py_ssize_t) (st[sk].size() * sizeof(double)));
        if (!o[k]) {
            for (int j = 0; j < k; j++) Py_DECREF(o[j]);
            ext::alloc().reset();
            return nullptr;
        }
    }
    ext::alloc().reset();
    return Py_BuildValue("(iiiiiiii)NNNNNNNNNNN", dims[0], dims[1], dims[2], dims[3], dims[4], dims[5], dims[6],
                         dims[7], o[0], o[1], o[2], o[3], o[4], o[5], o[6], o[7], o[8], o[9], o[10]);
}

bool horizon_arg(PyObject* oH, ext::Buf& bH, int ny, int np, const char* fn, const int** H) {
    *H = nullptr;
    if (oH == Py_None) return true;
    if (!ext::get(oH, bH, 'i', false, fn, "H", np)) return false;
    for (int i = 0; i < np; i++)
        if (bH.i()[i] < 0 || bH.i()[i] > ny) {
            PyErr_Format(PyExc_ValueError, "%s: Horizont %d ausserhalb 0..%d", fn, bH.i()[i], ny);
            return false;
        }
    *H = bH.i();
    return true;
}

PyObject* w_metrics(PyObject*, PyObject* args) {
    PyObject *osp, *oH, *om, *omn, *odd, *oce, *otot;
    int ny, np, nfy;
    double gamma, sv;
    if (!PyArg_ParseTuple(args, "OiiiOddOOOOO:wd_metrics", &osp, &ny, &np, &nfy, &oH, &gamma, &sv, &om, &omn, &odd,
                          &oce, &otot))
        return nullptr;
    const char* fn = "wd_metrics";
    ext::Buf bsp, bH, bm, bmn, bdd, bce, btot;
    const int* H = nullptr;
    if (ny < 0 || np < 0 || nfy < 0 || nfy > ny) {
        PyErr_Format(PyExc_ValueError, "%s: Abmessungen passen nicht", fn);
        return nullptr;
    }
    if (!ext::get(osp, bsp, 'd', false, fn, "sp", (Py_ssize_t) ny * np) || !horizon_arg(oH, bH, ny, np, fn, &H) ||
        !ext::get(om, bm, 'd', true, fn, "mean", np) || !ext::get(omn, bmn, 'd', true, fn, "min", np) ||
        !ext::get(odd, bdd, 'd', true, fn, "dd", np) || !ext::get(oce, bce, 'd', true, fn, "ce", np) ||
        !ext::get(otot, btot, 'd', true, fn, "total", np))
        return nullptr;
    std::vector<double> tmp(2 * (std::size_t) ny + 1);
    simlev::wd_metrics(ny, np, bsp.d(), nfy, H, gamma, sv, bm.d(), bmn.d(), bdd.d(), bce.d(), btot.d(), tmp.data());
    Py_RETURN_NONE;
}

PyObject* w_pwr(PyObject*, PyObject* args) {
    PyObject *oA, *oH, *oo;
    int ny, np;
    double legacy;
    if (!PyArg_ParseTuple(args, "OiidOO:wd_pwr", &oA, &ny, &np, &legacy, &oH, &oo)) return nullptr;
    const char* fn = "wd_pwr";
    ext::Buf bA, bH, bo;
    const int* H = nullptr;
    if (ny < 0 || np < 0) {
        PyErr_Format(PyExc_ValueError, "%s: Abmessungen passen nicht", fn);
        return nullptr;
    }
    if (!ext::get(oA, bA, 'd', false, fn, "AR", (Py_ssize_t) ny * np) || !horizon_arg(oH, bH, ny, np, fn, &H) ||
        !ext::get(oo, bo, 'd', true, fn, "out", np))
        return nullptr;
    std::vector<double> w(std::max((std::size_t) ny * (std::size_t) np, 2 * (std::size_t) ny) + 1);
    int64_t path = 0;
    const int st = simlev::wd_pwr(ny, np, bA.d(), legacy, H, bo.d(), &path, w.data());
    return Py_BuildValue("(iL)", st, (long long) path);
}

PyObject* w_annual_prod(PyObject*, PyObject* args) {
    PyObject *oR, *oo;
    int nr, nc, ppy;
    if (!PyArg_ParseTuple(args, "OiiiO:wd_annual_prod", &oR, &nr, &nc, &ppy, &oo)) return nullptr;
    const char* fn = "wd_annual_prod";
    ext::Buf bR, bo;
    if (nr < 0 || nc < 0 || ppy < 1) {
        PyErr_Format(PyExc_ValueError, "%s: Abmessungen passen nicht", fn);
        return nullptr;
    }
    if (!ext::get(oR, bR, 'd', false, fn, "real", (Py_ssize_t) nr * nc) ||
        !ext::get(oo, bo, 'd', true, fn, "out", (Py_ssize_t) (nr / ppy) * nc))
        return nullptr;
    simlev::wd_annual_prod(nr, nc, bR.d(), ppy, bo.d());
    Py_RETURN_NONE;
}

PyObject* w_tariff_count(PyObject*, PyObject* args) {
    PyObject* oM;
    int N;
    if (!PyArg_ParseTuple(args, "Oi:wd_tariff_count", &oM, &N)) return nullptr;
    ext::Buf bM;
    if (N < 0 || !ext::get(oM, bM, 'd', false, "wd_tariff_count", "M", (Py_ssize_t) N * simlev::TR_N)) return nullptr;
    return PyLong_FromLongLong((long long) simlev::wd_tariff_count(N, bM.d()));
}

PyObject* w_tariff_compact(PyObject*, PyObject* args) {
    PyObject *oM, *oo;
    int N, ny;
    long long nkeep;
    if (!PyArg_ParseTuple(args, "OiiLO:wd_tariff_compact", &oM, &N, &ny, &nkeep, &oo)) return nullptr;
    const char* fn = "wd_tariff_compact";
    ext::Buf bM, bo;
    if (N < 0 || nkeep < 0 || !ext::get(oM, bM, 'd', false, fn, "M", (Py_ssize_t) N * simlev::TR_N) ||
        !ext::get(oo, bo, 'd', true, fn, "out", (Py_ssize_t) nkeep * (simlev::TR_N + 1)))
        return nullptr;
    if (simlev::wd_tariff_count(N, bM.d()) != nkeep) {
        PyErr_Format(PyExc_ValueError, "%s: Zahl der Zeilen passt nicht", fn);
        return nullptr;
    }
    simlev::wd_tariff_compact(N, bM.d(), ny, nkeep, bo.d());
    Py_RETURN_NONE;
}

}  // namespace

PyMethodDef simlev_ext_withdrawal_methods[] = {
    {"wd_simulate", w_simulate, METH_VARARGS,
     "wd_simulate(R, nr, nc, INF, nr, nc, CAPE, nr, nc, BASE, nr, nc, ppy, rule, rp, start_timing,\n"
     "            start_value, income_real, tax_on, tax_rate, tfs, spb_annual, vp_on, cost, basis_ratio,\n"
     "            loss0, keep, lot_n, lot_basis, lot_vp, lot_group, spb_first, horizon_end, tariff_par, zve)\n"
     "-> (shape, wealth, spending, planned, terminal_real, terminal_nominal, taxes_real,\n"
     "    depletion_period, failed, wealth_end, taxes_end, tariff_years)"},
    {"wd_metrics", w_metrics, METH_VARARGS,
     "wd_metrics(sp, ny, np, nfy, H, gamma, start_value, mean, min, dd, ce, total): Kennzahlen je Pfad"},
    {"wd_pwr", w_pwr, METH_VARARGS, "wd_pwr(AR, ny, np, legacy, H, out) -> (status, path): PWR je Pfad"},
    {"wd_annual_prod", w_annual_prod, METH_VARARGS, "wd_annual_prod(real, nr, nc, ppy, out): Produkt je Jahr"},
    {"wd_tariff_count", w_tariff_count, METH_VARARGS, "wd_tariff_count(M, N) -> Zahl der Jahreszeilen"},
    {"wd_tariff_compact", w_tariff_compact, METH_VARARGS, "wd_tariff_compact(M, N, ny, nkeep, out): Jahreszeilen"},
    {nullptr, nullptr, 0, nullptr}
};

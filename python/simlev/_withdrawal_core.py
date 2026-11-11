"""Entnahme-Kern (``.wd_simulate``, Python-Hülle).

Es rechnet der gemeinsame Kern von R, Python und Julia (``core/withdrawal_core_impl.h``, hier über
``simlev._ext``). Der bitgleiche Python-Port als Rückfall (``SIMLEV_NO_EXT=1``,
mit ``rule_amount``, ``pmt_due`` und der FIFO-Steuer) ist seit 1.0.0 entfallen.
"""
from __future__ import annotations

import numpy as np

from . import _ext
from ._r.rnum import _c64 as _f64   # zusammenhängendes float64-Feld (seit 1.6.4 eine Fassung)

__all__ = ["wd_simulate", "wd_metrics", "wd_pwr", "wd_annual_prod", "wd_tariff_compact"]


class WdError(ValueError):
    """Fehler des Kerns (Meldung der C++-Hülle in ``simlev._ext``; in R ``stop``)."""


def _mat(x, nr=None):
    a = np.asarray(x, dtype=np.float64)
    if a.ndim == 1:
        a = a.reshape(-1, 1) if a.size else a.reshape(nr or 0, 0)
    return a


def wd_simulate(R, INF, CAPE, BASE, ppy, rule, rp, start_timing, start_value, income_real,
                tax_on, tax_rate, tfs, spb_annual, vp_on, cost, basis_ratio, loss0, keep,
                lot_n=(), lot_basis=(), lot_vp=(), lot_group=(), spb_first=-1.0, horizon_end=False,
                tariff_par=(), zve=()):
    """Schneller Entnahme-Kern (``.wd_simulate``); Rückgabe ``dict`` wie die R-Liste."""
    R = _mat(R)
    INF = _mat(INF)
    CAPE = _mat(CAPE, R.shape[0])
    BASE = _mat(BASE)
    lgi = [int(v) for v in np.asarray(lot_group).ravel()]
    ppy, rule = int(ppy), int(rule)
    mats = []
    for M in (R, INF, CAPE, BASE):
        mats += [np.ravel(M, order="F"), M.shape[0], M.shape[1]]
    try:
        out = _ext.wd_simulate(*mats, ppy, rule, _f64(rp), bool(start_timing), float(start_value), _f64(income_real),
                               bool(tax_on), float(tax_rate), float(tfs), float(spb_annual), bool(vp_on), float(cost),
                               float(basis_ratio), float(loss0), bool(keep), _f64(lot_n), _f64(lot_basis),
                               _f64(lot_vp), np.array(lgi, dtype=np.int32), float(spb_first), bool(horizon_end),
                               _f64(tariff_par), _f64(zve))
    except ValueError as e:                    # Fehler des Kerns (stop)
        raise WdError(str(e)) from None
    (ny, paths, wnr, wnc, enr, enc, tnr, tnc), arrs = out[0], out[1:]

    def mat(ba, nr, nc):
        return np.ascontiguousarray(np.frombuffer(ba, dtype=np.float64).reshape(nc, nr).T)

    def vec(ba):
        return np.frombuffer(ba, dtype=np.float64)
    out = {"wealth": mat(arrs[0], wnr, wnc), "spending": mat(arrs[1], ny, paths), "planned": mat(arrs[2], ny, paths),
           "terminal_real": vec(arrs[3]), "terminal_nominal": vec(arrs[4]), "taxes_real": vec(arrs[5]),
           "failed": vec(arrs[7]), "depletion_period": vec(arrs[6]),
           "wealth_end": mat(arrs[8], enr, enc), "taxes_end": mat(arrs[9], enr, enc)}
    if len(tariff_par):  # Jahreszeilen nur mit Tarifweg (sonst wie bisher)
        out["tariff_years"] = mat(arrs[10], tnr, tnc)
    return out


# ── Auswertung je Pfad (seit 1.5.0; core/withdrawal_core_impl.h) ─────────────────────────────────────────────────

def _horizon(H):
    return None if H is None else np.ascontiguousarray(np.asarray(H).ravel(), dtype=np.int32)


def wd_metrics(sp, nfy, H, gamma, start_value):
    """Kennzahlen der Entnahmen je Pfad (R: ``.wd_metrics``): ``dict`` mit ``mean_spending``, ``min_spending``,
    ``spending_drawdown``, ``ce_spending``, ``total_spending``; ``H`` ``None`` oder Horizont je Pfad."""
    sp = _mat(sp)
    ny, npth = sp.shape
    out = {k: np.empty(npth) for k in ("mean_spending", "min_spending", "spending_drawdown", "ce_spending",
                                       "total_spending")}
    _ext.wd_metrics(np.ravel(sp, order="F"), ny, npth, int(nfy), _horizon(H), float(gamma), float(start_value),
                    *out.values())
    return out


def wd_pwr(AR, legacy, H=None):
    """Perfect Withdrawal Rate je Spalte (R: ``.wd_pwr``): ``(pwr, status, path)``; status 1 nicht endlich,
    2 Median < 0.5, 3 negativ (dann pwr unvollständig, path der erste ungültige Pfad mit ``H``)."""
    AR = _mat(AR)
    ny, npth = AR.shape
    out = np.empty(npth)
    st, path = _ext.wd_pwr(np.ravel(AR, order="F"), ny, npth, float(legacy), _horizon(H), out)
    return out, st, path


def wd_annual_prod(real, ppy):
    """Produkt je Block von ``ppy`` Zeilen (R: ``.wd_annual_prod``): Matrix ``(nr // ppy) x nc``."""
    real = _mat(real)
    nr, nc = real.shape
    out = np.empty((nr // int(ppy)) * nc)
    _ext.wd_annual_prod(np.ravel(real, order="F"), nr, nc, int(ppy), out)
    return out.reshape(nc, nr // int(ppy)).T.copy()


def wd_tariff_compact(M, ny):
    """Jahreszeilen des Tarifwegs ohne Jahre NA (R: ``.wd_tariff_compact``): Matrix mit Pfad und den 25 Zeilen."""
    M = np.asarray(M, dtype=np.float64)
    flat = np.ravel(M, order="F")
    N = M.shape[1]
    nk = _ext.wd_tariff_count(flat, N)
    out = np.empty(nk * (M.shape[0] + 1))
    _ext.wd_tariff_compact(flat, N, int(ny), nk, out)
    return out.reshape(M.shape[0] + 1, nk).T


"""Entnahme-Kern (``.wd_simulate``, Python-Hülle).

Es rechnet der gemeinsame Kern von R und Python (``core/withdrawal_core_impl.h`` über
``simlev._ext``, Etappe 7.3a). Der bitgleiche Python-Port als Rückfall (``SIMLEV_NO_EXT=1``,
mit ``rule_amount``, ``pmt_due`` und der FIFO-Steuer) ist mit Etappe 9.6c entfallen.
"""
from __future__ import annotations

import numpy as np

from . import _ext

__all__ = ["wd_simulate"]


class WdError(ValueError):
    """Fehler des Kerns (Rcpp ``stop``)."""


def _mat(x, nr=None):
    a = np.asarray(x, dtype=np.float64)
    if a.ndim == 1:
        a = a.reshape(-1, 1) if a.size else a.reshape(nr or 0, 0)
    return a


def _f64(x):
    return np.ascontiguousarray(np.asarray(x, dtype=np.float64).ravel())


def wd_simulate(R, INF, CAPE, BASE, ppy, rule, rp, start_timing, start_value, income_real,
                tax_on, tax_rate, tfs, spb_annual, vp_on, cost, basis_ratio, loss0, keep,
                lot_n=(), lot_basis=(), lot_vp=(), lot_group=(), spb_first=-1.0, horizon_end=False):
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
                               _f64(lot_vp), np.array(lgi, dtype=np.int32), float(spb_first), bool(horizon_end))
    except ValueError as e:                    # Fehler des Kerns (stop)
        raise WdError(str(e)) from None
    (ny, paths, wnr, wnc, enr, enc), arrs = out[0], out[1:]

    def mat(ba, nr, nc):
        return np.ascontiguousarray(np.frombuffer(ba, dtype=np.float64).reshape(nc, nr).T)

    def vec(ba):
        return np.frombuffer(ba, dtype=np.float64)
    return {"wealth": mat(arrs[0], wnr, wnc), "spending": mat(arrs[1], ny, paths), "planned": mat(arrs[2], ny, paths),
            "terminal_real": vec(arrs[3]), "terminal_nominal": vec(arrs[4]), "taxes_real": vec(arrs[5]),
            "failed": vec(arrs[7]), "depletion_period": vec(arrs[6]),
            "wealth_end": mat(arrs[8], enr, enc), "taxes_end": mat(arrs[9], enr, enc)}

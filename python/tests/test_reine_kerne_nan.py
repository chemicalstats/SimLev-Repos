"""Reine Python-Kerne in NaN-Randfällen bitgleich zu R (Etappe 8.0).

Feste Randfälle mit NA, NaN, Division durch 0 und NaN-Vorzeichen für die Kerne, deren
reiner Python-Port (Rückfall ohne C-Erweiterung bzw. mit ``SIMLEV_NO_EXT=1``) vor
Etappe 8.0 in Zufallsvergleichen gegen R im NaN-Bitmuster abwich: cvar/cdar, hmm, dcc,
garch_filter, die Engine-Kerne (``_core``), ``boot_wild``, ``boot_garch``,
``boot_ms_garch``, ``boot_idx_regime`` (Division durch 0), ``rtruncnorm`` und ``_qnorm_std``
(Zweig r > 27).

Die erwarteten Werte stammen aus R 4.3.3 mit SimLev (Bitmuster als Hex-Literale; NA =
``0x7ff00000000007a2`` bzw. still ``0x7ff80000000007a2``, R's NaN ``0x7ff8000000000000``,
das Standard-NaN von x86 ``0xfff8000000000000``). Jeder Fall wird zweimal gerechnet,
damit auch der spezialisierte Bytecode von CPython (andere NaN-Wahl bei ``a + b``)
geprüft ist.
"""
import copy
import math

import numpy as np
import pytest

from simlev import _bootstrap_core as BC
from simlev import _core as C
from simlev import _dependence_core as D
from simlev import _optimize_core as O
from simlev._r import env, rng, truncnorm
from simlev._r.rnum import NA_REAL as NA

NAN = float("nan")


def _hex(x):
    return hex(int(np.float64(x).view(np.uint64)))


def _leaves(t, path=""):
    """Blätter in der Reihenfolge von R's flat(): Pfad und Hex-Bitmuster (bzw. Ganzzahlen, Texte)."""
    if t is None:
        return [(path, None)]
    if isinstance(t, dict):
        out = []
        for k, v in t.items():
            out += _leaves(v, path + "/" + k)
        return out
    if isinstance(t, tuple):                          # unbenannte Liste
        out = []
        for v in t:
            out += _leaves(v, path + "/")
        return out
    if isinstance(t, list) and t and all(isinstance(s, str) for s in t):
        return [(path, list(t))]
    if isinstance(t, list):                           # Liste von Lots
        out = []
        for v in t:
            out += _leaves(v, path + "/")
        return out
    if isinstance(t, (bool, np.bool_)):
        return [(path, [int(t)])]
    a = np.asarray(t)
    if a.dtype.kind in "iu":
        return [(path, [int(v) for v in a.ravel(order="F")])]
    return [(path, [_hex(v) for v in np.asarray(a, dtype=np.float64).ravel(order="F")])]


def _sim0():
    st = {"a": {"count": NAN, "price": 1.0, "worth": NA, "money": NAN, "total": 0.0, "actual": 0.5, "differ": 0.5},
          "b": {"count": 2.0, "price": NA, "worth": NAN, "money": NA, "total": 1.0, "actual": 0.5, "differ": 0.5}}
    mk = {"a": {"asset_day": np.arange(16000, 16003, dtype=np.int64), "asset_price": np.array([NA, 2.0, NAN])},
          "b": {"asset_day": np.arange(16000, 16003, dtype=np.int64), "asset_price": np.array([NAN, NA, 3.0])}}
    tr = {nm: {"buys": [], "buy_count": 0, "fifo_front": 1} for nm in "ab"}
    rp = {nm: {f: np.zeros(3) for f in ("worth", "money", "flows", "total", "share")} for nm in "ab"}
    return {"assets": ["a", "b"], "status": st, "market": mk, "trades": tr, "report": rp,
            "totals": {"loss_capital_gains": 0.0}}


def _canon_sim(s):
    """Zustand wie die R-Seite (.cmp_canon): Zahlen als double, asset_day als double."""
    s = copy.deepcopy(s)
    for nm in s["market"]:
        s["market"][nm]["asset_day"] = s["market"][nm]["asset_day"].astype(np.float64)
    for nm in s["trades"]:
        t = s["trades"][nm]
        t["buy_count"] = float(t["buy_count"])
        t["fifo_front"] = float(t["fifo_front"])
    return s


def _eng(f, *args):
    s = _sim0()
    f(s, *args)
    return {"res": None, "sim": _canon_sim(s)}


_LOTS = [{"date": 16000, "type": "Buy", "count": 3.0, "price": NA, "remaining": 2.0, "original": 3.0},
         {"date": 16100, "type": "Buy", "count": 1.0, "price": NAN, "remaining": 1.0, "original": 1.0},
         {"date": 18321, "type": "Buy", "count": 2.0, "price": 5.0, "remaining": 2.0, "original": 2.0, "vp": 0.5}]
_T = {"loss_capital_gains": 0.0, "cgt_loss_added_ytd": 0.0, "cgt_loss_used_ytd": NAN, "cgt_base_taxed_ytd": NA,
      "sparer_pauschbetrag_remaining": 100.0, "sparer_pauschbetrag_used_total": NAN, "total_taxes": NA}


def _buys(f, *args, totals=None):
    t = copy.deepcopy(totals)
    r = f(copy.deepcopy(_LOTS), *args) if t is None else f(args[0], args[1], t, *args[2:])
    if isinstance(r, dict):
        r = {k: float(v) for k, v in r.items()}
    return {"res": r, "totals": t}


def _rng(seed, f, *args):
    rng.set_seed(seed)
    r = f(*args)
    return (r, rng.runif(1))


_ZB = np.array([0.5, NA, -1.2, NAN, 0.3, 1.1])
_ZC = np.array([[0.1, NAN, NA, -0.4, 0.2, 0.0]]).T
_P_QNORM = [5e-324, 1e-320, 2.5e-318, 1e-317, 2.0e-317, 2.4e-317]

CASES = {
    "cvar_T0": lambda: O.min_cvar_core(np.zeros((0, 2)), 0.05, [0, 0], [1, 1], [0.5, 0.5], 0.01, [0.01], 5),
    "cdar_nan": lambda: O.min_cdar_core(np.array([[0.01, 0.02], [NA, NA], [-0.02, 0.0], [NAN, 0.01], [0.03, -0.03],
                                                  [0.01, NAN]]), 0.2, [0, 0], [1, 1], 15),
    "hmm_nan": lambda: D.hmm_forward_backward(np.array([[0.5, 0.3], [0.0, 0.0], [NA, NAN], [0.2, 0.4]]),
                                              np.array([[0.9, 0.1], [0.2, 0.8]]), [0.6, 0.4]),
    "dcc_nan": lambda: (lambda r: {"nll": r["nll"], "R": r["R"], "ok": r["ok"]})(
        D.dcc_filter(np.array([[0.5, 0.8], [NA, NAN], [1.2, 0.1], [-0.3, -1.0], [NAN, NA]]), 0.05, 0.9,
                     np.array([[1, 0.3], [0.3, 1]]), True)),
    "garch_filter_nan": lambda: BC.garch_filter([0.01, NA, -0.02, NAN, 0.005, NA, NAN], 1e-6, 0.05, 0.9, 0.1, 1e-4),
    "dca": lambda: _eng(C.dca_flows_allocation, "a", NA, 1),
    "buy_report": lambda: _eng(C.calculate_buy_report, "b", 2, NA, NAN, NA),
    "sell_report": lambda: _eng(C.calculate_sell_report, "b", 2, NAN, NA, NAN, 1.0),
    "total_report": lambda: _eng(C.calculate_total_report, ["a", "b"], 2),
    "market_update": lambda: _eng(C.perform_market_update, ["a", "b"], 3),
    "market_update_batch": lambda: _eng(C.batch_market_update, ["a", "b"], 1, 3),
    "fifo_price": lambda: _buys(C._calculate_fifo_price, 4.0, 1),
    "private_sale_tax": lambda: _buys(C._calculate_private_sale_tax, 1, 5.0, NAN, 18700),
    "sell_count_tp0": lambda: _buys(C.sell_count, 1, 10.0, 0.0, 5.0, False, 2, 0.0, 0.0, 0.25),
    "sell_count_nan": lambda: _buys(C.sell_count, 3, NAN, 2.0, 5.0, False, 1, 0.3, 0.0, 0.25),
    "p20_tax": lambda: _buys(C.p20_tax, NA, 0.0, 0.26375, True, totals=_T),
    "vp_tax": lambda: _buys(C.vp_tax, NAN, 0.3, 0.26375, True, totals=dict(_T, sparer_pauschbetrag_used_total=NA)),
    "boot_wild": lambda: _rng(7, BC.boot_wild, np.array([[1.01, 0.99], [NA, 1.02], [NAN, NAN], [1.0, NA], [0.98, 1.01]]), 2),
    "boot_garch": lambda: _rng(11, BC.boot_garch, 12, 0, 2, 0.0003, 2e-6, 0.08, 0.9, 0.05, 1e-4, _ZB, [1, 2, 3, 4, 5, 6],
                               [1], [0.0002], [1e-6], [0.05], [0.9], [True], [1e-4], _ZC),
    "boot_ms_garch": lambda: _rng(13, BC.boot_ms_garch, 12, 0, 2, 2, [0.0003, -0.0002], [2e-6, 5e-6], [0.05, 0.1],
                                  [0.9, 0.85], [0.05, 0.0], [0.1, 0.0], [0.05, 0.0], np.array([[0.95, 0.05], [0.1, 0.9]]),
                                  np.array([[0.0, 0.5], [0.3, 0.0]]), [1e-4, 2e-4], [0.6, 0.4], [[1, 2, 3], [4, 5, 6]],
                                  _ZB, [1], [0.0002], [1e-6], [0.05], [0.9], [False], [1e-4], _ZC),
    "truncnorm": lambda: _rng(5, truncnorm.rtruncnorm, 8.0, np.array([-1.0, -np.inf, 0.5, -2.0, 1.0, -np.inf, -1.0, 2.0]),
                              np.array([1.0, 0.5, np.inf, -1.0, 3.0, -0.2, 0.0, 2.5]),
                              np.array([NA, NAN, NA, 0.0, NAN, NA, 0.0, NAN]),
                              np.array([NAN, NA, NAN, NA, NA, NAN, NA, NA])),
    "boot_idx_regime_s0": lambda: _rng(3, BC.boot_idx_regime, [1, 2, 1, 2, 2], np.array([[0.0, 0.0], [0.0, 0.0]]), 6),
    "qnorm_tief": lambda: np.array([rng._qnorm_std(p) for p in _P_QNORM]),
}

# R 4.3.3 / SimLev (erzeugt mit scratchpad/e80y/tgen/gen.py)
EXPECTED = {
    'cvar_T0': [
        ('', ['0x0', '0x0']),
    ],
    'cdar_nan': [
        ('', ['0x3fe0000000000000', '0x3fe0000000000000']),
    ],
    'hmm_nan': [
        ('/filtered', ['0x3fe6db6db6db6db7', '0xfff8000000000000', '0xfff8000000000000', '0xfff8000000000000', '0x3fd2492492492492', '0xfff8000000000000', '0xfff8000000000000', '0xfff8000000000000']),
        ('/smoothed', ['0x7ff80000000007a2', '0xfff8000000000000', '0xfff8000000000000', '0xfff8000000000000', '0x7ff80000000007a2', '0xfff8000000000000', '0xfff8000000000000', '0xfff8000000000000']),
        ('/xi', ['0xfff8000000000000', '0xfff8000000000000', '0xfff8000000000000', '0xfff8000000000000']),
        ('/scale', ['0x3fdae147ae147ae1', '0x0', '0xfff8000000000000', '0xfff8000000000000']),
    ],
    'dcc_nan': [
        ('/nll', ['0x7ff80000000007a2']),
        ('/R', ['0x3fd3333333333333', '0x3fd41401a8034ed1', '0x7ff80000000007a2', '0x7ff80000000007a2', '0x7ff80000000007a2']),
        ('/ok', [1]),
    ],
    'garch_filter_nan': [
        ('', ['0x3f1a36e2eb1c432d', '0x3f192a737110e454', '0x7ff80000000007a2', '0x7ff80000000007a2', '0x7ff8000000000000', '0x7ff8000000000000', '0x7ff80000000007a2']),
    ],
    'dca': [
        ('/res', None),
        ('/sim/assets', ['a', 'b']),
        ('/sim/status/a/count', ['0x7ff8000000000000']),
        ('/sim/status/a/price', ['0x3ff0000000000000']),
        ('/sim/status/a/worth', ['0x7ff00000000007a2']),
        ('/sim/status/a/money', ['0x7ff80000000007a2']),
        ('/sim/status/a/total', ['0x7ff80000000007a2']),
        ('/sim/status/a/actual', ['0x3fe0000000000000']),
        ('/sim/status/a/differ', ['0x3fe0000000000000']),
        ('/sim/status/b/count', ['0x4000000000000000']),
        ('/sim/status/b/price', ['0x7ff00000000007a2']),
        ('/sim/status/b/worth', ['0x7ff8000000000000']),
        ('/sim/status/b/money', ['0x7ff00000000007a2']),
        ('/sim/status/b/total', ['0x3ff0000000000000']),
        ('/sim/status/b/actual', ['0x3fe0000000000000']),
        ('/sim/status/b/differ', ['0x3fe0000000000000']),
        ('/sim/market/a/asset_day', ['0x40cf400000000000', '0x40cf408000000000', '0x40cf410000000000']),
        ('/sim/market/a/asset_price', ['0x7ff00000000007a2', '0x4000000000000000', '0x7ff8000000000000']),
        ('/sim/market/b/asset_day', ['0x40cf400000000000', '0x40cf408000000000', '0x40cf410000000000']),
        ('/sim/market/b/asset_price', ['0x7ff8000000000000', '0x7ff00000000007a2', '0x4008000000000000']),
        ('/sim/trades/a/buy_count', ['0x0']),
        ('/sim/trades/a/fifo_front', ['0x3ff0000000000000']),
        ('/sim/trades/b/buy_count', ['0x0']),
        ('/sim/trades/b/fifo_front', ['0x3ff0000000000000']),
        ('/sim/report/a/worth', ['0x0', '0x0', '0x0']),
        ('/sim/report/a/money', ['0x7ff80000000007a2', '0x0', '0x0']),
        ('/sim/report/a/flows', ['0x7ff00000000007a2', '0x0', '0x0']),
        ('/sim/report/a/total', ['0x7ff80000000007a2', '0x0', '0x0']),
        ('/sim/report/a/share', ['0x0', '0x0', '0x0']),
        ('/sim/report/b/worth', ['0x0', '0x0', '0x0']),
        ('/sim/report/b/money', ['0x0', '0x0', '0x0']),
        ('/sim/report/b/flows', ['0x0', '0x0', '0x0']),
        ('/sim/report/b/total', ['0x0', '0x0', '0x0']),
        ('/sim/report/b/share', ['0x0', '0x0', '0x0']),
        ('/sim/totals/loss_capital_gains', ['0x0']),
    ],
    'buy_report': [
        ('/res', None),
        ('/sim/assets', ['a', 'b']),
        ('/sim/status/a/count', ['0x7ff8000000000000']),
        ('/sim/status/a/price', ['0x3ff0000000000000']),
        ('/sim/status/a/worth', ['0x7ff00000000007a2']),
        ('/sim/status/a/money', ['0x7ff8000000000000']),
        ('/sim/status/a/total', ['0x0']),
        ('/sim/status/a/actual', ['0x3fe0000000000000']),
        ('/sim/status/a/differ', ['0x3fe0000000000000']),
        ('/sim/status/b/count', ['0x7ff80000000007a2']),
        ('/sim/status/b/price', ['0x7ff00000000007a2']),
        ('/sim/status/b/worth', ['0x7ff80000000007a2']),
        ('/sim/status/b/money', ['0x7ff80000000007a2']),
        ('/sim/status/b/total', ['0x7ff80000000007a2']),
        ('/sim/status/b/actual', ['0x3fe0000000000000']),
        ('/sim/status/b/differ', ['0x3fe0000000000000']),
        ('/sim/market/a/asset_day', ['0x40cf400000000000', '0x40cf408000000000', '0x40cf410000000000']),
        ('/sim/market/a/asset_price', ['0x7ff00000000007a2', '0x4000000000000000', '0x7ff8000000000000']),
        ('/sim/market/b/asset_day', ['0x40cf400000000000', '0x40cf408000000000', '0x40cf410000000000']),
        ('/sim/market/b/asset_price', ['0x7ff8000000000000', '0x7ff00000000007a2', '0x4008000000000000']),
        ('/sim/trades/a/buy_count', ['0x0']),
        ('/sim/trades/a/fifo_front', ['0x3ff0000000000000']),
        ('/sim/trades/b/buy_count', ['0x0']),
        ('/sim/trades/b/fifo_front', ['0x3ff0000000000000']),
        ('/sim/report/a/worth', ['0x0', '0x0', '0x0']),
        ('/sim/report/a/money', ['0x0', '0x0', '0x0']),
        ('/sim/report/a/flows', ['0x0', '0x0', '0x0']),
        ('/sim/report/a/total', ['0x0', '0x0', '0x0']),
        ('/sim/report/a/share', ['0x0', '0x0', '0x0']),
        ('/sim/report/b/worth', ['0x0', '0x7ff80000000007a2', '0x0']),
        ('/sim/report/b/money', ['0x0', '0x7ff80000000007a2', '0x0']),
        ('/sim/report/b/flows', ['0x0', '0x0', '0x0']),
        ('/sim/report/b/total', ['0x0', '0x7ff80000000007a2', '0x0']),
        ('/sim/report/b/share', ['0x0', '0x0', '0x0']),
        ('/sim/totals/loss_capital_gains', ['0x0']),
    ],
    'sell_report': [
        ('/res', None),
        ('/sim/assets', ['a', 'b']),
        ('/sim/status/a/count', ['0x7ff8000000000000']),
        ('/sim/status/a/price', ['0x3ff0000000000000']),
        ('/sim/status/a/worth', ['0x7ff00000000007a2']),
        ('/sim/status/a/money', ['0x7ff8000000000000']),
        ('/sim/status/a/total', ['0x0']),
        ('/sim/status/a/actual', ['0x3fe0000000000000']),
        ('/sim/status/a/differ', ['0x3fe0000000000000']),
        ('/sim/status/b/count', ['0x7ff8000000000000']),
        ('/sim/status/b/price', ['0x7ff8000000000000']),
        ('/sim/status/b/worth', ['0x7ff8000000000000']),
        ('/sim/status/b/money', ['0x7ff8000000000000']),
        ('/sim/status/b/total', ['0x7ff8000000000000']),
        ('/sim/status/b/actual', ['0x3fe0000000000000']),
        ('/sim/status/b/differ', ['0x3fe0000000000000']),
        ('/sim/market/a/asset_day', ['0x40cf400000000000', '0x40cf408000000000', '0x40cf410000000000']),
        ('/sim/market/a/asset_price', ['0x7ff00000000007a2', '0x4000000000000000', '0x7ff8000000000000']),
        ('/sim/market/b/asset_day', ['0x40cf400000000000', '0x40cf408000000000', '0x40cf410000000000']),
        ('/sim/market/b/asset_price', ['0x7ff8000000000000', '0x7ff00000000007a2', '0x4008000000000000']),
        ('/sim/trades/a/buy_count', ['0x0']),
        ('/sim/trades/a/fifo_front', ['0x3ff0000000000000']),
        ('/sim/trades/b/buy_count', ['0x0']),
        ('/sim/trades/b/fifo_front', ['0x3ff0000000000000']),
        ('/sim/report/a/worth', ['0x0', '0x0', '0x0']),
        ('/sim/report/a/money', ['0x0', '0x0', '0x0']),
        ('/sim/report/a/flows', ['0x0', '0x0', '0x0']),
        ('/sim/report/a/total', ['0x0', '0x0', '0x0']),
        ('/sim/report/a/share', ['0x0', '0x0', '0x0']),
        ('/sim/report/b/worth', ['0x0', '0x7ff8000000000000', '0x0']),
        ('/sim/report/b/money', ['0x0', '0x7ff8000000000000', '0x0']),
        ('/sim/report/b/flows', ['0x0', '0x0', '0x0']),
        ('/sim/report/b/total', ['0x0', '0x7ff8000000000000', '0x0']),
        ('/sim/report/b/share', ['0x0', '0x0', '0x0']),
        ('/sim/totals/loss_capital_gains', ['0x0']),
    ],
    'total_report': [
        ('/res', None),
        ('/sim/assets', ['a', 'b']),
        ('/sim/status/a/count', ['0x7ff8000000000000']),
        ('/sim/status/a/price', ['0x4000000000000000']),
        ('/sim/status/a/worth', ['0x7ff8000000000000']),
        ('/sim/status/a/money', ['0x7ff8000000000000']),
        ('/sim/status/a/total', ['0x7ff8000000000000']),
        ('/sim/status/a/actual', ['0x3fe0000000000000']),
        ('/sim/status/a/differ', ['0x0']),
        ('/sim/status/b/count', ['0x4000000000000000']),
        ('/sim/status/b/price', ['0x7ff00000000007a2']),
        ('/sim/status/b/worth', ['0x7ff80000000007a2']),
        ('/sim/status/b/money', ['0x7ff00000000007a2']),
        ('/sim/status/b/total', ['0x7ff80000000007a2']),
        ('/sim/status/b/actual', ['0x3fe0000000000000']),
        ('/sim/status/b/differ', ['0x0']),
        ('/sim/market/a/asset_day', ['0x40cf400000000000', '0x40cf408000000000', '0x40cf410000000000']),
        ('/sim/market/a/asset_price', ['0x7ff00000000007a2', '0x4000000000000000', '0x7ff8000000000000']),
        ('/sim/market/b/asset_day', ['0x40cf400000000000', '0x40cf408000000000', '0x40cf410000000000']),
        ('/sim/market/b/asset_price', ['0x7ff8000000000000', '0x7ff00000000007a2', '0x4008000000000000']),
        ('/sim/trades/a/buy_count', ['0x0']),
        ('/sim/trades/a/fifo_front', ['0x3ff0000000000000']),
        ('/sim/trades/b/buy_count', ['0x0']),
        ('/sim/trades/b/fifo_front', ['0x3ff0000000000000']),
        ('/sim/report/a/worth', ['0x0', '0x7ff8000000000000', '0x0']),
        ('/sim/report/a/money', ['0x0', '0x7ff8000000000000', '0x0']),
        ('/sim/report/a/flows', ['0x0', '0x0', '0x0']),
        ('/sim/report/a/total', ['0x0', '0x7ff8000000000000', '0x0']),
        ('/sim/report/a/share', ['0x0', '0x0', '0x0']),
        ('/sim/report/b/worth', ['0x0', '0x7ff80000000007a2', '0x0']),
        ('/sim/report/b/money', ['0x0', '0x7ff00000000007a2', '0x0']),
        ('/sim/report/b/flows', ['0x0', '0x0', '0x0']),
        ('/sim/report/b/total', ['0x0', '0x7ff80000000007a2', '0x0']),
        ('/sim/report/b/share', ['0x0', '0x0', '0x0']),
        ('/sim/totals/loss_capital_gains', ['0x0']),
    ],
    'market_update': [
        ('/res', None),
        ('/sim/assets', ['a', 'b']),
        ('/sim/status/a/count', ['0x7ff8000000000000']),
        ('/sim/status/a/price', ['0x7ff8000000000000']),
        ('/sim/status/a/worth', ['0x7ff8000000000000']),
        ('/sim/status/a/money', ['0x7ff8000000000000']),
        ('/sim/status/a/total', ['0x7ff8000000000000']),
        ('/sim/status/a/actual', ['0x3fe0000000000000']),
        ('/sim/status/a/differ', ['0x0']),
        ('/sim/status/b/count', ['0x4000000000000000']),
        ('/sim/status/b/price', ['0x4008000000000000']),
        ('/sim/status/b/worth', ['0x4018000000000000']),
        ('/sim/status/b/money', ['0x7ff00000000007a2']),
        ('/sim/status/b/total', ['0x7ff80000000007a2']),
        ('/sim/status/b/actual', ['0x3fe0000000000000']),
        ('/sim/status/b/differ', ['0x0']),
        ('/sim/market/a/asset_day', ['0x40cf400000000000', '0x40cf408000000000', '0x40cf410000000000']),
        ('/sim/market/a/asset_price', ['0x7ff00000000007a2', '0x4000000000000000', '0x7ff8000000000000']),
        ('/sim/market/b/asset_day', ['0x40cf400000000000', '0x40cf408000000000', '0x40cf410000000000']),
        ('/sim/market/b/asset_price', ['0x7ff8000000000000', '0x7ff00000000007a2', '0x4008000000000000']),
        ('/sim/trades/a/buy_count', ['0x0']),
        ('/sim/trades/a/fifo_front', ['0x3ff0000000000000']),
        ('/sim/trades/b/buy_count', ['0x0']),
        ('/sim/trades/b/fifo_front', ['0x3ff0000000000000']),
        ('/sim/report/a/worth', ['0x0', '0x0', '0x7ff8000000000000']),
        ('/sim/report/a/money', ['0x0', '0x0', '0x7ff8000000000000']),
        ('/sim/report/a/flows', ['0x0', '0x0', '0x0']),
        ('/sim/report/a/total', ['0x0', '0x0', '0x7ff8000000000000']),
        ('/sim/report/a/share', ['0x0', '0x0', '0x0']),
        ('/sim/report/b/worth', ['0x0', '0x0', '0x4018000000000000']),
        ('/sim/report/b/money', ['0x0', '0x0', '0x7ff00000000007a2']),
        ('/sim/report/b/flows', ['0x0', '0x0', '0x0']),
        ('/sim/report/b/total', ['0x0', '0x0', '0x7ff80000000007a2']),
        ('/sim/report/b/share', ['0x0', '0x0', '0x0']),
        ('/sim/totals/loss_capital_gains', ['0x0']),
    ],
    'market_update_batch': [
        ('/res', None),
        ('/sim/assets', ['a', 'b']),
        ('/sim/status/a/count', ['0x7ff8000000000000']),
        ('/sim/status/a/price', ['0x7ff8000000000000']),
        ('/sim/status/a/worth', ['0x7ff8000000000000']),
        ('/sim/status/a/money', ['0x7ff8000000000000']),
        ('/sim/status/a/total', ['0x7ff8000000000000']),
        ('/sim/status/a/actual', ['0x3fe0000000000000']),
        ('/sim/status/a/differ', ['0x0']),
        ('/sim/status/b/count', ['0x4000000000000000']),
        ('/sim/status/b/price', ['0x4008000000000000']),
        ('/sim/status/b/worth', ['0x4018000000000000']),
        ('/sim/status/b/money', ['0x7ff00000000007a2']),
        ('/sim/status/b/total', ['0x7ff80000000007a2']),
        ('/sim/status/b/actual', ['0x3fe0000000000000']),
        ('/sim/status/b/differ', ['0x0']),
        ('/sim/market/a/asset_day', ['0x40cf400000000000', '0x40cf408000000000', '0x40cf410000000000']),
        ('/sim/market/a/asset_price', ['0x7ff00000000007a2', '0x4000000000000000', '0x7ff8000000000000']),
        ('/sim/market/b/asset_day', ['0x40cf400000000000', '0x40cf408000000000', '0x40cf410000000000']),
        ('/sim/market/b/asset_price', ['0x7ff8000000000000', '0x7ff00000000007a2', '0x4008000000000000']),
        ('/sim/trades/a/buy_count', ['0x0']),
        ('/sim/trades/a/fifo_front', ['0x3ff0000000000000']),
        ('/sim/trades/b/buy_count', ['0x0']),
        ('/sim/trades/b/fifo_front', ['0x3ff0000000000000']),
        ('/sim/report/a/worth', ['0x7ff80000000007a2', '0x7ff8000000000000', '0x7ff8000000000000']),
        ('/sim/report/a/money', ['0x7ff8000000000000', '0x7ff8000000000000', '0x7ff8000000000000']),
        ('/sim/report/a/flows', ['0x0', '0x0', '0x0']),
        ('/sim/report/a/total', ['0x7ff80000000007a2', '0x7ff8000000000000', '0x7ff8000000000000']),
        ('/sim/report/a/share', ['0x0', '0x0', '0x0']),
        ('/sim/report/b/worth', ['0x7ff8000000000000', '0x7ff80000000007a2', '0x4018000000000000']),
        ('/sim/report/b/money', ['0x7ff00000000007a2', '0x7ff00000000007a2', '0x7ff00000000007a2']),
        ('/sim/report/b/flows', ['0x0', '0x0', '0x0']),
        ('/sim/report/b/total', ['0x7ff8000000000000', '0x7ff80000000007a2', '0x7ff80000000007a2']),
        ('/sim/report/b/share', ['0x0', '0x0', '0x0']),
        ('/sim/totals/loss_capital_gains', ['0x0']),
    ],
    'fifo_price': [
        ('/res', ['0x7ff8000000000000']),
        ('/totals', None),
    ],
    'private_sale_tax': [
        ('/res/exempt_gain', ['0x0']),
        ('/res/exempt_loss', ['0x7ff8000000000000']),
        ('/res/taxable_gain', ['0x0']),
        ('/res/taxable_loss', ['0x0']),
        ('/res/total_gain', ['0x7ff8000000000000']),
        ('/totals', None),
    ],
    'sell_count_tp0': [
        ('/res/sell_count', ['0x4014000000000000']),
        ('/res/fifo_price', ['0x7ff80000000007a2']),
        ('/totals', None),
    ],
    'sell_count_nan': [
        ('/res/sell_count', ['0x0']),
        ('/res/fifo_price', ['0x4014000000000000']),
        ('/totals', None),
    ],
    'p20_tax': [
        ('/res/tax', ['0x7ff80000000007a2']),
        ('/res/spb_used', ['0x7ff80000000007a2']),
        ('/totals/loss_capital_gains', ['0x7ff80000000007a2']),
        ('/totals/cgt_loss_added_ytd', ['0x0']),
        ('/totals/cgt_loss_used_ytd', ['0x7ff8000000000000']),
        ('/totals/cgt_base_taxed_ytd', ['0x7ff80000000007a2']),
        ('/totals/sparer_pauschbetrag_remaining', ['0x7ff80000000007a2']),
        ('/totals/sparer_pauschbetrag_used_total', ['0x7ff80000000007a2']),
        ('/totals/total_taxes', ['0x7ff80000000007a2']),
    ],
    'vp_tax': [
        ('/res/tax', ['0x0']),
        ('/res/spb_used', ['0x7ff8000000000000']),
        ('/res/taxable_amount', ['0x7ff8000000000000']),
        ('/totals/loss_capital_gains', ['0x7ff8000000000000']),
        ('/totals/cgt_loss_added_ytd', ['0x0']),
        ('/totals/cgt_loss_used_ytd', ['0x7ff8000000000000']),
        ('/totals/cgt_base_taxed_ytd', ['0x7ff80000000007a2']),
        ('/totals/sparer_pauschbetrag_remaining', ['0x7ff8000000000000']),
        ('/totals/sparer_pauschbetrag_used_total', ['0x7ff8000000000000']),
        ('/totals/total_taxes', ['0x7ff00000000007a2']),
    ],
    'boot_wild': [
        ('/', ['0x7ff80000000007a2', '0x7ff80000000007a2', '0x7ff8000000000000', '0x7ff80000000007a2', '0x7ff80000000007a2', '0x7ff8000000000000', '0x7ff8000000000000', '0x7ff8000000000000', '0x7ff80000000007a2', '0x7ff8000000000000']),
        ('/', ['0x3fc5fbd74a800000']),
    ],
    'boot_garch': [
        ('//ret', ['0x7ff80000000007a2', '0x7ff80000000007a2', '0x7ff80000000007a2', '0x7ff80000000007a2', '0x7ff80000000007a2', '0x7ff80000000007a2', '0x7ff80000000007a2', '0x7ff80000000007a2', '0x7ff80000000007a2', '0x7ff80000000007a2', '0x7ff80000000007a2', '0x7ff80000000007a2', '0x7ff8000000000000', '0x7ff8000000000000', '0x7ff8000000000000', '0x7ff8000000000000', '0x7ff8000000000000', '0x7ff8000000000000', '0x7ff8000000000000', '0x7ff8000000000000', '0x7ff8000000000000', '0x7ff8000000000000', '0x7ff8000000000000', '0x7ff8000000000000']),
        ('//idx', [2, 1, 4, 1, 1, 6, 1, 2, 6, 1, 2, 3]),
        ('/', ['0x3fed07a496600000']),
    ],
    'boot_ms_garch': [
        ('//ret', ['0x7ff8000000000000', '0x7ff8000000000000', '0x7ff8000000000000', '0x7ff8000000000000', '0x7ff8000000000000', '0x7ff8000000000000', '0x7ff8000000000000', '0x7ff8000000000000', '0x7ff8000000000000', '0x7ff8000000000000', '0x7ff8000000000000', '0x7ff8000000000000', '0x3fefe26135589ea8', '0x3fefe3ac2fe77031', '0x3fefe4e599f6c85e', '0x3ff000d1b71758e2', '0x3fefe74442c14197', '0x3ff000d1b71758e2', '0x3ff006e29b7d3b37', '0x3ff006a363c3875c', '0x3ff00667f8f346f2', '0x3ff000d1b71758e2', '0x3ff005fa6690ef0e', '0x3ff005c96e0514ea']),
        ('//idx', [4, 4, 4, 6, 4, 6, 5, 5, 5, 6, 5, 5]),
        ('//regime', [2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2]),
        ('/', ['0x3fb635db46000000']),
    ],
    'truncnorm': [
        ('/', ['0x7ff80000000007a2', '0x7ff8000000000000', '0x7ff8000000000000', '0x7ff8000000000000', '0x7ff8000000000000', '0x7ff80000000007a2', '0x7ff8000000000000', '0x7ff8000000000000']),
        ('/', ['0x3fee9ba626800000']),
    ],
    'boot_idx_regime_s0': [
        ('/', [3, 2, 4, 2, 4, 4]),
        ('/', ['0x3fe1d4fcc4c00000']),
    ],
    'qnorm_tief': [
        ('', ['0xc0433bd3f27fcd03', '0xc0432272b3016ccd', '0xc0430ff53aba0c7a', '0xc0430b4df761d462', '0xc04308f9e8a70938', '0xc043085d13ee2ed5']),
    ],
}


@pytest.fixture
def no_ext():
    keep = rng.get_random_seed() if rng._S.exists else None
    with env.use_ext(False), np.errstate(all="ignore"):
        yield
    if keep is not None:
        rng.set_random_seed(keep)


@pytest.mark.parametrize("name", list(CASES))
def test_reiner_kern_nan_bitgleich_zu_r(name, no_ext):
    for _ in range(2):                                 # erster Lauf und spezialisierter Bytecode
        got = _leaves(CASES[name]())
        assert got == EXPECTED[name]


def test_qnorm_std_zweig_r_groesser_27():
    """_qnorm_std rechnet für subnormale p den Zweig r > 27 aus R 4.3.3 (qnorm.c)."""
    for p in _P_QNORM:
        q = p - 0.5
        assert math.sqrt(-math.log(p)) > 27
    assert [_hex(rng._qnorm_std(p)) for p in _P_QNORM] == EXPECTED["qnorm_tief"][0][1]

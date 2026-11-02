"""Reine Python-Kerne in NaN-Randfällen bitgleich zu R (Etappe 8.0).

Feste Randfälle mit NA, NaN, Division durch 0 und NaN-Vorzeichen für die Kerne, deren
reiner Python-Port (Rückfall ohne C-Erweiterung bzw. mit ``SIMLEV_NO_EXT=1``) vor
Etappe 8.0 in Zufallsvergleichen gegen R im NaN-Bitmuster abwich: cvar/cdar, hmm, dcc,
garch_filter, die Engine-Kerne (``_core``), ``boot_wild``, ``boot_garch``,
``boot_ms_garch``, ``boot_idx_regime`` (Division durch 0), ``rtruncnorm`` und ``_qnorm_std``
(Zweig r > 27).

Die erwarteten Werte stammen aus R 4.3.3 mit SimLev (Bitmuster als Hex-Literale; NA =
``0x7ff00000000007a2`` bzw. still ``0x7ff80000000007a2``, R's NaN ``0x7ff8000000000000``,
das Standard-NaN von x86 ``0xfff8000000000000``). N10: Die Engine-Kerne folgen der Regel „NA vor NaN“
(``core/simlev_core.h``); R, Python und Julia liefern dort seither dieselben Bitmuster (geändert:
``sell_report``, ``market_update_batch``, ``fifo_price``, ``private_sale_tax``, ``p20_tax``, ``vp_tax``); die Fälle
der Engine-Kerne sind mit E17 Stufe 1c entfallen (Kerne entfernt, Prüfung über ``tools/gleichlauf/sim_fuzz.R``).
Jeder Fall wird zweimal gerechnet,
damit auch der spezialisierte Bytecode von CPython (andere NaN-Wahl bei ``a + b``)
geprüft ist.
"""
import math

import numpy as np
import pytest

from simlev import _bootstrap_core as BC
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

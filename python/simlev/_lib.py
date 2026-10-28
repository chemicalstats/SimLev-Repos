"""Hüllen der C-Bibliothek slc (SimLev core, Etappe 9.1): Zufallszustand, ``simlev_seed()``,
interne Ziehungen und Verteilungen.

Gegenstück zu ``r/R/slc.R`` (R) und ``julia/src/slib.jl`` (Julia). Die Rechnung steht in
``src/core/slc*.c`` (Kopien von ``core/``), die Hülle in ``src/_ext_slc.c`` (Modul
``simlev._ext``). Warnungen und Fehlertexte kommen aus dem Kern und sind in allen drei Sprachen
gleich (Warnung: ``warnings.warn``; Fehler: ``ValueError``).

Zufallszustand (Entwurf C.5):

* globaler Zustand G: ``bytearray(32)`` in diesem Modul, mit ``threading.Lock``; beim Laden und
  mit ``simlev_seed(None)`` aus Uhrzeit (ns), Prozessnummer und Zähler;
* Strom-Objekt: :class:`Stream` (32 Byte); Ströme sind nicht gesperrt (je Einheit einer);
* innerhalb einer parallelen Einheit (:func:`in_unit`) darf G nicht benutzt werden.

Seit Etappe 9.6a ziehen alle zufälligen Exporte hierüber (Regeln C.5): ``seed=None`` zieht genau
einmal k = :func:`next_seed` aus G und verfährt dann wie mit ``seed=k``; ``seed=s`` lässt G
unberührt, der Hauptstrom ist ``Stream(s)`` (:func:`main_stream`); Einheiten mit ``cores``
bekommen ihre Ströme U_i = J^i(S_0) aus :func:`streams` vor der Verteilung. Die Nachbildung von
R's Zufall (``simlev._r.rng``, Export ``set_seed``) ist mit Etappe 9.6c entfallen.
"""
from __future__ import annotations

import contextlib
import os
import threading
import time

import numpy as np

from . import _ext

__all__ = ["simlev_seed", "Stream", "streams", "next_seed", "resolve_seed", "main_stream", "check_seed", "in_unit",
           "state_hex", "u64", "runif", "rnorm", "rexp", "rgeom", "rgamma", "rchisq", "sample",
           "pnorm", "qnorm", "dnorm", "erfc", "lgamma", "pbeta", "pt", "qt", "plogis", "qlogis", "version"]

_LOCK = threading.RLock()
_G = bytearray(32)
_COUNTER = [0]
_UNIT = threading.local()


def version():
    """Version der C-Bibliothek slc."""
    return _ext.slc_version()


def _entropy_state(buf):
    _COUNTER[0] += 1
    _ext.slc_seed_entropy(buf, time.time_ns() & 0xFFFFFFFFFFFFFFFF, os.getpid() & 0xFFFFFFFFFFFFFFFF,
                          _COUNTER[0] & 0xFFFFFFFFFFFFFFFF)


with _LOCK:
    _entropy_state(_G)


def check_seed(seed):
    """Seed prüfen: ``int`` (kein ``bool``) mit ``|seed| < 2**53`` (Entwurf C.5, Regel 2)."""
    if isinstance(seed, bool) or not isinstance(seed, (int, np.integer)) or not abs(int(seed)) < 2 ** 53:
        raise ValueError("seed: ganze Zahl erwartet (erhalten: %s)" % _seed_text(seed))
    return int(seed)


def _seed_text(seed):
    if isinstance(seed, (int, np.integer)) and not isinstance(seed, bool):
        return str(int(seed))
    txt = repr(seed)
    return txt if len(txt) <= 60 else txt[:57] + "..."


def simlev_seed(seed=None):
    """Zufallszustand von SimLev setzen.

    Setzt den globalen Zufallszustand der C-Bibliothek von SimLev. Mit einer ganzen Zahl entsteht
    ein reproduzierbarer Zustand; ohne Argument (oder mit ``None``) ein neuer Zustand aus Uhrzeit,
    Prozessnummer und einem Zähler, der nicht reproduzierbar ist. Beim Laden des Pakets geschieht
    dasselbe.

    Der Zustand wird in R, Python und Julia gleich gesetzt und liefert dort bei gleichem ``seed`` und gleicher
    Aufruffolge bitgleiche Ziehungen. Generator ist xoshiro256** (Blackman, Vigna 2021) mit
    SplitMix64-Seeding (Steele, Lea, Flood 2014); unabhängige Ströme je Einheit entstehen durch
    Sprünge um 2^128 Schritte.

    Die zufälligen Funktionen von SimLev (Argument ``seed``, z. B. ``bootstrap()``,
    ``bootstrap_study()``, ``scenario_copula()``, ``regime_hmm()``) ziehen aus diesem Zustand:

    * ``seed=None``: der Aufruf zieht **genau einmal** einen Startwert k (0 … 2^31 - 1) und rechnet
      wie mit ``seed=k``; ``bootstrap()``/``bootstrap_study()`` legen k unter ``seed`` ab. Nach
      ``simlev_seed(s)`` ist so auch eine Folge von Aufrufen mit ``seed=None`` reproduzierbar.
    * ``seed=s``: der globale Zustand bleibt unberührt.
    * Funktionen mit ``cores`` geben jedem Pfad einen eigenen Strom; das Ergebnis hängt nicht von
      ``cores`` oder ``chunk_size`` ab.
    * R's ``set.seed()`` wirkt auf SimLev nicht (die Nachbildung ``set_seed`` ist seit 9.6c entfallen).

    Beispiel::

        simlev_seed(42)
        a = sharpe_test(x, y, method="bootstrap", B=50)   # seed=None: ein Zug aus dem Zustand
        simlev_seed(42)
        b = sharpe_test(x, y, method="bootstrap", B=50)   # gleich a

    Parameters
    ----------
    seed : int oder None
        ganze Zahl mit ``|seed| < 2**53`` oder ``None`` (neuer, nicht reproduzierbarer Zustand).

    Returns
    -------
    seed (unverändert)
    """
    if seed is None:
        with _LOCK:
            _entropy_state(_G)
    else:
        s = check_seed(seed)
        with _LOCK:
            _ext.slc_seed(_G, s)
    return seed


class Stream:
    """Zufallsstrom (32 Byte Zustand). ``Stream(seed)`` wie ``simlev_seed(seed)``, aber eigenständig."""

    __slots__ = ("state",)

    def __init__(self, seed=None, state=None):
        self.state = bytearray(32)
        if state is not None:
            self.state[:] = bytes(state)
        else:
            _ext.slc_seed(self.state, check_seed(seed))

    def hex(self):
        return state_hex(self)


def _in_unit():
    return getattr(_UNIT, "flag", False)


@contextlib.contextmanager
def in_unit():
    """Block als parallele Einheit ausführen: G ist darin gesperrt (Entwurf C.5, Regel 7)."""
    old = _in_unit()
    _UNIT.flag = True
    try:
        yield
    finally:
        _UNIT.flag = old


def _global_check():
    if _in_unit():
        raise RuntimeError("interner Fehler: globaler Zufallszustand in paralleler Einheit")


def next_seed():
    """Regel 3: nächster Startwert aus G (0 ... 2^31 - 1); G rückt um eine Ausgabe vor."""
    _global_check()
    with _LOCK:
        return _ext.slc_seed31(_G)


def resolve_seed(seed):
    """Regeln 3 und 4: ``None`` -> :func:`next_seed`, sonst geprüft."""
    return next_seed() if seed is None else check_seed(seed)


def main_stream(seed):
    """Hauptstrom einer zufälligen Funktion (Regeln 3 bis 5): ``Stream(resolve_seed(seed))``."""
    return Stream(resolve_seed(seed))


def streams(stream, n):
    """Regel 6: Ströme je Einheit U_i = J^i(S_0), i = 1 ... n (Liste von :class:`Stream`)."""
    base = stream if isinstance(stream, Stream) else Stream(stream)
    n = int(n)
    if n < 0:
        raise ValueError("Ströme: Anzahl negativ")
    buf = bytearray(32 * n)
    if n:
        _ext.slc_streams(bytearray(base.state), buf)
    return [Stream(state=buf[32 * i:32 * (i + 1)]) for i in range(n)]


def state_hex(stream=None):
    """Zustand als 4 Hex-Wörter (Gleichlauf, Prüfung)."""
    if stream is None:
        _global_check()
        with _LOCK:
            b = bytes(_G)
    else:
        b = bytes(stream.state)
    return ["%016x" % v for v in np.frombuffer(b, dtype=np.uint64)]


def _draw(fn, stream, n, *par, dtype=np.float64):
    out = np.empty(_count(n), dtype=dtype)
    if stream is None:
        _global_check()
        with _LOCK:
            fn(_G, out, *par)
    else:
        fn(stream.state, out, *par)
    return out


def _count(n):
    if isinstance(n, bool) or not isinstance(n, (int, np.integer, float)) or not (0 <= n <= 2 ** 52) or n != int(n):
        raise ValueError("interner Fehler: n muss eine ganze Zahl >= 0 sein")
    return int(n)


def u64(n, stream=None):
    """rohe 64-Bit-Ausgaben als Hex (Testvektoren)."""
    v = _draw(_ext.slc_u64, stream, n, dtype=np.uint64)
    return ["%016x" % x for x in v]


def runif(n, min=0.0, max=1.0, stream=None):  # noqa: A002 (Namen wie in R)
    return _draw(_ext.slc_runif, stream, n, float(min), float(max))


def rnorm(n, mean=0.0, sd=1.0, stream=None):
    return _draw(_ext.slc_rnorm, stream, n, float(mean), float(sd))


def rexp(n, rate=1.0, stream=None):
    return _draw(_ext.slc_rexp, stream, n, float(rate))


def rgeom(n, prob, stream=None):
    return _draw(_ext.slc_rgeom, stream, n, float(prob))


def rgamma(n, shape, scale=1.0, stream=None):
    return _draw(_ext.slc_rgamma, stream, n, float(shape), float(scale))


def rchisq(n, df, stream=None):
    return _draw(_ext.slc_rchisq, stream, n, float(df))


def sample(n, size=None, replace=False, prob=None, stream=None):
    """Stichprobe aus 1 ... n (wie R's ``sample.int``); Ergebnis ``int32``."""
    n = _count(n)
    size = n if size is None else _count(size)
    pr = None if prob is None else np.ascontiguousarray(prob, dtype=np.float64)
    out = np.empty(size, dtype=np.int32)
    if stream is None:
        _global_check()
        with _LOCK:
            _ext.slc_sample(_G, out, n, bool(replace), pr)
    else:
        _ext.slc_sample(stream.state, out, n, bool(replace), pr)
    return out


# ── Verteilungen (Parameter skalar) ─────────────────────────────────────────

def _vec(x):
    return np.ascontiguousarray(x, dtype=np.float64)


def _apply(fn, x, *par):
    a0 = np.asarray(x, dtype=np.float64)
    a = np.ascontiguousarray(a0)            # ascontiguousarray macht aus einer Zahl ein 1-D-Feld
    out = np.empty_like(a)
    fn(a.reshape(-1), out.reshape(-1), *par)
    return out.reshape(a0.shape) if a0.ndim else float(out.reshape(-1)[0])   # Zahl bleibt Zahl


def pnorm(q, mean=0.0, sd=1.0, lower_tail=True):
    return _apply(_ext.slc_pnorm, q, float(mean), float(sd), bool(lower_tail))


def qnorm(p, mean=0.0, sd=1.0, lower_tail=True):
    return _apply(_ext.slc_qnorm, p, float(mean), float(sd), bool(lower_tail))


def dnorm(x, mean=0.0, sd=1.0, log=False):
    return _apply(_ext.slc_dnorm, x, float(mean), float(sd), bool(log))


def erfc(x):
    return _apply(_ext.slc_erfc, x)


def lgamma(x):
    return _apply(_ext.slc_lgamma, x)


def pbeta(q, shape1, shape2, lower_tail=True):
    return _apply(_ext.slc_pbeta, q, float(shape1), float(shape2), bool(lower_tail))


def pt(q, df, lower_tail=True):
    return _apply(_ext.slc_pt, q, float(df), bool(lower_tail))


def qt(p, df, lower_tail=True):
    return _apply(_ext.slc_qt, p, float(df), bool(lower_tail))


def plogis(q):
    return _apply(_ext.slc_plogis, q)


def qlogis(p):
    return _apply(_ext.slc_qlogis, p)


# 9.2: lineare Algebra, Matrixprodukt, kleinste Quadrate, Stineman, Spline, Kerndichte (_lib_linalg.py)
from ._lib_linalg import *  # noqa: E402,F401,F403
from ._lib_linalg import __all__ as _ALL_92  # noqa: E402

__all__ += _ALL_92
# 9.3: Optimierer der C-Bibliothek slc (simlev/_lib_opt.py)
from ._lib_opt import minimize_test, numgrad_test, opt_testfn, optim  # noqa: E402

__all__ += ["optim", "opt_testfn", "minimize_test", "numgrad_test"]
# 9.4: Modelle der C-Bibliothek slc (simlev/_lib_models.py)
from ._lib_models import *  # noqa: E402,F401,F403
from ._lib_models import __all__ as _ALL_94  # noqa: E402

__all__ += _ALL_94

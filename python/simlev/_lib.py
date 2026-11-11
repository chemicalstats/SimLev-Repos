"""Hüllen der C-Bibliothek slc (SimLev core): Zufallszustand, ``simlev_seed()``,
interne Ziehungen und Verteilungen.

Gegenstück zu ``r/R/slc.R`` (R) und ``julia/src/slib.jl`` (Julia). Die Rechnung steht in
``src/core/slc*.cpp`` (Kopien von ``core/``), die Hülle in ``src/_ext_slc.cpp`` (Modul
``simlev._ext``). Warnungen und Fehlertexte kommen aus dem Kern und sind in allen drei Sprachen
gleich (Warnung: ``warnings.warn``; Fehler: ``ValueError``).

Zufallszustand:

* globaler Zustand G: ``bytearray(32)`` in diesem Modul, mit ``threading.Lock``; beim Laden und
  mit ``simlev_seed(None)`` aus Uhrzeit (ns), Prozessnummer und Zähler;
* Strom-Objekt: :class:`Stream` (32 Byte); Ströme sind nicht gesperrt (je Einheit einer);
* innerhalb einer parallelen Einheit (:func:`in_unit`) darf G nicht benutzt werden.

Seit 1.0.0 ziehen alle zufälligen Exporte hierüber: ``seed=None`` zieht genau
einmal k = :func:`next_seed` aus G und verfährt dann wie mit ``seed=k``; ``seed=s`` lässt G
unberührt, der Hauptstrom ist ``Stream(s)`` (:func:`main_stream`); Einheiten mit ``cores``
bekommen ihre Ströme U_i = J^i(S_0) aus :func:`streams` vor der Verteilung. Die Nachbildung von
R's Zufall (``simlev._r.rng``, Export ``set_seed``) ist seit 1.0.0 entfallen.
"""
from __future__ import annotations

import contextlib
import os
import sys
import threading
import time

import numpy as np

from . import _ext

__all__ = ["simlev_seed", "Stream", "streams", "next_seed", "resolve_seed", "main_stream", "check_seed", "in_unit",
           "state_hex", "u64", "runif", "rnorm", "rexp", "rgeom", "rgamma", "rchisq", "sample",
           "pnorm", "qnorm", "dnorm", "erfc", "lgamma", "pbeta", "pt", "qt", "plogis", "qlogis"]

_LOCK = threading.RLock()
_G = bytearray(32)
_COUNTER = [0]
_UNIT = threading.local()


def _entropy_state(buf):
    _COUNTER[0] += 1
    _ext.slc_seed_entropy(buf, time.time_ns() & 0xFFFFFFFFFFFFFFFF, os.getpid() & 0xFFFFFFFFFFFFFFFF,
                          _COUNTER[0] & 0xFFFFFFFFFFFFFFFF)


with _LOCK:
    _entropy_state(_G)


def check_seed(seed, fn="simlev_seed"):
    """Seed prüfen: ganze Zahl mit ``|seed| < 2**53`` wie R (``int``, NumPy-Ganzzahl oder ganzzahliger ``float``,
    kein ``bool``; Länge 1 wie Einzelwert). Seit 1.6.4 ohne Eingabewert in der Meldung (Entscheidung 8, C-096) und
    wie R auch ``42.0`` (bis 1.6.3 nur ``int``); seit K43 T1-R5 mit dem Namen ``fn`` der Funktion (Baustein
    ``ut1.seed``; bis dahin "seed: ganze Zahl erwartet") und T1-R4 ohne ``OverflowError`` bei ``10**400``."""
    import math
    from ._pruefen import _to_float, chk_scalar, chk_stop
    seed = chk_scalar(seed)
    ok = isinstance(seed, (int, float, np.integer, np.floating)) and not isinstance(seed, (bool, np.bool_)) and \
        math.isfinite(_to_float(seed)) and float(seed) == math.trunc(float(seed)) and abs(float(seed)) < 2 ** 53
    if not ok:
        chk_stop("ut1.seed", fn)
    return int(seed)


def simlev_seed(seed=None):
    """Zufallszustand von SimLev setzen.

    Setzt den globalen Zufallszustand der C-Bibliothek von SimLev. Mit einer ganzen Zahl entsteht ein
    reproduzierbarer Zustand; ohne Argument (oder mit ``None``) ein neuer Zustand aus Uhrzeit, Prozessnummer und
    einem Zähler, der nicht reproduzierbar ist (wie R ohne ``set.seed()``). Beim Laden des Pakets geschieht
    dasselbe.

    Args:
        seed: ganze Zahl mit |seed| < 2^53 oder ``None`` (neuer, nicht reproduzierbarer Zustand).

    Returns:
        ``seed``, unsichtbar.

    Details:
        Der Zufallszustand von SimLev ist unabhängig von ``set.seed()`` und ``.Random.seed``; er wird in R, Python
        und Julia gleich gesetzt und liefert dort bei gleichem ``seed`` und gleicher Aufruffolge bitgleiche
        Ziehungen. Generator ist xoshiro256** (Blackman, Vigna 2021) mit SplitMix64-Seeding (Steele, Lea, Flood
        2014); unabhängige Ströme je Einheit entstehen durch Sprünge um 2^128 Schritte.

        Die zufälligen Funktionen von SimLev (Argument ``seed``, z. B. ``bootstrap()``, ``bootstrap_study()``,
        ``scenario_copula()``, ``regime_hmm()``) ziehen aus diesem Zustand:

        - Mit ``seed = None`` zieht ein Aufruf **genau einmal** einen Startwert k aus dem globalen Zustand (ganze
          Zahl von 0 bis 2^31 - 1) und rechnet dann wie mit ``seed = k``. ``bootstrap()`` und
          ``bootstrap_study()`` legen k unter ``$seed`` ab; damit lässt sich das Ergebnis wiederholen. Nach
          ``simlev_seed(s)`` ist daher auch eine Folge von Aufrufen mit ``seed = None`` reproduzierbar.
        - Mit ``seed = s`` bleibt der globale Zustand unberührt.
        - Funktionen mit ``cores`` geben jedem Pfad einen eigenen Strom (Sprung um 2^128 je Pfad); das Ergebnis
          hängt nicht von ``cores`` oder ``chunk_size`` ab.
        - ``set.seed()``, ``RNGkind()`` und ``.Random.seed`` wirken auf SimLev nicht; SimLev liest, setzt und
          löscht ``.Random.seed`` nie.

    Literatur:
        Blackman, D., Vigna, S. (2021). Scrambled linear pseudorandom number generators. *ACM Transactions on
        Mathematical Software* 47(4), Art. 36.

        Steele, G. L., Lea, D., Flood, C. H. (2014). Fast splittable pseudorandom number generators. *Proceedings
        OOPSLA 2014*, 453–472.

    Hinweise (Python):
        Der Zustand wird in R, Python und Julia gleich gesetzt und liefert dort bei gleichem ``seed`` und gleicher
        Aufruffolge bitgleiche Ziehungen. Generator ist xoshiro256** (Blackman, Vigna 2021) mit
        SplitMix64-Seeding (Steele, Lea, Flood 2014); unabhängige Ströme je Einheit entstehen durch
        Sprünge um 2^128 Schritte.

    Beispiel::

        import simlev
        x = [0.010, -0.020, 0.015, 0.003, -0.007, 0.012, -0.004, 0.009, 0.002, -0.011, 0.006, 0.001]
        y = [0.004, -0.006, 0.011, -0.002, 0.001, 0.008, -0.009, 0.005, 0.003, -0.004, 0.002, 0.000]
        simlev.simlev_seed(42); s1 = simlev.sharpe_test(x, y, method="bootstrap", B=50, ppy=52)
        simlev.simlev_seed(42); s2 = simlev.sharpe_test(x, y, method="bootstrap", B=50, ppy=52)
        print(s1.equals(s2))   # True: dieselbe Aufruffolge nach demselben simlev_seed()
    """
    if seed is None:
        with _LOCK:
            _entropy_state(_G)
    else:
        s = check_seed(seed, "simlev_seed")
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
    """Block als parallele Einheit ausführen: G ist darin gesperrt."""
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
    """Nächster Startwert aus G (0 ... 2^31 - 1); G rückt um eine Ausgabe vor."""
    _global_check()
    with _LOCK:
        return _ext.slc_seed31(_G)


def resolve_seed(seed, fn="simlev_seed"):
    """``None`` -> :func:`next_seed`, sonst geprüft (G bleibt unberührt; ``fn`` für die Meldung)."""
    return next_seed() if seed is None else check_seed(seed, fn)


def main_stream(seed, fn="simlev_seed"):
    """Hauptstrom einer zufälligen Funktion: ``Stream(resolve_seed(seed, fn))``."""
    return Stream(resolve_seed(seed, fn))


def streams(stream, n):
    """Ströme je Einheit U_i = J^i(S_0), i = 1 ... n (Liste von :class:`Stream`)."""
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


def _with_state(stream, fn, *args):
    """``fn(Zustand, *args)`` mit dem Zustand von ``stream`` bzw. dem globalen Zustand unter der Sperre (seit 1.6.3
    eine Fassung für _draw, sample und _lib_models._run)."""
    if stream is None:
        _global_check()
        with _LOCK:
            fn(_G, *args)
    else:
        fn(stream.state, *args)


def _draw(fn, stream, n, *par, dtype=np.float64):
    out = np.empty(_count(n), dtype=dtype)
    _with_state(stream, fn, out, *par)
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
    _with_state(stream, _ext.slc_sample, out, n, bool(replace), pr)
    return out


def pooled_draw(nr, cw, L, nper, n, stream=None):
    """Länderblöcke von ``bootstrap_pooled`` im Kern (seit 1.6.5, Paket E, K40/CR2-6; ``sl_pooled_draw``): Land und Zeile
    je Periode und Pfad als int64-Felder (nper x n), dieselben Züge wie die Schleife bis 1.6.4."""
    nper, n = int(nper), int(n)
    c = np.empty(nper * n, dtype=np.int32)
    r = np.empty(nper * n, dtype=np.int32)
    _with_state(stream, _ext.slc_pooled_draw, c, r, np.ascontiguousarray(nr, dtype=np.int64),
                np.ascontiguousarray(cw, dtype=np.float64), float(L), nper, n)
    return (np.ascontiguousarray(c.reshape(n, nper).T, dtype=np.int64),
            np.ascontiguousarray(r.reshape(n, nper).T, dtype=np.int64))


# ── Verteilungen (Parameter skalar) ─────────────────────────────────────────

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


def nprocs():
    """Höchstwert für Parallelität (seit 1.6.4, Entscheidung 41b; ``cores`` und Kern-Threads): Zahl der Prozessoren,
    mindestens 1, aus dem Kern (``sl_nprocs``; eine Quelle für R, Python und Julia)."""
    return int(_ext.slc_nprocs())


_THREADS_HINT = [False]
# Threads je parallele Einheit (seit 1.6.4, Entscheidung 41c; von _r.parallel vor dem Fork gesetzt), sonst None
_THREAD_CAP = [None]


def unit_threads(w):
    """Threads je Einheit bei ``w`` gleichzeitigen Einheiten (seit 1.6.4, Entscheidung 41c): Zahl der Prozessoren
    // ``w``, mindestens 1 (R ``.sl_unit_threads``)."""
    return max(1, nprocs() // int(w))


def env_threads():
    """``SIMLEV_THREADS`` als ganze Zahl >= 1, sonst 0 (ohne Begrenzung und Hinweis; seit 1.6.4 nur ASCII-Ziffern,
    Entscheidungen 27, 65; "2.7", "0x10", "+3", "３" wie andere Fehlwerte: 0; R ``.sl_env_threads``)."""
    v = os.environ.get("SIMLEV_THREADS", "").strip(" \t\r\n")
    n = int(v) if v and all(c in "0123456789" for c in v) else 0
    return n if 1 <= n < 2 ** 31 else 0


def auto_threads():
    """Kern-Threads außerhalb paralleler Einheiten als Zahl >= 1 (``cores = "auto"`` für die Starts des MS-GARCH-Fits,
    seit 1.6.4): :func:`nthreads`, 0 = Zahl der Prozessoren (R ``.sl_auto_threads``)."""
    v = nthreads()
    return nprocs() if v == 0 else v


def mem_avail():
    """Freier Arbeitsspeicher in Bytes laut System (-1 unbekannt; Kern ``sl_mem_avail``, seit 1.6.4)."""
    return float(_ext.slc_mem_avail())


def mem_self():
    """Arbeitsspeicher des eigenen Prozesses in Bytes (-1 unbekannt; Kern ``sl_mem_self``, seit 1.6.4)."""
    return float(_ext.slc_mem_self())


def par_probe(sys_=1, self_bytes=None):
    """Messzeit vor dem Plan (Kern ``sl_par_probe``): Start eines weiteren Laufs des Systems in Sekunden."""
    return float(_ext.slc_par_probe(int(sys_), mem_self() if self_bytes is None else float(self_bytes)))


def load_running():
    """Laufende Prozesse laut System einschließlich des eigenen (-1 unbekannt; Kern ``sl_load_running``, seit 1.6.4,
    Entscheidung 112)."""
    return float(_ext.slc_load_running())


def par_plan(n, unit_s, unit_bytes=0.0, sys_=1, nprocs_=None, max_runs=None, env=None, mem=None, self_bytes=None,
             running=None):
    """Planer für ``cores = "auto"`` (seit 1.6.4, Kern ``sl_par_plan``; gleiche Regel wie R ``.sl_par_plan``):
    ``(Läufe, Kern-Threads je Lauf)`` für ``n`` weitere Einheiten mit Rechenzeit ``unit_s`` (Sekunden) und
    Ergebnisgröße ``unit_bytes`` je Einheit. ``sys_`` 1 = Python (Fork-Prozess). ``nprocs_``, ``mem``, ``self_bytes``,
    ``running`` und ``env`` lassen sich für Proben der Regel vorgeben (Testschalter für andere Rechnergrößen und
    Fremdlast, nicht öffentlich); sonst Zahl der Prozessoren, freier Speicher laut System, Speicher des eigenen
    Prozesses, laufende Prozesse (Entscheidung 112) und ``SIMLEV_THREADS``."""
    np_ = nprocs() if nprocs_ is None else int(nprocs_)
    return tuple(_ext.slc_par_plan(int(sys_), np_, np_ if max_runs is None else int(max_runs),
                                   env_threads() if env is None else int(env), int(n), float(unit_s),
                                   float(unit_bytes), mem_avail() if mem is None else float(mem),
                                   mem_self() if self_bytes is None else float(self_bytes),
                                   load_running() if running is None else float(running)))


def nthreads():
    """Threads der elementweisen Kerne (seit 1.6.0): ``SIMLEV_THREADS`` (ganze Zahl >= 1, seit 1.6.4 nur ASCII-Ziffern),
    sonst 0 = Höchstwert
    (Zahl der Prozessoren; bis 1.6.3 höchstens 8). Seit 1.6.4 (Entscheidung 41b) wird mehr als der Höchstwert
    mit einem Hinweis (einmal je Sitzung) begrenzt; wie ``.sl_nthreads`` in R. Seit 1.6.4 (Entscheidung 41c)
    zusätzlich je parallele Einheit höchstens ``_THREAD_CAP`` Threads, auch bei gesetztem ``SIMLEV_THREADS``."""
    n = env_threads()
    mx = nprocs()
    if n > mx:
        if not _THREADS_HINT[0]:
            _THREADS_HINT[0] = True
            from ._meldungen import EINGABE
            sys.stderr.write(EINGABE["hinweis.prozessoren"] % ("SIMLEV_THREADS", mx) + "\n")
        n = mx
    cap = _THREAD_CAP[0]
    if cap is not None:
        n = cap if n == 0 else min(n, cap)
    return n


def pt(q, df, lower_tail=True):
    return _apply(_ext.slc_pt_mt, q, float(df), bool(lower_tail), nthreads())


def qt(p, df, lower_tail=True):
    return _apply(_ext.slc_qt_mt, p, float(df), bool(lower_tail), nthreads())


def plogis(q):
    return _apply(_ext.slc_plogis, q)


def qlogis(p):
    return _apply(_ext.slc_qlogis, p)


# lineare Algebra, Matrixprodukt, kleinste Quadrate, Stineman, Spline, Kerndichte (_lib_linalg.py)
from ._lib_linalg import *  # noqa: E402,F401,F403
from ._lib_linalg import __all__ as _ALL_92  # noqa: E402

__all__ += _ALL_92
# Optimierer der C-Bibliothek slc (simlev/_lib_opt.py)
from ._lib_opt import minimize_test, numgrad_test, opt_testfn, optim  # noqa: E402

__all__ += ["optim", "opt_testfn", "minimize_test", "numgrad_test"]
# Modelle der C-Bibliothek slc (simlev/_lib_models.py)
from ._lib_models import *  # noqa: E402,F401,F403
from ._lib_models import __all__ as _ALL_94  # noqa: E402

__all__ += _ALL_94

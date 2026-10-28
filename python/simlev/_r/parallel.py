"""Nachbildung von SimLev's ``.par_lapply`` (``r/R/bootstrap.R``): ``parallel::mclapply``
mit ``mc.preschedule = FALSE`` und ``mc.set.seed = FALSE``.

Verhalten (ermittelt in Etappe 5, siehe ``python/DEVELOPING.md``):

- ``cores`` wird wie in ``mclapply`` ganzzahlig abgeschnitten; bei weniger als zwei Kernen
  oder höchstens einem Element ist es ``lapply`` (der Zufallsstrom läuft fortlaufend weiter).
- Sonst startet **jedes Element mit dem Zufallszustand des Aufrufers** (das Kind erbt
  ``.Random.seed`` beim Fork); danach ist der Zustand des Aufrufers unverändert.
- Ergebnisse in der Reihenfolge von ``X``; Warnungen der Elemente gehen wie in Kindprozessen
  verloren; was ein Element auf ``sys.stdout``/``sys.stderr`` schreibt, erscheint im
  Elternprozess in der Reihenfolge der Elemente (R: Reihenfolge der Fertigstellung).
- Fehler: Ausgaben der Elemente davor, dann der erste Fehler in Elementreihenfolge (wie die
  sequentielle Fassung; R liefert stattdessen ein ``try-error``-Element mit Warnung).

Echte Parallelität gibt es nur mit ``fork`` (Linux und andere Unix-Systeme außer macOS): je
Kern ein Kindprozess über ``multiprocessing`` (Kontext ``"fork"``), dynamische Zuteilung wie
``mc.preschedule = FALSE``. Die Arbeitsfunktion (meist eine Closure) liegt vor dem Fork in
``_JOB``; an die Kinder gehen nur Indizes, zurück kommen gepickelte Ergebnisse (bitgleich, auch
NA mit Nutzlast 1954 und -0). Lässt sich ein Ergebnis nicht pickeln (z. B. weil es eine Closure
enthält), rechnet der Elternprozess dieses Element selbst, mit demselben Zufallszustand. Auf
Plattformen ohne Fork (Windows, macOS mit Standard ``spawn``) rechnet ``par_lapply``
sequentiell mit derselben Semantik.
"""
from __future__ import annotations

import io
import os
import pickle
import sys
import warnings

from . import rng as _rng

__all__ = ["par_lapply", "fork_available", "rng_snapshot", "rng_reset"]

# Auftrag für die Kindprozesse: (X, FUN, Zufallszustand), gesetzt vor dem Fork.
_JOB = None


def fork_available() -> bool:
    """Echte Parallelität möglich? Nur mit ``fork``, nicht unter Windows und macOS."""
    if sys.platform.startswith(("win", "cygwin", "darwin")) or not hasattr(os, "fork"):
        return False
    import multiprocessing as mp
    return "fork" in mp.get_all_start_methods()


# ═══════════════════════════════════════════════════════════════════════════
# Zufallszustand des Aufrufers
# ═══════════════════════════════════════════════════════════════════════════

def rng_snapshot():
    """Zustand wie ``.Random.seed`` samt RNGkind (auch ohne ``.Random.seed``)."""
    has = _rng.has_random_seed()
    return (has, _rng.get_random_seed() if has else None, _rng._S.kind, _rng._S.n01, _rng._S.sample)


def rng_reset(snap) -> None:
    """Zustand aus :func:`rng_snapshot` wiederherstellen."""
    has, seed, kind, n01, smp = snap
    if has:
        _rng.set_random_seed(seed)
    else:
        _rng._S.kind, _rng._S.n01, _rng._S.sample = kind, n01, smp
        _rng.rm_random_seed()


# ═══════════════════════════════════════════════════════════════════════════
# par_lapply
# ═══════════════════════════════════════════════════════════════════════════

def _ncores(cores) -> int:
    """``as.integer(mc.cores)`` für ``cores > 1`` (R schneidet ab)."""
    return int(cores)


def par_lapply(X, FUN, cores=1):
    """Port von ``.par_lapply(X, FUN, cores)``; Ergebnis als Liste."""
    X = list(X)
    if cores is None or cores <= 1 or len(X) <= 1:
        return [FUN(x) for x in X]
    n = min(_ncores(cores), len(X))
    if n < 2:                                   # mclapply: cores < 2 -> lapply
        return [FUN(x) for x in X]
    if not fork_available():
        return _sequential(X, FUN)
    return _forked(X, FUN, n)


def _sequential(X, FUN):
    """Fork-Semantik nacheinander: jedes Element mit dem Zustand des Aufrufers."""
    snap = rng_snapshot()
    out = []
    try:
        for x in X:
            rng_reset(snap)
            with warnings.catch_warnings():
                warnings.simplefilter("ignore")
                out.append(FUN(x))
    finally:
        rng_reset(snap)
    return out


class _Rec:
    """Ausgaben eines Elements als Folge (Strom, Text), Strom 1 = stdout, 2 = stderr."""

    def __init__(self):
        self.chunks = []

    def add(self, k, s):
        if self.chunks and self.chunks[-1][0] == k:
            self.chunks[-1][1].append(s)
        else:
            self.chunks.append((k, [s]))

    def result(self):
        return [(k, "".join(p)) for k, p in self.chunks]


class _Stream(io.TextIOBase):
    def __init__(self, rec, k, like):
        self._rec, self._k = rec, k
        self._enc = getattr(like, "encoding", None) or "utf-8"

    @property
    def encoding(self):
        return self._enc

    def writable(self):
        return True

    def isatty(self):
        return False

    def write(self, s):
        s = str(s)
        self._rec.add(self._k, s)
        return len(s)

    def flush(self):
        pass


def _replay(chunks) -> None:
    for k, s in chunks:
        (sys.stdout if k == 1 else sys.stderr).write(s)
    if chunks:
        for f in (sys.stdout, sys.stderr):
            try:
                f.flush()
            except Exception:  # noqa: BLE001 - geschlossene oder exotische Ströme
                pass


def _run_one(X, FUN, snap, i):
    """Ein Element im Kind: (ok, Wert oder Ausnahme, Ausgaben)."""
    rec = _Rec()
    old = sys.stdout, sys.stderr
    sys.stdout, sys.stderr = _Stream(rec, 1, old[0]), _Stream(rec, 2, old[1])
    try:
        rng_reset(snap)
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            val, ok = FUN(X[i]), True
    except BaseException as e:  # noqa: BLE001 - wird im Elternprozess erneut geworfen
        val, ok = e, False
    finally:
        sys.stdout, sys.stderr = old
    return ok, val, rec.result()


def _dumps(i, ok, val, chunks) -> bytes:
    try:
        return pickle.dumps((i, ok, val, chunks), protocol=pickle.HIGHEST_PROTOCOL)
    except Exception:  # noqa: BLE001 - nicht pickelbar
        if ok:
            # Ergebnis nicht übertragbar: der Elternprozess rechnet das Element selbst
            return pickle.dumps((i, None, None, None), protocol=pickle.HIGHEST_PROTOCOL)
        err = RuntimeError(str(val)) if not isinstance(val, Exception) else _plain_error(val)
        return pickle.dumps((i, False, err, chunks), protocol=pickle.HIGHEST_PROTOCOL)


def _plain_error(e):
    """Nicht pickelbare Ausnahme als gleichnamige Standardausnahme mit gleichem Text."""
    for cls in (ValueError, TypeError, KeyError, IndexError, ArithmeticError, LookupError, RuntimeError):
        if isinstance(e, cls):
            try:
                out = cls(*e.args)
                pickle.dumps(out)
                return out
            except Exception:  # noqa: BLE001
                break
    return RuntimeError(str(e))


def _worker(conn) -> None:
    """Kindprozess: Indizes empfangen, Element rechnen, Ergebnis senden."""
    X, FUN, snap = _JOB
    try:
        while True:
            i = conn.recv()
            if i is None:
                break
            ok, val, chunks = _run_one(X, FUN, snap, i)
            conn.send_bytes(_dumps(i, ok, val, chunks))
    except (EOFError, BrokenPipeError, KeyboardInterrupt):
        pass
    finally:
        conn.close()


def _forked(X, FUN, n):
    global _JOB
    import multiprocessing as mp
    from multiprocessing.connection import wait as _wait

    snap = rng_snapshot()
    ctx = mp.get_context("fork")
    prev = _JOB
    _JOB = (X, FUN, snap)
    procs, active = [], {}
    nx = len(X)
    nxt = 0
    res = [None] * nx
    state = [0] * nx            # 0 offen, 1 fertig, 2 Fehler, 3 im Elternprozess rechnen
    outs = [None] * nx
    emitted = 0
    first_err = nx              # kleinster Index mit Fehler
    done = False
    try:
        with warnings.catch_warnings():
            # Python >= 3.12 warnt bei fork() in einem Prozess mit Threads (etwa BLAS)
            warnings.simplefilter("ignore", DeprecationWarning)
            for _ in range(n):
                pc, cc = ctx.Pipe(duplex=True)
                p = ctx.Process(target=_worker, args=(cc,), daemon=False)
                p.start()
                cc.close()
                procs.append((p, pc))
        for p, pc in procs:
            if nxt < nx:
                pc.send(nxt)
                active[pc] = (p, nxt)
                nxt += 1
        while active:
            for pc in _wait(list(active)):
                p, i = active.pop(pc)
                try:
                    data = pc.recv_bytes()
                except (EOFError, OSError):
                    raise RuntimeError("par_lapply: Prozess %d endete ohne Ergebnis (Element %d)"
                                       % (p.pid or -1, i + 1)) from None
                j, ok, val, chunks = pickle.loads(data)
                if ok is None:
                    state[j] = 3
                elif ok:
                    state[j], res[j], outs[j] = 1, val, chunks
                else:
                    state[j], res[j], outs[j] = 2, val, chunks
                    first_err = min(first_err, j)
                if nxt < min(nx, first_err):
                    pc.send(nxt)
                    active[pc] = (p, nxt)
                    nxt += 1
                else:
                    pc.send(None)
            # Ausgaben in Elementreihenfolge, sobald alle davor fertig sind
            while emitted < nx and state[emitted] in (1, 3) and emitted < first_err:
                if state[emitted] == 3:
                    res[emitted] = _in_parent(X, FUN, snap, emitted)
                else:
                    _replay(outs[emitted])
                    outs[emitted] = None
                emitted += 1
            if emitted == first_err and first_err < nx:
                _replay(outs[first_err])
                raise res[first_err]
        done = True
        return res
    finally:
        _JOB = prev
        for p, pc in procs:
            try:
                pc.close()
            except OSError:
                pass
        for p, pc in procs:
            if not done and p.is_alive():
                p.terminate()          # Abbruch: noch rechnende Kinder beenden
            p.join()
        rng_reset(snap)


def _in_parent(X, FUN, snap, i):
    """Element im Elternprozess rechnen (Ergebnis nicht pickelbar), Zustand wie im Kind."""
    try:
        rng_reset(snap)
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            return FUN(X[i])
    finally:
        rng_reset(snap)

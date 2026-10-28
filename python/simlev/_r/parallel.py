"""Nachbildung von SimLev's ``.par_lapply`` (``r/R/bootstrap.R``): ``parallel::mclapply``
mit ``mc.preschedule = FALSE`` und ``mc.set.seed = FALSE``.

Verhalten (ermittelt in Etappe 5, siehe ``python/DEVELOPING.md``; Zufall seit Etappe 9.6a):

- ``cores`` wird wie in ``mclapply`` ganzzahlig abgeschnitten; bei weniger als zwei Kernen
  oder höchstens einem Element ist es ``lapply``.
- Zufall (Entwurf C.5, Regeln 6, 7 und 10): Jede Einheit läuft als parallele Einheit
  (:func:`simlev._lib.in_unit`): der globale Zufallszustand von SimLev ist darin gesperrt, auch
  bei ``cores = 1``. Zufällige Einheiten bekommen ihren Strom als Argument; das Ergebnis hängt
  damit nicht von ``cores`` ab. Die frühere Sicherung und Wiederherstellung des
  R-Zufallszustands je Element entfällt.
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
enthält), rechnet der Elternprozess dieses Element selbst. Auf Plattformen ohne Fork (Windows,
macOS mit Standard ``spawn``) rechnet ``par_lapply`` sequentiell mit derselben Semantik.
"""
from __future__ import annotations

import io
import os
import pickle
import sys
import warnings

__all__ = ["par_lapply", "fork_available"]

# Auftrag für die Kindprozesse: (X, FUN), gesetzt vor dem Fork.
_JOB = None


def fork_available() -> bool:
    """Echte Parallelität möglich? Nur mit ``fork``, nicht unter Windows und macOS."""
    if sys.platform.startswith(("win", "cygwin", "darwin")) or not hasattr(os, "fork"):
        return False
    import multiprocessing as mp
    return "fork" in mp.get_all_start_methods()


def _unit(FUN, x):
    """``FUN(x)`` als parallele Einheit (Entwurf C.5, Regel 7: G gesperrt)."""
    from .. import _lib
    with _lib.in_unit():
        return FUN(x)


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
        return [_unit(FUN, x) for x in X]
    n = min(_ncores(cores), len(X))
    if n < 2:                                   # mclapply: cores < 2 -> lapply
        return [_unit(FUN, x) for x in X]
    if not fork_available():
        return _sequential(X, FUN)
    return _forked(X, FUN, n)


def _sequential(X, FUN):
    """Fork-Semantik nacheinander (Warnungen der Elemente gehen verloren)."""
    out = []
    for x in X:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            out.append(_unit(FUN, x))
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


def _run_one(X, FUN, i):
    """Ein Element im Kind: (ok, Wert oder Ausnahme, Ausgaben)."""
    rec = _Rec()
    old = sys.stdout, sys.stderr
    sys.stdout, sys.stderr = _Stream(rec, 1, old[0]), _Stream(rec, 2, old[1])
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            val, ok = _unit(FUN, X[i]), True
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
    X, FUN = _JOB
    try:
        while True:
            i = conn.recv()
            if i is None:
                break
            ok, val, chunks = _run_one(X, FUN, i)
            conn.send_bytes(_dumps(i, ok, val, chunks))
    except (EOFError, BrokenPipeError, KeyboardInterrupt):
        pass
    finally:
        conn.close()


def _forked(X, FUN, n):
    global _JOB
    import multiprocessing as mp
    from multiprocessing.connection import wait as _wait

    ctx = mp.get_context("fork")
    prev = _JOB
    _JOB = (X, FUN)
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
                    res[emitted] = _in_parent(X, FUN, emitted)
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


def _in_parent(X, FUN, i):
    """Element im Elternprozess rechnen (Ergebnis nicht pickelbar), wie im Kind."""
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        return _unit(FUN, X[i])

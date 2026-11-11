# Herkunft:           nachgebildet nach R 4.3.3, src/library/parallel/R/unix/mclapply.R (nur das
#                     Verhalten: Reihenfolge, Fehler, Ausgaben)
# Rechte:             The R Core Team, teils Robert Gentleman und Ross Ihaka, The R Foundation (laut
#                     Kopf der jeweiligen R-Quelle)
# Lizenz der Vorlage: GPL (>= 2) laut Kopf der R-Quellen; in SimLev unter GPL-3
# Änderungen:         Übertragung nach Python bzw. Julia (Julia nach der Python-Fassung) im von
#                     SimLev genutzten Umfang.
"""Nachbildung von SimLev's ``.par_lapply`` (``r/R/bootstrap.R``): ``parallel::mclapply``
mit ``mc.preschedule = FALSE`` und ``mc.set.seed = FALSE``.

Verhalten (siehe ``python/DEVELOPING.md``; Zufall seit 1.0.0):

- ``cores`` wird wie in ``mclapply`` ganzzahlig abgeschnitten; bei weniger als zwei Kernen
  oder höchstens einem Element ist es ``lapply``.
- Zufall: Jede Einheit läuft als parallele Einheit
  (:func:`simlev._lib.in_unit`): der globale Zufallszustand von SimLev ist darin gesperrt, auch
  bei ``cores = 1``. Zufällige Einheiten bekommen ihren Strom als Argument; das Ergebnis hängt
  damit nicht von ``cores`` ab. Die frühere Sicherung und Wiederherstellung des
  R-Zufallszustands je Element entfällt.
- Ergebnisse in der Reihenfolge von ``X``; was ein Element auf ``sys.stdout``/``sys.stderr`` schreibt und welche
  Warnungen es auslöst, erscheint im Elternprozess in der Reihenfolge der Elemente wie mit ``cores = 1`` (seit 1.6.4,
  Entscheidung 133, auch bei fester Zahl; bis dahin gingen Warnungen bei fester Zahl ≥ 2 verloren).
- Fehler: Ausgaben der Elemente davor, dann der erste Fehler in Elementreihenfolge (wie die
  sequentielle Fassung).

Echte Parallelität gibt es nur mit ``fork`` (Linux und andere Unix-Systeme außer macOS): je
Kern ein Kindprozess über ``multiprocessing`` (Kontext ``"fork"``), dynamische Zuteilung wie
``mc.preschedule = FALSE``. Die Arbeitsfunktion (meist eine Closure) liegt vor dem Fork in
``_JOB``; an die Kinder gehen nur Indizes, zurück kommen gepickelte Ergebnisse (bitgleich, auch
NA mit Nutzlast 1954 und -0). Lässt sich ein Ergebnis nicht pickeln (z. B. weil es eine Closure
enthält), rechnet der Elternprozess dieses Element selbst. Auf Plattformen ohne Fork (Windows,
macOS mit Standard ``spawn``) rechnet ``par_lapply`` nacheinander wie mit ``cores = 1``.
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
# letzter Plan von cores = "auto" (seit 1.6.4; intern, für Proben)
_PAR_LAST = [None]


def fork_available() -> bool:
    """Echte Parallelität möglich? Nur mit ``fork``, nicht unter Windows und macOS."""
    if sys.platform.startswith(("win", "cygwin", "darwin")) or not hasattr(os, "fork"):
        return False
    import multiprocessing as mp
    return "fork" in mp.get_all_start_methods()


def _unit(FUN, x):
    """``FUN(x)`` als parallele Einheit (globaler Zustand G gesperrt)."""
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
    """Gegenstück zu ``.par_lapply(X, FUN, cores)`` in R; Ergebnis als Liste. ``cores = "auto"`` (seit 1.6.4):
    :func:`_auto`. Eine feste Zahl ≥ 2 ist seit 1.6.5 (Entscheidungen 140, 179) der Höchstwert der automatischen
    Wahl: :func:`_auto` mit höchstens ``cores`` Läufen (1.6.4, Entscheidung 133: :func:`_forked` mit min(cores,
    Elemente) Kindern ohne Messung); ohne ``fork`` nacheinander wie ``cores = 1``."""
    X = list(X)
    if isinstance(cores, str) and cores == "auto":
        return _auto(X, FUN)
    if cores is None or cores <= 1 or len(X) <= 1:
        return [_unit(FUN, x) for x in X]
    n = min(_ncores(cores), len(X))
    if n < 2 or not fork_available():           # mclapply: cores < 2 -> lapply
        return [_unit(FUN, x) for x in X]
    return _auto(X, FUN, max_runs=_ncores(cores))


def _auto(X, FUN, max_runs=None):
    """``cores = "auto"`` (seit 1.6.4, Entscheidungen 41b/41c; wie R ``.par_lapply_auto``). Ergebnis, Ausgaben,
    Warnungen und Fehler wie ``cores = 1``:

    - Messen: die ersten Einheiten laufen nacheinander im Elternprozess, bis die Startzeit eines weiteren Laufs
      (:func:`simlev._lib.par_probe`) vergangen ist (mindestens zwei Einheiten); Rechenzeit je Einheit = Mittel ohne
      die erste (Anlaufkosten), bei nur einer Einheit deren Zeit; Ergebnisgröße je Einheit aus ``pickle`` von
      höchstens 8 gleichmäßig verteilten gemessenen Einheiten (seit K43 T2-B1).
    - Planen: :func:`simlev._lib.par_plan` (Kern ``sl_par_plan``) wählt Läufe c und Kern-Threads je Lauf; c = 1: der
      Rest nacheinander.
    - Verteilen (c > 1, nur mit ``fork``): :func:`_forked` mit Mitschnitt der Warnungen; die Kinder
      zeigen Warnungen nicht, der Elternprozess gibt sie mit Ausgaben in Elementreihenfolge wieder
      (``warnings.warn_explicit`` mit dem Register des auslösenden Moduls, also mit denselben Filtern und derselben
      Unterdrückung von Wiederholungen wie nacheinander).
    - Ohne ``fork`` (Windows, macOS) oder mit einem Prozessor: nacheinander.
    """
    import time
    from .. import _lib
    n = len(X)
    _PAR_LAST[0] = (n, 1, None)            # letzter Plan (gemessene Elemente, Läufe, Threads; intern, für Proben)
    if n <= 1 or _lib.nprocs() < 2 or not fork_available():
        return [_unit(FUN, x) for x in X]
    probe = _lib.par_probe(1)
    res = []
    k, t_first, t_rest = 0, 0.0, 0.0
    while True:
        t0 = time.perf_counter()
        res.append(_unit(FUN, X[k]))
        dt = time.perf_counter() - t0
        k += 1
        if k == 1:
            t_first = dt
        else:
            t_rest += dt
        if k >= n or (k >= 2 and t_first + t_rest >= probe):
            break
    if k >= n:
        return res
    u = t_rest / (k - 1) if k >= 2 else t_first
    # Ergebnisgröße je Einheit aus höchstens 8 gleichmäßig verteilten gemessenen Einheiten (seit 1.6.4, K43 T2-B1; bis
    # dahin aus allen gemessenen, bei vielen leichten Einheiten bis +51 % Laufzeit); ändert höchstens den Plan
    sel = res if k <= 8 else [res[(j * (k - 1)) // 7] for j in range(8)]
    try:
        ub = len(pickle.dumps(sel, protocol=pickle.HIGHEST_PROTOCOL)) / len(sel)
    except Exception:  # noqa: BLE001 - nicht pickelbar: Größe unbekannt
        ub = 0.0
    np_ = _lib.nprocs()
    c, cap = _lib.par_plan(n - k, u, ub, 1, nprocs_=np_, max_runs=np_ if max_runs is None else min(np_, int(max_runs)))
    _PAR_LAST[0] = (k, c, cap)
    if c < 2:
        res.extend(_unit(FUN, x) for x in X[k:])
        return res
    res.extend(_forked(X[k:], FUN, c, cap=cap))
    return res


class _Rec:
    """Ausgaben eines Elements als Folge (Strom, Text), Strom 1 = stdout, 2 = stderr; seit 1.6.4
    Strom 3 = Warnungen als Tupel (Warnung, Kategorie, Datei, Zeile), 4 = Hinweis zu SIMLEV_THREADS (Merker),
    5 = Änderung der Warnungsfilter (``warnings._filters_mutated``, etwa durch ``catch_warnings``)."""

    def __init__(self):
        self.chunks = []

    def add(self, k, s):
        if self.chunks and self.chunks[-1][0] == k:
            self.chunks[-1][1].append(s)
        else:
            self.chunks.append((k, [s]))

    def result(self):
        return [(k, p if k in (3, 5) else "".join(p)) for k, p in self.chunks]


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


def _warn_again(w) -> None:
    """Warnung eines Kinds im Elternprozess auslösen wie am Ort im Kind: Modul und Register aus der Datei
    (seit 1.6.4)."""
    message, category, filename, lineno = w
    mod = None
    for m in list(sys.modules.values()):
        if getattr(m, "__file__", None) == filename:
            mod = m
            break
    if mod is None:
        warnings.warn_explicit(message, category, filename, lineno)
    else:
        reg = mod.__dict__.setdefault("__warningregistry__", {})
        warnings.warn_explicit(message, category, filename, lineno, module=mod.__name__, registry=reg)


def _replay(chunks) -> None:
    for k, s in chunks:
        if k == 3:
            for w in s:
                _warn_again(w)
            continue
        if k == 5:                  # Filter im Kind geändert: Register der Wiederholungen wie dort leeren
            for _ in s:
                warnings._filters_mutated()
            continue
        (sys.stdout if k == 1 else sys.stderr).write(s)
    if chunks:
        for f in (sys.stdout, sys.stderr):
            try:
                f.flush()
            except Exception:  # noqa: BLE001 - geschlossene oder exotische Ströme
                pass


def _run_one(X, FUN, i):
    """Ein Element im Kind: (ok, Wert oder Ausnahme, Ausgaben). Seit 1.6.4 schneidet das Kind die Warnungen nach seinen
    Filtern (vom Elternprozess geerbt) mit, statt sie zu verwerfen (seit Entscheidung 133 auch bei fester Zahl)."""
    rec = _Rec()
    old = sys.stdout, sys.stderr
    sys.stdout, sys.stderr = _Stream(rec, 1, old[0]), _Stream(rec, 2, old[1])
    try:
        # catch_warnings leert beim Eintritt die Register der Wiederholungen im Kind; das Kind zeigt danach
        # nur Wiederholungen innerhalb des Elements nicht (wie nacheinander), Änderungen der Filter im Element
        # (Strom 5) gibt der Elternprozess an derselben Stelle weiter
        with warnings.catch_warnings():
            warnings.showwarning = (lambda message, category, filename, lineno, file=None, line=None:
                                    rec.add(3, (message, category, filename, lineno)))
            mutated = warnings._filters_mutated

            def _mutated():
                rec.add(5, "")
                mutated()
            warnings._filters_mutated = _mutated
            try:
                val, ok = _unit(FUN, X[i]), True
            finally:
                warnings._filters_mutated = mutated
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


def _worker(conn, parent, others) -> None:
    """Kindprozess: Block (erster Index, Anzahl) empfangen, Elemente der Reihe nach rechnen (nach einem Fehler im
    Block keine weiteren), Ergebnisse als eine Nachricht senden (seit 1.6.3; bis 1.6.2 je Element eine).

    Seit 1.6.4 (K43 T2-B4): das Kind endet mit dem Elternprozess ``parent`` (Kern ``sl_child_guard``, Linux), und es
    schließt die geerbten Elternenden ``others`` der Verbindungen (eigene und die der früher gestarteten Geschwister),
    damit kein Kind das Ende eines anderen offen hält."""
    from .. import _ext
    for q in others:
        try:
            q.close()
        except OSError:
            pass
    _ext.slc_child_guard(int(parent))
    X, FUN = _JOB
    from .. import _lib
    try:
        while True:
            blk = conn.recv()
            if blk is None:
                break
            i0, m = blk
            parts = []
            for i in range(i0, i0 + m):
                hint0 = _lib._THREADS_HINT[0]
                ok, val, chunks = _run_one(X, FUN, i)
                if not hint0 and _lib._THREADS_HINT[0]:
                    chunks = chunks + [(4, "")]       # Merker: Hinweis zu SIMLEV_THREADS in diesem Element
                parts.append(_dumps(i, ok, val, chunks))
                if not ok:
                    break
            conn.send_bytes(pickle.dumps(parts, protocol=pickle.HIGHEST_PROTOCOL))
    except (EOFError, BrokenPipeError, KeyboardInterrupt):
        pass
    finally:
        conn.close()


def _forked(X, FUN, n, cap=None):
    """Elemente auf ``n`` Kindprozesse (Fork), dynamisch in Blöcken zugeteilt; Wiedergabe in Elementreihenfolge. Seit
    1.6.4 für ``"auto"`` und feste Zahlen gleich (Entscheidung 133): Warnungen mitgeschnitten und im Elternprozess
    wieder ausgelöst, der Hinweis zu SIMLEV_THREADS an der Stelle wie nacheinander; bis dahin verwarf eine feste Zahl
    die Warnungen (Schalter ``record``). ``cap``: Kern-Threads je Kind (Plan von ``"auto"``), sonst
    Prozessoren // n."""
    global _JOB
    import multiprocessing as mp
    from multiprocessing.connection import wait as _wait

    from .. import _lib
    from .._meldungen import EINGABE
    ctx = mp.get_context("fork")
    prev = _JOB
    _JOB = (X, FUN)
    # Kern-Threads je Kind (seit 1.6.4, Entscheidung 41c): Prozessoren // Kinder, mindestens 1 (cores = "auto": aus dem
    # Plan); der Hinweis zu SIMLEV_THREADS erscheint höchstens einmal je Sitzung, bei der Wiedergabe an der Stelle wie
    # nacheinander (_replay_unit)
    prev_cap = _lib._THREAD_CAP[0]
    _lib._THREAD_CAP[0] = _lib.unit_threads(n) if cap is None else int(cap)
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
        # Python >= 3.12 warnt bei fork() in einem Prozess mit Threads (etwa BLAS); ohne catch_warnings, das die
        # Register der Wiederholungen im Elternprozess leeren würde (die Standardfilter zeigen DeprecationWarning aus
        # multiprocessing ohnehin nicht; seit 1.6.4 auch bei fester Zahl, bis dahin dort unterdrückt)
        parent = os.getpid()
        for _ in range(n):
            pc, cc = ctx.Pipe(duplex=True)
            p = ctx.Process(target=_worker, args=(cc, parent, [q for _, q in procs] + [pc]), daemon=False)
            p.start()
            cc.close()
            procs.append((p, pc))
        # Blöcke aufeinanderfolgender Elemente (seit 1.6.3): etwa 8 Blöcke je Kern, höchstens 16 Elemente je
        # Block; Zuteilung weiter dynamisch, Reihenfolge, Ausgaben und Fehlerregel wie je Element
        bs = max(1, min(16, nx // (8 * n)))

        def send_next(pc, p):
            nonlocal nxt
            if nxt < min(nx, first_err):
                m = min(bs, nx - nxt, first_err - nxt)
                pc.send((nxt, m))
                active[pc] = (p, nxt)
                nxt += m
                return True
            return False

        for p, pc in procs:
            send_next(pc, p)
        while active:
            for pc in _wait(list(active)):
                p, i = active.pop(pc)
                try:
                    data = pc.recv_bytes()
                except (EOFError, OSError):
                    # Kind ohne Ergebnis (seit 1.6.4, K43 T2-R4): Fehler am Anfang seines Blocks, gemeldet in
                    # Elementreihenfolge wie die übrigen Fehler (frühere zuerst), Text aus der Tabelle wie in R (bis
                    # dahin sofort "par_lapply: Prozess <pid> endete ohne Ergebnis (Element k)")
                    state[i], res[i], outs[i] = 2, RuntimeError(EINGABE["ut2.prozess"] % "par_lapply"), []
                    first_err = min(first_err, i)
                    continue
                for part in pickle.loads(data):
                    j, ok, val, chunks = pickle.loads(part)
                    if ok is None:
                        state[j] = 3
                    elif ok:
                        state[j], res[j], outs[j] = 1, val, chunks
                    else:
                        state[j], res[j], outs[j] = 2, val, chunks
                        first_err = min(first_err, j)
                if not send_next(pc, p):
                    pc.send(None)
            # Ausgaben in Elementreihenfolge, sobald alle davor fertig sind
            while emitted < nx and state[emitted] in (1, 3) and emitted < first_err:
                if state[emitted] == 3:
                    res[emitted] = _in_parent(X, FUN, emitted)
                else:
                    _replay_unit(outs[emitted])
                    outs[emitted] = None
                emitted += 1
            if emitted == first_err and first_err < nx:
                _replay_unit(outs[first_err])
                raise res[first_err]
        done = True
        return res
    finally:
        _JOB = prev
        _lib._THREAD_CAP[0] = prev_cap
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
    """Element im Elternprozess rechnen (Ergebnis nicht pickelbar), mit Warnungen wie nacheinander."""
    return _unit(FUN, X[i])


def _replay_unit(chunks) -> None:
    """Ausgaben eines Elements wiedergeben; der Hinweis zu SIMLEV_THREADS (Merker 4 des Kinds) höchstens einmal je
    Sitzung wie nacheinander."""
    if chunks and chunks[-1][0] == 4:
        from .. import _lib
        from .._meldungen import EINGABE
        chunks = chunks[:-1]
        if _lib._THREADS_HINT[0]:
            hint = EINGABE["hinweis.prozessoren"] % ("SIMLEV_THREADS", _lib.nprocs()) + "\n"
            out, done = [], False
            for k, s in chunks:
                if not done and k == 2 and hint in s:
                    s, done = s.replace(hint, "", 1), True
                out.append((k, s))
            chunks = out
        else:
            _lib._THREADS_HINT[0] = True
    _replay(chunks)

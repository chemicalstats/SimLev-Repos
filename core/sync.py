#!/usr/bin/env python3
"""core/sync.py – Kopien der Kernquellen abgleichen (bis 1.4.0 ``core_sync.py``).

Kanonisch sind die Dateien in ``core/`` (nur dort ändern). Die Pakete bauen nur aus ihrem
Teilbaum und bekommen daher Byte-für-Byte-Kopien:

* Bibliothek slc (``core/slc*.cpp``, ``core/slc*.h``; seit 1.6.0 C++, bis 1.5.2 ``slc*.c``) nach

      r/src/             (flach; R übersetzt nur die oberste Ebene von src/)
      python/src/core/
      julia/deps/core/

* geteilte C++-Kerne (``core/simlev_core.h`` und ``core/*_core_impl.h``: Tagesengine mit Vorbereitung
  und Auswertung, Tarif, Research, Entnahme) nach ``r/src/``, ``python/src/core/`` und ``julia/deps/core/``;
* die C-ABI-Hülle der geteilten Kerne für Julia (``core/simlev_cabi.cpp``) nur nach
  ``julia/deps/core/``;
* die Grundfunktionen mit R-Regeln (``core/slc_rbase*``) nur nach ``python/src/core/`` und
  ``julia/deps/core/`` (R rechnet sie selbst); auch nach ``r/src/`` nur ``slc_rbase.cpp`` und ``slc_rbase.h``
  (``sl_r_sum`` und ``sl_r_zeroin2`` für Tagesengine und Auswertung von ``simulation()``, seit 1.6.4 ``sl_r_approx``)
  und seit 1.6.4 (C-035) ``slc_rbase2.h``, ``slc_rbase_cov.cpp``, ``slc_rbase_smooth.cpp`` und
  ``slc_rbase_clust.cpp`` (cov/cor/var/sd, filter, dist, hclust in R über die Kerne, ``r/R/slc_stats.R``).

Aufruf::

    python3 core/sync.py --write   # kopieren (nur geänderte), veraltete slc*-Kopien entfernen (auch slc*.c bis 1.5.2)
    python3 core/sync.py --check   # SHA-256-Vergleich; Ende 1 bei Abweichung

``--check`` prüft zusätzlich, dass ``core/slc_constants.h`` dem Stand von
``core/gen_constants.py`` entspricht und (seit 1.6.0) die Meldungstabellen ``r/R/meldungen.R``,
``python/simlev/_meldungen.py`` und ``julia/src/meldungen.jl`` dem Stand von ``core/meldungen.tsv``
(``core/gen_meldungen.py --check``; ``--write`` schreibt sie) und (seit 1.6.1), dass ``r/src/Makevars`` und
``Makevars.win`` für jede ``.cpp``-Datei in ``r/src/`` eine eigene Regel mit den Gleitkomma-Schaltern haben. Nur
Standardbibliothek.
"""
from __future__ import annotations

import argparse
import hashlib
import os
import shutil
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
CORE = os.path.join(ROOT, "core")
TARGETS = [os.path.join(ROOT, "r", "src"), os.path.join(ROOT, "python", "src", "core"),
           os.path.join(ROOT, "julia", "deps", "core")]
# geteilte Kerne (is_shared): alle drei Ziele; C-ABI-Hülle der geteilten Kerne: nur Julia
CABI_TARGETS = TARGETS[2:]
# früherer Ort der Python-Kopien der geteilten Kerne (vor 1.0.0 python/src/): dort darf keine mehr liegen
OLD_SHARED = [os.path.join(ROOT, "python", "src")]


def is_slc(f: str) -> bool:
    return f.startswith("slc") and f.endswith((".cpp", ".h"))


def is_old_c(f: str) -> bool:
    """C-Quellen bis 1.5.2 (slc*.c): seit 1.6.0 C++ (slc*.cpp); im Ziel und in core/ veraltet."""
    return f.startswith("slc") and f.endswith(".c")


# rbase-Dateien, die auch nach r/src/ gehen: slc_rbase.cpp/.h (sl_r_sum für die Summen der Tagesengine,
# core/engine_core_impl.h) und seit 1.6.4 (C-035) die Kerne der Statistikwege von R (r/R/slc_stats.R)
R_RBASE = ("slc_rbase.cpp", "slc_rbase.h", "slc_rbase2.h", "slc_rbase_cov.cpp", "slc_rbase_smooth.cpp",
           "slc_rbase_clust.cpp")


def is_rbase(f: str) -> bool:
    """Grundfunktionen mit R-Regeln (slc_rbase*) nur für Python und Julia; R rechnet sie selbst.
    Ausnahmen (auch nach r/src/): R_RBASE."""
    return f.startswith("slc_rbase") and f not in R_RBASE


def is_shared(f: str) -> bool:
    """Geteilter Kern (simlev_core.h, *_core_impl.h)."""
    return f == "simlev_core.h" or f.endswith("_core_impl.h")


def is_cabi(f: str) -> bool:
    """C-ABI-Hülle der geteilten Kerne (nur Julia)."""
    return f == "simlev_cabi.cpp"


def canonical() -> list[str]:
    return sorted(f for f in os.listdir(CORE)
                  if (is_slc(f) or is_shared(f) or is_cabi(f)) and os.path.isfile(os.path.join(CORE, f)))


def files_for(target: str, files: list[str]) -> list[str]:
    return [f for f in files if (is_slc(f) and not (is_rbase(f) and target == TARGETS[0]))
            or is_shared(f)
            or (is_cabi(f) and target in CABI_TARGETS)]


def sha(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        h.update(fh.read())
    return h.hexdigest()


def stale(target: str, files: list[str]) -> list[str]:
    """slc*-Dateien bzw. geteilte Kerne im Ziel, die es in core/ nicht gibt (Hüllen wie slc_r.cpp
    ausgenommen), und C-Quellen slc*.c bis 1.5.2."""
    if not os.path.isdir(target):
        return []
    keep = set(files) | {"slc_r.cpp"}
    keep |= {"slc_r_linalg.cpp"}  # R-Hülle der linearen Algebra (nur in r/src/)
    keep |= {"slc_r_opt.cpp"}   # R-Hülle der Optimierer (nur in r/src/)
    keep |= {"slc_r_models.cpp"}   # R-Hülle der Modelle (nur in r/src/)
    keep |= {"slc_r_stats.cpp"}    # R-Hülle der Statistikwege (nur in r/src/, seit 1.6.4)
    return sorted(f for f in os.listdir(target)
                  if (is_slc(f) or is_old_c(f) or is_shared(f) or is_cabi(f)) and f not in keep)


def check_makevars() -> int:
    """Je .cpp in r/src/ eine Regel ``x.o: x.cpp`` mit ``$(SIMLEV_CXXFLAGS)`` in Makevars und Makevars.win (seit 1.6.1)."""
    d = os.path.join(ROOT, "r", "src")
    srcs = sorted(f for f in os.listdir(d) if f.endswith(".cpp"))
    bad = 0
    for mk in ("Makevars", "Makevars.win"):
        txt = open(os.path.join(d, mk), encoding="utf-8").read()
        for f in srcs:
            o = f[:-4] + ".o"
            if "%s: %s\n\t$(CXX) $(ALL_CPPFLAGS) $(ALL_CXXFLAGS) $(SIMLEV_CXXFLAGS) -c %s -o %s" % (o, f, f, o) not in txt:
                print("core_sync: r/src/%s: keine Regel für %s" % (mk, f))
                bad += 1
    return bad


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--write", action="store_true")
    g.add_argument("--check", action="store_true")
    a = ap.parse_args(argv)
    files = canonical()
    bad = 0
    if a.check:
        r = subprocess.run([sys.executable, os.path.join(CORE, "gen_constants.py"), "--check"],
                           capture_output=True, text=True)
        if r.returncode != 0:
            print("core_sync: core/slc_constants.h ist nicht aktuell (gen_constants.py --check)")
            bad += 1
    r = subprocess.run([sys.executable, os.path.join(CORE, "gen_meldungen.py")] + (["--check"] if a.check else []),
                       capture_output=True, text=True)
    if a.write and r.stdout:
        print(r.stdout, end="")
    if r.returncode != 0:
        print("core_sync: Meldungstabellen nicht aktuell (core/gen_meldungen.py; aus core/meldungen.tsv)")
        print(r.stdout + r.stderr, end="")
        bad += 1
    n = 0
    for t in TARGETS:
        rel = os.path.relpath(t, ROOT)
        if a.write:
            os.makedirs(t, exist_ok=True)
        own = files_for(t, files)
        n += len(own)
        for f in own:
            src, dst = os.path.join(CORE, f), os.path.join(t, f)
            same = os.path.isfile(dst) and sha(src) == sha(dst)
            if a.write and not same:
                shutil.copyfile(src, dst)
                print("core_sync: %s/%s kopiert" % (rel, f))
            elif a.check and not same:
                print("core_sync: %s/%s %s" % (rel, f, "weicht ab" if os.path.isfile(dst) else "fehlt"))
                bad += 1
        for f in stale(t, own):
            if a.write:
                os.remove(os.path.join(t, f))
                print("core_sync: %s/%s entfernt (nicht in core/)" % (rel, f))
            else:
                print("core_sync: %s/%s ist nicht in core/" % (rel, f))
                bad += 1
    for t in OLD_SHARED:
        rel = os.path.relpath(t, ROOT)
        for f in sorted(os.listdir(t)) if os.path.isdir(t) else []:
            if is_shared(f) and os.path.isfile(os.path.join(t, f)):
                if a.write:
                    os.remove(os.path.join(t, f))
                    print("core_sync: %s/%s entfernt (alter Ort, jetzt python/src/core/)" % (rel, f))
                else:
                    print("core_sync: %s/%s am alten Ort (jetzt python/src/core/)" % (rel, f))
                    bad += 1
    if a.check:
        bad += check_makevars()
        print("core_sync: %d Kopien geprüft, %s" % (n, "alle gleich" if bad == 0 else "%d Abweichungen" % bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())

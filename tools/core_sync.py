#!/usr/bin/env python3
"""tools/core_sync.py – Kopien der C-Quellen abgleichen (Etappe 9, Entwurf C.1, F16).

Kanonisch sind die Dateien in ``core/`` (nur dort ändern). Die Pakete bauen nur aus ihrem
Teilbaum und bekommen daher Byte-für-Byte-Kopien:

* C-Bibliothek slc (``core/slc*.c``, ``core/slc*.h``) nach

      r/src/             (flach; R übersetzt nur die oberste Ebene von src/)
      python/src/core/
      julia/deps/core/

* geteilte Kerne (seit Etappe 9.6c: ``core/simlev_core.h`` und ``core/*_core_impl.h``: Engine, FIFO,
  Steuer, Research, Entnahme) nach ``r/src/``, ``python/src/core/`` und (seit N7) ``julia/deps/core/``;
* die C-ABI-Hülle der geteilten Kerne für Julia (N7: ``core/simlev_cabi.cpp``) nur nach
  ``julia/deps/core/``;
* die Grundfunktionen mit R-Regeln (N8: ``core/slc_rbase*``) nur nach ``python/src/core/`` und
  ``julia/deps/core/`` (R rechnet sie selbst); seit E17 ``slc_rbase.c`` und ``slc_rbase.h`` auch nach
  ``r/src/`` (``sl_r_sum`` für die Tagesengine ``core/engine_core_impl.h``).

Aufruf::

    python3 tools/core_sync.py --write   # kopieren (nur geänderte), veraltete slc*-Kopien entfernen
    python3 tools/core_sync.py --check   # SHA-256-Vergleich; Ende 1 bei Abweichung

``--check`` prüft zusätzlich, dass ``core/slc_constants.h`` dem Stand von
``core/tools/gen_constants.py`` entspricht. Nur Standardbibliothek.
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
# geteilte Kerne (9.6c, F16): R und Python, seit N7 auch Julia
SHARED_TARGETS = TARGETS
# C-ABI-Hülle der geteilten Kerne (N7): nur Julia
CABI_TARGETS = TARGETS[2:]
# frühere Orte der Python-Kopien der geteilten Kerne (bis 9.6c python/src/): dort darf keine mehr liegen
OLD_SHARED = [os.path.join(ROOT, "python", "src")]


def is_slc(f: str) -> bool:
    return f.startswith("slc") and f.endswith((".c", ".h"))


def is_rbase(f: str) -> bool:
    """N8: Grundfunktionen mit R-Regeln (slc_rbase*) nur für Python und Julia; R rechnet sie selbst.
    Ausnahme E17: slc_rbase.c/.h (sl_r_sum für die Summen der Tagesengine, core/engine_core_impl.h)
    gehen auch nach r/src/."""
    return f.startswith("slc_rbase") and f not in ("slc_rbase.c", "slc_rbase.h")


def is_shared(f: str) -> bool:
    """Geteilter Kern (simlev_core.h, *_core_impl.h)."""
    return f == "simlev_core.h" or f.endswith("_core_impl.h")


def is_cabi(f: str) -> bool:
    """C-ABI-Hülle der geteilten Kerne (N7, nur Julia)."""
    return f == "simlev_cabi.cpp"


def canonical() -> list[str]:
    return sorted(f for f in os.listdir(CORE)
                  if (is_slc(f) or is_shared(f) or is_cabi(f)) and os.path.isfile(os.path.join(CORE, f)))


def files_for(target: str, files: list[str]) -> list[str]:
    return [f for f in files if (is_slc(f) and not (is_rbase(f) and target == TARGETS[0]))
            or (is_shared(f) and target in SHARED_TARGETS)
            or (is_cabi(f) and target in CABI_TARGETS)]


def sha(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        h.update(fh.read())
    return h.hexdigest()


def stale(target: str, files: list[str]) -> list[str]:
    """slc*-Dateien bzw. geteilte Kerne im Ziel, die es in core/ nicht gibt (Hüllen wie slc_r.c
    ausgenommen)."""
    if not os.path.isdir(target):
        return []
    keep = set(files) | {"slc_r.c"}
    keep |= {"slc_r_linalg.c"}  # 9.2: R-Huelle der Etappe 9.2 (keine Kopie aus core/)

    keep |= {"slc_r_opt.c"}   # 9.3: R-Hülle der Optimierer (nur in r/src/)
    keep |= {"slc_r_models.c"}   # 9.4: R-Hülle der Modelle (nur in r/src/)
    return sorted(f for f in os.listdir(target)
                  if (is_slc(f) or is_shared(f) or is_cabi(f)) and f not in keep)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--write", action="store_true")
    g.add_argument("--check", action="store_true")
    a = ap.parse_args(argv)
    files = canonical()
    bad = 0
    if a.check:
        r = subprocess.run([sys.executable, os.path.join(CORE, "tools", "gen_constants.py"), "--check"],
                           capture_output=True, text=True)
        if r.returncode != 0:
            print("core_sync: core/slc_constants.h ist nicht aktuell (gen_constants.py --check)")
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
        print("core_sync: %d Kopien geprüft, %s" % (n, "alle gleich" if bad == 0 else "%d Abweichungen" % bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())

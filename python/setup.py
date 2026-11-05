"""Bau der C++-Erweiterung ``simlev._ext`` (ein Modul für alle Kerne).

Alle übrigen Angaben stehen in ``pyproject.toml``. Seit 1.0.0 ist die Erweiterung
Pflicht (``optional=False``): Sie enthält die Bibliothek slc (Zufall,
Verteilungen), die es nur im Kern gibt. Ohne C++-Compiler scheitert die Installation mit der
Meldung von setuptools. Seit 1.0.0 gibt es auch keine reinen Python-Kerne als Rückfall
mehr (kein Schalter ``SIMLEV_NO_EXT``).

Quellen (seit 1.6.0 nur C++; bis 1.5.2 slc und ihre Hüllen in C99): die Bibliothek slc
``src/core/slc*.{cpp,h}``, die geteilten Kerne ``src/core/*_core_impl.h`` und
``src/core/simlev_core.h`` sind Byte-für-Byte-Kopien der kanonischen Dateien in ``core/``
(``core/sync.py --check``); die Python-Hüllen ``src/_ext*.cpp`` gibt es nur hier. Die
früheren Kerne mit R-Zufall, die C-Übernahmen und die C-Nachbildung von R's Zufall
(``_rng_r.c``) sind seit 1.0.0 entfallen.

Gleitkomma-Einstellungen wie in den Builds von R und Julia, für alle Dateien gleich:
``-std=gnu++17 -O2 -ffp-contract=off -fno-fast-math`` (R: ``CXX_STD = CXX17``, ``-O2`` über
``CXXFLAGS``, die übrigen in ``r/src/Makevars``); kein Zusammenziehen zu fma (die geteilten
Kerne setzen dafür unter GCC ein Pragma nur dort, wo fma erzeugt werden kann, und lassen es mit
``SIMLEV_FP_CONTRACT_BY_FLAG`` weg); unter MSVC ``/O2 /fp:precise /std:c++17`` (zu prüfen: ob
MSVC unter ``/fp:precise`` zusammenzieht, sonst ``/fp:contract-``). Wie R ohne ``-fwrapv``:
Python übersetzt Erweiterungen mit ``-fno-strict-overflow`` (= ``-fwrapv``);
``-fstrict-overflow`` (sofern der Compiler es kennt) stellt die Übersetzung der Schleifen
wie in R her (Engine-Kerne). Threads (``SLC_THREADS``) für die parallelen Starts des
MS-GARCH-Fits außer unter Windows (wie ``r/src/Makevars``).
"""
import glob
import os
import sys

from setuptools import Extension, setup
from setuptools.command.build_ext import build_ext

_GNU_FLAGS = ("-O2", "-fno-fast-math", "-ffp-contract=off")   # unix und mingw32 gleich (seit 1.6.3 einmal)
FLAGS = {"unix": list(_GNU_FLAGS), "mingw32": list(_GNU_FLAGS), "msvc": ["/O2", "/fp:precise"]}
CXX_FLAGS = {"unix": ["-std=gnu++17"], "mingw32": ["-std=gnu++17"], "msvc": ["/std:c++17"]}

_HERE = os.path.dirname(os.path.abspath(__file__))
# Gemeinsame Kerne von R und Python (Kopien aus core/ in src/core/, nur Header; die Huellen
# binden sie ein, siehe core/simlev_core.h). Seit 1.6.3 alle src/core/*_core_impl.h ueber glob (bis 1.6.2 eine
# Liste ohne wrapper_core_impl.h: build_ext baute nach einer Aenderung nur dieser Datei nicht neu)
SHARED_HEADERS = ["core/simlev_core.h"] + sorted(
    os.path.relpath(f, os.path.join(_HERE, "src")).replace(os.sep, "/")
    for f in glob.glob(os.path.join(_HERE, "src", "core", "*_core_impl.h")))
# Python-Huellen (nur hier): geteilte Kerne und Bibliothek slc (Zufall und Verteilungen, lineare
# Algebra, Optimierer, Modelle, Grundfunktionen mit R-Regeln aus core/slc_rbase*)
WRAPPERS = ["_ext.cpp", "_ext_research.cpp", "_ext_withdrawal.cpp", "_ext_engine.cpp",
            "_ext_slc.cpp", "_ext_slc_linalg.cpp", "_ext_slc_opt.cpp", "_ext_slc_models.cpp",
            "_ext_slc_rbase.cpp", "_ext_slc_rbase2.cpp",
            "_ext_slc_prep.cpp"]   # seit 1.6.0: Kerne fuer Wirtsfunktionen (core/slc_prep.h), Brent fmin
# Bibliothek slc: Kopien aus core/
SLC = sorted(os.path.relpath(f, os.path.join(_HERE, "src")).replace(os.sep, "/")
             for f in glob.glob(os.path.join(_HERE, "src", "core", "slc*.cpp")))
SLC_HEADERS = sorted(os.path.relpath(f, os.path.join(_HERE, "src")).replace(os.sep, "/")
                     for f in glob.glob(os.path.join(_HERE, "src", "core", "slc*.h")))
HEADERS = SHARED_HEADERS + ["_ext_common.h", "_ext_slc_hull.h"] + SLC_HEADERS


# wie R ohne -fwrapv, nur wenn der Compiler die Option ohne Warnung annimmt; seit 1.6.1 außerdem Sprünge nicht über
# 32-Byte-Grenzen (GNU as; Intel-JCC-Erratum: sonst schwankt die Laufzeit der Kerne je nach Lage im Code um bis zu
# 30 %; ändert nur die Auffüllung, nicht die Befehle), ebenfalls nur, wenn der Assembler die Option kennt
OPTIONAL_FLAGS = {"unix": ["-fstrict-overflow", "-Wa,-mbranches-within-32B-boundaries"],
                  "mingw32": ["-fstrict-overflow"]}


def _accepts(compiler, flag):
    """Übersetzt eine leere Datei mit ``flag`` (und ``-Werror``); True, wenn das gelingt."""
    import tempfile
    with tempfile.TemporaryDirectory() as d:
        src = os.path.join(d, "probe.cpp")
        with open(src, "w") as fh:
            fh.write("int simlev_probe() { return 0; }\n")
        try:
            compiler.compile([src], output_dir=d, extra_postargs=[flag, "-Werror"])
        except Exception:      # noqa: BLE001 (CompileError und Verwandte)
            return False
    return True


class BuildExt(build_ext):
    """Setzt die Gleitkomma-Flags und ``-std=gnu++17`` passend zum Compiler (alle Quellen C++)."""

    def build_extensions(self):
        ctype = self.compiler.compiler_type
        extra = FLAGS.get(ctype, []) + [f for f in OPTIONAL_FLAGS.get(ctype, []) if _accepts(self.compiler, f)]
        cxx = CXX_FLAGS.get(ctype, [])
        for ext in self.extensions:
            ext.extra_compile_args = list(ext.extra_compile_args or []) + extra + cxx
        super().build_extensions()


setup(
    ext_modules=[
        Extension(
            "simlev._ext",
            sources=["src/" + f for f in WRAPPERS + SLC],
            depends=["src/" + f for f in HEADERS],
            include_dirs=["src"],
            # Gleitkomma ueber die Flags (-ffp-contract=off); das Pragma der Kerndateien entfaellt
            # außer unter Windows mit Threads für die parallelen Starts des MS-GARCH-Fits (wie r/src/Makevars)
            define_macros=[("SIMLEV_FP_CONTRACT_BY_FLAG", "1")] + ([] if sys.platform == "win32" else [("SLC_THREADS", "1")]),
            language="c++",
            libraries=[] if sys.platform == "win32" else ["m", "pthread"],   # exp, log aus der libm; pthread
            optional=False,     # Pflicht seit 1.0.0 (Bibliothek slc)
        )
    ],
    cmdclass={"build_ext": BuildExt},
)

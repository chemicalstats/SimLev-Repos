"""Bau der C/C++-Erweiterung ``simlev._ext`` (Etappe 7.2, seit 7.3a ein Modul für alle Kerne).

Alle übrigen Angaben stehen in ``pyproject.toml``. Seit Etappe 9.1 ist die Erweiterung
Pflicht (``optional=False``, Entwurf C.2): Sie enthält die C-Bibliothek slc (Zufall,
Verteilungen), die es nur in C gibt. Ohne C-Compiler scheitert die Installation mit der
Meldung von setuptools. Seit Etappe 9.6c gibt es auch keine reinen Python-Kerne als Rückfall
mehr (kein Schalter ``SIMLEV_NO_EXT``).

Quellen der C-Bibliothek slc: ``src/core/slc*.{c,h}`` sind Byte-für-Byte-Kopien der
kanonischen Dateien in ``core/`` (``tools/core_sync.py --check``), die Hülle
``src/_ext_slc.c`` gibt es nur hier.

Quellen: die geteilten Kerne ``src/core/*_core_impl.h`` und ``src/core/simlev_core.h`` sind
seit Etappe 9.6c (F16) ebenfalls Byte-für-Byte-Kopien der kanonischen Dateien in ``core/``
(``tools/core_sync.py --check``); die Python-Hüllen ``src/_ext*.cpp`` gibt es nur hier. Die
früheren Kerne mit R-Zufall, die C-Übernahmen und die C-Nachbildung von R's Zufall
(``_rng_r.c``) sind mit Etappe 9.6c entfallen.

Gleitkomma-Einstellungen wie im R-Paket: ``-O2`` (R: ``R CMD config CFLAGS`` bzw.
``CXXFLAGS``), kein ``-ffast-math``, kein Zusammenziehen zu fma
(``-ffp-contract=off``; die Kerndateien setzen dafuer unter GCC ein Pragma nur dort,
wo fma erzeugt werden kann, und lassen es mit ``SIMLEV_FP_CONTRACT_BY_FLAG`` weg); C++
wie R mit ``-std=gnu++17``; die C-Bibliothek slc wie R (``r/src/Makevars``) mit ``-std=c99``
(Etappe 9.1, gleiche Flags in allen drei Builds: ``-O2 -std=c99 -ffp-contract=off -fno-fast-math``;
die übrigen C-Dateien unverändert); unter
MSVC ``/O2 /fp:precise /std:c++17`` (zu prüfen: ob MSVC unter ``/fp:precise`` zusammenzieht,
sonst ``/fp:contract-``). Wie R ohne
``-fwrapv``: Python übersetzt Erweiterungen mit ``-fno-strict-overflow`` (= ``-fwrapv``);
``-fstrict-overflow`` (sofern der Compiler es kennt) stellt die Übersetzung der Schleifen
wie in R her (Etappe 7.3a, Engine-Kerne).
"""
import glob
import os
import sys

from setuptools import Extension, setup
from setuptools.command.build_ext import build_ext

FLAGS = {
    "unix": ["-O2", "-fno-fast-math", "-ffp-contract=off"],
    "mingw32": ["-O2", "-fno-fast-math", "-ffp-contract=off"],
    "msvc": ["/O2", "/fp:precise"],
}
CXX_FLAGS = {"unix": ["-std=gnu++17"], "mingw32": ["-std=gnu++17"], "msvc": ["/std:c++17"]}
C_FLAGS = {"unix": ["-std=c99"], "mingw32": ["-std=c99"], "msvc": []}

# Gemeinsame Kerne von R und Python (Kopien aus core/ in src/core/, nur Header; die Huellen
# binden sie ein, siehe core/simlev_core.h)
SHARED_HEADERS = ["core/simlev_core.h", "core/research_core_impl.h", "core/withdrawal_core_impl.h",
                  "core/simulation_core_impl.h", "core/fifo_core_impl.h", "core/tax_core_impl.h"]
# Python-Huellen (nur hier)
WRAPPERS = ["_ext.cpp", "_ext_research.cpp", "_ext_withdrawal.cpp", "_ext_engine.cpp"]
# C-Bibliothek slc (Etappe 9.1): Kopien aus core/ und die Hülle _ext_slc.c
_HERE = os.path.dirname(os.path.abspath(__file__))
SLC = sorted(os.path.relpath(f, os.path.join(_HERE, "src")).replace(os.sep, "/")
             for f in glob.glob(os.path.join(_HERE, "src", "core", "slc*.c")))
SLC_HEADERS = sorted(os.path.relpath(f, os.path.join(_HERE, "src")).replace(os.sep, "/")
                     for f in glob.glob(os.path.join(_HERE, "src", "core", "slc*.h")))
SLC_WRAPPERS = ["_ext_slc.c"]
# 9.2: Hülle der Etappe 9.2 (lineare Algebra, Matrixprodukt, kleinste Quadrate, Stineman, Spline, Kerndichte)
SLC_WRAPPERS += ["_ext_slc_linalg.c"]
SLC_WRAPPERS += ["_ext_slc_opt.c"]   # 9.3: Hülle der Optimierer
SLC_WRAPPERS += ["_ext_slc_models.c"]   # 9.4: Hülle der Modelle (GARCH/GJR, GPD, DCC, MS-GARCH, Bootstrap)
HEADERS = SHARED_HEADERS + ["_ext_common.h"] + SLC_HEADERS


# wie R ohne -fwrapv, nur wenn der Compiler die Option ohne Warnung annimmt
OPTIONAL_FLAGS = {"unix": ["-fstrict-overflow"], "mingw32": ["-fstrict-overflow"]}


def _accepts(compiler, flag):
    """Übersetzt eine leere Datei mit ``flag`` (und ``-Werror``); True, wenn das gelingt."""
    import os
    import tempfile
    with tempfile.TemporaryDirectory() as d:
        src = os.path.join(d, "probe.c")
        with open(src, "w") as fh:
            fh.write("int simlev_probe(void) { return 0; }\n")
        try:
            compiler.compile([src], output_dir=d, extra_postargs=[flag, "-Werror"])
        except Exception:      # noqa: BLE001 (CompileError und Verwandte)
            return False
    return True


def _is_slc(src):
    """Quellen der C-Bibliothek slc (Kopien in src/core/ und die Hülle _ext_slc.c)."""
    p = src.replace(os.sep, "/")
    return ("/core/slc" in p or p.endswith("_ext_slc.c") or p.endswith("_ext_slc_linalg.c")
            or p.endswith("_ext_slc_opt.c") or p.endswith("_ext_slc_models.c"))  # 9.1-9.4


class BuildExt(build_ext):
    """Setzt die Gleitkomma-Flags passend zum Compiler, ``-std=gnu++17`` nur für C++- und ``-std=c99``
    nur für die C-Dateien der Bibliothek slc."""

    def build_extensions(self):
        ctype = self.compiler.compiler_type
        extra = FLAGS.get(ctype, []) + [f for f in OPTIONAL_FLAGS.get(ctype, []) if _accepts(self.compiler, f)]
        cxx = CXX_FLAGS.get(ctype, [])
        cfl = C_FLAGS.get(ctype, [])
        for ext in self.extensions:
            ext.extra_compile_args = list(ext.extra_compile_args or []) + extra
        if ctype in ("unix", "mingw32") and hasattr(self.compiler, "_compile"):
            orig = self.compiler._compile

            def _compile(obj, src, ext, cc_args, extra_postargs, pp_opts):
                if src.endswith(".cpp"):
                    extra_postargs = list(extra_postargs) + cxx
                elif src.endswith(".c") and _is_slc(src):
                    extra_postargs = list(extra_postargs) + cfl
                return orig(obj, src, ext, cc_args, extra_postargs, pp_opts)

            self.compiler._compile = _compile
        elif ctype == "msvc":
            for ext in self.extensions:
                ext.extra_compile_args += cxx
        super().build_extensions()


setup(
    ext_modules=[
        Extension(
            "simlev._ext",
            sources=["src/" + f for f in WRAPPERS + SLC_WRAPPERS + SLC],
            depends=["src/" + f for f in HEADERS],
            include_dirs=["src"],
            # Gleitkomma ueber die Flags (-ffp-contract=off); das Pragma der Kerndateien entfaellt
            define_macros=[("SIMLEV_FP_CONTRACT_BY_FLAG", "1")],
            language="c++",
            libraries=[] if sys.platform == "win32" else ["m"],   # exp, log aus der libm
            optional=False,     # Pflicht seit Etappe 9.1 (C-Bibliothek slc)
        )
    ],
    cmdclass={"build_ext": BuildExt},
)

"""Bau der optionalen C/C++-Erweiterung ``simlev._ext`` (Etappe 7.2, seit 7.3a ein Modul für alle Kerne).

Alle übrigen Angaben stehen in ``pyproject.toml``. Die Erweiterung ist
optional (``optional=True``): Fehlt ein Compiler oder schlägt der Bau fehl,
installiert ``pip`` das Paket trotzdem, und Python rechnet mit den reinen
Python-Kernen (bitgleich, nur langsamer).

Quellen: die Kerne ``src/*_impl.{c,cpp,h}`` und ``src/simlev_core.h`` sind
Byte-für-Byte-Kopien der kanonischen Dateien in ``r/src/`` (Liste und Prüfung in
``tests/test_shared_c.py``); die Python-Hüllen ``src/_ext*.cpp`` gibt es nur hier.

Gleitkomma-Einstellungen wie im R-Paket: ``-O2`` (R: ``R CMD config CFLAGS`` bzw.
``CXXFLAGS``), kein ``-ffast-math``, kein Zusammenziehen zu fma
(``-ffp-contract=off``; die Kerndateien setzen dafuer unter GCC ein Pragma nur dort,
wo fma erzeugt werden kann, und lassen es mit ``SIMLEV_FP_CONTRACT_BY_FLAG`` weg); C++
wie R mit ``-std=gnu++17``; unter MSVC ``/O2 /fp:precise /std:c++17``. Wie R ohne
``-fwrapv``: Python übersetzt Erweiterungen mit ``-fno-strict-overflow`` (= ``-fwrapv``);
``-fstrict-overflow`` (sofern der Compiler es kennt) stellt die Übersetzung der Schleifen
wie in R her (Etappe 7.3a, Engine-Kerne).
"""
import sys

from setuptools import Extension, setup
from setuptools.command.build_ext import build_ext

FLAGS = {
    "unix": ["-O2", "-fno-fast-math", "-ffp-contract=off"],
    "mingw32": ["-O2", "-fno-fast-math", "-ffp-contract=off"],
    "msvc": ["/O2", "/fp:precise"],
}
CXX_FLAGS = {"unix": ["-std=gnu++17"], "mingw32": ["-std=gnu++17"], "msvc": ["/std:c++17"]}

# Gemeinsame Kerne (Kopien aus r/src/): C-Dateien und reine Header (die Huellen binden
# die Header ein, siehe r/src/simlev_core.h)
CORES = ["ms_garch_impl.c"]
SHARED_HEADERS = ["simlev_core.h", "ms_garch_impl.h", "research_core_impl.h", "withdrawal_core_impl.h",
                  "dependence_core_impl.h", "vendor_rugarch_impl.h", "vendor_evd_impl.h",
                  "vendor_imputets_impl.h", "simulation_core_impl.h", "fifo_core_impl.h", "tax_core_impl.h",
                  "bootstrap_core_impl.h", "vendor_truncnorm_impl.h"]
# Python-Huellen (nur hier)
WRAPPERS = ["_ext.cpp", "_ext_ms_garch.cpp", "_ext_research.cpp", "_ext_withdrawal.cpp", "_ext_rugarch.cpp",
            "_ext_rugarch_c.c", "_ext_dependence.cpp", "_ext_evd.cpp", "_ext_evd_c.c",
            "_ext_imputets.cpp", "_ext_engine.cpp", "_ext_bootstrap.cpp", "_ext_truncnorm.cpp",
            "_ext_truncnorm_c.c", "_ext_rng.cpp"]
# C-Nachbildung von R's Zufallszahlen (nur Python; R nutzt sein eigenes RNG), Etappe 7.3b
RNG = ["_rng_r.c"]
HEADERS = SHARED_HEADERS + ["_ext_common.h", "_rng_r.h"]


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


class BuildExt(build_ext):
    """Setzt die Gleitkomma-Flags passend zum Compiler und ``-std=gnu++17`` nur für C++-Dateien."""

    def build_extensions(self):
        ctype = self.compiler.compiler_type
        extra = FLAGS.get(ctype, []) + [f for f in OPTIONAL_FLAGS.get(ctype, []) if _accepts(self.compiler, f)]
        cxx = CXX_FLAGS.get(ctype, [])
        for ext in self.extensions:
            ext.extra_compile_args = list(ext.extra_compile_args or []) + extra
        if ctype in ("unix", "mingw32") and hasattr(self.compiler, "_compile"):
            orig = self.compiler._compile

            def _compile(obj, src, ext, cc_args, extra_postargs, pp_opts):
                if src.endswith(".cpp"):
                    extra_postargs = list(extra_postargs) + cxx
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
            sources=["src/" + f for f in WRAPPERS + CORES + RNG],
            depends=["src/" + f for f in HEADERS],
            include_dirs=["src"],
            # Gleitkomma ueber die Flags (-ffp-contract=off); das Pragma der Kerndateien entfaellt
            define_macros=[("SIMLEV_FP_CONTRACT_BY_FLAG", "1")],
            language="c++",
            libraries=[] if sys.platform == "win32" else ["m"],   # exp, log aus der libm
            optional=True,
        )
    ],
    cmdclass={"build_ext": BuildExt},
)

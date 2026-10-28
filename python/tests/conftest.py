import os
import sys

import pytest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

from simlev._r import env as _env  # noqa: E402

# Etappe 9 (Entwurf C.7): ohne SIMLEV_LEGACY_TESTS=1 sind die alten Tests ausgesetzt; es laufen nur
# die Rauchproben der Etappe 9 (Dateien test_etappe9_*.py). Keine Testdatei wird gelöscht. Seit 9.6c
# werden die alten Dateien ohne den Schalter gar nicht erst geladen (pytest_ignore_collect).
_SKIP = pytest.mark.skip(reason="Etappe 9: ausgesetzt (SIMLEV_LEGACY_TESTS=1 führt sie aus)")


def _is_legacy(name):
    return name.startswith("test_") and name.endswith(".py") and not name.startswith("test_etappe9_")


def pytest_ignore_collect(collection_path, config):
    """Seit Etappe 9.6c: ohne SIMLEV_LEGACY_TESTS=1 werden die alten Testdateien nicht geladen. Einige
    verweisen auf Module, die mit 9.6c entfallen sind (``simlev._r.nmath``, ``rng``, ``linalg``-Teile,
    ``_bootstrap_core`` …), und würden schon beim Laden scheitern. Mit dem Schalter laufen sie wie
    bisher (und scheitern dann dort, siehe ``scratchpad/e96c/bericht.md``)."""
    if _env.legacy_tests():
        return None
    return True if _is_legacy(collection_path.name) else None


def pytest_report_header(config):
    if _env.legacy_tests():
        return None
    n = sum(1 for f in os.listdir(os.path.dirname(os.path.abspath(__file__))) if _is_legacy(f))
    return "Etappe 9: %d alte Testdateien ausgesetzt (nicht geladen; SIMLEV_LEGACY_TESTS=1 führt sie aus)" % n


def pytest_collection_modifyitems(config, items):
    if _env.legacy_tests():
        return
    for item in items:
        if not os.path.basename(str(item.fspath)).startswith("test_etappe9_"):
            item.add_marker(_SKIP)

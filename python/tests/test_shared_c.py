"""Gemeinsame native Kerne für R und Python (seit Etappe 9.6c über ``tools/core_sync.py``).

Bis Etappe 9.6c verglich dieser Test die Kopien in ``python/src/`` Byte für Byte mit ``r/src/`` und
die Erweiterung mit den reinen Python-Kernen (``SIMLEV_NO_EXT``). Seit 9.6c (Entwurf C.1, F16) sind
alle C-Quellen kanonisch in ``core/``: die C-Bibliothek slc (``core/slc*``) und die geteilten Kerne
von R und Python (``core/simlev_core.h``, ``core/*_core_impl.h``). ``tools/core_sync.py --check``
prüft alle Kopien (SHA-256) und läuft in jedem Gleichlauf; dieser Test ruft ihn nur auf und prüft,
dass ``setup.py`` genau die Kopien in ``src/core/`` baut und ``simlev._ext`` die Hüllen der
geteilten Kerne bereitstellt. Reine Python-Kerne als Rückfall gibt es nicht mehr.

Ausgesetzt wie alle alten Tests (``SIMLEV_LEGACY_TESTS=1`` führt ihn aus, Entwurf C.7).
"""
import os
import re
import subprocess
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
PY_SRC = os.path.join(HERE, "..", "src")
REPO = os.path.join(HERE, "..", "..")
CORE_SYNC = os.path.join(REPO, "tools", "core_sync.py")

# Hüllen der geteilten Kerne in simlev._ext (je kanonischer Datei in core/)
METHODS = {
    "research_core_impl.h": ["proj_box_simplex", "qp_box_simplex", "min_cvar_core", "min_cdar_core",
                             "roll_mean_core", "roll_cov_core", "kendall_tau_core", "quantile_reg_core",
                             "hmm_forward_backward"],          # N2: garch_filter entfernt
    "withdrawal_core_impl.h": ["wd_simulate"],
    "simulation_core_impl.h": ["sim_dca_flows", "sim_buy_report", "sim_sell_report", "sim_total_report", "sim_buy",
                               "sim_market_update", "sim_market_update_batch"],
    "fifo_core_impl.h": ["sim_fifo_price", "sim_fifo_vp", "sim_private_sale_tax", "sim_fifo_consume"],
    "tax_core_impl.h": ["sim_flat_rate", "sim_p20_tax", "sim_vp_tax", "sim_sell_count"],
}


def _repo():
    if not os.path.isfile(CORE_SYNC):
        pytest.skip("tools/core_sync.py nicht vorhanden (kein Repo neben dem Python-Paket)")


def test_core_sync_check():
    """Alle Kopien aus core/ (r/src/, python/src/core/, julia/deps/core/) sind Byte für Byte gleich."""
    _repo()
    r = subprocess.run([sys.executable, CORE_SYNC, "--check"], capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr


def test_setup_baut_die_kopien():
    """setup.py nennt genau die geteilten Kerne in src/core/; src/ enthält nur noch die Hüllen."""
    src = open(os.path.join(HERE, "..", "setup.py"), encoding="utf-8").read()
    m = re.search(r"SHARED_HEADERS\s*=\s*\[(.*?)\]", src, re.S)
    listed = sorted(re.findall(r'"([^"]+)"', m.group(1)))
    copies = sorted("core/" + f for f in os.listdir(os.path.join(PY_SRC, "core"))
                    if f == "simlev_core.h" or f.endswith("_core_impl.h"))
    assert listed == copies
    rest = sorted(f for f in os.listdir(PY_SRC) if f != "core" and not f.startswith("."))
    assert all(f.startswith("_ext") for f in rest), rest


def test_ext_huellen():
    """simlev._ext stellt die Hüllen aller geteilten Kerne bereit (die Erweiterung ist Pflicht)."""
    from simlev import _ext
    for f, names in METHODS.items():
        for n in names:
            assert callable(getattr(_ext, n, None)), "%s: %s fehlt in simlev._ext" % (f, n)

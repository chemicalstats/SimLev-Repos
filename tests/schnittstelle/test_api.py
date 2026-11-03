"""Öffentliche Schnittstelle gegen den eingefrorenen Stand.

Führt den Python-Auszug ``tests/schnittstelle/api_py.py`` mit ``--frozen-check``
in einem eigenen Prozess aus (``simlev.__all__`` und die Methoden der Klassen
mit ``r_class``, wie für ``run.sh``) und vergleicht mit
``tests/schnittstelle/frozen/py.json``: Funktionen und Methoden, Argumente in
Reihenfolge, Art (positionell/Schlüsselwort), Standardwerte, dazu die Namen der
exportierten Klassen. Ein eigener Prozess, damit die von anderen Tests
geladenen Untermodule den Auszug nicht verändern. Die Meldung nennt jede
Abweichung und wie man den Stand bewusst neu festschreibt (Eintrag in
``tests/schnittstelle/CHANGES.md``, dann ``tests/schnittstelle/run.sh --freeze``).
"""
import os
import subprocess
import sys
import tempfile

import pytest

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
API = os.path.join(ROOT, "tests", "schnittstelle")
SCRIPT = os.path.join(API, "api_py.py")
FROZEN = os.path.join(API, "frozen", "py.json")


def test_api_eingefroren():
    if not (os.path.isfile(SCRIPT) and os.path.isfile(FROZEN)):
        pytest.skip("tests/schnittstelle/frozen/py.json fehlt")
    env = dict(os.environ, LC_ALL="C.UTF-8")
    with tempfile.TemporaryDirectory() as d:
        r = subprocess.run([sys.executable, SCRIPT, os.path.join(d, "api_py.json"), "--frozen-check", FROZEN],
                           cwd=ROOT, env=env, capture_output=True, text=True, encoding="utf-8")
    report = (r.stdout + r.stderr).strip()
    assert r.returncode == 0, "\n" + report
    assert "entspricht dem eingefrorenen Stand" in report

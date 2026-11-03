"""pytest-Einstellungen der Python-Tests (T20: tests/python, gegen das gebaute bzw. installierte Paket).

Aufruf aus der Repo-Wurzel: ``python3 -m pytest tests/python`` (oder ``tests/run.sh python``). Ist die
C-Erweiterung an Ort und Stelle gebaut (``cd python && python3 setup.py build_ext --inplace``), wird
``python/`` vor das installierte Paket gestellt; sonst gilt das installierte ``simlev``.
"""
import glob
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
_PY = os.path.normpath(os.path.join(HERE, "..", "..", "python"))
if glob.glob(os.path.join(_PY, "simlev", "_ext*.so")) or glob.glob(os.path.join(_PY, "simlev", "_ext*.pyd")):
    sys.path.insert(0, _PY)
sys.path.insert(0, HERE)

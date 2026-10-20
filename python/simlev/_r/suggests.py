"""Nachgebildete optionale R-Pakete (Suggests des R-Pakets).

R nimmt in einigen Funktionen einen anderen Weg, wenn ein optionales Paket
installiert ist (``requireNamespace(pkg, quietly = TRUE)``). SimLev bildet
``evd``, ``rugarch`` und ``imputeTS`` nach und verhält sich standardmäßig wie R
mit diesen Paketen. Die Umgebungsvariable ``SIMLEV_R_SUGGESTS`` wählt, welche als
installiert gelten (wird bei jedem Aufruf gelesen, wie ``requireNamespace``):

* nicht gesetzt oder ``all``: alle nachgebildeten Pakete
* ``none`` oder leer: keines (wie R ohne die Pakete)
* Liste, z. B. ``evd`` oder ``evd,rugarch,imputeTS``

Andere optionale Pakete (MSGARCH, plotly, TTR) gelten immer als
nicht installiert.
"""

import os

EMULATED = ("evd", "rugarch", "imputeTS")


def installed():
    """Tupel der Pakete, die derzeit als installiert gelten."""
    v = os.environ.get("SIMLEV_R_SUGGESTS")
    if v is None:
        return EMULATED
    v = v.strip()
    if v == "all":
        return EMULATED
    if v in ("", "none"):
        return ()
    want = {s.strip() for s in v.split(",")}
    return tuple(p for p in EMULATED if p in want)


def has(pkg):
    """``requireNamespace(pkg, quietly = TRUE)`` für die nachgebildeten Pakete."""
    return pkg in installed()

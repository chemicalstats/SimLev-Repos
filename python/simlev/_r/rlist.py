"""Basisklasse für R-Listen-Ergebnisse (Objekte mit S3-Klasse)."""
from __future__ import annotations

from collections import OrderedDict

__all__ = ["RList"]


class _PrintFormat:
    """``print()`` über ``format()``; gibt das Objekt zurück (wie R's ``print``). Seit 1.6.4 eine Fassung für die
    Ergebnisklassen mit eigener ``format()``-Methode (bis 1.6.3 zwölf gleiche Methoden)."""

    __slots__ = ()

    def print(self):
        print(self.format())
        return self


class RList(OrderedDict):
    """Geordnetes ``dict`` mit Attributzugriff, wie eine benannte R-Liste.

    ``x["worth"]`` und ``x.worth`` sind gleichwertig. Unterklassen
    überschreiben ``format()`` mit der exakten Ausgabe der R-``print``-Methode;
    ``str(x)``/``repr(x)``/``print(x)`` nutzen ``format()``.
    ``r_class`` enthält den R-Klassenvektor.
    """

    r_class: tuple = ()

    def __getattr__(self, name):
        try:
            return self[name]
        except KeyError:
            raise AttributeError(name) from None

    def __setattr__(self, name, value):
        if name.startswith("_") or name == "r_class":
            object.__setattr__(self, name, value)
        else:
            self[name] = value

    def __delattr__(self, name):
        try:
            del self[name]
        except KeyError:
            raise AttributeError(name) from None

    def format(self) -> str:  # pragma: no cover - Unterklassen
        return "<%s: %s>" % (type(self).__name__, ", ".join(self.keys()))

    def __str__(self) -> str:
        return self.format()

    __repr__ = __str__

    def _repr_pretty_(self, p, cycle):  # IPython
        p.text(self.format())

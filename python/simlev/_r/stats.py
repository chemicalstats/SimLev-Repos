"""R's ``stats``-Interna (R 4.3.3), bitgleich in Python.

Portiert aus ``src/library/stats/R/*.R`` und ``src/library/stats/src/*.c``
bzw. ``*.f`` (sowie Teilen von ``src/main/sort.c``, ``seq.c``, ``cum.c``).
Rechenreihenfolge, ``long double``-Akkumulation (``numpy.longdouble``) und
libm-Aufrufe (``math``) wie in R.

Konventionen
------------
* Namen wie in R, ``.`` → ``_`` (``weighted.mean`` → :func:`weighted_mean`,
  ``p.adjust`` → :func:`p_adjust`, …).
* Argumentnamen und Voreinstellungen wie in R (``na.rm`` → ``na_rm``).
* Eingaben: numpy-Arrays, Listen, Skalare, ``pandas.Series`` (benannte
  Vektoren) und ``pandas.DataFrame`` bzw. 2-D-Arrays (Matrizen).
* Ergebnisse: Länge-1-Vektoren als ``float``/``int``, sonst ``ndarray``;
  benannte Vektoren als ``Series``; Matrizen als 2-D-``ndarray`` bzw. mit
  dimnames als ``DataFrame``; R-Listen als :class:`~simlev._r.rlist.RList`.
* ``NA`` ist ``NA_REAL`` (NaN mit R's Nutzlast 1954), andere NaN sind R's ``NaN``. Fehler: :class:`RError` mit R's Meldungstext;
  Warnungen über :func:`warnings.warn` mit R's Text.

Aufteilung
----------
Dieses Modul sammelt die Namen der Themenmodule (gleiche Dateinamen wie in
Julia, ``julia/src/r/stats_*.jl``), damit ``from simlev._r.stats import …``
und ``simlev._r.stats.<name>`` gültig bleiben:

* :mod:`.stats_sort`    Hilfen, Sortieren, Ränge, Einteilen, Quantile, Median
* :mod:`.stats_cor`     ``cor``, ``cov``, ``var``, ``sd``, ``cov2cor``, ``scale``
* :mod:`.stats_smooth`  ``approx``, ``approxfun``, ``filter``
* :mod:`.stats_optim`   ``optimize``, ``uniroot``
* :mod:`.stats_models`  ``coef``, ``fitted``, ``residuals``, ``p.adjust``, ``ecdf``, ``ave``,
  ``aggregate``
* :mod:`.stats_cluster` ``dist``, ``hclust``

Seit Etappe 9.6c entfallen ``optim``, ``optimhess``, ``nlminb``, ``lm``/``lm.fit``, ``poly``,
``summary.lm``, ``glm``/``binomial``, ``t.test``, ``predict``, ``fft``, ``density``, ``bw.nrd0``
und ``smooth.spline``; SimLev rechnet sie mit der C-Bibliothek slc (:mod:`simlev._lib`).
"""
from __future__ import annotations

from ._collate import str_collate
from .linalg import RError
from .stats_sort import (
    quantile,
    median,
    weighted_mean,
    rank,
    order,
    sort,
    rle,
    cut,
    findInterval,
    tabulate,
    complete_cases,
    seq_len_out,
)
from .stats_cor import var, sd, cov, cor, cov2cor, scale
from .stats_smooth import approx, approxfun, filter
from .stats_optim import optimize, optimise, uniroot
from .stats_models import p_adjust, ave, aggregate, ecdf, fitted, coef, residuals
from .stats_cluster import RDist, RHclust, dist_as_matrix, hclust, dist, as_dist
from . import stats_sort as _sort

__all__ = [
    "RError", "RDist", "RHclust", "dist_as_matrix", "quantile", "median", "var", "sd", "cov", "cor",
    "cov2cor", "weighted_mean", "scale", "approx", "approxfun", "filter", "optimize", "optimise",
    "uniroot", "hclust", "dist", "as_dist", "p_adjust", "rank", "order", "sort", "rle",
    "cut", "findInterval", "tabulate", "ave", "aggregate", "complete_cases", "ecdf",
    "fitted", "coef", "residuals", "seq_len_out", "str_collate",
]

# Wiederausgabe interner Namen, die andere Module über ``stats`` nutzen
# (``sort_partial``; ``_rsum``, ``_rmean``, ``_warn`` aus ``stats_sort``)
sort_partial = _sort.sort_partial
_rsum = _sort._rsum
_rmean = _sort._rmean
_warn = _sort._warn


from .base import quiet_fp  # noqa: E402

quiet_fp(globals(), __all__)

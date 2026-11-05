"""R's ``stats``-Interna (R 4.3.3), bitgleich in Python.

Portiert aus ``src/library/stats/R/*.R`` und ``src/library/stats/src/*.c``
bzw. ``*.f`` (sowie Teilen von ``src/main/sort.c``, ``seq.c``, ``cum.c``).
Rechenreihenfolge, ``long double``-Akkumulation (über die C-Kerne
``core/slc_rbase*.cpp`` in :mod:`simlev._ext`) und libm-Aufrufe (``math``) wie in R.

Konventionen
------------
* Namen wie in R, ``.`` → ``_`` (``p.adjust`` → :func:`p_adjust`,
  ``seq_len(length.out)`` → :func:`seq_len_out`, …).
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
* :mod:`.stats_smooth`  ``approx``, ``filter``
* :mod:`.stats_optim`   ``optimize``
* :mod:`.stats_models`  ``coef``, ``fitted``, ``residuals``, ``p.adjust``
* :mod:`.stats_cluster` ``dist``, ``hclust``

Seit 1.0.0 entfallen ``optim``, ``optimhess``, ``nlminb``, ``lm``/``lm.fit``, ``poly``,
``summary.lm``, ``glm``/``binomial``, ``t.test``, ``predict``, ``fft``, ``density``, ``bw.nrd0``
und ``smooth.spline``; SimLev rechnet sie mit der C-Bibliothek slc (:mod:`simlev._lib`).
"""
from __future__ import annotations

from ._collate import str_collate
from .linalg import RError
from .stats_sort import (
    quantile,
    median,
    rank,
    order,
    sort,
    cut,
    seq_len_out,
)
from .stats_cor import var, sd, cov, cor, cov2cor, scale
from .stats_smooth import approx, filter
from .stats_optim import optimize
from .stats_models import p_adjust
from .stats_cluster import RDist, RHclust, dist_as_matrix, hclust, dist, as_dist
from . import stats_sort as _sort

__all__ = [
    "RError", "RDist", "RHclust", "dist_as_matrix", "quantile", "median", "var", "sd", "cov", "cor",
    "cov2cor", "scale", "approx", "filter", "optimize",
    "hclust", "dist", "as_dist", "p_adjust", "rank", "order", "sort",
    "cut", "seq_len_out", "str_collate",
]

# Wiederausgabe interner Namen aus ``stats_sort`` über ``stats``: ``sort_partial`` nutzt RExpr (``rexpr.py``,
# ``_stats.sort_partial``), ``_rmean`` tests/werkzeuge/gleichlauf/approx_fuzz.R (seit 1.6.3 ohne ``_rsum``/``_warn``)
sort_partial = _sort.sort_partial
_rmean = _sort._rmean


from .base import quiet_fp  # noqa: E402

quiet_fp(globals(), __all__)

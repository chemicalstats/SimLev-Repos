# Herkunft:           nachgebildet nach R 4.3.3, src/library/stats/R/lm.R (Zugriffe), p.adjust.R
# Rechte:             The R Core Team, teils Robert Gentleman und Ross Ihaka, The R Foundation (laut
#                     Kopf der jeweiligen R-Quelle)
# Lizenz der Vorlage: GPL (>= 2) laut Kopf der R-Quellen; in SimLev unter GPL-3
# Änderungen:         Übertragung nach Python bzw. Julia (Julia nach der Python-Fassung) im von
#                     SimLev genutzten Umfang; seit 1.6.0 rechnet p.adjust im C-Kern core/slc_rbase_models.cpp
#                     (sl_r_p_adjust, in Julia auch ecdf über sl_r_ecdf); seit 1.6.1 ohne ecdf, ave und aggregate
#                     (nur von Referenzfällen genutzt).
"""Generische Zugriffe ``coef``, ``fitted``, ``residuals`` sowie ``p.adjust``, nachgebildet aus R 4.3.3
``stats/R/lm.R`` (Zugriffe) und ``p.adjust.R``.

Seit 1.0.0 entfallen ``lm.fit``, ``lm``, ``poly``, ``summary.lm``, ``glm``/``binomial``,
``t.test`` und das generische ``predict``: SimLev rechnet kleinste Quadrate, Logit-IRLS, Polynomfit,
r² und den Welch-Test selbst (C-Bibliothek slc, :mod:`simlev._lib`).
"""
from __future__ import annotations

import math

import numpy as np

from .linalg import RError, _vec_out
from .. import _ext   # C-Kern sl_r_p_adjust (core/slc_rbase_models.cpp, seit 1.6.0)
from .stats_sort import _vec

__all__ = ["p_adjust"]


# ── p.adjust / ecdf / ave / aggregate ────────────────────────────────────

_PADJ = ["holm", "hochberg", "hommel", "bonferroni", "BH", "BY", "fdr", "none"]


def p_adjust(p, method="holm", n=None):
    """``p.adjust(p, method, n)``."""
    hits = [m for m in _PADJ if m.startswith(method)]
    if method in _PADJ:
        hits = [method]
    if len(hits) != 1:
        raise RError("'arg' should be one of " + ", ".join("“%s”" % m for m in _PADJ))
    method = hits[0]
    if method == "fdr":
        method = "BH"
    pv, nm = _vec(p)
    p0 = pv.copy()
    nna = ~np.isnan(pv)
    pp = pv[nna]
    lp = pp.size
    if n is None:
        n = lp          # R: Promise length(p) wird erst nach p <- p[nna] ausgewertet
    if not n >= lp:
        raise RError("n >= lp is not TRUE")
    if n <= 1:
        return _vec_out(p0, nm) if (nm is not None or p0.size != 1) else float(p0[0])
    r = np.empty(lp)   # C-Kern sl_r_p_adjust (seit 1.6.0)
    # seit 1.6.4 (C-017) wie R: hommel und BY brauchen n Werte (rep.int(1, n - lp) bzw. 1/(1L:n)); n = Inf ist dort
    # ein Fehler, ohne Speicher die Meldung von R (bis 1.6.3 undefinierte Umwandlung, Absturz bzw. ganzer Speicher)
    if method in ("hommel", "BY") and not (method == "hommel" and n == 2) and not math.isfinite(n):
        raise RError("invalid 'times' value" if method == "hommel" else "result would be too long a vector")
    try:
        _ext.slc_r_p_adjust(np.ascontiguousarray(pp), float(n), _PADJ_CODE[method], r)
    except MemoryError:
        raise RError(_r_alloc_msg(math.floor(n - lp if method == "hommel" else n) * 8.0)) from None
    p0[nna] = r
    return _vec_out(p0, nm) if (nm is not None or p0.size != 1) else float(p0[0])


def _r_alloc_msg(nbytes):
    """Meldung von R, wenn ein Vektor von nbytes Bytes nicht angelegt werden kann (memory.c, allocVector)."""
    kb = nbytes / 1024.0
    if kb > 1024.0 * 1024.0:
        return "cannot allocate vector of size %0.1f Gb" % (kb / 1024.0 / 1024.0)
    if kb > 1024.0:
        return "cannot allocate vector of size %0.1f Mb" % (kb / 1024.0)
    return "cannot allocate vector of size %0.f Kb" % kb


_PADJ_CODE = {"holm": 0, "hochberg": 1, "hommel": 2, "bonferroni": 3, "BH": 4, "BY": 5, "none": 6}


from .base import quiet_fp  # noqa: E402

quiet_fp(globals(), __all__)

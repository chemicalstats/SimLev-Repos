# ─────────────────────────────────────────────────────────────────────────────
# RStats – R's stats-Interna (R 4.3.3), bitgleich
#
# Portiert aus src/library/stats/R/*.R und src/library/stats/src/*.c bzw. *.f
# (sowie Teilen von src/main/sort.c, qsort-body.c, seq.c, cum.c) über die
# Vorlage python/simlev/_r/stats.py. Rechenreihenfolge, long-double-
# Akkumulation (SimLev.F80) und libm-Aufrufe (SimLev.RLibm) wie in R.
#
# Konventionen
# * Namen wie in R bzw. der Python-Fassung, `.` → `_` (weighted.mean →
#   weighted_mean, p.adjust → p_adjust, …). Kollisionen mit Base: r_sort,
#   r_rank, r_filter.
# * Seit Etappe 9.6c entfallen optim, optimhess, nlminb, lm/lm_fit, poly, summary_lm,
#   glm/r_binomial, t_test, predict, fft, density, bw_nrd0 und smooth_spline (eigene
#   Verfahren der C-Bibliothek slc, SimLev.SLib).
# * Eingaben: Vektoren (NA = SimLev.NA bzw. missing), RVector (benannt),
#   Matrix, NamedMat, RFrame, Skalare.
# * Ergebnisse: Länge 1 als Skalar, sonst Vector; benannte Vektoren als
#   RVector; Matrizen als Matrix bzw. mit dimnames als NamedMat; Listen als
#   RList (S3-Klasse im Feld `class`); data.frames als RFrame; Faktoren als
#   SimLev.RFmt.RFactor.
# * Fehler: error(<R-Text>); Warnungen: @warn <R-Text>.
# ─────────────────────────────────────────────────────────────────────────────
module RStats

import ..SimLev
import ..SimLev: RList, RVector, NamedMat, RFrame, NA, isna_strict, F80
using Dates

export quantile, median, var, sd, cov, cor, cov2cor, weighted_mean, scale, approx, approxfun,
       r_filter, optimize, optimise, uniroot, hclust, dist,
       as_dist, dist_as_matrix, p_adjust, r_rank, order, r_sort, sort_partial, rle, cut,
       findInterval, tabulate, ave, aggregate, complete_cases, ecdf, fitted, coef, residuals,
       seq_len_out, ApproxFun, str_collate, r_isless

const _DBL_EPS = 2.220446049250313e-16
const _DBL_MAX = 1.7976931348623157e308

"sqrt mit C-Semantik (negativ → NaN statt DomainError)."
@inline _csqrt(x::Float64) = x < 0.0 ? reinterpret(Float64, 0xFFF8000000000000) : sqrt(x)

include("_collate.jl")
include("_optim.jl")

# Kollationszustand (ICU-Handles) gilt nur im laufenden Prozess.
# Beim Laden nur zurücksetzen (nach der Vorkompilierung wären Zeiger ungültig).
__init__() = (_COLL.init = false; _COLL.coll = C_NULL; _COLL.warned = false; nothing)

# Themen (gleiche Dateinamen wie python/simlev/_r/stats_*.py)
include("stats_sort.jl")
include("stats_cor.jl")
include("stats_smooth.jl")
include("stats_optim.jl")
include("stats_models.jl")
include("stats_cluster.jl")

end # module

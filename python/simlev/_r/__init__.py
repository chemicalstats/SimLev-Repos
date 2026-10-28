"""R-Kompatibilitätsschicht für die bitgleiche Portierung.

Untermodule:

- ``rnum``    unterste Schicht: ``NA_REAL``, Summen in long double, ``r_pow``, ``r_uniroot``
  (skalare/eindimensionale Engine-Hilfen)
- ``rformat`` Rundung und Textausgabe der Engine (``r_round``, ``r_signif``, ``r_format``, ``r_sprintf``)
- ``libm``    elementweise libm-Funktionen (statt numpy-SIMD-Varianten)
- ``base``    Funktionen von R's base (``colSums``, ``cumprod``, ``pmin`` …) mit long double wie R,
  ``quiet_fp``
- ``stats``   quantile, cor, optimize, uniroot, approx, filter, p.adjust, hclust, …
- ``linalg``  outer, diag, isSymmetric und Hilfen (``RError``)
- ``fmt``     format, formatC, round, signif, print von Vektoren/data.frames
- ``rexpr``   Auswertung von R-Ausdrücken als Text (Bedingungen in R-Syntax)
- ``rlist``   Basisklasse für R-Listen-Ergebnisse
- ``parallel`` Nachbildung von ``.par_lapply`` (Fork)
- ``env``     Umgebungsschalter ``SIMLEV_*``
- ``reftree`` Vergleich mit R-Referenzfällen

Seit Etappe 9.6c entfallen die Nachbildungen von R's Zufall (``rng``), nmath, BLAS/LAPACK/LINPACK,
optim/L-BFGS-B/PORT, smooth.spline, FFT und TOMS 708 sowie der Übernahmen evd, rugarch, Rsolnp,
truncnorm, stinepack und imputeTS; SimLev rechnet diese Aufgaben mit der C-Bibliothek slc
(:mod:`simlev._lib`).
"""

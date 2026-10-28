"""R-Kompatibilitätsschicht für die bitgleiche Portierung.

Untermodule:

- ``rnum``    unterste Schicht: ``NA_REAL``, Summen in long double, ``r_pow``, ``r_uniroot``
  (skalare/eindimensionale Engine-Hilfen)
- ``rformat`` Rundung und Textausgabe der Engine (``r_round``, ``r_signif``, ``r_format``, ``r_sprintf``)
- ``libm``    elementweise libm-Funktionen (statt numpy-SIMD-Varianten)
- ``base``    Funktionen von R's base (``colSums``, ``cumprod``, ``pmin`` …) mit long double wie R,
  ``quiet_fp``, ``sys_time``
- ``rng``     R-Zufallszahlengeneratoren (Mersenne-Twister, L'Ecuyer-CMRG)
- ``nmath``   Verteilungsfunktionen aus R's nmath
- ``stats``   quantile, cor, optim, nlminb (PORT-Bibliothek in ``port``), optimize, uniroot, lm, glm, density, …
- ``linalg``  Matrixprodukte wie Referenz-BLAS, solve, chol, eigen, qr
- ``fmt``     format, formatC, round, signif, print von Vektoren/data.frames
- ``evd``     Nachbildung von evd::fpot (GPD-Fit; aus evd 2.3-7.1 ins R-Paket übernommen)
- ``solnp``   Nachbildung von Rsolnp::solnp (SQP mit Nebenbedingungen) und gosolnp (Zufallsstarts)
- ``truncnorm`` Nachbildung von truncnorm::rtruncnorm (gestutzte Normalverteilung)
- ``rugarch`` Nachbildung von rugarch::ugarchfit für .fit_garch11 (optionales R-Paket rugarch)
- ``stinepack`` Nachbildung von stinepack::stinterp (Stineman-Interpolation, Steigungen; aus stinepack 1.5 ins R-Paket übernommen)
- ``imputets`` Nachbildung von imputeTS::na_interpolation/na_locf für .fill_na (aus imputeTS 3.4 ins R-Paket übernommen)
- ``port``    PORT-Bibliothek für ``stats.nlminb`` (stats ``port.c``, ``portsrc.f``)
- ``rexpr``   Auswertung von R-Ausdrücken als Text (Bedingungen in R-Syntax)
- ``rlist``   Basisklasse für R-Listen-Ergebnisse
- ``reftree`` Vergleich mit R-Referenzfällen
"""

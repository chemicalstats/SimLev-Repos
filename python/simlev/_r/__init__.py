"""R-Kompatibilitätsschicht für die bitgleiche Portierung.

Untermodule:

- ``libm``    elementweise libm-Funktionen (statt numpy-SIMD-Varianten)
- ``base``    Summen, Mittel, kumulierte Größen mit long-double wie R
- ``rng``     R-Zufallszahlengeneratoren (Mersenne-Twister, L'Ecuyer-CMRG)
- ``nmath``   Verteilungsfunktionen aus R's nmath
- ``stats``   quantile, cor, optim, nlminb (PORT, ``_port``), optimize, uniroot, lm, glm, density, …
- ``linalg``  Matrixprodukte wie Referenz-BLAS, solve, chol, eigen, qr
- ``fmt``     format, formatC, round, signif, print von Vektoren/data.frames
- ``evd``     Nachbildung von evd::fpot (GPD-Fit, optionales R-Paket evd)
- ``solnp``   Nachbildung von Rsolnp::solnp (SQP mit Nebenbedingungen) und gosolnp (Zufallsstarts)
- ``truncnorm`` Nachbildung von truncnorm::rtruncnorm (gestutzte Normalverteilung)
- ``rugarch`` Nachbildung von rugarch::ugarchfit für .fit_garch11 (optionales R-Paket rugarch)
- ``stinepack`` Nachbildung von stinepack::stinterp (Stineman-Interpolation, Steigungen)
- ``imputets`` Nachbildung von imputeTS::na_interpolation/na_locf für .fill_na (optionales R-Paket imputeTS)
- ``rexpr``   Auswertung von R-Ausdrücken als Text (Bedingungen in R-Syntax)
- ``rlist``   Basisklasse für R-Listen-Ergebnisse
- ``reftree`` Vergleich mit R-Referenzfällen
"""

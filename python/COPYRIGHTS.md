# Urheberrecht und Lizenzen nachgebildeter Teile

SimLev für Python steht unter der GNU General Public License, Version 3
(GPL-3, siehe `LICENSE.md`). Copyright ChemicalStats von der Mauerstrasse,
ausgenommen die unten aufgeführten Teile: Sie bilden Code anderer R-Pakete
unter der GPL bitgleich nach (Übertragung nach Python, angepasst für SimLev).
Das Urheberrecht am Original liegt bei den genannten Autoren; es gelten die
Lizenzbedingungen des Originals. Das R-Paket enthält die übernommenen Teile
selbst, siehe `r/inst/COPYRIGHTS`.

## evd

| | |
|---|---|
| Paket | evd 2.3-7.1 (CRAN, 2024-09-21), *Functions for Extreme Value Distributions* |
| Autoren | Alec Stephenson. Function fbvpot by Chris Ferro. (laut DESCRIPTION von evd) |
| Lizenz | GPL-3 |
| Quelle | <https://CRAN.R-project.org/package=evd> |
| Datei in SimLev | `simlev/_r/evd.py` |

Nachgebildet sind `fpot` und `fpot.norm` aus `R/uvfit.R` (nur
`model = "gpd"` mit `cmax = FALSE` und `mper = NULL`) und `nlgpd` aus
`src/pot.c`. Im R-Paket entsprechen dem `.evd_fpot` (`r/R/vendor_evd.R`)
und `C_evd_nlgpd` (`r/src/vendor_evd.c`).

## imputeTS

| | |
|---|---|
| Paket | imputeTS 3.4 (CRAN, 2025-08-25), *Time Series Missing Value Imputation* |
| Autoren | Steffen Moritz [aut, cre, cph], Sebastian Gatscha [aut], Earo Wang [ctb], Ron Hause [ctb] (laut DESCRIPTION von imputeTS) |
| Lizenz | GPL-3 |
| Quelle | <https://CRAN.R-project.org/package=imputeTS> |
| Datei in SimLev | `simlev/_r/imputets.py` |

Nachgebildet sind `na_interpolation` aus `R/na_interpolation.R`
(`option = "stine"` und `"linear"`, diese mit `approx` und `rule = 2`, ohne
weitere Argumente für `approx`; `"spline"` bricht wie im R-Paket ab),
`na_locf` aus `R/na_locf.R` (ohne `na_remaining = "rm"`/`"mean"`) und der
C++-Kern `locf` aus `src/locf.cpp`. Im R-Paket entsprechen dem
`.imputets_na_interpolation`, `.imputets_na_locf` (`r/R/vendor_imputets.R`)
und `.imputets_locf` (`r/src/vendor_imputets.cpp`).

## stinepack

| | |
|---|---|
| Paket | stinepack 1.5 (CRAN, 2024-03-07), *Stineman, a Consistently Well Behaved Method of Interpolation* |
| Autoren | Tomas Johannesson & Halldor Bjornsson, Icelandic Met. Office; Gabor Grothendieck (laut DESCRIPTION von stinepack) |
| Lizenz | GPL (>= 2), in SimLev unter GPL-3 |
| Quelle | <https://CRAN.R-project.org/package=stinepack> |
| Datei in SimLev | `simlev/_r/stinepack.py` |

Nachgebildet sind `stinterp`, `stinemanSlopes` und `parabolaSlopes` aus
`R/stinterp.R`, `R/stinemanSlopes.R` und `R/parabolaSlopes.R`. Im R-Paket
entsprechen dem `.stinepack_stinterp`, `.stinepack_stinemanSlopes` und
`.stinepack_parabolaSlopes` (`r/R/vendor_stinepack.R`).

## rugarch

| | |
|---|---|
| Paket | rugarch 1.5-6 (CRAN, 2026-07-18), *Univariate GARCH Models* |
| Autoren | Alexios Galanos [aut, cre, cph], Tobias Kley [ctb] (laut DESCRIPTION von rugarch) |
| Lizenz | GPL-3 |
| Quelle | <https://CRAN.R-project.org/package=rugarch> |
| Datei in SimLev | `simlev/_r/rugarch.py` |

Nachgebildet ist `ugarchfit(spec, data, solver = "hybrid")` mit `coef()`
für die Spezifikation aus `.fit_garch11` (sGARCH bzw. gjrGARCH(1,1),
ARMA(0,0) mit Mittelwert, Normalverteilung): `.sgarchfit`/`.gjrgarchfit`,
Startwerte und Schranken aus `R/rugarch-startpars.R`, die Likelihood
`.sgarchLLH`/`.gjrgarchLLH` mit dem C-Filter aus `src/garchmodels.c`,
`src/filters.c` und `dnormstd` aus `src/distributions.c`, die Solver-Kette
`.hybridsolver` (solnp → nlminb → zweimal gosolnp), `.makefitmodel` mit
`.hessian2sided`, `robustvcv` und `neweywestcv` aus
`R/rugarch-numderiv.R` und die Warnungen von rugarch. Im R-Paket
entspricht dem `.rugarch_ugarchspec`, `.rugarch_ugarchfit`, `.rugarch_coef`
(`r/R/vendor_rugarch.R`) mit dem C-Filter in `r/src/vendor_rugarch.c`.

## Rsolnp

| | |
|---|---|
| Paket | Rsolnp 1.16 (CRAN, 2015-12-28), *General Non-Linear Optimization* |
| Autoren | Alexios Ghalanos and Stefan Theussl (laut DESCRIPTION von Rsolnp) |
| Lizenz | GPL (DESCRIPTION); GPL-3 laut `inst/COPYRIGHTS` von Rsolnp |
| Quelle | <https://CRAN.R-project.org/package=Rsolnp> |
| Datei in SimLev | `simlev/_r/solnp.py` |

Nachgebildet sind `solnp` mit `.subnp` und den Hilfen sowie `gosolnp`
mit `.randpars` und `.safefun` (ohne `cluster`, `control$eval.type = 2`
und `trace`). Im R-Paket entsprechen dem `.rsolnp_solnp` und
`.rsolnp_gosolnp` (`r/R/vendor_rsolnp.R`).

## Numerische Ableitungen

Numerische Ableitungen (Richardson-Extrapolation) eigenständig
implementiert; Ergebnisse gegen numDeriv geprüft (`simlev/_r/rugarch.py`: `_richardson_hessian`, `_richardson_jacobian`;
im R-Paket `r/R/richardson.R`; kein Code aus numDeriv übernommen).

## truncnorm

| | |
|---|---|
| Paket | truncnorm 1.0-9 (CRAN, 2023-03-20), *Truncated Normal Distribution* |
| Autoren | Olaf Mersmann [aut, cre], Heike Trautmann [aut], Detlef Steuer [aut], Björn Bornkamp [aut] (laut DESCRIPTION von truncnorm) |
| Lizenz | GPL (>= 2), in SimLev unter GPL-3 |
| Quelle | <https://CRAN.R-project.org/package=truncnorm> |
| Datei in SimLev | `simlev/_r/truncnorm.py` |

Nachgebildet ist `rtruncnorm` aus `R/truncnorm.R` mit `do_rtruncnorm` und
den Samplern aus `src/rtruncnorm.c`. Im R-Paket entsprechen dem
`.truncnorm_rtruncnorm` (`r/R/vendor_truncnorm.R`) und
`C_truncnorm_rtruncnorm` (`r/src/vendor_truncnorm.c`).

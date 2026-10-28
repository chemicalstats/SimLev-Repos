# Urheberrecht und Lizenzen

SimLev für Python steht unter der GNU General Public License, Version 3
(GPL-3, siehe `LICENSE.md`). Copyright ChemicalStats von der Mauerstrasse.

SimLev enthält **keinen Code aus anderen Paketen**. Bis Etappe 9 bildete
die Python-Fassung Teile von evd, imputeTS, stinepack, rugarch, Rsolnp und
truncnorm sowie R's Zufallszahlen, Verteilungsfunktionen (nmath), lineare
Algebra (BLAS, LAPACK, LINPACK) und Optimierer (`optim`, `nlminb`) nach;
diese Teile sind entfernt. Zufall und Numerik rechnet jetzt die eigene
C-Bibliothek von SimLev (siehe unten). Die Pakete dienten nur als Vorbild
und Prüforakel; ihre Angaben stehen im Abschnitt
[Literatur](../README.md#literatur) der Haupt-README.

Es bleiben Nachbildungen von **Grundfunktionen von R** (Abschnitt 2). Sie
sind nötig, damit die Python-Fassung zeichengleich zu R rechnet und ausgibt.

## 1. Eigener Code

| Teil | Inhalt |
|---|---|
| `simlev/*.py` | alle Funktionen von SimLev |
| `src/core/` | Kopien der kanonischen C-Quellen aus `core/` (Repo-Wurzel, `tools/core_sync.py`): die C-Bibliothek `slc*.c`, `slc*.h` (Zufall, Verteilungen, lineare Algebra, Optimierer, GARCH/GJR, GPD, DCC, MS-GARCH, Bootstrap-Kerne, Stineman, Glättungsspline, Kerndichte) und die gemeinsamen C++-Kerne `simlev_core.h`, `*_core_impl.h` (Engine, FIFO, Steuer, Research, Entnahme) |
| `src/_ext*.c`, `src/_ext*.cpp`, `src/_ext_common.h` | Hüllen der C-Erweiterung `simlev._ext` |
| `simlev/_lib*.py` | Python-Hüllen der C-Bibliothek |
| `simlev/_r/rlist.py`, `reftree.py`, `env.py` | Ergebnisobjekte, Vergleich mit den Referenzfällen, Umgebungsschalter |

Die C-Bibliothek ist nach Veröffentlichungen geschrieben, nicht nach fremdem
Code. Der Kopf jeder Datei in `core/` nennt ihre Quellen; die vollständigen
Angaben stehen im Abschnitt [Literatur](../README.md#literatur).

## 2. Nachbildungen von R-Grundfunktionen

| | |
|---|---|
| Programm | R 4.3.3 (2024-02-29), *The R Project for Statistical Computing*, <https://www.R-project.org/> |
| Rechteinhaber | laut den Dateiköpfen der genannten R-Quellen: The R Core Team; Robert Gentleman und Ross Ihaka; The R Foundation; einzelne Dateien nennen weitere Personen (siehe Abschnitt 3) |
| Lizenz | GPL (≥ 2) laut den Dateiköpfen; in SimLev unter GPL-3 weitergegeben |

Die Module in `simlev/_r/` übertragen die Rechenweise dieser R-Funktionen
nach Python (gleiche Rechenreihenfolge, `long double`-Summen, gleiche Texte):

| Modul | R-Funktionen | R-Quellen (R 4.3.3) |
|---|---|---|
| `rnum.py`, `base.py` | `sum`, `mean`, `var`, `sd`, `prod`, `cumsum`, `cumprod`, `cummax`, `cummin`, `rowSums`, `colSums`, `rowMeans`, `colMeans`, `pmin`, `pmax`, `range`, `diff`, Potenz `R_POW`, `%%`, Nullstelle `R_zeroin2` | `src/main/summary.c`, `cum.c`, `array.c`, `arithmetic.c`; `src/library/stats/src/zeroin.c` |
| `libm.py` | Randregeln von R um die libm-Funktionen (`log(0) = -Inf` u. a.) | `src/main/arithmetic.c` |
| `rformat.py`, `fmt.py` | `round`, `signif`, `format`, `formatC`, `prettyNum`, `sprintf`, `as.character`, `paste`, `print` von Vektoren, Matrizen, data.frames, Faktoren und Listen, Datumsformate | `src/main/format.c`, `printutils.c`, `printvector.c`, `printarray.c`, `print.c`, `paste.c`, `sprintf.c`, `util.c`; `src/nmath/fround.c`, `fprec.c`; `src/library/base/R/format.R`, `dataframe.R`, `factor.R`, `dates.R` |
| `_collate.py` | Vergleich und Sortierung von Zeichenketten (`Scollate`) | `src/main/util.c` |
| `stats_sort.py` | `order`, `sort`, `rank`, partielle Sortierung, `rle`, `tabulate`, `findInterval`, `cut`, `complete.cases`, `quantile`, `median`, `weighted.mean` | `src/main/sort.c`, `qsort-body.c`, `seq.c`; `src/library/base/R/sort.R`, `rle.R`, `cut.R`, `findInt.R`; `src/library/stats/R/quantile.R`, `median.R`, `weighted.mean.R` |
| `stats_cor.py` | `cor` (Pearson, Kendall, Spearman), `cov`, `var`, `sd`, `cov2cor`, `scale` | `src/library/stats/src/cov.c`, `stats/R/cor.R`; `src/library/base/R/scale.R` |
| `stats_smooth.py` | `approx`, `approxfun`, `filter` | `src/library/stats/R/approx.R`, `filter.R`; `stats/src/approx.c`, `filter.c` |
| `stats_optim.py`, `_optim.py` | `optimize`, `uniroot` | `src/library/stats/R/optimize.R`; `stats/src/optimize.c`, `zeroin.c` |
| `stats_models.py` | `coef`, `fitted`, `residuals`, `p.adjust`, `ecdf`, `ave`, `aggregate` | `src/library/stats/R/lm.R` (Zugriffe), `p.adjust.R`, `ecdf.R`, `ave.R`, `aggregate.R` |
| `stats_cluster.py` | `dist`, `as.dist`, `hclust` | `src/library/stats/R/dist.R`, `hclust.R`; `stats/src/distance.c`, `hclust.f` |
| `linalg.py` | `outer`, `diag`, `isSymmetric`, `all.equal` (numerisch) | `src/library/base/R/outer.R`, `diag.R`, `all.equal.R` |
| `rexpr.py` | Zerlegen und Auswerten von Bedingungen in R-Syntax (Lexer, Grammatik und Vorrang, NA-Logik, Indizierung) | `src/main/gram.y` und die Semantik der Grundoperatoren |
| `parallel.py` | Verhalten von `parallel::mclapply(mc.preschedule = FALSE)` für SimLev's `.par_lapply` (nur das Verhalten: Reihenfolge, Fehler, Ausgaben) | `src/library/parallel/R/unix/mclapply.R` |

## 3. Teile, die in R selbst Übersetzungen älteren Codes sind

Die Dateiköpfe bzw. Kommentare der R-Quellen nennen für einige der
nachgebildeten Funktionen eine ältere Herkunft:

| Funktion | Herkunft laut R-Quelle |
|---|---|
| `optimize` (`Brent_fmin`) | `optimize.c`: „fmin.f -- translated by f2c“, Brents Verfahren `fmin` (Netlib) |
| `uniroot` (`R_zeroin2`, auch `r_uniroot` der Engine) | `zeroin.c`: „from NETLIB c/brent.shar with max.iter, add'l info and convergence details hacked in by Peter Dalgaard“ |
| `hclust` | `hclust.f`: „F. Murtagh, ESA/ESO/STECF, Garching, February 1986. Modifications for R: Ross Ihaka, Dec 1996“ |
| Sortierung (`qsort-body.c`) | „Based on CACM algorithm #347 by R. C. Singleton (1969)“ |
| `signif` (`fprec.c`) | „a translation into C of a Fortran subroutine by W. Fullerton of Los Alamos Scientific Laboratory“ |
| `sprintf` (`sprintf.c`) | „Originally written by Jonathan Rougier“ |
| Parser (`gram.y`) | Rechteinhaber zusätzlich Romain Francois (2009–2011) |

## 4. Zur Laufzeit genutzt, nicht enthalten

- glibc-libm (mathematische Funktionen über das Modul `math`),
- die System-ICU (`libicui18n`, Kollation über ctypes),
- numpy und pandas (Datenhaltung).

Die Pakete evd, imputeTS, stinepack, rugarch, Rsolnp, truncnorm, MSGARCH und
numDeriv sind weder enthalten noch eine Abhängigkeit (siehe
[Literatur](../README.md#literatur)).

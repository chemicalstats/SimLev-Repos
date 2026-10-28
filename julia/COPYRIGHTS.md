# Urheberrecht und Lizenzen

SimLev für Julia steht unter der GNU General Public License, Version 3
(GPL-3, siehe `LICENSE.md`). Copyright ChemicalStats von der Mauerstrasse.

SimLev enthält **keinen Code aus anderen Paketen**. Bis Etappe 9 bildete
die Julia-Fassung Teile von evd, imputeTS, stinepack, rugarch, Rsolnp und
truncnorm sowie R's Zufallszahlen, Verteilungsfunktionen (nmath), lineare
Algebra (BLAS, LAPACK, LINPACK) und Optimierer (`optim`, `nlminb`) nach;
diese Teile sind entfernt. Zufall und Numerik rechnet jetzt die eigene
C-Bibliothek von SimLev (siehe unten). Die Pakete dienten nur als Vorbild
und Prüforakel; ihre Angaben stehen im Abschnitt
[Literatur](../README.md#literatur) der Haupt-README.

Es bleiben Nachbildungen von **Grundfunktionen von R** (Abschnitt 2) und
das nachgebildete Sortierverhalten der C++-Standardbibliothek (Abschnitt 4).
Sie sind nötig, damit die Julia-Fassung zeichengleich zu R rechnet und
ausgibt.

## 1. Eigener Code

| Teil | Inhalt |
|---|---|
| `src/*.jl` | alle Funktionen von SimLev, einschließlich der Ports der eigenen C++-Kerne (`core.jl`, `signals_core.jl`, `withdrawal_core.jl`, `dependence_core.jl`, `optimize_core.jl`) |
| `src/slib*.jl` | Hüllen der C-Bibliothek per `ccall` |
| `deps/core/` | Kopien der kanonischen C-Quellen aus `core/` (Repo-Wurzel, `tools/core_sync.py`): die C-Bibliothek `slc*.c`, `slc*.h` (Zufall, Verteilungen, lineare Algebra, Optimierer, GARCH/GJR, GPD, DCC, MS-GARCH, Bootstrap-Kerne, Stineman, Glättungsspline, Kerndichte) |
| `deps/build.jl` | Bau der C-Bibliothek |
| `src/r/types.jl`, `ld80.jl`, `env.jl` | R-Datenstrukturen, der Typ `F80` (x87-`long double`, Hardware und Software-Nachbau), Umgebungsschalter |

Die C-Bibliothek ist nach Veröffentlichungen geschrieben, nicht nach fremdem
Code. Der Kopf jeder Datei in `core/` nennt ihre Quellen; die vollständigen
Angaben stehen im Abschnitt [Literatur](../README.md#literatur).

## 2. Nachbildungen von R-Grundfunktionen

| | |
|---|---|
| Programm | R 4.3.3 (2024-02-29), *The R Project for Statistical Computing*, <https://www.R-project.org/> |
| Rechteinhaber | laut den Dateiköpfen der genannten R-Quellen: The R Core Team; Robert Gentleman und Ross Ihaka; The R Foundation; einzelne Dateien nennen weitere Personen (siehe Abschnitt 3) |
| Lizenz | GPL (≥ 2) laut den Dateiköpfen; in SimLev unter GPL-3 weitergegeben |

Die Dateien in `src/r/` übertragen die Rechenweise dieser R-Funktionen nach
Julia (Vorlage war jeweils die Python-Fassung, maßgeblich R):

| Datei | R-Funktionen | R-Quellen (R 4.3.3) |
|---|---|---|
| `rnum.jl`, `base.jl` | `sum`, `mean`, `var`, `sd`, `prod`, `cumsum`, `cumprod`, `cummax`, `cummin`, `rowSums`, `colSums`, `rowMeans`, `colMeans`, `pmin`, `pmax`, `range`, `diff`, Potenz `R_POW`, `%%`, Nullstelle `R_zeroin2` | `src/main/summary.c`, `cum.c`, `array.c`, `arithmetic.c`; `src/library/stats/src/zeroin.c` |
| `libm.jl` | Randregeln von R um die libm-Funktionen | `src/main/arithmetic.c` |
| `rformat.jl`, `fmt.jl`, `_fmt_core.jl`, `_fmt_format.jl`, `_fmt_print.jl` | `round`, `signif`, `format`, `formatC`, `prettyNum`, `sprintf`, `as.character`, `deparse` (einfache Werte), `paste`, `print` von Vektoren, Matrizen, data.frames, Faktoren und Listen, `cat`, Datumsformate | `src/main/format.c`, `printutils.c`, `printvector.c`, `printarray.c`, `print.c`, `paste.c`, `sprintf.c`, `util.c`; `src/nmath/fround.c`, `fprec.c`; `src/library/base/R/format.R`, `dataframe.R`, `factor.R`, `dates.R` |
| `_collate.jl` | Vergleich und Sortierung von Zeichenketten (`Scollate`) | `src/main/util.c` |
| `stats_sort.jl` | `order`, `sort`, `rank`, partielle Sortierung, `rle`, `tabulate`, `findInterval`, `cut`, `complete.cases`, `quantile`, `median`, `weighted.mean` | `src/main/sort.c`, `qsort-body.c`, `seq.c`; `src/library/base/R/sort.R`, `rle.R`, `cut.R`, `findInt.R`; `src/library/stats/R/quantile.R`, `median.R`, `weighted.mean.R` |
| `stats_cor.jl` | `cor` (Pearson, Kendall, Spearman), `cov`, `var`, `sd`, `cov2cor`, `scale` | `src/library/stats/src/cov.c`, `stats/R/cor.R`; `src/library/base/R/scale.R` |
| `stats_smooth.jl` | `approx`, `approxfun`, `filter` | `src/library/stats/R/approx.R`, `filter.R`; `stats/src/approx.c`, `filter.c` |
| `stats_optim.jl`, `_optim.jl` | `optimize`, `uniroot` | `src/library/stats/R/optimize.R`; `stats/src/optimize.c`, `zeroin.c` |
| `stats_models.jl` | `coef`, `fitted`, `residuals`, `p.adjust`, `ecdf`, `ave`, `aggregate` | `src/library/stats/R/lm.R` (Zugriffe), `p.adjust.R`, `ecdf.R`, `ave.R`, `aggregate.R` |
| `stats_cluster.jl` | `dist`, `as.dist`, `hclust` | `src/library/stats/R/dist.R`, `hclust.R`; `stats/src/distance.c`, `hclust.f` |
| `linalg.jl` | `outer`, `diag`, `isSymmetric`, `all.equal` (numerisch) | `src/library/base/R/outer.R`, `diag.R`, `all.equal.R` |
| `rexpr.jl` | Zerlegen und Auswerten von Bedingungen in R-Syntax (Lexer, Grammatik und Vorrang, NA-Logik, Indizierung) | `src/main/gram.y` und die Semantik der Grundoperatoren |
| `parallel.jl` | Verhalten von `parallel::mclapply(mc.preschedule = FALSE)` für SimLev's `.par_lapply` (nur das Verhalten: Reihenfolge, Fehler, Ausgaben) | `src/library/parallel/R/unix/mclapply.R` |

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

## 4. Nachgebildetes Verhalten von libstdc++ und glibc

| Teil | Herkunft | Lizenz des Vorbilds |
|---|---|---|
| `std::sort` (Introsort) und `std::nth_element` der GCC-13-Standardbibliothek, nachgebildet in `src/dependence_core.jl` (`_std_sort!`) und `src/optimize_core.jl`, damit die Julia-Ports der eigenen C++-Kerne Gleichstände in derselben Reihenfolge ordnen wie der R-Bau | libstdc++ (GNU ISO C++ Library), `bits/stl_algo.h` (Free Software Foundation; Teile Hewlett-Packard 1994, Silicon Graphics 1996) | GPL-3 mit GCC Runtime Library Exception 3.1 (laut Dateikopf) |
| Tabelle `powl(10.0L, k)` für k = −350 … 350 in `src/r/_fmt_powl.jl`: Ausgabewerte der glibc-Funktion `powl`, erzeugt mit einem C-Programm (kein Code aus glibc) | glibc | – |

## 5. Zur Laufzeit genutzt, nicht enthalten

- glibc (libm über `ccall`, `snprintf` für die Zahlenformatierung),
- die System-ICU (`libicui18n`, Kollation über `ccall`),
- ein C-Compiler beim Bau (`deps/build.jl`).

Die Pakete evd, imputeTS, stinepack, rugarch, Rsolnp, truncnorm, MSGARCH und
numDeriv sind weder enthalten noch eine Abhängigkeit (siehe
[Literatur](../README.md#literatur)).

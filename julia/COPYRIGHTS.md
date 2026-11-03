# Urheberrecht und Lizenzen

SimLev für Julia steht unter der GNU General Public License, Version 3
(GPL-3, siehe `LICENSE.md`). Copyright ChemicalStats von der Mauerstrasse.

SimLev enthält **keinen Code aus anderen Paketen**. Die Julia-Fassung
enthält Nachbildungen von **Grundfunktionen von R** (Abschnitt 2.1–2.3),
damit sie zeichengleich zu R rechnet und ausgibt, und gemeinfreie
Kalenderalgorithmen (Abschnitt 2.4). Die gleiche Gliederung haben
`r/inst/COPYRIGHTS` und `python/COPYRIGHTS.md` im Repository.

## Herkunftsschema

Jede Datei oder jeder Dateiteil mit fremder Vorlage trägt im Kopf (bei einem
Teil: direkt davor) einen Herkunftsblock mit diesen Feldern in dieser
Reihenfolge; C und C++ im Kopfkommentar (`/* … */` bzw. `//`), Python,
Julia und R als `#`-Zeilen:

| Feld | Inhalt |
|---|---|
| `Teil:` | nur wenn der Block einen Teil der Datei betrifft: die Funktionen |
| `Herkunft:` | `eigen` (ohne fremde Vorlage, nach Veröffentlichungen und Mathematik) · `nachgebildet nach <Vorlage>` (Verhalten bzw. Aufbau nach der Vorlage, nicht Zeile für Zeile) · `übersetzt aus <Vorlage, Datei>` (Code Schritt für Schritt in eine andere Sprache oder Form übertragen) |
| `Rechte:` | Rechteinhaber bzw. Urheber laut Vorlage |
| `Lizenz der Vorlage:` | Lizenz laut Vorlage; bei GPL (≥ 2): „in SimLev unter GPL-3“ |
| `Änderungen:` | was SimLev gegenüber der Vorlage geändert hat |

Dateien ohne Herkunftsblock sind eigener Code. Die Einträge in Abschnitt 2
haben dieselben Felder, dazu `Dateien:`.

## 1. Eigener Code

| Teil | Inhalt |
|---|---|
| `src/*.jl` | alle Funktionen von SimLev (Ausnahme: Kalenderteile, Abschnitt 2.4); `core.jl`, `signals_core.jl`, `withdrawal_core.jl`, `dependence_core.jl`, `optimize_core.jl` rufen seit 1.2.0 die gemeinsamen C++-Kerne über `cabi.jl` auf |
| `src/slib*.jl` | Hüllen der C-Bibliothek per `ccall` |
| `deps/core/` | Kopien der kanonischen C-Quellen aus `core/` (Repo-Wurzel, `core/sync.py`): die C-Bibliothek `slc*.c`, `slc*.h` **ohne `slc_rbase*`** (Zufall, Verteilungen, lineare Algebra, Optimierer, GARCH/GJR, GPD, DCC, MS-GARCH, Bootstrap-Kerne, Stineman, Glättungsspline, Kerndichte), die gemeinsamen C++-Kerne `simlev_core.h`, `*_core_impl.h` (Engine, FIFO, Steuer, Research, Entnahme) und ihre C-ABI-Hülle `simlev_cabi.cpp` |
| `deps/build.jl` | Bau der C-Bibliothek |
| `src/r/types.jl`, `env.jl`, `stats.jl`, `rbase_c.jl` | R-Datenstrukturen, Umgebungsschalter, Sammelmodul, Hülle der Kerne aus 2.2 |

Die C-Bibliothek (ohne `slc_rbase*`) ist nach Veröffentlichungen
geschrieben, nicht nach fremdem Code. Der Kopf jeder Datei in `core/` nennt
ihre Quellen; die vollständigen Angaben stehen in
[`LITERATUR.md`](../LITERATUR.md).

## 2. Fremde Vorlagen

### 2.1 R-Grundfunktionen in den Port-Modulen

| | |
|---|---|
| Dateien | `src/r/`: `rnum.jl`, `base.jl`, `libm.jl`, `rformat.jl`, `fmt.jl`, `_fmt_core.jl`, `_fmt_format.jl`, `_fmt_print.jl`, `_collate.jl`, `stats_sort.jl`, `stats_cor.jl`, `stats_smooth.jl`, `stats_optim.jl`, `_optim.jl`, `stats_models.jl`, `stats_cluster.jl`, `linalg.jl`, `rexpr.jl`, `parallel.jl` |
| Herkunft | übersetzt aus bzw. nachgebildet nach R 4.3.3 (*The R Project for Statistical Computing*, <https://www.R-project.org/>), je Datei siehe Tabelle und Kopf der Datei |
| Rechte | The R Core Team, teils Robert Gentleman und Ross Ihaka, The R Foundation (laut Kopf der jeweiligen R-Quelle); weitere Personen siehe 2.3 |
| Lizenz der Vorlage | GPL (≥ 2) laut Kopf der R-Quellen; in SimLev unter GPL-3 |
| Änderungen | Übertragung nach Julia (nach den Gegenstücken in R und Python) im von SimLev genutzten Umfang; Teile rechnen seit 1.2.0 die C-Kerne aus 2.2 |

| Datei | Herkunft | R-Funktionen |
|---|---|---|
| `rnum.jl`, `base.jl` | übersetzt aus `src/main/summary.c`, `cum.c`, `array.c`, `arithmetic.c` | `sum`, `mean`, `var`, `sd`, `prod`, `cumsum`, `cumprod`, `cummax`, `cummin`, `rowSums`, `colSums`, `rowMeans`, `colMeans`, `pmin`, `pmax`, `range`, `diff`, `R_POW`, `%%` |
| `libm.jl` | nachgebildet nach `src/main/arithmetic.c` | Randregeln um die libm-Funktionen |
| `rformat.jl`, `fmt.jl`, `_fmt_core.jl`, `_fmt_format.jl`, `_fmt_print.jl` | übersetzt aus `src/main/format.c`, `printutils.c`, `printvector.c`, `printarray.c`, `print.c`, `paste.c`, `sprintf.c`, `util.c`, `src/nmath/fround.c`, `fprec.c`; nachgebildet nach `base/R/format.R`, `dataframe.R`, `factor.R`, `dates.R` | `round`, `signif`, `format`, `formatC`, `prettyNum`, `sprintf`, `as.character`, `deparse` (einfache Werte), `paste`, `print`, `cat`, Datumsformate |
| `_collate.jl` | nachgebildet nach `src/main/util.c` | `Scollate` |
| `stats_sort.jl` | übersetzt aus `src/main/sort.c`, `qsort-body.c`, `seq.c`; nachgebildet nach `base/R/sort.R`, `rle.R`, `cut.R`, `findInt.R`, `stats/R/quantile.R`, `median.R`, `weighted.mean.R` | `order`, `sort`, `rank`, partielle Sortierung, `rle`, `tabulate`, `findInterval`, `cut`, `complete.cases`, `quantile`, `median`, `weighted.mean` |
| `stats_cor.jl` | übersetzt aus `stats/src/cov.c`; nachgebildet nach `stats/R/cor.R`, `base/R/scale.R` | `cor`, `cov`, `var`, `sd`, `cov2cor`, `scale` |
| `stats_smooth.jl` | übersetzt aus `stats/src/approx.c`, `filter.c`; nachgebildet nach `stats/R/approx.R`, `filter.R` | `approx`, `approxfun`, `filter` |
| `stats_optim.jl`, `_optim.jl` | übersetzt aus `stats/src/optimize.c`, `zeroin.c`; nachgebildet nach `stats/R/optimize.R`, `nlm.R` | `optimize`, `uniroot` |
| `stats_models.jl` | nachgebildet nach `stats/R/lm.R` (Zugriffe), `p.adjust.R`, `ecdf.R`, `ave.R`, `aggregate.R` | `coef`, `fitted`, `residuals`, `p.adjust`, `ecdf`, `ave`, `aggregate` |
| `stats_cluster.jl` | übersetzt aus `stats/src/distance.c`, `hclust.f`; nachgebildet nach `stats/R/dist.R`, `hclust.R` | `dist`, `as.dist`, `hclust` |
| `linalg.jl` | nachgebildet nach `base/R/outer.R`, `diag.R`, `all.equal.R` | `outer`, `diag`, `isSymmetric`, `all.equal` (numerisch) |
| `rexpr.jl` | nachgebildet nach `src/main/gram.y` und der Semantik der Grundoperatoren | Bedingungen in R-Syntax |
| `parallel.jl` | nachgebildet nach `parallel/R/unix/mclapply.R` (nur Verhalten) | `mclapply(mc.preschedule = FALSE)` für `.par_lapply` |

### 2.2 C-Kerne mit R-Regeln (`slc_rbase*`)

| | |
|---|---|
| Dateien | `deps/core/slc_rbase.h`, `slc_rbase.c`, `slc_rbase_sort.c`, `slc_rbase_cov.c`, `slc_rbase_num.c`, `slc_rbase_date.c` (Hülle `src/r/rbase_c.jl`; seit 1.4.0 sind `slc_rbase.c` und `slc_rbase.h` auch im R-Paket, für die Summen der Tagesengine `engine_core_impl.h` und für die Auswertung `evaluate_core_impl.h`) |
| Herkunft | übersetzt aus R 4.3.3 über die Port-Module aus 2.1: `slc_rbase.c` aus `summary.c`, `cum.c`, `array.c`, `arithmetic.c`, `stats/src/zeroin.c` (seit 1.4.0, `sl_r_zeroin2`), `stats/src/approx.c` (seit 1.5.0, `sl_r_approx`); `slc_rbase_sort.c` aus `sort.c` (`psort_body`, `Psort0`) und `qsort-body.c` (Schritt für Schritt); `slc_rbase_cov.c` aus `stats/src/cov.c`; `slc_rbase_num.c` aus `util.c` (`R_strtod`), `arithmetic.c` (`myfmod`), `format.c` (`scientific`). `slc_rbase_date.c`: nachgebildet nach den R-Hilfeseiten `?strptime`, `?format.Date`, `?as.Date`, Kalender nach 2.4 |
| Rechte | wie 2.1; Quicksort nach R. C. Singleton (siehe 2.3) |
| Lizenz der Vorlage | GPL (≥ 2) laut Kopf der R-Quellen; in SimLev unter GPL-3 |
| Änderungen | C99 ohne R-Datenstrukturen, gemeinsamer Kern für Python und Julia; je Datei im Kopf genannt |

### 2.3 Ältere Herkunft innerhalb der R-Vorlagen

| | |
|---|---|
| Dateien | wie in der Tabelle; jeweils im Herkunftsblock der Datei genannt |
| Herkunft | laut Kopf bzw. Kommentar der R-Quelle, siehe Tabelle |
| Rechte | siehe Tabelle |
| Lizenz der Vorlage | in R unter GPL (≥ 2); die älteren Vorlagen selbst wie in der Tabelle |
| Änderungen | wie 2.1 bzw. 2.2 |

| Funktion (Dateien) | Herkunft laut R-Quelle | Lizenzvermerk der älteren Vorlage |
|---|---|---|
| `optimize` (`_optim.jl`, `stats_optim.jl`) | `optimize.c`: „fmin.f -- translated by f2c“; Netlib `go/fmin.f`: Übersetzung von Brents ALGOL-60-Prozedur `localmin` (R. P. Brent, *Algorithms for Minimization without Derivatives*, Prentice-Hall 1973) | keiner (Netlib-Datei ohne Urheber- und Lizenzvermerk) |
| `uniroot` (`_optim.jl`, `stats_optim.jl`; seit 1.4.0 `.xirr_rate` über `sl_r_zeroin2` in `deps/core/slc_rbase.c`) | `zeroin.c`: „from NETLIB c/brent.shar with max.iter, add'l info and convergence details hacked in by Peter Dalgaard“; Netlib `go/zeroin.f`: Übersetzung von Brents Prozedur `zero` (Brent 1973) | `go/zeroin.f`: keiner; `c/brent.shar`: nicht geprüft (Abruf nicht möglich) |
| `hclust` (`stats_cluster.jl`) | `hclust.f`: „F. Murtagh, ESA/ESO/STECF, Garching, February 1986. Modifications for R: Ross Ihaka, Dec 1996“, weitere Änderungen Fritz Leisch, Martin Maechler | keiner in `hclust.f` |
| Sortierung (`stats_sort.jl`, `slc_rbase_sort.c`) | `qsort-body.c`: „Based on CACM algorithm #347 by R. C. Singleton (1969)“ | ACM-Software-Hinweis (Nutzung „solely for academic, research and other similar noncommercial uses“), Anwendbarkeit auf R's Umarbeitung nicht belegt |
| `signif` (`rformat.jl`, `fmt.jl`, `_fmt_core.jl`) | `fprec.c`: „a translation into C of a Fortran subroutine by W. Fullerton of Los Alamos Scientific Laboratory“ | keiner genannt |
| `sprintf` (`rformat.jl`, `fmt.jl`, `_fmt_core.jl`) | `sprintf.c`: „Originally written by Jonathan Rougier“ | GPL (≥ 2) wie die Datei |
| Parser (`rexpr.jl`) | `gram.y`: Rechteinhaber zusätzlich Romain Francois (2009–2011) | GPL (≥ 2) wie die Datei |

### 2.4 Kalenderrechnung nach Hinnant

| | |
|---|---|
| Dateien | `deps/core/prepare_core_impl.h` (`eng_civil`, `eng_days`; bis 1.3.0 `engine_core_impl.h`, davor `fifo_core_impl.h`, `tax_core_impl.h`), `deps/core/slc_rbase_date.c` (`sl_r_civil_from_days`, `sl_r_days_from_civil`), `src/data_prep.jl` (`_civil_to_days`, `_days_to_civil`) |
| Herkunft | übersetzt aus H. Hinnant, *chrono-Compatible Low-Level Date Algorithms*, <https://howardhinnant.github.io/date_algorithms.html> |
| Rechte | gemeinfrei: „Consider these donated to the public domain.“ |
| Lizenz der Vorlage | keine (gemeinfrei) |
| Änderungen | feste Ganzzahltypen; je Stelle im Herkunftsblock genannt |

## 3. Zur Laufzeit oder beim Bau genutzt, nicht enthalten

- glibc (libm, `snprintf` für die Zahlenformatierung, `powl`; über `ccall`
  bzw. die C-Kerne),
- die System-ICU (`libicui18n`, Kollation über `ccall`),
- beim Bau ein C/C++-Compiler (`deps/build.jl`); die C++-Kerne nutzen
  `std::sort` und `std::nth_element` über die Header der Standardbibliothek
  des Compilers (bei GCC libstdc++: GPL-3 mit GCC Runtime Library
  Exception 3.1).

Die Pakete evd, imputeTS, stinepack, rugarch, Rsolnp, truncnorm, MSGARCH und
numDeriv sind weder enthalten noch eine Abhängigkeit (siehe
[`LITERATUR.md`](../LITERATUR.md)).

## 4. Früher enthaltene Teile (entfernt)

Bis 0.10.0 bildete die Julia-Fassung Teile von evd, imputeTS, stinepack,
rugarch, Rsolnp und truncnorm sowie R's Zufallszahlen, Verteilungsfunktionen
(nmath), lineare Algebra (BLAS, LAPACK, LINPACK) und Optimierer (`optim`,
`nlminb`) nach; diese Teile sind entfernt (1.0.0). Mit 1.2.0 entfiel die
Übersetzung von libstdc++ `std::sort`/`std::nth_element` (`_std_sort!` u. a.
in `src/dependence_core.jl`, `src/optimize_core.jl`; Vorlage `bits/stl_algo.h`,
Free Software Foundation, Teile Hewlett-Packard 1994 und Silicon Graphics
1996, GPL-3 mit GCC Runtime Library Exception 3.1), mit 1.2.0 die Tabelle der
glibc-Werte `powl(10.0L, k)` (`src/r/_fmt_powl.jl`) und die long-double-
Nachbildung `src/r/ld80.jl`. Zufall und Numerik rechnet die eigene
C-Bibliothek von SimLev. Die Pakete dienten nur als Vorbild und
Prüforakel; ihre Angaben stehen in
[`LITERATUR.md`](../LITERATUR.md) im Wurzelverzeichnis.

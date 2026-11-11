# Urheberrecht und Lizenzen

SimLev für Python steht unter der GNU General Public License, Version 3
(GPL-3, siehe `LICENSE.md`). Copyright ChemicalStats von der Mauerstrasse.

SimLev enthält **keinen Code aus anderen Paketen**. Die Python-Fassung
enthält Nachbildungen von **Grundfunktionen von R** (Abschnitt 2.1–2.3),
damit sie zeichengleich zu R rechnet und ausgibt, und gemeinfreie
Kalenderalgorithmen (Abschnitt 2.4). Die gleiche Gliederung haben
`r/inst/COPYRIGHTS` und `julia/COPYRIGHTS.md` im Repository.

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
| `simlev/*.py` | alle Funktionen von SimLev (Ausnahme: Kalenderteile, Abschnitt 2.4) |
| `src/core/` | Kopien der kanonischen C-Quellen aus `core/` (Repo-Wurzel, `core/sync.py`): die C-Bibliothek `slc*.cpp`, `slc*.h` **ohne `slc_rbase*`** (Zufall, Verteilungen, lineare Algebra, Optimierer, GARCH/GJR, GPD, DCC, MS-GARCH, Bootstrap-Kerne, Stineman, Glättungsspline, Kerndichte) und die gemeinsamen C++-Kerne `simlev_core.h`, `*_core_impl.h` (Engine, FIFO, Steuer, Research, Entnahme) |
| `src/_ext*.c`, `src/_ext*.cpp`, `src/_ext_common.h` | Hüllen der C-Erweiterung `simlev._ext` |
| `simlev/_lib*.py` | Python-Hüllen der C-Bibliothek |
| `simlev/_r/rlist.py`, `env.py`, `stats.py`, `__init__.py` | Ergebnisobjekte, Umgebungsschalter, Sammelmodule |

Die C-Bibliothek (ohne `slc_rbase*`) ist nach Veröffentlichungen
geschrieben, nicht nach fremdem Code. Der Kopf jeder Datei in `core/` nennt
ihre Quellen; die vollständigen Angaben stehen in
[`LITERATUR.md`](../LITERATUR.md).

## 2. Fremde Vorlagen

### 2.1 R-Grundfunktionen in den Port-Modulen

| | |
|---|---|
| Dateien | `simlev/_r/`: `rnum.py`, `base.py`, `libm.py`, `rformat.py`, `fmt.py`, `_collate.py`, `stats_sort.py`, `stats_cor.py`, `stats_smooth.py`, `stats_optim.py`, `stats_models.py`, `stats_cluster.py`, `linalg.py`, `rexpr.py`, `parallel.py` |
| Herkunft | übersetzt aus bzw. nachgebildet nach R 4.3.3 (*The R Project for Statistical Computing*, <https://www.R-project.org/>), je Datei siehe Tabelle und Kopf der Datei |
| Rechte | The R Core Team, teils Robert Gentleman und Ross Ihaka, The R Foundation (laut Kopf der jeweiligen R-Quelle); weitere Personen siehe 2.3 |
| Lizenz der Vorlage | GPL (≥ 2) laut Kopf der R-Quellen; in SimLev unter GPL-3 |
| Änderungen | Übertragung nach Python im von SimLev genutzten Umfang; Teile rechnen seit 1.2.0 die C-Kerne aus 2.2 |

| Datei | Herkunft | R-Funktionen |
|---|---|---|
| `rnum.py`, `base.py` | übersetzt aus `src/main/summary.c`, `cum.c`, `array.c`, `arithmetic.c` | `sum`, `mean`, `var`, `sd`, `prod`, `cumsum`, `cumprod`, `cummax`, `rowSums`, `colSums`, `rowMeans`, `colMeans` (über `rnum`), `pmin`, `pmax`, `range`, `diff`, `R_POW` |
| `libm.py` | nachgebildet nach `src/main/arithmetic.c` | Randregeln um die libm-Funktionen |
| `rformat.py`, `fmt.py` | übersetzt aus `src/main/format.c`, `printutils.c`, `printvector.c`, `printarray.c`, `print.c`, `paste.c`, `sprintf.c`, `util.c`, `src/nmath/fround.c`, `fprec.c`; nachgebildet nach `base/R/format.R`, `dataframe.R`, `factor.R`, `dates.R` | `round`, `signif`, `format`, `formatC`, `sprintf`, `as.character`, `paste`, `print`, Datumsformate |
| `_collate.py` | nachgebildet nach `src/main/util.c` | `Scollate` |
| `stats_sort.py` | übersetzt aus `src/main/sort.c`, `qsort-body.c`, `seq.c`; nachgebildet nach `base/R/sort.R`, `cut.R`, `stats/R/quantile.R`, `median.R` | `order`, `sort`, `rank`, partielle Sortierung, `cut`, `quantile`, `median` |
| `stats_cor.py` | übersetzt aus `stats/src/cov.c`; nachgebildet nach `stats/R/cor.R`, `base/R/scale.R` | `cor`, `cov`, `var`, `sd`, `cov2cor`, `scale` |
| `stats_smooth.py` | übersetzt aus `stats/src/approx.c`, `filter.c`; nachgebildet nach `stats/R/approx.R`, `filter.R` | `approx`, `filter` |
| `stats_optim.py` (`_optim.py` bis 1.5.2) | nachgebildet nach `stats/src/optimize.c` (`do_fmin`, `fcn1`) und `stats/R/optimize.R`; `Brent_fmin` seit 1.6.0 im Kern (`core/slc_opt_fmin.cpp`, Herkunftsblock dort) | `optimize` (`uniroot` bis 1.5.1) |
| `stats_models.py` | nachgebildet nach `stats/R/lm.R` (Zugriffe), `p.adjust.R` | `coef`, `fitted`, `residuals`, `p.adjust` |
| `stats_cluster.py` | übersetzt aus `stats/src/distance.c`, `hclust.f`; nachgebildet nach `stats/R/dist.R`, `hclust.R` | `dist`, `as.dist`, `hclust` |
| `linalg.py` | nachgebildet nach `base/R/outer.R`, `diag.R`, `all.equal.R` | `outer`, `diag`, `isSymmetric`, `all.equal` (numerisch) |
| `rexpr.py` | nachgebildet nach `src/main/gram.y` und der Semantik der Grundoperatoren | Bedingungen in R-Syntax |
| `parallel.py` | nachgebildet nach `parallel/R/unix/mclapply.R` (nur Verhalten) | `mclapply(mc.preschedule = FALSE)` für `.par_lapply` |

### 2.2 C-Kerne mit R-Regeln (`slc_rbase*`)

| | |
|---|---|
| Dateien | `src/core/slc_rbase.h`, `slc_rbase.cpp`, `slc_rbase_sort.cpp`, `slc_rbase_cov.cpp`, `slc_rbase_num.cpp`, `slc_rbase_date.cpp`, seit 1.6.0 `slc_rbase2.h`, `slc_rbase_clust.cpp`, `slc_rbase_vec.cpp`, `slc_rbase_cor.cpp`, `slc_rbase_smooth.cpp`, `slc_rbase_models.cpp`, `slc_rbase_fmt.cpp` (Hüllen `src/_ext_slc_rbase.cpp`, `src/_ext_slc_rbase2.cpp`; seit 1.4.0 sind `slc_rbase.cpp` und `slc_rbase.h` auch im R-Paket, für die Summen der Tagesengine `engine_core_impl.h` und für die Auswertung `evaluate_core_impl.h`, seit 1.6.4 auch `slc_rbase2.h`, `slc_rbase_cov.cpp`, `slc_rbase_smooth.cpp` und `slc_rbase_clust.cpp` für cov/cor/var/sd, approx, filter, dist und hclust in R) |
| Herkunft | übersetzt aus R 4.3.3 über die Port-Module aus 2.1: `slc_rbase.cpp` aus `summary.c`, `cum.c`, `array.c`, `arithmetic.c`, `stats/src/zeroin.c` (seit 1.4.0, `sl_r_zeroin2`), `stats/src/approx.c` (seit 1.5.0, `sl_r_approx`); `slc_rbase_sort.cpp` aus `sort.c` (`psort_body`, `Psort0`) und `qsort-body.c` (Schritt für Schritt); `slc_rbase_cov.cpp` aus `stats/src/cov.c`; `slc_rbase_num.cpp` aus `util.c` (`R_strtod`), `arithmetic.c` (`myfmod`), `format.c` (`scientific`); seit 1.6.0 `slc_rbase_clust.cpp` aus `stats/src/distance.c` und `hclust.f`, `slc_rbase_vec.cpp` aus `util.c` (`bincode`), `seq.c` und `median.R`, `slc_rbase_cor.cpp` aus `cor.R` und `scale.R`, `slc_rbase_smooth.cpp` aus `approx.R` (`regularize.values`) und `filter.c`, `slc_rbase_models.cpp` aus `p.adjust.R` und `ecdf.R`, `slc_rbase_fmt.cpp` aus `nmath/fround.c`, `fprec.c`, `format.c` (`formatReal`), `printutils.c` (`encodeReal0`), `util.c` (`str_signif`) und `sprintf.c` (sprintf.c: ursprünglich Jonathan Rougier). `slc_rbase_date.cpp`: nachgebildet nach den R-Hilfeseiten `?strptime`, `?format.Date`, `?as.Date`, Kalender nach 2.4 |
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
| `optimize` (`stats_optim.py`; `Brent_fmin` seit 1.6.0 in `core/slc_opt_fmin.cpp`, bis 1.5.2 `_optim.py`) | `optimize.c`: „fmin.f -- translated by f2c“; Netlib `go/fmin.f`: Übersetzung von Brents ALGOL-60-Prozedur `localmin` (R. P. Brent, *Algorithms for Minimization without Derivatives*, Prentice-Hall 1973) | keiner (Netlib-Datei ohne Urheber- und Lizenzvermerk) |
| `R_zeroin2` (seit 1.4.0 `.xirr_rate` über `sl_r_zeroin2` in `src/core/slc_rbase.cpp`; Port `uniroot` in `_optim.py`, `stats_optim.py` bis 1.5.1) | `zeroin.c`: „from NETLIB c/brent.shar with max.iter, add'l info and convergence details hacked in by Peter Dalgaard“; Netlib `go/zeroin.f`: Übersetzung von Brents Prozedur `zero` (Brent 1973) | `go/zeroin.f`: keiner; `c/brent.shar`: nicht geprüft (Abruf nicht möglich) |
| `hclust` (`stats_cluster.py`) | `hclust.f`: „F. Murtagh, ESA/ESO/STECF, Garching, February 1986. Modifications for R: Ross Ihaka, Dec 1996“, weitere Änderungen Fritz Leisch, Martin Maechler | keiner in `hclust.f` |
| Sortierung (`stats_sort.py`, `slc_rbase_sort.cpp`) | `qsort-body.c`: „Based on CACM algorithm #347 by R. C. Singleton (1969)“ | ACM-Software-Hinweis (Nutzung „solely for academic, research and other similar noncommercial uses“), Anwendbarkeit auf R's Umarbeitung nicht belegt |
| `signif` (`rformat.py`, `fmt.py`) | `fprec.c`: „a translation into C of a Fortran subroutine by W. Fullerton of Los Alamos Scientific Laboratory“ | keiner genannt |
| `sprintf` (`rformat.py`, `fmt.py`) | `sprintf.c`: „Originally written by Jonathan Rougier“ | GPL (≥ 2) wie die Datei |
| Parser (`rexpr.py`) | `gram.y`: Rechteinhaber zusätzlich Romain Francois (2009–2011) | GPL (≥ 2) wie die Datei |

### 2.4 Kalenderrechnung nach Hinnant

| | |
|---|---|
| Dateien | `src/core/prepare_core_impl.h` (`eng_civil`, `eng_days`; bis 1.3.0 `engine_core_impl.h`, davor `fifo_core_impl.h`, `tax_core_impl.h`), `src/core/slc_rbase_date.cpp` (`sl_r_civil_from_days`, `sl_r_days_from_civil`), `simlev/data_prep.py` (`_civil_to_days`, `_days_to_civil`; seit 1.6.1 auch für `simlev/tactical.py`, bis 1.6.0 dort `_civil`) |
| Herkunft | übersetzt aus H. Hinnant, *chrono-Compatible Low-Level Date Algorithms*, <https://howardhinnant.github.io/date_algorithms.html> |
| Rechte | gemeinfrei: „Consider these donated to the public domain.“ |
| Lizenz der Vorlage | keine (gemeinfrei) |
| Änderungen | feste Ganzzahltypen bzw. numpy-Vektorisierung; je Stelle im Herkunftsblock genannt |

## 3. Zur Laufzeit oder beim Bau genutzt, nicht enthalten

- glibc-libm (mathematische Funktionen über das Modul `math`),
- die System-ICU (`libicui18n`, Kollation über ctypes),
- numpy und pandas (Datenhaltung),
- beim Bau ein C/C++-Compiler; die C++-Kerne nutzen `std::sort` und
  `std::nth_element` über die Header der Standardbibliothek des Compilers
  (bei GCC libstdc++: GPL-3 mit GCC Runtime Library Exception 3.1).

Die Pakete evd, imputeTS, stinepack, rugarch, Rsolnp, truncnorm, MSGARCH und
numDeriv sind weder enthalten noch eine Abhängigkeit (siehe
[`LITERATUR.md`](../LITERATUR.md)).

## 4. Früher enthaltene Teile (entfernt)

Bis 0.10.0 bildete die Python-Fassung Teile von evd, imputeTS, stinepack,
rugarch, Rsolnp und truncnorm sowie R's Zufallszahlen, Verteilungsfunktionen
(nmath), lineare Algebra (BLAS, LAPACK, LINPACK) und Optimierer (`optim`,
`nlminb`) nach; diese Teile sind entfernt (1.0.0), ebenso die Nachbildung von
libstdc++ `std::sort`/`std::nth_element` in den Python-Ports der C++-Kerne
(`_dependence_core.py`, `_optimize_core.py`). Zufall und Numerik rechnet die
eigene C-Bibliothek von SimLev. Die Pakete dienten nur als Vorbild und
Prüforakel; ihre Angaben stehen in
[`LITERATUR.md`](../LITERATUR.md) im Wurzelverzeichnis.

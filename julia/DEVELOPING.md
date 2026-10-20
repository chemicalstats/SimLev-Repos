# Entwicklung der Julia-Fassung

Die Julia-Fassung ist ein bitgleicher Port des R-Pakets SimLev 0.5.0 (Ordner
`r/`) und rechnet dieselben IEEE-754-Zahlen wie R und die Python-Fassung
(`python/`). Maßgeblich ist der R-Code; die Python-Fassung ist ein bereits
bitgleich geprüfter Zwischenschritt, der die Rechenreihenfolge von R
nachbildet und sich als Vorlage für die Übersetzung eignet.

## Aufbau

Alles liegt im Modul `SimLev`; die Bausteine sind Untermodule:

| Datei | Untermodul | Inhalt (R-Vorlage → Python-Vorlage) |
|---|---|---|
| `src/r/types.jl` | – | R-Datenstrukturen (`RList`, `RFrame`, `RVector`, `NamedMat`), Druck-/summary-/plot-Registrierung |
| `src/ld80.jl` | – | `F80`: 80-Bit-`long double` (x86-64: x87-Hardware über `llvmcall`, sonst Software-Nachbau `F80Soft`) |
| `src/r/libm.jl` | `RLibm` | glibc-libm (`exp`, `log`, `log1p`, `expm1`, `pow`, `tanh`, …) → `_r/libm.py` |
| `src/r/base.jl` | `RBase` | Summen, Mittel, `cumsum`, `cumprod`, `rowSums`, … mit `long double` → `_r/base.py`, `_rnum.py` |
| `src/r/rng.jl` | `RRng` | Zufallszahlen (`set_seed`, `runif`, `rnorm`, `sample_int`, L'Ecuyer-Streams) → `_r/rng.py` |
| `src/r/nmath.jl` | `RNmath` | Verteilungen (`qnorm`, `pt`, `qt`, `pbeta`/toms708, `lgamma` …) → `_r/nmath.py`, `_r/_toms708.py`, `_r/_cmath.py` |
| `src/r/fmt.jl` | `RFmt` | `format`, `formatC`, `sprintf`, `round`, `signif`, `print` von Vektoren/Matrizen/data.frames → `_r/fmt.py` |
| `src/r/stats.jl` | `RStats` | `quantile`, `cor`, `optim`, `optimize`, `uniroot`, `lm`, `glm`, `smooth_spline`, `density`, `fft`, `hclust`, … → `_r/stats.py` und Hilfsmodule |
| `src/r/linalg.jl` | `RLinalg` | `matprod`, `crossprod`, `solve`, `chol`, `qr` (LINPACK), `determinant`, `eigen` → `_r/linalg.py`, `_r/_blas.py`, `_r/_lapack.py`, `_r/_linpack.py` |
| `src/r/rexpr.jl` | `RExpr` | Ausdrücke in R-Syntax als Text (`eval(parse(text = …), data, env)`): ein gemeinsamer Auswerter für Bedingungen in `bootstrap_probability`, `regime_subset`, `view_prob`/`entropy_pooling` und `tactical_rules` (R-Vorrang inkl. schwach bindendem `!`, NA-Logik, `%in%`, `%%`, Funktionen über `RLibm`/`RFmt`) |
| `src/r/port.jl` | `RPort` | PORT-Bibliothek für `RStats.nlminb` (stats `port.c`, `portsrc.f`, `nlminb.R`) → `_r/_port.py` |
| `src/r/suggests.jl` | `RSuggests` | Schalter `SIMLEV_R_SUGGESTS`: welche optionalen R-Pakete als installiert gelten → `_r/suggests.py` |
| `src/r/evd.jl` | `REvd` | evd 2.3-7.1 `fpot`, `nlgpd` (`src/pot.c`) → `_r/evd.py` |
| `src/r/truncnorm.jl` | `RTruncnorm` | truncnorm 1.0-9 `rtruncnorm` → `_r/truncnorm.py` |
| `src/r/solnp.jl` | `RSolnp` | Rsolnp 1.16 `solnp`, `gosolnp` → `_r/solnp.py` |
| `src/r/stinepack.jl` | `RStinepack` | stinepack 1.5 `stinterp`, `stinemanSlopes`, `parabolaSlopes` → `_r/stinepack.py` |
| `src/r/imputets.jl` | `RImputeTS` | imputeTS 3.4 `na_interpolation` (stine/linear), `na_locf` → `_r/imputets.py` |
| `src/r/rugarch.jl` | `RRugarch` | rugarch 1.5-6 `ugarchfit`/`coef` für sGARCH/gjrGARCH(1,1), Solver „hybrid“ (solnp → nlminb → gosolnp), Filter aus `src/filters.c`, numDeriv-Hesse-Matrix → `_r/rugarch.py` |
| `src/engine.jl` u. a. | – | `simulation()` und Strategie/Config (r/R/simulation.R, sim_*.R, …) |
| `src/<modul>.jl` | `DataPrep`, `Backcast`, `Bonds`, `Signals`, `Bootstrap`, `Withdrawal`, `Dependence`, `Regimes`, `Scenarios`, `Optimize`, `Tactical`, `DeepAnalysis`, `Planning`, `AnalysisTests`, `Overfitting`, `ParamSearch`, `Sensitivity` | je eine R-Datei `r/R/<modul>.R` → `python/simlev/<modul>.py` |
| `src/<name>_core.jl` | `BootstrapCore`, `SignalsCore`, `WithdrawalCore`, `DependenceCore`, `OptimizeCore` | C++-Kerne aus `r/src/` → `python/simlev/_<name>_core.py` |
| `src/exports.jl` | – | sammelt die öffentlichen Funktionen der Untermodule für `using SimLev` |

Funktionen anderer Untermodule werden **im Funktionsrumpf qualifiziert**
aufgerufen (`SimLev.DataPrep._to_date(x)`, `SimLev.RStats.quantile(x, p)`),
damit die Reihenfolge der `include`s keine Rolle spielt. Typen und
Konstanten, die andere brauchen, stehen in früher eingebundenen Dateien.

Namen folgen R bzw. der Python-Fassung (snake_case, `.` → `_`, interne Helfer
mit führendem `_`). Kollidiert ein Name in einem `R*`-Untermodul mit einer
Funktion aus `Base` (`sort`, `filter`, `diff`, `round`, `range`, `cumprod`,
`cummax`, `cummin`, `rank`, `rem`, …), bekommt er das Präfix `r_`
(`RStats.r_sort`, `RFmt.r_round`). Pflichtargumente sind Positionsargumente,
alle anderen Schlüsselwortargumente mit den Voreinstellungen von R.
Julia-Schlüsselwörter als Argumentnamen werden mit `_` ergänzt (`from_`,
`end_`, `function_`, …).

## Datenstrukturen

Siehe Kopf von `src/r/types.jl`. Kurz: NULL → `nothing`; numerisches NA →
`SimLev.NA` (NaN mit R's Nutzlast 1954, von NaN unterscheidbar über
`isna_strict`), andere NA → `missing`; Vektor der Länge 1 → Skalar;
benannter Vektor → `RVector`; data.frame → `RFrame`; Matrix mit dimnames →
`NamedMat`; Liste mit Namen → `RList` (S3-Klasse im Feld `class`).
Attribute von data.frames und Vektoren stehen in `attrs(x)`.
Objekte mit Klasse drucken über `register_print!(klasse, (io, x) -> …)`
exakt wie die R-Methode; `r_summary` und `r_plot` verteilen ebenso.

Eingaben nehmen zusätzlich die natürlichen Julia-Formen an (NamedTuple oder
`Dict` statt data.frame, `Pair`-Listen/`Dict` statt benannter Vektoren).

## Regeln für Bitgleichheit

1. Rechenreihenfolge 1:1 aus R/C++ (bzw. der Python-Fassung) übernehmen.
2. **Nie `sum`, `prod`, `mean` aus Base auf Gleitkommavektoren**: Julia
   summiert paarweise. R summiert sequenziell in `long double` – dafür
   `RBase.r_sum`, `r_mean`, `r_cumsum`, `r_prod`, `r_var` usw. (über `F80`).
   Wo C++ mit `double` sequenziell summiert, eine einfache Schleife.
3. **Nie `exp`, `log`, `log1p`, `expm1`, `^`, `tanh`, `sin`, … aus Base** auf
   Float64: Julia rechnet sie selbst, R nutzt glibc-libm. Immer `RLibm.*`
   (auch beim Broadcasting: `RLibm.exp.(x)`); `x^2` ist in R `x*x`, sonst
   `RLibm.pow` (R's `R_POW`-Regeln, siehe `rnum.jl`). `sqrt`, `abs`, `floor`,
   `ceil`, `+ - * /` sind exakt. Kein `muladd`/`fma`, kein `@fastmath`.
4. **Keine Matrixprodukte mit `*`** (OpenBLAS): `RLinalg.matprod`,
   `crossprod` usw. bilden die Referenz-BLAS-Reihenfolge nach. Eigenvektoren
   kommen wie in R aus der Referenz-LAPACK des Systems (`ccall` auf
   `liblapack.so.3`, Pfad über `SIMLEV_LAPACK`); ohne sie warnt SimLev und
   rechnet mit `LinearAlgebra.eigen` (nicht bitgleich).
5. Sortieren, Runden und Formatieren immer über `RStats`/`RFmt` (R's
   Sortierverfahren bei Gleichständen und ±0, R's `round`-Algorithmus,
   C-`printf` für Zahlen).
6. Zufall nur über `RRng` (globaler Zustand wie `.Random.seed`).
7. NA und NaN wie in R auseinanderhalten: Arithmetik mit NA ergibt auf x86
   wie in R wieder NA; wo R `NA_real_` setzt, `SimLev.NA` setzen.
8. R-`warning(text)` → `@warn text` (nur die Meldung, keine weiteren
   Felder); R-`stop(text)` → `error(text)`; R-`message(text)` → Zeile auf
   `stderr`. Texte wortgleich.
9. Grafiken (SVG, ohne externe Pakete) müssen nicht bitgleich sein, aber
   dasselbe zeigen; berechnete Daten schon.

10. C-Bibliotheken nur über die zentrale Auswahl in `rnum.jl` (`_LIBM`,
    `_LIBC`, `_SNPRINTF`); nie Bibliotheksnamen fest eintragen.
11. Zeichenketten sortieren/vergleichen nur über `RStats.order`, `r_sort`,
    `r_rank`, `str_collate` (ICU-Kollation wie R, siehe `src/r/_collate.jl`).
12. Bedingungen als Text immer über `RExpr.eval_r` (R-Syntax), nie über
    Julia-`Meta.parse`.
13. data.frame-artige Eingaben am Funktionseingang mit `as_rframe`
    vereinheitlichen; plot-Methoden über `_plot_method` registrieren (liefern
    `SimLevDashboard`, schreiben nur mit `file = "….svg"`).
14. long-double-Summen laufen auf x86-64 über die x87-Hardware; ist das
    Ergebnis NaN, rechnen `r_sum` & Co. mit `F80Soft` nach, weil R's
    NA/NaN-Vorrang sonst vom erzeugten Maschinencode abhinge.
15. `requireNamespace("evd"/"rugarch"/"imputeTS", quietly = TRUE)` → bei jedem Aufruf
    `RSuggests.has(...)`. `Sys.time()` → `RBase.sys_time()` (Prüfschalter
    `SIMLEV_R_SYS_TIME`).

Keine externen Pakete; erlaubt ist nur die Standardbibliothek (`Dates`,
`Printf`, `Logging`; `LinearAlgebra` nur als Ersatzweg für Eigenvektoren).

## Referenzfälle und Prüfung

Die Referenzfälle unter `golden/modules/<modul>/` erzeugen die Generatoren
`golden/modules/gen_<modul>.R`. Jeder Aufruf `ref_case(id, r = …, py = …,
jl = …)` trägt R-, Python- und Julia-Code; der Julia-Code setzt `result`
und sieht die Eingaben als Variablen (siehe `test/reftree.jl`, `decode`).

``` bash
julia --project=julia julia/tools/compare_reference.jl [modul …] [-k id] [-v]
julia --project=julia julia/tools/compare_golden.jl golden/cases
julia --project=julia -e 'using Pkg; Pkg.test()'      # Referenzfälle: Auswahl; alle mit SIMLEV_FULL_TESTS=1
```

Verglichen wird ohne Toleranz: NA ≠ NaN, Vorzeichen der Null, Druck- und
Konsolenausgabe, Warnungen und Fehlermeldungen. Bei der Entwicklung spart
`SIMLEV_SKIP_PRECOMPILE=1` die Vorkompilier-Arbeitslast.

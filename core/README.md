# core/ – C-Bibliothek slc (SimLev core)

Kanonische Quellen der C-Bibliothek, die R, Python und Julia gemeinsam nutzen (Etappe 9).
**Nur hier ändern**, danach `python3 tools/core_sync.py --write`; `--check` prüft die Kopien
(SHA-256) und `core/slc_constants.h` gegen den Generator.

| Datei | Inhalt |
|---|---|
| `slc.h` | öffentliche Schnittstelle (reines C99): Kontext `sl_ctx`, Generator `sl_rng`, Ziehungen, Verteilungen |
| `slc_internal.h` | interne Hilfen: Gleitkomma-Schutz, Abbruchprüfung |
| `slc_constants.h` | **erzeugt** von `tools/gen_constants.py` (nicht von Hand ändern) |
| `slc_ctx.c` | Fehler, Warnungen, Benutzerabbruch ohne `longjmp` |
| `slc_rng.c` | xoshiro256**, SplitMix64-Seeding, Sprung um 2^128, Ströme, Gleichverteilung |
| `slc_sample.c` | ganze Zahlen (Lemire), Stichproben, normal (Inversion), exponentiell, geometrisch, Gamma (Marsaglia–Tsang), Chi-Quadrat |
| `slc_normal.c` | `erfc`, `pnorm`, `qnorm`, `dnorm` |
| `slc_special.c` | `lgamma`, unvollständige Beta, `pt`, `qt`, `plogis`, `qlogis` |
| `slc_linalg.h` | 9.2: Schnittstelle der Etappe 9.2 (eingebunden von `slc.h`) |
| `slc_la_internal.h` | 9.2: kompensierte Summen (Neumaier), Normen, NA, stabile Sortierung |
| `slc_linalg.c` | 9.2: Cholesky, Band-Cholesky, Dreieckslöser, SPD-Löser, log det, symmetrische Eigenwerte (zyklisches Jacobi) |
| `slc_matmul.c` | 9.2: Matrixprodukt `A B`, `X'Y`, `X Y'` mit fester Summationsreihenfolge |
| `slc_lsq.c` | 9.2: kleinste Quadrate (Householder-QR, begrenzte Spaltenpivotisierung), Logit-IRLS |
| `slc_stine.c` | 9.2: Stineman-Interpolation |
| `slc_spline.c` | 9.2: kubischer Glättungsspline (Reinsch, GCV, Spur nach Hutchinson/de Hoog), Vorhersage |
| `slc_kde.c` | 9.2: Gauß-Kerndichte, Bandbreite nach Silverman |
| `slc_opt.h`, `slc_opt.c`, `slc_opt_test.c` | (9.3) Optimierer BFGS (Wolfe-Liniensuche), projizierter BFGS, Nelder-Mead, numerischer Gradient; Rückfrage an den Host und `sl_minimize`; Prüffunktionen (Quellen: Nocedal/Wright, Bertsekas, Kelley, Nelder/Mead, Lagarias u. a., Gill/Murray/Wright, Moré/Garbow/Hillstrom) |
| `slc_models.h`, `slc_garch.c`, `slc_gpd.c`, `slc_dcc.c`, `slc_msgarch.c`, `slc_boot.c` | (9.4) Modelle: GARCH/GJR(1,1) (ML, Umparametrisierung, Rückfall Momente), GPD (ML, Startwerte nach Hosking/Wallis), DCC(1,1) (Filter, Nelder-Mead), MS-GARCH (Filter, Starts aus HMM-EM und Rangeinteilung, BFGS, Viterbi), Bootstrap-Kerne mit Strom `sl_rng` (Quellen: Bollerslev, Glosten/Jagannathan/Runkle, Pickands, Davison/Smith, Hosking/Wallis, Engle, Haas/Mittnik/Paolella, Hamilton, Baum u. a., Viterbi, Efron, Künsch, Politis/Romano, Wu, Liu, Mammen, Barone-Adesi u. a.; eigener SimLev-Code) |
| `tools/gen_constants.py` | Konstanten, Bernoulli-Zahlen, zeta(k), Stützwerte und Taylor-Polynome, Sprungpolynom, N2: selbst angepasste rationale Näherungen für `qnorm` (nur Standardbibliothek) |

**Geteilte Kerne von R und Python (seit Etappe 9.6c, F16):** Auch die früher in `r/src/`
kanonischen C++-Kerne liegen hier: `simlev_core.h` (Aufbau, Host-Schnittstelle, `NA`),
`simulation_core_impl.h`, `fifo_core_impl.h`, `tax_core_impl.h` (Engine), `research_core_impl.h`
(Optimierung, Quantilsregression, HMM, rollierende Kennzahlen, Kendalls Tau) und
`withdrawal_core_impl.h` (Entnahme). Sie folgen nicht den slc-Regeln unten (eigener SimLev-Code seit
Etappe 7.3a, C++17, Host-Makros `SIMLEV_*`) und werden nur nach `r/src/` und `python/src/core/`
kopiert; Julia hat eigene Ports (F2). Beim Verschieben blieb ihr Maschinencode in R gleich
(Vergleich der Objektdateien Funktion für Funktion, Bericht 9.6c).

Kopien (Pakete bauen nur aus ihrem Teilbaum): `r/src/` (flach), `python/src/core/`,
`julia/deps/core/` (nur slc). Die Hüllen gibt es nur je Sprache: `r/src/slc_r.c` (+ `r/R/slc.R`),
`python/src/_ext_slc.c` (+ `python/simlev/_lib.py`), `julia/src/slib.jl` (`ccall`, gebaut von
`julia/deps/build.jl`).

## Regeln

- **Reinraum.** Kerne entstehen nur aus Veröffentlichungen und Mathematik (DLMF,
  Abramowitz/Stegun, Blackman/Vigna, Steele u. a., Lemire, Knuth, Devroye, Marsaglia/Tsang,
  Lentz, Dekker). Nicht gelesen werden dabei `r/R/vendor_*`, `r/src/vendor_*`, die Port-Module
  in `python/simlev/_r/` und `julia/src/r/` (`rng`, `nmath`, `_toms708` …), `python/src/_rng_r.c`
  sowie R- und Paketquellen. R und die alten Pakete dienen nur als Prüforakel (Zahlen vergleichen).
- **Reinraum 9.2.** Zusätzliche Quellen der Etappe 9.2: Golub/Van Loan, Jacobi, Demmel/Veselić,
  Businger/Golub, Higham, Neumaier, McCullagh/Nelder, Stineman, Reinsch, Green/Silverman,
  Craven/Wahba, Hutchinson/de Hoog, Kiefer, Knuth, Silverman, Scott, Wand/Jones, Hyndman/Fan; nicht
  gelesen werden zusätzlich die Ports `_linpack`, `_lapack`, `_blas`, `linalg`, `stinepack`,
  `imputets`, `_sbart`, `stats_smooth`, `_fft` (und ihre Julia-Gegenstücke). stinepack, imputeTS
  und R dienen nur als Black-Box-Orakel.
- **Dateikopf.** Jede Kerndatei nennt Verfahren, Quellen (vollständige Angabe, bei DLMF die
  Gleichungsnummer), Herkunft der Konstanten, die Reinraum-Erklärung und das Prüforakel.
- **Konstanten** werden in `tools/gen_constants.py` hergeleitet (Herleitung im Kopf des Skripts);
  Verfahrensparameter aus einem Aufsatz stehen mit Fundstelle im Dateikopf.
- **Schnittstelle.** Kein `exit`, kein `longjmp`, keine Ausgabe; Status als Rückgabewert, Text im
  Kontext; Warnungen gesammelt (gleiche Texte einmal), vom Host nach dem Aufruf ausgegeben. Kein
  globaler Zustand.
- **Gleitkomma.** Nur `double`; Flags in allen drei Builds `-O2 -std=c99 -ffp-contract=off
  -fno-fast-math` (R: `r/src/Makevars`, Python: `python/setup.py`, Julia: `julia/deps/build.jl`);
  `slc_internal.h` bricht bei `__FAST_MATH__` ab. Bitgleichheit gilt auf derselben Maschine mit
  demselben Compiler und derselben libm.
- **NA/NaN.** Elementweise Funktionen geben bei NaN-Eingabe die Eingabe selbst zurück (NA bleibt
  NA); ein ungültiger Parameter ergibt NaN und genau eine Warnung „<funktion>: NaN erzeugt“.

- **Reinraum 9.4.** Zusätzlich nicht gelesen: `python/simlev/_r/{rugarch,solnp,evd,truncnorm}.py` und die
  Julia-Gegenstücke, Quellen von rugarch, Rsolnp, evd, MSGARCH. Überführt wurde nur eigener SimLev-Code
  (`ms_garch_impl.c`, `bootstrap_core_impl.h`, `dependence_core_impl.h`, `ms_garch.R`, `regimes.R`,
  `.fit_garch11`/`.fit_tail` bis zur Grenze der Übernahmen). rugarch, evd und MSGARCH dienen nur als Orakel.
- **N1 (nach 1.0.0).** GJR in `slc_garch.c` und je Regime in `slc_msgarch.c` mit γ < 0, solange
  α + γ ≥ 0 (Umparametrisierung (α/2, (α + γ)/2, β); Glosten/Jagannathan/Runkle 1993); GJR-GARCH mit
  BFGS von sieben Rasterpunkten; MS-GARCH mit analytischem Gradienten (Vorwärtsmodus, Griewank/Walther
  2008; LU nach Golub/Van Loan 2013 für die Ableitung der stationären Verteilung), `sl_msgarch_grad`,
  GJR mit 20 Starts (`SL_MSGARCH_MAXSTART` 20). Reinraum wie 9.4; rugarch und MSGARCH nur als Orakel.

Prüfung: Plausibilität gegen R und eine eigene decimal-Referenz (Arbeitsordner der Etappe),
Gleichlauf der Sprachen mit `tools/gleichlauf/run.sh --quick`.

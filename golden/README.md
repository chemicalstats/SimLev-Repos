# Golden-Master-Fälle

Dieser Ordner enthält die gemeinsamen Referenzfälle, an denen die Python-
und die Julia-Fassung ihre Bitgleichheit zum R-Paket prüfen.

| Ordner | Fälle | Geprüft von | Inhalt |
|---|---|---|---|
| `cases/` | 68 | Python, Julia | Engine: 38 gezielte Fälle für jeden Steuer- und Sonderpfad (`f01`–`f38`) und 30 Zufallsfälle (`r…`) |
| `extra/` | 37 | Python, Julia | Engine: Stressfälle mit 30 Jahren, Totalverlust-Hebel, mehreren Signal-Assets, konstanten Preisen, Kalender-Randfällen, Extremwerten, Fehlerpfaden (`x…`, `y…`) |
| `modules/` | 4.656 | Python, Julia | alle übrigen Funktionen des R-Pakets, die Engine mit den Argumenten und Ergebniselementen von 0.5.0 (Modul `engine`), die Nachbildung von evd, rugarch und imputeTS und die nachgebauten R-Interna, je Modul ein Unterordner (30 Module, siehe unten) |

## Engine-Fälle (`cases/`, `extra/`)

Jeder Fall ist eine gzip-komprimierte JSON-Datei mit den Eingabedaten, der
Strategie, den Argumenten von `simulation()` und den exakten Ergebnissen
aus R (Gleitkommazahlen als Hex-Literale, `NA` und `NaN` getrennt).

Seit Etappe 6.3 stehen in `args` die Bausteine von `simulation()`, je
Baustein als `{"block": "<Konstruktor>", "args": {...}}` (verschachtelt für
`income` und `harvest` in `tax_profile()`); die Vergleichswerkzeuge legen die
Bausteine mit den Konstruktoren der Zielsprache an. Die flachen Argumente
bis 6.2 stehen daneben in `args_flat`. Übersetzt hat
`golden/tools/blocks_from_flat.py` (Regeln dort; `--check` prüft die
Übersetzung aller Fälle), die Generatoren `golden_cases.R` und
`stress_cases.R` beschreiben ihre Fälle weiter flach und übersetzen sie mit
`golden/tools/blocks_from_flat.R` (gleiche Regeln). Die erwarteten
Ergebnisse sind dabei gleich geblieben (Fälle ohne Sparer-Pauschbetrag: das
Echo `tax_report$sparer_pauschbetrag_annual` ist jetzt 0, die Zeile
„SPB genutzt“ entfällt).

Stand R 0.5.0 (aktuelle Fassung): Alle 105 Fälle sind nach den
Engine-Korrekturen, steuerrechtlichen Anpassungen und der Übersetzung der
Ausgaben ins Deutsche neu erzeugt (Begründung in `r/NEWS.md`), zuletzt 101
davon wegen der deutschen Druckausgabe, 19 davon zusätzlich mit geänderten
Zahlen (keine Doppelorders am ersten Tag). Die neuen R-Ergebnisfelder
`tax_report$open_tax_debt` und `tax_report$tariff_years` gehören bewusst
nicht zum Golden-Format; sie prüft das Modul `engine` in `modules/` (vollständige
Ergebnisbäume). `extra/x24_dup_dates.json.gz` erwartet jetzt auch
in R einen Fehler (doppelte Datumswerte), wie schon in Julia 0.1.0.

- **Python 0.5.0** und **Julia 0.5.0** sind zu allen 105 Fällen
  bitgleich, einschließlich Druckausgabe und `details = TRUE`, und
  unterscheiden dabei strikt `NA` und `NaN`.

### Neue Engine-Fälle erzeugen

Benötigt werden R, das R-Paket SimLev (aus `../r`) und `jsonlite`.

``` bash
# Zielordner, Anzahl Zufallsfälle, Startwert
LC_ALL=C.UTF-8 Rscript golden/golden_cases.R /tmp/golden 500 4711
LC_ALL=C.UTF-8 Rscript golden/stress_cases.R /tmp/stress 1000 90210
```

Die Generatoren schreiben unkomprimierte `.json`-Dateien. Für die Ablage in
`cases/` oder `extra/` komprimieren Sie sie mit `gzip -9`; die Testsuiten
lesen nur `.json.gz`. Die Vergleichswerkzeuge beider Ports lesen beide
Formen.

Abgleich mit den Ports:

``` bash
python python/tools/compare_golden.py /tmp/golden          # ohne Pfad: golden/cases und golden/extra
julia --project=julia julia/tools/compare_golden.jl /tmp/golden     # ohne Pfad ebenso; --lax: NA = NaN
julia --project=julia julia/tools/compare_golden.jl golden/cases golden/extra   # mehrere Ordner, mit Gesamtsumme
```

## Modul-Fälle (`modules/`)

Je Modul gibt es einen Unterordner mit Fällen und einen Generator
`gen_<modul>.R`; alle Generatoren nutzen die Hilfen in `ref_tools.R`.

| Modul | Fälle | Prüft |
|---|---|---|
| `data_prep` | 160 | Datenaufbereitung, Portfolio-Vorlagen (`data_prep.R`) |
| `backcast` | 88 | `backcast.R` |
| `signals` | 56 | `signals.R` mit den Rollkernen |
| `bootstrap_core` | 18 | Kerne aus `bootstrap_core.cpp`, MS-GARCH-Filter aus `ms_garch.c` (`.ms_garch_filter`) |
| `bootstrap` | 194 | `bootstrap.R` (darunter `cores = 2`: `bs_rawcores2pathlength50`, `bs_cores2_*`, `study_returns`, `study_cores2*`) |
| `ms_garch` | 17 | eigene MS-GARCH-Schätzung `ms_garch.R` (`.ms_garch_fit`: K = 2/3, sGARCH/gjrGARCH, drei simulierte Datensätze, Fehlerwege der Prüfung; `simlev/ms_garch.py`, `src/ms_garch.jl`) |
| `withdrawal` | 313 | `withdrawal.R`, `withdrawal_core.cpp` |
| `deep_analysis` | 54 | `deep_analysis.R` |
| `sensitivity` | 44 | `sensitivity.R` (darunter `cores = 2`/`3`: `*_cores2*`, `sg_cores3_keep`; `sg_cores1_rng` als Gegenstück) |
| `param_search` | 55 | `param_search.R` (darunter `cores = 2`: `ps_cores2*`) |
| `overfitting` | 73 | `overfitting.R` (darunter `cores = 2`: `pb_cores2`) |
| `dependence` | 136 | `dependence.R`, `dependence_core.cpp` |
| `regimes` | 20 | `regimes.R` |
| `scenarios` | 65 | `scenarios.R` |
| `tactical` | 133 | `tactical.R` |
| `optimize` | 180 | `optimize.R` mit den Optimierungskernen |
| `planning` | 58 | `planning.R` |
| `analysis_tests` | 81 | `analysis_tests.R` |
| `engine` | 332 | `simulation()` mit den Bausteinen von 6.3 (`sim_costs()`, `dca_plan()`, `rebalance_plan()`, `split_rule()`, `tax_profile()` mit `income_rate()`, `income_tariff()`, `harvest_rule()`, `funds_costs()`; Prüfungen und Druckausgabe der Bausteine: `bk…`, `pr…`) und den Argumenten von 0.5.0 (`order_fee`, `dca_fee`, `church_tax`, `harvest_*`, `taxable_income`, `tax_tariff`), Günstigerprüfung, Fondsmodus, Sparplan, Rebalancing-Bänder, Splits, später startende Assets, `details = TRUE`, `summary()`, vollständiges Ergebnis (u. a. `fees_paid`, `harvest_days`, `open_lots`, `tax_report` mit `open_tax_debt`, `tariff_years`, `next_year`), `tax_tariff()`, Warn- und Fehlerpfade; 22 Zufallsfälle (`zz…`) |
| `r_rng` | 20 | Zufallszahlen (Python: `simlev/_r/rng.py`, Julia: `src/r/rng.jl`) |
| `r_nmath` | 64 | Verteilungsfunktionen (`simlev/_r/nmath.py`, `src/r/nmath.jl`) |
| `r_stats` | 384 | stats-Interna (`simlev/_r/stats.py`, `src/r/stats.jl`) |
| `r_linalg` | 106 | lineare Algebra (`simlev/_r/linalg.py`, `src/r/linalg.jl`) |
| `r_fmt` | 355 | Formatierung und Druckausgabe (`simlev/_r/fmt.py`, `src/r/fmt.jl`) |
| `r_nana` | 25 | NA/NaN in Summen und Kumulationen mit long double (`simlev/_r/base.py`, `src/r/base.jl`) |
| `rexpr` | 1016 | Bedingungen als Text in R-Syntax (`simlev/_r/rexpr.py`, `src/r/rexpr.jl`) gegen R's `eval(parse(text = …))` |
| `r_nlminb` | 104 | `stats::nlminb` mit allen PORT-Varianten (`simlev/_r/port.py`, `src/r/port.jl`) |
| `evd` | 129 | aus evd 2.3-7.1 übernommen (`SimLev:::.evd_fpot`, `C_evd_nlgpd`): `fpot`, `nlgpd`, `.fit_tail`, `bootstrap(…, "evt")` (`simlev/_r/evd.py`, `src/r/evd.jl`) |
| `imputets` | 203 | aus imputeTS 3.4 und stinepack 1.5 übernommen (`SimLev:::.imputets_na_interpolation`, `.imputets_na_locf`, `.stinepack_stinterp`): `na_interpolation` (stine), `na_locf`, stinepack `stinterp`, `.fill_na(…, "stine")`, `backcast_fit`/`backcast` mit `"stine"` (`simlev/_r/imputets.py`, `stinepack.py`, `src/r/imputets.jl`, `stinepack.jl`) |
| `rugarch` | 173 | aus rugarch 1.5-6, Rsolnp 1.16 und truncnorm 1.0-9 übernommen (`SimLev:::.rugarch_ugarchfit`, `.rugarch_coef`, `.rsolnp_solnp`, `.rsolnp_gosolnp`, `.truncnorm_rtruncnorm`), Ableitungen eigenständig (`.sl_richardson_hessian`, `.sl_richardson_jacobian`, gegen numDeriv 2016.8-1.1 geprüft): `ugarchfit`→`coef` (auch mit den Ausweichwegen nlminb und gosolnp, Zufallszustand danach), `solnp`, `gosolnp`, `rtruncnorm`, `.fit_garch11`, Bootstrap `garch`/`gjr_garch`, `dependence_dcc`, `dependence_analysis` (`simlev/_r/rugarch.py`, `solnp.py`, `truncnorm.py`, `src/r/rugarch.jl`, `solnp.jl`, `truncnorm.jl`) |

Python 0.5.0 und Julia 0.5.0 sind zu allen 4.656 Fällen bitgleich, bei strenger
Unterscheidung von `NA` und `NaN` und mit dem Vorzeichen der Null. Die Fälle mit
`cores > 1` rechnen in Python mit Fork und in Julia unter `julia -t 2` mit Threads
echt parallel; Julia prüft sie zusätzlich mit einem Thread.

### Format

Ein Fall ist eine gzip-komprimierte JSON-Datei `<modul>/<id>.json.gz` mit

| Feld | Inhalt |
|---|---|
| `id`, `module`, `note` | Kennung, Modul, optionale Bemerkung |
| `inputs` | benannte Eingabeobjekte als Baum oder als Verweis auf den Eingabespeicher (Format 2, siehe unten) |
| `r` | R-Code, dessen letzter Ausdruck das Ergebnis liefert |
| `py` | Python-Code, der `result = ...` setzt |
| `jl` | Julia-Code, der `result = ...` setzt (in `ref_tools.R` optional, in allen Fällen vorhanden) |
| `result` | Ergebnis als Baum |
| `output` | Konsolenausgabe während des Aufrufs (`cat`, `print`) |
| `print` | `print(result)` für Objekte mit eigener print-Methode in SimLev |
| `warnings` | Warnungen während des Aufrufs |
| `error` | Fehlermeldung, falls R mit einem Fehler abbricht (statt `result`) |
| `sys_time` | feste Uhrzeit (Sekunden seit 1970, als Text `%.17g`) für Fälle, deren Ergebnis von `Sys.time()` abhängt (gosolnp); je eine Stelle setzt und eine setzt zurück: in R `.ref_fix_time()` in `ref_case()` (ersetzt `Sys.time` in `baseenv()`, `on.exit` stellt es wieder her), in Python `_fixed_sys_time()` in `run_case()` und in Julia `withenv` in `run_ref_case()` (beide über `SIMLEV_R_SYS_TIME`) |

Im Baum hat jedes Objekt einen Typ `t` (`null`, `num`, `int`, `lgl`,
`chr`, `date`, `list`, `df`, `mat`, `skip`). Zahlen stehen als Hex-Literale
(`sprintf("%a")`), `NA` und `NaN` getrennt; die Attribute `names`, `dim`,
`dimnames` und `class` werden mitgeschrieben. Funktionen und Formeln
werden als `skip` übergangen.

#### Eingabespeicher (Format 2)

Viele Fälle eines Moduls rechnen auf denselben Eingabedaten. Bis Format 1
stand jede Eingabe vollständig in jedem Fall (93 MB für `golden/`). Seit
Format 2 liegt jede größere Eingabe nur einmal je Modul im
**Eingabespeicher** `<modul>/_inputs.json.gz`:

``` json
{"format":2,"module":"evd","inputs":{"0a1b…":{"t":"df",…},"…":…}}
```

Im Fall steht an ihrer Stelle ein Verweis, ein Baumknoten vom Typ `ref`:

``` json
"inputs":{"d":{"t":"ref","k":"0a1b…"},"n":{"t":"num","v":"0x1.4p+3"}}
```

- **Schlüssel** `k`: MD5-Prüfsumme (hex) der kanonischen JSON-Form der
  Eingabe, d. h. des kompakten JSON-Texts ohne Leerzeichen (UTF-8, Felder in
  der Reihenfolge des Baums), den `ref_tools.R` mit jsonlite für sie schreibt.
  Gleiche Eingaben ergeben denselben Schlüssel und werden so nur einmal
  gespeichert; im Speicher sind die Schlüssel sortiert.
- **Klein bleibt im Fall:** Eingaben mit weniger als 256 Bytes kanonischer
  Form (Skalare, kurze Vektoren) stehen weiter direkt im Fall – ein Verweis
  spart dort nichts, und der Fall bleibt lesbar. Größere Eingaben gehen
  immer in den Speicher, auch wenn nur ein Fall sie nutzt: So entscheidet
  `ref_case()` beim Schreiben jedes Falls allein, ohne die späteren Fälle zu
  kennen, und R und Konverter kommen ohne Zählung zum selben Ergebnis.
- **gzip statt xz**, wie bisher (`gzip -9 -n`): Julia liest über Zlib, eine
  weitere Abhängigkeit entfällt.

Einen Fall lesen: Datei entpacken, jeden Eingabeknoten mit `"t": "ref"`
durch `inputs[k]` aus `_inputs.json.gz` desselben Ordners ersetzen; das
Ergebnis ist genau der Baum des Formats 1. Die Harnesses machen das selbst
und lesen beide Formen: Python `simlev._r.reftree.load_case(pfad)` (dazu
`list_cases(ordner)`, das den Speicher auslässt), Julia `read_ref_case(pfad)`
und `list_ref_cases(ordner)` aus `julia/test/reftree.jl`. Von Hand, z. B.:

``` python
import gzip, json
rd = lambda p: json.load(gzip.open(p, "rt", encoding="utf-8"))
case, store = rd("golden/modules/evd/fpot_cg.json.gz"), rd("golden/modules/evd/_inputs.json.gz")["inputs"]
inputs = {k: store[v["k"]] if v.get("t") == "ref" else v for k, v in case["inputs"].items()}
```

`ref_tools.R` schreibt Format 2 direkt (den Speicher in `ref_done()`).
Vorhandene Fälle im Format 1 stellt `golden/tools/convert_format.py` (nur
Python-Standardbibliothek) um, ohne R erneut laufen zu lassen; es ist
wiederholbar und lässt Dateien mit unverändertem Inhalt unberührt. Es
schreibt Text und gzip-Bytes wie `ref_tools.R`, sodass ein neu erzeugtes
Modul mit unveränderten Ergebnissen dieselben Dateien ergibt.

``` bash
python3 golden/tools/convert_format.py            # alle Module; -n: nur zählen
```

### Neu erzeugen

Benötigt werden R (die Referenzen entstanden mit R 4.3.3), das installierte
R-Paket SimLev 0.5.0 und `jsonlite`, aber **nicht** das Paket MSGARCH:
SimLev schätzt das MS-GARCH-Modell selbst (`.ms_garch_fit`, Kern
`src/ms_garch.c`; Ports `simlev.ms_garch` bzw. `SimLev.MsGarch`). evd ist ins R-Paket übernommen
(`.evd_fpot`); `gen_evd.R` braucht evd nicht mehr, seine Fälle (zuvor mit
evd 2.3-7.1 erzeugt) sind mit der Übernahme bitgleich. Ebenso sind imputeTS
und stinepack übernommen (`.imputets_na_interpolation`,
`.stinepack_stinterp`); `gen_imputets.R` braucht die Pakete nicht mehr,
seine Fälle (zuvor mit imputeTS 3.4 und stinepack 1.5 erzeugt) sind mit der
Übernahme bitgleich, einschließlich der drei Fälle `ni_lin_*` mit
`option = "linear"`. Ebenso sind
rugarch, Rsolnp und truncnorm übernommen (`.rugarch_ugarchfit`,
`.rsolnp_solnp`, `.rsolnp_gosolnp`, `.truncnorm_rtruncnorm`), Hesse-Matrix
und Scores rechnet die eigenständige Richardson-Extrapolation
(`.sl_richardson_hessian`, `.sl_richardson_jacobian`; Direktvergleich mit
numDeriv als Orakel: `check_richardson.R`); `gen_rugarch.R` braucht die
Pakete nicht mehr, seine Fälle (zuvor mit rugarch 1.5-6, Rsolnp
1.16, numDeriv 2016.8-1.1 und truncnorm 1.0-9 erzeugt) sind mit der
Übernahme und der eigenen Richardson-Extrapolation bitgleich. Die gosolnp-Fälle laufen mit fester Uhr
(`ref_case(…, sys_time = t)`), weil gosolnp den Zufallszustand aus
`Sys.time()` setzt. Aufruf aus der Repo-Wurzel:

``` bash
LC_ALL=C.UTF-8 R_LIBS=<R-Bibliothek mit SimLev> Rscript golden/modules/gen_bootstrap.R
```

Jeder Generator leert zuerst seinen Unterordner (`ref_init()`) und schreibt
dann alle Fälle neu. `gen_r_nmath.R` übersetzt für die internen
nmath-Hilfen ein kleines C-Modul und braucht dafür einen C-Compiler und die
Quellen von R 4.3.3 (Verzeichnis `src/nmath`, Pfad in der Umgebungsvariable
`SIMLEV_R_NMATH_SRC`). Fehlt die Quelle, bricht der Generator ab, damit die
neun `helper_*`-Fälle nicht still verloren gehen; mit `SIMLEV_ALLOW_PARTIAL=1`
erzeugt er die übrigen 55 Fälle trotzdem.

Den Julia-Code eines Falls übergibt der Generator als Argument `jl` an
`ref_case()`. Er läuft in einem frischen Modul mit `using SimLev` und
`using Dates`, sieht die Eingaben aus `inputs` als Variablen (übersetzt in
die Julia-Datenstrukturen, siehe `julia/DEVELOPING.md`) und setzt
`result`.

Abgleich mit Python:

``` bash
python python/tools/compare_reference.py                    # alle Module
python python/tools/compare_reference.py bootstrap -k study -v
pytest python/tests/test_module_reference.py -k withdrawal
```

Verglichen wird ohne Toleranz, einschließlich des Vorzeichens der Null
(`SIMLEV_STRICT_ZERO=0` lässt −0 = +0 zu). Nicht verglichen werden die
Klasse und der Unterschied zwischen integer und double, `message()`-Hinweise
sowie zusätzliche Elemente, die nur das Python-Ergebnis enthält. `NA` und
`NaN` werden unterschieden (`SIMLEV_LAX_NA=1` lässt NA = NaN zu); im
`py`-Code eines Falls steht R's `NA` als `simlev._r.fmt.NA_REAL`.

Abgleich mit Julia (Werkzeug `julia/tools/compare_reference.jl`, Harness
`julia/test/reftree.jl`):

``` bash
julia --project=julia julia/tools/compare_reference.jl                  # alle Module
julia --project=julia julia/tools/compare_reference.jl bootstrap -k study -v
SIMLEV_FULL_TESTS=1 julia --project=julia -e 'using Pkg; Pkg.test()'     # alle Fälle in der Testsuite
```

Julia vergleicht ebenso streng: `NA` und `NaN` werden unterschieden, ebenso das
Vorzeichen der Null; verglichen werden Ergebnis, Konsolenausgabe,
Druckausgabe (`print`), Warnungen und Fehlermeldungen. Zur Fehlersuche
lockern `SIMLEV_LAX_NA=1` (NA = NaN) und `SIMLEV_STRICT_ZERO=0` (−0 = +0)
den Vergleich. Ohne `SIMLEV_FULL_TESTS=1` prüft `Pkg.test()` nur bis zu
vier Fälle je Modul.

## Schalter `SIMLEV_*`

Für die Referenzfälle relevant (die Ports lesen sie nur in
`python/simlev/_r/env.py` bzw. `julia/src/r/env.jl`; vollständige Liste in
`python/DEVELOPING.md` und `julia/DEVELOPING.md`):

| Schalter | Zweck | Art |
|---|---|---|
| `SIMLEV_R_SYS_TIME` | feste Uhr für gosolnp; die Harnesses setzen sie aus dem Feld `sys_time` eines Falls | Prüfung |
| `SIMLEV_LAX_NA` | `1`: NA = NaN im Vergleich (Python und Julia) | Prüfung |
| `SIMLEV_STRICT_ZERO` | `0`: −0 = +0 im Vergleich (Python und Julia) | Prüfung |
| `SIMLEV_FULL_TESTS` | `1`: `Pkg.test()` prüft alle Modul-Fälle statt bis zu vier je Modul | Prüfung |
| `SIMLEV_GOLDEN_DIR` | andere Ordner der Engine-Fälle (pytest: Ordnerliste; Julia: Wurzel mit `cases/`, `extra/`) | Prüfung |
| `SIMLEV_MODULE_DIR` | anderer Ordner der Modul-Fälle für pytest | Prüfung |
| `SIMLEV_COLLATE` | Sortierung; die Harnesses setzen `icu:root` (wie R unter C.UTF-8), falls nicht gesetzt | Nutzer |
| `SIMLEV_R_NMATH_SRC` | Pfad zu `src/nmath` der R-4.3.3-Quellen für `gen_r_nmath.R` | Generator |
| `SIMLEV_ALLOW_PARTIAL` | `1`: `gen_r_nmath.R` erzeugt ohne nmath-Quellen die übrigen 55 Fälle | Generator |

Das R-Paket selbst liest keine `SIMLEV_*`-Schalter.

## Änderungen an diesem Ordner

Wer die Rechenlogik des R-Pakets ändert, erzeugt die betroffenen Fälle in
`cases/`, `extra/` und `modules/` neu und zieht die Ports nach, bis alle
Fälle wieder bitgleich sind. Prüfen Sie nach jeder Änderung in diesem
Ordner Python (beide Werkzeuge oben bzw. die Testsuite) und Julia.

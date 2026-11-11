# Sensitivity – Gegenstück zu r/R/sensitivity.R und python/simlev/sensitivity.py
#
#  sensitivity_grid()         beliebige simulation()-Argumente im Raster
#  sensitivity_rebalancing()  Rebalancing-Frequenz, Versatz und Bänder
#  planning_lumpsum_vs_dca()           Einmalanlage gegen gestreckten Einstieg
#  series_leverage()         Hebelreihe aus einem Index (MSCI-Formel)
#  sensitivity_leverage()     Kennzahlen über den Hebel, optimaler Hebel
module Sensitivity

import ..SimLev
using ..SimLev: _res_fig, _res_finish, _res_line!, _res_panel, _res_points!, _res_range, _res_rect!, _res_vline!
using Dates

const SL = SimLev
const NA = SimLev.NA
const OF = SimLev.Overfitting
const PS = SimLev.ParamSearch

export sensitivity_grid, sensitivity_rebalancing, planning_lumpsum_vs_dca, series_leverage, sensitivity_leverage

_metrics(m) = m === nothing ? SL.Bootstrap.bootstrap_study_metrics : m

# Einheitliche Eingabeprüfung (seit 1.6.4, R: .sens_check_sim, .sens_check_common, .lev_check): data und strategy, die
# an simulation() gehen, früh mit dessen Meldungen; data nur als RFrame (Entscheidung 6; vorher NamedTuple/Dict
# umgewandelt); sim_args als Liste, metrics als Funktion (nothing = Standard), cores ganze Zahl >= 1.
function _sens_check_sim(data, strategy)
    (data isa SL.RFrame || data isa SL._Frame) ||
        SL.chk_stop("a.m_sim_check_inputs", SL.chk_msg("tabelle.formen"))
    _e2_check_strategy(strategy)
    return nothing
end
"strategy wie simulation(): nicht leer, alle Assets benannt; gleiche Meldungen (R: .e2_check_strategy)."
function _e2_check_strategy(strategy)
    (strategy === nothing || (applicable(length, strategy) && length(strategy) == 0)) &&
        SL.chk_stop("a.m_sim_check_inputs_2")
    (!SL._is_mapping(strategy) || any(p -> isempty(p.first), SL._kvpairs(strategy))) &&
        SL.chk_stop("a.m_sim_check_inputs_3")
    return nothing
end
function _sens_check_common(fn, sim_args, cores; metrics = nothing, check_metrics::Bool = true)
    SL.Bootstrap._is_listlike(sim_args) || SL.chk_stop("liste", fn, "sim_args")
    check_metrics && metrics !== nothing && !(metrics isa Function) && SL.chk_stop("e2.funktion", fn, "metrics")
    return SL.chk_cores(cores, fn)   # seit 1.6.4 höchstens Zahl der Prozessoren, mit Hinweis (Entscheidung 41b)
end
function _lev_check(fn, data, index, rate, expense, spread)
    SL.chk_df(data, fn, "data")
    index = SL.chk_name1(index, fn, "index")
    SL.chk_cols(data, ["date", index], fn)
    SL.chk_col_nofactor(data, "date", fn)   # seit 1.6.4 (Entscheidung 15; bis 1.6.3 still in Text umgewandelt)
    SL.chk_col_nofactor(data, index, fn)   # Entscheidung 15
    SL.chk_col_type(data, index, fn, "numerisch")
    r1 = SL.chk_scalar(rate)
    if r1 isa Real && !(r1 isa Bool)
        SL.chk_num1(r1, fn, "rate")
    elseif r1 isa AbstractString && r1 in names(data)
        SL.chk_col_nofactor(data, r1, fn); SL.chk_col_type(data, r1, fn, "numerisch")
    else
        SL.chk_nofactor(rate, fn, "rate")
    end
    SL.chk_num1(expense, fn, "expense")
    SL.chk_num1(spread, fn, "spread")
    # seit 1.6.5 (CR2-V2-1): Datum ohne NA und aufsteigend, Index nach dem Auffüllen endlich und > 0, Zinsreihe ohne
    # Lücke (bis 1.6.4 Rohfehler bzw. still NaN, 0 oder negative Tagesabstände; Entscheidung 186 M8)
    if SL.nrow(data) > 0
        dt = OF._dates(_col(data, "date"), "data\$date")
        (any(ismissing, dt) || any(i -> dt[i] < dt[i-1], 2:length(dt))) && SL.chk_stop("e3.datum", fn)
        idx = OF._tofloat(SL.Backcast._fill_na(OF._tofloat(_col(data, String(index))), "locf"))
        bad = findfirst(z -> !(isfinite(z) && z > 0), idx)
        bad === nothing || SL.chk_stop("b2b.index_positiv", fn, String(index), bad)
        rt = OF._tofloat(PS._vec(SL.Backcast._resolve_series(SL.chk_scalar(rate), data, "rate")))
        miss = findfirst(isnan, rt)
        miss === nothing || SL.chk_stop("a.mm_luecke", fn, "rate", SimLev.fmt_date(Int(OF._days(dt[miss]))))
    end
    return index
end

# Fehlgeschlagene Läufe der Studien (seit 1.6.5, CR2-C-10/CR2-H-6; R `.sens_failed`): alle fehlgeschlagen = Fehler,
# sonst Warnung mit Anzahl und Meldungen
function _sens_failed(fn, err, n)
    txt = _table_msg(err)
    length(err) == n && SL.chk_stop("b2b.alle_fehl", fn, n, txt)
    isempty(err) || @warn SL.chk_msg("b2b.teil_fehl", fn, length(err), n, txt)
    nothing
end
# simulation() mit aufgelösten sim_args (Bausteine, Pfade; R: .sim_call)
_sim(data, strategy, args) = OF._quiet(() -> SL._sim_call(data, strategy, args))

"`table(errs)` als Text `<msg> (<n> x); ...` (Namen sortiert wie R, Kollation `RStats.str_collate`)."
function _table_msg(errs)
    cnt = Dict{String,Int}()
    for e in errs
        OF._isna(e) && continue
        cnt[e] = get(cnt, e, 0) + 1
    end
    return join(["$k ($(cnt[k]) x)" for k in sort(collect(keys(cnt)); alg = MergeSort, lt = SimLev.RStats.r_isless)], "; ")
end

_is_listval(v) = v isa AbstractVector && !(v isa AbstractString)
"Zelle `i` einer Rasterspalte (Listen-Spalte: das Element; R: Länge 1 = Skalar)."
_cell(col, i) = (v = col[i]; v isa SL.RVector ? v.values : v)
_is_na_scalar(v) = (_is_listval(v) && length(v) == 1) ? OF._isna(v[1]) : (!_is_listval(v) && OF._isna(v))

"`expand.grid(grid)` bzw. data.frame unverändert."
function _grid_frame(grid)
    grid isa SL.RFrame && return grid
    kv = OF._kv(grid)
    return PS._expand_grid(String[p.first for p in kv], Any[_is_listval(p.second) ? collect(p.second) : [p.second] for p in kv])
end

# ═════════════════════════════════════════════════════════════════════════════
# sensitivity_grid
# ═════════════════════════════════════════════════════════════════════════════

"""
    sensitivity_grid(data, strategy, grid; sim_args = nothing, metrics = nothing,
                     keep_results = false, cores = "auto")

`simulation` über ein Parameterraster.

Ruft `simulation()` für jede Kombination von `grid` auf denselben Daten und derselben Strategie auf und
sammelt die Kennzahlen in einem Tabelle (RFrame) (eine Zeile je Lauf). Grundlage der speziellen Studien in
diesem Abschnitt (`sensitivity_rebalancing()`, `sensitivity_leverage()`).

# Argumente
- `data`, `strategy`: Wie in `simulation()`: Tabelle (RFrame) mit Spalte `date` und Kursspalten (Niveaus) bzw.
  Strategie aus `create_strategy()`.
- `grid`: Benannte Liste von Argumentwerten für `simulation()`; alle Kombinationen werden gerechnet. Parameter
  der Bausteine werden mit Pfad `"<Baustein>.<Parameter>"` angesprochen, z. B. `(rebalance.unit = ["month",
  "year"], rebalance.thresh = [5, 10])`, `"dca.value"`, `"tax.rate"`, `"tax.church_tax"`; Teilbausteine von
  `tax_profile()` mit drei Teilen (`"tax.income.marginal_rate"`, `"tax.income.taxable_income"`,
  `"tax.harvest.day"`). Ein Pfad baut den Baustein für jeden Lauf neu: Grundwerte aus dem gleichnamigen
  Baustein in `sim_args` (ohne ihn die Standardwerte des Konstruktors, z. B. `dca_plan(value, span)` braucht
  dann beide Pfade); mehrere Pfade eines Bausteins gelten zusammen. Ohne Punkt sind es Argumente von
  `simulation()` (`start_value`, `risk_free`, `fractions`, `liquidate`, `details` oder ein ganzer Baustein als
  Listen-Spalte). Unbekannte Pfade und die alten Einzelargumente (z. B. `balance_unit`) ergeben einen Fehler
  mit den möglichen Bausteinen und Parametern. Alternativ ein Tabelle (RFrame) mit einer Zeile je Lauf.
  Listen-Spalten (z. B. `splits.thresh`) sind erlaubt. `NA` lässt das Argument weg (Standardwert bzw. Wert aus
  `sim_args`).
  Seit 1.6.4 geprüft: benannte Liste oder data.frame ohne Faktorspalten.
- `sim_args`: Benannte Liste gemeinsamer Argumente für alle Läufe (Standard `()`); Werte aus `grid` haben
  Vorrang. Argumente von `simulation()` außer `data` und `strategy`, also auch Bausteine (z. B. `dca =
  dca_plan(100, 1)`, `tax = tax_profile()`) und Pfade zu Parametern der Bausteine (`"dca.value"`, siehe
  `sensitivity_grid`). Alte Einzelargumente (bis 0.8.0, vor den Bausteinen, z. B. `dca_value`) ergeben einen
  Fehler, der den Baustein nennt.
- `metrics`: Funktion `SimLevResult -> benannter numerischer Vektor` (Standard `bootstrap_study_metrics()`).
  Seit 1.6.4 müssen die Namen der Kennzahlen eindeutig und nicht leer sein und dürfen keiner festen Spalte des
  Ergebnisses gleichen (sonst Fehler nach dem Rechnen).
- `keep_results`: Logisch (Standard `false`): Ergebnisse der Läufe zusätzlich als Attribut `results`
  zurückgeben.
  Seit 1.6.4 nur TRUE oder FALSE.
- `cores`: Anzahl Läufe:
  `"auto"` (Standard seit 1.6.4; bis 1.6.3 1) oder eine ganze Zahl ≥ 1.
  Mit `"auto"` rechnet SimLev die ersten Einheiten nacheinander, misst ihre Rechenzeit und wählt dann
  die Zahl der Aufgaben (Tasks auf Threads statt Prozesse) und der Kern-Threads je Lauf selbst (Planer,
  gleiche Regel in R, Python und Julia): höchstens Zahl der freien Prozessoren (Prozessoren minus andere laufende
  Prozesse gleicher oder höherer Priorität) und der Julia-Threads, so viele, wie
  der freie Speicher trägt, und nur, wenn die Startkosten kleiner sind als der Gewinn (kleine Rechnungen
  bleiben bei einer Aufgabe; mit einem Thread, `julia` ohne `-t`, immer einer).
  Ausgaben, Meldungen, Warnungen und Fehler der Einheiten erscheinen dabei wie mit `cores = 1`, in
  Einheitenreihenfolge.
  Eine feste Zahl ist seit 1.6.5 der Höchstwert der automatischen Wahl: SimLev misst und plant wie mit
  `"auto"`, nimmt aber höchstens so viele Aufgaben (bis 1.6.4 immer so viele ohne Messung; höchstens Zahl der
  Julia-Threads, mit einem Thread nacheinander); höchstens Zahl der Prozessoren: mehr wird mit einem Hinweis begrenzt.
  Ausgaben, die eigene Funktionen
  (etwa `metrics`) direkt mit `println` oder `print` schreiben, erscheinen bei mehreren Aufgaben in der Reihenfolge,
  in der die Einheiten fertig werden; Warnungen (`@warn`) und SimLevs eigene Meldungen erscheinen in
  Einheitenreihenfolge (R und Python: alle Ausgaben in Einheitenreihenfolge). Das Ergebnis hängt nicht von cores ab.
  Je paralleler Einheit rechnen die Kerne mit höchstens Zahl der Prozessoren / Läufe Threads (mindestens 1).

# Rückgabe
Tabelle (RFrame): Rasterspalten (Listen-Spalten als Text "a/b"), die Kennzahlen aus `metrics` (bei
`bootstrap_study_metrics()` z. B. `cagr` als Anteil; mit Sparplan geldgewichtet, XIRR) und, falls ein Lauf
fehlschlug, eine Spalte `error` (Fehlermeldung, Kennzahlen dann `NA`); schlagen alle Läufe fehl, ein Fehler
mit den Meldungen der Läufe. Bei `keep_results = true` Attribut `results` (Liste der `SimLevResult`).

# Beispiel
```julia
using SimLev, Dates, Random
rng = MersenneTwister(1)
n = 1500
d = RFrame("date" => Date(2015, 1, 1) .+ Day.(0:n-1))
d["A"] = 100 .* cumprod(1 .+ 3e-4 .+ 0.01 .* randn(rng, n))
d["B"] = 100 .* cumprod(1 .+ 1e-4 .+ 0.004 .* randn(rng, n))
st = create_strategy(A = asset_config("etf"; share = 0.6), B = asset_config("etf"; share = 0.4))
g = sensitivity_grid(d, st, ("rebalance.unit" => ["month", "year"],); sim_args = (rebalance = rebalance_plan(1),))
println(g)
```
"""
SimLev.@study function sensitivity_grid(data, strategy, grid; sim_args = nothing, metrics = nothing, keep_results = false,
                          cores = "auto")
    @nospecialize   # seit 1.6.3: ein Rumpf für alle Typen der Schlüsselwörter (Übersetzung je Aufrufform entfällt)
    _sens_check_sim(data, strategy)
    # grid: RFrame oder benannte Liste (R nannte unbenannte Elemente "Var1"); seit 1.6.4
    # seit 1.6.5 (CR2-C-9, Entscheidung 185 K28): Tupel von Paaren wie im Beispiel wieder erlaubt (seit 1.6.4 abgelehnt)
    grid isa Tuple && !isempty(grid) && all(p -> p isa Pair, grid) && (grid = collect(Pair, grid))
    # seit 1.6.5 (CR2-7, K19): ein Dict mit mehreren Einträgen gibt eine Warnung (Reihenfolge der Hash-Tabelle)
    grid isa Base.Dict && SL.DeepAnalysis._list_items(grid; fn = "sensitivity_grid")
    gn = grid isa SL.RFrame ? names(grid) : grid isa Union{SL.RList,NamedTuple,AbstractDict,AbstractVector{<:Pair}} ?
         SL.Bootstrap._names(grid) : nothing
    (gn !== nothing && (grid isa SL.RFrame || (!isempty(gn) && all(k -> k isa AbstractString && !isempty(k), gn)))) ||
        SL.chk_stop("e2.benannt", "sensitivity_grid", "grid")
    length(unique(gn)) == length(gn) || SL.chk_stop("e2.doppelt", "sensitivity_grid", "grid")
    if grid isa SL.RFrame   # Entscheidung 15
        for k in gn; SL.chk_col_nofactor(grid, k, "sensitivity_grid"); end
    else
        for (k, v) in zip(gn, SL.Bootstrap._values(grid))
            v isa SL.RFmt.RFactor && SL.chk_stop("faktor", "sensitivity_grid", "grid\$" * k)
        end
    end
    cores = _sens_check_common("sensitivity_grid", sim_args, cores; metrics = metrics)
    sim_args = SL.Bootstrap._e2_sim_args(sim_args)
    keep_results = SL.chk_bool1(keep_results, "sensitivity_grid", "keep_results")
    metrics = _metrics(metrics)
    design = _grid_frame(grid)
    SL.nrow(design) == 0 && SL.chk_stop("rs.raster_leer", "sensitivity_grid")
    SL._sim_check_names(names(design), "sensitivity_grid")   # Argumente von simulation() bzw. Pfade wie "dca.value"
    sim_args = SL._sim_args_set(SL.RList(), sim_args, "sensitivity_grid")
    function run(i)
        a = SL.RList()
        for k in names(design)
            v = _cell(design[k], i)
            _is_na_scalar(v) || (a[k] = v)
        end
        res = try
            _sim(data, strategy, SL._sim_args_set(sim_args, a, "sensitivity_grid"))
        catch e
            e isa InterruptException && rethrow()
            return (m = nothing, err = OF._cond_msg(e), res = nothing)
        end
        return (m = PS._e2_pairs(metrics(res)), err = missing, res = keep_results ? res : nothing)
    end
    out = SL.RParallel.par_lapply(1:SL.nrow(design), run, cores)
    okm = [o.m for o in out if o.m !== nothing]
    isempty(okm) && _sens_failed("sensitivity_grid", Any[o.err for o in out], length(out))   # Fehler (Tabelle seit 1.6.5)
    # seit 1.6.4 (Entscheidung 43, Regel 28 wie bootstrap_study): Namen der Kennzahlen eindeutig, nicht leer und keine
    # Spalte des Rasters bzw. error; geprüft nach dem Rechnen, bei jedem cores gleich (R: gleiche Prüfung)
    for m in okm
        SL.chk_kennzahlen(m[1], length(m[2]), vcat(String[string(k) for k in names(design)], "error"), "sensitivity_grid")
    end
    mnames = okm[1][1]
    tab = SL.RFrame()
    for k in names(design)
        col = design[k]
        if any(_is_listval, col)
            col = String[_is_listval(v) ? join([OF._as_chr(e) for e in v], "/") : OF._as_chr(v) for v in col]
        end
        tab = _addcol(tab, k, col, SL.nrow(design))
    end
    for (j, k) in enumerate(mnames)
        tab = _addcol(tab, k, Float64[o.m === nothing ? NA : (p = findfirst(==(k), o.m[1]); p === nothing ? NA : o.m[2][p]) for o in out],
                      SL.nrow(design))
    end
    errs = Union{Missing,String}[o.err for o in out]
    all(ismissing, errs) || (tab["error"] = errs)
    keep_results && (SL.attrs(tab)["results"] = Any[o.res for o in out])
    return tab
end
_addcol(tab::SL.RFrame, k, col, n) = SL.ncol(tab) == 0 ? SL.RFrame(k => col; nrow = n) : (tab[k] = col; tab)

# ═════════════════════════════════════════════════════════════════════════════
# Rebalancing
# ═════════════════════════════════════════════════════════════════════════════

const _FREQ = ["monthly" => ("month", 1), "bimonthly" => ("month", 2), "quarterly" => ("quarter", 1),
               "four_monthly" => ("month", 4), "semiannual" => ("month", 6), "yearly" => ("year", 1)]

_num_of(x) = x isa AbstractString ? parse(Float64, x) : Float64(x)
_isna_lgl(v) = v === missing || v === nothing      # logisches NA (R: NA)

"""
    sensitivity_rebalancing(data, strategy; frequencies = (monthly … yearly), offsets = nothing,
                            bands = missing, band_type = "absolute", include_none = true,
                            sim_args = nothing, metrics = nothing, cores = "auto")

Rebalancing-Sensitivität.

Vergleicht Rebalancing-Frequenzen, Versatz vor dem Periodenende und Toleranzbänder (absolut oder relativ) für
eine Strategie, wie die Rebalancing-Sensitivity von testfol.io. Jede Kombination aus `frequencies`, `offsets`
und `bands` wird mit `simulation()` (`rebalance = rebalance_plan(...)`) gerechnet. Bänder werden an den
Kalenderterminen der jeweiligen Frequenz geprüft. Termine, die nicht als Zeile in `data` vorkommen (bei
Handelstagsdaten z. B. Wochenenden), entfallen.

# Argumente
- `data`, `strategy`: Wie in `simulation()`: Tabelle (RFrame) mit Spalte `date` und Kursspalten (Niveaus) bzw.
  Strategie aus `create_strategy()`.
- `frequencies`: Benannte Liste von `[unit, span]` mit `unit` "month", "quarter" oder "year" und `span` =
  Anzahl Einheiten zwischen den Terminen (`unit` und `span` von `rebalance_plan()`). Standard: monatlich,
  zweimonatlich, quartalsweise, viermonatlich, halbjährlich, jährlich (Namen monthly, bimonthly, quarterly,
  four_monthly, semiannual, yearly).
  Seit 1.6.4 geprüft: benannte Liste, je Eintrag Einheit und Abstand; seit 1.6.5 auch die Werte (Einheit aus
  den drei Namen, Abstand ganze Zahl ≥ 1 bis zur Obergrenze von `rebalance_plan()`).
- `offsets`: Numerischer Vektor: Kalendertage vor dem Ende des Monats, Dreimonatsblocks bzw. Jahres, in dem
  der Termin liegt (0 = letzter Tag; `rebalance_plan(anchor = "end", days = offset + 1)`). `nothing`
  (Standard) rebalanciert am Periodenanfang.
  Seit 1.6.4 ganze Zahlen ≥ 0.
- `bands`: Toleranzbänder in Prozent (5 = 5 Prozent); `NA` (Standard) = an jedem Termin rebalancieren. Mehrere
  Werte, auch gemischt mit `NA`, sind möglich.
  Seit 1.6.4 Werte ≥ 0 oder NA.
- `band_type`: "absolute" (Standard; Prozentpunkte Abweichung vom Zielgewicht) oder "relative" (Prozent des
  Zielgewichts), siehe `thresh_type` von `rebalance_plan()`.
- `include_none`: Logisch (Standard `true`): zusätzlich einen Lauf ohne Rebalancing (Zeile `frequency =
  "none"`).
  Seit 1.6.4 nur TRUE oder FALSE.
- `sim_args`: Benannte Liste gemeinsamer Argumente für alle Läufe (Standard `()`): Argumente von
  `simulation()` außer `data` und `strategy`, also auch Bausteine (z. B. `dca = dca_plan(100, 1)`, `tax =
  tax_profile()`) und Pfade zu Parametern der Bausteine (`"dca.value"`, siehe `sensitivity_grid`). Alte
  Einzelargumente (bis 0.8.0, vor den Bausteinen, z. B. `dca_value`) ergeben einen Fehler, der den Baustein
  nennt. Ein `rebalance = rebalance_plan(...)` in `sim_args` liefert die Grundwerte (z. B. `start`,
  `event_col`); Frequenz, Versatz und Band setzt die Funktion je Lauf über die Pfade `"rebalance.unit"`,
  `"rebalance.span"`, `"rebalance.anchor"`, `"rebalance.days"`, `"rebalance.thresh"` und
  `"rebalance.thresh_type"`; der Lauf ohne Rebalancing setzt `rebalance = nothing`.
- `metrics`: Funktion `SimLevResult -> benannter numerischer Vektor` (Standard `bootstrap_study_metrics()`).
  Seit 1.6.4 müssen die Namen der Kennzahlen eindeutig und nicht leer sein und dürfen keiner festen Spalte des
  Ergebnisses gleichen (sonst Fehler nach dem Rechnen).
- `cores`: Anzahl Läufe:
  `"auto"` (Standard seit 1.6.4; bis 1.6.3 1) oder eine ganze Zahl ≥ 1.
  Mit `"auto"` rechnet SimLev die ersten Einheiten nacheinander, misst ihre Rechenzeit und wählt dann
  die Zahl der Aufgaben (Tasks auf Threads statt Prozesse) und der Kern-Threads je Lauf selbst (Planer,
  gleiche Regel in R, Python und Julia): höchstens Zahl der freien Prozessoren (Prozessoren minus andere laufende
  Prozesse gleicher oder höherer Priorität) und der Julia-Threads, so viele, wie
  der freie Speicher trägt, und nur, wenn die Startkosten kleiner sind als der Gewinn (kleine Rechnungen
  bleiben bei einer Aufgabe; mit einem Thread, `julia` ohne `-t`, immer einer).
  Ausgaben, Meldungen, Warnungen und Fehler der Einheiten erscheinen dabei wie mit `cores = 1`, in
  Einheitenreihenfolge.
  Eine feste Zahl ist seit 1.6.5 der Höchstwert der automatischen Wahl: SimLev misst und plant wie mit
  `"auto"`, nimmt aber höchstens so viele Aufgaben (bis 1.6.4 immer so viele ohne Messung; höchstens Zahl der
  Julia-Threads, mit einem Thread nacheinander); höchstens Zahl der Prozessoren: mehr wird mit einem Hinweis begrenzt.
  Ausgaben, die eigene Funktionen
  (etwa `metrics`) direkt mit `println` oder `print` schreiben, erscheinen bei mehreren Aufgaben in der Reihenfolge,
  in der die Einheiten fertig werden; Warnungen (`@warn`) und SimLevs eigene Meldungen erscheinen in
  Einheitenreihenfolge (R und Python: alle Ausgaben in Einheitenreihenfolge). Das Ergebnis hängt nicht von cores ab.
  Je paralleler Einheit rechnen die Kerne mit höchstens Zahl der Prozessoren / Läufe Threads (mindestens 1).

# Rückgabe
Tabelle (RFrame) der Klasse `SimLevSensitivity` mit den Spalten `frequency`, `offset`, `band`, `band_type` und
den Kennzahlen aus `metrics`; fehlgeschlagene Läufe fehlen (seit 1.6.5 mit einer Warnung mit Anzahl und
Meldungen; schlagen alle fehl, ein Fehler). Attribut `kind = "rebalancing"`. Ausgabe und
Grafik über `print()` und `plot()`. Mit Sparplan (`sim_args`) ist `cagr` geldgewichtet (XIRR); `print()` weist
darauf hin.

# Beispiel
```julia
using SimLev, Dates, Random
rng = MersenneTwister(1)
n = 1500
d = RFrame("date" => Date(2015, 1, 1) .+ Day.(0:n-1))
d["A"] = 100 .* cumprod(1 .+ 3e-4 .+ 0.01 .* randn(rng, n))
d["B"] = 100 .* cumprod(1 .+ 1e-4 .+ 0.004 .* randn(rng, n))
st = create_strategy(A = asset_config("etf"; share = 0.6), B = asset_config("etf"; share = 0.4))
println(sensitivity_rebalancing(d, st; frequencies = (monthly = ["month", 1], yearly = ["year", 1]),
                                bands = [missing, 5]))
```
"""
SimLev.@study function sensitivity_rebalancing(data, strategy; frequencies = nothing, offsets = nothing, bands = missing,
                                 band_type = nothing, include_none = true, sim_args = nothing, metrics = nothing,
                                 cores = "auto")
    SimLev.DataPrep._e5_match_arg(band_type, ("absolute", "relative"), "sensitivity_rebalancing", "band_type")   # seit 1.6.4 (K43 T2-N4) Prüfung vor match.arg (Meldung auswahl)
    band_type = OF._match_arg(band_type, ("absolute", "relative"))
    fn = "sensitivity_rebalancing"
    _sens_check_sim(data, strategy)
    if frequencies !== nothing
        frequencies isa Tuple && !isempty(frequencies) && all(p -> p isa Pair, frequencies) &&
            (frequencies = collect(Pair, frequencies))   # seit 1.6.5 wie grid (K28)
        frequencies isa Base.Dict && SL.DeepAnalysis._list_items(frequencies; fn = fn)   # seit 1.6.5 (CR2-7, K19)
        fnm = frequencies isa Union{SL.RList,NamedTuple,AbstractDict,AbstractVector{<:Pair}} ? SL.Bootstrap._names(frequencies) : nothing
        (fnm !== nothing && !isempty(fnm) && all(k -> k isa AbstractString && !isempty(k), fnm)) || SL.chk_stop("e2.benannt", fn, "frequencies")
        for (k, f) in zip(fnm, SL.Bootstrap._values(frequencies))
            (f isa Union{AbstractVector,Tuple} && length(f) == 2) || SL.chk_stop("e2.frequenz", fn, k)
        end
        # seit 1.6.5 (CR2-C-10, Entscheidung 185 K26): Einheit und Abstand vorab (bis 1.6.4 fehlten solche Läufe still
        # bzw. Rohfehler "cannot parse")
        for (k, f) in zip(fnm, SL.Bootstrap._values(frequencies))
            u = collect(f)[1]; spv = collect(f)[2]
            uok = u isa AbstractString && u in ("month", "quarter", "year")
            hi = uok ? SL._blk_span_max(u) : 2147483647
            sp = spv isa Real && !(spv isa Bool) ? Float64(spv) :
                 spv isa AbstractString ? something(tryparse(Float64, strip(spv)), NaN) : NaN
            (uok && isfinite(sp) && sp == trunc(sp) && sp >= 1 && sp <= hi) || SL.chk_stop("b2b.frequenz_wert", fn, k, SL.chk_fmt(hi))
        end
    end
    if offsets !== nothing
        ov = PS._vec(offsets)
        (!isempty(ov) && all(z -> z isa Real && !(z isa Bool) && isfinite(z) && z == trunc(z) && z >= 0, ov)) ||
            SL.chk_stop("ganz_vektor", fn, "offsets", SL.chk_range_text(0))
    end
    bv = PS._vec(bands)
    (!isempty(bv) && all(z -> OF._isna(z) || (z isa Real && !(z isa Bool) && isfinite(z) && z >= 0), bv)) ||
        SL.chk_stop("e2.zahlen_na", fn, "bands", SL.chk_range_text(0))
    include_none = SL.chk_bool1(include_none, fn, "include_none")
    cores = _sens_check_common(fn, sim_args, cores; metrics = metrics)
    sim_args = SL.Bootstrap._e2_sim_args(sim_args)
    frequencies = frequencies === nothing ? _FREQ : OF._kv(frequencies)
    sim_args = SL._sim_args_set(SL.RList(), sim_args, "sensitivity_rebalancing")
    metrics = _metrics(metrics)
    offs = offsets === nothing ? Any[missing] : Any[e for e in PS._vec(offsets)]
    bnds = Any[e for e in PS._vec(bands)]
    rows = Vector{Any}()
    for (fn, f) in frequencies
        f = collect(f)
        for off in offs, b in bnds
            # Rebalancing über Pfade: weitere Angaben eines rebalance_plan() aus sim_args bleiben erhalten
            a = SL.RList("rebalance.unit" => String(string(f[1])), "rebalance.span" => _num_of(f[2]),
                         "rebalance.thresh_type" => band_type)
            if !OF._isna(off)
                a["rebalance.anchor"] = "end"; a["rebalance.days"] = off + 1
            end
            OF._isna(b) || (a["rebalance.thresh"] = b)
            push!(rows, (label = (fn, off, b, band_type), args = a))
        end
    end
    include_none && push!(rows, (label = ("none", missing, missing, missing), args = SL.RList("rebalance" => nothing)))
    function run(i)
        res = try
            _sim(data, strategy, SL._sim_args_set(sim_args, rows[i].args, "sensitivity_rebalancing"))
        catch e
            e isa InterruptException && rethrow()
            return OF._cond_msg(e)
        end
        return PS._e2_pairs(metrics(res))
    end
    out = SL.RParallel.par_lapply(1:length(rows), run, cores)
    ok = [!(o isa AbstractString) for o in out]
    # seit 1.6.5 (CR2-C-10 b): einzelne fehlgeschlagene Läufe mit Warnung (bis 1.6.4 fehlten sie still)
    _sens_failed("sensitivity_rebalancing", Any[o for o in out if o isa AbstractString], length(out))
    good = out[ok]; lab = [r.label for r in rows[ok]]
    # seit 1.6.4 (Entscheidung 43, Regel 28): Namen der Kennzahlen eindeutig, nicht leer und keine feste Spalte
    for g in good
        SL.chk_kennzahlen(g[1], length(g[2]), ["frequency", "offset", "band", "band_type"], "sensitivity_rebalancing")
    end
    mnames = good[1][1]
    n = length(good)
    tab = SL.RFrame("frequency" => String[l[1] for l in lab],
                    "offset" => _lblcol([l[2] for l in lab]), "band" => _lblcol([l[3] for l in lab]),
                    "band_type" => Union{Missing,String}[l[4] for l in lab]; class = ["SimLevSensitivity", "data.frame"])
    for (j, k) in enumerate(mnames)
        tab[k] = Float64[g[2][j] for g in good]
    end
    SL.attrs(tab)["kind"] = "rebalancing"
    return tab
end
"Beschriftungsspalte: nur logische NA → logisch, sonst numerisch mit NA."
_lblcol(v) = all(_isna_lgl, v) ? Union{Missing,Bool}[missing for _ in v] : Float64[OF._f64(e) for e in v]

# ═════════════════════════════════════════════════════════════════════════════
# Lump Sum vs. DCA
# ═════════════════════════════════════════════════════════════════════════════

_num_str(x) = OF._as_chr(Float64(x))

"`seq.Date(s, by = \"<k> <einheit>\", length.out = 2)[2]` (POSIXlt-Normalisierung)."
function _seq_date_2nd(s::Date, by::AbstractString)
    parts = split(by, " ")
    unit = parts[end]
    k = length(parts) > 1 ? trunc(Int, parse(Float64, parts[1])) : 1
    y, m, d = Dates.yearmonthday(s)
    if startswith(unit, "year")
        y2, m2 = y + k, m
    else
        tot = (m - 1) + k
        y2, m2 = y + fld(tot, 12), mod(tot, 12) + 1
    end
    return Date(y2, m2, 1) + Day(d - 1)
end

# seit 1.6.5 (CR2-F-7): eine Spalte vom Typ Vector{Float64} ohne Kopie (bis 1.6.4 elementweise umgewandelt, rund 40 %
# der Laufzeit); Leser verändern sie nicht
function _rep_get(rep, a, key)
    r = rep[a]
    v = r isa AbstractDict || r isa SL.RList ? r[key] : getproperty(r, Symbol(key))
    return v isa Vector{Float64} ? v : Float64[Float64(e) for e in v]
end

"""
    planning_lumpsum_vs_dca(data, strategy; amount = 10000, months = 12, horizon = 10, step = 1,
                   sim_args = nothing, cores = "auto")

Einmalanlage gegen gestreckten Einstieg (Lump Sum vs. DCA).

Vergleicht für rollierende Starttermine (jeweils am Monatsersten) die sofortige Anlage eines Betrags mit einem
Einstieg in `months` gleichen Monatsraten. Verglichen wird das Vermögen nach `horizon` Jahren.

# Argumente
- `data`, `strategy`: Wie in `simulation()`: Tabelle (RFrame) mit Spalte `date` und Kursspalten (Niveaus) bzw.
  Strategie aus `create_strategy()`.
- `amount`: Anlagebetrag in Währungseinheiten (Standard 10000); bei DCA in `months` Raten von `amount /
  months` aufgeteilt.
  Seit 1.6.4 eine Zahl > 0.
- `months`: Anzahl Monatsraten des gestreckten Einstiegs (Standard 12).
  Seit 1.6.4 eine ganze Zahl ≥ 1.
  Seit 1.6.4 höchstens 1200; seit 1.6.5 höchstens 12 * `horizon`.
- `horizon`: Vergleichshorizont in Jahren ab Start (Standard 10).
  Seit 1.6.4 eine ganze Zahl ≥ 1.
  Seit 1.6.4 höchstens 100.
- `step`: Jeder wievielte mögliche Starttermin verwendet wird (Standard 1 = jeder Monat; 12 = jährlich).
  Seit 1.6.4 eine ganze Zahl ≥ 1.
- `sim_args`: Benannte Liste weiterer Argumente für `simulation()` (z. B. `tax = tax_profile()`): Argumente
  von `simulation()` außer `data` und `strategy`, also auch Bausteine (z. B. `dca = dca_plan(100, 1)`, `tax =
  tax_profile()`) und Pfade zu Parametern der Bausteine (`"dca.value"`, siehe `sensitivity_grid`). Alte
  Einzelargumente (bis 0.8.0, vor den Bausteinen, z. B. `dca_value`) ergeben einen Fehler, der den Baustein
  nennt. `start_value` und `dca` (auch Pfade `"dca.*"` und die alten `dca_*`) setzt die Funktion selbst (in
  `sim_args` ein Fehler).
- `cores`: Anzahl Läufe:
  `"auto"` (Standard seit 1.6.4; bis 1.6.3 1) oder eine ganze Zahl ≥ 1.
  Mit `"auto"` rechnet SimLev die ersten Einheiten nacheinander, misst ihre Rechenzeit und wählt dann
  die Zahl der Aufgaben (Tasks auf Threads statt Prozesse) und der Kern-Threads je Lauf selbst (Planer,
  gleiche Regel in R, Python und Julia): höchstens Zahl der freien Prozessoren (Prozessoren minus andere laufende
  Prozesse gleicher oder höherer Priorität) und der Julia-Threads, so viele, wie
  der freie Speicher trägt, und nur, wenn die Startkosten kleiner sind als der Gewinn (kleine Rechnungen
  bleiben bei einer Aufgabe; mit einem Thread, `julia` ohne `-t`, immer einer).
  Ausgaben, Meldungen, Warnungen und Fehler der Einheiten erscheinen dabei wie mit `cores = 1`, in
  Einheitenreihenfolge.
  Eine feste Zahl ist seit 1.6.5 der Höchstwert der automatischen Wahl: SimLev misst und plant wie mit
  `"auto"`, nimmt aber höchstens so viele Aufgaben (bis 1.6.4 immer so viele ohne Messung; höchstens Zahl der
  Julia-Threads, mit einem Thread nacheinander); höchstens Zahl der Prozessoren: mehr wird mit einem Hinweis begrenzt.
  Ausgaben, die eigene Funktionen
  (etwa `metrics`) direkt mit `println` oder `print` schreiben, erscheinen bei mehreren Aufgaben in der Reihenfolge,
  in der die Einheiten fertig werden; Warnungen (`@warn`) und SimLevs eigene Meldungen erscheinen in
  Einheitenreihenfolge (R und Python: alle Ausgaben in Einheitenreihenfolge). Das Ergebnis hängt nicht von cores ab.
  Je paralleler Einheit rechnen die Kerne mit höchstens Zahl der Prozessoren / Läufe Threads (mindestens 1).

# Rückgabe
Tabelle (RFrame) der Klasse `SimLevLumpSum` mit einer Zeile je Start: `start` (Datum), `lump_sum` und `dca`
(Endvermögen nach `horizon` Jahren in Währungseinheiten), `advantage` (Lump Sum / DCA - 1, als Anteil) und
`exact` (logisch: DCA-Depot exakt über Stückzahlen fortgeschrieben, siehe oben). Attribut `summary`:
`win_rate` (Anteil der Starttermine mit Vorsprung der Einmalanlage), `mean_advantage`, `median_advantage`,
`mlsa` (mittlerer Vorsprung bei Gewinn) und `mlsd` (mittlerer Rückstand bei Verlust), alle als Anteil;
Attribut `settings`.

# Details
Die Einmalanlage wird über den ganzen Horizont mit `simulation()` gerechnet, der gestreckte Einstieg über die
`months` Monate der Einstiegsphase (Sparplan). Danach wird das DCA-Depot fortgeschrieben:

- exakt: Handelt die Strategie nach der Einstiegsphase nicht mehr (in der Einmalanlage bleibt die Stückzahl
  jedes Assets bis zum Horizont gleich, z. B. Buy-and-Hold ohne Rebalancing, ohne Steuern), hält auch das
  DCA-Depot seine Stückzahlen: Endwert = Summe der Stückzahlen am Ende der Einstiegsphase x Kurs am Horizont
  plus Cash. Jedes Asset behält so seine eigenen Gewichte.
- Näherung: Sonst (Rebalancing, Signale, Steuern mit Vorabpauschale oder Kosten, die Stück verkaufen) wächst
  das DCA-Depot mit dem zeitgewichteten Index der Einmalanlage (`result_index()`), als hätte es ab dem Ende
  der Einstiegsphase deren Gewichte; mit Steuern (`tax = tax_profile()`) erscheint dazu eine Warnung.

Welche Variante verwendet wurde, steht je Start in der Spalte `exact`. Für Fonds-Wrapper
(`asset_config(wrapper = )`) ist der Kurs der Anteilswert aus `wrapper_nav()` im Fenster der Einmalanlage, wie
ihn `simulation()` rechnet.

Als Starttermine dienen nur Monatserste, die als Zeile in `data` vorkommen (bei Handelstagsdaten entfallen
Monate, deren Erster kein Handelstag ist), und nur solche, nach denen noch `horizon` Jahre Daten folgen.

# Beispiel
```julia
using SimLev, Dates, Random
rng = MersenneTwister(1)
n = 2190
d = RFrame("date" => Date(2010, 1, 1) .+ Day.(0:n-1))
d["ETF"] = 100 .* cumprod(1 .+ 3e-4 .+ 0.01 .* randn(rng, n))
ld = planning_lumpsum_vs_dca(d, create_strategy(ETF = asset_config("etf")); amount = 12000, months = 12,
                             horizon = 3, step = 6)
println(ld)
```
"""
SimLev.@study function planning_lumpsum_vs_dca(data, strategy; amount = 10000, months = 12, horizon = 10, step = 1, sim_args = nothing,
                        cores = "auto")
    fn = "planning_lumpsum_vs_dca"
    _sens_check_sim(data, strategy)
    amount = SL.chk_num1(amount, fn, "amount"; lo = 0, lo_open = true)   # seit 1.6.4
    months = SL.chk_int1(months, fn, "months")
    horizon = SL.chk_int1(horizon, fn, "horizon")
    # seit 1.6.4 Obergrenzen (Entscheidungen 16 und 46): Laufzeiten bis 100 Jahre (months in Monaten)
    SL.chk_max(months, SL.SL_MAX_MONATE, fn, "months")
    SL.chk_max(horizon, SL.SL_MAX_JAHRE, fn, "horizon")
    # seit 1.6.5 (CR2-F-6): Einstiegsphase höchstens so lang wie der Horizont (bis 1.6.4 Rohfehler MethodError)
    months > 12 * horizon && SL.chk_stop("b2b.months_horizont", fn, Int(months), Int(horizon))
    step = SL.chk_int1(step, fn, "step")
    cores = _sens_check_common(fn, sim_args, cores; check_metrics = false)
    sim_args = SL.Bootstrap._e2_sim_args(sim_args)
    sim_args = SL.RList(SL._sim_kv(sim_args)...)
    own = [k for k in keys(sim_args) if k in ("start_value", "dca", "dca_mode", "dca_value", "dca_span", "dca_unit", "dca_skip") ||
           startswith(k, "dca.")]
    isempty(own) || SL.chk_stop("rs.sim_args_eigen", fn, join(own, ", "))
    sim_args = SL._sim_args_set(SL.RList(), sim_args, "planning_lumpsum_vs_dca")
    data = PS._as_frame(data)
    data["date"] isa SL.RFmt.RFactor && SL.chk_stop("spalte_faktor", "planning_lumpsum_vs_dca", "date")   # seit 1.6.4 (Entscheidung 15; bis 1.6.3 still in Text umgewandelt)
    data["date"] = OF._dates(data["date"], "planning_lumpsum_vs_dca: data\$date")
    data = SL.rows(data, OF._order(Float64[OF._days(v) for v in data["date"]]))
    d = collect(Date, data["date"])
    dn = Float64[OF._days(v) for v in d]
    get(sim_args, "tax", nothing) !== nothing &&
        @warn SL.chk_msg("b2b.m_planning_lumpsum_vs_dca")
    firsts = d[Dates.day.(d) .== 1]
    # seit 1.6.5 (CR2-F-5, K12): ein Start zählt, wenn sein Fenster am letzten Datentag endet (ab max(d) + 1 gerechnet)
    last_ok = _seq_date_2nd(maximum(d) + Day(1), "-" * _num_str(horizon) * " years")
    starts = firsts[firsts .<= last_ok]
    isempty(starts) && SL.chk_stop("rs.horizont_kurz", fn)   # seit 1.6.4 vor seq (vorher "wrong sign in 'by' argument")
    sel = PS._seq_by(1, length(starts), step)
    starts = starts[Int.(sel)]
    hz = _num_str(horizon) * " years"; mo = _num_str(months) * " months"
    # Kurse je Spalte, gefüllt beim ersten Zugriff; seit 1.6.4 (K43 T2-B7) nur unter der Sperre (die Einheiten laufen
    # mit cores >= 2 in mehreren Aufgaben, Dict ist nicht threadsicher)
    cache = Dict{String,Vector{Float64}}()
    cache_lock = ReentrantLock()
    wraps = SL._strategy_wrappers(strategy)   # Fonds-Wrapper: Asset-Name ist keine Kursspalte (_strategy_columns)
    function px(a, dates, navs = nothing)
        if a in wraps                          # Kurs = Anteilswert im Fenster der Einmalanlage (findInterval, mindestens 1)
            nd, nv = navs[a]
            return Float64[nv[max(searchsortedlast(nd, Float64(OF._days(t))), 1)] for t in dates]
        end
        pa = lock(cache_lock) do
            get!(() -> OF._tofloat(SL.Backcast._fill_na(OF._tofloat(data[a]), "locf")), cache, a)
        end
        return Float64[pa[searchsortedlast(dn, Float64(OF._days(t)))] for t in dates]
    end
    function run(s)
        e = _seq_date_2nd(s, hz) - Day(1)
        e_dca = _seq_date_2nd(s, mo) - Day(1)
        w = SL.rows(data, (d .>= s) .& (d .<= e))
        ls = _sim(w, strategy, SL.RList("start_value" => amount, SL._sim_kv(sim_args)...))
        wd = SL.rows(data, (d .>= s) .& (d .<= e_dca))
        dp = SL.dca_plan(; value = amount / months, span = 1, unit = "month", skip = true)
        dca = _sim(wd, strategy, SL.RList("start_value" => amount / months, "dca" => dp, SL._sim_kv(sim_args)...))
        ix = SL.Withdrawal.result_index(ls)
        # Fonds-Wrapper: Anteilswert aus den inneren Spalten des Fensters (wie in simulation())
        navs = Dict{String,Tuple{Vector{Float64},Vector{Float64}}}()
        if !isempty(wraps)
            wf = SL._to_frame(w); wf.filled_attr = nothing
            sa = Dict(SL._strategy_pairs(strategy))
            for a in wraps
                nv = OF._quiet(() -> SL._wrapper_nav_calc(wf, SL._aget(sa[a], "wrapper"), get(sim_args, "splits", nothing),
                                                          "Wrapper '$a'", "planning_lumpsum_vs_dca: Wrapper '$a'"))
                navs[a] = (Float64[OF._days(v) for v in nv["date"]], Float64.(nv["nav"]))
            end
        end
        ixd = collect(Date, ix["date"]); ixv = OF._tofloat(ix["value"])
        k = findfirst(==(maximum(wd["date"])), ixd)
        assets = collect(keys(dca.report))
        rws = k:length(ixd)
        const_ = all(map(assets) do a
            p = px(a, ixd[rws], navs); u = _rep_get(ls.report, a, "worth")[rws] ./ p
            all(isfinite, u) && all(abs.(u .- u[1]) .<= 1e-9 * max(1, abs(u[1])))
        end)
        dca_end = if const_
            nd = length(dca.worth)
            SL.r_sum(Float64[_rep_get(dca.report, a, "worth")[nd] / px(a, [dca.dates[nd]], navs)[1] * px(a, [ixd[end]], navs)[1] +
                             _rep_get(dca.report, a, "money")[nd] for a in assets])
        else
            dca.worth[end] * ixv[end] / ixv[k]
        end
        return (Float64(ls.worth[end]), Float64(dca_end), const_)
    end
    res = SL.RParallel.par_lapply(starts, run, cores)
    lump = Float64[r[1] for r in res]; dcav = Float64[r[2] for r in res]
    adv = lump ./ dcav .- 1
    tab = SL.RFrame("start" => starts, "lump_sum" => lump, "dca" => dcav, "advantage" => adv,
                    "exact" => Bool[r[3] for r in res]; class = ["SimLevLumpSum", "data.frame"])
    # seit 1.6.5 (CR2-W3-1, Entscheidung 189): Fast-Gleichstand |advantage| <= 1e-12 (Regel _near_eq) weder vorn noch
    # hinten
    SL.attrs(tab)["summary"] = _ls_summary(adv)
    SL.attrs(tab)["settings"] = SL.RList("amount" => amount, "months" => months, "horizon" => horizon)
    return tab
end

"Vergleich mit Toleranz (seit 1.6.5, Entscheidung 189 W2-1/W3-1; R `.near_eq`): gleich, wenn |a - b| <= tol max(1, |a|, |b|)."
_near_eq(a::Real, b::Real, tol = 1e-12) = abs(a - b) <= tol * max(1.0, abs(a), abs(b))

"Kennzahlen von planning_lumpsum_vs_dca aus den Vorsprüngen (R `.ls_summary`; seit 1.6.5 eigene Funktion, CR2-W3-2)."
function _ls_summary(adv)
    adv = Float64[Float64(z) for z in adv]
    tie = _near_eq.(adv, 0.0)
    win = (adv .> 0) .& .!tie
    lose = (adv .< 0) .& .!tie
    return SL.RVector([OF._mean_lgl(collect(win)), SL.r_mean(adv), OF._median(adv),
                       any(win) ? SL.r_mean(adv[win]) : NA, any(lose) ? SL.r_mean(adv[lose]) : NA];
                      names = ["win_rate", "mean_advantage", "median_advantage", "mlsa", "mlsd"])
end

function _print_lumpsum(io::IO, x)
    # seit 1.6.5 (CR2-W3-2): Kennzahlen aus den vorhandenen Zeilen (bis 1.6.4 aus dem Attribut der ganzen Tabelle, auch
    # für rows(x, 1:3)); für das ungeteilte Ergebnis dieselben Werte
    s = _ls_summary(x["advantage"]); st = SL.attrs(x)["settings"]
    # seit 1.6.5 (CR2-W3-3): Betrag unter 1 mit %.15g
    amt = Float64(st["amount"]) < 1 ? OF._spf("%.15g", Float64(st["amount"])) :
          SL.RFmt.formatC(st["amount"]; format = "f", digits = 0, big_mark = " ")
    amt = amt isa AbstractString ? String(amt) : String(first(amt))
    print(io, OF._spf("Lump Sum vs. DCA: %d Starttermine, %s in %d Monatsraten, Horizont %g Jahre\n",
                      SL.nrow(x), amt, st["months"], Float64(st["horizon"])))
    print(io, OF._spf("  Einmalanlage vorn:          %.1f %% der Starttermine\n", 100 * s["win_rate"]))
    print(io, OF._spf("  Vorsprung Mittel / Median:  %+.2f %% / %+.2f %%\n", 100 * s["mean_advantage"], 100 * s["median_advantage"]))
    print(io, OF._spf("  MLSA (wenn vorn):           %+.2f %%\n", 100 * s["mlsa"]))
    print(io, OF._spf("  MLSD (wenn hinten):         %+.2f %%\n", 100 * s["mlsd"]))
    nothing
end

# ═════════════════════════════════════════════════════════════════════════════
# Hebel
# ═════════════════════════════════════════════════════════════════════════════

_col(data, k) = data isa SL.RFrame ? data[k] : OF._lget(data, k)

"""
    series_leverage(data, index; leverage = 2, rate = 0, expense = 0, spread = 0, start = 100)

Gehebelte Reihe aus einem Index erzeugen (täglich zurückgesetzt, MSCI-Formel plus Kosten).

Bildet eine täglich zurückgesetzte Hebelreihe (Niveau) nach der MSCI-Formel plus Fondskosten (wie die
Ticker-Parameter L, E, SP und FR bei testfol.io): r = L x + (1 - L) i T/360 - TER· T/365 - s· m(L) T/360 mit
Indexrendite x, Kalendertagen T seit der Vorzeile, m(L) = max(L-1, 0) + max(-L, 0) und i, TER, s als Anteil
(Prozentangabe / 100); der Zins gilt für den Tag der Rendite. Das Ergebnis kann als Kursspalte in
`simulation()` dienen; für die Anpassung an ein echtes Produkt siehe `backcast_fit()`.

# Argumente
- `data`: Tabelle (RFrame) mit Spalte `date` und der Indexspalte.
  Seit 1.6.4 mindestens eine Datenzeile (vorher ergab R bei 0 Zeilen still 100).
  Seit 1.6.5 muss `date` aufsteigend und ohne NA sein.
- `index`: Spaltenname des Index (Niveau, nicht Rendite; Lücken werden mit dem letzten Wert gefüllt).
  Seit 1.6.4 geprüft: Zahlenspalte in data (kein Faktor). Seit 1.6.5 nach dem Auffüllen endlich und > 0 (sonst
  Fehler mit Zeile).
- `leverage`: Hebel L als Zahl (Standard 2; negativ für Short).
- `rate`: Finanzierungszins in Prozent p. a. (Standard 0): Skalar, Spaltenname, Vektor der Länge `nrow(data)`,
  `data.frame(date, value)` oder benannter Vektor mit Datumsnamen.
  Seit 1.6.5 ohne fehlende Werte (Lücke ist ein Fehler).
- `expense`: TER in Prozent p. a. (Standard 0).
- `spread`: Spread auf den finanzierten bzw. leerverkauften Anteil m(L) in Prozent p. a. (Standard 0).
- `start`: Startwert der Reihe in der ersten Zeile (Standard 100).
  Seit 1.6.4 eine Zahl > 0.

# Rückgabe
Numerischer Vektor (Niveau, Länge `nrow(data)`); fällt eine Tagesrendite auf -100 Prozent oder darunter,
bleibt die Reihe ab dort bei 0.

# Beispiel
```julia
using SimLev, Dates, Random
rng = MersenneTwister(1)
n = 1500
d = RFrame("date" => Date(2015, 1, 1) .+ Day.(0:n-1))
d["idx"] = 100 .* cumprod(1 .+ 3e-4 .+ 0.01 .* randn(rng, n))
d["zins"] = fill(2.0, n)
d["l2"] = series_leverage(d, "idx"; leverage = 2, rate = "zins", expense = 0.6, spread = 0.3)
println(d["l2"][end])
```
"""
function series_leverage(data, index; leverage = 2, rate = 0, expense = 0, spread = 0, start = 100)
    index = _lev_check("series_leverage", data, index, rate, expense, spread)   # seit 1.6.4
    SL.nrow(data) == 0 && SL.chk_stop("zeilen_keine", "series_leverage", "data")   # seit 1.6.4 (Entscheidung 38; bis 1.6.3 R 100)
    leverage = SL.chk_num1(leverage, "series_leverage", "leverage")
    start = SL.chk_num1(start, "series_leverage", "start"; lo = 0, lo_open = true)
    rate, expense, spread = SL.chk_scalar(rate), SL.chk_scalar(expense), SL.chk_scalar(spread)
    idx = OF._tofloat(SL.Backcast._fill_na(OF._tofloat(_col(data, String(index))), "locf"))
    dts = Float64[OF._days(v) for v in OF._dates(_col(data, "date"), "data\$date")]
    dd = vcat(1.0, dts[2:end] .- dts[1:end-1])
    x = vcat(0.0, idx[2:end] ./ idx[1:end-1] .- 1)
    rt = OF._tofloat(PS._vec(SL.Backcast._resolve_series(rate, data, "rate")))
    L = Float64(leverage)
    m = max(L - 1, 0.0) + max(-L, 0.0)
    ex = Float64(expense); sp = Float64(spread)
    r = L .* x .+ (1 - L) .* rt ./ 100 .* dd ./ 360 .- ex / 100 .* dd ./ 365 .- sp / 100 * m .* dd ./ 360
    r[1] = 0.0
    ko = findfirst(<=(-1), r)
    ko === nothing || (r[ko:end] .= -1.0)
    v = Float64(start) .* OF._cumprod(1 .+ r)
    v[v .< 0] .= 0.0
    return v
end

"""
    sensitivity_leverage(data, index; leverages = 0.5:0.25:4, rate = 0, expense = 0, spread = 0,
                         strategy = nothing, sim_args = nothing, metrics = nothing, cores = "auto")

Kennzahlen über den Hebel.

Erzeugt für jeden Hebel eine Reihe mit `series_leverage()`, simuliert sie als Buy-and-Hold (oder mit einer
eigenen Strategie für das Asset `"LEV"`) und bestimmt den Hebel mit der höchsten CAGR bzw. Sharpe Ratio, wie
die LETF-Analyse von testfol.io. An `simulation()` wird ein Tabelle (RFrame) mit den Spalten `date` und `LEV`
übergeben, seit 1.6.5 dazu alle übrigen Spalten von `data` (Signal- und Ereignisspalten einer eigenen Strategie).

# Argumente
- `data`: Tabelle (RFrame) mit Spalte `date` und der Indexspalte.
  Seit 1.6.5 geprüft wie in `series_leverage`; eine Spalte `LEV` ist ein Fehler.
- `index`: Spaltenname des Index (Niveau, nicht Rendite; Lücken werden mit dem letzten Wert gefüllt).
- `leverages`: Numerischer Vektor der zu prüfenden Hebel (Standard `seq(0.5, 4, by = 0.25)`).
  Seit 1.6.4 endliche Zahlen.
- `rate`: Finanzierungszins in Prozent p. a. (Standard 0): Skalar, Spaltenname, Vektor der Länge `nrow(data)`,
  `data.frame(date, value)` oder benannter Vektor mit Datumsnamen.
- `expense`: TER in Prozent p. a. (Standard 0).
- `spread`: Spread auf den finanzierten bzw. leerverkauften Anteil m(L) in Prozent p. a. (Standard 0).
- `strategy`: Optional Strategie mit dem Asset `"LEV"`; `nothing` (Standard) = Buy-and-Hold-ETF mit 30 Prozent
  Teilfreistellung (`asset_config("etf", "bnh", partial_exemption = 30)`).
  Seit 1.6.5 muss eine eigene Strategie das Asset `"LEV"` enthalten (sonst Fehler).
- `sim_args`: Benannte Liste gemeinsamer Argumente für alle Läufe (Standard `()`): Argumente von
  `simulation()` außer `data` und `strategy`, also auch Bausteine (z. B. `dca = dca_plan(100, 1)`, `tax =
  tax_profile()`) und Pfade zu Parametern der Bausteine (`"dca.value"`, siehe `sensitivity_grid`). Alte
  Einzelargumente (bis 0.8.0, vor den Bausteinen, z. B. `dca_value`) ergeben einen Fehler, der den Baustein
  nennt.
- `metrics`: Funktion `SimLevResult -> benannter numerischer Vektor` (Standard `bootstrap_study_metrics()`).
  Seit 1.6.4 müssen die Namen der Kennzahlen eindeutig und nicht leer sein und dürfen keiner festen Spalte des
  Ergebnisses gleichen (sonst Fehler nach dem Rechnen).
- `cores`: Anzahl Läufe:
  `"auto"` (Standard seit 1.6.4; bis 1.6.3 1) oder eine ganze Zahl ≥ 1.
  Mit `"auto"` rechnet SimLev die ersten Einheiten nacheinander, misst ihre Rechenzeit und wählt dann
  die Zahl der Aufgaben (Tasks auf Threads statt Prozesse) und der Kern-Threads je Lauf selbst (Planer,
  gleiche Regel in R, Python und Julia): höchstens Zahl der freien Prozessoren (Prozessoren minus andere laufende
  Prozesse gleicher oder höherer Priorität) und der Julia-Threads, so viele, wie
  der freie Speicher trägt, und nur, wenn die Startkosten kleiner sind als der Gewinn (kleine Rechnungen
  bleiben bei einer Aufgabe; mit einem Thread, `julia` ohne `-t`, immer einer).
  Ausgaben, Meldungen, Warnungen und Fehler der Einheiten erscheinen dabei wie mit `cores = 1`, in
  Einheitenreihenfolge.
  Eine feste Zahl ist seit 1.6.5 der Höchstwert der automatischen Wahl: SimLev misst und plant wie mit
  `"auto"`, nimmt aber höchstens so viele Aufgaben (bis 1.6.4 immer so viele ohne Messung; höchstens Zahl der
  Julia-Threads, mit einem Thread nacheinander); höchstens Zahl der Prozessoren: mehr wird mit einem Hinweis begrenzt.
  Ausgaben, die eigene Funktionen
  (etwa `metrics`) direkt mit `println` oder `print` schreiben, erscheinen bei mehreren Aufgaben in der Reihenfolge,
  in der die Einheiten fertig werden; Warnungen (`@warn`) und SimLevs eigene Meldungen erscheinen in
  Einheitenreihenfolge (R und Python: alle Ausgaben in Einheitenreihenfolge). Das Ergebnis hängt nicht von cores ab.
  Je paralleler Einheit rechnen die Kerne mit höchstens Zahl der Prozessoren / Läufe Threads (mindestens 1).

# Rückgabe
Tabelle (RFrame) der Klasse `SimLevSensitivity` mit `leverage` und den Kennzahlen aus `metrics`
(fehlgeschlagene Läufe fehlen; seit 1.6.5 mit Warnung und Attribut `failed`, Tabelle mit `leverage` und
`error`; schlagen alle fehl, ein Fehler); Attribut `optimal` (benannter Vektor `cagr`, `sharpe`: Hebel mit
maximaler CAGR bzw. Sharpe Ratio; seit 1.6.4 NA ohne diese Kennzahl bzw. ohne Wert; seit 1.6.5 NA mit Hinweis,
wenn mehrere Hebel mit dem besten Wert gleichauf liegen, Abstand höchstens relativ 1e-12, z. B. die Sharpe Ratio
ohne Finanzierungskosten und ohne risikolosen Zins) und `kind = "leverage"`. Mit Sparplan (`sim_args`) ist `cagr` geldgewichtet (XIRR).
Ausgabe und Grafik über `print()` und `plot()`.

# Beispiel
```julia
using SimLev, Dates, Random
rng = MersenneTwister(1)
n = 1500
d = RFrame("date" => Date(2015, 1, 1) .+ Day.(0:n-1))
d["idx"] = 100 .* cumprod(1 .+ 3e-4 .+ 0.01 .* randn(rng, n))
lv = sensitivity_leverage(d, "idx"; leverages = [1, 1.5, 2, 3], rate = 2, expense = 0.5)
println(lv)
```
"""
SimLev.@study function sensitivity_leverage(data, index; leverages = nothing, rate = 0, expense = 0, spread = 0, strategy = nothing,
                              sim_args = nothing, metrics = nothing, cores = "auto")
    fn = "sensitivity_leverage"
    index = _lev_check(fn, data, index, rate, expense, spread)   # seit 1.6.4
    if leverages !== nothing
        lv = PS._vec(leverages)
        (!isempty(lv) && all(z -> z isa Real && !(z isa Bool) && isfinite(z), lv)) || SL.chk_stop("e2.zahlen_endlich", fn, "leverages")
    end
    if strategy !== nothing
        _sens_check_sim(data, strategy)
        # seit 1.6.5 (CR2-H-6): die Strategie muss das Asset LEV enthalten
        "LEV" in String[String(string(p.first)) for p in SL._strategy_pairs(strategy)] || SL.chk_stop("b2b.lev_asset", fn)
    end
    # seit 1.6.5 (CR2-H-6, Entscheidung 189): alle Spalten von data gehen mit an simulation(); Spalte LEV = Fehler
    "LEV" in names(data) && SL.chk_stop("b2b.lev_spalte", fn)
    cores = _sens_check_common(fn, sim_args, cores; metrics = metrics)
    sim_args = SL.Bootstrap._e2_sim_args(sim_args)
    rate, expense, spread = SL.chk_scalar(rate), SL.chk_scalar(expense), SL.chk_scalar(spread)
    leverages = leverages === nothing ? PS._seq_by(0.5, 4, 0.25) : OF._tofloat(PS._vec(leverages))
    sim_args = SL._sim_args_set(SL.RList(), sim_args, "sensitivity_leverage")
    metrics = _metrics(metrics)
    strategy === nothing && (strategy = SL.create_strategy("LEV" => SL.asset_config("etf", "bnh"; partial_exemption = 30)))
    dts = OF._dates(_col(data, "date"), "data\$date")
    extra = [k for k in names(data) if k != "date"]
    function run(L)
        lev = series_leverage(data, index; leverage = L, rate = rate, expense = expense, spread = spread)
        lev[lev .<= 0] .= 1e-8
        df = SL.RFrame("date" => dts, "LEV" => lev)
        for k in extra; df[k] = data[k]; end
        res = try
            _sim(df, strategy, sim_args)
        catch e
            e isa InterruptException && rethrow()
            return OF._cond_msg(e)
        end
        return PS._e2_pairs(metrics(res))
    end
    out = SL.RParallel.par_lapply(leverages, run, cores)
    ok = [!(o isa AbstractString) for o in out]
    # seit 1.6.5 (CR2-H-6): alle fehlgeschlagen = Fehler, einzelne = Warnung und Attribut failed (bis 1.6.4 still)
    _sens_failed(fn, Any[o for o in out if o isa AbstractString], length(out))
    good = out[ok]
    # seit 1.6.4 (Entscheidung 43, Regel 28): Namen der Kennzahlen eindeutig, nicht leer und nicht leverage
    for g in good
        SL.chk_kennzahlen(g[1], length(g[2]), ["leverage"], fn)
    end
    tab = SL.RFrame("leverage" => leverages[ok]; class = ["SimLevSensitivity", "data.frame"], nrow = count(ok))
    if !isempty(good)
        for (j, k) in enumerate(good[1][1])
            tab[k] = Float64[g[2][j] for g in good]
        end
    end
    SL.attrs(tab)["kind"] = "leverage"
    lv = tab["leverage"]
    # seit 1.6.4 (K43 T2-N3) immer cagr und sharpe, NA ohne Spalte bzw. ohne Wert (bis dahin fehlte cagr ohne Spalte
    # oder bei lauter NA, der Druck las dann den Sharpe-Hebel als CAGR); seit 1.6.5 (CR2-X15-1, Entscheidung 189) NA
    # mit Hinweis, wenn mehrere Hebel mit dem besten Wert gleichauf liegen (_near_eq)
    function best(k)
        haskey(tab, k) || return NA
        v = OF._tofloat(tab[k]); j = SimLev._which_max(v)
        j === nothing && return NA
        if _lev_tie(v, j)
            SL.DeepAnalysis._message(SL.chk_msg("b2b.lev_gleichauf", fn, k))
            return NA
        end
        return Float64(lv[j])
    end
    on = ["cagr", "sharpe"]
    ov = Float64[best("cagr"), best("sharpe")]
    SL.attrs(tab)["optimal"] = SL.RVector(ov; names = on)
    if !all(ok)
        SL.attrs(tab)["failed"] = SL.RFrame("leverage" => Float64[Float64(z) for z in leverages[.!ok]],
                                            "error" => String[o for o in out if o isa AbstractString])
    end
    return tab
end

"Mehrere Werte gleichauf mit dem besten `v[j]` (Regel `_near_eq`; NA zählt nicht)."
_lev_tie(v, j) = count(z -> !isnan(z) && _near_eq(z, v[j]), v) > 1

# ═════════════════════════════════════════════════════════════════════════════
# print / plot
# ═════════════════════════════════════════════════════════════════════════════

function _print_sens(io::IO, x)
    keep = [c for c in ("frequency", "offset", "band", "band_type", "leverage", "cagr", "ttwror", "max_drawdown",
                        "sharpe", "ulcer_index", "taxes", "trades") if haskey(x, c)]
    y = SL.RFrame((c => x[c] for c in keep)...; nrow = SL.nrow(x))
    if haskey(y, "cagr") && haskey(y, "ttwror") && SL.RLinalg.all_equal_numeric(OF._tofloat(y["cagr"]), OF._tofloat(y["ttwror"])) === true
        y = PS._select(y, [c for c in names(y) if c != "ttwror"])
    end
    bt = String[]
    if haskey(y, "band_type")
        btv = y["band_type"]
        sel = haskey(y, "band") ? [!OF._isna(b) for b in y["band"]] : trues(length(btv))
        bt = unique([v === missing ? "NA" : v for v in btv[sel]])
    end
    if haskey(y, "band_type") && length(bt) <= 1
        y = PS._select(y, [c for c in names(y) if c != "band_type"])
        length(bt) == 1 && print(io, "Toleranzbänder: ", bt[1] == "relative" ? "relativ (% des Zielgewichts)" : "absolut (Prozentpunkte)", "\n")
    end
    if haskey(y, "band")
        b = y["band"]
        fb = OF._formatv(b)
        y["band"] = String[OF._isna(b[i]) ? "-" : fb[i] for i in eachindex(b)]
    end
    for k in ("cagr", "ttwror", "max_drawdown"); haskey(y, k) && (y[k] = OF._spfv("%.2f %%", 100 .* OF._tofloat(y[k]))); end
    for k in ("sharpe", "ulcer_index"); haskey(y, k) && (y[k] = OF._spfv("%.3f", OF._tofloat(y[k]))); end
    for k in ("taxes", "trades"); haskey(y, k) && (y[k] = OF._spfv("%.1f", OF._tofloat(y[k]))); end
    print(io, OF._print_df(y), "\n")
    haskey(y, "cagr") && print(io, "cagr: mit Sparplan geldgewichtet (XIRR), sonst CAGR des Depotwerts\n")
    opt = get(SL.attrs(x), "optimal", nothing)
    if opt !== nothing
        ov = opt isa SL.RVector ? opt.values : opt isa AbstractVector ? opt : [opt]
        o(i) = i <= length(ov) ? OF._f64(ov[i]) : NA          # R: x[i] jenseits der Länge = NA
        print(io, OF._spf("Optimaler Hebel: CAGR %.2f, Sharpe %.2f\n", o(1), o(2)))
        # seit 1.6.5 (CR2-X15-1): Gleichstand benennen
        for k in ("cagr", "sharpe")
            haskey(x, k) || continue
            v = OF._tofloat(x[k]); j = SimLev._which_max(v)
            j !== nothing && _lev_tie(v, j) && print(io, SL.chk_msg("b2b.lev_gleichauf_druck", k), "\n")
        end
    end
    nothing
end

function _plot_sens(x; metric = "cagr", kw...)
    kind = get(SL.attrs(x), "kind", "grid")
    sc = metric in ("cagr", "ttwror", "max_drawdown", "avg_drawdown") ? 100 : 1
    y = sc .* OF._tofloat(x[metric])
    f = _res_fig(720, 460)
    if kind == "leverage"
        lv = OF._tofloat(x["leverage"])
        p = _res_panel(f, 70, 40, 620, 360, _res_range(lv), _res_range(y); title = "$metric nach Hebel", xlab = "Hebel", ylab = metric)
        _res_line!(f, p, lv, y); _res_points!(f, p, lv, y)
        j = SimLev._which_max(x[metric])
        j === nothing || _res_vline!(f, p, lv[j]; width = 1, dash = "2,3")
        data = SL.RList("leverage" => SL.RFrame("leverage" => lv, "value" => OF._tofloat(x[metric])))
    else
        n = length(y)
        lab = String[]
        for i in 1:n
            b = x["band"][i]; o = x["offset"][i]
            push!(lab, join([x["frequency"][i], OF._isna(b) ? "" : "±" * OF._as_chr(b), OF._isna(o) ? "" : "-" * OF._as_chr(o) * "d"], " "))
        end
        lo, hi = _res_range(vcat(0.0, y))
        p = _res_panel(f, 160, 40, 530, 380, (lo, hi), (0.5, n + 0.5); title = "Rebalancing-Varianten: $metric", xlab = metric,
                       yticks = collect(1.0:n), yticklabels = reverse(lab), grid = false)
        for (i, v) in enumerate(reverse(y))
            isfinite(v) && _res_rect!(f, p, 0.0, i - 0.35, v, i + 0.35)
        end
        data = SL.RList("variants" => SL.RFrame("label" => lab, "value" => OF._tofloat(x[metric])))
    end
    # Werte unskaliert wie im Ergebnis (Anteile, nicht ×100)
    return (_res_finish(f), data)
end

function __init__()
    SL.register_print!("SimLevSensitivity", _print_sens)
    SL.register_plot!("SimLevSensitivity", SL._plot_method(_plot_sens, "SimLevSensitivity"))
    SL.register_print!("SimLevLumpSum", _print_lumpsum)
end

end # module

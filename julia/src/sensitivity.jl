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
                     keep_results = false, cores = 1)

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
- `sim_args`: Benannte Liste gemeinsamer Argumente für alle Läufe (Standard `()`); Werte aus `grid` haben
  Vorrang. Argumente von `simulation()` außer `data` und `strategy`, also auch Bausteine (z. B. `dca =
  dca_plan(100, 1)`, `tax = tax_profile()`) und Pfade zu Parametern der Bausteine (`"dca.value"`, siehe
  `sensitivity_grid`). Alte Einzelargumente (bis 0.8.0, vor den Bausteinen, z. B. `dca_value`) ergeben einen
  Fehler, der den Baustein nennt.
- `metrics`: Funktion `SimLevResult -> benannter numerischer Vektor` (Standard `bootstrap_study_metrics()`).
- `keep_results`: Logisch (Standard `false`): Ergebnisse der Läufe zusätzlich als Attribut `results`
  zurückgeben.
- `cores`: Anzahl Prozesse (Standard 1; Fork auf Unix, PSOCK auf Windows).

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
SimLev.@study function sensitivity_grid(data, strategy, grid; sim_args = nothing, metrics = nothing, keep_results::Bool = false,
                          cores = 1)
    @nospecialize   # seit 1.6.3: ein Rumpf für alle Typen der Schlüsselwörter (Übersetzung je Aufrufform entfällt)
    data = SimLev.as_rframe(data)
    metrics = _metrics(metrics)
    design = _grid_frame(grid)
    SL.nrow(design) == 0 && error("Leeres Raster.")
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
        return (m = OF._metric_pairs(metrics(res)), err = missing, res = keep_results ? res : nothing)
    end
    out = SL.RParallel.par_lapply(1:SL.nrow(design), run, cores)
    okm = [o.m for o in out if o.m !== nothing]
    isempty(okm) && error("sensitivity_grid: Alle $(length(out)) Läufe fehlgeschlagen: $(_table_msg([o.err for o in out]))")
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
                            sim_args = nothing, metrics = nothing, cores = 1)

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
- `offsets`: Numerischer Vektor: Kalendertage vor dem Ende des Monats, Dreimonatsblocks bzw. Jahres, in dem
  der Termin liegt (0 = letzter Tag; `rebalance_plan(anchor = "end", days = offset + 1)`). `nothing`
  (Standard) rebalanciert am Periodenanfang.
- `bands`: Toleranzbänder in Prozent (5 = 5 Prozent); `NA` (Standard) = an jedem Termin rebalancieren. Mehrere
  Werte, auch gemischt mit `NA`, sind möglich.
- `band_type`: "absolute" (Standard; Prozentpunkte Abweichung vom Zielgewicht) oder "relative" (Prozent des
  Zielgewichts), siehe `thresh_type` von `rebalance_plan()`.
- `include_none`: Logisch (Standard `true`): zusätzlich einen Lauf ohne Rebalancing (Zeile `frequency =
  "none"`).
- `sim_args`: Benannte Liste gemeinsamer Argumente für alle Läufe (Standard `()`): Argumente von
  `simulation()` außer `data` und `strategy`, also auch Bausteine (z. B. `dca = dca_plan(100, 1)`, `tax =
  tax_profile()`) und Pfade zu Parametern der Bausteine (`"dca.value"`, siehe `sensitivity_grid`). Alte
  Einzelargumente (bis 0.8.0, vor den Bausteinen, z. B. `dca_value`) ergeben einen Fehler, der den Baustein
  nennt. Ein `rebalance = rebalance_plan(...)` in `sim_args` liefert die Grundwerte (z. B. `start`,
  `event_col`); Frequenz, Versatz und Band setzt die Funktion je Lauf über die Pfade `"rebalance.unit"`,
  `"rebalance.span"`, `"rebalance.anchor"`, `"rebalance.days"`, `"rebalance.thresh"` und
  `"rebalance.thresh_type"`; der Lauf ohne Rebalancing setzt `rebalance = nothing`.
- `metrics`: Funktion `SimLevResult -> benannter numerischer Vektor` (Standard `bootstrap_study_metrics()`).
- `cores`: Anzahl Prozesse (Standard 1; Fork auf Unix, PSOCK auf Windows).

# Rückgabe
Tabelle (RFrame) der Klasse `SimLevSensitivity` mit den Spalten `frequency`, `offset`, `band`, `band_type` und
den Kennzahlen aus `metrics`; fehlgeschlagene Läufe fehlen. Attribut `kind = "rebalancing"`. Ausgabe und
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
                                 band_type = nothing, include_none::Bool = true, sim_args = nothing, metrics = nothing,
                                 cores = 1)
    data = SimLev.as_rframe(data)
    band_type = OF._match_arg(band_type, ("absolute", "relative"))
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
        return OF._metric_pairs(metrics(res))
    end
    out = SL.RParallel.par_lapply(1:length(rows), run, cores)
    ok = [!(o isa AbstractString) for o in out]
    any(ok) || error("sensitivity_rebalancing: Alle $(length(out)) Läufe fehlgeschlagen: $(_table_msg(out))")
    good = out[ok]; lab = [r.label for r in rows[ok]]
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

_rep_get(rep, a, key) = (r = rep[a]; v = r isa AbstractDict || r isa SL.RList ? r[key] : getproperty(r, Symbol(key)); Float64[Float64(e) for e in v])

"""
    planning_lumpsum_vs_dca(data, strategy; amount = 10000, months = 12, horizon = 10, step = 1,
                   sim_args = nothing, cores = 1)

Einmalanlage gegen gestreckten Einstieg (Lump Sum vs. DCA).

Vergleicht für rollierende Starttermine (jeweils am Monatsersten) die sofortige Anlage eines Betrags mit einem
Einstieg in `months` gleichen Monatsraten. Verglichen wird das Vermögen nach `horizon` Jahren.

# Argumente
- `data`, `strategy`: Wie in `simulation()`: Tabelle (RFrame) mit Spalte `date` und Kursspalten (Niveaus) bzw.
  Strategie aus `create_strategy()`.
- `amount`: Anlagebetrag in Währungseinheiten (Standard 10000); bei DCA in `months` Raten von `amount /
  months` aufgeteilt.
- `months`: Anzahl Monatsraten des gestreckten Einstiegs (Standard 12).
- `horizon`: Vergleichshorizont in Jahren ab Start (Standard 10).
- `step`: Jeder wievielte mögliche Starttermin verwendet wird (Standard 1 = jeder Monat; 12 = jährlich).
- `sim_args`: Benannte Liste weiterer Argumente für `simulation()` (z. B. `tax = tax_profile()`): Argumente
  von `simulation()` außer `data` und `strategy`, also auch Bausteine (z. B. `dca = dca_plan(100, 1)`, `tax =
  tax_profile()`) und Pfade zu Parametern der Bausteine (`"dca.value"`, siehe `sensitivity_grid`). Alte
  Einzelargumente (bis 0.8.0, vor den Bausteinen, z. B. `dca_value`) ergeben einen Fehler, der den Baustein
  nennt. `start_value` und `dca` (auch Pfade `"dca.*"` und die alten `dca_*`) setzt die Funktion selbst (in
  `sim_args` ein Fehler).
- `cores`: Anzahl Prozesse (Standard 1; Fork auf Unix, PSOCK auf Windows).

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
                        cores = 1)
    data = SimLev.as_rframe(data)
    sim_args = SL.RList(SL._sim_kv(sim_args)...)
    own = [k for k in keys(sim_args) if k in ("start_value", "dca", "dca_mode", "dca_value", "dca_span", "dca_unit", "dca_skip") ||
           startswith(k, "dca.")]
    isempty(own) || error("planning_lumpsum_vs_dca setzt $(join(own, ", ")) selbst; aus sim_args entfernen (Betrag über amount, Raten über months).")
    sim_args = SL._sim_args_set(SL.RList(), sim_args, "planning_lumpsum_vs_dca")
    data = PS._as_frame(data)
    data["date"] = OF._dates(data["date"], "planning_lumpsum_vs_dca: data\$date")
    data = SL.rows(data, OF._order(Float64[OF._days(v) for v in data["date"]]))
    d = collect(Date, data["date"])
    dn = Float64[OF._days(v) for v in d]
    get(sim_args, "tax", nothing) !== nothing &&
        @warn "Mit Steuern ist die Fortschreibung des DCA-Depots nach der Einstiegsphase eine Näherung (Index der Einmalanlage)."
    firsts = d[Dates.day.(d) .== 1]
    last_ok = _seq_date_2nd(maximum(d), "-" * _num_str(horizon) * " years")
    starts = firsts[firsts .<= last_ok]
    sel = PS._seq_by(1, length(starts), step)
    starts = starts[Int.(sel)]
    isempty(starts) && error("Historie zu kurz für den Horizont.")
    hz = _num_str(horizon) * " years"; mo = _num_str(months) * " months"
    cache = Dict{String,Vector{Float64}}()
    wraps = SL._strategy_wrappers(strategy)   # Fonds-Wrapper: Asset-Name ist keine Kursspalte (_strategy_columns)
    function px(a, dates, navs = nothing)
        if a in wraps                          # Kurs = Anteilswert im Fenster der Einmalanlage (findInterval, mindestens 1)
            nd, nv = navs[a]
            return Float64[nv[max(searchsortedlast(nd, Float64(OF._days(t))), 1)] for t in dates]
        end
        haskey(cache, a) || (cache[a] = OF._tofloat(SL.Backcast._fill_na(OF._tofloat(data[a]), "locf")))
        return Float64[cache[a][searchsortedlast(dn, Float64(OF._days(t)))] for t in dates]
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
    win = adv .> 0
    SL.attrs(tab)["summary"] = SL.RVector([OF._mean_lgl(collect(win)), SL.r_mean(adv), OF._median(adv),
                                           any(win) ? SL.r_mean(adv[win]) : NA, any(.!win) ? SL.r_mean(adv[.!win]) : NA];
                                          names = ["win_rate", "mean_advantage", "median_advantage", "mlsa", "mlsd"])
    SL.attrs(tab)["settings"] = SL.RList("amount" => amount, "months" => months, "horizon" => horizon)
    return tab
end

function _print_lumpsum(io::IO, x)
    s = SL.attrs(x)["summary"]; st = SL.attrs(x)["settings"]
    amt = SL.RFmt.formatC(st["amount"]; format = "f", digits = 0, big_mark = " ")
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
- `index`: Spaltenname des Index (Niveau, nicht Rendite; Lücken werden mit dem letzten Wert gefüllt).
- `leverage`: Hebel L als Zahl (Standard 2; negativ für Short).
- `rate`: Finanzierungszins in Prozent p. a. (Standard 0): Skalar, Spaltenname, Vektor der Länge `nrow(data)`,
  `data.frame(date, value)` oder benannter Vektor mit Datumsnamen.
- `expense`: TER in Prozent p. a. (Standard 0).
- `spread`: Spread auf den finanzierten bzw. leerverkauften Anteil m(L) in Prozent p. a. (Standard 0).
- `start`: Startwert der Reihe in der ersten Zeile (Standard 100).

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
    data = SimLev.as_rframe(data)
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
                         strategy = nothing, sim_args = nothing, metrics = nothing, cores = 1)

Kennzahlen über den Hebel.

Erzeugt für jeden Hebel eine Reihe mit `series_leverage()`, simuliert sie als Buy-and-Hold (oder mit einer
eigenen Strategie für das Asset `"LEV"`) und bestimmt den Hebel mit der höchsten CAGR bzw. Sharpe Ratio, wie
die LETF-Analyse von testfol.io. An `simulation()` wird ein Tabelle (RFrame) mit den Spalten `date` und `LEV`
übergeben.

# Argumente
- `data`: Tabelle (RFrame) mit Spalte `date` und der Indexspalte.
- `index`: Spaltenname des Index (Niveau, nicht Rendite; Lücken werden mit dem letzten Wert gefüllt).
- `leverages`: Numerischer Vektor der zu prüfenden Hebel (Standard `seq(0.5, 4, by = 0.25)`).
- `rate`: Finanzierungszins in Prozent p. a. (Standard 0): Skalar, Spaltenname, Vektor der Länge `nrow(data)`,
  `data.frame(date, value)` oder benannter Vektor mit Datumsnamen.
- `expense`: TER in Prozent p. a. (Standard 0).
- `spread`: Spread auf den finanzierten bzw. leerverkauften Anteil m(L) in Prozent p. a. (Standard 0).
- `strategy`: Optional Strategie mit dem Asset `"LEV"`; `nothing` (Standard) = Buy-and-Hold-ETF mit 30 Prozent
  Teilfreistellung (`asset_config("etf", "bnh", partial_exemption = 30)`).
- `sim_args`: Benannte Liste gemeinsamer Argumente für alle Läufe (Standard `()`): Argumente von
  `simulation()` außer `data` und `strategy`, also auch Bausteine (z. B. `dca = dca_plan(100, 1)`, `tax =
  tax_profile()`) und Pfade zu Parametern der Bausteine (`"dca.value"`, siehe `sensitivity_grid`). Alte
  Einzelargumente (bis 0.8.0, vor den Bausteinen, z. B. `dca_value`) ergeben einen Fehler, der den Baustein
  nennt.
- `metrics`: Funktion `SimLevResult -> benannter numerischer Vektor` (Standard `bootstrap_study_metrics()`).
- `cores`: Anzahl Prozesse (Standard 1; Fork auf Unix, PSOCK auf Windows).

# Rückgabe
Tabelle (RFrame) der Klasse `SimLevSensitivity` mit `leverage` und den Kennzahlen aus `metrics`
(fehlgeschlagene Läufe fehlen); Attribut `optimal` (benannter Vektor `cagr`, `sharpe`: Hebel mit maximaler
CAGR bzw. Sharpe Ratio) und `kind = "leverage"`. Mit Sparplan (`sim_args`) ist `cagr` geldgewichtet (XIRR).
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
                              sim_args = nothing, metrics = nothing, cores = 1)
    data = SimLev.as_rframe(data)
    leverages = leverages === nothing ? PS._seq_by(0.5, 4, 0.25) : OF._tofloat(PS._vec(leverages))
    sim_args = SL._sim_args_set(SL.RList(), sim_args, "sensitivity_leverage")
    metrics = _metrics(metrics)
    strategy === nothing && (strategy = SL.create_strategy("LEV" => SL.asset_config("etf", "bnh"; partial_exemption = 30)))
    dts = OF._dates(_col(data, "date"), "data\$date")
    function run(L)
        lev = series_leverage(data, index; leverage = L, rate = rate, expense = expense, spread = spread)
        lev[lev .<= 0] .= 1e-8
        df = SL.RFrame("date" => dts, "LEV" => lev)
        res = try
            _sim(df, strategy, sim_args)
        catch e
            e isa InterruptException && rethrow()
            return nothing
        end
        return OF._metric_pairs(metrics(res))
    end
    out = SL.RParallel.par_lapply(leverages, run, cores)
    ok = [o !== nothing for o in out]
    good = out[ok]
    tab = SL.RFrame("leverage" => leverages[ok]; class = ["SimLevSensitivity", "data.frame"], nrow = count(ok))
    if !isempty(good)
        for (j, k) in enumerate(good[1][1])
            tab[k] = Float64[g[2][j] for g in good]
        end
    end
    SL.attrs(tab)["kind"] = "leverage"
    lv = tab["leverage"]
    jc = haskey(tab, "cagr") ? SimLev._which_max(tab["cagr"]) : nothing
    js = haskey(tab, "sharpe") ? SimLev._which_max(tab["sharpe"]) : nothing
    # R: c(cagr = lev[which.max(cagr)], sharpe = ...): ein leeres which.max lässt das Element weg
    on = String[]; ov = Float64[]
    jc === nothing || (push!(on, "cagr"); push!(ov, lv[jc]))
    if haskey(tab, "sharpe")
        js === nothing || (push!(on, "sharpe"); push!(ov, lv[js]))
    else
        push!(on, "sharpe"); push!(ov, NA)
    end
    SL.attrs(tab)["optimal"] = SL.RVector(ov; names = on)
    return tab
end

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

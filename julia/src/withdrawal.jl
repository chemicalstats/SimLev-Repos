# Withdrawal – Gegenstück zu r/R/withdrawal.R und python/simlev/withdrawal.py
#
# Entnahme-Simulationen (Ruhestand / Decumulation):
#   withdrawal_rule        Regel-Objekt (14 Regeln)
#   withdrawal_cohorts     historische rollierende Kohorten (Bengen/Trinity)
#   withdrawal_paths       Periodenrenditen aus Bootstrap-Pfaden, Ergebnislisten oder Studien
#   result_index           zeitgewichteter Wertindex eines Simulationsergebnisses
#   withdrawal_simulation  schneller Kern über viele Pfade, optional mit Steuern
#   withdrawal_perfect_rate, withdrawal_max_rate, withdrawal_horizon
#
# PROZENT-KONVENTION: rate, ceiling, floor, cut, raise, exp_return usw. in
# Prozent (rate = 4 bedeutet 4 % p. a.), wie im restlichen Paket.
module Withdrawal

import ..SimLev
using Dates
using Printf

export withdrawal_rule, withdrawal_cohorts, result_index, withdrawal_paths, withdrawal_perfect_rate,
       withdrawal_simulation, withdrawal_max_rate, withdrawal_horizon

const RList = SimLev.RList
const RFrame = SimLev.RFrame
const RVector = SimLev.RVector
const NamedMat = SimLev.NamedMat
const NA = SimLev.NA

# Gemeinsame Hilfen aus Bootstrap
const B = SimLev.Bootstrap
const _MISSING = B._MISSING
const _Missing = B._Missing
import ..Bootstrap: _stop, _warn, _message, _sp, _keep_count, _fmt1, _fmtstrs, _show, _as_char, _round0, _isnum, _numvec, _num1, _f1,
                    _dvec, _ivec, _mat, _get, _names, _values, _len, _rval, _rsum, _rmean, _rprod, _rpow, _rlog, _rexp,
                    _cumprod, _cummax, _median, _quantile7, _weighted_mean, _wquantile, _uniq,
                    _match_arg, _todate, _seq_dates, _days, _is_boot_result, _is_study, _is_result, _deparse,
                    _quiet, _no_messages, _aux_type_of, _cfg_list, _as_numeric_col, _pmax, _pmin, _istrue

const _WD_RULES = ["constant" => 1, "percent" => 2, "vanguard" => 3, "guyton_klinger" => 4, "floor_ceiling" => 5,
                   "clyatt" => 6, "ratchet" => 7, "endowment" => 8, "one_over_n" => 9, "vpw" => 10, "abw" => 11,
                   "cape" => 12, "sensible" => 13, "hebeler" => 14]
const _WD_RULE_NAMES = Tuple(first.(_WD_RULES))
_rule_code(t) = last(_WD_RULES[findfirst(p -> p.first == t, _WD_RULES)])

const _WD_LABELS = Dict(
    "constant" => "Konstante reale Entnahme (Bengen/Trinity)",
    "percent" => "Fester Prozentsatz des Depots",
    "vanguard" => "Vanguard Dynamic Spending (Ceiling/Floor)",
    "guyton_klinger" => "Guyton-Klinger-Entscheidungsregeln",
    "floor_ceiling" => "Floor-and-Ceiling (Bengen 2001)",
    "clyatt" => "Clyatt 95-%-Regel",
    "ratchet" => "Kitces-Ratchet",
    "endowment" => "Endowment-/Yale-Regel (Tobin)",
    "one_over_n" => "1/N (Restlaufzeit)",
    "vpw" => "Variable Percentage Withdrawal (Bogleheads)",
    "abw" => "Amortisationsbasierte Entnahme (ABW)",
    "cape" => "CAPE-basierte Regel",
    "sensible" => "Sensible Withdrawals",
    "hebeler" => "Hebeler Autopilot II")

_wcore() = SimLev.WithdrawalCore

"R-`show()` (NULL → \"NULL\", TRUE/FALSE, sonst `paste(format(x), collapse = \", \")`)."
function _rshow(x)
    x === nothing && return "NULL"
    x isa Bool && return x ? "TRUE" : "FALSE"
    x === missing && return "NA"
    return _show(x)
end
_wshow(x) = x === nothing ? "" : _rshow(x)
"`format()` eines Rechenergebnisses."
_fmt_nan(x; kw...) = _fmt1(Float64(x); kw...)

_is_rule(x) = x isa RList && SimLev.inherits(x, "withdrawal_rule")
_is_wp(x) = x isa RList && SimLev.inherits(x, "withdrawal_paths")
_is_horizon(x) = x isa RList && SimLev.inherits(x, "SimLevHorizon")

"R-Zahlwert eines Arguments (Int → Float64)."
_num(x) = x isa Bool ? x : x isa Integer ? Float64(x) : x

# ═══════════════════════════════════════════════════════════════════════════
# Regeln
# ═══════════════════════════════════════════════════════════════════════════

"""
    withdrawal_rule(type = "constant"; rate = 4, ceiling = nothing, floor = nothing, cut = 10, raise = 10,
                    cpr_years = 15, inflation_cap = Inf, skip_inflation = true, smoothing = nothing,
                    exp_return = nothing, stock_share = 60, age = 65, max_age = 100, fv = 0, cape_a = 1.75,
                    cape_b = 0.5, ratchet_threshold = 1.5, ratchet_gap = 3, extra = 10, floor95 = 95,
                    min_real = 0, max_real = Inf, max_rate = 100)

Entnahmeregel definieren.

Erzeugt eine validierte Entnahmeregel für `withdrawal_simulation()` und `withdrawal_max_rate()`. Die
Jahresentnahme wird zu Beginn jedes Planjahres festgelegt (Guyton & Klinger 2006; Suarez et al. 2015) und bei
unterjährigen Perioden gleichmäßig ausgezahlt (Jahresbetrag / Perioden je Jahr). Alle Beträge sind
Netto-Konsum; Steuern werden zusätzlich aus dem Depot verkauft. Alle Raten und Schranken werden in Prozent
angegeben (`rate = 4` bedeutet 4 % des Depots); welche Argumente eine Regel nutzt, zeigt die Tabelle unter
Details. Jedes Argument muss eine einzelne Zahl ohne `NA` im zulässigen Bereich sein (Prozentsätze wie
`floor`, `cut`, `smoothing`, `floor95`, `extra`, `max_rate` 0 bis 100, `ceiling`, `raise`, `inflation_cap` >=
0, `min_real <= max_real`, bei `vpw` `age < max_age` und `max_rate > 0`); sonst bricht die Funktion mit einer
Meldung ab. Schranken zwischen 0 und 0,2 lösen eine Warnung aus (vermutlich Anteil statt Prozent).

# Argumente
- `type`: Regel (Zeichenkette, Standard `"constant"`):

  - "constant": Bengen (1994) / Trinity-Studie: W_1 = rate · P_1, danach W_t-1(1+π) (real konstant).
  - "percent": Fester Prozentsatz des aktuellen Depots: rate · P.
  - "vanguard": Vanguard Dynamic Spending: rate · P, die Veränderung gegenüber W_t-1(1+π) (also real) begrenzt
    auf +`ceiling` Prozent / -`floor` Prozent (Standard 5 / 2,5).
  - "guyton_klinger": Guyton & Klinger (2006): Erstentnahme rate · P_1, Anfangsrate WR_0 = W_1 / P_1. Danach
    W_t-1 mit Inflationsausgleich (höchstens `inflation_cap` Prozent). Withdrawal-Rule (`skip_inflation`):
    kein Inflationsausgleich, wenn die nominale Depotrendite des Vorjahres negativ war und die inflationierte
    Entnahme eine Rate über WR_0 ergäbe. Capital-Preservation-Rule: Kürzung um `cut` Prozent, wenn die
    aktuelle Rate W / P über WR_0 (1 + ceiling/100) liegt und noch mehr als `cpr_years` Restjahre bleiben.
    Prosperity-Rule: sonst Erhöhung um `raise` Prozent, wenn die Rate unter WR_0 (1 - floor/100) liegt.
    Standard 20 / 20 / 10 / 10, 15 Jahre.
  - "floor_ceiling": Bengen (2001): rate · P, begrenzt auf das (1 - `floor`/100)- bis (1 +
    `ceiling`/100)-fache der realen Erstentnahme in heutigen Preisen (Standard 15 / 20).
  - "clyatt": Clyatt: max(rate · P, floor95/100 · W_t-1), nominal (ohne Inflationsausgleich).
  - "ratchet": Kitces: real konstant wie `"constant"`; Erhöhung um `raise` Prozent (10), wenn das reale Depot
    das `ratchet_threshold`-fache (1,5) des realen Startdepots übersteigt, höchstens alle `ratchet_gap` (3)
    Jahre (frühestens im Jahr 1 + `ratchet_gap`).
  - "endowment": Yale/Tobin: λ W_t-1(1+π) + (1-λ) rate · P mit λ = `smoothing`/100 (Standard 70).
  - "one_over_n": P / Restjahre; leert das Depot planmäßig bis zum Ende der Simulation.
  - "vpw": Bogleheads VPW: P · PMT(r, n) mit n = `max_age` - Alter im Planjahr (`age` im ersten Jahr) und r =
    `exp_return`/100, höchstens `max_rate` Prozent des Depots; bei n ≤ 1 das ganze Depot.
  - "abw": Amortisation: reale vorschüssige Annuität (P_real - fv / (1+r)^n) · PMT(r, n) über n = Restjahre
    mit r = `exp_return`/100 und Zielvermögen `fv`; nicht negativ.
  - "cape": (cape_a/100 + cape_b / CAPE) · P mit dem CAPE zu Beginn des Planjahres (CAPE <= 0: nur `cape_a`).
    Standard `cape_a` = 1,75, `cape_b` = 0,5 (ERN); CAPE-Reihe nötig (Argument `cape` in
    `withdrawal_cohorts()` bzw. `withdrawal_paths()`).
  - "sensible": Erstes Jahr rate · P_1; danach diese Erstentnahme real (inflationiert) plus `extra` Prozent
    (10) des realen Depotzuwachses seit der Vorjahresentnahme (nur Zuwächse).
  - "hebeler": Autopilot II: λ W_t-1(1+π) + (1-λ) PMT(r, n) · P mit λ = `smoothing`/100 (Standard 75), r =
    `exp_return`/100, n = Restjahre; im ersten Jahr nur die Annuität.
- `rate`: Entnahmerate in Prozent (4 = 4 % des Depots; Standard 4; zulässig 0 bis 100): Anfangsrate
  (`constant`, `guyton_klinger`, `ratchet`, `sensible`) bzw. laufende Rate auf das aktuelle Depot (`percent`,
  `vanguard`, `floor_ceiling`, `clyatt`, `endowment`). Von `one_over_n`, `vpw`, `abw`, `cape` und `hebeler`
  nicht genutzt. Werte zwischen 0 und 0,2 lösen bei `constant`, `percent`, `vanguard` und `guyton_klinger`
  eine Warnung aus (vermutlich Anteil statt Prozent).
- `ceiling`, `floor`: Obere bzw. untere Schranke in Prozent (>= 0), Bedeutung je Regel: `vanguard` = maximale
  reale Erhöhung / Senkung gegenüber dem Vorjahr (Standard 5 / 2,5); `guyton_klinger` = Abstand der
  Leitplanken von der Anfangsrate (20 / 20); `floor_ceiling` = Korridor um die reale Erstentnahme (20 / 15).
  `nothing` = diese Regel-Standards; andere Regeln ignorieren die Werte (gespeichert als 0).
- `cut`, `raise`: Kürzung bzw. Erhöhung der Entnahme in Prozent (>= 0, Standard 10 / 10): `cut` für
  `guyton_klinger`, `raise` für `guyton_klinger` und `ratchet`.
- `cpr_years`: Guyton-Klinger: Anzahl Jahre (Standard 15). Die Capital-Preservation-Rule greift nur, solange
  mehr als `cpr_years` Restjahre (einschließlich des aktuellen) bleiben.
- `inflation_cap`: Guyton-Klinger: maximaler Inflationsausgleich je Jahr in Prozent (Standard `Inf` =
  unbegrenzt, wie in der Fassung von 2006).
- `skip_inflation`: Logisch, Guyton-Klinger: Withdrawal-Rule aktiv (Standard `true`; siehe `type`).
- `smoothing`: Glättungsgewicht der Vorjahresentnahme in Prozent (0 bis 100) für `endowment` und `hebeler`.
  `nothing` = 75 bei `hebeler`, sonst 70.
- `exp_return`: Erwartete reale Rendite in Prozent p. a. für `vpw`, `abw` und `hebeler`. `nothing` = 5 x
  `stock_share`/100 + 1,9 x (1 - `stock_share`/100), beim Standard `stock_share = 60` also 3,76.
- `stock_share`: Aktienquote in Prozent (60 = 60 %, Standard 60); nur für den Standardwert von `exp_return`
  verwendet.
- `age`, `max_age`: Alter bei Rentenbeginn und Planungsalter in Jahren (Standard 65 / 100), nur `vpw`.
- `fv`: `abw`: reales Zielvermögen am Ende als Geldbetrag in Kaufkraft des Startzeitpunkts (Standard 0 = Depot
  aufbrauchen).
- `cape_a`, `cape_b`: CAPE-Regel: Konstante in Prozent (Standard 1.75 = 1,75 %) und Faktor auf 1 / CAPE als
  Anteil (Standard 0.5; bei CAPE 25 also 0.5 / 25 = 0.02 = 2 %).
- `ratchet_threshold`: `ratchet`: Faktor auf das reale Startdepot (Standard 1.5 = 150 %), ab dem erhöht wird.
- `ratchet_gap`: `ratchet`: Mindestabstand zwischen Erhöhungen in Jahren (Standard 3).
- `extra`: `sensible`: Anteil des realen Depotzuwachses in Prozent (Standard 10).
- `floor95`: `clyatt`: Mindestanteil der Vorjahresentnahme in Prozent (Standard 95).
- `min_real`, `max_real`: Absolute Unter- bzw. Obergrenze der Jahresentnahme als Geldbetrag in Kaufkraft des
  Startzeitpunkts, für alle Regeln (Standard 0 und `Inf` = keine Grenze).
- `max_rate`: `vpw`: Höchstsatz in Prozent des Depots (Standard 100).

# Rückgabe
Objekt der Klasse `withdrawal_rule` (Liste) mit `type` und allen Parametern in Prozent-Konvention, wobei
`ceiling`, `floor`, `smoothing` und `exp_return` bereits mit den Standardwerten gefüllt sind (`stock_share`
wird nicht gespeichert). Ausgabe mit `print()`.

# Details
Bezeichnungen: P = nominaler Depotwert zu Beginn des Planjahres vor der Entnahme, P_1 = Startdepot, W_t-1 =
nominale Entnahme des Vorjahres, π = Inflation des Vorjahres, Restjahre = verbleibende Planjahre der
Simulation einschließlich des aktuellen Jahres, PMT(r, n) = vorschüssige Annuität je Geldeinheit Kapital (r /
((1 - (1+r)^-n)(1+r)), bei n ≤ 1 gleich 1). Nach jeder Regel werden `min_real` und `max_real` angewendet.

Genutzte Argumente je Regel (Standardwerte von `ceiling`, `floor` und `smoothing` in Klammern; `min_real` und
`max_real` gelten für alle Regeln):
- Regel | genutzte Argumente
- `constant` | `rate`
- `percent` | `rate`
- `vanguard` | `rate`, `ceiling` (5), `floor` (2.5)
- `guyton_klinger` | `rate`, `ceiling` (20), `floor` (20), `cut`, `raise`, `cpr_years`, `inflation_cap`,
  `skip_inflation`
- `floor_ceiling` | `rate`, `ceiling` (20), `floor` (15)
- `clyatt` | `rate`, `floor95`
- `ratchet` | `rate`, `raise`, `ratchet_threshold`, `ratchet_gap`
- `endowment` | `rate`, `smoothing` (70)
- `one_over_n` | keine (nur Restjahre)
- `vpw` | `exp_return` bzw. `stock_share`, `age`, `max_age`, `max_rate`
- `abw` | `exp_return` bzw. `stock_share`, `fv` (Restjahre)
- `cape` | `cape_a`, `cape_b`; CAPE-Reihe in den Pfaden nötig
- `sensible` | `rate`, `extra`
- `hebeler` | `exp_return` bzw. `stock_share`, `smoothing` (75) (Restjahre)

Die Restjahre (`one_over_n`, `abw`, `hebeler` und die Capital-Preservation-Rule von `guyton_klinger`) sind
kein Argument der Regel: Sie ergeben sich in `withdrawal_simulation()` aus der Zahl der Planjahre (Pfadlänge
bzw. `years`). Eine zufällige Laufzeit je Pfad (`horizon` in `withdrawal_simulation()`, Objekt aus
`withdrawal_horizon()`) ändert nur die Auswertung (Erfolg, Konsum und Endvermögen bis zum Horizont); die Regel
rechnet weiter mit den Restjahren der vollen Pfadlänge.

# Quellen und Abweichungen
- `clyatt`: Nach Clyatt (2005): jedes Jahr `rate` des aktuellen Depots, mindestens `floor95` Prozent der
  Vorjahresentnahme, nominal; Kürzungen in Folgejahren verketten sich (95 % von 95 %). Keine Abweichung.
- `endowment`: Angelehnt an die Yale-Regel (Swensen 2009, Kap. 3, mit Verweis auf Tobin 1974): Gewicht mal
  Vorjahresentnahme plus (1 - Gewicht) mal Zielrate mal Vermögen; Yale früher 70 %, heute 80 %. Abweichend:
  Yale wendet die Zielrate auf den Wert zum Ende des vorigen Geschäftsjahres an und schreibt die Summe beider
  Teile mit der Inflation fort; SimLev nimmt das Depot zu Beginn des Planjahres und inflationiert nur die
  Vorjahresentnahme.
- `one_over_n`: Nach Bogleheads Wiki, Withdrawal methods (1/N): Depot geteilt durch die Restjahre. Abweichend:
  das Wiki empfiehlt 1/N eher als Höchstbetrag; SimLev entnimmt genau 1/N.
- `abw`: Angelehnt an die jährlich neu berechnete virtuelle Annuität (ARVA) von Waring & Siegel (2015): Rate
  einer vorschüssigen Annuität mit dem aktuellen Depot über die Restjahre. Abweichend: feste erwartete
  Realrendite `exp_return` statt der aktuellen Marktzinsen; reales Zielvermögen `fv` als eigene Ergänzung.
- `cape`: Nach Jeske (2017): Rate = a + b / CAPE auf das aktuelle Depot; 1,75 % und 0,5 sind eine der dort
  gerechneten Varianten. Abweichend: dort monatlich mit den Werten vom Ende des Vormonats, in SimLev jährlich
  mit dem CAPE zu Beginn des Planjahres; CAPE <= 0 ergibt nur a (eigene Festlegung).
- `sensible`: Angelehnt an Ponzo (o. J.), Sensible Withdrawals: Grundentnahme plus ein Anteil (dort Beispiele
  10 und 25 %) des Zuwachses, wenn das Depot nach der Grundentnahme stärker als die Inflation gewachsen ist.
  Abweichend bzw. dort offen: SimLev setzt die Grundentnahme als inflationierte Erstentnahme rate · P_1, misst
  den Zuwachs als reales Depot vor der Entnahme minus reales Depot nach der Vorjahresentnahme und begrenzt den
  Zusatz nicht.
- `hebeler`: Angelehnt an Hebelers Retirement Autopilot (Hebeler 2001); Gewichtung 75 % inflationierte
  Vorjahresentnahme plus 25 % Annuität nach Steiner (2015). Abweichend: Hebeler rechnet die Annuität über die
  Lebenserwartung (IRS-Tabellen) mit einem niedrigen Realzins, SimLev über die Restjahre der Simulation mit
  `exp_return`.

# Literatur
Bengen (1994, 2001); Cooley, Hubbard & Walz (1998); Guyton & Klinger (2006), Journal of Financial Planning
19(3); Vanguard (2021), Sustainable spending rates in turbulent markets; Bogleheads Wiki, Variable percentage
withdrawal; Kitces (2015); Suarez, Suarez & Walz (2015), Financial Services Review 24; Clyatt, B. (2005), Work
Less, Live More: The New Way to Retire Early, Nolo, Berkeley; Swensen, D. F. (2009), Pioneering Portfolio
Management, Fully Revised and Updated, Free Press, Kap. 3; Tobin, J. (1974), What is permanent endowment
income?, American Economic Review 64(2), 427-432; Bogleheads Wiki, Withdrawal methods,
https://www.bogleheads.org/wiki/Withdrawal_methods; Waring, M. B. & Siegel, L. B. (2015), The only spending
rule article you will ever need, Financial Analysts Journal 71(1), 91-107, doi:10.2469/faj.v71.n1.2; Jeske, K.
(2017), The ultimate guide to safe withdrawal rates - Part 18: Flexibility and the mechanics of CAPE-based
rules, earlyretirementnow.com, 30.08.2017; Ponzo, P. (o. J.), Sensible withdrawals, gummy-stuff,
https://www.financialwisdomforum.org/gummy-stuff/sensible_withdrawals.htm; Hebeler, H. K. (2001), J.K.
Lasser's Your Winning Retirement Plan, Wiley; Steiner, K. (2015), Bud Hebeler's Autopilot withdrawal rule,
Blog How much can I afford to spend in retirement?, 22.01.2015.

# Beispiel
```julia
using SimLev
println(withdrawal_rule("vanguard"; rate = 5, ceiling = 5, floor = 2.5))
```
"""
function withdrawal_rule(type_pos = nothing; type = type_pos, type_ = type, rate = 4, ceiling = nothing, floor = nothing, cut = 10, raise = 10,
                         cpr_years = 15, inflation_cap = Inf, skip_inflation = true, smoothing = nothing,
                         exp_return = nothing, stock_share = 60, age = 65, max_age = 100, fv = 0, cape_a = 1.75,
                         cape_b = 0.5, ratchet_threshold = 1.5, ratchet_gap = 3, extra = 10, floor95 = 95,
                         min_real = 0, max_real = Inf, max_rate = 100, kwargs...)
    if !isempty(kwargs)
        k, v = first(kwargs)
        _stop(string("unused argument (", k, " = ", _deparse(v), ")"))
    end
    t = _match_arg(type_, _WD_RULE_NAMES)
    function chk(x, arg; lo = -Inf, hi = Inf, what = "", inf_ok = false, null_ok = false)
        x === nothing && null_ok && return
        v = _numvec(x)
        if v === nothing || length(v) != 1 || isnan(v[1]) || (!inf_ok && !isfinite(v[1])) || v[1] < lo || v[1] > hi
            _stop(@sprintf("withdrawal_rule: %s muss %s sein (erhalten: %s).", arg, what, _rshow(x)))
        end
    end
    v = _numvec(rate)
    if v === nothing || length(v) != 1 || !isfinite(v[1]) || v[1] < 0 || v[1] > 100
        _stop(@sprintf("rate muss zwischen 0 und 100 Prozent liegen (z. B. 4; erhalten: %s).", _rshow(rate)))
    end
    0 < rate < 0.2 && t in ("constant", "percent", "vanguard", "guyton_klinger") &&
        _warn("rate wirkt wie eine Dezimalzahl. PROZENT-KONVENTION: 4 bedeutet 4 %.")
    chk(ceiling, "ceiling"; lo = 0, what = "NULL oder eine Zahl >= 0 in Prozent (z. B. 20)", null_ok = true)
    chk(floor, "floor"; lo = 0, hi = 100, what = "NULL oder eine Zahl von 0 bis 100 in Prozent (z. B. 20)", null_ok = true)
    chk(cut, "cut"; lo = 0, hi = 100, what = "eine Zahl von 0 bis 100 in Prozent (z. B. 10)")
    chk(raise, "raise"; lo = 0, what = "eine Zahl >= 0 in Prozent (z. B. 10)")
    chk(cpr_years, "cpr_years"; lo = 0, what = "eine Zahl von Jahren >= 0 (z. B. 15)")
    chk(inflation_cap, "inflation_cap"; lo = 0, what = "eine Zahl >= 0 in Prozent oder Inf (unbegrenzt)", inf_ok = true)
    if !(skip_inflation isa Bool)
        _stop(@sprintf("withdrawal_rule: skip_inflation muss TRUE oder FALSE sein (erhalten: %s).", _rshow(skip_inflation)))
    end
    chk(smoothing, "smoothing"; lo = 0, hi = 100, what = "NULL oder eine Zahl von 0 bis 100 in Prozent (z. B. 70)", null_ok = true)
    chk(exp_return, "exp_return"; lo = -99.99, what = "NULL oder eine Zahl in Prozent p. a. über -100 (z. B. 3.5)", null_ok = true)
    chk(stock_share, "stock_share"; lo = 0, hi = 100, what = "eine Zahl von 0 bis 100 in Prozent (z. B. 60)")
    chk(age, "age"; lo = 0, what = "ein Alter in Jahren >= 0 (z. B. 65)")
    chk(max_age, "max_age"; lo = 0, what = "ein Alter in Jahren >= 0 (z. B. 100)")
    if t == "vpw" && age >= max_age
        _stop(@sprintf("withdrawal_rule('vpw'): age (%s) muss kleiner als max_age (%s) sein.", _fmt1(_num(age)), _fmt1(_num(max_age))))
    end
    chk(fv, "fv"; lo = 0, what = "ein Geldbetrag >= 0 (reales Zielvermögen)")
    chk(cape_a, "cape_a"; lo = 0, hi = 100, what = "eine Zahl von 0 bis 100 in Prozent (z. B. 1.75)")
    chk(cape_b, "cape_b"; lo = 0, what = "eine Zahl >= 0 (Faktor auf 1 / CAPE, z. B. 0.5)")
    chk(ratchet_threshold, "ratchet_threshold"; lo = 0, what = "ein Faktor > 0 (z. B. 1.5 = 150 %)")
    chk(ratchet_gap, "ratchet_gap"; lo = 0, what = "eine Zahl von Jahren >= 0 (z. B. 3)")
    chk(extra, "extra"; lo = 0, hi = 100, what = "eine Zahl von 0 bis 100 in Prozent (z. B. 10)")
    chk(floor95, "floor95"; lo = 0, hi = 100, what = "eine Zahl von 0 bis 100 in Prozent (z. B. 95)")
    chk(min_real, "min_real"; lo = 0, what = "ein Geldbetrag >= 0")
    chk(max_real, "max_real"; lo = 0, what = "ein Geldbetrag >= 0 oder Inf", inf_ok = true)
    if min_real > max_real
        _stop(@sprintf("withdrawal_rule: min_real (%s) darf nicht größer als max_real (%s) sein.", _fmt1(_num(min_real)), _fmt1(_num(max_real))))
    end
    chk(max_rate, "max_rate"; lo = 0, hi = 100, what = "eine Zahl von 0 bis 100 in Prozent (z. B. 100)")
    if t == "vpw" && max_rate == 0
        _stop("withdrawal_rule('vpw'): max_rate = 0 erlaubt keine Entnahme; Höchstsatz in Prozent > 0 angeben (z. B. 100).")
    end
    frac = Pair{String,Float64}["ceiling" => ceiling === nothing ? NaN : Float64(ceiling),
                                "floor" => floor === nothing ? NaN : Float64(floor), "cut" => Float64(cut),
                                "raise" => Float64(raise), "smoothing" => smoothing === nothing ? NaN : Float64(smoothing),
                                "inflation_cap" => Float64(inflation_cap), "extra" => Float64(extra),
                                "floor95" => Float64(floor95), "max_rate" => Float64(max_rate)]
    frac = [p for p in frac if !isnan(p.second) && 0 < p.second < 0.2]
    if !isempty(frac)
        a = _fmtstrs(Float64[p.second for p in frac])
        b = _fmtstrs(Float64[100 * p.second for p in frac])
        _warn(@sprintf("withdrawal_rule: %s wirkt wie ein Anteil; PROZENT-KONVENTION: 5 bedeutet 5 %% (gemeint vermutlich %s).",
                       join([string(p.first, " = ", s) for (p, s) in zip(frac, a)], ", "),
                       join([string(p.first, " = ", s) for (p, s) in zip(frac, b)], ", ")))
    end
    dflt = t == "vanguard" ? (5.0, 2.5) : t == "guyton_klinger" ? (20.0, 20.0) : t == "floor_ceiling" ? (20.0, 15.0) : (0.0, 0.0)
    ceiling = ceiling === nothing ? dflt[1] : ceiling
    floor = floor === nothing ? dflt[2] : floor
    smoothing = smoothing === nothing ? (t == "hebeler" ? 75.0 : 70.0) : smoothing
    exp_return = exp_return === nothing ? (5.0 * stock_share / 100 + 1.9 * (1 - stock_share / 100)) : exp_return
    return RList("type" => t, "rate" => _num(rate), "ceiling" => _num(ceiling), "floor" => _num(floor), "cut" => _num(cut),
                 "raise" => _num(raise), "cpr_years" => _num(cpr_years), "inflation_cap" => _num(inflation_cap),
                 "skip_inflation" => skip_inflation, "smoothing" => _num(smoothing), "exp_return" => _num(exp_return),
                 "age" => _num(age), "max_age" => _num(max_age), "fv" => _num(fv), "cape_a" => _num(cape_a),
                 "cape_b" => _num(cape_b), "ratchet_threshold" => _num(ratchet_threshold), "ratchet_gap" => _num(ratchet_gap),
                 "extra" => _num(extra), "floor95" => _num(floor95), "min_real" => _num(min_real),
                 "max_real" => _num(max_real), "max_rate" => _num(max_rate); class = ["withdrawal_rule", "list"])
end

_as_integer(x) = Int(trunc(Float64(x)))

function _print_rule(io::IO, x)
    print(io, "Entnahmeregel\n-------------\n")
    t = x["type"]
    print(io, _sp("  Typ:       %s (%s)\n", t, _WD_LABELS[t]))
    t in ("one_over_n", "vpw", "abw", "cape", "hebeler") || print(io, _sp("  Rate:      %.2f %%\n", x["rate"]))
    ex = if t == "vanguard"
        _sp("  Ceiling/Floor (real): +%.2f %% / -%.2f %%\n", x["ceiling"], x["floor"])
    elseif t == "guyton_klinger"
        _sp("  Guardrails: +%.0f %% / -%.0f %%, Kürzung %.0f %%, Erhöhung %.0f %%, CPR bis %d J. vor Ende\n",
            x["ceiling"], x["floor"], x["cut"], x["raise"], _as_integer(x["cpr_years"]))
    elseif t == "floor_ceiling"
        _sp("  Korridor:  -%.0f %% / +%.0f %% um reale Erstentnahme\n", x["floor"], x["ceiling"])
    elseif t == "endowment"
        _sp("  Glättung:  %.0f %%\n", x["smoothing"])
    elseif t == "hebeler"
        _sp("  Glättung:  %.0f %%, erwartete Realrendite %.2f %%\n", x["smoothing"], x["exp_return"])
    elseif t == "vpw"
        _sp("  Alter %d bis %d, erwartete Realrendite %.2f %%\n", _as_integer(x["age"]), _as_integer(x["max_age"]), x["exp_return"])
    elseif t == "abw"
        _sp("  Erwartete Realrendite %.2f %%, Zielvermögen %.0f\n", x["exp_return"], x["fv"])
    elseif t == "cape"
        _sp("  Rate = %.2f %% + %.2f / CAPE\n", x["cape_a"], x["cape_b"])
    elseif t == "ratchet"
        _sp("  +%.0f %% bei Depot > %.2f x Start, alle %d Jahre\n", x["raise"], x["ratchet_threshold"], _as_integer(x["ratchet_gap"]))
    elseif t == "sensible"
        _sp("  Zusatz: %.0f %% des realen Vorjahresgewinns\n", x["extra"])
    elseif t == "clyatt"
        _sp("  Mindestens %.0f %% der Vorjahresentnahme\n", x["floor95"])
    else
        ""
    end
    print(io, ex)
    if x["min_real"] > 0 || isfinite(x["max_real"])
        print(io, _sp("  Grenzen:   %.0f bis %s (real)\n", x["min_real"], _fmt1(Float64(x["max_real"]))))
    end
    nothing
end

"Parametervektor für den Kern (Reihenfolge = enum in withdrawal_core.cpp)."
function _wd_param_vector(rule)
    r = rule
    f(k) = Float64(r[k])
    return Float64[f("rate") / 100, f("ceiling") / 100, f("floor") / 100, f("cut") / 100, f("raise") / 100, f("cpr_years"),
                   f("inflation_cap") / 100, f("smoothing") / 100, f("exp_return") / 100, f("cape_a") / 100, f("cape_b"),
                   f("ratchet_threshold"), f("ratchet_gap"), f("extra") / 100, f("min_real"), f("max_real"), f("age"),
                   f("max_age"), f("fv"), f("floor95") / 100, _istrue(r["skip_inflation"]) ? 1.0 : 0.0, f("max_rate") / 100]
end

"Perioden je Jahr (`.wd_ppy`)."
function _wd_ppy(frequency)
    frequency == "year" && return 1
    frequency == "quarter" && return 4
    frequency == "month" && return 12
    _stop("frequency muss 'year', 'quarter' oder 'month' sein.")
end

"Letzte Zeile je Kalenderperiode (1-basiert), R: `.period_ends`."
function _period_ends(dates, frequency)
    d = _todate(dates, "dates")
    key = [frequency == "year" ? Dates.year(x) : frequency == "quarter" ? Dates.year(x) * 10 + (Dates.month(x) - 1) ÷ 3 :
           Dates.year(x) * 100 + Dates.month(x) for x in d]
    isempty(key) && return Int[]
    return findall(vcat(key[2:end] .!= key[1:end-1], true))
end

# ═══════════════════════════════════════════════════════════════════════════
# withdrawal_paths-Objekte, Kohorten, Wertindex
# ═══════════════════════════════════════════════════════════════════════════

_fill_locf(v) = _dvec(SimLev.Backcast._fill_na(_dvec(v), "locf"))

_dfnames(data) = data isa RFrame ? names(data) : something(_names(data), String[])
_dfcol(data, nm) = data isa RFrame ? data[nm] : _get(data, nm)

"R's `x^y` elementweise mit Recycling."
function _pow_vec(x, y)
    x = _dvec(x); y = _dvec(y)
    (isempty(x) || isempty(y)) && return Float64[]
    n = max(length(x), length(y))
    return Float64[_rpow(x[(i-1)%length(x)+1], y[(i-1)%length(y)+1]) for i in 1:n]
end

"`apply(M, 2, f)`: Vektor bei Länge 1 je Spalte, sonst Matrix (Ergebnis × Spalten)."
function _apply_cols(M::AbstractMatrix, f)
    res = [_dvec(f(M[:, j])) for j in 1:size(M, 2)]
    isempty(res) && return Float64[]
    all(r -> length(r) == 1, res) && return Float64[r[1] for r in res]
    return reduce(hcat, res)
end
_agg_prod(c, k) = Float64[_rprod(c[i:min(i + k - 1, length(c))]) for i in 1:k:length(c)]
_as_matrix(x) = x isa RFrame ? reduce(hcat, [_dvec(c) for c in x.cols]) : x isa AbstractVector ? reshape(_dvec(x), :, 1) :
                x isa Number ? fill(Float64(x), 1, 1) : _mat(x)

"""
    withdrawal_cohorts(data; price = "value", inflation = nothing, years = 30, frequency = "year",
                       step = "month", wrap = false, cape = nothing, base_rate = nothing, inflation_type = "level")

Historische Entnahme-Kohorten bilden.

Erzeugt rollierende Start-Kohorten (wie Bengen 1994 und die Trinity-Studie) aus einer historischen Kursreihe:
Für jeden Startmonat bzw. jedes Startjahr entsteht ein Pfad über `years` Jahre. Eingabe ist ein Tabelle
(RFrame) mit Spalte `date` und einer Kursspalte (Niveau, keine Renditen) oder ein gespeichertes Ergebnis von
`simulation()`. Die Reihe wird auf Monatsenden verdichtet (letzter Wert je Kalendermonat, fehlende Werte
fortgeschrieben); die Monatsrenditen werden zur gewählten `frequency` aufmultipliziert. Die Daten müssen jeden
Kalendermonat zwischen erstem und letztem Datum enthalten (Tages-, Wochen- oder Monatsdaten); sonst, etwa bei
Jahresdaten, bricht die Funktion ab. Das Ergebnis geht direkt an `withdrawal_simulation()`,
`withdrawal_max_rate()` oder `withdrawal_perfect_rate()`.

# Argumente
- `data`: Tabelle (RFrame) mit Spalte `date` (Klasse Date oder umwandelbar) und der Kursspalte `price` (ggf.
  auch Spalten für `inflation`, `cape`, `base_rate`), oder ein `SimLevResult`: dann wird dessen
  zeitgewichteter Wertindex `result_index()` verwendet, `price` ignoriert, und nur `nothing` oder ein
  Prozentsatz für `inflation` ist erlaubt (keine `cape`- oder `base_rate`-Spalten).
- `price`: Name der Kursspalte des Portfolios (Total-Return-Niveau, nach Kosten), z. B. eine Backcast-Reihe.
  Standard `"value"`.
- `inflation`: `nothing` (Standard; keine Inflation), Zahl = konstante Inflation in Prozent p. a. (2 = 2 % p.
  a., tagesgenau über 365.25 Tage je Jahr umgerechnet) oder Zeichenkette = Name einer Preisindex-Spalte
  (CPI-Niveau, z. B. HVPI) bzw. einer Ratenspalte (siehe `inflation_type`).
- `years`: Länge jeder Kohorte in Jahren (Standard 30; intern 12 x `years` Monate). Muss ganze Perioden der
  `frequency` ergeben (bei `"year"` ganze Jahre, bei `"quarter"` z. B. auch 2.5).
- `frequency`: Periodenlänge der Entnahme-Simulation: `"year"` (Standard), `"quarter"` oder `"month"`.
- `step`: Abstand der Kohortenstarts: `"month"` (Standard; jede Kohorte beginnt einen Monat später) oder
  `"year"` (alle 12 Monate).
- `wrap`: Logisch (Standard `false`). `true`: Kohorten über das Datenende hinaus durch Fortsetzung am
  Datenanfang verlängern (wie FI Calc, Option "loop"), so dass jeder Startzeitpunkt gemäß `step` eine Kohorte
  ergibt; `false`: nur Kohorten, die vollständig in den Daten liegen.
- `cape`: Optional Name einer Spalte mit CAPE-Werten (für die Regel `"cape"` in `withdrawal_rule()`);
  verwendet wird der Wert zu Beginn jeder Periode.
- `base_rate`: Optional Name einer Spalte mit dem Basiszins in Prozent (2.5 = 2,5 %) für die Vorabpauschale
  (Wert zu Beginn jeder Periode); sonst gilt `base_rate` aus `withdrawal_simulation()`.
- `inflation_type`: Behandlung einer Spalte in `inflation`: `"level"` (Reihe ist ein Preisindex-Niveau;
  Inflation = Verhältnis der Monatsendwerte) oder `"rate_pa"` (Reihe ist eine Inflationsrate in Prozent pro
  Jahr, 2 = 2 % p. a., nicht je Datenperiode, kein Anteil; je Zeile über die Kalendertage seit der Vorzeile
  aufgezinst, Π (1 + r/100)^Tage/365.25). Stammt `data` aus `bootstrap_data()` und ist die Spalte in
  `bootstrap_config()` ausdrücklich als `aux_type = "rate"` gekennzeichnet (Attribut `aux_type` des Tabelle
  (RFrame)), ergibt sich `"rate_pa"` daraus; `inflation_type` kann dann entfallen und muss, wenn angegeben,
  dazu passen (sonst Fehler). Ohne Attribut gilt `inflation_type` (Standard `"level"`, bisheriges Verhalten).
  Das Attribut geht bei Umformungen wie `transform()`, `merge()`, `cbind()` oder Speichern als CSV verloren;
  dann `inflation_type = "rate_pa"` angeben. Bei Zahl oder `nothing` in `inflation` ohne Wirkung.

# Rückgabe
Objekt der Klasse `withdrawal_paths` (Liste) mit `returns` (Matrix Perioden x Kohorten der
Brutto-Periodenrenditen), `inflation` (gleiche Form, Brutto-Inflation je Periode; ohne Inflation 1), `cape`
und `base_rate` (Matrizen der Werte zu Periodenbeginn oder `nothing`), `frequency`, `start_dates` (Datum des
Monatsendwerts, ab dem jede Kohorte läuft), `historical = true`, `wrap` und `source` (Name der Kursspalte).

# Beispiel
```julia
using SimLev, Dates, Random
dts = [Date(1990, 1, 1) + Month(k) for k in 0:359]
d = RFrame("date" => dts, "depot" => 100 .* cumprod(exp.(0.005 .+ 0.04 .* randn(MersenneTwister(1), 360))))
coh = withdrawal_cohorts(d; price = "depot", inflation = 2, years = 20, step = "year")
ws = withdrawal_simulation(coh, withdrawal_rule("constant"; rate = 4))
println(size(coh["returns"]))
```
"""
function withdrawal_cohorts(data; price = "value", inflation = nothing, years = 30, frequency = nothing, step = nothing,
                            wrap = false, cape = nothing, base_rate = nothing, inflation_type = _MISSING)
    data = SimLev.as_rframe(data)
    it_given = inflation_type !== _MISSING
    frequency = _match_arg(frequency, ("year", "quarter", "month"))
    step = _match_arg(step, ("month", "year"))
    inflation_type = _match_arg(it_given ? inflation_type : nothing, ("level", "rate_pa"))
    if _is_result(data)
        if inflation isa AbstractString || cape !== nothing || base_rate !== nothing
            _stop("Bei einem SimLevResult sind nur numerische Inflation und keine Zusatzspalten möglich.")
        end
        data = result_index(data)
        price = "value"
    end
    nms = _dfnames(data)
    ("date" in nms && price in nms) || _stop("data braucht 'date' und die Kursspalte.")
    at = data isa RFrame ? get(SimLev.attrs(data), "aux_type", nothing) : nothing
    attr_rate = inflation isa AbstractString && at !== nothing && _aux_type_of(at, inflation) == "rate"
    if attr_rate && it_given && inflation_type != "rate_pa"
        _stop(@sprintf("inflation_type = '%s' passt nicht zu aux_type['%s'] = 'rate' (Attribut aus bootstrap_data()); inflation_type weglassen oder 'rate_pa' angeben.",
                       inflation_type, inflation))
    end
    infl_rate = inflation isa AbstractString && (attr_rate || inflation_type == "rate_pa")
    dd = _todate(_dfcol(data, "date"), "withdrawal_cohorts: data\$date")
    o = sortperm(_days.(dd); alg = MergeSort)
    dates = dd[o]
    col(name) = _as_numeric_col(_dfcol(data, name))[o]
    px = _fill_locf(col(price))
    ends = _period_ends(dates, "month")
    mdates = dates[ends]
    mpx = px[ends]
    mi = Int[Dates.year(x) * 12 + Dates.month(x) for x in mdates]
    dmi = diff(mi)
    gap = findall(!=(1), dmi)
    if !isempty(gap)
        _stop(@sprintf("withdrawal_cohorts braucht lückenlose Monatsdaten (mindestens ein Datum je Kalendermonat), aber nach %s folgt %s%s.",
                       string(mdates[gap[1]]), string(mdates[gap[1]+1]),
                       _median(Float64.(dmi)) >= 12 ? " (Jahresdaten? Dann Jahresrenditen als Matrix Jahre x Kohorten an withdrawal_simulation() übergeben)" : ""))
    end
    cpi = if inflation === nothing
        ones(length(ends))
    elseif infl_rate
        v = _fill_locf(col(inflation))
        dt = Float64[_days(dates[i+1]) - _days(dates[i]) for i in 1:length(dates)-1] ./ 365.25
        lvf = _cumprod(vcat(1.0, _pow_vec(1 .+ v[2:end] ./ 100, dt)))
        lv = lvf[ends]
        f = lv[2:end] ./ lv[1:end-1]
        bad = .!isfinite.(f) .| (f .<= 0)
        if any(bad)
            _stop(@sprintf("Spalte '%s' (Rate in Prozent p. a.) ergibt nicht endliche oder nicht positive Monatsfaktoren (z. B. %s; Rate <= -100 %%?).",
                           inflation, _fmt_nan(f[bad][1]; digits = 4)))
        end
        lv
    elseif inflation isa AbstractString
        _fill_locf(col(inflation))[ends]
    else
        _pow_vec(1 + Float64(_f1(inflation)) / 100, Float64[_days(m) - _days(mdates[1]) for m in mdates] ./ 365.25)
    end
    capev = cape === nothing ? nothing : _fill_locf(col(cape))[ends]
    brv = base_rate === nothing ? nothing : _fill_locf(col(base_rate))[ends]
    mret = mpx[2:end] ./ mpx[1:end-1]
    minf = cpi[2:end] ./ cpi[1:end-1]
    nm = length(mret)
    ppy = _wd_ppy(frequency)
    mpp = 12 ÷ ppy
    yv = _numvec(years)
    if yv === nothing || length(yv) != 1 || !isfinite(yv[1]) || yv[1] <= 0 ||
       abs(yv[1] * 12 - _round0(yv[1] * 12)) > 1e-8 || rem(_round0(yv[1] * 12), mpp) != 0
        _stop(@sprintf("years muss eine positive Zahl sein, die ganze Perioden der frequency '%s' ergibt (bei 'year' ganze Jahre; erhalten: %s).",
                       frequency, _show(years)))
    end
    len_m = Int(_round0(yv[1] * 12))
    starts = if step == "month"
        collect(1:nm)
    else
        nm < 1 && _stop("wrong sign in 'by' argument")
        collect(1:12:nm)
    end
    wrap || (starts = starts[starts .+ len_m .- 1 .<= nm])
    isempty(starts) && _stop("Zu kurze Historie für die gewählte Kohortenlänge.")
    take(v, s) = v[((s - 1) .+ (1:len_m) .- 1) .% nm .+ 1]
    agg(M) = mpp == 1 ? M : _apply_cols(M, c -> _agg_prod(c, mpp))
    ns = length(starts)
    Rm = agg(reduce(hcat, [take(mret, s) for s in starts]))
    Im = agg(reduce(hcat, [take(minf, s) for s in starts]))
    to_mat(A) = A isa AbstractVector ? reshape(A, :, ns) : A
    pick_start(v) = v === nothing ? nothing : reduce(hcat, [take(v[1:end-1], s) for s in starts])[1:mpp:len_m, :]
    return RList("returns" => to_mat(Rm), "inflation" => to_mat(Im), "cape" => pick_start(capev),
                 "base_rate" => pick_start(brv), "frequency" => frequency, "start_dates" => mdates[starts],
                 "historical" => true, "wrap" => Bool(wrap), "source" => price; class = "withdrawal_paths")
end

_report_items(rep) = rep === nothing ? Any[] : rep isa AbstractDict ? collect(values(rep)) : rep isa NamedTuple ? collect(values(rep)) :
                     rep isa AbstractVector ? collect(rep) : Any[]

"""
    result_index(x; base = 100)

Zeitgewichteter Wertindex eines Simulationsergebnisses.

Bildet aus einem `SimLevResult` den um Ein- und Auszahlungen bereinigten Wertindex (Basis der TTWROR). Damit
lässt sich jedes gespeicherte Ergebnis von `simulation()` als Renditequelle für `withdrawal_simulation()`
verwenden. Verwendet wird der von `simulation()` gespeicherte Index `twr_index`: an Tagen ohne Zahlung I_t =
I_t-1 W_t / W_t-1; an Tagen mit Zahlung wird der Vortagesbestand zum Schlusskurs vor der Zahlung bewertet
(siehe `simulation()`, Abschnitt Kennzahlen), sodass die Zahlung die Rendite nicht verzerrt. W_t ist der
Depotwert. Für ältere Ergebnisse ohne `twr_index` gilt I_t = I_t-1 (W_t - F_t) / W_t-1 mit F_t = Summe der
Ein- und Auszahlungen aller Assets am Tag t; nicht endliche Tagesfaktoren (z. B. bei Depotwert 0) werden dabei
als 1 gesetzt.

# Argumente
- `x`: Objekt der Klasse `SimLevResult` (Ergebnis von `simulation()`).
- `base`: Startwert des Index (Zahl, Standard 100).

# Rückgabe
Tabelle (RFrame) mit einer Zeile je Simulationstag und den Spalten `date` (Date), `value` (Index, beginnt bei
`base`), `worth` (Depotwert) und `flows` (Summe der Ein-/Auszahlungen je Tag, Geldbetrag).

# Beispiel
```julia
using SimLev, Dates, Random
rng = MersenneTwister(1)
n = 400
d = RFrame("date" => Date(2020, 1, 1) .+ Day.(0:n-1))
d["ETF"] = 100 .* cumprod(1 .+ 3e-4 .+ 0.01 .* randn(rng, n))
res = simulation(d, create_strategy(ETF = asset_config("etf")); dca = dca_plan(100, 1))
println(result_index(res))
```
"""
function result_index(x; base = 100)
    x = SimLev.as_rframe(x)
    _is_result(x) || _stop("x muss ein SimLevResult (Ergebnis von simulation()) sein.")
    w = _dvec(_get(x, "worth"))
    fls = [_dvec(_get(a, "flows")) for a in _report_items(_get(x, "report"))]
    fl = if !isempty(fls) && length(w) > 1
        Float64[_rsum(Float64[f[i] for f in fls]) for i in eachindex(w)]
    elseif !isempty(fls)
        Float64[f[1] for f in fls]
    else
        zeros(length(w))
    end
    twr = _get(x, "twr_index")
    idx = if twr !== nothing && _len(twr) == length(w)
        _dvec(twr)
    else
        g = vcat(1.0, Float64[(w[i] - fl[i]) / w[i-1] for i in 2:length(w)])
        for i in eachindex(g)
            isfinite(g[i]) || (g[i] = 1.0)
        end
        _cumprod(g)
    end
    dts = _get(x, "dates")
    dts = eltype(dts) <: Integer ? [Date(1970, 1, 1) + Day(d) for d in dts] : _todate(dts, "dates")
    return RFrame("date" => dts, "value" => Float64(base) .* idx, "worth" => w, "flows" => fl)
end

"Periodenenden als Jahrestage ab Startdatum (1-basierte Zeilen), R: `.anniv_ends`."
function _anniv_ends(dates, frequency)
    stp = frequency == "year" ? 12 : frequency == "quarter" ? 3 : 1
    d = _todate(dates, "dates")
    d0, d1 = d[1], d[end]
    nmon = (Dates.year(d1) - Dates.year(d0)) * 12 + Dates.month(d1) - Dates.month(d0)
    last = fld(nmon, stp) * stp
    ks = last >= 0 ? collect(0:stp:last) : Int[]
    tg = _todate(SimLev.DataPrep._add_months(d0, ks), "dates")
    tg = tg[tg .<= d1]
    dd = _days.(d)
    out = Int[]
    for t in tg
        v = searchsortedlast(dd, _days(t))
        v in out || push!(out, v)
    end
    return out
end

function _aux_kind(cfg, inflation, it_given, inflation_type)
    sets = _cfg_list(cfg, "aux_type_set")
    (!(inflation isa AbstractString) || !(inflation in sets)) && return nothing
    k = _aux_type_of(_get(cfg, "aux_type"), inflation)
    it = k == "level" ? "level" : "rate_pa"
    if it_given && inflation_type != it
        _stop(@sprintf("inflation_type = '%s' passt nicht zu aux_type['%s'] = '%s' in bootstrap_config(); inflation_type weglassen oder '%s' angeben.",
                       inflation_type, inflation, k, it))
    end
    return k
end

function _is_result_list(x)
    (x isa RList || x isa RFrame) && return false
    vals = x isa AbstractDict || x isa NamedTuple ? collect(values(x)) : x isa AbstractVector ? collect(x) : nothing
    vals === nothing && return false
    return !isempty(vals) && all(_is_result, vals)
end

_vapply_mat(vecs, L) = L == 1 ? reshape(Float64[v[1] for v in vecs], :, 1) :
                       (isempty(vecs) ? zeros(L, 0) : reduce(hcat, [_dvec(v) for v in vecs]))

"""
    withdrawal_paths(x; column = nothing, strategy = nothing, inflation = nothing, inflation_type = "level",
                     frequency = "year", dates = nothing, start = "2000-01-01", cape = nothing)

Pfade in Perioden-Renditen für Entnahmen umwandeln.

Wandelt fertige Simulationen in die Periodenmatrizen von `withdrawal_simulation()` um, damit sich eine
Entnahmephase auf bereits gerechnete Pfade setzen lässt. Perioden beginnen am Startdatum der Pfade und enden
an den Jahrestagen (bzw. Quartals- oder Monatstagen) danach, je vom Startdatum gezählt und auf das Monatsende
begrenzt (Start 31.01.: 29.02., 31.03., 30.04. ...); eine unvollständige letzte Periode entfällt.

# Argumente
- `x`: `SimLevBootstrapStudy`, Liste von `SimLevResult` oder `bootstrap_result` (siehe oben).
- `column`: Nur bei `bootstrap_result` (dort Pflicht): Name der Kursspalte im Pfad (Index oder Hebelprodukt).
- `strategy`: Nur bei `SimLevBootstrapStudy`: Strategiename. `nothing` (Standard) = erste gespeicherte
  Strategie.
- `inflation`: `nothing` (Standard; keine Inflation, Faktor 1), Zahl = konstante Inflation in Prozent p. a. (2
  = 2 % p. a., über die Kalendertage der Perioden umgerechnet) oder Zeichenkette = Name einer Zusatzreihe: bei
  `bootstrap_result` eine Spalte der Pfade (aus `aux` in `bootstrap_config()`; Behandlung nach `aux_type` bzw.
  `inflation_type`), bei Studien eine mit `keep_aux` gespeicherte Reihe (deren gespeicherte Periodenfaktoren
  werden direkt als Brutto-Inflation verwendet; nicht endliche Faktoren oder Werte <= 0 sind ein Fehler). Eine
  Reihe mit `aux_type = "rate"` gilt dabei immer als Inflationsrate in Prozent pro Jahr (2 = 2 % p. a.; nicht
  je Datenperiode, kein Anteil), je Pfadzeile über die Kalendertage aufgezinst, Π (1 + r/100)^Tage/365.25. Bei
  Ergebnislisten nur `nothing` oder eine Zahl.
- `inflation_type`: Behandlung einer Zusatzreihe in `inflation`: `"level"` (Reihe ist ein Preisindex-Niveau;
  Inflation = Verhältnis des kumulierten Niveaus an den Periodenenden, d. h. die historischen
  Zeilenverhältnisse der gezogenen Zeilen) oder `"rate_pa"` (Reihe ist eine Inflationsrate in Prozent pro
  Jahr, 2 = 2 % p. a., nicht je Datenperiode, kein Anteil; je Pfadzeile über die Kalendertage aufgezinst, Π (1
  + r/100)^Tage/365.25). Ist die Art der Reihe in `bootstrap_config()` mit `aux_type` ausdrücklich angegeben,
  ergibt sich die Behandlung daraus (`"level"` bzw. `"rate"` -> `"rate_pa"`); `inflation_type` kann dann
  entfallen und muss, wenn angegeben, dazu passen (sonst Fehler). Ohne Angabe in `aux_type` gilt das bisherige
  Verhalten: bei `bootstrap_result` entscheidet `inflation_type` (Standard `"level"`; verwendet wird die
  Niveau-Variante im Pfad, Attribut `aux_level` aus `bootstrap()`); bei Studien werden die mit `keep_aux`
  gespeicherten Faktoren (Niveau-Variante) unverändert verwendet, ein ausdrückliches `inflation_type =
  "rate_pa"` ist dort ein Fehler (die Rate lässt sich aus den gespeicherten Faktoren nicht gewinnen; `aux_type
  = [<Name> = "rate"]` angeben und die Studie neu rechnen).
- `frequency`: Periodenlänge: `"year"` (Standard), `"quarter"` oder `"month"`. Bei Studien gilt stattdessen
  die gespeicherte Frequenz.
- `dates`, `start`: Nur bei `bootstrap_result`: Kalender der Pfadzeilen. `dates` = Date-Vektor (oder in Date
  umwandelbar) mit genau einem Datum je Pfadzeile, streng aufsteigend; `nothing` (Standard) = tägliche
  Kalenderdaten ab `start` (Standard `"2000-01-01"`), d. h. jede Pfadzeile zählt als ein Kalendertag. Für
  Pfade aus Handelstagen passende `dates` angeben (siehe `bootstrap_data()`).
- `cape`: Nur bei `bootstrap_result`: optional Name einer Pfadspalte mit CAPE-Werten (Wert zu Periodenbeginn)
  für die Regel `"cape"`.

# Rückgabe
Objekt der Klasse `withdrawal_paths` (Liste) mit `returns` (Matrix Perioden x Pfade der
Brutto-Periodenrenditen), `inflation` (gleiche Form, Brutto-Inflation je Periode), `cape` (Matrix oder
`nothing`), `base_rate = nothing`, `frequency`, `start_dates = nothing`, `historical = false`, `weights`
(Pfadgewichte oder `nothing`) und `source` (Spaltenname, `"study:"` mit angehängtem Strategienamen oder
`"results"`).

# Details
Akzeptierte Eingaben `x`:

- `SimLevBootstrapStudy`: Ergebnis von `bootstrap_study()`, das mit `keep_returns = "year"`, `"quarter"` oder
  `"month"` gerechnet wurde. Verwendet die gespeicherten zeitgewichteten Periodenrenditen der Strategie
  `strategy` und deren Frequenz (`frequency` wird ignoriert); Pfade mit fehlenden Werten entfallen; die
  Pfadgewichte der Studie werden übernommen.
- Liste von `SimLevResult`: z. B. gespeicherte Läufe von `simulation()` auf Bootstrap-Pfaden; je Element ein
  Pfad über dessen zeitgewichteten Wertindex (`result_index()`). Alle Ergebnisse müssen gleich viele Tage
  haben; der Kalender des ersten Ergebnisses gilt.
- `bootstrap_result`: Ergebnis von `bootstrap()`; `column` wählt die Kursspalte der Pfade, die Pfadgewichte
  werden übernommen.

Ein einzelnes `SimLevResult` wird hier nicht angenommen (dafür `withdrawal_cohorts()`). Bereits fertige
`withdrawal_paths` (aus `withdrawal_cohorts()` oder `bootstrap_pooled()`) und Renditematrizen werden direkt an
`withdrawal_simulation()` übergeben; `withdrawal_simulation()` ruft diese Funktion für Studien und
Ergebnislisten auch selbst auf.

# Beispiel
```julia
using SimLev, Random
d = RFrame("us" => 1 .+ 3e-4 .+ 0.01 .* randn(MersenneTwister(2), 1500), "infl" => fill(2.0, 1500))
cfg = bootstrap_config((us = "us",); aux = (infl = "infl",))
b = bootstrap(d, cfg; method = "stationary", n = 20, params = (L = 50,), path_length = 3653, seed = 1, progress = false)
wp = withdrawal_paths(b; column = "us", inflation = "infl", inflation_type = "rate_pa")
println(size(wp["returns"]))   # 10 Jahre x 20 Pfade
```
"""
function withdrawal_paths(x; column = nothing, strategy = nothing, inflation = nothing, inflation_type = _MISSING,
                          frequency = nothing, dates = nothing, start = "2000-01-01", cape = nothing)
    x = SimLev.as_rframe(x)
    it_given = inflation_type !== _MISSING
    frequency = _match_arg(frequency, ("year", "quarter", "month"))
    inflation_type = _match_arg(it_given ? inflation_type : nothing, ("level", "rate_pa"))
    if inflation !== nothing
        okv = inflation isa AbstractString || (_isnum(inflation) && isfinite(Float64(inflation)))
        okv || _stop("inflation muss NULL, eine Zahl (Prozent p. a.) oder der Name einer Zusatzreihe sein.")
    end
    function infl_from(n_per, n_paths, ends_dates)
        inflation === nothing && return ones(n_per, n_paths)
        inflation isa AbstractString && return nothing
        f = _pow_vec(1 + Float64(inflation) / 100, Float64[_days(ends_dates[i+1]) - _days(ends_dates[i]) for i in 1:length(ends_dates)-1] ./ 365.25)
        return reshape(Float64[f[(i-1)%length(f)+1] for i in 1:n_per*n_paths], n_per, n_paths)
    end
    mk(R, I, C, w, src, freq) = RList("returns" => _as_matrix(R), "inflation" => _as_matrix(I),
                                      "cape" => C === nothing ? nothing : _as_matrix(C), "base_rate" => nothing,
                                      "frequency" => freq, "start_dates" => nothing, "historical" => false,
                                      "weights" => w, "source" => src; class = "withdrawal_paths")
    # 1) Gespeicherte Bootstrap-Studie
    if _is_study(x)
        rets = _get(x, "returns")
        rets === nothing && _stop("Die Studie enthält keine Periodenrenditen; bootstrap_study(..., keep_returns = 'year') verwenden.")
        rn = collect(String, keys(rets))
        strategy = strategy === nothing ? rn[1] : strategy
        strategy in rn || _stop(@sprintf("Strategie '%s' nicht gespeichert. Verfügbar: %s", strategy, join(rn, ", ")))
        freq = x["returns_frequency"]
        R = _mat(rets[strategy])
        ok = Bool[!any(isnan, view(R, :, j)) for j in 1:size(R, 2)]
        if inflation isa AbstractString
            ar = _get(x, "aux_returns")
            (ar === nothing || _get(ar, inflation) === nothing) && _stop(@sprintf("Zusatzreihe '%s' nicht gespeichert (keep_aux).", inflation))
            kind = _aux_kind(x["config"], inflation, it_given, inflation_type)
            if kind === nothing && it_given && inflation_type == "rate_pa"
                _stop(@sprintf("inflation_type = 'rate_pa': die mit keep_aux gespeicherten Faktoren der Zusatzreihe '%s' sind die Niveau-Variante (Reihe nicht in aux_type genannt). Für eine Rate in Prozent p. a. aux_type = c(%s = 'rate') in bootstrap_config() angeben und die Studie neu rechnen.",
                               inflation, inflation))
            end
            I0 = _mat(ar[inflation])
            r = vec(I0[:, ok])
            bad = .!isfinite.(r) .| (r .<= 0)
            if any(bad)
                msg = kind == "rate" ? "Zusatzreihe '%s' (aux_type 'rate') ergibt nicht endliche oder nicht positive Periodenfaktoren (z. B. %s)." :
                      "Zusatzreihe '%s' ist kein positives Niveau (gespeicherte Periodenverhältnisse nicht endlich oder <= 0, z. B. %s); für eine Rate in Prozent p. a. aux_type = c(<Name> = 'rate') in bootstrap_config() angeben."
                _stop(_sp(msg, inflation, _fmt_nan(r[bad][1]; digits = 4)))
            end
            I = I0
        else
            I = infl_from(size(R, 1), size(R, 2), x["returns_dates"])
        end
        w = _get(x, "path_weights")
        return mk(R[:, ok], I[:, ok], nothing, w === nothing ? nothing : _dvec(w)[ok], "study:" * strategy, freq)
    end
    # 2) Liste von simulation()-Ergebnissen
    if !_is_boot_result(x) && _is_result_list(x)
        inflation isa AbstractString && _stop("Bei Ergebnislisten ist 'inflation' ein Prozentsatz p. a.")
        lst = x isa AbstractDict || x isa NamedTuple ? collect(values(x)) : collect(x)
        idx = [result_index(r) for r in lst]
        ends = _anniv_ends(idx[1]["date"], frequency)
        length(ends) < 2 && _stop("Ergebnisse zu kurz für eine volle Periode.")
        vecs = Vector{Float64}[]
        for d in idx
            SimLev.nrow(d) != SimLev.nrow(idx[1]) && _stop("Alle Ergebnisse müssen gleich lang sein.")
            v = d["value"][ends]
            push!(vecs, v[2:end] ./ v[1:end-1])
        end
        R = _vapply_mat(vecs, length(ends) - 1)
        return mk(R, infl_from(size(R, 1), size(R, 2), idx[1]["date"][ends]), nothing, nothing, "results", frequency)
    end
    # 3) bootstrap()-Pfade
    _is_boot_result(x) || _stop("x muss ein bootstrap_result, eine Liste von SimLevResult oder eine SimLevBootstrapStudy sein.")
    column === nothing && _stop("Bei bootstrap_result muss 'column' angegeben werden.")
    P1 = x["paths"][1]
    cn = something(B._colnames(P1), String[])
    column in cn || _stop(@sprintf("Spalte '%s' nicht im Pfad. Verfügbar: %s", column, join(cn, ", ")))
    nr = B._nrow(P1)
    if dates === nothing
        dates = _seq_dates(_todate(start, "start")[1], nr)
    else
        dates = _todate(dates, "dates")
        length(dates) != nr && _stop(@sprintf("dates hat Länge %d, die Pfade haben %d Zeilen (path_length + 1); ein Datum je Pfadzeile angeben.", length(dates), nr))
        dv = _days.(dates)
        any(diff(dv) .<= 0) && _stop("dates muss streng aufsteigend sein und darf kein NA enthalten.")
    end
    ends = _anniv_ends(dates, frequency)
    length(ends) < 2 && _stop("Pfade zu kurz für eine volle Periode der gewählten frequency.")
    e1 = ends[2:end]; e0 = ends[1:end-1]
    per(v) = (v = _dvec(v); v[e1] ./ v[e0])
    pcol(P, c) = P isa RFrame ? _dvec(P[c]) : _mat(P)[:, findfirst(==(c), B._colnames(P))]
    n_per = length(ends) - 1
    R = _vapply_mat([per(pcol(P, column)) for P in x["paths"]], n_per)
    I = infl_from(size(R, 1), size(R, 2), dates[ends])
    if I === nothing
        inflation in cn || _stop(@sprintf("Zusatzreihe '%s' nicht im Pfad. Verfügbar: %s", inflation, join(cn, ", ")))
        kind = _aux_kind(_get(x, "config", RList()), inflation, it_given, inflation_type)
        kind === nothing || (inflation_type = kind == "level" ? "level" : "rate_pa")
        dt = Float64[_days(dates[i+1]) - _days(dates[i]) for i in 1:length(dates)-1] ./ 365.25
        vecs = Vector{Float64}[]
        for P in x["paths"]
            if inflation_type == "rate_pa"
                v = pcol(P, inflation)
                r = per(_cumprod(vcat(1.0, _pow_vec(1 .+ v[2:end] ./ 100, dt))))
                bad = .!isfinite.(r) .| (r .<= 0)
                if any(bad)
                    _stop(@sprintf("Zusatzreihe '%s' (Rate in Prozent p. a.) ergibt nicht endliche oder nicht positive Periodenfaktoren (z. B. %s; Rate <= -100 %%?).",
                                   inflation, _fmt_nan(r[bad][1]; digits = 4)))
                end
                push!(vecs, r)
                continue
            end
            lv = P isa NamedMat ? get(P.attrs, "aux_level", nothing) : P isa RFrame ? get(SimLev.attrs(P), "aux_level", nothing) : nothing
            v = if kind == "level"
                pcol(P, inflation)
            elseif lv !== nothing && inflation in something(B._colnames(lv), String[])
                pcol(lv, inflation)
            elseif _get(x, "method") in ("wild", "reset")
                pcol(P, inflation)
            else
                _stop(@sprintf("inflation_type = 'level': Pfad ohne Niveau-Variante der Reihe '%s' (Attribut aux_level); beim Verfahren '%s' springen die Originalwerte an Blockgrenzen. Pfade mit bootstrap() neu erzeugen.",
                               inflation, _get(x, "method")))
            end
            r = per(v)
            any(.!isfinite.(r) .| (r .<= 0)) &&
                _stop(@sprintf("Zusatzreihe '%s' ist kein positives Niveau (Verhältnisse nicht endlich oder <= 0); für eine Rate inflation_type = 'rate_pa' verwenden.", inflation))
            push!(vecs, r)
        end
        I = _vapply_mat(vecs, n_per)
    end
    C = nothing
    if cape !== nothing
        cv = [pcol(P, cape)[e0] for P in x["paths"]]
        C = n_per == 1 ? Float64[v[1] for v in cv] : reduce(hcat, cv)
    end
    return mk(R, I, C, _get(x, "weights"), column, frequency)
end

# ═══════════════════════════════════════════════════════════════════════════
# Perfect Withdrawal Rate
# ═══════════════════════════════════════════════════════════════════════════

"Reale Jahresrenditen aus Perioden-Matrizen (R: `.annual_real`)."
function _annual_real(wp)
    ppy = _wd_ppy(_get(wp, "frequency"))
    real = _mat(_get(wp, "returns")) ./ _mat(_get(wp, "inflation"))
    ppy == 1 && return real
    ny = size(real, 1) ÷ ppy
    return _apply_cols(real[1:ny*ppy, :], c -> _agg_prod(c, ppy))
end

"""
    withdrawal_perfect_rate(real_returns; legacy = 0)

Perfect Withdrawal Rate (PWR) je Pfad in Prozent.

Exakte konstante reale Entnahmerate, die ein Depot bei gegebener Renditefolge genau aufbraucht bzw. das
Zielvermögen hinterlässt (Suarez, Suarez & Walz 2015; Entnahme jeweils zu Jahresbeginn): PWR = (R_n - K_E/K_S)
· S_n, R_n = Π (1+r_i), S_n = 1 / Σ_i=1^n Π_j=i^n (1 + r_j)

# Argumente
- `real_returns`: Numerische Matrix (Jahre x Pfade) realer Brutto-Jahresrenditen (z. B. 1.05 = +5 % real; ein
  Vektor gilt als ein Pfad) oder ein `withdrawal_paths`-Objekt: dann werden `returns / inflation` je Periode
  zu Jahren aufmultipliziert (ein unvollständiges letztes Jahr entfällt).
- `legacy`: Reales Zielvermögen am Ende als Anteil des Startvermögens (K_E / K_S; 0 = aufbrauchen (Standard),
  0.5 = 50 % erhalten; >= 0). Renditen müssen Brutto-Renditen sein (1.05, nicht 0.05); eine Matrix mit Median
  unter 0.5, negativen oder nicht endlichen Werten ist ein Fehler.

# Rückgabe
Numerischer Vektor der PWR je Pfad in Prozent des Startvermögens (4 = 4 % je Jahr).

# Details
Die PWR hängt nur von der realen Renditefolge ab (keine Steuern, Verkaufskosten oder weiteren Einkommen).

# Beispiel
```julia
using SimLev, Random
R = exp.(0.03 .+ 0.12 .* randn(MersenneTwister(1), 30, 5))   # 30 Jahre, 5 Pfade, real
println(withdrawal_perfect_rate(R))
```
"""
function withdrawal_perfect_rate(real_returns; legacy = 0)
    _is_wp(real_returns) && (real_returns = _annual_real(real_returns))
    R = try
        _numvec(real_returns) === nothing ? nothing : _as_matrix(real_returns)
    catch
        nothing
    end
    if R === nothing || isempty(R) || any(isnan, R) || any(!isfinite, R)
        _stop("withdrawal_perfect_rate: real_returns muss eine Matrix endlicher realer Brutto-Jahresrenditen sein (1.05 = +5 %).")
    end
    med = _median(vec(R))
    if med < 0.5
        _stop(@sprintf("withdrawal_perfect_rate: real_returns sieht nicht wie Brutto-Renditen aus (Median %s); erwartet z. B. 1.05 für +5 %%, nicht 0.05 (Nettorendite: 1 + r übergeben).",
                       _fmt1(med; digits = 4)))
    end
    any(<(0), R) && _stop("withdrawal_perfect_rate: Brutto-Renditen in real_returns müssen >= 0 sein (0 = Totalverlust).")
    lv = _numvec(legacy)
    if lv === nothing || length(lv) != 1 || !isfinite(lv[1]) || lv[1] < 0
        _stop(@sprintf("withdrawal_perfect_rate: legacy muss ein Anteil >= 0 sein (0.5 = 50 %% des Startvermögens; erhalten: %s).", _show(legacy)))
    end
    lg = lv[1]
    out = Vector{Float64}(undef, size(R, 2))
    for j in 1:size(R, 2)
        r = R[:, j]
        tp = reverse(_cumprod(reverse(r)))
        out[j] = (_rprod(r) - lg) / _rsum(tp) * 100
    end
    return out
end

# ═══════════════════════════════════════════════════════════════════════════
# Lots der Ansparphase
# ═══════════════════════════════════════════════════════════════════════════

_lots_df(a) = _get(a, "lots")
_lcol(L, nm) = L === nothing ? Float64[] : _dvec(L isa RFrame ? L[nm] : _get(L, nm))
_lrows(L) = L === nothing ? 0 : L isa RFrame ? SimLev.nrow(L) : length(_lcol(L, "units"))
function _last_worth(report, nm)
    r = _get(report, nm)
    wv = _dvec(_get(r, "worth", Float64[]))
    return isempty(wv) ? wv : wv[end:end]
end
_list_names(ol) = ol === nothing ? String[] : collect(String, something(_names(ol), String[]))

"Am Ende der Ansparphase gehaltene Assets (R: `.wd_held`)."
function _wd_held(ol, report, sv; tol = 1e-12)
    out = String[]
    for nm in _list_names(ol)
        L = _lots_df(_get(ol, nm))
        wv = _last_worth(report, nm)
        if _lrows(L) > 0 && _rsum(_lcol(L, "units")) > 0 && length(wv) == 1 && isfinite(wv[1]) && wv[1] > tol * sv
            push!(out, nm)
        end
    end
    return out
end

"Offene Lots als FIFO-Bestand für den Kern (R: `.wd_lots`)."
function _wd_lots(ol, report, sv; tol = 1e-12)
    n = Float64[]; basis = Float64[]; vp = Float64[]; group = Int[]
    g = 0
    assets = 0.0
    for nm in _wd_held(ol, report, sv; tol = tol)
        L = _lots_df(_get(ol, nm))
        units = _lcol(L, "units")
        U = _rsum(units)
        keep = units .> 0
        u = units[keep]
        pr = _lcol(L, "price")[keep]
        v = _lcol(L, "vp")[keep]
        wv = _last_worth(report, nm)[1]
        append!(n, u ./ U .* wv)
        append!(basis, u .* pr)
        append!(vp, v)
        append!(group, fill(g, length(u)))
        g += 1
        assets = assets + wv
    end
    cash = sv - assets
    if abs(cash) > tol * sv
        push!(n, cash); push!(basis, cash); push!(vp, 0.0); push!(group, g)
    end
    return RList("n" => n, "basis" => basis, "vp" => vp, "group" => group)
end

"Ist eine Ordergebühr gesetzt (Zahl oder Liste(fixed, percent, min, max))?"
function _wd_fee_set(f)
    f === nothing && return false
    v = Any[]
    if f isa Union{RList,NamedTuple,AbstractDict}
        for k in something(_names(f), String[])
            k in ("fixed", "percent", "min") || continue
            x = _get(f, k)
            x === nothing && continue
            append!(v, x isa AbstractVector ? collect(x) : [x])
        end
    else
        append!(v, f isa AbstractVector ? collect(f) : [f])
    end
    out = Float64[]
    for z in v
        push!(out, z isa Bool ? Float64(z) : z isa Real ? Float64(z) : z isa AbstractString ? something(tryparse(Float64, strip(z)), NaN) : NaN)
    end
    return any(z -> isfinite(z) && z != 0, out)
end

# ═══════════════════════════════════════════════════════════════════════════
# withdrawal_simulation()
# ═══════════════════════════════════════════════════════════════════════════

_dflt(x, d) = x === _MISSING ? d : x
_sv_get(r, path...) = (v = r; for k in path; v = _get(v, k); end; v)

"Mittel bzw. Summe je Spalte in long double (colMeans/colSums; C-Kern)."
_col_ld(M::Matrix{Float64}, mean::Bool) = SimLev._ld_colsums(M; mean = mean)

"Steuerangaben der Person prüfen (R: `.wd_tax_mode`): `nothing` → \"none\", `tax_profile()` → \"person\"."
function _wd_tax_mode(tax)
    tax === nothing && return "none"
    (tax isa RList && SimLev.inherits(tax, "SimLevTaxProfile")) ||
        _stop("withdrawal_simulation: tax muss NULL oder ein Objekt aus tax_profile() sein, nicht $(SimLev._blk_cls(tax)).")
    pst = tax["private_sale_threshold"]
    un = ["private_sale_threshold" => !(pst isa Real && pst == 1000),
          "base_rate" => tax["base_rate"] !== nothing, "harvest" => tax["harvest"] !== nothing]
    bad = [p.first for p in un if p.second]
    isempty(bad) || _stop("withdrawal_simulation: tax_profile($(join(bad, ", "))) bildet die Entnahmephase nicht ab; " *
                          "ausgewertet werden rate, church_tax, sparer_pauschbetrag, guenstigerpruefung und income = income_rate() oder income_tariff() (Basiszins über base_rate von withdrawal_simulation()).")
    return "person"
end

const _WD_TARIFF_COLS = ("year", "taxable_income", "church_tax_paid_deductible", "church_tax_refunded",
                         "church_tax_net_deduction", "taxable_income_net", "deduction_effect", "gain_p23", "income_tax_p23",
                         "soli_p23", "church_tax_p23", "tax_p23", "capital_income", "abgeltung_burden", "church_tax_withheld_k",
                         "tariff_income_tax_k", "tariff_soli_k", "tariff_church_tax_k", "tariff_burden", "burden_without_gp",
                         "burden_with_gp", "guenstiger", "settlement", "refund", "church_tax_settlement_next_year")

"Tarifparameter für den Kern (R: `.wd_tariff_par`, `core/tariff_core_impl.h`)."
function _wd_tariff_par(tt, church_k::Float64, use_gp)
    z = tt["zones"]; so = tt["soli"]
    out = Float64[use_gp === true ? 1.0 : 0.0, church_k, 0.25 / (1 + 0.25 * church_k), Float64(so["freigrenze"]),
                  Float64(so["satz"]), Float64(so["milderung"]), Float64(length(z["ab"]))]
    for c in ("ab", "bezug", "teiler", "a", "b", "c")
        append!(out, Float64[Float64(v) for v in z[c]])
    end
    return out
end

"""zvE je Planjahr für den Tarifweg der Entnahme (R: `.wd_zve`): Zahl für alle Planjahre, Vektor ohne Namen der
Länge `ny`, nach Kalenderjahren benannt nur mit `year1`; Länge `ny + 1` (Folgejahr ggf. NA)."""
function _wd_zve(x, ny::Int, year1)
    who = "withdrawal_simulation"
    form = "eine Zahl (zvE in EUR für alle Planjahre), ein Vektor ohne Namen mit einem Wert je Planjahr (Länge $ny)" *
           (year1 === nothing ? "" : " oder nach Kalenderjahren benannt (Vektor bzw. data.frame mit den Spalten year und taxable_income; Planjahr 1 = $year1)")
    zv = SimLev._check_taxable_income(x, Int[], "income_tariff"; plan_ok = true)
    zv.all !== nothing && return fill(Float64(zv.all), ny + 1)
    if haskey(zv, :plan)
        v = zv.plan
        length(v) == ny && return vcat(Float64.(v), NA)
        _stop("$who: taxable_income (income_tariff()) hat $(length(v)) Werte, die Entnahme $ny Planjahre; erwartet wird $form.")
    end
    year1 === nothing &&
        _stop("$who: taxable_income (income_tariff()) nach Kalenderjahren lässt sich nur mit einem SimLevResult als start_value auf Planjahre abbilden (Planjahr 1 = tax_report\$next_year\$year); erwartet wird $form.")
    zv = SimLev._check_taxable_income(x, collect(year1:(year1 + ny - 1)), who)
    return Float64[get(zv.by_year, string(y), NA) for y in year1:(year1 + ny)]
end

"""Jahreszeilen des Tarifwegs als RFrame (R: `.wd_tariff_years`): `path`, `year` (Planjahr) und die Spalten von
`tax_report["tariff_years"]` aus `simulation()`, nach Pfad und Jahr."""
function _wd_tariff_years(M::Matrix{Float64}, ny::Int)
    keep = findall(!isnan, M[1, :])
    cols = Pair{String,Any}["path" => Int[(k - 1) ÷ (ny + 1) + 1 for k in keep]]
    for (j, c) in enumerate(_WD_TARIFF_COLS)
        col = M[j, keep]
        push!(cols, c => (c == "year" ? Int[Int(v) for v in col] : c == "guenstiger" ? Bool[v != 0 for v in col] : col))
    end
    return RFrame(cols...; class = ["data.frame"])
end

"""
    withdrawal_simulation(x, rule = withdrawal_rule("constant"); start_value = 1e6, inflation = 0,
                          frequency = "year", strategy = nothing, years = nothing, timing = "start",
                          income = nothing, tax = nothing, partial_exemption = 30,
                          base_rate = 3.20, vorabpauschale = true, sale_cost = 0,
                          cost_basis = 100, loss_carryforward = 0, gamma = 2, keep_paths = true, horizon = nothing)

Entnahme-Simulation über viele Pfade.

Simuliert eine Entnahmeregel auf historischen Kohorten (`withdrawal_cohorts()`), Bootstrap-Pfaden
(`withdrawal_paths()`, `bootstrap_pooled()`), gespeicherten Ergebnissen von `simulation()` bzw.
`bootstrap_study()` oder einer beliebigen Renditematrix. Je Pfad entstehen Erfolg, Erschöpfungsjahr, reales
Endvermögen, Konsumkennzahlen, Steuern und die Perfect Withdrawal Rate. Der Rechenkern ist in C++
implementiert.

# Argumente
- `x`: Renditequelle, eine der folgenden:

  - `withdrawal_paths`: aus `withdrawal_cohorts()`, `withdrawal_paths()` oder `bootstrap_pooled()`; Inflation
    und Frequenz stammen aus dem Objekt (`inflation` und `frequency` werden ignoriert).
  - Matrix: (Perioden x Pfade) von Brutto-Periodenrenditen nach Produktkosten (1.05 = +5 Prozent); keine
    negativen Werte, Median >= 0.5.
  - `SimLevResult`: historische Kohorten über dessen Verlauf, Länge `years` (Standard 30 Jahre).
  - `SimLevWrapperNav`: Anteilswert eines Fonds-Wrappers aus `wrapper_nav()`: historische Kohorten über die
    Spalte `nav` wie `withdrawal_cohorts(x, price = "nav")`, Länge `years` (Standard 30 Jahre). Nur das ganze
    Objekt: Ein Ausschnitt (`x[i, ]`, `head()`, `subset()`) ist ein gewöhnlicher `data.frame`; Tabellen mit
    Spalte `date` ergeben einen Fehler mit Hinweis auf `withdrawal_cohorts(x, price = "nav")`.
  - Liste von `SimLevResult` oder `SimLevBootstrapStudy`: (mit `keep_returns`; Strategie über `strategy`) je
    Element bzw. Studienpfad ein Pfad.
- `rule`: Objekt aus `withdrawal_rule()` (Standard: konstante reale Entnahme mit 4 %).
- `start_value`: Startvermögen als Geldbetrag > 0 (Standard 1e6) oder ein `SimLevResult` der Ansparphase: dann
  gilt dessen letzter Depotwert (Stück x Schlusskurs ohne Spread plus Cash) als Startvermögen (ein Endwert <=
  0, etwa durch eine offene Steuerschuld `tax_report["open_tax_debt"]`, ist ein Fehler) und, sofern
  `cost_basis` nicht angegeben ist, wird `cost_basis` daraus abgeleitet (siehe dort). Mit Steuern (`tax =
  tax_profile()`) wird gewarnt, wenn die am Ende gehaltenen Assets eine andere Teilfreistellung als
  `partial_exemption` haben (Regime `"capital_gains"` zählt als 0 %) oder das Regime `"private_sale"` (§ 23
  EStG) haben, das die Entnahmephase nicht abbildet. Mit Steuern werden außerdem die Lots (FIFO, siehe
  Details) und nicht angegebene `partial_exemption`, `loss_carryforward` und `sale_cost` aus dem Ergebnis
  übernommen (siehe dort); was übernommen wurde, meldet ein Hinweis (`message()`) und steht im Ergebnis unter
  `adopted`. Ausdrückliche Angaben haben immer Vorrang.
- `inflation`: Inflation für Eingaben ohne eigene Inflationsreihe: Zahl = konstante Inflation in Prozent p. a.
  (Standard 0; 2 = 2 % p. a.) bei Matrix-, Ergebnis-, Ergebnislisten- und Studien-Eingabe; bei Matrix-Eingabe
  auch eine Matrix gleicher Dimension mit Brutto-Periodeninflation (z. B. 1.002 je Monat); bei Studien auch
  der Name einer mit `keep_aux` gespeicherten Zusatzreihe (Behandlung wie in `withdrawal_paths()` ohne
  `inflation_type`: eine Reihe mit `aux_type = "rate"` in `bootstrap_config()` gilt als Inflationsrate in
  Prozent pro Jahr, 2 = 2 % p. a., nicht je Datenperiode, kein Anteil, über die Kalendertage aufgezinst; ohne
  Angabe in `aux_type` wie bisher die gespeicherte Niveau-Variante). `nothing` wie 0. Bei `withdrawal_paths`
  ohne Wirkung.
- `frequency`: Periodenlänge der Zeilen bei Matrix-Eingabe bzw. der erzeugten Perioden bei Ergebnis- und
  Ergebnislisten-Eingabe: `"year"` (Standard), `"quarter"` oder `"month"`. Bei `withdrawal_paths` und Studien
  gilt die gespeicherte Frequenz.
- `strategy`: Bei `SimLevBootstrapStudy`: Name der Strategie (`nothing` = erste gespeicherte).
- `years`: Optional Anzahl Jahre (> 0, `years` x Perioden je Jahr muss ganzzahlig sein): Kürzung auf die
  ersten `years` Jahre (`years` x Perioden je Jahr Zeilen). Bei einem `SimLevResult` zugleich die
  Kohortenlänge (`nothing` = 30). `nothing` (Standard) = volle Pfadlänge.
- `timing`: Zeitpunkt der Entnahme innerhalb jeder Periode: `"start"` (Standard; vor der Rendite) oder `"end"`
  (nach der Rendite).
- `income`: Optional weitere Einkommen (z. B. gesetzliche Rente): Liste von Listen `(start = Jahr, end = Jahr,
  amount = Betrag)`; ein einzelnes `RList("start" => …, "end" => …, "amount" => …)` wird automatisch verpackt.
  `start`/`end` sind Planjahre (Standard 1 bzw. letztes Jahr, `start <= end`; Jahre nach dem Pfadende
  entfallen), `amount` ist ein realer Jahresbetrag in Kaufkraft des Startzeitpunkts. Einkommen mindern die
  Depotentnahme (Entnahme = max(0, Regelbetrag - Einkommen)) und zählen im Konsum (`spending`) mit.
- `tax`: Steuerdaten der Person: `nothing` (Standard; keine Steuern) oder ein Objekt aus `tax_profile()`
  (vereinfachte deutsche Besteuerung, siehe Details). Ausgewertet werden `rate` (Abgeltungsteuer inkl.
  Solidaritätszuschlag in Prozent, Standard 26.375), `church_tax` (Kirchensteuer in Prozent; der Satz der
  Abgeltungsteuer folgt dann § 32d Abs. 1 EStG wie in `simulation()`), `guenstigerpruefung` mit `income =
  income_rate()` (Günstigerprüfung wie in `simulation()`: einmal je Lauf; ist der Grenzsteuersatz
  einschließlich Soli und Kirchensteuer niedriger als die Abgeltungsteuer, gilt er für alle Verkäufe und
  Vorabpauschalen aller Pfade und Planjahre; ohne `income` Warnung und Abgeltungsteuer; `income_rate()` ohne
  `guenstigerpruefung = true` wirkt nicht) und `sparer_pauschbetrag` (Sparer-Pauschbetrag je Planjahr als
  nominaler Geldbetrag, Standard 1000; 2000 bei Zusammenveranlagung; 0 = ohne). Bei `start_value` =
  `SimLevResult` mit `tax_report["next_year"]` steht im ersten Planjahr nur dieser Betrag minus
  `next_year["sparer_pauschbetrag_used"]` zur Verfügung (siehe Details, Kalender; bei gleichem Pauschbetrag
  wie in der Ansparphase `next_year["sparer_pauschbetrag_remaining"]`). Angaben, die die Entnahmephase nicht
  abbildet (`private_sale_threshold` ungleich 1000, `base_rate`, `harvest`), ergeben einen Fehler; der
  Basiszins kommt aus `base_rate` dieser Funktion. Mit `income = income_tariff(taxable_income, tariff)`
  rechnet die Entnahmephase den Tarifweg wie `simulation()`: unterjährig Abgeltungsteuer, nach jedem Planjahr
  je Pfad eine Veranlagung (siehe Details, Tarifweg). `taxable_income` ist das zu versteuernde Einkommen ohne
  die Erträge der Entnahme, nominal in EUR genau wie angegeben (ohne Fortschreibung mit der Inflation): eine
  Zahl gilt für alle Planjahre, ein Vektor ohne Namen braucht einen Wert je Planjahr; nach Kalenderjahren
  benannt (Vektor oder Tabelle (RFrame) wie in `simulation()`) nur mit einem `SimLevResult` als `start_value`
  (Planjahr 1 = `tax_report["next_year"]\$year`), sonst Fehler. `income` dieser Funktion zählt nicht zum zvE;
  einen steuerpflichtigen Teil (etwa einer Rente) selbst in `taxable_income` einrechnen. Kirchensteuer und
  Günstigerprüfung werden nicht aus der Ansparphase (`start_value` = `SimLevResult`) übernommen, sondern hier
  ausdrücklich in `tax_profile()` angegeben. Die Bestandsmerkmale (`partial_exemption`, `vorabpauschale`,
  `cost_basis`, `loss_carryforward`, `sale_cost`) sind eigene Argumente. Wie in `simulation()` sind
  `partial_exemption`, `sale_cost`, `cost_basis`, `loss_carryforward` und `gamma` einzelne endliche Zahlen im
  zulässigen Bereich (sonst Fehler); Werte zwischen 0 und 1 bei `partial_exemption` und `cost_basis` sowie
  zwischen 0 und 0,05 bei `inflation` (Zahl) und `base_rate` (Zahl) lösen eine Warnung aus (vermutlich Anteil
  statt Prozent).
- `partial_exemption`: Teilfreistellung in Prozent (Standard 30 für Aktienfonds; 15 für Mischfonds). Nicht
  angegeben und `start_value` ein `SimLevResult` mit `open_lots`: die gemeinsame Teilfreistellung der am Ende
  gehaltenen Assets (Regime `"capital_gains"` = 0), sofern alle denselben Wert haben und keines das Regime
  `"private_sale"` hat und keine Fonds neben anderen Regimen gehalten werden; sonst 30 mit Warnung. Als
  gehalten gelten Assets mit Endwert > 1e-12 x Depotwert (Stückreste ohne Wert zählen nicht).
- `base_rate`: Basiszins für die Vorabpauschale in Prozent (Standard 3.20 für 2026; negative Werte zählen als
  0): Skalar oder Matrix (Perioden x Pfade, gleiche Dimension wie die Renditen vor einer Kürzung mit `years`),
  maßgeblich ist der Wert der letzten Periode jedes Planjahres. Enthält `x` eine Basiszins-Reihe (Argument
  `base_rate` in `withdrawal_cohorts()`), wird diese verwendet.
- `vorabpauschale`: Logisch: Vorabpauschale berücksichtigen (Standard `true`; nur mit `tax = tax_profile()`
  wirksam). Nicht angegeben und `start_value` ein `SimLevResult` mit `open_lots`, in dem kein gehaltenes Asset
  das Regime `"investment_fund"` hat (nur ETN/Zertifikate, `"capital_gains"`, bzw. `"private_sale"`): `false`,
  da `simulation()` dort keine Vorabpauschale erhebt. Bei Fonds neben anderen Regimen Warnung, keine
  Übernahme.
- `sale_cost`: Verkaufskosten in Prozent des Verkaufsbetrags (Standard 0; z. B. halber Spread). Nicht
  angegeben und `start_value` ein `SimLevResult` mit `open_lots`: der halbe Spread (`spread`) der am Ende
  gehaltenen Assets, sofern alle denselben Spread haben (sonst 0 mit Warnung; ohne Spread-Angabe im Ergebnis
  0). Ordergebühren bildet die Entnahmephase nicht ab; waren sie in der Ansparphase gesetzt, warnt die
  Funktion.
- `cost_basis`: Anschaffungskosten in Prozent des Startwerts (Standard 100 = frisch gekauft; kleiner bei
  Altbestand mit stillen Reserven), einschließlich bereits versteuerter Vorabpauschalen, die beim Verkauf nach
  § 19 InvStG angerechnet werden. Mit `cost_basis` rechnet die Entnahmephase mit Durchschnittskosten: jede
  Entnahme verbraucht den Anteil Entnahme / Depotwert der Basis. Ein ausdrücklich angegebener Wert gilt immer
  (auch bei einem `SimLevResult`; dann ohne FIFO-Lots). Ist `start_value` ein `SimLevResult` und `cost_basis`
  nicht angegeben:

  - nur Cash am letzten Tag: (z. B. `liquidate = true`): 100, alle Gewinne sind bereits versteuert.
  - mit offenen Lots: (Element `open_lots`, nur Ergebnisse mit `simulation(tax = tax_profile())`): mit `tax =
    tax_profile()` die Lots selbst (FIFO, siehe Details); ihre Summe entspricht 100 x (Anschaffungskosten
    `units` x `price` plus anzurechnende Vorabpauschalen `vp` aller Assets plus Cash) / Endwert. Ein Verkauf
    ergibt dieselbe Steuer wie in `simulation()` beim Verkauf derselben Stückzahl, wenn `sale_cost` dem halben
    Spread entspricht, keine Ordergebühr anfällt, alle Assets die Teilfreistellung `partial_exemption` haben
    und Topf und Sparer-Pauschbetrag gleich stehen.
  - sonst: (Ergebnis ohne Steuern oder älter): die Näherung 100 x (Startwert brutto + Summe der Einzahlungen)
    / Endwert, mit Warnung bei `tax = tax_profile()`. Sie behandelt bereits realisierte (und versteuerte)
    Gewinne, Vorabpauschalen und Cash wie stille Reserven und überschätzt die spätere Steuer dann.
- `loss_carryforward`: Anfangsbestand des Verlusttopfs als nominaler Geldbetrag (Standard 0; Betrag nach
  Teilfreistellung wie in `simulation()`). Nicht angegeben und `start_value` ein `SimLevResult` mit
  `open_lots`: der allgemeine Verlusttopf (Topf für Fonds und sonstige Kapitalerträge) zu Beginn des ersten
  Planjahres, `tax_report["next_year"]\$loss_carryforward_capital` (ältere Ergebnisse ohne `next_year`:
  `tax_report["loss_carryforward_capital"]`); der Verlustvortrag für private Veräußerungsgeschäfte wird nicht
  übernommen.
- `gamma`: Relative Risikoaversion (CRRA, Zahl, Standard 2) für das Sicherheitsäquivalent der realen
  jährlichen Konsumreihe (`gamma = 1`: geometrisches Mittel).
- `keep_paths`: Vermögensmatrix `wealth` zurückgeben: `true` (Standard) = alle Pfade, `false` oder 0 = keine,
  ganze Zahl k >= 1 = die ersten k Pfade (Spalten; k größer als die Pfadzahl: alle). Gerechnet werden immer
  alle Pfade; `plot()` zeichnet den Vermögensfächer dann nur aus den behaltenen Pfaden (Titel mit „erste k von
  n Pfaden“). Bei historischen Kohorten sind das die frühesten Starts.
- `horizon`: Optional Laufzeit je Pfad: Objekt aus `withdrawal_horizon()` (zufällige Laufzeit in Jahren je
  Pfad) oder eine Zahl > 0 = feste Laufzeit in Jahren. `nothing` (Standard) = volle Pfadlänge. Dann gilt ein
  Pfad als erfolgreich, wenn das Vermögen bis zu seinem Horizont reicht; reales Endvermögen, Steuern,
  Konsumkennzahlen und PWR (diese nur bei Jahresperioden, sonst `NA`) beziehen sich auf den jeweiligen
  Horizont; Endvermögen und Steuern enthalten dabei die Abrechnung der Vorabpauschale des Horizontjahres wie
  am Pfadende (ein Pfad mit H Jahren und Horizont H auf längeren Pfaden ergeben dasselbe) (`paths["horizon"]`,
  Erfolg über die volle Pfadlänge in `paths["success_full"]`). Horizonte über der Pfadlänge werden mit Warnung
  gekürzt. Die Regel selbst rechnet weiter mit den Restjahren der vollen Pfadlänge. Nicht zu verwechseln mit
  `horizon` in `planning_goal()` (Perioden).

# Rückgabe
Objekt der Klasse `SimLevWithdrawal` (Liste):

- `paths`: Tabelle (RFrame) mit einer Zeile je Pfad: `success` (logisch: alle geplanten Entnahmen voll bezahlt
  bzw. planmäßig vollständig geleert, siehe Details), `depletion_year` (Planjahr der ersten Unterdeckung,
  sonst `NA`), `terminal_real` (reales Endvermögen), `terminal_nominal` (nominales Endvermögen am Pfadende),
  `first_withdrawal` (realer Konsum im ersten Planjahr), `mean_spending`, `min_spending`, `total_spending`
  (Mittel, Minimum, Summe des realen Jahreskonsums), `spending_drawdown` (größter Rückgang des realen Konsums
  gegenüber dem bisherigen Höchststand, als Anteil 0 bis 1), `ce_spending` (Sicherheitsäquivalent nach
  `gamma`); Mittel, Minimum, Rückgang und Sicherheitsäquivalent nur über volle Planjahre (ein unvollständiges
  letztes Planjahr zählt nur in `total_spending`; ohne volles Jahr `NA`), `taxes` (Summe der Steuern, real)
  und `pwr` (Perfect Withdrawal Rate in Prozent); bei Kohorten zusätzlich `start` (Startdatum), mit `horizon`
  zusätzlich `horizon` (Jahre) und `success_full`.
- `spending`: Matrix Planjahre x Pfade: realer Konsum (Netto-Entnahme plus `income`).
- `planned`: Matrix Planjahre x Pfade: von der Regel geplante Jahresentnahme (real, vor Abzug von `income`).
- `wealth`: Matrix (Planjahre + 1) x Pfade: reales Vermögen zu Beginn jedes Planjahres, letzte Zeile am Ende;
  mit `keep_paths = k` nur die ersten k Spalten, `nothing` bei `keep_paths = false`.
- `rule`, `start_value`, `frequency`, `horizon`, `tax_mode` (`"person"` mit `tax`, sonst `"none"`), `gamma`,
  `timing`: Eingaben.
- `years`, `full_years`: Anzahl Planjahre (einschließlich eines unvollständigen letzten Jahres) bzw. voller
  Planjahre.
- `historical`: `true` bei historischen Kohorten.
- `adopted`: Nur bei `start_value` = `SimLevResult` und `tax = tax_profile()`: benannte Liste der aus der
  Ansparphase übernommenen Werte (`lots` = Anzahl FIFO-Lots einschließlich Cash-Position, `cost_basis` bei
  Durchschnittskosten, `partial_exemption`, `loss_carryforward`, `sale_cost`, `sparer_pauschbetrag_used_year1`
  = im ersten Planjahr bereits verbrauchter Pauschbetrag, `vorabpauschale` = `false` ohne gehaltene Fonds);
  sonst `nothing`.
- `weights`: Pfadgewichte (Standard 1 je Pfad).
- `source`: Herkunft der Renditen.
- `elapsed`: Rechenzeit in Sekunden (ab Start des Kerns).
- `tariff_years`: Nur mit dem Tarifweg (`income_tariff()`): Tabelle (RFrame) mit einer Zeile je Pfad und
  veranlagtem Planjahr, nach Pfad und Jahr: `path`, `year` (Planjahr; Planjahre + 1 = Folgejahr am Pfadende)
  und dieselben Spalten wie `tax_report["tariff_years"]` in `simulation()` (zvE, Kirchensteuer-Sonderausgaben
  und ihre Wirkung, § 23-Spalten, in der Entnahme 0, `capital_income` = K, Abgeltungsteuer, Tarif auf K,
  Belastung ohne und mit Günstigerprüfung, `guenstiger`, `settlement` > 0 Nachzahlung bzw. < 0 Erstattung,
  `refund`, `church_tax_settlement_next_year`); Beträge nominal in EUR.

Auswertung mit `print()`, `summary()` und `plot()` (siehe SimLevWithdrawal-methods).

# Details
Ablauf je Planjahr: Zu Beginn legt die Regel den Jahresbetrag fest; er wird gleichmäßig auf die Perioden des
Jahres verteilt und je nach `timing` zu Beginn oder Ende jeder Periode als Netto-Betrag entnommen (abzüglich
`income`). Ein Pfad scheitert, sobald eine geplante Entnahme nicht mehr voll bezahlt werden kann. Ausnahme
Verzehrregeln (`one_over_n`, `vpw`, `abw`, `hebeler`): Sie leeren das Depot planmäßig im letzten Planjahr bzw.
in dem Jahr, für das sie das ganze Depot vorsehen (Jahresbetrag >= Depotwert zu Jahresbeginn, z. B. `vpw` bei
Erreichen von `max_age`). Wird das Depot in einem solchen Jahr vollständig verkauft und fällt die Entnahme
dabei kleiner aus (Steuern und Kosten aus dem Erlös bezahlt, bei unterjährigen Perioden auch Kursverluste im
Jahr), ist das kein Fehlschlag, sofern der Jahresbetrag das Depot zu Jahresbeginn nicht übersteigt (sonst, z.
B. bei `hebeler` durch die Glättung, bleibt es ein Fehlschlag). Bei allen anderen Regeln zählt jede nicht voll
bezahlte Entnahme als Fehlschlag. Alle "realen" Größen sind durch die aufgelaufene Inflation geteilt, also in
Kaufkraft des Startzeitpunkts.

Besteuerung (`tax = tax_profile()`): vereinfachtes Modell eines einzelnen thesaurierenden Fondsbestands nach
heutiger Rechtslage (Modellphilosophie des Pakets): Verkaufsgewinne mit Teilfreistellung, Verlustverrechnung
vor Sparer-Pauschbetrag, Abgeltungsteuer; Vorabpauschale zum Jahresende festgesetzt; sie gilt nach § 18 Abs. 3
InvStG am ersten Werktag des Folgejahres als zugeflossen und wird daher wie in `simulation()` mit Verlusttopf
und Sparer-Pauschbetrag des Folgejahres versteuert, durch Anteilsverkauf beglichen und beim späteren Verkauf
angerechnet. Die Vorabpauschale des letzten Planjahres wird am Pfadende abgerechnet wie in `simulation()` bei
Datenende am 31.12.: die Steuer auf die VP wird vorab mit den Töpfen des Folgejahres (neuer Pauschbetrag,
Verlusttopf am Jahresende) bestimmt und per Zwangsverkauf noch im ablaufenden Jahr bezahlt (Gewinn mit dessen
Pauschbetrag und Verlusttopf); danach wird die VP-Steuer mit dem Verlusttopf nach diesem Verkauf endgültig
berechnet und die Differenz ausgeglichen (Nachzahlung per Verkauf im Folgejahr, Erstattung als Geld ins
Depot). Alle diese Steuern mindern das Endvermögen und zählen in `taxes`; ebenso beim Endvermögen am Horizont
(`horizon`). Während des Pfades wird die VP-Steuer dagegen zusammen mit der ersten Entnahme des Folgejahres
verkauft (Töpfe des Folgejahres). Ohne Lots einer Ansparphase rechnet der Kern mit Durchschnittskosten
(`cost_basis`); bei einer Einmalanlage ohne Zukäufe ist das identisch mit FIFO. Das Planjahr wird als
Steuerjahr behandelt; der Sparer-Pauschbetrag steht in jedem Planjahr neu und nominal unverändert zur
Verfügung.

FIFO mit den Lots einer Ansparphase: Ist `start_value` ein `SimLevResult` mit `open_lots` (gerechnet mit `tax
= tax_profile()`), `cost_basis` nicht angegeben und `tax = tax_profile()`, übernimmt die Entnahmephase die
einzelnen Lots: je Asset in FIFO-Reihenfolge mit Anschaffungskosten (`units` x `price`) und anzurechnender
Vorabpauschale (`vp`); der Wert eines Lots ist sein Stückanteil am Endwert des Assets. Ein Verkauf nimmt jedem
Asset seinen Wertanteil am Depot (die Entnahmephase hat nur eine Renditereihe, die Anteile bleiben daher
konstant) und innerhalb des Assets die ältesten Lots zuerst; Gewinn je Lot = Erlös x (1 - `sale_cost` / 100)
minus Anschaffungskosten minus anteilige Vorabpauschale (§ 19 InvStG), die Gewinne aller verkauften Lots
werden summiert und mit Teilfreistellung `partial_exemption`, Verlusttopf, Sparer-Pauschbetrag und Steuersatz
`rate` besteuert (wie `simulation()` je Verkauf, siehe dort `open_lots`). Cash am Ende der Ansparphase ist
eine eigene Position mit Basis = Betrag, die wie bisher mit der Depotrendite wächst und anteilig verkauft
wird. Neue Vorabpauschalen sind je Anteil für alle Lots gleich: es gibt keine Zukäufe, jedes Lot wird
ganzjährig gehalten, und alle Assets haben dieselbe Rendite (in `simulation()` hängt die VP je Stück nur vom
Kursverlauf des Jahres und der Haltedauer ab). Einkommen mindern nur die Entnahme, Umschichtungen gibt es in
der Entnahmephase nicht; die Lots werden also nur durch Verkäufe und Vorabpauschalen fortgeschrieben.

Tarifweg (`tax = tax_profile(income = income_tariff())`): Verkäufe und Vorabpauschalen werden unterjährig mit
der Abgeltungsteuer belastet. Nach jedem Planjahr folgt je Pfad eine Veranlagung wie der Jahresabschluss von
`simulation()` mit einem festen Tarif aus `tax_tariff()`: Kapitalerträge K = mit Abgeltungsteuer belastete
Bemessungsgrundlage des Planjahres (nach Teilfreistellung, Verlusttopf und Sparer-Pauschbetrag; die
Vorabpauschale zählt im Jahr ihres Zuflusses), Kirchensteuer als Sonderausgabe im Zahlungsjahr (Saldo des
Bescheids des Vorjahres; im ersten Planjahr 0), mit `guenstigerpruefung = true` der Vergleich mit dem Tarif
auf zvE + K. Der Saldo (Nachzahlung bzw. Erstattung) wird mit der ersten Entnahme des Folgejahres gezahlt bzw.
mindert sie (wie die Steuer auf die Vorabpauschale); eine Erstattung über diese Entnahme hinaus fließt als
Geld ins Depot. Am Pfadende und am Horizont wird das letzte Planjahr sofort veranlagt und abgerechnet wie in
`simulation()` am letzten Tag (der Zwangsverkauf für die Vorabpauschale zählt zu diesem Jahr); mit
Günstigerprüfung wird die Vorabpauschale des letzten Planjahres (Zufluss im Folgejahr) zusätzlich für das
Folgejahr veranlagt, sofern dafür ein zvE vorliegt (eine Zahl für alle Jahre bzw. ein benannter Wert für
dieses Kalenderjahr). Nachzahlungen werden per Verkauf, Erstattungen als Geld ins Depot abgerechnet; alle
Salden zählen in `taxes`. Ohne Kirchensteuer und ohne Günstigerprüfung ist der Saldo stets 0. Die Jahreszeilen
stehen im Ergebnis unter `tariff_years`.

Kalender: Die Entnahmephase kennt keine Kalenderjahre; ihr erstes Planjahr gilt als das Jahr nach dem letzten
Datentag der Ansparphase (`tax_report["next_year"]\$year`), jedes weitere Planjahr als ein neues Steuerjahr.
Was `simulation()` diesem Jahr schon zugerechnet hat (endet die Ansparphase am 31.12.: die dort festgesetzte
und im Folgejahr verrechnete Vorabpauschale), geht ein: im ersten Planjahr steht nur `sparer_pauschbetrag`
minus `next_year["sparer_pauschbetrag_used"]` zur Verfügung, der Verlusttopf beginnt mit
`next_year["loss_carryforward_capital"]`.

Grenzen gegenüber `simulation()`: (1) Verluste: Die Entnahmephase saldiert Gewinne und Verluste der Lots eines
Verkaufs sofort und trägt einen verbleibenden Verlust in den Topf vor; eine Erstattung bereits versteuerter
Erträge desselben Jahres gibt es nicht. `simulation()` besteuert jeden Verkauf eines Assets einzeln und
erstattet zum Jahresende Steuer auf im Jahr versteuerte Erträge, wenn später im Jahr Verluste entstehen
(unterjährige Verlustverrechnung, mit Freigabe des Pauschbetrags). Gleich sind beide, solange in einem
Planjahr alle Verkäufe Gewinne ergeben. (2) Steuersatz: die Entnahmephase rechnet mit einem festen Satz aus
`tax_profile()` (`rate` bzw. mit `church_tax` der Satz nach § 32d Abs. 1 EStG, mit `guenstigerpruefung` und
`income_rate()` gegebenenfalls der persönliche Satz). Kirchensteuer und Günstigerprüfung der Ansparphase
werden nicht übernommen; sie sind in `tax` ausdrücklich anzugeben. Mit dem Tarifweg (`income_tariff()`) gilt
unterjährig die Abgeltungsteuer und je Planjahr eine Veranlagung (siehe Tarifweg); das zvE gilt für alle Pfade
gleich, wird nicht mit der Inflation fortgeschrieben, und `income` zählt nicht dazu. (3) Ordergebühren beim
Verkauf bildet die Entnahmephase nicht ab (Warnung, wenn sie in der Ansparphase gesetzt waren). (4)
Verschiedene Teilfreistellungen, Regime `"capital_gains"` neben Fonds und `"private_sale"` (§ 23 EStG) werden
nicht getrennt besteuert (Warnung); Teilfreistellung und Vorabpauschale gelten für den ganzen Bestand. (5)
Positionen ohne Wert (Endwert <= 1e-12 x Depotwert, etwa nach Knockout) entfallen; ein Verlust aus ihrem
Verkauf entsteht in der Entnahmephase nicht.

Renditequellen: Die Entnahmephase ist bewusst von `simulation()` getrennt. Ein gespeichertes Ergebnis von
`simulation()` (etwa per `saveRDS()`) liefert über seinen zeitgewichteten Wertindex (`result_index()`) die
Renditen; bei einem Einzelergebnis werden daraus historische Kohorten gebildet (wie `withdrawal_cohorts()` mit
monatlichen Starts), eine Liste von Ergebnissen (z. B. je Bootstrap-Pfad) oder eine `bootstrap_study()` mit
`keep_returns` liefert je Element einen Pfad (über `withdrawal_paths()`). Ein `bootstrap_result` aus
`bootstrap()` zuerst mit `withdrawal_paths()` umwandeln. Wurde das Quellergebnis bereits mit Steuern (`tax =
tax_profile()`) gerechnet, enthält der Index schon Vorabpauschalen; dann hier `vorabpauschale = false` setzen
oder die Quelle ohne Steuern rechnen (bei Ergebnissen und Ergebnislisten erscheint dazu eine Warnung).

# Beispiel
```julia
using SimLev, Random
rng = MersenneTwister(1)
R = exp.(0.05 .+ 0.15 .* randn(rng, 30, 200))   # 30 Jahre, 200 Pfade
ws = withdrawal_simulation(R, withdrawal_rule("guyton_klinger"; rate = 5); start_value = 1e6, inflation = 2)
println(ws)
```
"""
function withdrawal_simulation(x, rule_pos = _MISSING; rule = _MISSING, start_value = 1e6, inflation = 0,
                               frequency = nothing, strategy = nothing, years = nothing, timing = nothing,
                               income = nothing, tax = nothing, partial_exemption = _MISSING,
                               base_rate = 3.20, vorabpauschale = _MISSING,
                               sale_cost = _MISSING, cost_basis = _MISSING, loss_carryforward = _MISSING,
                               gamma = 2, keep_paths = true, horizon = nothing)
    x = SimLev.as_rframe(x)
    rule_pos === _MISSING || (rule = rule_pos)
    rule === _MISSING && (rule = withdrawal_rule("constant"))
    ab_missing = partial_exemption === _MISSING; vp_missing = vorabpauschale === _MISSING
    sc_missing = sale_cost === _MISSING; cb_missing = cost_basis === _MISSING; lc_missing = loss_carryforward === _MISSING
    partial_exemption = _num(_dflt(partial_exemption, 30.0)); vorabpauschale = _dflt(vorabpauschale, true)
    sale_cost = _num(_dflt(sale_cost, 0.0)); cost_basis = _num(_dflt(cost_basis, 100.0))
    loss_carryforward = _num(_dflt(loss_carryforward, 0.0))
    freq_arg = frequency
    timing = _match_arg(timing, ("start", "end"))
    tax_mode = _wd_tax_mode(tax)
    # Satz wie in simulation() (_tax_rates: Kirchensteuer, Günstigerprüfung einmal je Lauf); die Angaben stehen
    # ausdrücklich in tax_profile(), aus der Ansparphase wird nichts übernommen
    # Tarifweg (income_tariff()): unterjährig Abgeltungsteuer, Veranlagung je Planjahr und Pfad im Kern
    tariff_on = tax !== nothing && tax["income"] isa RList && SimLev.inherits(tax["income"], "SimLevIncomeTariff")
    tax_rate = if tax === nothing
        26.375 / 100
    else
        ti = tax["income"]
        ir = ti isa RList && SimLev.inherits(ti, "SimLevIncomeRate")
        SimLev._tax_rates(tax["rate"], tax["church_tax"], tax["guenstigerpruefung"], ir ? ti["marginal_rate"] : nothing,
                          ir && ti["soli_rate"] != 0, ir ? ti["soli_rate"] : 5.5,
                          "withdrawal_simulation"; tariff_on = tariff_on).effective_tax_rate
    end
    sparer_pauschbetrag = tax === nothing ? 1000 : tax["sparer_pauschbetrag"]
    if horizon !== nothing && !_is_horizon(horizon)
        if !_num1(horizon) || _f1(horizon) <= 0
            _stop(@sprintf("withdrawal_simulation: 'horizon' muss NULL, ein Objekt aus withdrawal_horizon() oder eine Zahl von Jahren > 0 sein, nicht %s.",
                           _show(horizon)))
        end
        horizon = withdrawal_horizon("fixed"; years = horizon)
    end
    _is_rule(rule) || _stop("rule muss mit withdrawal_rule() erstellt werden.")
    inflation === nothing && (inflation = 0)
    function chk(v, arg, what; lo = 0.0, hi = Inf)
        if !_num1(v) || _f1(v) < lo || _f1(v) > hi
            _stop(@sprintf("withdrawal_simulation: '%s' muss %s sein, nicht %s.", arg, what, _rshow(v)))
        end
    end
    function frac(v, arg; hi = 1.0, unit = "%")
        if _num1(v) && 0 < _f1(v) < hi
            _warn(@sprintf("withdrawal_simulation: %s = %s wird als %s %s gelesen (Prozent-Konvention); gemeint war vermutlich %s.",
                           arg, _fmt1(_num(v)), _fmt1(_num(v)), unit, _fmt1(_f1(v) * 100)))
        end
    end
    chk(partial_exemption, "partial_exemption", "eine Zahl von 0 bis 100 in Prozent (z. B. 30)"; lo = 0.0, hi = 100.0); frac(partial_exemption, "partial_exemption")
    chk(sale_cost, "sale_cost", "eine Zahl von 0 bis unter 100 in Prozent (z. B. 0.1)"; lo = 0.0, hi = 99.999)
    chk(cost_basis, "cost_basis", "eine Zahl >= 0 in Prozent des Startwerts (z. B. 100)"); frac(cost_basis, "cost_basis")
    chk(loss_carryforward, "loss_carryforward", "eine Zahl >= 0 (EUR)")
    chk(gamma, "gamma", "eine Zahl >= 0 (relative Risikoaversion, z. B. 2)")
    vorabpauschale isa Bool || _stop(@sprintf("withdrawal_simulation: '%s' muss TRUE oder FALSE sein, nicht %s.", "vorabpauschale", _rshow(vorabpauschale)))
    kp = _keep_count(keep_paths, Inf, "withdrawal_simulation")   # Anzahl behaltener Pfade, begrenzt nach ncol(R)
    infl_is_mat = inflation isa AbstractMatrix
    if (_isnum(inflation)) || (inflation isa AbstractVector && length(inflation) == 1 && _numvec(inflation) !== nothing)
        chk(inflation, "inflation", "eine Zahl in Prozent p. a. über -100 (z. B. 2) oder eine Matrix"; lo = -99.999)
        frac(inflation, "inflation"; hi = 0.05, unit = "% p. a.")
    end
    br_is_mat = base_rate isa AbstractMatrix
    br_is_mat || frac(base_rate, "base_rate"; hi = 0.05)
    if years !== nothing && (!_num1(years) || _f1(years) <= 0)
        _stop(@sprintf("years muss eine positive Zahl von Jahren sein (erhalten: %s).", _show(years)))
    end
    (!br_is_mat && !_num1(base_rate)) && _stop("base_rate muss eine Zahl (Prozent) oder eine Matrix Perioden x Pfade sein.")
    if income isa Union{RList,NamedTuple,AbstractDict} && _get(income, "amount") !== nothing &&
       !(_get(income, "amount") isa Union{RList,NamedTuple,AbstractDict})
        income = Any[income]
    end
    if income !== nothing
        okinc = income isa AbstractVector && all(e -> e isa Union{RList,NamedTuple,AbstractDict} && _num1(_get(e, "amount")), income)
        okinc || _stop("income muss eine Liste von list(start = Jahr, end = Jahr, amount = Betrag) sein (amount: realer Jahresbetrag).")
    end
    lots = nothing
    adopted = RList()
    spb_used1 = 0.0
    year1 = nothing
    if _is_result(start_value)
        sres = start_value
        ny1_ = _get(_get(sres, "tax_report"), "next_year")
        y1_ = ny1_ isa Union{RList,NamedTuple,AbstractDict} ? _get(ny1_, "year") : nothing
        _num1(y1_) && isfinite(_f1(y1_)) && (year1 = Int(_f1(y1_)))   # Kalenderjahr des ersten Planjahres (Tarifweg)
        acc = result_index(sres)
        sv = acc["worth"][end]
        if !isfinite(sv) || sv <= 0
            debt = _sv_get(sres, "tax_report", "open_tax_debt")
            debt === nothing && (debt = 0.0)
            extra = (_num1(debt) && _f1(debt) > 0) ? _sp(" (offene, nicht gedeckte Steuerschuld der Ansparphase: %s EUR, tax_report\$open_tax_debt)", _sp("%.2f", _f1(debt))) : ""
            _stop(_sp("start_value: Endwert der Ansparphase (SimLevResult) ist %s EUR; withdrawal_simulation() braucht ein positives Startvermögen%s.",
                      _sp("%.2f", sv), extra))
        end
        ol = _get(sres, "open_lots")
        ol_names = _list_names(ol)
        has_lots = !isempty(ol_names) && all(nm -> begin
                a = _get(ol, nm); L = _lots_df(a)
                (L isa RFrame && all(c -> haskey(L, c), ("units", "price", "vp"))) && _isnum(_get(a, "cash"))
            end, ol_names)
        cb_given = !cb_missing
        report = _get(sres, "report")
        rep_names = _list_names(report)
        if !cb_given
            held = [_last_worth(report, nm) for nm in rep_names]
            held_v = Float64[length(h) == 1 ? h[1] : NaN for h in held]
            if !isempty(held_v) && all(isfinite, held_v) && all(==(0), held_v)
                cost_basis = 100.0
            elseif has_lots
                bs = Float64[]
                for nm in ol_names
                    a = _get(ol, nm); L = _lots_df(a)
                    push!(bs, _rsum(_lcol(L, "units") .* _lcol(L, "price")) + _rsum(_lcol(L, "vp")) + Float64(_get(a, "cash")))
                end
                basis = _rsum(bs)
                cost_basis = 100 * basis / sv
                tax_mode == "person" && (lots = _wd_lots(ol, report, sv))
            else
                tax_mode == "person" && _warn("cost_basis: Näherung 100 x (Startwert brutto + Einzahlungen) / Endwert, da das Ansparergebnis keine offenen Lots enthält (simulation() ohne tax = tax_profile() oder älteres Ergebnis); realisierte Gewinne und Cash zählen dabei als stille Reserven. Für genaue Werte die Ansparphase mit tax = tax_profile() rechnen oder cost_basis angeben.")
                inv = _get(sres, "invested")
                inv = inv === nothing ? Float64[] : _dvec(inv)
                start_gross = !isempty(inv) ? inv[1] : acc["worth"][1]
                fl = acc["flows"]
                invested = start_gross + _rsum(Float64[_pmax(f, 0.0) for f in fl[2:end]])
                cost_basis = 100 * invested / sv
            end
        end
        if tax_mode == "person" && has_lots
            hold_n = _wd_held(ol, report, sv)
            hold = [_get(ol, nm) for nm in hold_n]
            reg = String[string(_get(a, "regime", "investment_fund")) for a in hold]
            fund = reg .== "investment_fund"
            mixed = any(fund) && !all(fund)
            if !isempty(hold) && !any(fund) && vp_missing
                vorabpauschale = false
                adopted["vorabpauschale"] = false
            end
            if mixed
                _warn(_sp("Am Ende gehaltene Assets mit verschiedenen Regimen (Investmentfonds: %s; andere: %s): withdrawal_simulation() wendet Vorabpauschale (vorabpauschale = %s) und Teilfreistellung (partial_exemption = %g %%) auf den ganzen Bestand an; beide werden nicht übernommen.",
                          join(hold_n[fund], ", "), join(hold_n[.!fund], ", "), _istrue(vorabpauschale) ? "TRUE" : "FALSE", partial_exemption))
            end
            if any(==("private_sale"), reg)
                _warn(_sp("Assets mit Regime 'private_sale' (Paragraf 23 EStG: %s) am Ende der Ansparphase: Spekulationsfrist und Freigrenze bildet withdrawal_simulation() nicht ab; deren Gewinne werden wie Fondsgewinne mit Teilfreistellung partial_exemption = %g %% besteuert.",
                          join(hold_n[reg .== "private_sale"], ", "), partial_exemption))
            end
            fs = reg .!= "private_sale"
            tfs_all = Float64[r == "investment_fund" ? Float64(_get(a, "partial_exemption", 0.0)) : 0.0 for (a, r) in zip(hold, reg)]
            tfs = tfs_all[fs]
            fs_names = hold_n[fs]
            if ab_missing && !mixed && !isempty(tfs) && all(fs) && all(abs.(tfs .- tfs[1]) .< 1e-9)
                partial_exemption = tfs[1]
                adopted["partial_exemption"] = partial_exemption
            elseif !mixed && !isempty(tfs) && any(abs.(tfs .- partial_exemption) .> 1e-9)
                _warn(_sp("partial_exemption = %g %%, aber die am Ende gehaltenen Assets haben die Teilfreistellung %s; withdrawal_simulation() rechnet mit einer Teilfreistellung für den ganzen Bestand (partial_exemption passend angeben; bei verschiedenen Werten keine exakte Abbildung).",
                          partial_exemption, join([_sp("%s %g %%", n, t) for (n, t) in zip(fs_names, tfs)], ", ")))
            end
            tr = _get(sres, "tax_report")
            ny_ = _get(tr, "next_year")
            num1p(v) = _num1(v) && _f1(v) >= 0
            ny_is_list = ny_ isa Union{RList,NamedTuple,AbstractDict}
            lc = (ny_is_list && num1p(_get(ny_, "loss_carryforward_capital"))) ? _get(ny_, "loss_carryforward_capital") :
                 _get(tr, "loss_carryforward_capital")
            if lc_missing && num1p(lc)
                loss_carryforward = _f1(lc)
                adopted["loss_carryforward"] = _f1(lc)
            end
            ny_is_list && num1p(_get(ny_, "sparer_pauschbetrag_used")) && (spb_used1 = _f1(_get(ny_, "sparer_pauschbetrag_used")))
            spr = Float64[(s = _get(a, "spread"); _isnum(s) ? Float64(s) : NA) for a in hold]
            if sc_missing && !isempty(spr) && !any(isnan, spr)
                if all(abs.(spr .- spr[1]) .< 1e-12)
                    sale_cost = spr[1] / 2
                    adopted["sale_cost"] = sale_cost
                else
                    _warn(_sp("sale_cost nicht übernommen: die gehaltenen Assets haben verschiedene Spreads (%s); withdrawal_simulation() rechnet mit einem Verkaufskostensatz für den ganzen Bestand (sale_cost angeben).",
                              join([_sp("%s %g %%", n, s) for (n, s) in zip(hold_n, spr)], ", ")))
                end
            end
            fee_set = Bool[_wd_fee_set(_get(a, "order_fee")) for a in hold]
            if any(fee_set)
                _warn(_sp("Ordergebühren der Ansparphase (%s) bildet withdrawal_simulation() beim Verkauf nicht ab; gegebenenfalls in sale_cost (Prozent des Verkaufsbetrags) berücksichtigen.",
                          join(hold_n[fee_set], ", ")))
            end
        end
        spb_used1 > 0 && (adopted["sparer_pauschbetrag_used_year1"] = spb_used1)
        if lots !== nothing
            adopted["lots"] = length(lots["n"])
        elseif !cb_given && tax_mode == "person"
            adopted["cost_basis"] = cost_basis
        end
        if length(adopted) > 0
            parts = String[]
            for (k, v) in adopted
                if k == "lots"
                    push!(parts, @sprintf("%d Lots (FIFO)", v))
                elseif v isa Bool
                    push!(parts, string(k, " = ", v ? "TRUE" : "FALSE"))
                else
                    push!(parts, string(k, " = ", _fmt1(SimLev.RFmt.signif(Float64(v), 8))))
                end
            end
            _message("Hinweis: aus der Ansparphase übernommen: " * join(parts, ", ") * ".")
        end
        start_value = sv
    end
    (!_num1(start_value) || _f1(start_value) <= 0) &&
        _stop(@sprintf("start_value muss ein positiver Geldbetrag (Zahl > 0) oder ein SimLevResult sein (erhalten: %s).", _wshow(start_value)))
    start_value = Float64(_f1(start_value))
    src_taxed = false
    if _is_result(x)
        tp = _sv_get(x, "tax_report", "total_taxes_paid")
        src_taxed = _num1(tp) && _f1(tp) > 0
        (_isnum(inflation)) || _stop("Bei einem SimLevResult ist 'inflation' ein Prozentsatz p. a.")
        x = withdrawal_cohorts(x; inflation = inflation, years = years === nothing ? 30 : years,
                               frequency = _match_arg(freq_arg, ("year", "quarter", "month")))
    elseif SimLev.inherits(x, "SimLevWrapperNav")   # Anteilswert eines Fonds-Wrappers (wrapper_nav()) als Kursreihe
        (_isnum(inflation)) || _stop("Bei einem SimLevWrapperNav ist 'inflation' ein Prozentsatz p. a.")
        x = withdrawal_cohorts(x; price = "nav", inflation = inflation, years = years === nothing ? 30 : years,
                               frequency = _match_arg(freq_arg, ("year", "quarter", "month")))
    elseif x isa RFrame && haskey(x, "date")   # Kurstabelle, z. B. Ausschnitt aus wrapper_nav()
        _stop("x ist eine Tabelle mit Spalte 'date' (z. B. ein Ausschnitt aus wrapper_nav(), der eine gewöhnliche " *
              "Tabelle ist); Kurse zuerst mit withdrawal_cohorts(x, price = \"<Kursspalte>\") in Renditen umwandeln " *
              "oder das ganze Ergebnis von wrapper_nav() übergeben.")
    elseif _is_study(x) || _is_result_list(x)
        if !_is_study(x)
            lst = x isa AbstractDict || x isa NamedTuple ? collect(values(x)) : collect(x)
            src_taxed = any(r -> (tp = _sv_get(r, "tax_report", "total_taxes_paid"); _num1(tp) && _f1(tp) > 0), lst)
        end
        x = withdrawal_paths(x; strategy = strategy, inflation = inflation, frequency = _match_arg(freq_arg, ("year", "quarter", "month")))
    end
    if src_taxed && tax_mode == "person" && _istrue(vorabpauschale)
        _warn("Das Quellergebnis wurde mit Steuern gerechnet (Vorabpauschale im Index enthalten); vorabpauschale = FALSE oder eine Quelle ohne Steuern (simulation(tax = NULL)) vermeidet Doppelzählung.")
    end
    if !_is_wp(x)
        frequency = _match_arg(freq_arg, ("year", "quarter", "month"))
        R = _numvec(x) === nothing ? nothing : _as_matrix(x)
        (R === nothing || isempty(R)) && _stop("x muss eine numerische Matrix (Perioden x Pfade) von Brutto-Periodenrenditen sein.")
        any(v -> !isnan(v) && v < 0, R) && _stop("x muss Brutto-Periodenrenditen enthalten (z. B. 1.05 für +5 %).")
        any(isnan, R) && _stop("missing value where TRUE/FALSE needed")
        _median(vec(R)) < 0.5 && _stop("x muss Brutto-Periodenrenditen enthalten (z. B. 1.05 für +5 %).")
        if infl_is_mat && size(inflation) != size(R)
            _stop(@sprintf("inflation als Matrix braucht dieselbe Dimension wie die Renditen (%d x %d), hat aber %d x %d.",
                           size(R, 1), size(R, 2), size(inflation, 1), size(inflation, 2)))
        end
        (!infl_is_mat && !_num1(inflation)) && _stop("inflation muss eine Zahl (Prozent p. a.) oder eine Matrix Perioden x Pfade sein.")
        I = infl_is_mat ? _mat(inflation) : fill(_rpow(1 + _f1(inflation) / 100, 1 / _wd_ppy(frequency)), size(R))
        x = RList("returns" => R, "inflation" => I, "cape" => nothing, "base_rate" => nothing, "frequency" => frequency,
                  "historical" => false, "start_dates" => nothing, "weights" => nothing, "source" => "matrix";
                  class = "withdrawal_paths")
    end
    ppy = _wd_ppy(_get(x, "frequency"))
    R = _get(x, "returns"); I = _get(x, "inflation")
    (!(R isa AbstractMatrix) || size(R, 1) == 0 || size(R, 2) == 0) && _stop("Keine Renditen (leere Matrix bzw. keine Pfade).")
    R = _mat(R); I = _mat(I)
    (any(isnan, R) || any(isnan, I)) && _stop("Renditen/Inflation enthalten NA.")
    size(I) != size(R) && _stop(@sprintf("Inflation (%d x %d) passt nicht zu den Renditen (%d x %d).", size(I, 1), size(I, 2), size(R, 1), size(R, 2)))
    xcape = _get(x, "cape"); xbase = _get(x, "base_rate")
    if br_is_mat
        base_rate = _mat(base_rate)
        if xbase === nothing && size(base_rate) != size(R)
            _stop(@sprintf("base_rate als Matrix braucht dieselbe Dimension wie die Renditen (%d x %d Perioden x Pfade), hat aber %d x %d.",
                           size(R, 1), size(R, 2), size(base_rate, 1), size(base_rate, 2)))
        end
    end
    if years !== nothing
        yy = _f1(years)
        abs(yy * ppy - _round0(yy * ppy)) > 1e-8 && _stop(@sprintf("years = %s ergibt keine ganze Zahl von Perioden (%d je Jahr).", _fmt1(_num(years)), ppy))
        kr = min(size(R, 1), Int(_round0(yy * ppy)))
        R = R[1:kr, :]; I = I[1:kr, :]
        xcape === nothing || (xcape = _mat(xcape)[1:kr, :])
        xbase === nothing || (xbase = _mat(xbase)[1:kr, :])
        br_is_mat && (base_rate = base_rate[1:kr, :])
    end
    size(R, 1) % ppy != 0 && _warn("Periodenzahl ist kein Vielfaches eines Jahres; letztes Planjahr unvollständig.")
    ny = cld(size(R, 1), ppy)
    nfy = size(R, 1) ÷ ppy
    rule["type"] == "cape" && xcape === nothing && _stop("Die CAPE-Regel braucht eine CAPE-Reihe (Argument cape in withdrawal_cohorts/withdrawal_paths).")
    CAPE = xcape !== nothing ? _mat(xcape) : zeros(size(R, 1), 0)
    BASE = xbase !== nothing ? _mat(xbase) : br_is_mat ? base_rate : fill(Float64(_f1(base_rate)), size(R))
    inc = zeros(ny)
    for e in something(income, Any[])
        s0 = _get(e, "start", 1.0); e0 = _get(e, "end", _get(e, "end_", Inf))
        sv0 = _numvec(s0); ev0 = _numvec(e0)
        if sv0 === nothing || ev0 === nothing || length(sv0) != 1 || length(ev0) != 1 || isnan(sv0[1]) || isnan(ev0[1]) || ev0[1] < sv0[1]
            _stop(@sprintf("income: start und end müssen Planjahre mit start <= end sein (erhalten: start = %s, end = %s).", _wshow(s0), _wshow(e0)))
        end
        s1 = max(1, Int(ceil(sv0[1])))
        e1 = isfinite(ev0[1]) ? min(ny, Int(floor(ev0[1]))) : ny
        if s1 <= e1
            amt = Float64(_f1(_get(e, "amount")))
            for k in s1:e1
                inc[k] = inc[k] + amt
            end
        end
    end
    rp = _wd_param_vector(rule)
    kp = min(kp, Float64(size(R, 2)))
    # Tarifweg: zvE je Planjahr (nominal wie angegeben; income zählt nicht dazu) und Tarif wie in simulation()
    tariff_par = Float64[]; zve = Float64[]
    if tariff_on
        zve = _wd_zve(tax["income"]["taxable_income"], Int(ny), year1)
        tt = tax["income"]["tariff"] === nothing ? SimLev.tax_tariff() : tax["income"]["tariff"]
        ct = tax["church_tax"]
        ck = ct !== nothing && Float64(ct) > 0 ? Float64(ct) / 100 : 0.0
        tariff_par = _wd_tariff_par(tt, ck, tax["guenstigerpruefung"])
    end
    t0 = time()
    core = _wcore().wd_simulate(R, I, CAPE, BASE, ppy, _rule_code(rule["type"]), rp, timing == "start", start_value, inc,
                                tax_mode == "person", Float64(tax_rate), Float64(partial_exemption) / 100, Float64(sparer_pauschbetrag),
                                _istrue(vorabpauschale), Float64(sale_cost) / 100, Float64(cost_basis) / 100, Float64(loss_carryforward),
                                kp > 0 || horizon !== nothing,
                                lots === nothing ? Float64[] : lots["n"], lots === nothing ? Float64[] : lots["basis"],
                                lots === nothing ? Float64[] : lots["vp"], lots === nothing ? Int[] : lots["group"],
                                spb_used1 > 0 ? max(0.0, Float64(sparer_pauschbetrag) - spb_used1) : -1.0, horizon !== nothing,
                                tariff_par, zve)
    sp = core["spending"]
    w0 = sp[1, :]
    gamma = Float64(gamma)
    function ce_fun(c)
        c = Float64[_pmax(v, 1e-9 * start_value) for v in c]
        abs(gamma - 1) < 1e-12 && return _rexp(_rmean(Float64[_rlog(v) for v in c]))
        return _rpow(_rmean(_pow_vec(c, 1 - gamma)), 1 / (1 - gamma))
    end
    dd_fun(c) = (m = _cummax(c); maximum(1 .- c ./ m))
    ncol = size(sp, 2)
    function per_path(fun, H = fill(ny, ncol))
        Float64[(r = min(Int(H[i]), nfy); r > 0 ? fun(sp[1:r, i]) : NA) for i in 1:ncol]
    end
    pwr = (ppy == 1 || size(R, 1) >= ppy) ?
          withdrawal_perfect_rate(_annual_real(RList("returns" => R, "inflation" => I, "frequency" => x["frequency"]))) : nothing
    pwr = pwr === nothing ? Union{Missing,Bool}[missing for _ in 1:ncol] :
          Float64[pwr[(i-1)%length(pwr)+1] for i in 1:ncol]
    dep = Float64[ceil(v / ppy) for v in core["depletion_period"]]
    cols = Pair{String,Any}["success" => core["failed"] .== 0, "depletion_year" => dep,
            "terminal_real" => core["terminal_real"], "terminal_nominal" => core["terminal_nominal"],
            "first_withdrawal" => w0, "mean_spending" => nfy == ny ? _col_ld(sp, true) : per_path(_rmean),
            "min_spending" => per_path(minimum), "spending_drawdown" => per_path(dd_fun), "ce_spending" => per_path(ce_fun),
            "total_spending" => _col_ld(sp, false), "taxes" => core["taxes_real"], "pwr" => pwr]
    paths = RFrame(cols...)
    sd = _get(x, "start_dates")
    sd === nothing || (paths["start"] = _todate(sd, "dates"))
    wealth = core["wealth"]
    if horizon !== nothing
        H = _draw_horizon(horizon, size(R, 2))
        if maximum(H) > ny
            _warn(@sprintf("Horizont bis %d Jahre, Pfade nur %d Jahre: längere Horizonte werden auf %d gekürzt.", maximum(H), ny, ny))
            H = min.(H, ny)
        end
        dy = dep
        paths["success_full"] = copy(paths["success"])
        paths["horizon"] = H
        paths["success"] = Bool[isnan(dy[i]) || dy[i] > H[i] for i in eachindex(H)]
        paths["depletion_year"] = Float64[!isnan(dy[i]) && dy[i] <= H[i] ? dy[i] : NA for i in eachindex(H)]
        paths["terminal_real"] = Float64[core["wealth_end"][H[i]+1, i] for i in eachindex(H)]
        paths["taxes"] = Float64[core["taxes_end"][H[i]+1, i] for i in eachindex(H)]
        paths["mean_spending"] = per_path(_rmean, H); paths["min_spending"] = per_path(minimum, H)
        paths["total_spending"] = Float64[_rsum(sp[1:H[i], i]) for i in eachindex(H)]
        paths["spending_drawdown"] = per_path(dd_fun, H); paths["ce_spending"] = per_path(ce_fun, H)
        if ppy == 1
            AR = _annual_real(RList("returns" => R, "inflation" => I, "frequency" => x["frequency"]))
            paths["pwr"] = Float64[withdrawal_perfect_rate(AR[1:H[i], i:i])[1] for i in eachindex(H)]
        else
            paths["pwr"] = fill(NA, length(H))
        end
        kp == 0 && (wealth = nothing)
    end
    w = _get(x, "weights")
    w = w === nothing ? ones(size(R, 2)) : _dvec(w)
    out = RList("paths" => paths, "spending" => sp, "planned" => core["planned"],
                 "wealth" => kp == 0 ? nothing : (kp < size(wealth, 2) ? wealth[:, 1:Int(kp)] : wealth), "rule" => rule, "start_value" => start_value,
                 "frequency" => x["frequency"], "years" => ny, "full_years" => nfy, "horizon" => horizon,
                 "historical" => _istrue(_get(x, "historical")), "weights" => w, "tax_mode" => tax_mode, "gamma" => gamma,
                 "timing" => timing, "source" => _get(x, "source"), "adopted" => length(adopted) > 0 ? adopted : nothing,
                 "elapsed" => time() - t0; class = "SimLevWithdrawal")
    tariff_on && (out["tariff_years"] = _wd_tariff_years(core["tariff_years"], Int(ny)))
    return out
end

"""
    withdrawal_max_rate(x, rule = withdrawal_rule("constant"); success = 0.95, lower = 0.5, upper = 20,
                        tol = 0.005, kwargs...)

Maximale Anfangsrate für eine Ziel-Erfolgsquote (Bisektion).

Bestimmt per Bisektion die höchste Entnahmerate (`rate` der Regel), bei der der (mit den Pfadgewichten
gewichtete) Anteil erfolgreicher Pfade mindestens `success` beträgt. Für die konstante Regel ohne Steuern und
Einkommen entspricht das dem Quantil der Perfect Withdrawal Rate (historisch: Minimum über alle Kohorten =
SWR). Jeder Suchschritt ruft `withdrawal_simulation()` mit `keep_paths = false` auf.

# Argumente
- `x`: Renditequelle wie in `withdrawal_simulation()`: `withdrawal_paths` (z. B. aus `withdrawal_cohorts()`,
  `withdrawal_paths()`, `bootstrap_pooled()`), Renditematrix, `SimLevResult`, Liste von `SimLevResult` oder
  `SimLevBootstrapStudy`.
- `rule`: Objekt aus `withdrawal_rule()`; dessen `rate` wird variiert (Standard:
  `withdrawal_rule("constant")`). Nur für Regeln, die `rate` nutzen; bei `one_over_n`, `vpw`, `abw`, `cape`
  und `hebeler` bricht die Funktion ab.
- `success`: Ziel-Erfolgsquote als Anteil (0.95 = 95 % der Pfade, Standard); 1 = historische SWR. Zulässig 0 <
  success <= 1 (95 statt 0.95 ist ein Fehler).
- `lower`, `upper`: Suchintervall für `rate` in Prozent (Standard 0.5 und 20).
- `tol`: Genauigkeit in Prozentpunkten (Standard 0.005; > 0). Es muss 0 <= lower < upper <= 100 gelten.
- `kwargs...`: weitere Argumente für `withdrawal_simulation()` (z. B. `inflation`, `tax_mode`, `horizon`). Ein
  `horizon` aus `withdrawal_horizon()` mit `seed = nothing` wird einmal zu einem Startwert aufgelöst (ein Zug
  aus dem Zufallszustand von SimLev, `simlev_seed()`); alle Suchschritte vergleichen damit dieselben
  Laufzeiten.

# Rückgabe
Rate in Prozent (Zahl; 4 = 4 %) mit Attribut `"success"` (erreichte Erfolgsquote als Anteil). `NA`, wenn schon
`lower` die Zielquote verfehlt; `upper`, wenn selbst `upper` sie erreicht.

# Beispiel
```julia
using SimLev, Random
rng = MersenneTwister(1)
R = exp.(0.05 .+ 0.15 .* randn(rng, 30, 200))   # 30 Jahre, 200 Pfade
println(withdrawal_max_rate(R, withdrawal_rule("constant"); success = 0.9, inflation = 2))
```
"""
function withdrawal_max_rate(x, rule_pos = _MISSING; rule = _MISSING, success = 0.95, lower = 0.5, upper = 20, tol = 0.005, kwargs...)
    x = SimLev.as_rframe(x)
    rule_pos === _MISSING || (rule = rule_pos)
    rule === _MISSING && (rule = withdrawal_rule("constant"))
    _is_rule(rule) || _stop("rule muss mit withdrawal_rule() erstellt werden.")
    if rule["type"] in ("one_over_n", "vpw", "abw", "cape", "hebeler")
        _stop(@sprintf("withdrawal_max_rate: Die Regel '%s' nutzt rate nicht; eine Suche über rate ist dafür nicht möglich.", rule["type"]))
    end
    if !_num1(success) || _f1(success) <= 0 || _f1(success) > 1
        hint = (_num1(success) && 1 < _f1(success) <= 100) ? "; gemeint vermutlich " * _fmt1(_f1(success) / 100) : ""
        _stop(@sprintf("withdrawal_max_rate: success muss ein Anteil mit 0 < success <= 1 sein (0.95 = 95 %%; erhalten: %s)%s.", _show(success), hint))
    end
    if !_num1(lower) || !_num1(upper) || lower < 0 || upper > 100 || lower >= upper
        _stop(@sprintf("withdrawal_max_rate: lower und upper müssen Raten in Prozent mit 0 <= lower < upper <= 100 sein (erhalten: lower = %s, upper = %s).",
                       _show(lower), _show(upper)))
    end
    if !_num1(tol) || _f1(tol) <= 0
        _stop(@sprintf("withdrawal_max_rate: tol muss eine Zahl > 0 in Prozentpunkten sein (z. B. 0.005; erhalten: %s).", _show(tol)))
    end
    lower = Float64(lower); upper = Float64(upper); success = Float64(success); tol = Float64(tol)
    # Ein Horizont mit seed = nothing wird einmal zu k aufgelöst; alle
    # Suchschritte ziehen damit dieselben Laufzeiten
    hz = get(kwargs, :horizon, nothing)
    if _is_horizon(hz) && _get(hz, "seed") === nothing && hz["type"] != "fixed"
        hz = copy(hz)
        hz["seed"] = SimLev.SLib.next_seed()
        kwargs = (; kwargs..., horizon = hz)
    end
    first = Ref(true)
    function f(rate)
        rl = copy(rule)
        rl["rate"] = rate
        s = if first[]
            withdrawal_simulation(x, rl; keep_paths = false, kwargs...)
        else
            _quiet(() -> _no_messages(() -> withdrawal_simulation(x, rl; keep_paths = false, kwargs...)))
        end
        first[] = false
        return _weighted_mean(Float64.(s["paths"]["success"]), s["weights"])
    end
    mk(v, s) = RVector([v]; attrs = Dict{String,Any}("success" => s))
    s_lo = f(lower)
    s_lo < success && return mk(NA, s_lo)
    s_up = f(upper)
    s_up >= success && return mk(upper, s_up)
    while upper - lower > tol
        mid = (lower + upper) / 2
        s_mid = f(mid)
        if s_mid >= success
            lower = mid; s_lo = s_mid
        else
            upper = mid
        end
    end
    return mk(lower, s_lo)
end

# ═══════════════════════════════════════════════════════════════════════════
# Zusammenfassung, Ausgabe, Grafik
# ═══════════════════════════════════════════════════════════════════════════

"Zusammenfassung (R: `summary.SimLevWithdrawal`)."
function _summary_wd(obj; probs = [0.05, 0.25, 0.5, 0.75, 0.95])
    p = obj["paths"]
    w = _dvec(obj["weights"])
    probs = _dvec(probs)
    wq(v) = _wquantile(_dvec(v), w, probs)
    wm(v) = _weighted_mean(_dvec(v), w; na_rm = true)
    yrs = obj["years"]
    H = haskey(p, "horizon") ? p["horizon"] : nothing
    nfy = _get(obj, "full_years", yrs)
    spm = _mat(obj["spending"])
    function pick(y)
        j = H === nothing ? collect(1:size(spm, 2)) : findall(H .>= y)
        (y > nfy || isempty(j)) && return fill(NA, length(probs))
        return _wquantile(spm[y, j], w[j], probs)
    end
    succ = Bool.(p["success"])
    sby = NamedMat(permutedims(reduce(hcat, [pick(1), pick(10), pick(20), pick(30)])); rownames = ["Jahr 1", "Jahr 10", "Jahr 20", "Jahr 30"])
    pwr = _dvec(p["pwr"])
    swr = if _istrue(obj["historical"])
        fin = pwr[.!isnan.(pwr)]
        if isempty(fin)
            _warn("no non-missing arguments to min; returning Inf")
            Inf
        else
            minimum(fin)
        end
    else
        _wquantile(pwr, w, 0.05)[1]
    end
    return RList("rule" => obj["rule"], "n_paths" => SimLev.nrow(p), "years" => yrs, "historical" => obj["historical"],
                 "success_rate" => wm(succ),
                 "depletion" => any(.!succ) ? _wquantile(_dvec(p["depletion_year"])[.!succ], w[.!succ], probs) : nothing,
                 "terminal_real" => wq(p["terminal_real"]),
                 "preserve_rate" => wm(_dvec(p["terminal_real"]) .>= obj["start_value"]),
                 "first_withdrawal" => wq(p["first_withdrawal"]),
                 "mean_spending" => wq(p["mean_spending"]), "min_spending" => wq(p["min_spending"]),
                 "spending_drawdown" => wq(p["spending_drawdown"]), "ce_spending" => wq(p["ce_spending"]),
                 "spending_by_year" => sby, "taxes" => wq(p["taxes"]), "pwr" => wq(pwr), "swr" => swr,
                 "probs" => probs, "start_value" => obj["start_value"], "tax_mode" => obj["tax_mode"], "gamma" => obj["gamma"];
                 class = "summary.SimLevWithdrawal")
end

const _WLINE = repeat("═", 62)
_fw(s) = (r = SimLev.RFmt.format(s; width = 28); r isa AbstractString ? String(r) : String(first(r)))

function _print_summary_wd(io::IO, x)
    # Fehlwert als Gedankenstrich, rechtsbündig auf 10 Zeichen; nicht mit _sp("%10s"), das wie R bei %s
    # Bytes zählt (der Gedankenstrich hat in UTF-8 drei)
    function q(v; pct = false)
        join([isnan(z) ? " "^9 * "–" : pct ? _sp("%9.2f%%", z) : _sp("%10.0f", z) for z in _dvec(v)])
    end
    probs = _dvec(x["probs"])
    hdr = join([_sp("%10s", _sp("q%02d", _round0(100 * p))) for p in probs])
    print(io, "\n", _WLINE, "\n")
    print(io, "                 SimLev Entnahme-Simulation                    \n")
    print(io, _WLINE, "\n\n")
    print(io, _sp("  Regel:            %s\n", _WD_LABELS[x["rule"]["type"]]))
    print(io, _sp("  Pfade:            %d %s über %d Jahre, Startvermögen %.0f\n", x["n_paths"],
                  _istrue(x["historical"]) ? "historische Kohorten" : "Pfade", x["years"], x["start_value"]))
    print(io, _sp("  Steuern:          %s\n\n", x["tax_mode"] == "person" ? "deutsche Privatperson (vereinfacht)" : "keine"))
    print(io, _sp("  Erfolgsquote:     %.1f %% (Depot reicht für alle geplanten Entnahmen)\n", 100 * x["success_rate"]))
    print(io, _sp("  Kapitalerhalt:    %.1f %% (reales Endvermögen >= Start)\n", 100 * x["preserve_rate"]))
    if _get(x, "depletion") !== nothing
        print(io, _sp("  Erschöpfung:      Median im Jahr %.0f (bei gescheiterten Pfaden)\n", _dvec(x["depletion"])[cld(length(probs), 2)]))
    end
    print(io, _sp("  %s: %.2f %% der Startsumme\n", _istrue(x["historical"]) ? "SWR historisch (min. PWR)" : "SWR (5-%-Quantil PWR)", x["swr"]))
    print(io, _sp("\n  %s%s\n", _fw("real, in Startkaufkraft"), hdr))
    print(io, _sp("  %s%s\n", _fw("Endvermögen"), q(x["terminal_real"])))
    print(io, _sp("  %s%s\n", _fw("Entnahme Jahr 1"), q(x["first_withdrawal"])))
    sby = x["spending_by_year"]
    for (i, r) in enumerate(sby.rownames)
        print(io, _sp("  %s%s\n", _fw("Konsum " * r), q(sby.data[i, :])))
    end
    print(io, _sp("  %s%s\n", _fw("Konsum Durchschnitt"), q(x["mean_spending"])))
    print(io, _sp("  %s%s\n", _fw("Konsum Minimum"), q(x["min_spending"])))
    print(io, _sp("  %s%s\n", _fw(_sp("Sicherheitsäquiv. (g=%g)", x["gamma"])), q(x["ce_spending"])))
    print(io, _sp("  %s%s\n", _fw("Max. Konsumrückgang"), q(100 .* _dvec(x["spending_drawdown"]); pct = true)))
    print(io, _sp("  %s%s\n", _fw("PWR"), q(x["pwr"]; pct = true)))
    x["tax_mode"] == "person" && print(io, _sp("  %s%s\n", _fw("Steuern gesamt"), q(x["taxes"])))
    print(io, "\n", _WLINE)   # ohne abschließenden Zeilenumbruch
end

"R `print.SimLevWithdrawal(x, ...)`: druckt `summary(x, ...)`; `probs` geht an summary, andere Schlüsselwörter ignoriert (wie R)."
function _print_wd(io::IO, x; kw...)
    _print_summary_wd(io, _summary_wd(x; (k => v for (k, v) in kw if k === :probs)...))
    return nothing
end

"Fächer des realen Vermögens und des realen Jahreskonsums als SVG (R: `plot.SimLevWithdrawal`)."
function _plot_wd(x; probs = [0.05, 0.25, 0.5, 0.75, 0.95], file = nothing, width = 900, height = 380)
    probs = _dvec(probs)
    w = _dvec(x["weights"])
    panels = Any[]
    # keep_paths = k < Pfade: Vermögensfächer mit den Gewichten der behaltenen Spalten, Konsum mit allen;
    # Titel mit Zusatz, ebenso als Attribut `title` der Tabelle `wealth` in `data`
    spm = _mat(x["spending"])
    title = nothing
    if _get(x, "wealth") !== nothing
        wm = _mat(x["wealth"])
        kk, nn = size(wm, 2), size(spm, 2)
        kk < nn && (title = _sp("Reales Vermögen (erste %d von %d Pfaden)", kk, nn))
        push!(panels, (wm, title === nothing ? "Reales Vermögen" : title, 0, w[1:kk]))
    end
    push!(panels, (spm, "Realer Konsum je Jahr", 1, w))
    np = length(panels)
    pw = width / np
    data = SimLev.RList()
    # Spaltennamen der Quantile: q05, q25, q50, … (100·p mit %g, einstellig mit führender Null)
    qn = String[(t = SimLev.r_sprintf("%g", 100 * p); length(t) == 1 ? "q0" * t : "q" * t) for p in probs]
    io = IOBuffer()
    print(io, "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"$width\" height=\"$height\" viewBox=\"0 0 $width $height\" font-family=\"sans-serif\" font-size=\"12\">\n")
    print(io, "<rect width=\"100%\" height=\"100%\" fill=\"white\"/>\n")
    k = length(probs)
    for (pi_, (M, main, x0, wp)) in enumerate(panels)
        Qr = reduce(hcat, [_wquantile(M[i, :], wp, probs) for i in 1:size(M, 1)])
        Q = Qr ./ 1000
        xs = collect(x0:x0+size(M, 1)-1)
        # dargestellte Werte unskaliert (gezeichnet in Tausend)
        data[x0 == 0 ? "wealth" : "spending"] = SimLev.RFrame("year" => xs, (qn[i] => Float64[Qr[i, j] for j in eachindex(xs)] for i in eachindex(qn))...)
        x0 == 0 && title !== nothing && (SimLev.attrs(data["wealth"])["title"] = title)
        fin = filter(isfinite, vec(Q))
        ylo, yhi = isempty(fin) ? (0.0, 1.0) : (minimum(fin), maximum(fin))
        yhi == ylo && (yhi = ylo + 1)
        xlo, xhi = first(xs), max(last(xs), first(xs) + 1)
        ox = (pi_ - 1) * pw
        ml, mr, mt, mb = 60, 15, 35, 45
        aw, ah = pw - ml - mr, height - mt - mb
        sx(v) = ox + ml + (v - xlo) / (xhi - xlo) * aw
        sy(v) = mt + ah - (v - ylo) / (yhi - ylo) * ah
        print(io, "<text x=\"", ox + pw / 2, "\" y=\"20\" text-anchor=\"middle\" font-weight=\"bold\">", main, "</text>\n")
        print(io, "<rect x=\"", ox + ml, "\" y=\"$mt\" width=\"$aw\" height=\"$ah\" fill=\"none\" stroke=\"black\"/>\n")
        print(io, "<text x=\"", ox + ml + aw / 2, "\" y=\"", height - 10, "\" text-anchor=\"middle\">Jahr</text>\n")
        for i in 1:(k ÷ 2)
            up = [string(@sprintf("%.2f", sx(xs[j])), ",", @sprintf("%.2f", sy(Q[i, j]))) for j in eachindex(xs) if isfinite(Q[i, j])]
            dn = [string(@sprintf("%.2f", sx(xs[j])), ",", @sprintf("%.2f", sy(Q[k+1-i, j]))) for j in reverse(eachindex(xs)) if isfinite(Q[k+1-i, j])]
            print(io, "<polygon fill=\"#2C6E9B\" fill-opacity=\"0.18\" stroke=\"none\" points=\"", join(vcat(up, dn), " "), "\"/>\n")
        end
        mid = cld(k, 2)
        pts = [string(@sprintf("%.2f", sx(xs[j])), ",", @sprintf("%.2f", sy(Q[mid, j]))) for j in eachindex(xs) if isfinite(Q[mid, j])]
        print(io, "<polyline fill=\"none\" stroke=\"#2C6E9B\" stroke-width=\"2\" points=\"", join(pts, " "), "\"/>\n")
    end
    print(io, "</svg>\n")
    svg = String(take!(io))
    file === nothing || write(file, svg)
    return (svg, data)
end

# ═══════════════════════════════════════════════════════════════════════════
# Laufzeitmodell
# ═══════════════════════════════════════════════════════════════════════════

"""
    withdrawal_horizon(type = "fixed"; years = nothing, prob = nothing, min = nothing, max = nothing,
                  mean = nothing, sd = nothing, mode = nothing, seed = 1)

Laufzeit der Entnahmephase nach eigenen Annahmen.

Beschreibt, wie lange die Entnahmephase dauern soll - fest oder als Verteilung nach eigenen Vorgaben. Jeder
Pfad von `withdrawal_simulation()` erhält eine eigene Laufzeit, gezogen mit festem Startwert (gleiche
Laufzeiten bei wiederholten Aufrufen; mit `seed = nothing` je Aufruf andere, außer innerhalb von
`withdrawal_max_rate()`).

# Argumente
- `type`: Verteilung: `"fixed"` (Standard), `"uniform"`, `"discrete"`, `"normal"`, `"triangular"` oder
  `"sample"` (siehe oben). Fehlende Pflichtparameter führen zu einem Fehler.
- `years`: Laufzeit(en) in Jahren: feste Laufzeit (`fixed`), mögliche Laufzeiten (`discrete`) bzw. Stichprobe
  (`sample`). Bei `discrete` und `sample` ist auch ein einzelner Wert erlaubt (dann immer diese Laufzeit).
- `prob`: `discrete`: Wahrscheinlichkeiten je Eintrag von `years` (gleiche Länge, >= 0, Summe > 0; werden
  normiert).
- `min`, `max`: Untere und obere Grenze in Jahren (`uniform`, `normal`, `triangular`); `min <= max`.
- `mean`, `sd`: `normal`: Mittelwert und Standardabweichung in Jahren.
- `mode`: `triangular`: häufigster Wert in Jahren.
- `seed`: Startwert für die Ziehung der Laufzeiten (Standard 1; ganze Zahl mit |seed| < 2^53); der
  Zufallszustand von SimLev bleibt dann unverändert. `nothing` = bei jeder Ziehung wird genau einmal ein
  Startwert aus dem Zufallszustand von SimLev gezogen (siehe `simlev_seed()`), jede Ziehung ist anders;
  `withdrawal_max_rate()` löst `nothing` einmal auf und nutzt in allen Suchschritten dieselben Laufzeiten.
  `set.seed()` wirkt nicht.

# Rückgabe
Objekt der Klasse `SimLevHorizon` (Liste mit `type`, `seed` und den benötigten Parametern) zur Übergabe an das
Argument `horizon` von `withdrawal_simulation()` bzw. `withdrawal_max_rate()`. Ausgabe mit `print()` (siehe
SimLevWithdrawal-methods).

# Details
- fixed: `years`: feste Laufzeit.
- uniform: `min`, `max`: ganzzahlig gleichverteilt.
- discrete: `years`, `prob`: eigene Wahrscheinlichkeiten je Laufzeit, z. B. `years = [25, 30, 35, 40], prob =
  [.3, .4, .2, .1]`.
- normal: `mean`, `sd`, `min`, `max`: gerundet und auf `[min, max]` begrenzt.
- triangular: `min`, `mode`, `max` mit `min <= mode <= max`.
- sample: `years`: eigene Stichprobe von Laufzeiten, aus der mit Zurücklegen gezogen wird.

Gezogene Laufzeiten werden auf ganze Jahre gebracht (bei `normal` und `triangular` gerundet) und sind
mindestens 1 Jahr. Laufzeiten über der Pfadlänge kürzt `withdrawal_simulation()` mit Warnung. Die
Laufzeit-Parameter `years`, `min`, `max`, `mean` und `mode` müssen > 0 sein (sonst Fehler).

# Beispiel
```julia
using SimLev, Random
h = withdrawal_horizon("discrete"; years = [25, 30, 35, 40], prob = [0.3, 0.4, 0.2, 0.1])
R = exp.(0.05 .+ 0.15 .* randn(MersenneTwister(1), 40, 500))
println(withdrawal_simulation(R, withdrawal_rule("constant"; rate = 4); inflation = 2, horizon = h))
```
"""
function withdrawal_horizon(type_pos = nothing; type = type_pos, type_ = type, years = nothing, prob = nothing, min = nothing, max = nothing,
                       mean = nothing, sd = nothing, mode = nothing, seed = 1)
    t = _match_arg(type_, ("fixed", "uniform", "discrete", "normal", "triangular", "sample"))
    need = Dict("fixed" => ["years"], "uniform" => ["min", "max"], "discrete" => ["years", "prob"],
                "normal" => ["mean", "sd", "min", "max"], "triangular" => ["min", "mode", "max"], "sample" => ["years"])[t]
    given = Dict{String,Any}("years" => years, "prob" => prob, "min" => min, "max" => max, "mean" => mean, "sd" => sd, "mode" => mode)
    miss = [k for k in need if given[k] === nothing]
    isempty(miss) || _stop(@sprintf("withdrawal_horizon('%s') braucht: %s", t, join(miss, ", ")))
    for k in need
        v = given[k]
        multi = k == "prob" || (k == "years" && t in ("discrete", "sample"))
        a = _numvec(v)
        if a === nothing || isempty(a) || any(!isfinite, a) || (!multi && length(a) != 1)
            _stop(@sprintf("withdrawal_horizon('%s'): %s muss %s sein (erhalten: %s).", t, k,
                           multi ? "ein endlicher Zahlenvektor" : "eine endliche Zahl", _show(v)))
        end
    end
    for k in [k for k in need if k in ("years", "min", "max", "mean", "mode")]
        any(_numvec(given[k]) .<= 0) &&
            _stop(@sprintf("withdrawal_horizon('%s'): %s muss > 0 sein (Laufzeit in Jahren; erhalten: %s).", t, k, _show(given[k])))
    end
    if t == "discrete"
        yv, pv = _numvec(years), _numvec(prob)
        (length(yv) != length(pv) || any(pv .< 0) || _rsum(pv) <= 0) &&
            _stop("withdrawal_horizon('discrete'): years und prob gleich lang, prob >= 0 mit Summe > 0.")
    end
    min !== nothing && max !== nothing && _f1(min) > _f1(max) && _stop("min <= max erforderlich.")
    if t == "triangular" && (mode < min || mode > max)
        _stop(_sp("withdrawal_horizon('triangular'): mode (%g) muss zwischen min (%g) und max (%g) liegen.", mode, min, max))
    end
    t == "normal" && sd < 0 && _stop("withdrawal_horizon('normal'): sd muss >= 0 sein.")
    seed === nothing || SimLev.SLib.check_seed(seed)          # ganze Zahl, |seed| < 2^53
    out = RList("type" => t, "seed" => seed; class = "SimLevHorizon")
    for k in need
        out[k] = _rval(given[k])
    end
    return out
end

"`seq(a, b)` (Schritt 1)."
function _seq_from_to(a, b)
    a = Float64(a); b = Float64(b)
    n = Int(floor(b - a + 1e-10))
    return Float64[a + i for i in 0:n]
end

"Laufzeiten ziehen (R: `.draw_horizon`); ganzzahlig, mindestens 1."
function _draw_horizon(h, n)
    n = Int(n)
    # Hauptstrom aus h["seed"]; "fixed" zieht nicht
    rs = h["type"] == "fixed" ? nothing : SimLev.SLib.main_stream(_get(h, "seed"))
    function pick(x, prob = nothing)
        x = _dvec(x)
        ix = prob === nothing ? SimLev.SLib.sample(length(x), n; replace = true, stream = rs) :
             SimLev.SLib.sample(length(x), n; replace = true, prob = _dvec(prob), stream = rs)
        return x[_ivec(ix)]
    end
    function body()
        t = h["type"]
        t == "fixed" && return fill(Float64(_f1(h["years"])), n)
        t == "uniform" && return pick(_seq_from_to(_f1(h["min"]), _f1(h["max"])))
        t == "discrete" && return pick(h["years"], h["prob"])
        if t == "normal"
            z = SimLev.SLib.rnorm(n, Float64(_f1(h["mean"])), Float64(_f1(h["sd"])); stream = rs)
            r = Float64[_round0(v) for v in z]
            return Float64[_pmin(Float64(_f1(h["max"])), _pmax(Float64(_f1(h["min"])), v)) for v in r]
        end
        if t == "triangular"
            u = SimLev.SLib.runif(n; stream = rs)
            a, b, c = Float64(_f1(h["min"])), Float64(_f1(h["max"])), Float64(_f1(h["mode"]))
            b == a && return fill(a, n)
            f = (c - a) / (b - a)
            return Float64[_round0(ui < f ? a + sqrt(ui * (b - a) * (c - a)) : b - sqrt((1 - ui) * (b - a) * (b - c))) for ui in u]
        end
        return pick(h["years"])
    end
    out = body()
    return Int[Int(trunc(_pmax(1.0, v))) for v in out]
end

function _print_horizon(io::IO, x)
    d = _draw_horizon(x, 20000)
    print(io, _sp("Laufzeit der Entnahmephase (%s): Mittel %.1f Jahre, Median %g, 90 %%-Quantil %g, Bereich %g bis %g\n",
                  x["type"], SimLev.r_mean_int(d), _median(Float64.(d)), _quantile7(Float64.(d), 0.9)[1],
                  Float64(minimum(d)), Float64(maximum(d))))
end

function __init__()
    SimLev.register_print!("withdrawal_rule", _print_rule)
    SimLev.register_print!("SimLevWithdrawal", _print_wd)
    SimLev.register_print!("summary.SimLevWithdrawal", _print_summary_wd)
    SimLev.register_print!("SimLevHorizon", _print_horizon)
    SimLev.register_summary!("SimLevWithdrawal", (x, args...; kw...) -> _summary_wd(x; kw...))
    SimLev.register_plot!("SimLevWithdrawal", SimLev._plot_method(_plot_wd, "SimLevWithdrawal"))
end

end # module

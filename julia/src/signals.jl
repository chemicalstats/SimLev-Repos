# Signals – Gegenstück zu r/R/signals.R und python/simlev/signals.py
#
# Jeder Baustein nimmt eine Kursreihe und liefert `RList(buy, sell)` mit
# logischen Vektoren gleicher Länge (NA → false), das Format für
# `signal = df -> ...` in bootstrap_study() und param_search(). Fenster zählen
# in Zeilen. In simulation(): Kauf nur, wenn das Asset nicht gehalten wird und
# `buy` wahr ist; Verkauf, wenn es gehalten wird und `sell` wahr ist.
module Signals

import ..SimLev
using ..SimLev: RList, RVector, NA
using Dates

export signal_sma, signal_ema, signal_crossover, signal_momentum, signal_drawdown,
       signal_volatility, signal_combine

const DP = SimLev.DataPrep
const SC = SimLev.SignalsCore

_asint(n) = Int(trunc(Float64(n)))

using ..SimLev: chk_num1, chk_scalar, chk_stop
const _IMAX = 2147483647

"""Kursreihe prüfen (seit 1.6.4, B-009 bis B-012, B-016; R: .sig_x): numerischer Vektor (keine Matrix, keine
Tabelle, kein Text, keine Wahrheitswerte; leer erlaubt; nur NA (missing) zählt als Zahlenvektor)."""
function _sig_x(x, fn)
    @nospecialize
    SimLev.chk_nofactor(x, fn, "x")   # Entscheidung 15
    v = x isa RVector ? x.values : x
    ok = if v isa Real
        !(v isa Bool)
    elseif v isa AbstractVector && !(v isa AbstractVector{<:Pair})
        all(e -> e === missing || (e isa Real && !(e isa Bool)), v)
    else
        false
    end
    ok || chk_stop("zahlen", fn, "x")
    return nothing
end

"Fenster bzw. Verzögerung: ganze Zahl >= lo bis zur R-Ganzzahlgrenze (seit 1.6.4, Entscheidungen 19 und 32; bis 1.6.3 abgeschnitten)."
_sig_win(x, fn, arg; lo = 1, null_ok = false) =
    SimLev.chk_int1(chk_num1(x, fn, arg; lo = lo, hi = _IMAX, null_ok = null_ok), fn, arg; lo = lo, null_ok = null_ok)

"Rollierender Mittelwert (Fenster `n` inkl. aktueller Zeile; NA bei fehlendem Wert im Fenster)."
_roll_mean(x, n) = SC.roll_mean_core(DP._as_numeric(x), _asint(n))

"Rollierende Varianz (Populationsform, Zwei-Pass)."
_roll_var(x, n) = (v = DP._as_numeric(x); SC.roll_cov_core(v, v, _asint(n)))

"Rollierende Kovarianz (Populationsform, Zwei-Pass)."
_roll_cov(x, y, n) = SC.roll_cov_core(DP._as_numeric(x), DP._as_numeric(y), _asint(n))

"""
    _ema(x, n)

Exponentieller gleitender Durchschnitt (Glättung 2/(n+1), Start mit dem
einfachen Mittel der ersten `n` Werte); davor NA.
"""
# Hinweis bei fehlenden Kursen für den exponentiellen Durchschnitt (seit 1.6.5, CR2-V1-5)
function _sig_ema_na(x, fn)
    i = findfirst(isnan, x)
    i === nothing || @warn SimLev.chk_msg("b2.ema_na", fn, i)
    nothing
end

# seit 1.6.5 (CR2-V1-5): führende NA werden übersprungen (Start mit dem SMA der ersten n vorhandenen Werte)
function _ema(x, n)
    x = DP._as_numeric(x)
    f = findfirst(v -> !isnan(v), x)
    if f !== nothing && f > 1
        out = fill(NA, length(x)); out[f:end] = _ema(x[f:end], n); return out
    end
    n = _asint(n)
    m = length(x)
    out = fill(NA, m)
    (n < 1 || n > m) && return out
    a = 2 / (n + 1)
    out[n] = SimLev.r_mean(x[1:n])
    if n < m
        # seit 1.6.4 (T3-R4) direkt über den Kern sl_r_filter_rec (gleiche Bits wie filter(method = "recursive")): r_filter
        # gab bei einem Wert (n = m - 1) einen Skalar, vec() brach ab; spart zudem die Zwischenkopien von r_filter
        out[n+1:m] .= SimLev._rb_filter(convert(Vector{Float64}, a .* @view(x[n+1:m])), Float64[1 - a], true, 2, false, Float64[out[n]])
    end
    return out
end

# Vergleich mit R-Semantik: NA in einem Operanden → NA (missing)
function _cmp(op, a, b)
    out = Vector{Union{Missing,Bool}}(undef, length(a))
    for i in eachindex(a)
        out[i] = (isnan(a[i]) || isnan(b[i])) ? missing : op(a[i], b[i])
    end
    out
end

_lglvec(v) = v isa AbstractVector ? v : [v]

"""
    _sig_out(buy, sell, lag = 0)

Signale um `lag` Zeilen verzögern und NA durch `false` ersetzen.
"""
function _sig_out(buy, sell, lag = 0)
    lag = _asint(lag)
    buy = _lglvec(buy); sell = _lglvec(sell)
    if lag > 0
        m = length(buy)
        lag = min(lag, m)   # seit 1.6.4 (B-024): lag >= Länge ergibt nur false
        buy = vcat(fill(false, lag), buy[1:max(m - lag, 0)])
        sell = vcat(fill(false, lag), sell[1:max(m - lag, 0)])
    end
    tf(v) = Bool[!(e === missing || e === nothing || (e isa AbstractFloat && isnan(e))) && Bool(e) for e in v]
    return RList("buy" => tf(buy), "sell" => tf(sell))
end

"""
    signal_sma(x, n = 200; band = 0, lag = 0)

Kurs über/unter dem einfachen gleitenden Durchschnitt der letzten `n` Zeilen.

Erzeugen Kauf- und Verkaufssignale aus einer Kursreihe, im Format, das `bootstrap_study()` und
`param_search()` für `signal = function(df) ...` erwarten: Die Elemente `buy` und `sell` werden dort als
gleichnamige Spalten an den Datensatz angehängt. Für `simulation()` hängt man sie selbst an und nennt sie in
`asset_config()` (`trading = "signal"`, `signal_buy`, `signal_sell`); für `tactical_rules()` lassen sie sich
direkt als Bedingung verwenden.

# Argumente
- `x`: Numerischer Vektor mit Kursniveaus (z. B. `df["eu"]`).
- `n`: Fensterlänge in Zeilen (Standard: 200 bei `signal_sma` und `signal_ema`, 250 bei `signal_momentum`, 20
  bei `signal_volatility`).
- `band`: Hysterese-Band (Standard 0 = keins): bei Durchschnitten in Prozent des Durchschnitts (1 = 1 %), bei
  `signal_momentum` und `signal_volatility` in Prozentpunkten um `threshold`.
- `lag`: Verzögerung der Signale in Zeilen (Standard 0; z. B. 1, um erst in der Folgezeile zu handeln). Die
  ersten `lag` Zeilen sind `false`.

# Rückgabe
`RList("buy" => …, "sell" => …)` mit logischen Vektoren der Länge von `x` (NA als `false`).

# Details
Eingabe ist ein numerischer Vektor mit Kursniveaus (keine Renditen), z. B. eine Spalte aus `series_align()`.
Alle Fenster (`n`, `fast`, `slow`, `window`, `lag`) zählen in Zeilen der Daten, bei Kalendertagsdaten
(Wochenenden per LOCF) also in Kalendertagen, bei Handelstagsdaten in Handelstagen. Solange ein Fenster noch
nicht gefüllt ist, sind beide Signale `false` (außer bei `signal_drawdown`, das anfangs das Hoch der
bisherigen Zeilen verwendet). `x` sollte keine NA enthalten: Bei Durchschnitten liefern Fenster mit NA kein
Signal, beim exponentiellen Durchschnitt auch alle folgenden Zeilen; bei `signal_drawdown` nur die Zeile mit
NA (das Hoch wird ohne sie fortgeführt).

Eingaben (seit 1.6.4 geprüft): `x` ein numerischer Vektor (keine Matrix, Tabelle, kein Text, keine
Wahrheitswerte; leer erlaubt); `n`, `fast`, `slow`, `window` je eine endliche Zahl `>= 1`, `lag >= 0` (seit 1.6.4
ganze Zahlen, gebrochene Werte sind ein Fehler; `lag` ab der Länge von `x` ergibt nur `false`); `band >= 0`; `sell_dd`, `buy_dd`
größer 0 und höchstens 100; bei `signal_volatility` `threshold >= 0` und `ppy > 0`; bei `signal_combine` `buy` und
`sell` je true/false oder 0/1 (NA bleibt NA: Ergebnis dann `Union{Missing,Bool}`).

`band` wirkt als Hysterese: Zwischen Kauf- und Verkaufsschwelle sind beide Signale `false`, der Zustand in
`simulation()` bzw. `signal_state()` bleibt dann unverändert. Bei Durchschnitten (`signal_sma`, `signal_ema`,
`signal_crossover`) ist `band` relativ zum Durchschnitt in Prozent, bei `signal_momentum` und
`signal_volatility` ein Abstand in Prozentpunkten zu `threshold`.

- signal_sma: Kurs über/unter dem einfachen gleitenden Durchschnitt der letzten `n` Zeilen (einschließlich der
  aktuellen): Kauf ab `SMA * (1 + band/100)`, Verkauf unter `SMA * (1 - band/100)`, dazwischen bleibt der
  Zustand.
- signal_ema: Wie `signal_sma` mit exponentiellem Durchschnitt (Glättung 2 / (n + 1), Start mit dem einfachen
  Mittel der ersten `n` Werte).
- signal_crossover: Schneller über langsamem Durchschnitt: Kauf, wenn der schnelle mindestens das `(1 +
  band/100)`-fache des langsamen erreicht, Verkauf unter dem `(1 - band/100)`-fachen.
- signal_momentum: Rendite über `n` Zeilen in Prozent: Kauf ab `threshold + band`, Verkauf unter `threshold -
  band`.
- signal_drawdown: Verkauf ab `sell_dd` Prozent unter dem (rollierenden) Hoch, Kauf (Wiedereinstieg), solange
  der Abstand unter `buy_dd` Prozent liegt; dazwischen bleibt der Zustand.
- signal_volatility: Realisierte Volatilität der Log-Renditen über `n` Zeilen, annualisiert mit `ppy`, in
  Prozent p. a.: Kauf bis `threshold - band`, Verkauf über `threshold + band`.
- signal_combine: Verknüpft Signale: `"and"` kauft nur, wenn alle kaufen, und verkauft, sobald eines verkauft;
  `"or"` kauft, sobald eines kauft, und verkauft nur, wenn alle verkaufen.

# Beispiel
```julia
using SimLev, Dates, Random
rng = MersenneTwister(1)
n = 1000
d = RFrame("date" => Date(2018, 1, 1) .+ Day.(0:n-1))
d["A"] = 100 .* cumprod(1 .+ 2e-4 .+ 0.01 .* randn(rng, n))
s = signal_sma(d["A"], 200; band = 1, lag = 1)
d["buy"] = s["buy"]; d["sell"] = s["sell"]
res = simulation(d, create_strategy(A = asset_config("etf", "signal"; signal_buy = "buy", signal_sell = "sell")))
println(res["buys"], " ", res["sells"])
```
"""
function signal_sma(x, n_ = nothing; n = 200, band = 0, lag = 0)
    n_ === nothing || (n = n_)
    fn = "signal_sma"
    _sig_x(x, fn); n = _sig_win(n, fn, "n"); band = chk_num1(band, fn, "band"; lo = 0); lag = _sig_win(lag, fn, "lag"; lo = 0)
    xv = DP._as_numeric(x)
    s = _roll_mean(xv, n)
    return _sig_out(_cmp(>=, xv, s .* (1 + band / 100)), _cmp(<, xv, s .* (1 - band / 100)), lag)
end

"""
    signal_ema(x, n_ = nothing; n = 200, band = 0, lag = 0)

Wie `signal_sma` mit exponentiellem Durchschnitt (Glättung 2/(n+1)).

Erzeugen Kauf- und Verkaufssignale aus einer Kursreihe, im Format, das `bootstrap_study()` und
`param_search()` für `signal = function(df) ...` erwarten: Die Elemente `buy` und `sell` werden dort als
gleichnamige Spalten an den Datensatz angehängt. Für `simulation()` hängt man sie selbst an und nennt sie in
`asset_config()` (`trading = "signal"`, `signal_buy`, `signal_sell`); für `tactical_rules()` lassen sie sich
direkt als Bedingung verwenden.

# Argumente
- `x`: Numerischer Vektor mit Kursniveaus (z. B. `df["eu"]`).
- `n`: Fensterlänge in Zeilen (Standard: 200 bei `signal_sma` und `signal_ema`, 250 bei `signal_momentum`, 20
  bei `signal_volatility`).
- `band`: Hysterese-Band (Standard 0 = keins): bei Durchschnitten in Prozent des Durchschnitts (1 = 1 %), bei
  `signal_momentum` und `signal_volatility` in Prozentpunkten um `threshold`.
- `lag`: Verzögerung der Signale in Zeilen (Standard 0; z. B. 1, um erst in der Folgezeile zu handeln). Die
  ersten `lag` Zeilen sind `false`.

# Rückgabe
`RList("buy" => …, "sell" => …)` mit logischen Vektoren der Länge von `x` (NA als `false`).

# Details
Eingabe ist ein numerischer Vektor mit Kursniveaus (keine Renditen), z. B. eine Spalte aus `series_align()`.
Alle Fenster (`n`, `fast`, `slow`, `window`, `lag`) zählen in Zeilen der Daten, bei Kalendertagsdaten
(Wochenenden per LOCF) also in Kalendertagen, bei Handelstagsdaten in Handelstagen. Solange ein Fenster noch
nicht gefüllt ist, sind beide Signale `false` (außer bei `signal_drawdown`, das anfangs das Hoch der
bisherigen Zeilen verwendet). `x` sollte keine NA enthalten: Bei Durchschnitten liefern Fenster mit NA kein
Signal, beim exponentiellen Durchschnitt auch alle folgenden Zeilen; bei `signal_drawdown` nur die Zeile mit
NA (das Hoch wird ohne sie fortgeführt).

Eingaben (seit 1.6.4 geprüft): `x` ein numerischer Vektor (keine Matrix, Tabelle, kein Text, keine
Wahrheitswerte; leer erlaubt); `n`, `fast`, `slow`, `window` je eine endliche Zahl `>= 1`, `lag >= 0` (seit 1.6.4
ganze Zahlen, gebrochene Werte sind ein Fehler; `lag` ab der Länge von `x` ergibt nur `false`); `band >= 0`; `sell_dd`, `buy_dd`
größer 0 und höchstens 100; bei `signal_volatility` `threshold >= 0` und `ppy > 0`; bei `signal_combine` `buy` und
`sell` je true/false oder 0/1 (NA bleibt NA: Ergebnis dann `Union{Missing,Bool}`).

`band` wirkt als Hysterese: Zwischen Kauf- und Verkaufsschwelle sind beide Signale `false`, der Zustand in
`simulation()` bzw. `signal_state()` bleibt dann unverändert. Bei Durchschnitten (`signal_sma`, `signal_ema`,
`signal_crossover`) ist `band` relativ zum Durchschnitt in Prozent, bei `signal_momentum` und
`signal_volatility` ein Abstand in Prozentpunkten zu `threshold`.

- signal_sma: Kurs über/unter dem einfachen gleitenden Durchschnitt der letzten `n` Zeilen (einschließlich der
  aktuellen): Kauf ab `SMA * (1 + band/100)`, Verkauf unter `SMA * (1 - band/100)`, dazwischen bleibt der
  Zustand.
- signal_ema: Wie `signal_sma` mit exponentiellem Durchschnitt (Glättung 2 / (n + 1), Start mit dem einfachen
  Mittel der ersten `n` Werte).
- signal_crossover: Schneller über langsamem Durchschnitt: Kauf, wenn der schnelle mindestens das `(1 +
  band/100)`-fache des langsamen erreicht, Verkauf unter dem `(1 - band/100)`-fachen.
- signal_momentum: Rendite über `n` Zeilen in Prozent: Kauf ab `threshold + band`, Verkauf unter `threshold -
  band`.
- signal_drawdown: Verkauf ab `sell_dd` Prozent unter dem (rollierenden) Hoch, Kauf (Wiedereinstieg), solange
  der Abstand unter `buy_dd` Prozent liegt; dazwischen bleibt der Zustand.
- signal_volatility: Realisierte Volatilität der Log-Renditen über `n` Zeilen, annualisiert mit `ppy`, in
  Prozent p. a.: Kauf bis `threshold - band`, Verkauf über `threshold + band`.
- signal_combine: Verknüpft Signale: `"and"` kauft nur, wenn alle kaufen, und verkauft, sobald eines verkauft;
  `"or"` kauft, sobald eines kauft, und verkauft nur, wenn alle verkaufen.

# Beispiel
```julia
using SimLev, Random
x = 100 .* cumprod(1 .+ 2e-4 .+ 0.01 .* randn(MersenneTwister(1), 1000))
println(sum(signal_ema(x; n = 200, band = 1)["buy"]))
```
"""
function signal_ema(x, n_ = nothing; n = 200, band = 0, lag = 0)
    n_ === nothing || (n = n_)
    fn = "signal_ema"
    _sig_x(x, fn); n = _sig_win(n, fn, "n"); band = chk_num1(band, fn, "band"; lo = 0); lag = _sig_win(lag, fn, "lag"; lo = 0)
    xv = DP._as_numeric(x)
    _sig_ema_na(xv, fn)
    s = _ema(xv, n)
    return _sig_out(_cmp(>=, xv, s .* (1 + band / 100)), _cmp(<, xv, s .* (1 - band / 100)), lag)
end

"""
    signal_crossover(x, fast = 50, slow = 200; type = "sma", band = 0, lag = 0)

Schneller über langsamem Durchschnitt.

Erzeugen Kauf- und Verkaufssignale aus einer Kursreihe, im Format, das `bootstrap_study()` und
`param_search()` für `signal = function(df) ...` erwarten: Die Elemente `buy` und `sell` werden dort als
gleichnamige Spalten an den Datensatz angehängt. Für `simulation()` hängt man sie selbst an und nennt sie in
`asset_config()` (`trading = "signal"`, `signal_buy`, `signal_sell`); für `tactical_rules()` lassen sie sich
direkt als Bedingung verwenden.

# Argumente
- `x`: Numerischer Vektor mit Kursniveaus (z. B. `df["eu"]`).
- `fast`, `slow`: Fensterlängen in Zeilen für den schnellen und den langsamen Durchschnitt (Standard 50 und
  200; `fast < slow`).
- `type`: Art der Durchschnitte bei `signal_crossover`: `"sma"` (Standard) oder `"ema"`.
- `band`: Hysterese-Band (Standard 0 = keins): bei Durchschnitten in Prozent des Durchschnitts (1 = 1 %), bei
  `signal_momentum` und `signal_volatility` in Prozentpunkten um `threshold`.
- `lag`: Verzögerung der Signale in Zeilen (Standard 0; z. B. 1, um erst in der Folgezeile zu handeln). Die
  ersten `lag` Zeilen sind `false`.

# Rückgabe
`RList("buy" => …, "sell" => …)` mit logischen Vektoren der Länge von `x` (NA als `false`).

# Details
Eingabe ist ein numerischer Vektor mit Kursniveaus (keine Renditen), z. B. eine Spalte aus `series_align()`.
Alle Fenster (`n`, `fast`, `slow`, `window`, `lag`) zählen in Zeilen der Daten, bei Kalendertagsdaten
(Wochenenden per LOCF) also in Kalendertagen, bei Handelstagsdaten in Handelstagen. Solange ein Fenster noch
nicht gefüllt ist, sind beide Signale `false` (außer bei `signal_drawdown`, das anfangs das Hoch der
bisherigen Zeilen verwendet). `x` sollte keine NA enthalten: Bei Durchschnitten liefern Fenster mit NA kein
Signal, beim exponentiellen Durchschnitt auch alle folgenden Zeilen; bei `signal_drawdown` nur die Zeile mit
NA (das Hoch wird ohne sie fortgeführt).

Eingaben (seit 1.6.4 geprüft): `x` ein numerischer Vektor (keine Matrix, Tabelle, kein Text, keine
Wahrheitswerte; leer erlaubt); `n`, `fast`, `slow`, `window` je eine endliche Zahl `>= 1`, `lag >= 0` (seit 1.6.4
ganze Zahlen, gebrochene Werte sind ein Fehler; `lag` ab der Länge von `x` ergibt nur `false`); `band >= 0`; `sell_dd`, `buy_dd`
größer 0 und höchstens 100; bei `signal_volatility` `threshold >= 0` und `ppy > 0`; bei `signal_combine` `buy` und
`sell` je true/false oder 0/1 (NA bleibt NA: Ergebnis dann `Union{Missing,Bool}`).

`band` wirkt als Hysterese: Zwischen Kauf- und Verkaufsschwelle sind beide Signale `false`, der Zustand in
`simulation()` bzw. `signal_state()` bleibt dann unverändert. Bei Durchschnitten (`signal_sma`, `signal_ema`,
`signal_crossover`) ist `band` relativ zum Durchschnitt in Prozent, bei `signal_momentum` und
`signal_volatility` ein Abstand in Prozentpunkten zu `threshold`.

- signal_sma: Kurs über/unter dem einfachen gleitenden Durchschnitt der letzten `n` Zeilen (einschließlich der
  aktuellen): Kauf ab `SMA * (1 + band/100)`, Verkauf unter `SMA * (1 - band/100)`, dazwischen bleibt der
  Zustand.
- signal_ema: Wie `signal_sma` mit exponentiellem Durchschnitt (Glättung 2 / (n + 1), Start mit dem einfachen
  Mittel der ersten `n` Werte).
- signal_crossover: Schneller über langsamem Durchschnitt: Kauf, wenn der schnelle mindestens das `(1 +
  band/100)`-fache des langsamen erreicht, Verkauf unter dem `(1 - band/100)`-fachen.
- signal_momentum: Rendite über `n` Zeilen in Prozent: Kauf ab `threshold + band`, Verkauf unter `threshold -
  band`.
- signal_drawdown: Verkauf ab `sell_dd` Prozent unter dem (rollierenden) Hoch, Kauf (Wiedereinstieg), solange
  der Abstand unter `buy_dd` Prozent liegt; dazwischen bleibt der Zustand.
- signal_volatility: Realisierte Volatilität der Log-Renditen über `n` Zeilen, annualisiert mit `ppy`, in
  Prozent p. a.: Kauf bis `threshold - band`, Verkauf über `threshold + band`.
- signal_combine: Verknüpft Signale: `"and"` kauft nur, wenn alle kaufen, und verkauft, sobald eines verkauft;
  `"or"` kauft, sobald eines kauft, und verkauft nur, wenn alle verkaufen.

# Beispiel
```julia
using SimLev, Random
x = 100 .* cumprod(1 .+ 2e-4 .+ 0.01 .* randn(MersenneTwister(1), 1000))
println(sum(signal_crossover(x, 50, 200)["buy"]))
```
"""
function signal_crossover(x, fast_ = nothing, slow_ = nothing; fast = 50, slow = 200, type = ("sma", "ema"), band = 0, lag = 0)
    fast_ === nothing || (fast = fast_)
    slow_ === nothing || (slow = slow_)
    fn = "signal_crossover"
    _sig_x(x, fn); fast = _sig_win(fast, fn, "fast"); slow = _sig_win(slow, fn, "slow")
    type_ = DP._match_arg(chk_scalar(type), ("sma", "ema"))
    fast >= slow && chk_stop("b2b.m_signal_crossover")
    band = chk_num1(band, fn, "band"; lo = 0); lag = _sig_win(lag, fn, "lag"; lo = 0)
    xv = DP._as_numeric(x)
    type_ == "ema" && _sig_ema_na(xv, fn)
    f = type_ == "sma" ? _roll_mean(xv, fast) : _ema(xv, fast)
    s = type_ == "sma" ? _roll_mean(xv, slow) : _ema(xv, slow)
    return _sig_out(_cmp(>=, f, s .* (1 + band / 100)), _cmp(<, f, s .* (1 - band / 100)), lag)
end

"""
    signal_momentum(x, n = 250; threshold = 0, band = 0, lag = 0)

Rendite über `n` Zeilen in Prozent: Kauf ab `threshold + band`, Verkauf unter `threshold - band`.

Erzeugen Kauf- und Verkaufssignale aus einer Kursreihe, im Format, das `bootstrap_study()` und
`param_search()` für `signal = function(df) ...` erwarten: Die Elemente `buy` und `sell` werden dort als
gleichnamige Spalten an den Datensatz angehängt. Für `simulation()` hängt man sie selbst an und nennt sie in
`asset_config()` (`trading = "signal"`, `signal_buy`, `signal_sell`); für `tactical_rules()` lassen sie sich
direkt als Bedingung verwenden.

# Argumente
- `x`: Numerischer Vektor mit Kursniveaus (z. B. `df["eu"]`).
- `n`: Fensterlänge in Zeilen (Standard: 200 bei `signal_sma` und `signal_ema`, 250 bei `signal_momentum`, 20
  bei `signal_volatility`).
- `threshold`: Schwelle in Prozent: bei `signal_momentum` für die Rendite über `n` Zeilen (Standard 0), bei
  `signal_volatility` für die Volatilität in Prozent p. a. (Standard 25).
- `band`: Hysterese-Band (Standard 0 = keins): bei Durchschnitten in Prozent des Durchschnitts (1 = 1 %), bei
  `signal_momentum` und `signal_volatility` in Prozentpunkten um `threshold`.
- `lag`: Verzögerung der Signale in Zeilen (Standard 0; z. B. 1, um erst in der Folgezeile zu handeln). Die
  ersten `lag` Zeilen sind `false`.

# Rückgabe
`RList("buy" => …, "sell" => …)` mit logischen Vektoren der Länge von `x` (NA als `false`).

# Details
Eingabe ist ein numerischer Vektor mit Kursniveaus (keine Renditen), z. B. eine Spalte aus `series_align()`.
Alle Fenster (`n`, `fast`, `slow`, `window`, `lag`) zählen in Zeilen der Daten, bei Kalendertagsdaten
(Wochenenden per LOCF) also in Kalendertagen, bei Handelstagsdaten in Handelstagen. Solange ein Fenster noch
nicht gefüllt ist, sind beide Signale `false` (außer bei `signal_drawdown`, das anfangs das Hoch der
bisherigen Zeilen verwendet). `x` sollte keine NA enthalten: Bei Durchschnitten liefern Fenster mit NA kein
Signal, beim exponentiellen Durchschnitt auch alle folgenden Zeilen; bei `signal_drawdown` nur die Zeile mit
NA (das Hoch wird ohne sie fortgeführt).

Eingaben (seit 1.6.4 geprüft): `x` ein numerischer Vektor (keine Matrix, Tabelle, kein Text, keine
Wahrheitswerte; leer erlaubt); `n`, `fast`, `slow`, `window` je eine endliche Zahl `>= 1`, `lag >= 0` (seit 1.6.4
ganze Zahlen, gebrochene Werte sind ein Fehler; `lag` ab der Länge von `x` ergibt nur `false`); `band >= 0`; `sell_dd`, `buy_dd`
größer 0 und höchstens 100; bei `signal_volatility` `threshold >= 0` und `ppy > 0`; bei `signal_combine` `buy` und
`sell` je true/false oder 0/1 (NA bleibt NA: Ergebnis dann `Union{Missing,Bool}`).

`band` wirkt als Hysterese: Zwischen Kauf- und Verkaufsschwelle sind beide Signale `false`, der Zustand in
`simulation()` bzw. `signal_state()` bleibt dann unverändert. Bei Durchschnitten (`signal_sma`, `signal_ema`,
`signal_crossover`) ist `band` relativ zum Durchschnitt in Prozent, bei `signal_momentum` und
`signal_volatility` ein Abstand in Prozentpunkten zu `threshold`.

- signal_sma: Kurs über/unter dem einfachen gleitenden Durchschnitt der letzten `n` Zeilen (einschließlich der
  aktuellen): Kauf ab `SMA * (1 + band/100)`, Verkauf unter `SMA * (1 - band/100)`, dazwischen bleibt der
  Zustand.
- signal_ema: Wie `signal_sma` mit exponentiellem Durchschnitt (Glättung 2 / (n + 1), Start mit dem einfachen
  Mittel der ersten `n` Werte).
- signal_crossover: Schneller über langsamem Durchschnitt: Kauf, wenn der schnelle mindestens das `(1 +
  band/100)`-fache des langsamen erreicht, Verkauf unter dem `(1 - band/100)`-fachen.
- signal_momentum: Rendite über `n` Zeilen in Prozent: Kauf ab `threshold + band`, Verkauf unter `threshold -
  band`.
- signal_drawdown: Verkauf ab `sell_dd` Prozent unter dem (rollierenden) Hoch, Kauf (Wiedereinstieg), solange
  der Abstand unter `buy_dd` Prozent liegt; dazwischen bleibt der Zustand.
- signal_volatility: Realisierte Volatilität der Log-Renditen über `n` Zeilen, annualisiert mit `ppy`, in
  Prozent p. a.: Kauf bis `threshold - band`, Verkauf über `threshold + band`.
- signal_combine: Verknüpft Signale: `"and"` kauft nur, wenn alle kaufen, und verkauft, sobald eines verkauft;
  `"or"` kauft, sobald eines kauft, und verkauft nur, wenn alle verkaufen.

# Beispiel
```julia
using SimLev, Random
x = 100 .* cumprod(1 .+ 2e-4 .+ 0.01 .* randn(MersenneTwister(1), 1000))
println(sum(signal_momentum(x, 250)["buy"]))
```
"""
function signal_momentum(x, n_ = nothing; n = 250, threshold = 0, band = 0, lag = 0)
    n_ === nothing || (n = n_)
    fn = "signal_momentum"
    _sig_x(x, fn); n = _sig_win(n, fn, "n"); threshold = chk_num1(threshold, fn, "threshold")
    band = chk_num1(band, fn, "band"; lo = 0); lag = _sig_win(lag, fn, "lag"; lo = 0)
    x = DP._as_numeric(x)
    m = length(x)
    n = _asint(n)
    r = fill(NA, m)
    if n < m
        for i in n+1:m
            r[i] = 100 * (x[i] / x[i-n] - 1)
        end
    end
    return _sig_out(_cmp(>=, r, fill(threshold + band, m)), _cmp(<, r, fill(threshold - band, m)), lag)
end

"""
    signal_drawdown(x, sell_dd = 20, buy_dd = 10; window = nothing, lag = 0)

Verkauf ab `sell_dd` Prozent unter dem (rollierenden) Hoch, Kauf unter `buy_dd` Prozent.

Erzeugen Kauf- und Verkaufssignale aus einer Kursreihe, im Format, das `bootstrap_study()` und
`param_search()` für `signal = function(df) ...` erwarten: Die Elemente `buy` und `sell` werden dort als
gleichnamige Spalten an den Datensatz angehängt. Für `simulation()` hängt man sie selbst an und nennt sie in
`asset_config()` (`trading = "signal"`, `signal_buy`, `signal_sell`); für `tactical_rules()` lassen sie sich
direkt als Bedingung verwenden.

# Argumente
- `x`: Numerischer Vektor mit Kursniveaus (z. B. `df["eu"]`).
- `sell_dd`, `buy_dd`: Abstand zum Hoch in Prozent (positiv, 20 = 20 % unter dem Hoch); `buy_dd` darf nicht
  größer als `sell_dd` sein (Standard 20 und 10).
- `window`: Fenster in Zeilen für das rollierende Hoch (Standard `nothing` = laufendes Hoch seit Beginn).
- `lag`: Verzögerung der Signale in Zeilen (Standard 0; z. B. 1, um erst in der Folgezeile zu handeln). Die
  ersten `lag` Zeilen sind `false`.

# Rückgabe
`RList("buy" => …, "sell" => …)` mit logischen Vektoren der Länge von `x` (NA als `false`).

# Details
Eingabe ist ein numerischer Vektor mit Kursniveaus (keine Renditen), z. B. eine Spalte aus `series_align()`.
Alle Fenster (`n`, `fast`, `slow`, `window`, `lag`) zählen in Zeilen der Daten, bei Kalendertagsdaten
(Wochenenden per LOCF) also in Kalendertagen, bei Handelstagsdaten in Handelstagen. Solange ein Fenster noch
nicht gefüllt ist, sind beide Signale `false` (außer bei `signal_drawdown`, das anfangs das Hoch der
bisherigen Zeilen verwendet). `x` sollte keine NA enthalten: Bei Durchschnitten liefern Fenster mit NA kein
Signal, beim exponentiellen Durchschnitt auch alle folgenden Zeilen; bei `signal_drawdown` nur die Zeile mit
NA (das Hoch wird ohne sie fortgeführt).

Eingaben (seit 1.6.4 geprüft): `x` ein numerischer Vektor (keine Matrix, Tabelle, kein Text, keine
Wahrheitswerte; leer erlaubt); `n`, `fast`, `slow`, `window` je eine endliche Zahl `>= 1`, `lag >= 0` (seit 1.6.4
ganze Zahlen, gebrochene Werte sind ein Fehler; `lag` ab der Länge von `x` ergibt nur `false`); `band >= 0`; `sell_dd`, `buy_dd`
größer 0 und höchstens 100; bei `signal_volatility` `threshold >= 0` und `ppy > 0`; bei `signal_combine` `buy` und
`sell` je true/false oder 0/1 (NA bleibt NA: Ergebnis dann `Union{Missing,Bool}`).

`band` wirkt als Hysterese: Zwischen Kauf- und Verkaufsschwelle sind beide Signale `false`, der Zustand in
`simulation()` bzw. `signal_state()` bleibt dann unverändert. Bei Durchschnitten (`signal_sma`, `signal_ema`,
`signal_crossover`) ist `band` relativ zum Durchschnitt in Prozent, bei `signal_momentum` und
`signal_volatility` ein Abstand in Prozentpunkten zu `threshold`.

- signal_sma: Kurs über/unter dem einfachen gleitenden Durchschnitt der letzten `n` Zeilen (einschließlich der
  aktuellen): Kauf ab `SMA * (1 + band/100)`, Verkauf unter `SMA * (1 - band/100)`, dazwischen bleibt der
  Zustand.
- signal_ema: Wie `signal_sma` mit exponentiellem Durchschnitt (Glättung 2 / (n + 1), Start mit dem einfachen
  Mittel der ersten `n` Werte).
- signal_crossover: Schneller über langsamem Durchschnitt: Kauf, wenn der schnelle mindestens das `(1 +
  band/100)`-fache des langsamen erreicht, Verkauf unter dem `(1 - band/100)`-fachen.
- signal_momentum: Rendite über `n` Zeilen in Prozent: Kauf ab `threshold + band`, Verkauf unter `threshold -
  band`.
- signal_drawdown: Verkauf ab `sell_dd` Prozent unter dem (rollierenden) Hoch, Kauf (Wiedereinstieg), solange
  der Abstand unter `buy_dd` Prozent liegt; dazwischen bleibt der Zustand.
- signal_volatility: Realisierte Volatilität der Log-Renditen über `n` Zeilen, annualisiert mit `ppy`, in
  Prozent p. a.: Kauf bis `threshold - band`, Verkauf über `threshold + band`.
- signal_combine: Verknüpft Signale: `"and"` kauft nur, wenn alle kaufen, und verkauft, sobald eines verkauft;
  `"or"` kauft, sobald eines kauft, und verkauft nur, wenn alle verkaufen.

# Beispiel
```julia
using SimLev, Random
x = 100 .* cumprod(1 .+ 2e-4 .+ 0.01 .* randn(MersenneTwister(1), 1000))
println(sum(signal_drawdown(x, 20, 10)["sell"]))
```
"""
function signal_drawdown(x, sell_dd_ = nothing, buy_dd_ = nothing; sell_dd = 20, buy_dd = 10, window = nothing, lag = 0)
    sell_dd_ === nothing || (sell_dd = sell_dd_)
    buy_dd_ === nothing || (buy_dd = buy_dd_)
    fn = "signal_drawdown"
    _sig_x(x, fn)
    sell_dd = chk_num1(sell_dd, fn, "sell_dd"; lo = 0, lo_open = true, hi = 100)
    buy_dd = chk_num1(buy_dd, fn, "buy_dd"; lo = 0, lo_open = true, hi = 100)
    window = _sig_win(window, fn, "window"; null_ok = true); lag = _sig_win(lag, fn, "lag"; lo = 0)
    x = DP._as_numeric(x)
    buy_dd > sell_dd && chk_stop("b2b.m_signal_drawdown")
    m = length(x)
    xp = Float64[isnan(v) ? -Inf : v for v in x]
    peak = Vector{Float64}(undef, m)
    if window === nothing
        cur = -Inf
        for i in 1:m
            v = xp[i]
            (i == 1 || v > cur) && (cur = v)
            peak[i] = cur
        end
    else
        w = _asint(window)
        if w >= 1   # gleitendes Maximum im Kern (seit 1.6.3; bis 1.6.2 maximum je Fenster, O(m·w)), bitgleich
            peak = SC.roll_max_core(xp, w)
        else        # w < 1: wie bisher (Fehler aus maximum über ein leeres Fenster)
            for i in 1:m
                peak[i] = maximum(xp[max(1, i - w + 1):i])
            end
        end
    end
    dd = Float64[100 * (1 - x[i] / peak[i]) for i in 1:m]
    return _sig_out(_cmp(<, dd, fill(Float64(buy_dd), m)), _cmp(>=, dd, fill(Float64(sell_dd), m)), lag)
end

"""
    signal_volatility(x, n = 20; threshold = 25, band = 0, ppy = 365.25, lag = 0)

Realisierte Volatilität der Log-Renditen über `n` Zeilen in Prozent p. a.

Erzeugen Kauf- und Verkaufssignale aus einer Kursreihe, im Format, das `bootstrap_study()` und
`param_search()` für `signal = function(df) ...` erwarten: Die Elemente `buy` und `sell` werden dort als
gleichnamige Spalten an den Datensatz angehängt. Für `simulation()` hängt man sie selbst an und nennt sie in
`asset_config()` (`trading = "signal"`, `signal_buy`, `signal_sell`); für `tactical_rules()` lassen sie sich
direkt als Bedingung verwenden.

# Argumente
- `x`: Numerischer Vektor mit Kursniveaus (z. B. `df["eu"]`).
- `n`: Fensterlänge in Zeilen (Standard: 200 bei `signal_sma` und `signal_ema`, 250 bei `signal_momentum`, 20
  bei `signal_volatility`).
- `threshold`: Schwelle in Prozent: bei `signal_momentum` für die Rendite über `n` Zeilen (Standard 0), bei
  `signal_volatility` für die Volatilität in Prozent p. a. (Standard 25).
- `band`: Hysterese-Band (Standard 0 = keins): bei Durchschnitten in Prozent des Durchschnitts (1 = 1 %), bei
  `signal_momentum` und `signal_volatility` in Prozentpunkten um `threshold`.
- `ppy`: Zeilen je Jahr für die Annualisierung der Volatilität (Standard 365.25 für Kalendertagsdaten; bei
  Handelstagsdaten z. B. 252). Wird nicht aus den Daten ermittelt.
- `lag`: Verzögerung der Signale in Zeilen (Standard 0; z. B. 1, um erst in der Folgezeile zu handeln). Die
  ersten `lag` Zeilen sind `false`.

# Rückgabe
`RList("buy" => …, "sell" => …)` mit logischen Vektoren der Länge von `x` (NA als `false`).

# Details
Eingabe ist ein numerischer Vektor mit Kursniveaus (keine Renditen), z. B. eine Spalte aus `series_align()`.
Alle Fenster (`n`, `fast`, `slow`, `window`, `lag`) zählen in Zeilen der Daten, bei Kalendertagsdaten
(Wochenenden per LOCF) also in Kalendertagen, bei Handelstagsdaten in Handelstagen. Solange ein Fenster noch
nicht gefüllt ist, sind beide Signale `false` (außer bei `signal_drawdown`, das anfangs das Hoch der
bisherigen Zeilen verwendet). `x` sollte keine NA enthalten: Bei Durchschnitten liefern Fenster mit NA kein
Signal, beim exponentiellen Durchschnitt auch alle folgenden Zeilen; bei `signal_drawdown` nur die Zeile mit
NA (das Hoch wird ohne sie fortgeführt).

Eingaben (seit 1.6.4 geprüft): `x` ein numerischer Vektor (keine Matrix, Tabelle, kein Text, keine
Wahrheitswerte; leer erlaubt); `n`, `fast`, `slow`, `window` je eine endliche Zahl `>= 1`, `lag >= 0` (seit 1.6.4
ganze Zahlen, gebrochene Werte sind ein Fehler; `lag` ab der Länge von `x` ergibt nur `false`); `band >= 0`; `sell_dd`, `buy_dd`
größer 0 und höchstens 100; bei `signal_volatility` `threshold >= 0` und `ppy > 0`; bei `signal_combine` `buy` und
`sell` je true/false oder 0/1 (NA bleibt NA: Ergebnis dann `Union{Missing,Bool}`).

`band` wirkt als Hysterese: Zwischen Kauf- und Verkaufsschwelle sind beide Signale `false`, der Zustand in
`simulation()` bzw. `signal_state()` bleibt dann unverändert. Bei Durchschnitten (`signal_sma`, `signal_ema`,
`signal_crossover`) ist `band` relativ zum Durchschnitt in Prozent, bei `signal_momentum` und
`signal_volatility` ein Abstand in Prozentpunkten zu `threshold`.

- signal_sma: Kurs über/unter dem einfachen gleitenden Durchschnitt der letzten `n` Zeilen (einschließlich der
  aktuellen): Kauf ab `SMA * (1 + band/100)`, Verkauf unter `SMA * (1 - band/100)`, dazwischen bleibt der
  Zustand.
- signal_ema: Wie `signal_sma` mit exponentiellem Durchschnitt (Glättung 2 / (n + 1), Start mit dem einfachen
  Mittel der ersten `n` Werte).
- signal_crossover: Schneller über langsamem Durchschnitt: Kauf, wenn der schnelle mindestens das `(1 +
  band/100)`-fache des langsamen erreicht, Verkauf unter dem `(1 - band/100)`-fachen.
- signal_momentum: Rendite über `n` Zeilen in Prozent: Kauf ab `threshold + band`, Verkauf unter `threshold -
  band`.
- signal_drawdown: Verkauf ab `sell_dd` Prozent unter dem (rollierenden) Hoch, Kauf (Wiedereinstieg), solange
  der Abstand unter `buy_dd` Prozent liegt; dazwischen bleibt der Zustand.
- signal_volatility: Realisierte Volatilität der Log-Renditen über `n` Zeilen, annualisiert mit `ppy`, in
  Prozent p. a.: Kauf bis `threshold - band`, Verkauf über `threshold + band`.
- signal_combine: Verknüpft Signale: `"and"` kauft nur, wenn alle kaufen, und verkauft, sobald eines verkauft;
  `"or"` kauft, sobald eines kauft, und verkauft nur, wenn alle verkaufen.

# Beispiel
```julia
using SimLev, Random
x = 100 .* cumprod(1 .+ 2e-4 .+ 0.01 .* randn(MersenneTwister(1), 1000))
println(sum(signal_volatility(x, 20; threshold = 25)["buy"]))
```
"""
function signal_volatility(x, n_ = nothing; n = 20, threshold = 25, band = 0, ppy = 365.25, lag = 0)
    n_ === nothing || (n = n_)
    fn = "signal_volatility"
    # seit 1.6.5 (CR2-R-4): n >= 2, Kurse > 0
    _sig_x(x, fn); n = _sig_win(n, fn, "n"; lo = 2); threshold = chk_num1(threshold, fn, "threshold"; lo = 0)
    band = chk_num1(band, fn, "band"; lo = 0); ppy = chk_num1(ppy, fn, "ppy"; lo = 0, lo_open = true)
    lag = _sig_win(lag, fn, "lag"; lo = 0)
    x = DP._as_numeric(x)
    any(v -> v <= 0, x) && chk_stop("b2.kurs_positiv", fn)
    m = length(x)
    lx = Float64[SimLev.RLibm.log(v) for v in x]
    r = m == 0 ? Float64[] : vcat(NA, Float64[lx[i] - lx[i-1] for i in 2:m])
    r0 = Float64[isnan(v) ? 0.0 : v for v in r]
    rv = _roll_var(r0, n)
    fac = max(n - 1, 1)
    v = Float64[(p = isnan(rv[i]) ? rv[i] : SimLev.r_max2(rv[i], 0.0); 100 * sqrt(p * n / fac * ppy)) for i in 1:m]
    v[1:min(_asint(n), m)] .= NA
    return _sig_out(_cmp(<=, v, fill(threshold - band, m)), _cmp(>, v, fill(threshold + band, m)), lag)
end

_getsig(z, k) = z isa AbstractDict ? get(z, k, nothing) : z isa NamedTuple ? get(z, Symbol(k), nothing) : nothing

"Signalvektor als Vector{Union{Missing,Bool}}; nothing, wenn kein Signal (Text, andere Zahlen, Matrix)."
function _sig_vals(v)
    @nospecialize
    v === nothing && return nothing
    v isa RVector && (v = v.values)
    v isa Union{Bool,Real} && (v = [v])
    (v isa AbstractVector && !(v isa AbstractVector{<:Pair})) || return nothing
    return _sig_vals_typed(v)
end
# seit 1.6.5 (CR2-G-1): je Elementtyp übersetzt (Funktionsbarriere) und als Paar (Werte, NA-Maske) statt Vektor aus
# Union{Missing,Bool} mit push! je Element (bis 1.6.4 rund 55-mal langsamer als R); gleiche Annahme und gleiche Werte
function _sig_vals_typed(v::AbstractVector)
    n = length(v)
    vals = Vector{Bool}(undef, n); na = zeros(Bool, n)
    @inbounds for (i, e) in enumerate(v)
        if e === missing || e === nothing || (e isa AbstractFloat && isnan(e))
            na[i] = true; vals[i] = false
        elseif e isa Bool
            vals[i] = e
        elseif e isa Real && (e == 0 || e == 1)
            vals[i] = e == 1
        else
            return nothing
        end
    end
    return (vals, na)
end
_sig_vals_typed(v::AbstractVector{Bool}) = (collect(Bool, v), zeros(Bool, length(v)))


"""
    signal_combine(signals...; op = "and")

Verknüpft Signale: `"and"` kauft nur, wenn alle kaufen, und verkauft, sobald eines verkauft; `"or"` kauft, sobald eines kauft, und verkauft nur, wenn alle verkaufen.

Erzeugen Kauf- und Verkaufssignale aus einer Kursreihe, im Format, das `bootstrap_study()` und
`param_search()` für `signal = function(df) ...` erwarten: Die Elemente `buy` und `sell` werden dort als
gleichnamige Spalten an den Datensatz angehängt. Für `simulation()` hängt man sie selbst an und nennt sie in
`asset_config()` (`trading = "signal"`, `signal_buy`, `signal_sell`); für `tactical_rules()` lassen sie sich
direkt als Bedingung verwenden.

# Argumente
- `signals...`: Bei `signal_combine`: Signal-Listen `RList("buy" => …, "sell" => …)` gleicher Länge (sonst
  Fehler).
- `op`: Verknüpfung bei `signal_combine`: `"and"` (Standard) oder `"or"`.

# Rückgabe
`RList("buy" => …, "sell" => …)` mit logischen Vektoren der Länge von `x` (NA als `false`).

# Details
Eingabe ist ein numerischer Vektor mit Kursniveaus (keine Renditen), z. B. eine Spalte aus `series_align()`.
Alle Fenster (`n`, `fast`, `slow`, `window`, `lag`) zählen in Zeilen der Daten, bei Kalendertagsdaten
(Wochenenden per LOCF) also in Kalendertagen, bei Handelstagsdaten in Handelstagen. Solange ein Fenster noch
nicht gefüllt ist, sind beide Signale `false` (außer bei `signal_drawdown`, das anfangs das Hoch der
bisherigen Zeilen verwendet). `x` sollte keine NA enthalten: Bei Durchschnitten liefern Fenster mit NA kein
Signal, beim exponentiellen Durchschnitt auch alle folgenden Zeilen; bei `signal_drawdown` nur die Zeile mit
NA (das Hoch wird ohne sie fortgeführt).

Eingaben (seit 1.6.4 geprüft): `x` ein numerischer Vektor (keine Matrix, Tabelle, kein Text, keine
Wahrheitswerte; leer erlaubt); `n`, `fast`, `slow`, `window` je eine endliche Zahl `>= 1`, `lag >= 0` (seit 1.6.4
ganze Zahlen, gebrochene Werte sind ein Fehler; `lag` ab der Länge von `x` ergibt nur `false`); `band >= 0`; `sell_dd`, `buy_dd`
größer 0 und höchstens 100; bei `signal_volatility` `threshold >= 0` und `ppy > 0`; bei `signal_combine` `buy` und
`sell` je true/false oder 0/1 (NA bleibt NA: Ergebnis dann `Union{Missing,Bool}`).

`band` wirkt als Hysterese: Zwischen Kauf- und Verkaufsschwelle sind beide Signale `false`, der Zustand in
`simulation()` bzw. `signal_state()` bleibt dann unverändert. Bei Durchschnitten (`signal_sma`, `signal_ema`,
`signal_crossover`) ist `band` relativ zum Durchschnitt in Prozent, bei `signal_momentum` und
`signal_volatility` ein Abstand in Prozentpunkten zu `threshold`.

- signal_sma: Kurs über/unter dem einfachen gleitenden Durchschnitt der letzten `n` Zeilen (einschließlich der
  aktuellen): Kauf ab `SMA * (1 + band/100)`, Verkauf unter `SMA * (1 - band/100)`, dazwischen bleibt der
  Zustand.
- signal_ema: Wie `signal_sma` mit exponentiellem Durchschnitt (Glättung 2 / (n + 1), Start mit dem einfachen
  Mittel der ersten `n` Werte).
- signal_crossover: Schneller über langsamem Durchschnitt: Kauf, wenn der schnelle mindestens das `(1 +
  band/100)`-fache des langsamen erreicht, Verkauf unter dem `(1 - band/100)`-fachen.
- signal_momentum: Rendite über `n` Zeilen in Prozent: Kauf ab `threshold + band`, Verkauf unter `threshold -
  band`.
- signal_drawdown: Verkauf ab `sell_dd` Prozent unter dem (rollierenden) Hoch, Kauf (Wiedereinstieg), solange
  der Abstand unter `buy_dd` Prozent liegt; dazwischen bleibt der Zustand.
- signal_volatility: Realisierte Volatilität der Log-Renditen über `n` Zeilen, annualisiert mit `ppy`, in
  Prozent p. a.: Kauf bis `threshold - band`, Verkauf über `threshold + band`.
- signal_combine: Verknüpft Signale: `"and"` kauft nur, wenn alle kaufen, und verkauft, sobald eines verkauft;
  `"or"` kauft, sobald eines kauft, und verkauft nur, wenn alle verkaufen.

# Beispiel
```julia
using SimLev, Random
x = 100 .* cumprod(1 .+ 2e-4 .+ 0.01 .* randn(MersenneTwister(1), 1000))
both = signal_combine(signal_sma(x, 200), signal_volatility(x, 20; threshold = 25))
println(sum(both["buy"]))
```
"""
function signal_combine(signals...; op = ("and", "or"))
    op = DP._match_arg(chk_scalar(op), ("and", "or"))
    s = collect(signals)
    isempty(s) && chk_stop("b2b.m_signal_combine")
    # seit 1.6.4 (B-008, Entscheidung 1): je Signal buy und sell, jeweils true/false oder 0/1 (missing/NaN = NA erlaubt,
    # bleibt NA wie in R; bis 1.6.3 brach Julia mit NA ab)
    VB = Tuple{Vector{Bool},Vector{Bool}}[]; VS = Tuple{Vector{Bool},Vector{Bool}}[]
    for (i, z) in enumerate(s)
        b = _sig_vals(_getsig(z, "buy")); c = _sig_vals(_getsig(z, "sell"))
        (b === nothing || c === nothing) && chk_stop("e1.signal", "signal_combine", i)
        push!(VB, b); push!(VS, c)
    end
    len = [length(b[1]) for b in VB]; slen = [length(c[1]) for c in VS]
    (any(!=(len[1]), len) || any(slen .!= len)) &&
        chk_stop("b2b.m_sig_ok", join(len, ", "))
    n = len[1]
    and_ = op == "and"
    if any(v -> any(v[2]), VB) || any(v -> any(v[2]), VS)   # mit NA: dreiwertig wie R
        return RList("buy" => _sig_comb3(VB, and_, n), "sell" => _sig_comb3(VS, !and_, n))
    end
    # seit 1.6.5 (CR2-G-1): spaltenweise mit & bzw. | statt je Zeile über einen Generator
    return RList("buy" => _sig_comb2(VB, and_, n), "sell" => _sig_comb2(VS, !and_, n))
end
# ohne NA: all (conj) bzw. any je Zeile
function _sig_comb2(vs::Vector{Tuple{Vector{Bool},Vector{Bool}}}, conj::Bool, n::Int)
    r = fill(conj, n)
    for (v, _) in vs
        if conj
            @inbounds for i in 1:n; r[i] &= v[i]; end
        else
            @inbounds for i in 1:n; r[i] |= v[i]; end
        end
    end
    return r
end
# mit NA: dreiwertig wie R (ein sicheres false bzw. true entscheidet, sonst NA, wenn ein Wert NA ist)
function _sig_comb3(vs::Vector{Tuple{Vector{Bool},Vector{Bool}}}, conj::Bool, n::Int)
    dec = zeros(Bool, n); anyna = zeros(Bool, n)
    for (v, m) in vs
        @inbounds for i in 1:n
            anyna[i] |= m[i]
            dec[i] |= !m[i] && (conj ? !v[i] : v[i])
        end
    end
    out = Vector{Union{Missing,Bool}}(undef, n)
    @inbounds for i in 1:n
        out[i] = dec[i] ? !conj : (anyna[i] ? missing : conj)
    end
    return out
end

end # module

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
function _ema(x, n)
    n = _asint(n)
    x = DP._as_numeric(x)
    m = length(x)
    out = fill(NA, m)
    (n < 1 || n > m) && return out
    a = 2 / (n + 1)
    out[n] = SimLev.r_mean(x[1:n])
    if n < m
        f = SimLev.RStats.r_filter(a .* x[n+1:m], 1 - a; method = "recursive", init = out[n])
        out[n+1:m] .= vec(f isa RVector ? f.values : f)
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
    xv = DP._as_numeric(x)
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
    type_ = DP._match_arg(type, ("sma", "ema"))
    fast >= slow && error("fast muss kleiner als slow sein.")
    xv = DP._as_numeric(x)
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
    x = DP._as_numeric(x)
    buy_dd > sell_dd && error("buy_dd darf nicht größer als sell_dd sein.")
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
    x = DP._as_numeric(x)
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
    op = DP._match_arg(op, ("and", "or"))
    s = collect(signals)
    isempty(s) && error("Keine Signale übergeben.")
    len = [(b = _getsig(z, "buy"); b === nothing ? 0 : length(b)) for z in s]
    slen = [(b = _getsig(z, "sell"); b === nothing ? 0 : length(b)) for z in s]
    (any(!=(len[1]), len) || any(slen .!= len)) &&
        error("signal_combine: Signale haben unterschiedliche Längen ($(join(len, ", "))); alle aus derselben Kursreihe erzeugen.")
    n = len[1]
    B = [Bool.(_getsig(z, "buy")) for z in s]; S = [Bool.(_getsig(z, "sell")) for z in s]
    if op == "and"
        return RList("buy" => Bool[all(b[i] for b in B) for i in 1:n], "sell" => Bool[any(c[i] for c in S) for i in 1:n])
    end
    return RList("buy" => Bool[any(b[i] for b in B) for i in 1:n], "sell" => Bool[all(c[i] for c in S) for i in 1:n])
end

end # module

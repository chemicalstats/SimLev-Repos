# Bonds – Gegenstück zu r/R/bonds.R und python/simlev/bonds.py
#
#   index_bond  Total-Return-Index einer Anleihe konstanter Laufzeit
#                           aus einer Renditereihe (Swinkels 2019)
#   index_money_market      Geldmarkt-Index aus einem Tageszins (Act/360)
#   index_currency_hedged   währungsgesicherte Reihe (gedeckte Zinsparität)
#
# Alle Zinsen in Prozent p. a.; Eingaben als Spaltenname, Vektor, Skalar oder
# RFrame(date, value) (Stufenfunktion).
module Bonds

import ..SimLev
using ..SimLev: RList, RFrame, RVector, nrow, attrs, NA
using Dates

export index_bond, index_money_market, index_currency_hedged

const DP = SimLev.DataPrep
const BC = SimLev.Backcast

"Kurs einer Anleihe je 1 Nominal (R: `.bond_price`), elementweise."
function _bond_price(y, coupon, maturity, m)
    n = maturity * m
    out = Vector{Float64}(undef, length(y))
    for k in eachindex(y)
        i = y[k] / m
        dis = SimLev.r_pow(1 + i, -n)
        ann = abs(i) < 1e-10 ? Float64(n) : (1 - SimLev.r_pow(1 + i, -n)) / i
        out[k] = coupon[k] / m * ann + dis
    end
    return out
end

"""
    index_bond(data, yield; maturity = 10, coupon_frequency = 1,
                           method = "exact", start = 100)

Anleihe-Index aus Renditen (konstante Laufzeit).

Bildet einen Total-Return-Index einer Staatsanleihe mit konstanter Restlaufzeit aus einer Renditereihe. An
jedem Tag wird eine neue Par-Anleihe (Kupon = Rendite des Vortags) gekauft und am Folgetag zur neuen Rendite
bewertet: r_t = P(y_t; c = y_t-1, M) - 1 + y_t-1 Δ t mit Δ t = Kalendertage seit der Vorzeile / 365.25. Mit
`method = "duration"` wird die Kursänderung über modifizierte Duration und Konvexität angenähert, -D Δ y +
tfrac12 C Δ y^2 (wie bei Swinkels 2019). Roll-down-Effekte entlang der Zinskurve und Kosten sind nicht
enthalten. Das Ergebnis kann als Kursspalte (Niveau) in `simulation()` oder `bootstrap_config()` verwendet
werden.

# Argumente
- `data`: Tabelle (RFrame) mit Spalte `date` (Date oder umwandelbar, eine Zeile je Tag des gewünschten Index).
- `yield`: Rendite in Prozent p. a. (2.5 = 2,5 Prozent): Spaltenname, Vektor der Länge `nrow(data)`, Skalar,
  `data.frame(date, value)` (z. B. Monatswerte, Stufenfunktion ab Datum) oder benannter Vektor mit
  Datumsnamen.
- `maturity`: Konstante Restlaufzeit in Jahren (Standard 10).
- `coupon_frequency`: Kupons je Jahr (Standard 1 = jährlich wie Bundesanleihen; 2 = halbjährlich wie
  US-Treasuries).
- `method`: `"exact"` (Standard, Neubewertung) oder `"duration"` (Duration-/Konvexitätsnäherung).
- `start`: Startwert des Index in der ersten Zeile (Standard 100).

# Rückgabe
Numerischer Indexvektor (Niveau, Länge `nrow(data)`) mit Attribut `duration` (modifizierte Duration der
Par-Anleihe zur Rendite des jeweiligen Tages, in Jahren).

# Literatur
Swinkels, L. (2019), Treasury Bond Return Data Starting in 1962, Data 4(3), 91.

# Beispiel
```julia
using SimLev, Dates, Random
rng = MersenneTwister(1)
n = 400
d = RFrame("date" => Date(2020, 1, 1) .+ Day.(0:n-1))
d["y10"] = 2 .+ cumsum(0.03 .* randn(rng, n))
b = index_bond(d, "y10"; maturity = 10, coupon_frequency = 1)
println(b[end])
```
"""
function index_bond(data, yield; maturity = 10, coupon_frequency = 1,
                                method = ("exact", "duration"), start = 100)
    data = SimLev.as_rframe(data)
    method = DP._match_arg(method, ("exact", "duration"))
    data = DP._as_frame(data)
    y = BC._resolve_series(yield, data, "yield") ./ 100
    d = DP._days(DP._to_date(DP._col(data, "date"), "data\$date"))
    n = length(y)
    dt = vcat(0.0, Float64[d[i+1] - d[i] for i in 1:n-1]) ./ 365.25
    m = coupon_frequency
    y0 = n == 0 ? Float64[] : vcat(y[1], y[1:n-1])
    c0 = y0
    if method == "exact"
        price = _bond_price(y, c0, maturity, m)
    else
        h = 1e-4
        p0 = _bond_price(y0, c0, maturity, m)
        up = _bond_price(y0 .+ h, c0, maturity, m)
        dn = _bond_price(y0 .- h, c0, maturity, m)
        dur = .-(up .- dn) ./ (2 * h) ./ p0
        up2 = _bond_price(y0 .+ h, c0, maturity, m)
        dn2 = _bond_price(y0 .- h, c0, maturity, m)
        cvx = (up2 .- 2 .* p0 .+ dn2) ./ (h * h) ./ p0
        dy = y .- y0
        price = Float64[1 - dur[i] * dy[i] + 0.5 * cvx[i] * (dy[i] * dy[i]) for i in 1:n]
    end
    r = Float64[price[i] - 1 + c0[i] * dt[i] for i in 1:n]
    n > 0 && (r[1] = 0.0)
    out = start .* SimLev.RBase.r_cumprod(1 .+ r)
    h = 1e-4
    dur = .-(_bond_price(y .+ h, y, maturity, m) .- _bond_price(y .- h, y, maturity, m)) ./ (2 * h)
    return RVector(out; attrs = Dict{String,Any}("duration" => dur))
end

"""
    index_money_market(data, rate; spread = 0, basis = 360, start = 100)

Geldmarkt-Index aus einem Tageszins: `I_t = I_{t-1} (1 + (i_{t-1} - s)/100 Δt/B)`.

Bildet einen Geldmarkt- bzw. Tagesgeld-Index (Niveau) aus einem Zinssatz, z. B. ESTR oder EFFR, als Kursspalte
für `simulation()`: I_t = I_t-1(1 + fraci_t-1 - s100·(Δ t)/(B)) mit Zins i des Vortags, Abschlag s (z. B.
Fondskosten), Kalendertagen Δ t seit der Vorzeile und Tagesbasis B (Act/360).

# Argumente
- `data`: Tabelle (RFrame) mit Spalte `date` (eine Zeile je Indextag).
- `rate`: Zins in Prozent p. a. (3 = 3 Prozent): Spaltenname, Vektor der Länge `nrow(data)`, Skalar,
  `data.frame(date, value)` (Stufenfunktion ab Datum) oder benannter Vektor mit Datumsnamen.
- `spread`: Abschlag in Prozent p. a. (Standard 0), auf derselben Tagesbasis wie der Zins.
- `basis`: Tagesbasis (Standard 360; üblich 360 oder 365).
- `start`: Startwert des Index in der ersten Zeile (Standard 100).

# Rückgabe
Numerischer Indexvektor (Niveau, Länge `nrow(data)`).

# Beispiel
```julia
using SimLev, Dates, Random
rng = MersenneTwister(1)
n = 730
d = RFrame("date" => Date(2020, 1, 1) .+ Day.(0:n-1))
d["estr"] = fill(3.0, n)
mm = index_money_market(d, "estr"; spread = 0.1)
println(mm[end])
```
"""
function index_money_market(data, rate; spread = 0, basis = 360, start = 100)
    data = SimLev.as_rframe(data)
    data = DP._as_frame(data)
    i = BC._resolve_series(rate, data, "rate")
    d = DP._days(DP._to_date(DP._col(data, "date"), "data\$date"))
    n = length(i)
    days = vcat(0.0, Float64[d[k+1] - d[k] for k in 1:length(d)-1])
    r = vcat(0.0, Float64[(i[k] - spread) / 100 * days[k+1] / basis for k in 1:n-1])
    return start .* SimLev.RBase.r_cumprod(1 .+ r)
end

"""
    index_currency_hedged(data, local_, domestic_rate, foreign_rate; cost = 0,
                          basis = 360, start = nothing)

Währungsgesicherte Reihe: lokale Rendite plus Zinsdifferenz, minus Sicherungskosten.

Näherung einer rollierend per Devisentermingeschäft gesicherten Anlage: Die Rendite in Lokalwährung plus die
Zinsdifferenz zwischen Heimat- und Fremdwährung (gedeckte Zinsparität), abzüglich Sicherungskosten: r^h_t =
r^lokal_t + fraci^heim_t-1 - i^fremd_t-1100·(Δ t)/(B) - (k)/(100)·(Δ t)/(365) mit Zinsen des Vortags und
Kalendertagen Δ t seit der Vorzeile. Effekte aus der Absicherung nur des Anfangswerts einer Rollperiode
(Restrisiko auf Kursgewinne) sind nicht enthalten.

# Argumente
- `data`: Tabelle (RFrame) mit Spalte `date`.
- `local_`: Kursreihe in Lokalwährung (Niveau): Spaltenname in `data` oder numerischer Vektor der Länge
  `nrow(data)`; Lücken werden mit dem letzten Wert gefüllt.
- `domestic_rate`, `foreign_rate`: Zinsen der Heimat- bzw. Fremdwährung in Prozent p. a. (Spaltenname, Vektor,
  Skalar, `data.frame(date, value)` oder benannter Vektor mit Datumsnamen).
- `cost`: Sicherungskosten in Prozent p. a. (Standard 0; Tagesbasis 365).
- `basis`: Tagesbasis der Zinsdifferenz (Standard 360).
- `start`: Startwert; `nothing` (Standard) = erster Wert der lokalen Reihe.

# Rückgabe
Numerischer Indexvektor (Niveau, Länge `nrow(data)`).

# Beispiel
```julia
using SimLev, Dates, Random
rng = MersenneTwister(1)
n = 730
d = RFrame("date" => Date(2020, 1, 1) .+ Day.(0:n-1))
d["sp500"] = 100 .* cumprod(1 .+ 3e-4 .+ 0.01 .* randn(rng, n))
h = index_currency_hedged(d, "sp500", 3, 5; cost = 0.1)
println(d["sp500"][end], " ", h[end])
```
"""
function index_currency_hedged(data, local_, domestic_rate, foreign_rate; cost = 0, basis = 360, start = nothing)
    data = SimLev.as_rframe(data)
    data = DP._as_frame(data)
    x = local_ isa AbstractString ? DP._as_numeric(DP._col(data, local_)) : DP._as_numeric(local_)
    x = BC._fill_na(x, "locf")
    id = BC._resolve_series(domestic_rate, data, "domestic_rate")
    ifr = BC._resolve_series(foreign_rate, data, "foreign_rate")
    d = DP._days(DP._to_date(DP._col(data, "date"), "data\$date"))
    n = length(x)
    days = vcat(0.0, Float64[d[k+1] - d[k] for k in 1:length(d)-1])
    r = vcat(0.0, Float64[x[k+1] / x[k] - 1 + (id[k] - ifr[k]) / 100 * days[k+1] / basis - cost / 100 * days[k+1] / 365
                          for k in 1:n-1])
    s = start === nothing ? x[1] : Float64(start)
    return s .* SimLev.RBase.r_cumprod(1 .+ r)
end

end # module

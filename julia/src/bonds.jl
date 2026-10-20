# Bonds – r/R/bonds.R (Vorlage python/simlev/bonds.py)
#
#   bond_index_from_yields  Total-Return-Index einer Anleihe konstanter Laufzeit
#                           aus einer Renditereihe (Swinkels 2019)
#   money_market_index      Geldmarkt-Index aus einem Tageszins (Act/360)
#   currency_hedged_index   währungsgesicherte Reihe (gedeckte Zinsparität)
#
# Alle Zinsen in Prozent p. a.; Eingaben als Spaltenname, Vektor, Skalar oder
# RFrame(date, value) (Stufenfunktion).
module Bonds

import ..SimLev
using ..SimLev: RList, RFrame, RVector, nrow, attrs, NA
using Dates

export bond_index_from_yields, money_market_index, currency_hedged_index

const DP = SimLev.DataPrep
const BC = SimLev.Backcast

"Kurs einer Anleihe je 1 Nominal (Port von `.bond_price`), elementweise."
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
    bond_index_from_yields(data, yield; maturity = 10, coupon_frequency = 1,
                           method = "exact", start = 100)

Anleihe-Index aus Renditen (konstante Laufzeit): an jedem Tag wird eine
Par-Anleihe (Kupon = Rendite des Vortags) gekauft und am Folgetag zur neuen
Rendite bewertet; `method = "duration"` nähert über Duration und Konvexität.
Liefert ein `RVector` (Indexniveau) mit `attrs(x)["duration"]`.
"""
function bond_index_from_yields(data, yield; maturity = 10, coupon_frequency = 1,
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
    money_market_index(data, rate; spread = 0, basis = 360, start = 100)

Geldmarkt-Index aus einem Tageszins: `I_t = I_{t-1} (1 + (i_{t-1} - s)/100 Δt/B)`.
"""
function money_market_index(data, rate; spread = 0, basis = 360, start = 100)
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
    currency_hedged_index(data, local_, domestic_rate, foreign_rate; cost = 0,
                          basis = 360, start = nothing)

Währungsgesicherte Reihe: lokale Rendite plus Zinsdifferenz, minus
Sicherungskosten (Prozent p. a., Basis 365). `local_` als Spaltenname oder
Vektor (Lücken per LOCF).
"""
function currency_hedged_index(data, local_, domestic_rate, foreign_rate; cost = 0, basis = 360, start = nothing)
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

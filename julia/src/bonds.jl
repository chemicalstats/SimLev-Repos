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
using ..SimLev: RFrame, RVector, nrow, attrs
using Dates

export index_bond, index_money_market, index_currency_hedged

const DP = SimLev.DataPrep
const BC = SimLev.Backcast
using ..SimLev: chk_cols, chk_df, chk_len, chk_msg, chk_name1, chk_num1, chk_numvec, chk_scalar, chk_stop

"data nur als RFrame mit Spalte date (seit 1.6.4, Entscheidung 6; R: .idx_data)."
function _idx_data(data, fn)
    @nospecialize
    chk_df(data, fn, "data")
    chk_cols(data, ["date"], fn)
    data["date"] isa SimLev.RFmt.RFactor && chk_stop("spalte_faktor", fn, "date")   # seit 1.6.4 (Entscheidung 15; bis 1.6.3 still in Text umgewandelt)
    nrow(data) == 0 && chk_stop("zeilen_keine", fn, "data")   # seit 1.6.4 Fehler (Entscheidung 25; bis 1.6.3 R 100)
    # seit 1.6.5 (CR2-V1-4, CR2-V3-4): Datum aufsteigend und ohne NA (bis 1.6.4 gingen negative Tageszahlen still ein)
    d = DP._days(DP._to_date(DP._col(DP._as_frame(data), "date"), "data\$date"))
    (any(isnan, d) || any(k -> d[k+1] < d[k], 1:length(d)-1)) && chk_stop("e3.datum", fn)
    return data
end

"""Stufentabelle (RFrame(date, Wert) oder benannter Vektor mit Datumsnamen), die erst nach dem ersten Datentag
beginnt: Warnung (seit 1.6.5, CR2-V3-4 Punkt 4, Entscheidung 189; R `.step_start_warn`); ungültige Tabellen meldet
danach `_resolve_series` wie bisher."""
function _step_start_warn(x, data, fn, arg)
    @nospecialize
    first_ = try
        xf = DP._as_frame(x)
        if xf isa RFrame
            if SimLev.ncol(xf) >= 2
                nm = SimLev.names(xf)
                fd = DP._days(DP._to_date(xf["date" in nm ? "date" : nm[1]], "x"))
                (!isempty(fd) && !any(isnan, fd)) ? minimum(fd) : nothing
            else
                nothing
            end
        elseif DP._is_named_numeric(x)
            nd = Float64.(DP._names_as_dates_optional(DP._named_parts(x)[1]))
            (!isempty(nd) && !any(isnan, nd)) ? minimum(nd) : nothing
        else
            nothing
        end
    catch
        nothing
    end
    first_ === nothing && return nothing
    d = try
        DP._days(DP._to_date(DP._col(DP._as_frame(data), "date"), "x"))
    catch
        return nothing
    end
    (isempty(d) || all(isnan, d)) && return nothing
    d0 = minimum(v for v in d if !isnan(v))
    first_ > d0 && @warn chk_msg("a.stufe_spaet", fn, arg, SimLev.fmt_date(Int(first_)), SimLev.fmt_date(Int(d0)))
    return nothing
end

"Spalte numerisch (eine Spalte nur aus NA zählt als Zahlenspalte, Entscheidung 14)."
function _idx_numcol(data, col, fn)
    data[col] isa SimLev.RFmt.RFactor && chk_stop("spalte_faktor", fn, col)   # Entscheidung 15
    all(ismissing, data[col]) && return nothing   # nur NA: Zahlenspalte (Entscheidung 14)
    kind, arr = SimLev._column(data[col])
    (kind == :numeric || (kind == :logical && all(ismissing, arr))) || chk_stop("spalte_typ", fn, col, chk_msg("typ.numerisch"))
    return nothing
end

"""Zinsangabe (R: .idx_rate): Spaltenname einer numerischen Spalte oder einzelne endliche Zahl; die übrigen Formen
prüft _resolve_series. nothing (R NULL) fehlt; ein Wahrheitswert ist wie in R nicht interpretierbar."""
function _idx_rate(x, data, fn, arg)
    @nospecialize
    x === nothing && chk_stop("fehlt", fn, arg)
    x isa RFrame && for k in SimLev.names(x); SimLev.chk_col_nofactor(x, k, fn); end   # Entscheidung 15 (R .no_factor_df)
    SimLev.chk_nofactor(x, fn, arg)   # Entscheidung 15
    x1 = chk_scalar(x)
    if x1 isa AbstractString
        chk_name1(x1, fn, arg)
        x1 in SimLev.names(data) && _idx_numcol(data, String(x1), fn)
    elseif x1 isa Bool
        chk_stop("a.m_idx_rate", arg, SimLev.nrow(data))
    elseif x1 isa Real || x1 === missing
        chk_num1(x1, fn, arg)
    end
    return nothing
end

const RL = SimLev.RLibm   # libm wie R (glibc), Skalarkerne ohne Warnung

"""Modifizierte Duration der Par-Anleihe geschlossen (seit 1.6.4, K43 T1-R3, Entscheidung 136; R `.bond_dur`):
`-expm1(-n log1p(i)) / (i m)`, bei `i == 0` die Laufzeit, NA und NaN ergeben NA."""
function _bond_dur(i::AbstractVector{Float64}, n, maturity, m)
    out = Vector{Float64}(undef, length(i))
    for k in eachindex(i)
        x = i[k]
        out[k] = isnan(x) ? SimLev.NA : x == 0 ? Float64(maturity) : -RL._expm1(-n * RL._log1p(x)) / (x * m)
    end
    return out
end

"""Konvexität der Par-Anleihe geschlossen bzw. als Reihe für `|i| (n + 1) < 0.05` (seit 1.6.4, K43 T1-R3; R
`.bond_cvx`, gleiche Rechenfolge)."""
function _bond_cvx(i::AbstractVector{Float64}, n, m)
    out = Vector{Float64}(undef, length(i))
    for k in eachindex(i)
        x = i[k]
        if isnan(x)
            out[k] = SimLev.NA
        elseif abs(x) * (n + 1) < 0.05
            t = n * (n + 1) / 2
            s = t
            for j in 1:15
                t = t * (-x) * (n + j + 1) * (j + 1) / (j * (j + 2))
                s = s + t
            end
            out[k] = 2 * s / (m * m)
        else
            lx = RL._log1p(x)
            out[k] = 2 * (-RL._expm1(-n * lx) / x - n * RL._exp(-(n + 1) * lx)) / (x * (m * m))
        end
    end
    return out
end

"""Kurs einer Anleihe je 1 Nominal (R: `.bond_price`), elementweise; seit 1.6.5 (CR2-X44-1) über `L = log1p(i)`:
Abzinsung `exp(-n L)`, Rentenbarwert `-expm1(-n L) / i` (bei `i == 0`: `n`), ohne Auslöschung bei sehr kleinen
Renditen (bis 1.6.4 `(1 + i)^(-n)` und `(1 - dis) / i` mit Schwelle 1e-10)."""
function _bond_price(y::Vector{Float64}, coupon::Vector{Float64}, maturity::Float64, m::Float64)
    n = maturity * m
    out = Vector{Float64}(undef, length(y))
    for k in eachindex(y)
        i = y[k] / m
        L = RL._log1p(i)
        dis = RL._exp(-n * L)
        ann = i == 0 ? n : -RL._expm1(-n * L) / i
        out[k] = coupon[k] / m * ann + dis
    end
    return out
end
_bond_price(y, coupon, maturity, m) = _bond_price(Vector{Float64}(y), Vector{Float64}(coupon), Float64(maturity), Float64(m))

# seit 1.6.5 (CR2-V3-1): Schleifen hinter einer Funktionsgrenze mit festen Typen (bis 1.6.4 über untypisierte Werte
# aus _resolve_series, 9-mal langsamer); gleiche Rechenfolge
function _mm_returns(i::Vector{Float64}, d::Vector{Float64}, spread::Float64, basis::Float64)
    n = length(i)
    days = vcat(0.0, Float64[d[k+1] - d[k] for k in 1:length(d)-1])
    return vcat(0.0, Float64[(i[k] - spread) / 100 * days[k+1] / basis for k in 1:n-1])
end
function _hedged_returns(x::Vector{Float64}, id::Vector{Float64}, ifr::Vector{Float64}, d::Vector{Float64},
                         cost::Float64, basis::Float64)
    n = length(x)
    days = vcat(0.0, Float64[d[k+1] - d[k] for k in 1:length(d)-1])
    return vcat(0.0, Float64[x[k+1] / x[k] - 1 + (id[k] - ifr[k]) / 100 * days[k+1] / basis - cost / 100 * days[k+1] / 365
                             for k in 1:n-1])
end

"""
    index_bond(data, yield; maturity = 10, coupon_frequency = 1,
                           method = "exact", start = 100)

Anleihe-Index aus Renditen (konstante Laufzeit).

Bildet einen Total-Return-Index einer Staatsanleihe mit konstanter Restlaufzeit aus einer Renditereihe. An
jedem Tag wird eine neue Par-Anleihe (Kupon = Rendite des Vortags) gekauft und am Folgetag zur neuen Rendite
bewertet: r_t = P(y_t; c = y_{t-1}, M) - 1 + y_{t-1} Δt mit Δt = Kalendertage seit der Vorzeile / 365.25. Mit
`method = "duration"` wird die Kursänderung über modifizierte Duration und Konvexität angenähert, -D Δy +
(1/2) C Δy^2 (wie bei Swinkels 2019). Roll-down-Effekte entlang der Zinskurve und Kosten sind nicht
enthalten. Das Ergebnis kann als Kursspalte (Niveau) in `simulation()` oder `bootstrap_config()` verwendet
werden.

# Argumente
- `data`: Tabelle (RFrame) mit Spalte `date` (Date oder umwandelbar, eine Zeile je Tag des gewünschten Index).
- `yield`: Rendite in Prozent p. a. (2.5 = 2,5 Prozent): Spaltenname, Vektor der Länge `nrow(data)`, Skalar,
  `data.frame(date, value)` (z. B. Monatswerte, Stufenfunktion ab Datum) oder benannter Vektor mit
  Datumsnamen. Je Kuponperiode muss die Rendite größer als -100 Prozent sein (`yield / coupon_frequency > -100`; seit
  1.6.4 geprüft).
- `maturity`: Konstante Restlaufzeit in Jahren (Standard 10).
- `coupon_frequency`: Kupons je Jahr (Standard 1 = jährlich wie Bundesanleihen; 2 = halbjährlich wie
  US-Treasuries).
- `method`: `"exact"` (Standard, Neubewertung) oder `"duration"` (Duration-/Konvexitätsnäherung).
- `start`: Startwert des Index in der ersten Zeile (Standard 100; > 0). Seit 1.6.4 geprüft: `data` nur als
  `RFrame` mit Spalte `date` (mindestens eine Datenzeile; seit 1.6.4 ist 0 Zeilen ein Fehler), Zahlen endlich (Laufzeit, Kupons, Basis > 0), eine Spalte
  als Zinsangabe numerisch, `nothing` als Zins fehlt.

# Rückgabe
Numerischer Indexvektor (Niveau, Länge `nrow(data)`) mit Attribut `duration` (modifizierte Duration der
Par-Anleihe zur Rendite des jeweiligen Tages, in Jahren) und seit 1.6.5 `convexity` (Konvexität der Par-Anleihe
zur Rendite des jeweiligen Tages, in Jahren², geschlossen wie beim Verfahren `"duration"`; `attrs(b)["convexity"]`).
Duration (und beim Verfahren `"duration"` die Konvexität) seit 1.6.4 geschlossen gerechnet, auf alle Stellen genau;
bis 1.6.3 über zentrale Differenzen (relativer Fehler bis etwa 2e-6 bei 30 Jahren). Seit 1.6.5 muss `date`
aufsteigend und ohne NA sein; der Kurs der Anleihe wird über `log1p` ohne Auslöschung bei sehr kleinen Renditen
gerechnet (Änderung in den letzten Stellen); eine Stufentabelle als `yield`, die erst nach dem ersten Datentag
beginnt, ergibt eine Warnung (davor gilt ihr erster Wert).

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
    fn = "index_bond"
    _idx_data(data, fn)
    _idx_rate(yield, data, fn, "yield")
    maturity = chk_num1(maturity, fn, "maturity"; lo = 0, lo_open = true)
    coupon_frequency = chk_num1(coupon_frequency, fn, "coupon_frequency"; lo = 0, lo_open = true)
    start = chk_num1(start, fn, "start"; lo = 0, lo_open = true)
    method = DP._match_arg(chk_scalar(method), ("exact", "duration"))
    data = DP._as_frame(data)
    _step_start_warn(yield, data, fn, "yield")
    y = Vector{Float64}(BC._resolve_series(yield, data, "yield")) ./ 100
    m = coupon_frequency
    # seit 1.6.4 (K43 T1-R8): Renditen von -100 % je Kuponperiode oder weniger ablehnen (wie R und Python)
    iy = y ./ Float64(m)   # i = y / m je Tag (Float64(m): gleiche Werte, typstabil)
    any(<=(-1), iy) && chk_stop("ut1.rendite", fn)
    d = DP._days(DP._to_date(DP._col(data, "date"), "data\$date"))
    n = length(y)
    dt = vcat(0.0, Float64[d[i+1] - d[i] for i in 1:n-1]) ./ 365.25
    y0 = n == 0 ? Float64[] : vcat(y[1], y[1:n-1])
    c0 = y0
    nm = maturity * m
    if method == "exact"
        price = _bond_price(y, c0, maturity, m)
    else
        # seit 1.6.4 (K43 T1-R3, Entscheidung 136) Duration und Konvexität geschlossen
        i0 = n == 0 ? Float64[] : vcat(iy[1], iy[1:n-1])   # y0 / m
        dur = _bond_dur(i0, nm, maturity, m)
        cvx = _bond_cvx(i0, nm, m)
        dy = y .- y0
        price = Float64[1 - dur[i] * dy[i] + 0.5 * cvx[i] * (dy[i] * dy[i]) for i in 1:n]
    end
    r = Float64[price[i] - 1 + c0[i] * dt[i] for i in 1:n]
    n > 0 && (r[1] = 0.0)
    out = start .* SimLev.RBase.r_cumprod(1 .+ r)
    dur = _bond_dur(iy, nm, maturity, m)   # seit 1.6.4 geschlossen (K43 T1-R3)
    cvx = _bond_cvx(iy, nm, m)             # seit 1.6.5 (Entscheidung 151): Konvexität je Tag
    return RVector(out; attrs = Dict{String,Any}("duration" => dur, "convexity" => cvx))
end

"""
    index_money_market(data, rate; spread = 0, basis = 360, start = 100)

Geldmarkt-Index aus einem Tageszins: `I_t = I_{t-1} (1 + (i_{t-1} - s)/100 Δt/B)`.

Bildet einen Geldmarkt- bzw. Tagesgeld-Index (Niveau) aus einem Zinssatz, z. B. ESTR oder EFFR, als Kursspalte
für `simulation()`: I_t = I_{t-1} · (1 + (i_{t-1} - s)/100 · Δt/B) mit Zins i des Vortags, Abschlag s (z. B.
Fondskosten), Kalendertagen Δt seit der Vorzeile und Tagesbasis B (Act/360).

Seit 1.6.5 muss `date` aufsteigend und ohne NA sein (sonst Fehler); eine Stufentabelle als `rate`, die erst nach
dem ersten Datentag beginnt, ergibt eine Warnung (davor gilt ihr erster Wert).

# Argumente
- `data`: Tabelle (RFrame) mit Spalte `date` (eine Zeile je Indextag).
- `rate`: Zins in Prozent p. a. (3 = 3 Prozent): Spaltenname, Vektor der Länge `nrow(data)`, Skalar,
  `data.frame(date, value)` (Stufenfunktion ab Datum) oder benannter Vektor mit Datumsnamen.
- `spread`: Abschlag in Prozent p. a. (Standard 0), auf derselben Tagesbasis wie der Zins.
- `basis`: Tagesbasis (Standard 360; üblich 360 oder 365).
- `start`: Startwert des Index in der ersten Zeile (Standard 100; > 0). Seit 1.6.4 geprüft: `data` nur als
  `RFrame` mit Spalte `date` (mindestens eine Datenzeile; seit 1.6.4 ist 0 Zeilen ein Fehler), Zahlen endlich (Laufzeit, Kupons, Basis > 0), eine Spalte
  als Zinsangabe numerisch, `nothing` als Zins fehlt.

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
    fn = "index_money_market"
    _idx_data(data, fn)
    _idx_rate(rate, data, fn, "rate")
    spread = chk_num1(spread, fn, "spread")
    basis = chk_num1(basis, fn, "basis"; lo = 0, lo_open = true)
    start = chk_num1(start, fn, "start"; lo = 0, lo_open = true)
    data = DP._as_frame(data)
    _step_start_warn(rate, data, fn, "rate")
    i = Vector{Float64}(BC._resolve_series(rate, data, "rate"))
    d = Vector{Float64}(DP._days(DP._to_date(DP._col(data, "date"), "data\$date")))
    # seit 1.6.5 (CR2-V3-4 Punkt 3, wie Entscheidung 186 M8): Zinsreihe ohne Lücken, Tagesfaktor > 0
    raw = (rate isa AbstractString && rate in SimLev.names(data)) ?
          [SimLev._isna(v) ? NaN : Float64(v) for v in DP._col(data, rate)] : i
    k = findfirst(isnan, raw)
    k === nothing || chk_stop("a.mm_luecke", fn, "rate", SimLev.fmt_date(Int(d[k])))
    r = _mm_returns(i, d, Float64(spread), Float64(basis))
    k = findfirst(x -> !(1 + x > 0), r)
    k === nothing || chk_stop("a.mm_faktor", fn, SimLev.fmt_date(Int(d[k])))
    return start .* SimLev.RBase.r_cumprod(1 .+ r)
end

"""
    index_currency_hedged(data, local_, domestic_rate, foreign_rate; cost = 0,
                          basis = 360, start = nothing)

Währungsgesicherte Reihe: lokale Rendite plus Zinsdifferenz, minus Sicherungskosten.

Näherung einer rollierend per Devisentermingeschäft gesicherten Anlage: Die Rendite in Lokalwährung plus die
Zinsdifferenz zwischen Heimat- und Fremdwährung (gedeckte Zinsparität), abzüglich Sicherungskosten: r^h_t =
r^lokal_t + (i^heim_{t-1} - i^fremd_{t-1})/100 · Δt/B - k/100 · Δt/365 mit Zinsen des Vortags und
Kalendertagen Δt seit der Vorzeile. Effekte aus der Absicherung nur des Anfangswerts einer Rollperiode
(Restrisiko auf Kursgewinne) sind nicht enthalten.

Seit 1.6.5 muss `date` aufsteigend und ohne NA sein und `local` (nach dem Füllen) endliche Werte > 0 haben
(sonst Fehler); eine Stufentabelle als Zins, die erst nach dem ersten Datentag beginnt, ergibt eine Warnung
(davor gilt ihr erster Wert).

# Argumente
- `data`: Tabelle (RFrame) mit Spalte `date`.
- `local_`: Kursreihe in Lokalwährung (Niveau): Spaltenname in `data` oder numerischer Vektor der Länge
  `nrow(data)`; Lücken werden mit dem letzten Wert gefüllt.
- `domestic_rate`, `foreign_rate`: Zinsen der Heimat- bzw. Fremdwährung in Prozent p. a. (Spaltenname, Vektor,
  Skalar, `data.frame(date, value)` oder benannter Vektor mit Datumsnamen).
- `cost`: Sicherungskosten in Prozent p. a. (Standard 0; Tagesbasis 365).
- `basis`: Tagesbasis der Zinsdifferenz (Standard 360).
- `start`: Startwert; `nothing` (Standard) = erster Wert der lokalen Reihe; sonst > 0. Seit 1.6.4 geprüft:
  `local_` als Vektor mit der Länge `nrow(data)`, `cost` endlich, `basis` > 0.

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
    fn = "index_currency_hedged"
    _idx_data(data, fn)
    local_ === nothing && chk_stop("fehlt", fn, "local")
    # local: Spaltenname einer numerischen Spalte oder numerischer Vektor der Länge nrow(data)
    if chk_scalar(local_) isa AbstractString
        local_ = chk_name1(local_, fn, "local")
        chk_cols(data, [local_], fn)
        _idx_numcol(data, String(local_), fn)
    else
        SimLev.chk_nofactor(local_, fn, "local")   # Entscheidung 15
        local_ isa AbstractMatrix && chk_stop("zahlen", fn, "local")
        chk_numvec(local_, fn, "local")
        chk_len(local_ isa Union{AbstractVector,Tuple} ? local_ : [local_], nrow(data), fn, "local")
    end
    _idx_rate(domestic_rate, data, fn, "domestic_rate")
    _idx_rate(foreign_rate, data, fn, "foreign_rate")
    cost = chk_num1(cost, fn, "cost")
    basis = chk_num1(basis, fn, "basis"; lo = 0, lo_open = true)
    start = chk_num1(start, fn, "start"; lo = 0, lo_open = true, null_ok = true)
    data = DP._as_frame(data)
    x = local_ isa AbstractString ? DP._as_numeric(DP._col(data, local_)) : DP._as_numeric(local_)
    x = Vector{Float64}(BC._fill_na(x, "locf"))
    # seit 1.6.5 (CR2-V1-4): Kurse endlich und > 0 (bis 1.6.4 still -Inf bzw. sinnlose Werte)
    ib = findfirst(v -> !isnan(v) && (isinf(v) || v <= 0), x)
    ib === nothing || chk_stop("a.werte_positiv", fn, "local", ib)
    _step_start_warn(domestic_rate, data, fn, "domestic_rate")
    _step_start_warn(foreign_rate, data, fn, "foreign_rate")
    id = Vector{Float64}(BC._resolve_series(domestic_rate, data, "domestic_rate"))
    ifr = Vector{Float64}(BC._resolve_series(foreign_rate, data, "foreign_rate"))
    d = Vector{Float64}(DP._days(DP._to_date(DP._col(data, "date"), "data\$date")))
    r = _hedged_returns(x, id, ifr, d, Float64(cost), Float64(basis))
    s = start === nothing ? x[1] : Float64(start)
    return s .* SimLev.RBase.r_cumprod(1 .+ r)
end

end # module

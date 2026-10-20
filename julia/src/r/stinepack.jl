"""
Nachbildung des R-Pakets stinepack 1.5 (Stineman-Interpolation).

Nachgebildet sind `stinterp(x, y, xout; yp, method)` mit allen
Eingabeprüfungen und Meldungen sowie die Steigungen `stinemanSlopes` (mit
und ohne Skalierung) und `parabolaSlopes`. Die Rechenreihenfolge folgt dem
R-Code Zeile für Zeile, auch in den Eigenheiten von stinepack: `NA` in `y`
wird nicht geprüft (die Prüfung fragt zweimal `x`); `missing(yp)` ist in R
nach der Zuweisung der Steigungen `FALSE`, der rationale Zweig läuft darum
auch für zwei Stützstellen; `yo[id] <- …` mit `NA` im logischen Index bricht
mit "NAs are not allowed in subscripted assignments" ab, sobald mehr als ein
Element ausgewählt ist, `if` mit `NA` mit "missing value where TRUE/FALSE
needed".

imputeTS nutzt `stinterp` in `na_interpolation(option = "stine")` (siehe
`src/r/imputets.jl`). Vorlage: `python/simlev/_r/stinepack.py`.
"""
module RStinepack

import ..SimLev
import ..SimLev: RList, RVector, NA

export stinterp, stinemanSlopes, parabolaSlopes

const _DBL_EPS = 2.220446049250313e-16

"Kennzeichen für ein nicht angegebenes Argument (R `missing()`)."
struct Missing_ end
const MISSING = Missing_()

# ── R-Logik (dreiwertig: true, false, nothing = NA) ──────────────────────────
_cmp(a::Float64, b::Float64, op) = (isnan(a) || isnan(b)) ? nothing : op(a, b)
_and(a, b) = a === false ? false : a === true ? b : (b === false ? false : nothing)
_or(a, b) = a === true ? true : a === false ? b : (b === true ? true : nothing)
_if(v) = v === nothing ? error("missing value where TRUE/FALSE needed") : v
function _any3(flags)
    na = false
    for f in flags
        f === true && return true
        f === nothing && (na = true)
    end
    return na ? nothing : false
end

_isna_el(v) = v === missing || v === nothing || (v isa AbstractFloat && isnan(v))
_isnum_el(v) = v isa Real && !(v isa Bool)

"""
    classify(x) -> (typ, werte, ist_vektor)

Atomaren R-Vektor erkennen: `typ` ist `"num"`, `"lgl"`, `"chr"` oder
`"null"`; `werte` bei `"num"` ein `Vector{Float64}` (NA bzw. `missing` als
R-NA), sonst ein `Vector{Any}`; `ist_vektor` entspricht `is.vector(x)`
(Matrizen: `false`).
"""
function classify(x)
    x === nothing && return ("null", Float64[], false)
    isvec = true
    if x isa RVector
        a = x.values
    elseif x isa AbstractMatrix
        a = vec(x); isvec = false
    elseif x isa AbstractArray
        a = vec(x)
    elseif x isa Tuple
        a = collect(x)
    else
        a = [x]
    end
    if isempty(a)
        S = Base.nonmissingtype(eltype(a))
        S <: Real && !(S <: Bool) && return ("num", Float64[], isvec)
        S <: Bool && return ("lgl", Any[], isvec)
        return ("chr", Any[], isvec)
    end
    vals = [v for v in a if !_isna_el(v)]
    S = Base.nonmissingtype(eltype(a))
    isnum = isempty(vals) ? ((S <: Real && !(S <: Bool)) || any(v -> v isa AbstractFloat, a)) : all(_isnum_el, vals)
    isnum && return ("num", Float64[(v === missing || v === nothing) ? NA : Float64(v) for v in a], isvec)
    (isempty(vals) || all(v -> v isa Bool, vals)) && return ("lgl", Any[_isna_el(v) ? missing : v for v in a], isvec)
    return ("chr", Any[_isna_el(v) ? missing : string(v) for v in a], isvec)
end

isna_vals(kind, v) = kind == "num" ? Bool[isnan(e) for e in v] : Bool[_isna_el(e) for e in v]

"`match.arg(method)` mit den Wahlen von stinterp."
function _match_method(method)
    choices = ("scaledstineman", "stineman", "parabola")
    method === nothing && return choices[1]
    if method isa Union{AbstractVector,Tuple}
        a = collect(method)
        (length(a) == 3 && all(i -> a[i] == choices[i], 1:3)) && return choices[1]
        length(a) == 1 || error("'arg' must be of length 1")
        method = a[1]
    end
    method isa Symbol && (method = String(method))
    method isa AbstractString || error("'arg' must be NULL or a character vector")
    method in choices && return String(method)
    hits = isempty(method) ? String[] : [c for c in choices if startswith(c, method)]
    length(hits) == 1 && return hits[1]
    error("'arg' should be one of " * join(("“$(c)”" for c in choices), ", "))
end

_diff(v::Vector{Float64}) = Float64[v[i+1] - v[i] for i in 1:length(v)-1]
_range_diff(v::Vector{Float64}) = any(isnan, v) ? NaN : maximum(v) - minimum(v)

"""
    stinemanSlopes(x, y; scale = false)

Steigungen nach Stineman (stinepack `stinemanSlopes`) an den Stützstellen
`x` (streng steigend) mit Werten `y`; `scale = true` skaliert x und y vorher
auf ihre Spannweite (Methode "scaledstineman", Voreinstellung von `stinterp`).
"""
function stinemanSlopes(x, y; scale::Bool = false)
    x = copy(classify(x)[2]); y = copy(classify(y)[2])
    m = length(x); m1 = m - 1
    if m == 2
        d = (y[2] - y[1]) / (x[2] - x[1])
        return [d, d]
    end
    sx = sy = 1.0
    if scale
        sx = _range_diff(x)
        sy = _range_diff(y)
        _if(_cmp(sy, 0.0, <=)) && (sy = 1.0)
        x = x ./ sx
        y = y ./ sy
    end
    dx = _diff(x); dy = _diff(y)
    yp = fill(NA, m)
    for i in 1:m1-1
        # dx[-1] = dx[i+1], dx[-m1] = dx[i]
        p = dx[i+1] * dx[i+1] + dy[i+1] * dy[i+1]
        q = dx[i] * dx[i] + dy[i] * dy[i]
        yp[i+1] = (dy[i] * p + dy[i+1] * q) / (dx[i] * p + dx[i+1] * q)
    end
    for (k, j, i) in ((1, 2, 1), (m, m1, m1))
        s = dy[i] / dx[i]
        q = yp[j]
        c = _or(_and(_cmp(s, 0.0, >=), _cmp(s, q, >=)), _and(_cmp(s, 0.0, <=), _cmp(s, q, <=)))
        if _if(c)
            yp[k] = 2 * s - q
        else
            yp[k] = s + abs(s) * (s - q) / (abs(s) + abs(s - q))
        end
    end
    if scale
        yp = (yp .* sy) ./ sx
    end
    return yp
end

"""
    parabolaSlopes(x, y)

Steigungen der Parabel durch je drei Punkte (stinepack `parabolaSlopes`).
"""
function parabolaSlopes(x, y)
    x = classify(x)[2]; y = classify(y)[2]
    m = length(x); m1 = m - 1
    dx = _diff(x); dy = _diff(y)
    dydx = dy ./ dx
    m == 2 && return [dydx[1], dydx[1]]
    yp = Vector{Float64}(undef, m)
    yp[1] = (dydx[1] * (2 * dx[1] + dx[2]) - dydx[2] * dx[1]) / (dx[1] + dx[2])
    for i in 1:m1-1
        yp[i+1] = (dydx[i] * dx[i+1] + dydx[i+1] * dx[i]) / (dx[i+1] + dx[i])
    end
    yp[m] = (dydx[m1] * (2 * dx[m1] + dx[m1-1]) - dydx[m1-1] * dx[m1]) / (dx[m1] + dx[m1-1])
    return yp
end

_lgl_cmp(v::Vector{Float64}, op) = Any[isnan(e) ? nothing : op(e, 0.0) for e in v]

"`yo[id] <- wert` mit logischem Index `id` (true/false/nothing)."
function _sub_assign!(yo::Vector{Float64}, flags, value_fn)
    sel = [i for i in eachindex(flags) if flags[i] !== false]
    isempty(sel) && return yo
    if any(i -> flags[i] === nothing, sel)
        length(sel) > 1 && error("NAs are not allowed in subscripted assignments")
        return yo                                  # Länge 1: NA-Index wird übergangen
    end
    for j in sel
        yo[j] = value_fn(j)
    end
    return yo
end

"`findInterval(xout, x, rightmost.closed = TRUE)` (Vergleiche mit `<=` wie R, ±0 gleich)."
function _find_interval(xout::Vector{Float64}, x::Vector{Float64})
    m = length(x)
    r = Int[searchsortedlast(x, v; lt = <) for v in xout]
    for i in eachindex(xout)
        xout[i] == x[m] && (r[i] = m - 1)
    end
    return r
end

"""
    stinterp(x, y, xout; yp = MISSING, method = MISSING)

Stineman-Interpolation (stinepack `stinterp`): Stützstellen `x` (streng
steigend, ohne NA), Werte `y`, Auswertungsstellen `xout` (ohne NA).
`yp`: optionale Steigungen an den Stützstellen; sonst nach `method`
(`"scaledstineman"` Standard, `"stineman"`, `"parabola"`, Teilwörter wie
`match.arg`; nicht zusammen mit `yp`).

Ergebnis: `RList` mit `x` (= `xout`) und `y` (`NA` außerhalb von `range(x)`).
"""
function stinterp(x = MISSING, y = MISSING, xout = MISSING; yp = MISSING, method = MISSING)
    (x === MISSING || y === MISSING || xout === MISSING) &&
        error("Wrong number of input arguments, x, y and xout must be specified")
    kx, xv, vx = classify(x)
    ky, yv, vy = classify(y)
    ko, ov, vo = classify(xout)
    (vx && vy && vo && kx == "num" && ky == "num" && ko == "num") || error("x, y and xout must be numeric vectors")
    length(xv) < 2 && error("x must have 2 or more elements")
    length(xv) != length(yv) && error("x must have the same number of elements as y")
    (any(isnan, xv) || any(isnan, ov)) && error("NAs in x, y or xout are not allowed")
    pv = Float64[]
    if yp !== MISSING
        kp, pv, vp = classify(yp)
        (vp && kp == "num") || error("yp must be a numeric vector")
        length(yv) != length(pv) && error("When specified, yp must have the same number of elements as y")
        any(isnan, pv) && error("NAs in yp are not allowed")
        method !== MISSING && error("Method should not be specified if yp is given")
    end
    dx = _diff(xv); dy = _diff(yv)
    _if(_any3(_lgl_cmp(dx, <=))) && error("The values of x must strictly increasing")
    if yp === MISSING
        meth = _match_method(method === MISSING ? nothing : method)
        pv = meth == "scaledstineman" ? stinemanSlopes(xv, yv; scale = true) :
             meth == "stineman" ? stinemanSlopes(xv, yv; scale = false) : parabolaSlopes(xv, yv)
    end
    m = length(xv); m1 = m - 1
    s = dy ./ dx
    k = length(ov)
    ix = _find_interval(ov, xv)
    xmin = minimum(xv); xmax = maximum(xv)
    epx = 5 * _DBL_EPS * (xmax - xmin)
    for i in 1:k
        (xmin - epx <= ov[i] && ov[i] <= xmin) && (ix[i] = 1)
    end
    for i in 1:k
        (xmax <= ov[i] && ov[i] <= xmax + epx) && (ix[i] = m1)
    end
    idx = [1 <= ix[i] <= m1 for i in 1:k]
    i1 = ix[idx]; i2 = i1 .+ 1
    xo = ov[idx]
    n = length(i1)
    dxo1 = Float64[xo[j] - xv[i1[j]] for j in 1:n]
    dxo2 = Float64[xo[j] - xv[i2[j]] for j in 1:n]
    y0o = Float64[yv[i1[j]] + s[i1[j]] * dxo1[j] for j in 1:n]
    dyo1 = Float64[(pv[i1[j]] - s[i1[j]]) * dxo1[j] for j in 1:n]
    dyo2 = Float64[(pv[i2[j]] - s[i1[j]]) * dxo2[j] for j in 1:n]
    dyo1dyo2 = Float64[dyo1[j] * dyo2[j] for j in 1:n]
    yo = copy(y0o)
    # R: `if (m > 2 || !missing(yp))` ist immer wahr, weil yp vorher zugewiesen wurde
    _sub_assign!(yo, _lgl_cmp(dyo1dyo2, >), j -> y0o[j] + dyo1dyo2[j] / (dyo1[j] + dyo2[j]))
    _sub_assign!(yo, _lgl_cmp(dyo1dyo2, <),
                 j -> y0o[j] + dyo1dyo2[j] * (dxo1[j] + dxo2[j]) / (dyo1[j] - dyo2[j]) / dx[i1[j]])
    yout = fill(NA, k)
    yout[idx] = yo
    return RList("x" => (xout isa AbstractVector ? xout : ov), "y" => yout)
end

end # module

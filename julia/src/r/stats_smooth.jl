# Herkunft:           übersetzt aus R 4.3.3, src/library/stats/src/approx.c, filter.c; nachgebildet
#                     nach R 4.3.3, src/library/stats/R/approx.R, filter.R
# Rechte:             The R Core Team, teils Robert Gentleman und Ross Ihaka, The R Foundation (laut
#                     Kopf der jeweiligen R-Quelle)
# Lizenz der Vorlage: GPL (>= 2) laut Kopf der R-Quellen; in SimLev unter GPL-3
# Änderungen:         Übertragung nach Python bzw. Julia (Julia nach der Python-Fassung) im von
#                     SimLev genutzten Umfang; seit 1.6.0 rechnen regularize.values und filter im C-Kern
#                     core/slc_rbase_smooth.cpp (sl_r_regularize, sl_r_filter_conv, sl_r_filter_rec).
# Interpolation und Filter (approx, approxfun, r_filter) aus R 4.3.3 stats/R/approx.R, filter.R und
# stats/src/approx.c, filter.c; Python: _r/stats_smooth.py. Die Interpolation je Punkt (approx.c) rechnet seit
# 1.5.0 der C-Kern sl_r_approx (core/slc_rbase.cpp).
# Teil des Untermoduls RStats (eingebunden in stats.jl).
#
# Seit 1.0.0 entfallen fft, bw_nrd0, density, smooth_spline und predict_smooth_spline: SimLev
# nutzt die eigene Gauß-Kerndichte und den eigenen Glättungsspline der C-Bibliothek slc (SimLev.SLib).

# ── approx / approxfun / filter ──────────────────────────────────────────

"regularize.values (C-Kern sl_r_regularize, seit 1.6.0: NA-Paare, Sortierung, Gruppen gleicher x, mean je Gruppe)."
function _regularize(x, y, ties, warn_collapsing::Bool, na_rm::Bool)
    xv = _v(x)
    if y === nothing
        yv = xv
        xv = Float64.(1:length(yv))
    else
        yv = _v(y)
    end
    length(xv) != length(yv) && error("'x' and 'y' lengths differ")
    if ties isa AbstractString && ties == "ordered"
        mode = 2; fun = nothing
    elseif ties isa Tuple && length(ties) == 2 && ties[2] isa Function
        mode = ties[1] == "ordered" ? 1 : 0; fun = ties[2]
    else
        mode = 0; fun = ties
    end
    mean = fun === nothing || fun === _rmean || fun == "mean"
    xo, yo, grp, m, nout, collapsed, kept_na = SimLev._rb_regularize(Vector{Float64}(xv), Vector{Float64}(yv), na_rm,
                                                                    mode, mean)
    if collapsed
        warn_collapsing && @warn "collapsing to unique 'x' values"
        if !mean
            ys = yo[1:m]; g = grp[1:m]
            yo = Float64[Float64(first(_v(fun(ys[g .== k])))) for k in 0:nout-1]
        end
    end
    # notNA wie R: ohne Zusammenfassen die Maske der Eingabe (vor dem Sortieren), sonst !is.na(x)
    ok = !kept_na ? nothing : collapsed ? .!isnan.(xo[1:nout]) : .!(isnan.(xv) .| isnan.(yv))
    return xo[1:nout], yo[1:nout], kept_na, ok
end

"""`seq.int(from, to, length.out = n)` in `approx`: Grenzen endlich (sonst Fehler wie R); sind from, to und Schritt
ganzzahlig, liefert R ganze Zahlen (aus -0 wird 0)."""
function _seq_int(frm, to, n)
    frm = Float64(frm); to = Float64(to)
    isfinite(frm) || error("'from' must be a finite number")
    isfinite(to) || error("'to' must be a finite number")
    out = seq_len_out(frm, to, n)
    n = ceil(Int, Float64(n))   # seit 1.6.4 wie R aufgerundet (C-061)
    rby = 0.0
    if n > 2
        nint = Float64(n - 1)
        rby = to - frm
        rby = isfinite(rby) ? rby / nint : to / nint - frm / nint
    end
    lim = 2147483647.0
    if -lim - 1 <= frm <= lim && -lim - 1 <= to <= lim && frm == trunc(frm) && (n <= 1 || to == trunc(to)) &&
       (n <= 2 || rby == trunc(rby))
        out = out .+ 0.0
    end
    out
end

"R_approxfun: Interpolation je Punkt im C-Kern `sl_r_approx` (core/slc_rbase.cpp, seit 1.5.0)."
_approx_core(x::Vector{Float64}, y::Vector{Float64}, v::Vector{Float64}, method::Int, yleft::Float64, yright::Float64,
             f::Float64) = SimLev._rb_approx(x, y, v, method, yleft, yright, f)

function _approx_setup(x, y, method, yleft, yright, rule, f, ties, na_rm::Bool, ties_missing::Bool)
    meths = [("linear", 1), ("constant", 2)]
    m = isempty(method) ? Int[] : [v for (k, v) in meths if startswith(k, method)]
    length(m) != 1 && error("invalid interpolation method")
    method = m[1]
    # seit 1.6.4 wie R stopifnot(is.numeric(rule), (lenR <- length(rule)) >= 1L, lenR <= 2L) (C-061)
    rv = rule isa Union{AbstractVector,Tuple} ? collect(rule) : [rule]
    (all(v -> v isa Real && !(v isa Bool), rv) && !(!isempty(rv) && all(ismissing, rv))) ||
        error("is.numeric(rule) is not TRUE")
    isempty(rv) && error("(lenR <- length(rule)) >= 1L is not TRUE")
    length(rv) > 2 && error("lenR <= 2L is not TRUE")
    rule = Float64.(rv)
    length(rule) == 1 && (rule = [rule[1], rule[1]])
    xv, yv, kept_na, notna = _regularize(x, y, ties, ties_missing, na_rm)
    nona = na_rm || !kept_na
    nx = nona ? length(xv) : count(notna)
    if nx <= 1
        method == 1 && error("need at least two non-NA values to interpolate")
        nx == 0 && error("zero non-NA points")
    end
    yleft === nothing && isnan(rule[1]) && error("missing value where TRUE/FALSE needed")
    yleft === nothing && (yleft = rule[1] == 1 ? NA : yv[1])
    yright === nothing && isnan(rule[2]) && error("missing value where TRUE/FALSE needed")
    yright === nothing && (yright = rule[2] == 1 ? NA : yv[end])
    # seit 1.6.4 wie R stopifnot(length(yleft) == 1L, length(yright) == 1L, length(f) == 1L) (T4-R3; bis dahin
    # MethodError/TypeError); die f- und NA-Prüfung (C_ApproxTest) folgt in approx erst nach n und xout
    _ax_len(yleft) == 1 || error("length(yleft) == 1L is not TRUE")
    _ax_len(yright) == 1 || error("length(yright) == 1L is not TRUE")
    _ax_len(f) == 1 || error("length(f) == 1L is not TRUE")
    return xv, yv, method, _ax_one(yleft), _ax_one(yright), nona, notna, nx, _ax_one(f)
end

"`length(v)` für ein Argument (nothing = NULL, Einzelwert 1, sonst Zahl der Elemente)."
_ax_len(v) = v === nothing ? 0 : v isa Union{AbstractArray,Tuple} ? length(v) : 1
"Wert eines Arguments der Länge 1 als Float64."
_ax_one(v) = v isa Union{AbstractArray,Tuple} ? Float64(first(v)) : Float64(v)

"R's C_ApproxTest: f bei method \"constant\", dann NA in x (und y bei na.rm)."
function _approx_test(xv, yv, method::Int, f::Float64, na_rm::Bool)
    if method == 2
        (!isfinite(f) || f < 0 || f > 1) && error("approx(): invalid f value")
    end
    if na_rm
        (any(isnan, xv) || any(isnan, yv)) && error("approx(): attempted to interpolate NA values")
    else
        any(isnan, xv) && error("approx(x,y, .., na.rm=FALSE): NA values in x are not allowed")
    end
    return nothing
end

"""
    approx(x, y = nothing; xout = nothing, method = "linear", n = 50, yleft, yright, rule = 1, f = 0, ties = nothing, na_rm = true)

`approx(...)`; `ties = nothing` entspricht R's Voreinstellung `mean` (mit
Warnung beim Zusammenfassen); auch "ordered", eine Funktion oder
`("ordered", fun)`. Ergebnis: RList mit `x` und `y`.
"""
function approx(x, y = nothing; xout = nothing, method::AbstractString = "linear", n = 50, yleft = nothing,
                yright = nothing, rule = 1, f = 0, ties = nothing, na_rm::Bool = true)
    ties_missing = ties === nothing
    # Reihenfolge der Prüfungen seit 1.6.4 wie stats::approx 4.3.3 (T4-R3): method, rule, Werte, yleft/yright/f-Längen,
    # n und xout, dann f und NA (C_ApproxTest)
    xv, yv, meth, yl, yr, nona, notna, nx, fv = _approx_setup(x, y, method, yleft, yright, rule, f,
                                                             ties === nothing ? _rmean : ties, na_rm, ties_missing)
    if xout === nothing
        n === nothing && error("argument is of length zero")
        (n isa Real && isnan(n)) && error("missing value where TRUE/FALSE needed")
        n <= 0 && error("'approx' requires n >= 1")
        if nona
            xo = _seq_int(xv[1], xv[nx], n)
        else
            xs = xv[notna]
            xo = _seq_int(xs[1], xs[end], n)
        end
    end
    _approx_test(xv, yv, meth, fv, na_rm)
    xout === nothing || (xo = _v(xout))
    yo = _approx_core(xv, yv, xo, meth, yl, yr, fv)
    xres = xout === nothing ? _vec_out(xo) : (xout isa Real ? Float64(xout) : xout)
    return RList("x" => xres, "y" => (xout isa Real ? yo[1] : _vec_out(yo)))
end

"Interpolationsfunktion aus `approxfun()`/`ecdf()`; aufrufbar `f(v)`."
struct ApproxFun <: Function
    x::Vector{Float64}
    y::Vector{Float64}
    method::Int
    yleft::Float64
    yright::Float64
    f::Float64
    attrs::Dict{String,Any}
end
function (F::ApproxFun)(v)
    out = _approx_core(F.x, F.y, _v(v), F.method, F.yleft, F.yright, F.f)
    v isa Real && return out[1]
    return _vec_out(out)
end
SimLev.attrs(F::ApproxFun) = F.attrs

"`approxfun(...)`: liefert eine aufrufbare Funktion `v -> y` (ApproxFun mit x, y)."
function approxfun(x, y = nothing; method::AbstractString = "linear", yleft = nothing, yright = nothing, rule = 1,
                   f = 0, ties = nothing, na_rm::Bool = true)
    ties_missing = ties === nothing
    xv, yv, meth, yl, yr, nona, notna, nx, fv = _approx_setup(x, y, method, yleft, yright, rule, f,
                                                             ties === nothing ? _rmean : ties, na_rm, ties_missing)
    _approx_test(xv, yv, meth, fv, na_rm)
    return ApproxFun(xv, yv, meth, yl, yr, fv, Dict{String,Any}())
end

"`as.integer(v)[1]` für einen Wert (abgeschnitten; NA, Text ohne Zahl, ±Inf → `nothing`)."
function _as_int1(v)
    v isa Union{AbstractVector,Tuple} && (v = isempty(v) ? nothing : first(v))
    (v === nothing || v === missing) && return nothing
    if v isa AbstractString
        f = tryparse(Float64, strip(v))
        f === nothing && return nothing
        v = f
    end
    v isa Real || return nothing
    f = Float64(v)
    (isnan(f) || !(-2147483648.0 < f < 2147483648.0)) && return nothing
    return trunc(Int, f)
end

"`as.logical(v)[1]` für einen Wert (Text \"TRUE\"/\"true\"/\"T\"/\"True\" bzw. \"FALSE\"/…; Zahl != 0; sonst `nothing`)."
function _as_lgl1(v)
    v isa Union{AbstractVector,Tuple} && (v = isempty(v) ? nothing : first(v))
    (v === nothing || v === missing) && return nothing
    v isa Bool && return v
    v isa AbstractString && return v in ("TRUE", "true", "T", "True") ? true :
                                  v in ("FALSE", "false", "F", "False") ? false : nothing
    v isa Real || return nothing
    return isnan(Float64(v)) ? nothing : v != 0
end

"`filter(x, filter, method, sides, circular, init)` (ohne ts-Attribute)."
function r_filter(x, filter; method::AbstractString = "convolution", sides = 2, circular = false,
                  init = nothing)
    meth = [m for m in ("convolution", "recursive") if startswith(m, method)]
    length(meth) != 1 && error("'arg' should be one of “convolution”, “recursive”")
    method = meth[1]
    is_mat = x isa AbstractMatrix || x isa RFrame
    X = is_mat ? _as_cov_input(x)[1] : reshape(_v(x), :, 1)
    n, nser = size(X)
    n == 0 && error("'ts' object must have one or more observations")   # seit 1.6.4 wie R as.ts(x) (C-052)
    fv = _v(filter)
    nf = length(fv)
    any(isnan, fv) && error("missing values in 'filter'")
    Y = Matrix{Float64}(undef, n, nser)
    if method == "convolution"
        nf > n && error("'filter' is longer than time series")
        sv = _as_int1(sides)   # seit 1.6.4 wie R as.integer(sides), NA mit Meldung (C-052)
        (sv === nothing || !(sv in (1, 2))) && error("argument 'sides' must be 1 or 2")
        sides = sv
        cv = _as_lgl1(circular)
        cv === nothing && error("'circular' must be logical and not NA")
        circular = cv
        ini = zeros(0, nser)
    elseif init === nothing
        ini = zeros(nf, nser)
    else
        ia = init isa AbstractMatrix ? _fmat(init isa NamedMat ? init.data : init) : reshape(_v(init), :, 1)
        size(ia, 1) != nf && error("length of 'init' must equal length of 'filter'")
        ncol = size(ia, 2)
        if ncol != 1 && ncol != nser
            nser == 1 && error("'init' must have $nser column")
            error("'init' must have 1 or $nser columns")
        end
        if ncol == 1 && nser > 1   # wie R (seit 1.6.0): dim(init) <- c(nf, nser) bzw. init[, 2]
            init isa AbstractMatrix && error("subscript out of bounds")
            error("dims [product $(nf * nser)] do not match the length of object [$nf]")
        end
        ini = ia
    end
    for s in 1:nser   # C-Kerne sl_r_filter_conv, sl_r_filter_rec (seit 1.6.0)
        Y[:, s] = SimLev._rb_filter(Vector{Float64}(X[:, s]), Vector{Float64}(fv), method == "recursive",
                                    method == "recursive" ? 2 : Int(sides), circular === true,
                                    Vector{Float64}(ini[:, s]))
    end
    is_mat && return Y
    return _vec_out(Y[:, 1])
end



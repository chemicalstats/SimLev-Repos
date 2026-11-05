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
    n = trunc(Int, n)
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

function _approx_setup(x, y, method, yleft, yright, rule, f::Float64, ties, na_rm::Bool, ties_missing::Bool)
    meths = [("linear", 1), ("constant", 2)]
    m = isempty(method) ? Int[] : [v for (k, v) in meths if startswith(k, method)]
    length(m) != 1 && error("invalid interpolation method")
    method = m[1]
    rule = collect(_v(rule))
    length(rule) == 1 && (rule = [rule[1], rule[1]])
    xv, yv, kept_na, notna = _regularize(x, y, ties, ties_missing, na_rm)
    nona = na_rm || !kept_na
    nx = nona ? length(xv) : count(notna)
    if nx <= 1
        method == 1 && error("need at least two non-NA values to interpolate")
        nx == 0 && error("zero non-NA points")
    end
    yleft === nothing && (yleft = rule[1] == 1 ? NA : yv[1])
    yright === nothing && (yright = rule[2] == 1 ? NA : yv[end])
    if method == 2
        (!isfinite(f) || f < 0 || f > 1) && error("approx(): invalid f value")
    end
    if na_rm
        (any(isnan, xv) || any(isnan, yv)) && error("approx(): attempted to interpolate NA values")
    else
        any(isnan, xv) && error("approx(x,y, .., na.rm=FALSE): NA values in x are not allowed")
    end
    return xv, yv, method, Float64(yleft), Float64(yright), nona, notna, nx
end

"""
    approx(x, y = nothing; xout = nothing, method = "linear", n = 50, yleft, yright, rule = 1, f = 0, ties = nothing, na_rm = true)

`approx(...)`; `ties = nothing` entspricht R's Voreinstellung `mean` (mit
Warnung beim Zusammenfassen); auch "ordered", eine Funktion oder
`("ordered", fun)`. Ergebnis: RList mit `x` und `y`.
"""
function approx(x, y = nothing; xout = nothing, method::AbstractString = "linear", n::Integer = 50, yleft = nothing,
                yright = nothing, rule = 1, f::Real = 0, ties = nothing, na_rm::Bool = true)
    ties_missing = ties === nothing
    xv, yv, meth, yl, yr, nona, notna, nx = _approx_setup(x, y, method, yleft, yright, rule, Float64(f),
                                                         ties === nothing ? _rmean : ties, na_rm, ties_missing)
    if xout === nothing
        n <= 0 && error("'approx' requires n >= 1")
        if nona
            xo = _seq_int(xv[1], xv[nx], n)
        else
            xs = xv[notna]
            xo = _seq_int(xs[1], xs[end], n)
        end
    else
        xo = _v(xout)
    end
    yo = _approx_core(xv, yv, xo, meth, yl, yr, Float64(f))
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
                   f::Real = 0, ties = nothing, na_rm::Bool = true)
    ties_missing = ties === nothing
    xv, yv, meth, yl, yr, nona, notna, nx = _approx_setup(x, y, method, yleft, yright, rule, Float64(f),
                                                         ties === nothing ? _rmean : ties, na_rm, ties_missing)
    return ApproxFun(xv, yv, meth, yl, yr, Float64(f), Dict{String,Any}())
end

"`filter(x, filter, method, sides, circular, init)` (ohne ts-Attribute)."
function r_filter(x, filter; method::AbstractString = "convolution", sides::Integer = 2, circular::Bool = false,
                  init = nothing)
    meth = [m for m in ("convolution", "recursive") if startswith(m, method)]
    length(meth) != 1 && error("'arg' should be one of “convolution”, “recursive”")
    method = meth[1]
    is_mat = x isa AbstractMatrix || x isa RFrame
    X = is_mat ? _as_cov_input(x)[1] : reshape(_v(x), :, 1)
    n, nser = size(X)
    fv = _v(filter)
    nf = length(fv)
    any(isnan, fv) && error("missing values in 'filter'")
    Y = Matrix{Float64}(undef, n, nser)
    if method == "convolution"
        nf > n && error("'filter' is longer than time series")
        sides = Int(sides)
        sides in (1, 2) || error("argument 'sides' must be 1 or 2")
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
        Y[:, s] = SimLev._rb_filter(Vector{Float64}(X[:, s]), Vector{Float64}(fv), method == "recursive", Int(sides),
                                    circular, Vector{Float64}(ini[:, s]))
    end
    is_mat && return Y
    return _vec_out(Y[:, 1])
end



# Interpolation und Filter (approx, approxfun, r_filter) aus R 4.3.3 stats/R/approx.R, filter.R und
# stats/src/approx.c, filter.c; Python: _r/stats_smooth.py.
# Teil des Untermoduls RStats (eingebunden in stats.jl).
#
# Seit Etappe 9.6c entfallen fft, bw_nrd0, density, smooth_spline und predict_smooth_spline: SimLev
# nutzt die eigene Gauß-Kerndichte und den eigenen Glättungsspline der C-Bibliothek slc (SimLev.SLib,
# Entwurf B.15, B.16).

# ── approx / approxfun / filter ──────────────────────────────────────────

"Gleiche Werte (−0 = +0, NaN als ein Wert) in Reihenfolge des ersten Auftretens."
function _unique_keys(v::Vector{Float64})
    keys = Float64[]
    idx = Int[]
    d = Dict{Float64,Int}()
    nanidx = 0
    for t in v
        if isnan(t)
            if nanidx == 0
                push!(keys, t); nanidx = length(keys)
            end
            push!(idx, nanidx)
        else
            k = _z0(t)
            g = get(d, k, 0)
            if g == 0
                push!(keys, t); g = length(keys); d[k] = g
            end
            push!(idx, g)
        end
    end
    keys, idx
end

function _regularize(x, y, ties, warn_collapsing::Bool, na_rm::Bool)
    xv = _v(x)
    if y === nothing
        yv = xv
        xv = Float64.(1:length(yv))
    else
        yv = _v(y)
    end
    length(xv) != length(yv) && error("'x' and 'y' lengths differ")
    kept_na = false
    na = isnan.(xv) .| isnan.(yv)
    ok = .!na
    if any(na)
        if na_rm
            xv = xv[ok]; yv = yv[ok]
            nx = length(xv)
        else
            kept_na = true
            nx = count(ok)
        end
    else
        nx = length(xv)
    end
    ordered = false
    fun = ties
    if ties isa AbstractString && ties == "ordered"
        ordered = true
        fun = nothing
    elseif ties isa Tuple && length(ties) == 2 && ties[2] isa Function
        fun = ties[2]
        ordered = ties[1] == "ordered"
    end
    if !(ties isa AbstractString && ties == "ordered")
        xx = kept_na ? xv[ok] : xv
        if !ordered && length(xx) > 1 && any(i -> xx[i+1] < xx[i], 1:length(xx)-1)
            o = _nan_last_perm(xv)
            xv = xv[o]; yv = yv[o]
        end
        ux, gidx = _unique_keys(xv)
        if length(ux) < nx
            warn_collapsing && @warn "collapsing to unique 'x' values"
            f = (fun === nothing || fun === _rmean || fun == "mean") ? _rmean : fun
            groups = [Float64[] for _ in ux]
            for (g, yi) in zip(gidx, yv)
                push!(groups[g], yi)
            end
            yv = Float64[Float64(first(_v(f(gr)))) for gr in groups]
            xv = ux
            kept_na && (ok = .!isnan.(xv))
        end
    end
    return xv, yv, kept_na, (kept_na ? ok : nothing)
end

"Stabile aufsteigende Permutation, NaN zuletzt (wie numpy argsort, kind = stable)."
function _nan_last_perm(v::Vector{Float64})
    ok = findall(!isnan, v)
    bad = findall(isnan, v)
    vcat(ok[_stable_argsort(v[ok], false, false)], bad)
end

function _approx_core(x::Vector{Float64}, y::Vector{Float64}, v::Vector{Float64}, method::Int,
                      yleft::Float64, yright::Float64, f::Float64)
    n = length(x)
    out = Vector{Float64}(undef, length(v))
    if n == 0
        fill!(out, NaN)
        return out
    end
    f2 = f
    f1 = 1 - f
    for (k, vk) in enumerate(v)
        if isnan(vk)
            out[k] = vk
            continue
        end
        i = 1
        j = n
        if vk < x[i]
            out[k] = yleft; continue
        end
        if vk > x[j]
            out[k] = yright; continue
        end
        while i < j - 1
            ij = (i + j) ÷ 2
            if vk < x[ij]
                j = ij
            else
                i = ij
            end
        end
        if vk == x[j]
            out[k] = y[j]; continue
        end
        if vk == x[i]
            out[k] = y[i]; continue
        end
        if method == 1
            out[k] = y[i] + (y[j] - y[i]) * ((vk - x[i]) / (x[j] - x[i]))
        else
            out[k] = (f1 != 0.0 ? y[i] * f1 : 0.0) + (f2 != 0.0 ? y[j] * f2 : 0.0)
        end
    end
    out
end

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
            xo = seq_len_out(xv[1], xv[nx], n)
        else
            xs = xv[notna]
            xo = seq_len_out(xs[1], xs[end], n)
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
    Y = fill(NA, n, nser)
    isok(t) = !isnan(t)
    if method == "convolution"
        nf > n && error("'filter' is longer than time series")
        sides = Int(sides)
        sides in (1, 2) || error("argument 'sides' must be 1 or 2")
        nshift = sides == 2 ? nf ÷ 2 : 0
        for s in 1:nser
            xs = view(X, :, s)
            for i in 0:n-1
                if !circular
                    (i + nshift - (nf - 1) < 0 || i + nshift >= n) && continue
                end
                z = 0.0
                bad = false
                for j in 0:nf-1
                    ii = i + nshift - j
                    if circular
                        ii < 0 && (ii += n)
                        ii >= n && (ii -= n)
                    end
                    tmp = xs[ii+1]
                    if isok(tmp)
                        z += fv[j+1] * tmp
                    else
                        bad = true
                        break
                    end
                end
                Y[i+1, s] = bad ? NA : z
            end
        end
    else
        if init === nothing
            ini = zeros(nf, nser)
        else
            ia = init isa AbstractMatrix ? _fmat(init isa NamedMat ? init.data : init) : reshape(_v(init), :, 1)
            size(ia, 1) != nf && error("length of 'init' must equal length of 'filter'")
            ncol = size(ia, 2)
            if ncol != 1 && ncol != nser
                nser == 1 && error("'init' must have $nser column")
                error("'init' must have 1 or $nser columns")
            end
            ini = (ncol == 1 && nser > 1) ? repeat(ia, 1, nser) : ia
        end
        for s in 1:nser
            r = vcat(reverse(ini[:, s]), zeros(n))
            for i in 1:n
                sm = X[i, s]
                if !isok(sm)
                    r[nf+i] = NA
                    continue
                end
                badf = false
                for j in 1:nf
                    tmp = r[nf+i-j]
                    if isok(tmp)
                        sm += tmp * fv[j]
                    else
                        r[nf+i] = NA
                        badf = true
                        break
                    end
                end
                badf || (r[nf+i] = sm)
            end
            Y[:, s] = r[nf+1:end]
        end
    end
    is_mat && return Y
    return _vec_out(Y[:, 1])
end



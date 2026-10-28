# Interpolation, Filter, Fourier-Transformation, Kerndichte und Glättungssplines (approx, approxfun, r_filter,
# fft, bw_nrd0, density, smooth_spline, predict_smooth_spline) aus R 4.3.3 stats/R/approx.R, filter.R, fft.R,
# bandwidths.R, density.R, smspline.R und stats/src/approx.c, filter.c, fourier.c, massdist.c, sbart.c;
# Python: _r/stats_smooth.py.
# Teil des Untermoduls RStats (eingebunden in stats.jl).

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

# ── fft / density ────────────────────────────────────────────────────────

"`fft(z, inverse)` (R's gemischte Basis); Ergebnis ComplexF64 gleicher Form (Matrizen: mehrdimensional wie R)."
function fft(z; inverse::Bool = false)
    a = z isa NamedMat ? z.data : z isa RVector ? z.values : z
    if a isa Number
        r, i = fft_vec([Float64(real(a))], [Float64(imag(a))]; inverse = inverse)
        return complex(r[1], i[1])
    end
    flat = vec(a)
    re = Float64[real(v) for v in flat]
    im = Float64[imag(v) for v in flat]
    dims = ndims(a) >= 2 ? collect(size(a)) : nothing
    r, i = fft_vec(re, im; inverse = inverse, dims = dims)
    out = ComplexF64[complex(r[k], i[k]) for k in eachindex(r)]
    return reshape(out, size(a))
end

"`bw.nrd0(x)`."
function bw_nrd0(x)
    xv = _v(x)
    length(xv) < 2 && error("need at least 2 data points")
    hi = sd(xv)
    q = quantile(xv, [0.25, 0.75]; names = false)
    iqr = q[2] - q[1]
    q134 = iqr / 1.34
    lo = isnan(hi) ? hi : (q134 < hi ? q134 : hi)
    (!isnan(hi) && isnan(q134)) && (lo = NaN)
    if lo == 0
        lo = hi
        if lo == 0
            lo = abs(xv[1])
            lo == 0 && (lo = 1.0)
        end
    end
    return 0.9 * lo * SimLev.r_pow(Float64(length(xv)), -0.2)
end

function _bindist(x, w, xlo, xhi, n)
    y = zeros(2 * n)
    ixmin = 0
    ixmax = n - 2
    xdelta = (xhi - xlo) / (n - 1)
    for (xi, wi) in zip(x, w)
        if isfinite(xi)
            xpos = (xi - xlo) / xdelta
            (xpos > 2147483647 || xpos < -2147483648) && continue
            ix = trunc(Int, floor(xpos))
            fx = xpos - ix
            if ixmin <= ix <= ixmax
                y[ix+1] += (1 - fx) * wi
                y[ix+2] += fx * wi
            elseif ix == -1
                y[1] += fx * wi
            elseif ix == ixmax + 1
                y[ix+1] += (1 - fx) * wi
            end
        end
    end
    y
end

"""
    density(x; bw = "nrd0", adjust = 1, kernel = "gaussian", weights = nothing, n = 512, from_ = nothing, to = nothing, cut = 3, na_rm = false)

`density.default(...)`: RList (Klasse \"density\") mit x, y, bw, n.
"""
function density(x; bw = "nrd0", adjust::Real = 1, kernel::AbstractString = "gaussian", weights = nothing,
                 n::Integer = 512, from_ = nothing, to = nothing, cut::Real = 3, na_rm::Bool = false)
    kernels = ["gaussian", "epanechnikov", "rectangular", "triangular", "biweight", "cosine", "optcosine"]
    km = [k for k in kernels if startswith(k, kernel)]
    length(km) != 1 && error("'arg' should be one of " * join(["“$(k)”" for k in kernels], ", "))
    kernel = km[1]
    xv = _v(x)
    N = length(xv)
    has_wts = weights !== nothing
    wv = Float64[]
    if has_wts
        wv = _v(weights)
        length(wv) != N && error("'x' and 'weights' have unequal length")
    end
    xna = isnan.(xv)
    if any(xna)
        if na_rm
            xv = xv[.!xna]
            N = length(xv)
            if has_wts
                trueD = SimLev.RLinalg.all_equal_numeric(1.0, _rsum(wv)) === true
                wv = wv[.!xna]
                trueD && (wv = wv ./ _rsum(wv))
            end
        else
            error("'x' contains missing values")
        end
    end
    nx = N
    xfin = isfinite.(xv)
    if !all(xfin)
        xv = xv[xfin]
        nx = length(xv)
    end
    if !has_wts
        wv = nx > 0 ? fill(1.0 / nx, nx) : Float64[]
        totMass = nx / N
    else
        all(isfinite, wv) || error("'weights' must all be finite")
        any(<(0), wv) && error("'weights' must not be negative")
        wsum = _rsum(wv)
        if !all(xfin)
            wv = wv[xfin]
            totMass = _rsum(wv) / wsum
        else
            totMass = 1.0
        end
        SimLev.RLinalg.all_equal_numeric(1.0, wsum) === true || @warn "sum(weights) != 1  -- will not get true density"
    end
    n_user = Int(n)
    n = max(n_user, 512)
    n > 512 && (n = trunc(Int, SimLev.r_pow(2.0, ceil(SimLev.RLibm.log2(Float64(n))))))
    if bw isa AbstractString
        nx < 2 && error("need at least 2 points to select a bandwidth automatically")
        (has_wts && var(wv) > 0) && @warn "Selecting bandwidth *not* using 'weights'"
        lowercase(bw) != "nrd0" && error("density(): nur bw = 'nrd0' ist portiert")
        bw = bw_nrd0(xv)
    end
    bw = Float64(bw)
    isfinite(bw) || error("non-finite 'bw'")
    bw = adjust * bw
    bw <= 0 && error("'bw' is not positive.")
    from_ === nothing && (from_ = minimum(xv) - cut * bw)
    to === nothing && (to = maximum(xv) + cut * bw)
    from_ = Float64(from_); to = Float64(to)
    isfinite(from_) || error("non-finite 'from'")
    isfinite(to) || error("non-finite 'to'")
    lo = from_ - 4 * bw
    up = to + 4 * bw
    y = _bindist(xv, wv, lo, up, n) .* totMass
    kords = seq_len_out(0.0, 2 * (up - lo), 2 * n)
    kords[n+2:2n] = -kords[n:-1:2]
    cosf = SimLev.RLibm.c_cos
    if kernel == "gaussian"
        kords = _v(SimLev.RNmath.dnorm(kords; sd = bw))
    elseif kernel == "rectangular"
        a = bw * sqrt(3.0)
        kords = Float64[abs(k) < a ? 0.5 / a : 0.0 for k in kords]
    elseif kernel == "triangular"
        a = bw * sqrt(6.0)
        kords = Float64[abs(k) < a ? (1 - abs(k) / a) / a : 0.0 for k in kords]
    elseif kernel == "epanechnikov"
        a = bw * sqrt(5.0)
        kords = Float64[(q = abs(k) / a; abs(k) < a ? 3 / 4 * (1 - q * q) / a : 0.0) for k in kords]
    elseif kernel == "biweight"
        a = bw * sqrt(7.0)
        kords = Float64[(q = abs(k) / a; t = 1 - q * q; abs(k) < a ? 15 / 16 * (t * t) / a : 0.0) for k in kords]
    elseif kernel == "cosine"
        a = bw / sqrt(1 / 3 - 2 / (pi * pi))
        kords = Float64[abs(k) < a ? (1 + cosf(pi * k / a)) / (2 * a) : 0.0 for k in kords]
    else
        a = bw / sqrt(1 - 8 / (pi * pi))
        kords = Float64[abs(k) < a ? pi / 4 * cosf(pi * k / (2 * a)) / a : 0.0 for k in kords]
    end
    fyr, fyi = fft_vec(y, zeros(length(y)))
    fkr, fki = fft_vec(kords, zeros(length(kords)))
    pr = similar(fyr); pim = similar(fyi)
    for k in eachindex(fyr)
        cr = fkr[k]; ci = -fki[k]
        pr[k] = fyr[k] * cr - fyi[k] * ci
        pim[k] = fyr[k] * ci + fyi[k] * cr
    end
    kr, _ = fft_vec(pr, pim; inverse = true)
    kv = Float64[(t = kr[k] / length(y); isnan(t) ? t : (t > 0 ? t : 0.0)) for k in 1:n]
    xords = seq_len_out(lo, up, n)
    xo = seq_len_out(from_, to, n_user)
    return RList("x" => xo, "y" => approx(xords, kv; xout = xo)["y"], "bw" => bw, "n" => N, "call" => nothing,
                 "data.name" => "x", "has.na" => false; class = "density")
end

# ── smooth.spline ────────────────────────────────────────────────────────

function _nknots_smspl(n::Int)
    n < 50 && return n
    L2 = SimLev.RLibm.log2
    a1 = L2(50.0); a2 = L2(100.0); a3 = L2(140.0); a4 = L2(200.0)
    if n < 200
        v = SimLev.r_pow(2.0, a1 + (a2 - a1) * (n - 50) / 150)
    elseif n < 800
        v = SimLev.r_pow(2.0, a2 + (a3 - a2) * (n - 200) / 600)
    elseif n < 3200
        v = SimLev.r_pow(2.0, a3 + (a4 - a3) * (n - 800) / 2400)
    else
        v = 200 + SimLev.r_pow(Float64(n - 3200), 0.2)
    end
    return trunc(Int, v)
end

"""
    smooth_spline(x, y = nothing; w, df, spar, lambda_, cv = false, all_knots = false, nknots, keep_data = true, df_offset = 0, penalty = 1, control_spar, tol)

`smooth.spline(...)`; `lambda` heißt `lambda_`, `cv = missing` entspricht
`cv = NA`. Ergebnis: RList (Klasse \"smooth.spline\"); Vorhersage mit
`predict_smooth_spline`.
"""
function smooth_spline(x, y = nothing; w = nothing, df = nothing, spar = nothing, lambda_ = nothing, cv = false,
                       all_knots = false, nknots = nothing, keep_data::Bool = true, df_offset::Real = 0,
                       penalty::Real = 1, control_spar = nothing, tol = nothing, keep_stuff::Bool = false)
    contr = Dict{String,Any}("low" => -1.5, "high" => 1.5, "tol" => 1e-4, "eps" => 2e-8, "maxit" => 500, "trace" => false)
    control_spar === nothing || merge!(contr, _ctl_dict(control_spar))
    (contr["tol"] < 0 || contr["eps"] <= 0 || contr["maxit"] <= 0) && error("invalid 'control.spar'")
    xv = _v(x)
    if y === nothing
        yv = xv
        xv = Float64.(1:length(yv))
    else
        yv = _v(y)
        length(yv) != length(xv) && error("'x' and 'y' lengths differ")
    end
    (all(isfinite, xv) && all(isfinite, yv)) || error("missing or infinite values in inputs are not allowed")
    n = length(xv)
    no_wgts = w === nothing
    wv = Float64[]
    if !no_wgts
        wv = _v(w)
        n != length(wv) && error("lengths of 'x' and 'w' must match")
        any(<(0), wv) && error("all weights should be non-negative")
        all(==(0), wv) && error("some weights should be positive")
        wv = (wv .* Float64(count(>(0), wv))) ./ _rsum(wv)
    end
    if tol === nothing
        q = quantile(xv, [0.25, 0.75]; names = false)
        tol = 1e-6 * (q[2] - q[1])
    end
    tol = Float64(tol)
    (!isfinite(tol) || tol <= 0) && error("'tol' must be strictly positive and finite")
    mx = _rmean(xv)
    xx = Float64[round((t - mx) / tol) for t in xv]
    uns = n > 1 && any(i -> xv[i+1] < xv[i], 1:n-1)
    iOx = uns ? _stable_argsort(xv, false, false) : collect(1:n)
    xxs = xx[iOx]
    nd = vcat(true, [xxs[i] < xxs[i+1] for i in 1:n-1])
    ux = xv[iOx][nd]
    nx = length(ux)
    nx <= 3 && error("need at least four unique 'x' values")
    if nx == n
        ox = uns ? invperm(iOx) : collect(1:n)
        tmp = no_wgts ? hcat(ones(n), 1 .* yv, 1 .* (yv .* yv))[iOx, :] : hcat(wv, wv .* yv, wv .* (yv .* yv))[iOx, :]
    else
        ukeys = xxs[nd]
        ox = [searchsortedfirst(ukeys, t; lt = <) for t in xx]
        tmp = zeros(nx, 3)
        for g in 1:nx
            idx = findall(==(g), ox)
            if no_wgts
                tmp[g, :] = [Float64(length(idx)), _rsum(yv[idx]), _rsum(yv[idx] .* yv[idx])]
            else
                tmp[g, :] = [_rsum(wv[idx]), _rsum(wv[idx] .* yv[idx]), _rsum(wv[idx] .* (yv[idx] .* yv[idx]))]
            end
        end
    end
    wbar = tmp[:, 1]
    ybar = tmp[:, 2] ./ Float64[t > 0 ? t : 1.0 for t in wbar]
    yssw = _rsum(tmp[:, 3] .- wbar .* (ybar .* ybar))
    (cv === missing && df !== nothing) && error("'cv' must not be NA when 'df' is specified")
    CV = cv !== missing && cv === true
    (CV && nx < n) && @warn "cross-validation with non-unique 'x' values seems doubtful"
    r_ux = ux[nx] - ux[1]
    xbar = (ux .- ux[1]) ./ r_ux
    if !(all_knots isa Bool)
        ak = _v(all_knots)
        (length(ak) > 1 && any(i -> ak[i+1] <= ak[i], 1:length(ak)-1)) && error("Numeric 'all.knots' must be strictly increasing")
        nknots !== nothing && @warn "'all.knots' is vector of knots; 'nknots' specification is disregarded"
        nknots = length(ak)
        (0 < ak[1] || ak[end] < 1) && error("numeric 'all.knots' must cover [0,1] (= the transformed data-range)")
        knot = vcat(fill(ak[1], 3), ak, fill(ak[end], 3))
    else
        if all_knots
            nknots !== nothing && @warn "'all.knots' is TRUE; 'nknots' specification is disregarded"
            nknots = nx
        elseif nknots === nothing
            nknots = _nknots_smspl(nx)
        else
            nknots isa Function && (nknots = nknots(nx))
            if nknots < 1
                error("'nknots' must be at least 1")
            elseif nknots > nx
                error("cannot use more inner knots than unique 'x' values")
            end
        end
        nknots = Int(nknots)
        inner = all_knots ? xbar : xbar[[trunc(Int, t) for t in seq_len_out(1, nx, nknots)]]
        knot = vcat(fill(xbar[1], 3), inner, fill(xbar[nx], 3))
    end
    nk = nknots + 2
    spar_is_lambda = lambda_ !== nothing
    if spar_is_lambda
        spar !== nothing && error("must not specify both 'spar' and 'lambda'")
        ispar = 1
    else
        ispar = spar === nothing ? (contr["trace"] == true ? -1 : 0) : 1
    end
    sparv = spar_is_lambda ? Float64(lambda_) : (ispar == 1 ? Float64(spar) : 0.0)
    icrit = cv === missing ? 0 : (cv === true ? 2 : 1)
    dofoff = Float64(df_offset)
    if df !== nothing
        if 1 < df <= nx
            icrit = 3
            dofoff = Float64(df)
        else
            @warn "not using invalid df; must have 1 < df <= n := #{unique x} = $nx"
        end
    end
    isetup = spar_is_lambda ? 2 : 0
    fit = sbart(Float64(penalty), dofoff, xbar, ybar, wbar, yssw, nx, knot, nk, icrit, sparv, ispar,
                Int(contr["maxit"]), Float64(contr["low"]), Float64(contr["high"]), Float64(contr["tol"]),
                Float64(contr["eps"]), isetup)
    ty = fit.sz[1:nx]
    if cv === missing
        lev = NA
        dfv = NA
    else
        lev = fit.lev[1:nx]
        dfv = _rsum(lev)
        isnan(dfv) && error("NA lev[]; probably smoothing parameter 'spar' way too large!")
    end
    if fit.ier > 0
        sml = !spar_is_lambda && fit.spar < 0.5
        kind = spar_is_lambda ? "extreme" : (sml ? "small" : "large")
        wtxt = "smoothing parameter value too " * kind
        (spar_is_lambda || sml) && error(wtxt)
        ty = fill(_rmean(yv), nx)
        dfv = 1.0
        @warn wtxt * "\nsetting df = 1  __use with care!__"
    end
    if cv === missing
        cvcrit = NA
    else
        r = yv .- ty[ox]
        if CV
            ww = copy(wbar)
            ww[ww .== 0] .= 1
            wfac = no_wgts ? ones(n) : wv
            r = r ./ (1 .- (lev[ox] .* wfac) ./ ww[ox])
            cvcrit = no_wgts ? _rmean(r .* r) : weighted_mean(r .* r, wv)
        else
            base = no_wgts ? _rmean(r .* r) : weighted_mean(r .* r, wv)
            t = 1 - (df_offset + penalty * dfv) / n
            cvcrit = base / (t * t)
        end
    end
    dd = ybar .- ty
    pen = _rsum(wbar .* (dd .* dd))
    fobj = RList("knot" => knot, "nk" => nk, "min" => ux[1], "range" => r_ux, "coef" => fit.coef[1:nk];
                 class = "smooth.spline.fit")
    return RList("x" => ux, "y" => ty, "w" => wbar, "yin" => ybar, "tol" => tol,
                 "data" => (keep_data ? RList("x" => xv, "y" => yv, "w" => (no_wgts ? 1.0 : wv)) : nothing),
                 "no.weights" => no_wgts, "n" => n, "lev" => lev, "cv" => cv, "cv.crit" => cvcrit, "pen.crit" => pen,
                 "crit" => fit.crit, "df" => dfv, "spar" => (spar_is_lambda ? NA : fit.spar),
                 "ratio" => (spar_is_lambda ? NA : fit.ratio), "lambda" => fit.lspar,
                 "iparms" => RVector([Float64(icrit), Float64(ispar), Float64(ispar != 1 ? fit.iter : contr["maxit"]),
                                      Float64(spar_is_lambda), fit.ier != 0 ? Float64(fit.ier) : NA];
                                     names = ["icrit", "ispar", "iter", "", "errorI"]),
                 "auxM" => nothing, "fit" => fobj, "call" => nothing; class = "smooth.spline")
end

function _predict_ssfit(obj, x = nothing, deriv::Int = 0)
    x === nothing && (x = seq_len_out(obj["min"], obj["min"] + obj["range"], length(obj["coef"]) - 4))
    xv = _v(x)
    xs = (xv .- obj["min"]) ./ obj["range"]
    el = xs .< 0
    er = xs .> 1
    ex = el .| er
    interp = .!ex
    y = copy(xs)
    if any(interp)
        y[interp] = bvalus(collect(Float64, obj["knot"]), collect(Float64, obj["coef"]), Int(obj["nk"]), xs[interp], deriv)
    end
    if any(ex)
        xrange = [obj["min"], obj["min"] + obj["range"]]
        if deriv == 0
            eo = _v(_predict_ssfit(obj, xrange)["y"])
            es = _v(_predict_ssfit(obj, xrange, 1)["y"]) .* obj["range"]
            any(el) && (y[el] = eo[1] .+ es[1] .* (xs[el] .- 0))
            any(er) && (y[er] = eo[2] .+ es[2] .* (xs[er] .- 1))
        elseif deriv == 1
            es = _v(_predict_ssfit(obj, xrange, 1)["y"]) .* obj["range"]
            y[el] .= es[1]
            y[er] .= es[2]
        else
            y[ex] .= 0.0
        end
    end
    deriv > 0 && (y = y ./ SimLev.r_pow(obj["range"], Float64(deriv)))
    return RList("x" => x, "y" => _vec_out(y))
end

"`predict.smooth.spline(object, x, deriv)`: RList mit x, y."
function predict_smooth_spline(object, x = nothing; deriv::Integer = 0)
    if x === nothing
        deriv == 0 && return RList("x" => object["x"], "y" => object["y"])
        x = object["x"]
    end
    fit = get(object, "fit", nothing)
    fit === nothing && error("not a valid \"smooth.spline\" object")
    return _predict_ssfit(fit, x, Int(deriv))
end

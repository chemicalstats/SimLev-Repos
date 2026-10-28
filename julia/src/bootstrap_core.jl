# BootstrapCore – Port von r/src/bootstrap_core.cpp, .garch_filter und r/src/ms_garch.c
#
# Jeder Kern liefert wie im Original die 1-basierten Quellzeilen der gezogenen
# Beobachtungen; parametrische Verfahren zusätzlich die simulierte
# Renditematrix. Zufallszahlen ausschließlich über SimLev.RRng
# (R::runif = runif1, R::rgeom = rgeom1, R::rnorm = rnorm1), damit set_seed
# und L'Ecuyer-Streams wie in R greifen. Rechenreihenfolge 1:1 aus dem C++-Code
# (Vorlage: python/simlev/_bootstrap_core.py).
module BootstrapCore

import ..SimLev
using Dates

export boot_idx_iid, boot_idx_block, boot_idx_stationary, boot_idx_regime, boot_idx_tails,
       boot_wild, boot_reset, boot_evt, boot_garch, boot_ms_garch, rolling_vol, assign_regimes,
       estimate_trans_mat, garch_filter, ms_garch_filter

_rng() = SimLev.RRng
_runif1(a, b) = Float64(_rng().runif1(Float64(a), Float64(b)))

"Gleichverteilt in {0, …, n-1}: `floor(R::runif(0, n))`."
function _draw_int(n::Int)
    k = floor(_runif1(0.0, Float64(n)))
    k >= n && return n - 1
    return Int(k)
end

# Rcpp::RNGScope → GetRNGstate()
_state() = (_rng()._get_state(); nothing)

_as_int_vec(x) = x === nothing ? Int[] : x isa Number ? [Int(x)] : Int[Int(v) for v in vec(collect(x))]
_as_dbl_vec(x) = x === nothing ? Float64[] : x isa Number ? [Float64(x)] : Float64[Float64(v) for v in vec(collect(x))]
_as_bool_vec(x) = x === nothing ? Bool[] : x isa Bool ? [x] : Bool[Bool(v) for v in vec(collect(x))]

function _as_mat(x)
    x isa SimLev.NamedMat && return Matrix{Float64}(x.data)
    x isa AbstractMatrix && return Matrix{Float64}(x)
    x isa Number && return fill(Float64(x), 1, 1)
    v = _as_dbl_vec(x)
    return reshape(v, length(v), 1)
end

_stop(msg) = error(msg)

# ── Index-Kerne ───────────────────────────────────────────────────────────

"`.boot_idx_iid`: IID-Bootstrap (Efron 1979)."
function boot_idx_iid(n_src, n_out)
    n_src = Int(n_src); n_out = Int(n_out)
    n_src < 1 && _stop("Keine Quellzeilen")
    _state()
    idx = Vector{Int}(undef, n_out)
    @inbounds for i in 1:n_out
        idx[i] = _draw_int(n_src) + 1
    end
    return idx
end

"`.boot_idx_block`: Moving bzw. Circular Block Bootstrap."
function boot_idx_block(n_src, n_out, block_length, circular)
    n_src = Int(n_src); n_out = Int(n_out); block_length = Int(block_length)
    n_src < 1 && _stop("Keine Quellzeilen")
    block_length <= 0 && _stop("block_length muss positiv sein")
    block_length > n_src && _stop("block_length ($block_length) ist größer als die Historie ($n_src Zeilen)")
    _state()
    idx = Vector{Int}(undef, n_out)
    i = 0
    n_start = circular ? n_src : (n_src - block_length + 1)
    while i < n_out
        start = _draw_int(n_start)
        ln = min(block_length, n_out - i)
        for t in 0:ln-1
            idx[i+t+1] = ((start + t) % n_src) + 1
        end
        i += ln
    end
    return idx
end

"`.boot_idx_stationary`: stationärer Bootstrap (Politis & Romano 1994)."
function boot_idx_stationary(n_src, n_out, L)
    n_src = Int(n_src); n_out = Int(n_out); L = Float64(L)
    n_src < 1 && _stop("Keine Quellzeilen")
    L >= 1.0 || _stop("L muss >= 1 sein")
    _state()
    idx = Vector{Int}(undef, n_out)
    p = 1.0 / L
    i = 0
    while i < n_out
        ln = p >= 1.0 ? 1 : Int(trunc(Float64(_rng().rgeom1(p)))) + 1
        start = _draw_int(n_src)
        ln = min(ln, n_out - i)
        for t in 0:ln-1
            idx[i+t+1] = ((start + t) % n_src) + 1
        end
        i += ln
    end
    return idx
end

function _stationary_dist(P::Matrix{Float64})
    K = size(P, 1)
    pi_ = fill(1.0 / K, K)
    nw = zeros(K)
    for _ in 1:2000
        s = 0.0
        diff = 0.0
        for j in 1:K
            v = 0.0
            for i in 1:K
                v += pi_[i] * P[i, j]
            end
            nw[j] = v
            s += v
        end
        for j in 1:K
            nw[j] /= s
            diff += abs(nw[j] - pi_[j])
        end
        pi_ = copy(nw)
        diff < 1e-12 && break
    end
    return pi_
end

function _draw_from(p::AbstractVector{Float64}, K::Int)
    u = _runif1(0.0, 1.0)
    c = 0.0
    for r in 1:K
        c += p[r]
        u <= c && return r
    end
    return K
end

"`.boot_idx_regime`: Markov-Kette über Volatilitätsregime."
function boot_idx_regime(regimes, trans, n_out)
    reg = _as_int_vec(regimes)
    T = _as_mat(trans)
    n = length(reg)
    K = size(T, 1)
    n_out = Int(n_out)
    pool = [Int[] for _ in 1:K]
    for i in 1:n
        r = reg[i]
        1 <= r <= K && push!(pool[r], i - 1)
    end
    _state()
    pi_ = _stationary_dist(T)
    for r in 1:K
        isempty(pool[r]) && (pi_[r] = 0.0)
    end
    s = 0.0
    for r in 1:K
        s += pi_[r]
    end
    pi_ = Float64[s > 0 ? pi_[r] / s : 1.0 / K for r in 1:K]
    cur = _draw_from(pi_, K)
    idx = Vector{Int}(undef, n_out)
    row = zeros(K)
    for t in 1:n_out
        p = pool[cur]
        if isempty(p)
            for r in 1:K
                if !isempty(pool[r])
                    p = pool[r]
                    break
                end
            end
        end
        idx[t] = p[_draw_int(length(p))+1] + 1
        for r in 1:K
            row[r] = T[cur, r]
        end
        cur = _draw_from(row, K)
    end
    return idx
end

"`.boot_idx_tails`: Mischung aus linkem Rand, Kern und rechtem Rand."
function boot_idx_tails(n_out, p_l, p_r, bulk_idx, left_idx, right_idx)
    b = _as_int_vec(bulk_idx); lf = _as_int_vec(left_idx); rt = _as_int_vec(right_idx)
    nb, nl, nr = length(b), length(lf), length(rt)
    nb == 0 && _stop("Keine Bulk-Beobachtungen")
    _state()
    n_out = Int(n_out)
    p_l = Float64(p_l); p_r = Float64(p_r)
    idx = Vector{Int}(undef, n_out)
    for t in 1:n_out
        u = _runif1(0.0, 1.0)
        if u < p_l && nl > 0
            idx[t] = lf[_draw_int(nl)+1]
        elseif u < p_l + p_r && nr > 0
            idx[t] = rt[_draw_int(nr)+1]
        else
            idx[t] = b[_draw_int(nb)+1]
        end
    end
    return idx
end

# ── Matrix-Kerne ──────────────────────────────────────────────────────────

"`.boot_wild`: Wild Bootstrap mit gemeinsamem Gewicht je Zeile."
function boot_wild(returns, type)
    type = Int(type)
    (type < 0 || type > 2) && _stop("wild_type muss 0, 1 oder 2 sein (erhalten: $type)")
    X = _as_mat(returns)
    n, k = size(X)
    mu = zeros(k)
    for j in 1:k
        s = 0.0
        for i in 1:n
            s += X[i, j]
        end
        mu[j] = s / n
    end
    s5 = sqrt(5.0)
    mp = (s5 + 1.0) / (2.0 * s5)
    mneg = -(s5 - 1.0) / 2.0
    mpos = (s5 + 1.0) / 2.0
    _state()
    out = Matrix{Float64}(undef, n, k)
    for i in 1:n
        w = if type == 0
            _runif1(0.0, 1.0) < 0.5 ? -1.0 : 1.0
        elseif type == 1
            _runif1(0.0, 1.0) < mp ? mneg : mpos
        else
            Float64(_rng().rnorm1(0.0, 1.0))
        end
        for j in 1:k
            out[i, j] = mu[j] + (X[i, j] - mu[j]) * w
        end
    end
    return out
end

"`.boot_reset`: Segmente mit Wahrscheinlichkeit `p_break` spiegeln."
function boot_reset(returns, p_break)
    p_break = Float64(p_break)
    (p_break >= 0.0 && p_break <= 1.0) || _stop("p_break muss in [0, 1] liegen")
    X = _as_mat(returns)
    n, k = size(X)
    _state()
    out = Matrix{Float64}(undef, n, k)
    flipped = false
    for t in 1:n
        _runif1(0.0, 1.0) < p_break && (flipped = !flipped)
        for j in 1:k
            out[t, j] = flipped ? 2.0 - X[t, j] : X[t, j]
        end
    end
    return out
end

function _rgpd(scale::Float64, shape::Float64)
    u = _runif1(0.0, 1.0)
    u <= 0.0 && (u = 1e-300)
    abs(shape) < 1e-10 && return -scale * SimLev.RLibm.log(u)
    return scale * (SimLev.RLibm.pow(u, -shape) - 1.0) / shape
end

"`.boot_evt`: Kern empirisch, Ränder der Basisreihe aus der GPD."
function boot_evt(returns, base, n_out, p_l, thresh_l, scale_l, shape_l, pool_l,
                  p_r, thresh_r, scale_r, shape_r, pool_r, bulk_idx)
    X = _as_mat(returns)
    k = size(X, 2)
    base = Int(base) + 1
    pl = _as_int_vec(pool_l); pr = _as_int_vec(pool_r); b = _as_int_vec(bulk_idx)
    nb, nl, nr = length(b), length(pl), length(pr)
    nb == 0 && _stop("Keine Bulk-Beobachtungen")
    p_l = Float64(p_l); thresh_l = Float64(thresh_l); scale_l = Float64(scale_l); shape_l = Float64(shape_l)
    p_r = Float64(p_r); thresh_r = Float64(thresh_r); scale_r = Float64(scale_r); shape_r = Float64(shape_r)
    n_out = Int(n_out)
    out = Matrix{Float64}(undef, n_out, k)
    idx = Vector{Int}(undef, n_out)
    _state()
    for t in 1:n_out
        u = _runif1(0.0, 1.0)
        left = u < p_l
        right = !left && p_r > 0 && u < p_l + p_r
        if (left && nl > 0) || (right && nr > 0)
            if left
                rb = thresh_l - _rgpd(scale_l, shape_l)
                j = pl[_draw_int(nl)+1]
            else
                rb = thresh_r + _rgpd(scale_r, shape_r)
                j = pr[_draw_int(nr)+1]
            end
            for c in 1:k
                out[t, c] = c == base ? rb : rb * X[j, c] / X[j, base]
            end
            idx[t] = j
        else
            j = b[_draw_int(nb)+1]
            for c in 1:k
                out[t, c] = X[j, c]
            end
            idx[t] = j
        end
    end
    return SimLev.RList("ret" => out, "idx" => idx)
end

mutable struct _Cross
    col::Vector{Int}
    m::Int
    mu::Vector{Float64}
    om::Vector{Float64}
    al::Vector{Float64}
    be::Vector{Float64}
    ratio::Vector{Bool}
    s2::Vector{Float64}
    eps::Vector{Float64}
end
function _Cross(cols, mu, om, al, be, ratio, s2_init)
    col = _as_int_vec(cols)
    _Cross(col, length(col), _as_dbl_vec(mu), _as_dbl_vec(om), _as_dbl_vec(al), _as_dbl_vec(be),
           _as_bool_vec(ratio), _as_dbl_vec(s2_init), zeros(length(col)))
end

function _step!(cs::_Cross, out::Matrix{Float64}, t::Int, base_ret::Float64, zc::Matrix{Float64}, tstar::Int)
    for c in 1:cs.m
        s2 = cs.om[c] + cs.al[c] * cs.eps[c] * cs.eps[c] + cs.be[c] * cs.s2[c]
        s2 < 1e-14 && (s2 = 1e-14)
        cs.s2[c] = s2
        e = sqrt(s2) * zc[tstar, c]
        cs.eps[c] = e
        g = 1.0 + cs.mu[c] + e
        out[t, cs.col[c]+1] = cs.ratio[c] ? base_ret * g : g
    end
end

function _zmat(z)
    z === nothing && return zeros(0, 0)
    z isa SimLev.NamedMat && return Matrix{Float64}(z.data)
    z isa AbstractMatrix && return Matrix{Float64}(z)
    v = _as_dbl_vec(z)
    return isempty(v) ? zeros(0, 0) : reshape(v, length(v), 1)
end

"`.boot_garch`: (GJR-)GARCH(1,1) mit Filtered Historical Simulation."
function boot_garch(n_out, base, k, mu, omega, alpha, beta, gamma, s2_init, z_base, valid,
                    cross_cols, cmu, com, cal, cbe, cratio, cs2, z_cross)
    omega = Float64(omega)
    omega <= 0 && _stop("omega muss > 0 sein")
    v = _as_int_vec(valid)
    nv = length(v)
    nv == 0 && _stop("Keine gültigen Residuen")
    n_out = Int(n_out); base = Int(base) + 1
    mu = Float64(mu); alpha = Float64(alpha); beta = Float64(beta); gamma = Float64(gamma)
    zb = _as_dbl_vec(z_base)
    zc = _zmat(z_cross)
    out = zeros(n_out, Int(k))
    idx = Vector{Int}(undef, n_out)
    cs = _Cross(cross_cols, cmu, com, cal, cbe, cratio, cs2)
    s2 = Float64(s2_init)
    eps = 0.0
    _state()
    for t in 1:n_out
        ind = eps < 0.0 ? 1.0 : 0.0
        s2 = omega + (alpha + gamma * ind) * eps * eps + beta * s2
        s2 < 1e-14 && (s2 = 1e-14)
        ts = v[_draw_int(nv)+1]
        eps = sqrt(s2) * zb[ts]
        rb = 1.0 + mu + eps
        out[t, base] = rb
        _step!(cs, out, t, rb, zc, ts)
        idx[t] = ts
    end
    return SimLev.RList("ret" => out, "idx" => idx)
end

"`.boot_ms_garch`: Markov-Switching-(AR-)GJR-GARCH(-M), optional TVTP."
function boot_ms_garch(n_out, base, k, K, mu, omega, alpha, beta, gamma, phi, lam,
                       trans, delta, unc_var, stat_prob, pools, z_base,
                       cross_cols, cmu, com, cal, cbe, cratio, cs2, z_cross)
    K = Int(K)
    mu = _as_dbl_vec(mu); omega = _as_dbl_vec(omega); alpha = _as_dbl_vec(alpha); beta = _as_dbl_vec(beta)
    gamma = _as_dbl_vec(gamma); phi = _as_dbl_vec(phi); lam = _as_dbl_vec(lam)
    T = _as_mat(trans)
    D = _as_mat(delta)
    uv = _as_dbl_vec(unc_var)
    for i in 1:K
        rs = 0.0
        for j in 1:K
            rs += T[i, j]
        end
        abs(rs - 1.0) > 1e-6 && _stop("Zeile $i der Uebergangsmatrix summiert nicht auf 1")
        uv[i] <= 0 && _stop("unc_var[$i] <= 0")
    end
    pl = [_as_int_vec(p) for p in pools]
    tvtp = any(abs(D[i, j]) > 1e-12 for i in 1:K for j in 1:K)
    n_out = Int(n_out); base = Int(base) + 1
    zb = _as_dbl_vec(z_base)
    zc = _zmat(z_cross)
    out = zeros(n_out, Int(k))
    idx = Vector{Int}(undef, n_out)
    reg = Vector{Int}(undef, n_out)
    cs = _Cross(cross_cols, cmu, com, cal, cbe, cratio, cs2)
    sp = _as_dbl_vec(stat_prob)
    pr = zeros(K)
    _state()
    r = _draw_from(sp, K)
    s2 = uv[r]
    eps = 0.0
    prev = 0.0
    for t in 1:n_out
        if t > 1
            old = r
            if tvtp
                x = s2 / uv[old] - 1.0
                x = min(10.0, max(-0.99, x))
                mx = -1e300
                for j in 1:K
                    b = max(T[old, j], 1e-10)
                    pr[j] = SimLev.RLibm.log(b) + D[old, j] * x
                    mx = max(mx, pr[j])
                end
                se = 0.0
                for j in 1:K
                    pr[j] = SimLev.RLibm.exp(pr[j] - mx)
                    se += pr[j]
                end
                for j in 1:K
                    pr[j] /= se
                end
            else
                for j in 1:K
                    pr[j] = T[old, j]
                end
            end
            r = _draw_from(pr, K)
            r != old && (s2 = 0.5 * s2 + 0.5 * uv[r])
        end
        ind = eps < 0.0 ? 1.0 : 0.0
        s2 = omega[r] + (alpha[r] + gamma[r] * ind) * eps * eps + beta[r] * s2
        s2 < 1e-14 && (s2 = 1e-14)
        sig = sqrt(s2)
        p = pl[r]
        if isempty(p)
            for q in 1:K
                if !isempty(pl[q])
                    p = pl[q]
                    break
                end
            end
        end
        ts = p[_draw_int(length(p))+1]
        eps = sig * zb[ts]
        m = mu[r] + phi[r] * prev + lam[r] * sig
        ex = m + eps
        rb = 1.0 + ex
        out[t, base] = rb
        prev = ex
        _step!(cs, out, t, rb, zc, ts)
        idx[t] = ts
        reg[t] = r
    end
    return SimLev.RList("ret" => out, "idx" => idx, "regime" => reg)
end

# ── Hilfsfunktionen ──────────────────────────────────────────────────────

"`.rolling_vol`: rollierende Volatilität von `x - 1` (Bessel)."
function rolling_vol(x, window)
    xs = _as_dbl_vec(x)
    n = length(xs)
    window = Int(window)
    window <= 0 && _stop("window muss positiv sein")
    window > n && (window = n)
    vol = Vector{Float64}(undef, n)
    s = 0.0
    sq = 0.0
    for i in 1:n
        v = xs[i] - 1.0
        s += v
        sq += v * v
        if i - 1 >= window
            o = xs[i-window] - 1.0
            s -= o
            sq -= o * o
        end
        cnt = min(i, window)
        if cnt <= 1
            vol[i] = 0.0
        else
            m = s / cnt
            vol[i] = sqrt(max(0.0, (sq - cnt * m * m) / (cnt - 1)))
        end
    end
    return vol
end

"`.assign_regimes`: Regime über Schwellen `[tau_r, tau_{r+1})`."
function assign_regimes(vol, thresh)
    v = _as_dbl_vec(vol)
    th = _as_dbl_vec(thresh)
    K = length(th) - 1
    reg = fill(K, length(v))
    for (i, x) in enumerate(v)
        for r in 1:K
            if x >= th[r] && x < th[r+1]
                reg[i] = r
                break
            end
        end
    end
    return reg
end

"`.estimate_trans_mat`: Übergangsmatrix mit Laplace-Glättung."
function estimate_trans_mat(regimes, K, alpha = 0.1)
    reg = _as_int_vec(regimes)
    K = Int(K); alpha = Float64(alpha)
    P = zeros(K, K)
    for t in 2:length(reg)
        a = reg[t-1]; b = reg[t]
        (1 <= a <= K && 1 <= b <= K) && (P[a, b] += 1.0)
    end
    for r in 1:K
        s = 0.0
        for c in 1:K
            P[r, c] += alpha
            s += P[r, c]
        end
        for c in 1:K
            P[r, c] /= s
        end
    end
    return P
end

"`.garch_filter`: bedingte Varianzen eines GARCH(1,1)/GJR-Modells."
function garch_filter(ep, om, al, be, ga, v0)
    e = _as_dbl_vec(ep)
    om = Float64(om); al = Float64(al); be = Float64(be); ga = Float64(ga)
    n = length(e)
    s2 = Vector{Float64}(undef, n)
    v = Float64(v0)
    @inbounds for t in 1:n
        s2[t] = v
        v = om + (al + ga * (e[t] < 0.0 ? 1.0 : 0.0)) * (e[t] * e[t]) + be * v
        v < 1e-14 && (v = 1e-14)
    end
    return s2
end

# ── MS-GARCH-Filter (r/src/ms_garch.c) ──────────────────────────────────────
#
# Hamilton-Filter mit parallelen Varianzpfaden je Regime (Haas, Mittnik und
# Paolella 2004). Rechenfolge wie im C-Kern: Summen beginnen bei 0.0 und laufen
# über k (bzw. i) aufsteigend, jede Formel in der Klammerung des C-Codes (y^2 als
# y * y, 2 pi als 2.0 * M_PI), ohne fma; exp und log aus glibc-libm (RLibm).

"Argument als double-Vektor (wie `coerceVector`, Matrizen spaltenweise) mit Längenprüfung."
function _msg_num(x, len::Int, name::AbstractString)
    v = x isa SimLev.NamedMat ? vec(Matrix{Float64}(x.data)) :
        x isa Real ? [Float64(x)] :
        (x isa AbstractArray && (eltype(x) <: Real || all(e -> e isa Real, x))) ? Float64[Float64(e) for e in vec(x)] :
        _stop("ms_garch_filter: '$name' muss numerisch sein.")
    (len >= 0 && length(v) != len) && _stop("ms_garch_filter: '$name' muss die Länge $len haben (erhalten: $(length(v))).")
    return v
end

@inline _msg_sqrt(x::Float64) = x < 0.0 ? NaN : sqrt(x)

"""
`.ms_garch_filter`: Hamilton-Filter des MS-GARCH-Modells (r/src/ms_garch.c).

Liefert `RList(loglik, h, pred, filt, lB)` mit n × K-Matrizen (`pred` =
ξ_{t|t-1}, `filt` = ξ_{t|t}, `lB` = Log-Normaldichte je Regime); `loglik` ist
`-Inf`, sobald ein `f_t` nicht endlich oder ≤ 0 ist (die Rechnung läuft weiter).
"""
function ms_garch_filter(y, omega, alpha, beta, gamma, P, xi0, h1)
    yv = _msg_num(y, -1, "y")
    n = length(yv)
    n < 1 && _stop("ms_garch_filter: 'y' darf nicht leer sein.")
    om = _msg_num(omega, -1, "omega")
    K = length(om)
    (K < 1 || K > 1000) && _stop("ms_garch_filter: 'omega' muss 1 bis 1000 Werte haben (einen je Regime).")
    al = _msg_num(alpha, K, "alpha")
    be = _msg_num(beta, K, "beta")
    ga = _msg_num(gamma, K, "gamma")
    Pv = _msg_num(P, K * K, "P")
    xi = _msg_num(xi0, K, "xi0")
    h1v = _msg_num(h1, 1, "h1")[1]
    ex = SimLev.RLibm.exp; lg = SimLev.RLibm.log
    two_pi = 2.0 * Float64(pi)
    h = Matrix{Float64}(undef, n, K)
    pred = Matrix{Float64}(undef, n, K)
    filt = Matrix{Float64}(undef, n, K)
    lB = Matrix{Float64}(undef, n, K)
    ll = 0.0
    ok = true
    @inbounds for k in 1:K
        pred[1, k] = xi[k]
    end
    @inbounds for t in 1:n
        # Varianzpfade
        if t == 1
            for k in 1:K
                h[1, k] = h1v
            end
        else
            e = yv[t-1]
            e2 = e * e
            ind = e < 0.0 ? 1.0 : 0.0
            for k in 1:K
                a = al[k] + ga[k] * ind
                h[t, k] = (om[k] + a * e2) + be[k] * h[t-1, k]
            end
        end
        # Dichten, Mischungsdichte und Log-Emissionen
        y2 = yv[t] * yv[t]
        f = 0.0
        for k in 1:K
            hk = h[t, k]
            q = (-0.5 * y2) / hk
            phi = ex(q) / _msg_sqrt(two_pi * hk)
            lB[t, k] = q - 0.5 * lg(two_pi * hk)
            filt[t, k] = pred[t, k] * phi          # Zähler, unten geteilt
            f = f + filt[t, k]
        end
        if !isfinite(f) || f <= 0.0
            ok = false
        else
            ll = ll + lg(f)
        end
        for k in 1:K
            filt[t, k] = filt[t, k] / f
        end
        # Vorhersage für t + 1
        if t < n
            for j in 1:K
                s = 0.0
                for i in 1:K
                    s = s + Pv[i+K*(j-1)] * filt[t, i]
                end
                pred[t+1, j] = s
            end
        end
    end
    if any(isnan, h) || any(isnan, pred) || any(isnan, filt) || any(isnan, lB)
        # NaN im Ergebnis: Nutzlast und Vorzeichen wie im R-Bau (siehe _ms_garch_filter_nan)
        return _ms_garch_filter_nan(yv, om, al, be, ga, Pv, xi, h1v, n, K)
    end
    return SimLev.RList("loglik" => (ok ? ll : -Inf), "h" => h, "pred" => pred, "filt" => filt, "lB" => lB)
end

# ── NaN-genauer Weg (Etappe 7.3a) ───────────────────────────────────────────
#
# Treffen in einer Operation zwei NaN aufeinander (etwa NA in y auf einen schon
# ungültigen Filterzustand), behält x86-64/SSE die Nutzlast des ersten Operanden
# der Maschinenanweisung; welcher das ist, legt der Compiler fest (gcc im R-Bau,
# LLVM in Julia), bei kommutativen Operationen auch entgegen der Quelltextfolge.
# Ungültige Operationen (0/0, log oder sqrt einer negativen Zahl) liefern in C
# das Standard-NaN von x86 (Vorzeichen gesetzt, 0xFFF8000000000000), Julias NaN
# ist +NaN. Der schnelle Weg oben ist ohne NaN exakt; enthält ein Ergebnis NaN,
# rechnet _ms_garch_filter_nan den Filter noch einmal und wählt bei zwei
# NaN-Operanden den Operanden, den der R-Bau (gcc -O2, x86-64) behält
# (Operandenfolge aus dem Maschinencode von simlev_ms_garch_filter, je Zeile
# vermerkt; gleiche Regeln wie im Python-Port _bootstrap_core.py).

const _X86_NAN = reinterpret(Float64, 0xFFF8000000000000)
@inline _nquiet(x::Float64) = reinterpret(Float64, reinterpret(UInt64, x) | 0x0008000000000000)
"Ergebnis `r` mit bevorzugtem Operanden `a`: sind `a` und `b` NaN, gilt `a` (still)."
@inline _nn(r::Float64, a::Float64, b::Float64) = (isnan(a) && isnan(b)) ? _nquiet(a) : r
@inline _n_add(a::Float64, b::Float64) = _nn(a + b, a, b)
@inline _n_mul(a::Float64, b::Float64) = _nn(a * b, a, b)
@inline _n_sub(a::Float64, b::Float64) = _nn(a - b, a, b)
@inline _n_div(a::Float64, b::Float64) = _nn(a / b, a, b)
@inline _n_exp(x::Float64) = isnan(x) ? _nquiet(x) : SimLev.RLibm.c_exp(x)
@inline _n_log(x::Float64) = x > 0.0 ? SimLev.RLibm.c_log(x) : x == 0.0 ? -Inf : isnan(x) ? _nquiet(x) : _X86_NAN
@inline _n_sqrt(x::Float64) = x >= 0.0 ? sqrt(x) : isnan(x) ? _nquiet(x) : _X86_NAN

"`ms_garch_filter` Schritt für Schritt mit der NaN-Wahl des R-Baus (siehe oben)."
function _ms_garch_filter_nan(yv, om, al, be, ga, Pv, xi, h1v, n, K)
    two_pi = 2.0 * Float64(pi)
    h = Matrix{Float64}(undef, n, K)
    pred = Matrix{Float64}(undef, n, K)
    filt = Matrix{Float64}(undef, n, K)
    lB = Matrix{Float64}(undef, n, K)
    ll = 0.0
    ok = true
    @inbounds for k in 1:K
        pred[1, k] = xi[k]
    end
    @inbounds for t in 1:n
        if t == 1
            for k in 1:K
                h[1, k] = h1v
            end
        else
            e = yv[t-1]
            e2 = e * e
            ind = e < 0.0 ? 1.0 : 0.0
            for k in 1:K
                a = _n_add(ga[k] * ind, al[k])                          # alpha + gamma * ind: gamma * ind bleibt
                c = _n_add(_n_mul(a, e2), om[k])                        # omega + a * e2: a * e2 bleibt
                h[t, k] = _n_add(c, _n_mul(be[k], h[t-1, k]))          # ... + beta * h[t-1]: linker Teil, beta bleibt
            end
        end
        y2 = yv[t] * yv[t]
        f = 0.0
        for k in 1:K
            hk = h[t, k]
            q = _n_div(y2 * -0.5, hk)                                   # (-0.5 * y2) / hk: Zähler bleibt
            th = hk * two_pi
            phi = _n_div(_n_exp(q), _n_sqrt(th))                        # exp(q) / sqrt(2 pi hk): exp(q) bleibt
            lB[t, k] = _n_sub(q, 0.5 * _n_log(th))                      # q - 0.5 * log(2 pi hk): q bleibt
            filt[t, k] = _n_mul(phi, pred[t, k])                        # pred * phi: phi bleibt
            f = _n_add(filt[t, k], f)                                   # f + filt: filt bleibt
        end
        if !isfinite(f) || f <= 0.0
            ok = false
        else
            ll = ll + SimLev.RLibm.c_log(f)
        end
        for k in 1:K
            filt[t, k] = _n_div(filt[t, k], f)                          # filt / f: filt bleibt
        end
        if t < n
            for j in 1:K
                s = 0.0
                for i in 1:K
                    s = _n_add(s, _n_mul(Pv[i+K*(j-1)], filt[t, i]))  # s + P * filt: s bleibt, P bleibt
                end
                pred[t+1, j] = s
            end
        end
    end
    return SimLev.RList("loglik" => (ok ? ll : -Inf), "h" => h, "pred" => pred, "filt" => filt, "lB" => lB)
end

end # module

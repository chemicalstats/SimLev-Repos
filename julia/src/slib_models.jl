# SLib (Teil 9.4) – Hüllen der Modelle der C-Bibliothek slc über ccall: GARCH/GJR(1,1), GPD,
# DCC(1,1), MS-GARCH und univariates HMM, Bootstrap-Kerne.
#
# Gegenstück zu r/R/slc_models.R und python/simlev/_lib_models.py. Die Rechnung steht in
# deps/core/slc_{garch,gpd,dcc,msgarch,boot}.c (Kopien von core/), gebaut von deps/build.jl in
# libslc. Fehlertexte und Warnungen kommen aus dem Kern. Ergebnisse als RList (Reihenfolge wie R).
# Die Bootstrap-Kerne ziehen aus einem Stream bzw. dem globalen Zustand (Entwurf C.5, _draw).
#
# Seit Etappe 9.6a/b rufen die Ports diese Hüllen an denselben Stellen wie R. Eingebunden am Ende von
# slib.jl (Modul SLib); RList steht im übergeordneten Modul (_P aus slib_opt.jl).

const _GARCH_METHODS = ("konstant", "ml", "momente")
# SL_MSGARCH_MAXSTART in slc_models.h: 20 (N1; bis 1.0.0 12)

_fv(x) = Vector{Float64}(vec(collect(Float64, x)))
_iv(x) = Vector{Int32}(vec(collect(x)))
function _fm(x)
    m = x isa AbstractMatrix ? Matrix{Float64}(x) : reshape(_fv(x), :, 1)
    m
end

# ── GARCH(1,1) / GJR-GARCH(1,1) ─────────────────────────────────────────────

"Filter wie der frühere `.garch_filter`: s2[1] = s2_init, Untergrenze 1e-14."
function garch11_filter(eps, omega, alpha, beta, gamma, s2_init)
    e = _fv(eps); out = similar(e)
    cx = _ctx()
    st = ccall((:sl_garch11_filter, LIBSLC), Cint, (Ptr{Cvoid}, Cint, Ptr{Float64}, Float64, Float64, Float64, Float64, Float64, Ptr{Float64}),
               cx, Cint(length(e)), e, Float64(omega), Float64(alpha), Float64(beta), Float64(gamma), Float64(s2_init), out)
    _finish(cx, st)
    out
end

"NLL an par = (mu, omega, alpha, beta[, gamma]); s2_init `nothing`: Stichprobenvarianz."
function garch11_nll(e, par; gjr = false, s2_init = nothing)
    p = zeros(5); pv = _fv(par); p[1:min(5, length(pv))] = pv[1:min(5, length(pv))]
    ev = _fv(e); v = Ref{Float64}(0.0)
    cx = _ctx()
    st = ccall((:sl_garch11_nll, LIBSLC), Cint, (Ptr{Cvoid}, Cint, Ptr{Float64}, Cint, Ptr{Float64}, Float64, Ref{Float64}),
               cx, Cint(length(ev)), ev, Cint(gjr), p, s2_init === nothing ? NaN : Float64(s2_init), v)
    _finish(cx, st)
    v[]
end

"ML-Punktschätzer; RList(mu, omega, alpha, beta, gamma, loglik, convergence, method)."
function garch11_fit(e; gjr = false)
    ev = _fv(e); p = zeros(5); ll = Ref{Float64}(0.0); code = Ref{Cint}(0)
    cx = _ctx()
    st = ccall((:sl_garch11_fit, LIBSLC), Cint, (Ptr{Cvoid}, Cint, Ptr{Float64}, Cint, Ptr{Cvoid}, Ptr{Float64}, Ref{Float64}, Ref{Cint}),
               cx, Cint(length(ev)), ev, Cint(gjr), C_NULL, p, ll, code)
    _finish(cx, st)
    _P.RList("mu" => p[1], "omega" => p[2], "alpha" => p[3], "beta" => p[4], "gamma" => p[5],
             "loglik" => ll[], "convergence" => Int(code[]), "method" => "ml")
end

"GARCH(1,1) / GJR-GARCH(1,1) wie `_fit_garch11` (ML -> Momente, F10)."
function fit_garch11(e; gjr = false, quiet = false)
    ev = _fv(e); n = length(ev)
    p = zeros(5); s2 = Vector{Float64}(undef, n); z = Vector{Float64}(undef, n)
    ll = Ref{Float64}(0.0); code = Ref{Cint}(0); meth = Ref{Cint}(0); s2i = Ref{Float64}(0.0); pers = Ref{Float64}(0.0)
    cx = _ctx()
    st = ccall((:sl_garch11_estimate, LIBSLC), Cint,
               (Ptr{Cvoid}, Cint, Ptr{Float64}, Cint, Ptr{Float64}, Ref{Float64}, Ref{Cint}, Ref{Cint}, Ptr{Float64}, Ptr{Float64},
                Ref{Float64}, Ref{Float64}), cx, Cint(n), ev, Cint(gjr), p, ll, code, meth, s2, z, s2i, pers)
    _finish(cx, st)
    method = _GARCH_METHODS[meth[] + 1]
    if method == "konstant"
        return _P.RList("mu" => p[1], "omega" => p[2], "alpha" => 0.0, "beta" => 0.0, "gamma" => 0.0, "s2" => s2, "z" => z,
                        "method" => "konstant", "s2_init" => s2i[])
    end
    method == "momente" && !quiet && @warn "GARCH: ML-Schätzung fehlgeschlagen, verwende Moment-Schätzer"
    _P.RList("mu" => p[1], "omega" => p[2], "alpha" => p[3], "beta" => p[4], "gamma" => p[5], "s2" => s2, "z" => z,
             "method" => method, "persistence" => pers[], "s2_init" => s2i[])
end

# ── Verallgemeinerte Pareto-Verteilung ──────────────────────────────────────

function gpd_nll(x, scale, shape)
    v = _fv(x); r = Ref{Float64}(0.0)
    cx = _ctx()
    st = ccall((:sl_gpd_nll, LIBSLC), Cint, (Ptr{Cvoid}, Cint, Ptr{Float64}, Float64, Float64, Ref{Float64}),
               cx, Cint(length(v)), v, Float64(scale), Float64(shape), r)
    _finish(cx, st)
    r[]
end

function gpd_pwm(x)
    v = _fv(x); a = Ref{Float64}(0.0); b = Ref{Float64}(0.0)
    cx = _ctx()
    st = ccall((:sl_gpd_pwm, LIBSLC), Cint, (Ptr{Cvoid}, Cint, Ptr{Float64}, Ref{Float64}, Ref{Float64}), cx, Cint(length(v)), v, a, b)
    _finish(cx, st)
    _P.RList("scale" => a[], "shape" => b[])
end

"ML der Überschreitungen (>= 0); RList(scale, shape, loglik, convergence)."
function gpd_fit(x)
    v = _fv(x); a = Ref{Float64}(0.0); b = Ref{Float64}(0.0); ll = Ref{Float64}(0.0); code = Ref{Cint}(0)
    cx = _ctx()
    st = ccall((:sl_gpd_fit, LIBSLC), Cint, (Ptr{Cvoid}, Cint, Ptr{Float64}, Ptr{Cvoid}, Ref{Float64}, Ref{Float64}, Ref{Float64}, Ref{Cint}),
               cx, Cint(length(v)), v, C_NULL, a, b, ll, code)
    _finish(cx, st)
    _P.RList("scale" => a[], "shape" => b[], "loglik" => ll[], "convergence" => Int(code[]))
end

# ── DCC(1,1) ────────────────────────────────────────────────────────────────

"wie `dcc_filter`: RList(nll, R, ok)."
function dcc_filter(Z, a, b, Qbar, keep)
    z = _fm(Z); q = _fm(Qbar); n, k = size(z)
    size(q) == (k, k) || error("interner Fehler: Qbar muss k x k sein")
    np = k * (k - 1) ÷ 2
    R = keep ? Matrix{Float64}(undef, n, np) : Matrix{Float64}(undef, 0, 0)
    nll = Ref{Float64}(0.0); ok = Ref{Cint}(0)
    cx = _ctx()
    st = ccall((:sl_dcc_filter, LIBSLC), Cint,
               (Ptr{Cvoid}, Cint, Cint, Ptr{Float64}, Float64, Float64, Ptr{Float64}, Cint, Ref{Float64}, Ptr{Float64}, Ref{Cint}),
               cx, Cint(n), Cint(k), z, Float64(a), Float64(b), q, Cint(keep), nll, keep ? pointer(R) : Ptr{Float64}(C_NULL), ok)
    _finish(cx, st)
    _P.RList("nll" => nll[], "R" => R, "ok" => ok[] != 0)
end

"Schätzung von (a, b) ganz in C; RList(a, b, nll, convergence, par)."
function dcc_fit(Z, Qbar)
    z = _fm(Z); q = _fm(Qbar); n, k = size(z)
    size(q) == (k, k) || error("interner Fehler: Qbar muss k x k sein")
    a = Ref{Float64}(0.0); b = Ref{Float64}(0.0); nll = Ref{Float64}(0.0); code = Ref{Cint}(0); th = zeros(2)
    cx = _ctx()
    st = ccall((:sl_dcc_fit, LIBSLC), Cint,
               (Ptr{Cvoid}, Cint, Cint, Ptr{Float64}, Ptr{Float64}, Ptr{Cvoid}, Ref{Float64}, Ref{Float64}, Ref{Float64}, Ref{Cint}, Ptr{Float64}),
               cx, Cint(n), Cint(k), z, q, C_NULL, a, b, nll, code, th)
    _finish(cx, st)
    _P.RList("a" => a[], "b" => b[], "nll" => nll[], "convergence" => Int(code[]), "par" => th)
end

# ── MS-GARCH und HMM ────────────────────────────────────────────────────────

function _gjr(model)
    model in ("sGARCH", "gjrGARCH") || error("interner Fehler: model muss \"sGARCH\" oder \"gjrGARCH\" sein")
    model == "gjrGARCH"
end
_h1(h1) = h1 === nothing ? NaN : Float64(h1)
_npar(K, gjr) = Int(ccall((:sl_msgarch_npar, LIBSLC), Cint, (Cint, Cint), Cint(K), Cint(gjr)))

"wie `ms_garch_filter`: RList(loglik, h, pred, filt, lB)."
function ms_garch_filter(y, omega, alpha, beta, gamma, P, xi0, h1)
    yv = _fv(y); om = _fv(omega); K = length(om); n = length(yv)
    1 <= K <= 1000 || error("ms_garch_filter: 'omega' muss 1 bis 1000 Werte haben (einen je Regime).")
    al = _fv(alpha); be = _fv(beta); ga = _fv(gamma); Pm = _fv(P); xi = _fv(xi0)
    (length(al) == K && length(be) == K && length(ga) == K && length(Pm) == K * K && length(xi) == K) ||
        error("interner Fehler: Längen der Regimeparameter")
    h = Matrix{Float64}(undef, n, K); pr = similar(h); fl = similar(h); lb = similar(h); ll = Ref{Float64}(0.0)
    cx = _ctx()
    st = ccall((:sl_msgarch_filter, LIBSLC), Cint,
               (Ptr{Cvoid}, Cint, Ptr{Float64}, Cint, Ptr{Float64}, Ptr{Float64}, Ptr{Float64}, Ptr{Float64}, Ptr{Float64}, Ptr{Float64},
                Float64, Ptr{Float64}, Ptr{Float64}, Ptr{Float64}, Ptr{Float64}, Ref{Float64}),
               cx, Cint(n), yv, Cint(K), om, al, be, ga, Pm, xi, Float64(h1), h, pr, fl, lb, ll)
    _finish(cx, st)
    _P.RList("loglik" => ll[], "h" => h, "pred" => pr, "filt" => fl, "lB" => lb)
end

function ms_garch_nll(theta, y, K, model; h1 = nothing)
    g = _gjr(model); yv = _fv(y); th = _fv(theta); v = Ref{Float64}(0.0)
    1 <= K <= 1000 || error("interner Fehler: K")
    length(th) == _npar(K, g) || error("interner Fehler: theta hat die falsche Länge")
    cx = _ctx()
    st = ccall((:sl_msgarch_nll, LIBSLC), Cint, (Ptr{Cvoid}, Cint, Ptr{Float64}, Cint, Cint, Ptr{Float64}, Float64, Ref{Float64}),
               cx, Cint(length(yv)), yv, Cint(K), Cint(g), th, _h1(h1), v)
    _finish(cx, st)
    v[]
end

"N1: NLL und analytischer Gradient an `theta` (vorwärts mitdifferenzierter Hamilton-Filter); RList(value, gradient)."
function ms_garch_grad(theta, y, K, model; h1 = nothing)
    g = _gjr(model); yv = _fv(y); th = _fv(theta); v = Ref{Float64}(0.0)
    1 <= K <= 64 || error("interner Fehler: K")
    length(th) == _npar(K, g) || error("interner Fehler: theta hat die falsche Länge")
    gr = Vector{Float64}(undef, _npar(K, g))
    cx = _ctx()
    st = ccall((:sl_msgarch_grad, LIBSLC), Cint, (Ptr{Cvoid}, Cint, Ptr{Float64}, Cint, Cint, Ptr{Float64}, Float64, Ref{Float64}, Ptr{Float64}),
               cx, Cint(length(yv)), yv, Cint(K), Cint(g), th, _h1(h1), v, gr)
    _finish(cx, st)
    _P.RList("value" => v[], "gradient" => gr)
end

"Startpunkte wie `_ms_garch_fit` (Spalten: HMM-Start, falls gelungen, dann Rang-Start); `all`: danach die übrigen Rasterpunkte."
function ms_garch_starts(y, K, model; h1 = nothing, all = false)
    g = _gjr(model); yv = _fv(y)
    2 <= K <= 64 || error("MS-GARCH: Anzahl Regime muss zwischen 2 und 64 liegen (erhalten: $(K))")
    np = _npar(K, g); out = Vector{Float64}(undef, 20 * np); ns = Ref{Cint}(0)   # N1: SL_MSGARCH_MAXSTART 20
    cx = _ctx()
    st = ccall((:sl_msgarch_starts, LIBSLC), Cint, (Ptr{Cvoid}, Cint, Ptr{Float64}, Cint, Cint, Float64, Cint, Ref{Cint}, Ptr{Float64}),
               cx, Cint(length(yv)), yv, Cint(K), Cint(g), _h1(h1), Cint(all), ns, out)
    _finish(cx, st)
    reshape(out[1:np * ns[]], np, Int(ns[]))
end

function ms_garch_fitstarts(y, K, model, starts; h1 = nothing)
    g = _gjr(model); yv = _fv(y); s = _fm(starts); np = _npar(K, g)
    size(s, 1) == np || error("interner Fehler: starts muss $(np) Zeilen haben")
    th = Vector{Float64}(undef, np); v = Ref{Float64}(0.0); code = Ref{Cint}(0)
    cx = _ctx()
    st = ccall((:sl_msgarch_fit, LIBSLC), Cint,
               (Ptr{Cvoid}, Cint, Ptr{Float64}, Cint, Cint, Cint, Ptr{Float64}, Float64, Ptr{Cvoid}, Ptr{Float64}, Ref{Float64}, Ref{Cint}),
               cx, Cint(length(yv)), yv, Cint(K), Cint(g), Cint(size(s, 2)), s, _h1(h1), C_NULL, th, v, code)
    _finish(cx, st)
    _P.RList("par" => th, "value" => v[], "convergence" => Int(code[]))
end

"MS-GARCH-Modell wie `_ms_garch_fit`, ganz in C (Starts, BFGS, Sortierung, Viterbi)."
function ms_garch_fit(y, K, model)
    _P.MsGarch._ms_garch_check(K, model)
    K = Int(K); yv = _fv(y); n = length(yv)
    om = Vector{Float64}(undef, K); al = similar(om); be = similar(om); ga = similar(om)
    P = Matrix{Float64}(undef, K, K); reg = Vector{Int32}(undef, n); s2 = Vector{Float64}(undef, n)
    ll = Ref{Float64}(0.0); code = Ref{Cint}(0)
    cx = _ctx()
    st = ccall((:sl_msgarch_estimate, LIBSLC), Cint,
               (Ptr{Cvoid}, Cint, Ptr{Float64}, Cint, Cint, Ptr{Float64}, Ptr{Float64}, Ptr{Float64}, Ptr{Float64}, Ptr{Float64},
                Ptr{Int32}, Ptr{Float64}, Ref{Float64}, Ref{Cint}),
               cx, Cint(n), yv, Cint(K), Cint(model == "gjrGARCH"), om, al, be, ga, P, reg, s2, ll, code)
    _finish(cx, st)
    _P.RList("omega" => om, "alpha" => al, "beta" => be, "gamma" => ga, "P" => P, "regimes" => reg, "s2" => s2,
             "loglik" => ll[], "convergence" => Int(code[]))
end

function hmm_em_univ(x, K; win = 21, max_iter = 300, tol = 1e-7)
    2 <= K <= 64 || error("HMM: Anzahl Zustände muss zwischen 2 und 64 liegen (erhalten: $(K))")
    xv = _fv(x); mu = Vector{Float64}(undef, K); S = similar(mu); A = Matrix{Float64}(undef, K, K)
    ll = Ref{Float64}(0.0); it = Ref{Cint}(0)
    cx = _ctx()
    st = ccall((:sl_hmm_em_univ, LIBSLC), Cint,
               (Ptr{Cvoid}, Cint, Ptr{Float64}, Cint, Cint, Cint, Float64, Ptr{Float64}, Ptr{Float64}, Ptr{Float64}, Ref{Float64}, Ref{Cint}),
               cx, Cint(length(xv)), xv, Cint(K), Cint(win), Cint(max_iter), Float64(tol), mu, S, A, ll, it)
    _finish(cx, st)
    _P.RList("mu" => mu, "S" => S, "A" => A, "ll" => ll[], "iter" => Int(it[]))
end

function hmm_viterbi(lB, lA, lp0)
    b = _fm(lB); a = _fm(lA); n, K = size(b); p = _fv(lp0)
    size(a) == (K, K) || error("interner Fehler: lA muss K x K sein")
    out = Vector{Int32}(undef, n)
    cx = _ctx()
    st = ccall((:sl_hmm_viterbi, LIBSLC), Cint, (Ptr{Cvoid}, Cint, Cint, Ptr{Float64}, Ptr{Float64}, Ptr{Float64}, Ptr{Int32}),
               cx, Cint(n), Cint(K), b, a, p, out)
    _finish(cx, st)
    out
end

# ── Bootstrap-Kerne (Zufall aus stream bzw. dem globalen Zustand) ───────────

function _nout(v)
    v < 0 && error("n_out muss >= 0 sein")
    Int(v)
end

function boot_idx_iid(n_src, n_out; stream = nothing)
    out = Vector{Int32}(undef, _nout(n_out))
    _draw(stream) do st
        cx = _ctx()
        s = ccall((:sl_boot_idx_iid, LIBSLC), Cint, (Ptr{Cvoid}, Ref{Stream}, Cint, Cint, Ptr{Int32}), cx, st, Cint(n_src), Cint(length(out)), out)
        _finish(cx, s); out
    end
end

function boot_idx_block(n_src, n_out, block_length, circular; stream = nothing)
    out = Vector{Int32}(undef, _nout(n_out))
    _draw(stream) do st
        cx = _ctx()
        s = ccall((:sl_boot_idx_block, LIBSLC), Cint, (Ptr{Cvoid}, Ref{Stream}, Cint, Cint, Cint, Cint, Ptr{Int32}),
                  cx, st, Cint(n_src), Cint(length(out)), Cint(block_length), Cint(circular), out)
        _finish(cx, s); out
    end
end

function boot_idx_stationary(n_src, n_out, L; stream = nothing)
    out = Vector{Int32}(undef, _nout(n_out))
    _draw(stream) do st
        cx = _ctx()
        s = ccall((:sl_boot_idx_stationary, LIBSLC), Cint, (Ptr{Cvoid}, Ref{Stream}, Cint, Cint, Float64, Ptr{Int32}),
                  cx, st, Cint(n_src), Cint(length(out)), Float64(L), out)
        _finish(cx, s); out
    end
end

function boot_idx_regime(regimes, trans, n_out; stream = nothing)
    rg = _iv(regimes); tr = _fm(trans); K = size(tr, 1)
    size(tr, 2) == K || error("interner Fehler: trans muss quadratisch sein")
    out = Vector{Int32}(undef, _nout(n_out))
    _draw(stream) do st
        cx = _ctx()
        s = ccall((:sl_boot_idx_regime, LIBSLC), Cint, (Ptr{Cvoid}, Ref{Stream}, Cint, Ptr{Int32}, Cint, Ptr{Float64}, Cint, Ptr{Int32}),
                  cx, st, Cint(length(rg)), rg, Cint(K), tr, Cint(length(out)), out)
        _finish(cx, s); out
    end
end

function boot_idx_tails(n_out, p_l, p_r, bulk_idx, left_idx, right_idx; stream = nothing)
    b = _iv(bulk_idx); l = _iv(left_idx); r = _iv(right_idx)
    out = Vector{Int32}(undef, _nout(n_out))
    _draw(stream) do st
        cx = _ctx()
        s = ccall((:sl_boot_idx_tails, LIBSLC), Cint,
                  (Ptr{Cvoid}, Ref{Stream}, Cint, Float64, Float64, Cint, Ptr{Int32}, Cint, Ptr{Int32}, Cint, Ptr{Int32}, Ptr{Int32}),
                  cx, st, Cint(length(out)), Float64(p_l), Float64(p_r), Cint(length(b)), b, Cint(length(l)), l, Cint(length(r)), r, out)
        _finish(cx, s); out
    end
end

function boot_wild(returns, type; stream = nothing)
    x = _fm(returns); n, k = size(x); out = similar(x)
    _draw(stream) do st
        cx = _ctx()
        s = ccall((:sl_boot_wild, LIBSLC), Cint, (Ptr{Cvoid}, Ref{Stream}, Cint, Cint, Ptr{Float64}, Cint, Ptr{Float64}),
                  cx, st, Cint(n), Cint(k), x, Cint(type), out)
        _finish(cx, s); out
    end
end

function boot_reset(returns, p_break; stream = nothing)
    x = _fm(returns); n, k = size(x); out = similar(x)
    _draw(stream) do st
        cx = _ctx()
        s = ccall((:sl_boot_reset, LIBSLC), Cint, (Ptr{Cvoid}, Ref{Stream}, Cint, Cint, Ptr{Float64}, Float64, Ptr{Float64}),
                  cx, st, Cint(n), Cint(k), x, Float64(p_break), out)
        _finish(cx, s); out
    end
end

function boot_evt(returns, base, n_out, p_l, thresh_l, scale_l, shape_l, pool_l,
                  p_r, thresh_r, scale_r, shape_r, pool_r, bulk_idx; stream = nothing)
    x = _fm(returns); n, k = size(x); no = _nout(n_out)
    pl = _iv(pool_l); pr = _iv(pool_r); bk = _iv(bulk_idx)
    out = Matrix{Float64}(undef, no, k); idx = Vector{Int32}(undef, no)
    _draw(stream) do st
        cx = _ctx()
        s = ccall((:sl_boot_evt, LIBSLC), Cint,
                  (Ptr{Cvoid}, Ref{Stream}, Cint, Cint, Ptr{Float64}, Cint, Cint, Float64, Float64, Float64, Float64, Cint, Ptr{Int32},
                   Float64, Float64, Float64, Float64, Cint, Ptr{Int32}, Cint, Ptr{Int32}, Ptr{Float64}, Ptr{Int32}),
                  cx, st, Cint(n), Cint(k), x, Cint(base), Cint(no), Float64(p_l), Float64(thresh_l), Float64(scale_l), Float64(shape_l),
                  Cint(length(pl)), pl, Float64(p_r), Float64(thresh_r), Float64(scale_r), Float64(shape_r), Cint(length(pr)), pr,
                  Cint(length(bk)), bk, out, idx)
        _finish(cx, s)
        _P.RList("ret" => out, "idx" => idx)
    end
end

function _cross(cross_cols, cmu, com, cal, cbe, cratio, cs2, z_cross)
    cols = _iv(cross_cols)
    z = isempty(cols) ? zeros(0) : _fv(_fm(z_cross))
    (cols, _fv(cmu), _fv(com), _fv(cal), _fv(cbe), Vector{Int32}([Bool(v) ? 1 : 0 for v in cratio]), _fv(cs2), z)
end

function boot_garch(n_out, base, k, mu, omega, alpha, beta, gamma, s2_init, z_base, valid,
                    cross_cols, cmu, com, cal, cbe, cratio, cs2, z_cross; stream = nothing)
    no = _nout(n_out); zb = _fv(z_base); vl = _iv(valid)
    c = _cross(cross_cols, cmu, com, cal, cbe, cratio, cs2, z_cross)
    m = length(c[1])
    all(length(c[i]) == m for i in 2:7) && length(c[8]) == m * length(zb) || error("interner Fehler: Längen der Kopplung")
    out = Matrix{Float64}(undef, no, Int(k)); idx = Vector{Int32}(undef, no)
    _draw(stream) do st
        cx = _ctx()
        s = ccall((:sl_boot_garch, LIBSLC), Cint,
                  (Ptr{Cvoid}, Ref{Stream}, Cint, Cint, Cint, Float64, Float64, Float64, Float64, Float64, Float64, Cint, Ptr{Float64},
                   Cint, Ptr{Int32}, Cint, Ptr{Int32}, Ptr{Float64}, Ptr{Float64}, Ptr{Float64}, Ptr{Float64}, Ptr{Int32}, Ptr{Float64},
                   Ptr{Float64}, Ptr{Float64}, Ptr{Int32}),
                  cx, st, Cint(no), Cint(base), Cint(k), Float64(mu), Float64(omega), Float64(alpha), Float64(beta), Float64(gamma),
                  Float64(s2_init), Cint(length(zb)), zb, Cint(length(vl)), vl, Cint(m), c[1], c[2], c[3], c[4], c[5], c[6], c[7], c[8],
                  out, idx)
        _finish(cx, s)
        _P.RList("ret" => out, "idx" => idx)
    end
end

function boot_ms_garch(n_out, base, k, K, mu, omega, alpha, beta, gamma, phi, lambda,
                       trans, delta, unc_var, stat_prob, pools, z_base, cross_cols,
                       cmu, com, cal, cbe, cratio, cs2, z_cross; stream = nothing)
    no = _nout(n_out); K = Int(K); zb = _fv(z_base)
    pl = [_iv(p) for p in pools]
    length(pl) == K || error("interner Fehler: pools muss K Einträge haben")
    off = Int32[0; cumsum(Int32[length(p) for p in pl])]
    pidx = isempty(pl) ? Int32[] : reduce(vcat, pl; init = Int32[])
    v = [_fv(mu), _fv(omega), _fv(alpha), _fv(beta), _fv(gamma), _fv(phi), _fv(lambda), _fv(_fm(trans)), _fv(_fm(delta)),
         _fv(unc_var), _fv(stat_prob)]
    all(length(v[i]) == ((i == 8 || i == 9) ? K * K : K) for i in 1:11) || error("interner Fehler: Längen der Regimeparameter")
    c = _cross(cross_cols, cmu, com, cal, cbe, cratio, cs2, z_cross)
    m = length(c[1])
    all(length(c[i]) == m for i in 2:7) && length(c[8]) == m * length(zb) || error("interner Fehler: Längen der Kopplung")
    out = Matrix{Float64}(undef, no, Int(k)); idx = Vector{Int32}(undef, no); reg = Vector{Int32}(undef, no)
    _draw(stream) do st
        cx = _ctx()
        s = ccall((:sl_boot_ms_garch, LIBSLC), Cint,
                  (Ptr{Cvoid}, Ref{Stream}, Cint, Cint, Cint, Cint, Ptr{Float64}, Ptr{Float64}, Ptr{Float64}, Ptr{Float64}, Ptr{Float64},
                   Ptr{Float64}, Ptr{Float64}, Ptr{Float64}, Ptr{Float64}, Ptr{Float64}, Ptr{Float64}, Ptr{Int32}, Ptr{Int32}, Cint,
                   Ptr{Float64}, Cint, Ptr{Int32}, Ptr{Float64}, Ptr{Float64}, Ptr{Float64}, Ptr{Float64}, Ptr{Int32}, Ptr{Float64},
                   Ptr{Float64}, Ptr{Float64}, Ptr{Int32}, Ptr{Int32}),
                  cx, st, Cint(no), Cint(base), Cint(k), Cint(K), v[1], v[2], v[3], v[4], v[5], v[6], v[7], v[8], v[9], v[10], v[11],
                  off, pidx, Cint(length(zb)), zb, Cint(m), c[1], c[2], c[3], c[4], c[5], c[6], c[7], c[8], out, idx, reg)
        _finish(cx, s)
        _P.RList("ret" => out, "idx" => idx, "regime" => reg)
    end
end

# ── ohne Zufall ─────────────────────────────────────────────────────────────

function rolling_vol(x, window)
    v = _fv(x); out = similar(v)
    cx = _ctx()
    st = ccall((:sl_rolling_vol, LIBSLC), Cint, (Ptr{Cvoid}, Cint, Ptr{Float64}, Cint, Ptr{Float64}), cx, Cint(length(v)), v, Cint(window), out)
    _finish(cx, st)
    out
end

function assign_regimes(vol, thresh)
    v = _fv(vol); t = _fv(thresh); out = Vector{Int32}(undef, length(v))
    cx = _ctx()
    st = ccall((:sl_assign_regimes, LIBSLC), Cint, (Ptr{Cvoid}, Cint, Ptr{Float64}, Cint, Ptr{Float64}, Ptr{Int32}),
               cx, Cint(length(v)), v, Cint(length(t)), t, out)
    _finish(cx, st)
    out
end

function estimate_trans_mat(regimes, K, alpha = 0.1)
    K >= 1 || error("K muss >= 1 sein")
    rg = _iv(regimes); out = Matrix{Float64}(undef, K, K)
    cx = _ctx()
    st = ccall((:sl_estimate_trans_mat, LIBSLC), Cint, (Ptr{Cvoid}, Cint, Ptr{Int32}, Cint, Float64, Ptr{Float64}),
               cx, Cint(length(rg)), rg, Cint(K), Float64(alpha), out)
    _finish(cx, st)
    out
end

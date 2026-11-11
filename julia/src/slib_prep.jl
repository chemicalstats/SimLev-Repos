# julia/src/slib_prep.jl – Kerne für Wirtsfunktionen (seit 1.6.0; core/slc_prep.h) und Brent fmin (core/slc_opt_fmin.cpp)
#
# Teil des Moduls SLib (eingebunden in slib.jl): Kalenderauffüllung (cal_index, cal_fill_real; sim_phases.jl),
# Momentum-Scores (mom_score; tactical.jl), Pfadaufbau im Bootstrap (boot_path; bootstrap.jl), t-Copula (tcop_fit,
# tcop_nu; dependence.jl, scenarios.jl) und Brent fmin als Frage/Antwort (fmin_init!, fmin_ask!, fmin_tell!;
# r/stats_optim.jl). Gegenstücke: r/src/prep_r.cpp, python/src/_ext_slc_prep.cpp. Die Aufrufer prüfen die Eingaben
# und bauen die Ergebnisobjekte.

"Zeile (0-basiert, -1 = keine) je Kalendertag d0, d0 + 1, …, d0 + nd - 1 (`sl_cal_index`)."
function cal_index(day::Vector{Float64}, d0::Float64, nd::Int)
    src = Vector{Int64}(undef, nd)
    cx = _ctx()
    s = ccall((:sl_cal_index, LIBSLC), Cint, (Ptr{Cvoid}, Int64, Ptr{Float64}, Float64, Int64, Ptr{Int64}),
              cx, length(day), day, d0, nd, src)
    _finish(cx, s)
    return src
end

"Spalte auf das Raster (`sl_cal_fill_real`; fehlend NA, mit `locf` danach LOCF wie R's `.locf_fill`)."
function cal_fill_real(src::Vector{Int64}, x::Vector{Float64}, locf::Bool)
    all(<(length(x)), src) || error("interner Fehler: cal_fill Index")
    out = Vector{Float64}(undef, length(src))
    ccall((:sl_cal_fill_real, LIBSLC), Cvoid, (Int64, Ptr{Int64}, Ptr{Float64}, Cint, Ptr{Float64}),
          length(src), src, x, Cint(locf), out)
    return out
end

"Momentum-Scores (`sl_mom_back`, `sl_mom_score`): d sortiert, lb ganze Monate, X Zeilen × Anlagen."
function mom_score(d::Vector{Float64}, lb::Vector{Cint}, X::Matrix{Float64}, w13612::Bool)
    n = length(d)
    size(X, 1) == n || error("interner Fehler: mom_score Längen")
    back = Vector{Int64}(undef, max(n, 1) * max(length(lb), 1))
    S = Matrix{Float64}(undef, n, size(X, 2))
    cx = _ctx()
    s = ccall((:sl_mom_back, LIBSLC), Cint, (Ptr{Cvoid}, Int64, Ptr{Float64}, Cint, Ptr{Cint}, Ptr{Int64}),
              cx, n, d, Cint(length(lb)), lb, back)
    s == 0 && (s = ccall((:sl_mom_score, LIBSLC), Cint,
                         (Ptr{Cvoid}, Int64, Int64, Ptr{Float64}, Cint, Ptr{Int64}, Cint, Ptr{Float64}),
                         cx, n, size(X, 2), X, Cint(length(lb)), back, Cint(w13612), S))
    _finish(cx, s)
    return S
end

"Hebelprodukt für `sl_boot_path` (Aufbau wie `sl_letf` in core/slc_prep.h)."
struct Letf
    base::Cint
    L::Float64
    rate_col::Cint
    rate::Float64
    days_col::Cint
    days::Float64
    rate_basis::Float64
    ter_basis::Float64
    expense::Float64
    spread::Float64
end

# seit 1.6.4 (C-018): Längen der Hilfsreihen wie die Python-Hülle (bis 1.6.3 las der Kern bei zu kurzen Feldern dahinter)
function _bp_check(aux, aux_ratio, aux_start, level, na)
    na == 0 && return nothing
    ok = (aux_ratio === nothing || size(aux_ratio) == size(aux)) && (aux_start === nothing || length(aux_start) == na) &&
         length(level) == na
    ok || error("interner Fehler: boot_path Laengen")
    nothing
end

"""Bootstrap-Pfad (`sl_boot_path`): ret n_out × k, idx 1-basiert, aux/aux_ratio n_aux × na oder `nothing`;
Ergebnis `(P, lv)` (lv `nothing` ohne aux_ratio) oder `nothing` (ungültiger Pfad)."""
function boot_path(ret::Matrix{Float64}, idx::Vector{Int64}, aux, aux_ratio, aux_start, level::Vector{Cint},
                   letf::Vector{Letf}, start::Float64)
    n_out, k = size(ret)
    na = aux === nothing ? 0 : size(aux, 2)
    n_aux = aux === nothing ? 0 : size(aux, 1)
    nL = length(letf)
    length(idx) == n_out || error("interner Fehler: boot_path Laengen")   # seit 1.6.4 (C-018, wie Python)
    _bp_check(aux, aux_ratio, aux_start, level, na)
    P = Matrix{Float64}(undef, n_out + 1, k + nL + na)
    lv = aux_ratio === nothing || na == 0 ? nothing : Matrix{Float64}(undef, n_out + 1, na)
    cx = _ctx()
    s = ccall((:sl_boot_path, LIBSLC), Cint,
              (Ptr{Cvoid}, Int64, Cint, Ptr{Float64}, Ptr{Int64}, Int64, Cint, Ptr{Float64}, Ptr{Float64}, Ptr{Float64},
               Ptr{Cint}, Cint, Ptr{Letf}, Float64, Ptr{Float64}, Ptr{Float64}),
              cx, n_out, Cint(k), ret, idx, n_aux, Cint(na), aux === nothing ? C_NULL : aux,
              lv === nothing ? C_NULL : aux_ratio, aux_start === nothing || na == 0 ? C_NULL : aux_start,
              na == 0 ? C_NULL : level, Cint(nL), nL == 0 ? C_NULL : letf, start, P, lv === nothing ? C_NULL : lv)
    _finish(cx, s < 0 ? -s : Cint(0))
    return s == 1 ? (P, lv) : nothing
end

"""Bootstrap-Pfad aus Zeilen der Quelle (`sl_boot_path_src`, seit 1.6.3): wie `boot_path(src[idx, :], idx, …)`,
ohne die Zeilenkopie; `src` n_src × k spaltenweise, `idx` 1-basiert (1 … n_src)."""
function boot_path_src(src::Matrix{Float64}, idx::Vector{Int64}, aux, aux_ratio, aux_start, level::Vector{Cint},
                       letf::Vector{Letf}, start::Float64)
    n_src, k = size(src); n_out = length(idx)
    na = aux === nothing ? 0 : size(aux, 2)
    n_aux = aux === nothing ? 0 : size(aux, 1)
    nL = length(letf)
    _bp_check(aux, aux_ratio, aux_start, level, na)   # seit 1.6.4 (C-018, wie Python)
    P = Matrix{Float64}(undef, n_out + 1, k + nL + na)
    lv = aux_ratio === nothing || na == 0 ? nothing : Matrix{Float64}(undef, n_out + 1, na)
    cx = _ctx()
    s = ccall((:sl_boot_path_src, LIBSLC), Cint,
              (Ptr{Cvoid}, Int64, Cint, Ptr{Float64}, Int64, Int64, Int64, Ptr{Int64}, Int64, Cint, Ptr{Float64},
               Ptr{Float64}, Ptr{Float64}, Ptr{Cint}, Cint, Ptr{Letf}, Float64, Ptr{Float64}, Ptr{Float64}),
              cx, n_out, Cint(k), src, n_src, 1, n_src, idx, n_aux, Cint(na), aux === nothing ? C_NULL : aux,
              lv === nothing ? C_NULL : aux_ratio, aux_start === nothing || na == 0 ? C_NULL : aux_start,
              na == 0 ? C_NULL : level, Cint(nL), nL == 0 ? C_NULL : letf, start, P, lv === nothing ? C_NULL : lv)
    _finish(cx, s < 0 ? -s : Cint(0))
    return s == 1 ? (P, lv) : nothing
end

"t-Copula per Profil-Likelihood (`sl_tcop_fit`): `[atanh rho, nu, -loglik]` oder `nothing` (dann wie bisher)."
function tcop_fit(u::Vector{Float64}, v::Vector{Float64})
    length(u) == length(v) && !isempty(u) || return nothing
    best = Vector{Float64}(undef, 3); flag = Ref{Cint}(0)
    cx = _ctx_intr()   # seit 1.6.5: Strg-C schon während der Schätzung (Entscheidung 188)
    s = ccall((:sl_tcop_fit, LIBSLC), Cint, (Ptr{Cvoid}, Int64, Ptr{Float64}, Ptr{Float64}, Cint, Ptr{Float64}, Ptr{Cint}),
              cx, length(u), u, v, Cint(nthreads()), best, flag)
    ccall((:sl_ctx_free, LIBSLC), Cvoid, (Ptr{Cvoid},), cx)
    _throw_intr(s)
    return s == 0 && flag[] == 0 ? best : nothing
end

"nu der t-Copula von scenario_copula (`sl_tcop_nu`) oder `nothing` (dann wie bisher)."
function tcop_nu(U::Matrix{Float64}, Ri::Matrix{Float64}, ldR::Float64, lower::Float64, upper::Float64, tol::Float64)
    k = size(U, 2)
    size(Ri) == (k, k) && k >= 1 || return nothing
    nu = Ref{Float64}(0.0); flag = Ref{Cint}(0)
    cx = _ctx_intr()   # seit 1.6.5: Strg-C schon während der Schätzung (Entscheidung 188)
    s = ccall((:sl_tcop_nu, LIBSLC), Cint,
              (Ptr{Cvoid}, Int64, Cint, Ptr{Float64}, Ptr{Float64}, Float64, Float64, Float64, Float64, Cint, Ptr{Float64}, Ptr{Cint}),
              cx, size(U, 1), Cint(k), U, Ri, ldR, lower, upper, tol, Cint(nthreads()), nu, flag)
    ccall((:sl_ctx_free, LIBSLC), Cvoid, (Ptr{Cvoid},), cx)
    _throw_intr(s)
    return s == 0 && flag[] == 0 ? nu[] : nothing
end

# Brent fmin als Frage/Antwort (Arbeitsfeld mit SL_FMIN_WS = 24 Werten; seit 1.6.4 geprüft, C-018)
_fmin_ws(ws) = length(ws) >= 24 || error("interner Fehler: Arbeitsfeld von fmin muss mindestens 24 Werte haben")
fmin_init!(ws::Vector{Float64}, ax::Float64, bx::Float64, tol::Float64) =
    (_fmin_ws(ws); ccall((:sl_fmin_init, LIBSLC), Cvoid, (Ptr{Float64}, Float64, Float64, Float64), ws, ax, bx, tol))
function fmin_ask!(ws::Vector{Float64})
    _fmin_ws(ws)
    x = Ref{Float64}(0.0)
    need = ccall((:sl_fmin_ask, LIBSLC), Cint, (Ptr{Float64}, Ptr{Float64}), ws, x)
    return need != 0, x[]
end
fmin_tell!(ws::Vector{Float64}, f::Float64) =
    (_fmin_ws(ws); ccall((:sl_fmin_tell, LIBSLC), Cvoid, (Ptr{Float64}, Float64), ws, f))

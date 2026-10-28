# SLib (Teil 9.3) – Hüllen der Optimierer der C-Bibliothek slc über ccall: optim und Prüfhilfen.
#
# Gegenstück zu r/R/slc_opt.R (.sl_optim) und python/simlev/_lib_opt.py (optim). Die Rechnung
# steht in deps/core/slc_opt.c (Kopie von core/), gebaut von deps/build.jl in libslc.
# Rückfrage an den Host (Entwurf B.8): Julia holt die nächste Anfrage, rechnet die Zielfunktion
# selbst und gibt die Antwort; der Kern ruft nie nach Julia zurück, Fehler der Zielfunktion sind
# gewöhnliche Julia-Ausnahmen. Das Arbeitsfeld ist ein Vector{Float64} des Hosts.
#
# Seit Etappe 9.6b rufen die Ports optim an denselben Stellen wie R. optim nimmt die
# Argumente und Steuerwerte von R's optim an, soweit SimLev sie nutzt, und gibt eine RList mit
# par, value, counts (RVector "function", "gradient"; bei Nelder-Mead gradient = missing),
# convergence, message, iterations, evaluations (und trace) zurück.
# Eingebunden am Ende von slib.jl (Modul SLib); RList/RVector stehen im übergeordneten Modul.

const _P = parentmodule(@__MODULE__)

"Steuerwerte wie `sl_opt_ctrl` (Layout wie in C)."
struct OptCtrl
    maxit::Cint
    maxfev::Cint
    reltol::Float64
    gtol::Float64
    xtol::Float64
    fnscale::Float64
    parscale::Ptr{Float64}
    trace::Cint
end

const _OPT_METHODS = Dict("Nelder-Mead" => 3, "BFGS" => 1, "L-BFGS-B" => 2, "PBFGS" => 2, "NM" => 3)
const _OPT_KNOWN = ("maxit", "maxfev", "reltol", "factr", "pgtol", "gtol", "xtol", "fnscale", "parscale", "trace")
const _EPS = 2.220446049250313e-16

function _opt_method(method)
    haskey(_OPT_METHODS, method) || error("optim: unbekanntes Verfahren \"$method\"")
    _OPT_METHODS[method]
end

# Steuerwerte wie in R (.sl_opt_control): Nelder-Mead maxit = Funktionsauswertungen,
# L-BFGS-B factr (reltol = factr * eps, Standard 1e7) und pgtol (= gtol)
function _opt_control(control, m::Int, n::Int)
    ctl = Dict{String,Any}(String(k) => v for (k, v) in pairs(control === nothing ? Dict{String,Any}() : control))
    bad = [k for k in keys(ctl) if !(k in _OPT_KNOWN)]
    isempty(bad) || error("optim: unbekannte Steuerwerte " * join(["'$k'" for k in sort(bad)], ", "))
    function num1(k, def)
        v = get(ctl, k, nothing)
        v === nothing && return Float64(def)
        (v isa Real && !(v isa Bool) && !isnan(v)) || error("optim: Steuerwert $k muss eine Zahl sein")
        Float64(v)
    end
    get(ctl, "factr", nothing) !== nothing && get(ctl, "reltol", nothing) !== nothing &&
        error("optim: factr und reltol nicht zugleich angeben")
    if m == 3
        maxfev = num1("maxfev", num1("maxit", 500.0)); maxit = 0.0
        reltol = num1("reltol", sqrt(_EPS))
    else
        maxit = num1("maxit", 100.0); maxfev = num1("maxfev", 0.0)
        reltol = get(ctl, "factr", nothing) !== nothing ? num1("factr", 1e7) * _EPS :
                 num1("reltol", m == 2 ? 1e7 * _EPS : sqrt(_EPS))
    end
    gtol = num1("gtol", num1("pgtol", 1e-8))
    ps = get(ctl, "parscale", nothing)
    if ps !== nothing
        p = Float64.(vec(collect(ps)))
        length(p) in (1, n) || error("optim: Steuerwert parscale passt nicht zu par")
        ps = length(p) == n ? p : fill(p[1], n)
    end
    (Cint(maxit), Cint(maxfev), reltol, gtol, num1("xtol", _EPS), num1("fnscale", 1.0)), ps, get(ctl, "trace", false) == true
end

_opt_ctrl(c, ps) = OptCtrl(c[1], c[2], c[3], c[4], c[5], c[6], ps === nothing ? Ptr{Float64}(C_NULL) : pointer(ps), Cint(0))

_bounds(b, n) = (v = Float64.(vec(collect(b))); length(v) == n ? v : [v[mod1(i, length(v))] for i in 1:n])

function _fscalar(v)
    (v === missing || v === nothing) && return NaN
    v isa AbstractArray && (length(v) == 1 || error("optim: die Zielfunktion muss eine Zahl liefern (erhalten: Länge $(length(v)))"); v = first(v))
    v isa Real || error("optim: die Zielfunktion muss eine Zahl liefern (erhalten: Länge 1)")
    Float64(v)
end

_optmsg(reason) = unsafe_string(ccall((:sl_opt_message, LIBSLC), Cstring, (Cint,), Cint(reason)))

"""
    optim(par, fn, gr = nothing; method = "Nelder-Mead", lower = -Inf, upper = Inf, control = Dict())

Minimieren mit den Optimierern der C-Bibliothek slc (wie R's `optim` für "Nelder-Mead", "BFGS"
und "L-BFGS-B"; letzteres ist hier der projizierte BFGS, auch "PBFGS").
"""
function optim(par, fn, gr = nothing; method = "Nelder-Mead", lower = -Inf, upper = Inf, control = nothing)
    m = _opt_method(method)
    x0 = Float64.(vec(collect(par)))
    n = length(x0)
    n == 0 && error("optim: par muss ein nichtleerer Zahlenvektor sein")
    c, ps, trace = _opt_control(control, m, n)
    lo = hi = nothing
    if m == 2
        lo = _bounds(lower, n); hi = _bounds(upper, n)
    elseif any(isfinite, Float64.(vcat(lower))) || any(isfinite, Float64.(vcat(upper)))
        error("optim: Schranken nur mit L-BFGS-B bzw. PBFGS (nicht $method)")
    end
    len = ccall((:sl_opt_wsize, LIBSLC), Int64, (Cint, Cint), Cint(m), Cint(n))
    ws = zeros(Float64, len)
    plo = lo === nothing ? Ptr{Float64}(C_NULL) : pointer(lo)
    phi = hi === nothing ? Ptr{Float64}(C_NULL) : pointer(hi)
    cx = _ctx()
    st = GC.@preserve lo hi ps begin
        ctrl = Ref(_opt_ctrl(c, ps))
        ccall((:sl_opt_init, LIBSLC), Cint,
              (Ptr{Cvoid}, Cint, Cint, Ptr{Float64}, Ptr{Float64}, Ptr{Float64}, Ref{OptCtrl}, Cint, Ptr{Float64}),
              cx, Cint(m), Cint(n), x0, plo, phi, ctrl, Cint(gr !== nothing), ws)
    end
    _finish(cx, st)
    x = Vector{Float64}(undef, n)
    need = Ref{Cint}(0)
    tx = Vector{Vector{Float64}}(); tf = Float64[]; tk = Int32[]
    cx = _ctx()                       # ein Kontext für die ganze Schleife (der Kern warnt hier nie)
    try
        while true
            st = ccall((:sl_opt_ask, LIBSLC), Cint, (Ptr{Cvoid}, Ptr{Float64}, Ptr{Float64}, Ref{Cint}), cx, ws, x, need)
            st == 0 || error(unsafe_string(ccall((:sl_ctx_msg, LIBSLC), Cstring, (Ptr{Cvoid},), cx)))
            need[] == 0 && break
            xe = copy(x)
            if need[] == 1
                v = _fscalar(fn(xe))
                trace && (push!(tx, xe); push!(tf, v); push!(tk, Int32(1)))
                st = ccall((:sl_opt_tell, LIBSLC), Cint, (Ptr{Cvoid}, Ptr{Float64}, Float64, Ptr{Float64}), cx, ws, v, C_NULL)
            else
                g = Float64.(vec(collect(gr(xe))))
                length(g) == n || error("optim: der Gradient muss $n Zahlen liefern (erhalten: Länge $(length(g)))")
                trace && (push!(tx, xe); push!(tf, NaN); push!(tk, Int32(2)))
                st = ccall((:sl_opt_tell, LIBSLC), Cint, (Ptr{Cvoid}, Ptr{Float64}, Float64, Ptr{Float64}), cx, ws, 0.0, g)
            end
            st == 0 || error(unsafe_string(ccall((:sl_ctx_msg, LIBSLC), Cstring, (Ptr{Cvoid},), cx)))
        end
    finally
        ccall((:sl_ctx_free, LIBSLC), Cvoid, (Ptr{Cvoid},), cx)
    end
    xr = Vector{Float64}(undef, n)
    f = Ref{Float64}(0.0); code = Ref{Cint}(0); it = Ref{Cint}(0); nf = Ref{Cint}(0); ng = Ref{Cint}(0)
    reason = Ref{Cint}(0); ntot = Ref{Cint}(0)
    ccall((:sl_opt_result, LIBSLC), Cint,
          (Ptr{Float64}, Ptr{Float64}, Ref{Float64}, Ref{Cint}, Ref{Cint}, Ref{Cint}, Ref{Cint}), ws, xr, f, code, it, nf, ng)
    ccall((:sl_opt_info, LIBSLC), Cint, (Ptr{Float64}, Ref{Cint}, Ref{Cint}), ws, reason, ntot)
    counts = _P.RVector(Union{Int,Missing}[Int(nf[]), m == 3 ? missing : Int(ng[])]; names = ["function", "gradient"])
    out = _P.RList("par" => xr, "value" => f[], "counts" => counts, "convergence" => Int(code[]),
                   "message" => _optmsg(reason[]), "iterations" => Int(it[]), "evaluations" => Int(ntot[]))
    if trace
        X = Matrix{Float64}(undef, length(tx), n)
        for i in eachindex(tx)
            X[i, :] = tx[i]
        end
        out["trace"] = _P.RList("x" => X, "f" => tf, "need" => tk)
    end
    out
end

# ── Prüfhilfen (Plausibilität, Gleichlauf): Prüffunktionen in C ─────────────

"Wert (`grad = false`) bzw. `[Wert, Gradient]` der Prüffunktion `id` an `x`."
function opt_testfn(id, x; grad = false)
    v = Float64.(vec(collect(x)))
    if !grad
        return ccall((:sl_opt_testfn, LIBSLC), Float64, (Cint, Cint, Ptr{Float64}, Ptr{Float64}), Cint(id), Cint(length(v)), v, C_NULL)
    end
    g = Vector{Float64}(undef, length(v))
    f = ccall((:sl_opt_testfn, LIBSLC), Float64, (Cint, Cint, Ptr{Float64}, Ptr{Float64}), Cint(id), Cint(length(v)), v, g)
    Any[f, g]
end

"Direkter C-Weg (`sl_minimize`) mit der Prüffunktion `id`; Steuerwerte wie `optim`."
function minimize_test(id, par; method = "Nelder-Mead", lower = -Inf, upper = Inf, control = nothing, grad = false)
    m = _opt_method(method)
    x = Float64.(vec(collect(par)))
    n = length(x)
    c, ps, _ = _opt_control(control, m, n)
    lo = hi = nothing
    m == 2 && (lo = _bounds(lower, n); hi = _bounds(upper, n))
    plo = lo === nothing ? Ptr{Float64}(C_NULL) : pointer(lo)
    phi = hi === nothing ? Ptr{Float64}(C_NULL) : pointer(hi)
    f = Ref{Float64}(0.0); code = Ref{Cint}(0); it = Ref{Cint}(0); nf = Ref{Cint}(0); ntot = Ref{Cint}(0)
    cx = _ctx()
    st = GC.@preserve lo hi ps begin
        ctrl = Ref(_opt_ctrl(c, ps))
        ccall((:sl_opt_test_minimize, LIBSLC), Cint,
              (Ptr{Cvoid}, Cint, Cint, Cint, Ptr{Float64}, Ptr{Float64}, Ptr{Float64}, Ref{OptCtrl}, Cint,
               Ref{Float64}, Ref{Cint}, Ref{Cint}, Ref{Cint}, Ref{Cint}),
              cx, Cint(id), Cint(m), Cint(n), x, plo, phi, ctrl, Cint(grad), f, code, it, nf, ntot)
    end
    _finish(cx, st)
    _P.RList("par" => x, "value" => f[], "convergence" => Int(code[]), "iterations" => Int(it[]),
             "nfev" => Int(nf[]), "evaluations" => Int(ntot[]))
end

"Numerischer Gradient (B.9) der Prüffunktion `id` an `x` (Schranken wahlweise)."
function numgrad_test(id, x; lower = nothing, upper = nothing)
    v = Float64.(vec(collect(x)))
    n = length(v)
    lo = lower === nothing ? nothing : _bounds(lower, n)
    hi = upper === nothing ? nothing : _bounds(upper, n)
    g = Vector{Float64}(undef, n)
    cnt = Ref{Cint}(0)
    cx = _ctx()
    st = GC.@preserve lo hi ccall((:sl_opt_test_numgrad, LIBSLC), Cint,
        (Ptr{Cvoid}, Cint, Cint, Ptr{Float64}, Ptr{Float64}, Ptr{Float64}, Ptr{Float64}, Ref{Cint}),
        cx, Cint(id), Cint(n), v, lo === nothing ? Ptr{Float64}(C_NULL) : pointer(lo),
        hi === nothing ? Ptr{Float64}(C_NULL) : pointer(hi), g, cnt)
    _finish(cx, st)
    g
end

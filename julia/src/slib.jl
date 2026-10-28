# SLib – Hüllen der C-Bibliothek slc (SimLev core, Etappe 9.1) über ccall: Zufallszustand,
# simlev_seed(), interne Ziehungen und Verteilungen.
#
# Gegenstück zu r/R/slc.R (R) und python/simlev/_lib.py (Python). Die Rechnung steht in
# deps/core/slc*.c (Kopien von core/), gebaut von deps/build.jl (Pkg.build) nach
# deps/usr/lib/libslc.<dlext>; deps/deps.jl nennt den Pfad (const LIBSLC). Warnungen und
# Fehlertexte kommen aus dem Kern und sind in allen drei Sprachen gleich (Warnung: @warn ohne
# Quellangabe; Fehler: error(msg)). Der Kontext sl_ctx ist für Julia undurchsichtig
# (sl_ctx_alloc/sl_ctx_free und Zugriffsfunktionen); ein Benutzerabbruch ist nur zwischen zwei
# Aufrufen möglich (interrupted = NULL).
#
# Zufallszustand (Entwurf C.5): globaler Zustand G prozessweit mit ReentrantLock (F3; nicht je
# Task), gesetzt beim Laden (__init__) und mit simlev_seed(nothing) aus Uhrzeit, Prozessnummer
# und Zähler; Strom-Objekt Stream (32 Byte). Die Hüllen rechnen auf einer Kopie des Zustands und
# schreiben ihn nur bei Erfolg zurück. Innerhalb einer parallelen Einheit (in_unit) darf G nicht
# benutzt werden (Merker je Task).
#
# Seit Etappe 9.6a ziehen alle zufälligen Exporte hierüber (Regeln C.5): seed = nothing zieht genau
# einmal k = next_seed() aus G und verfährt dann wie mit seed = k; seed = s lässt G unberührt, der
# Hauptstrom ist Stream(s) (main_stream); Einheiten mit cores bekommen ihre Ströme U_i = J^i(S_0) aus
# streams() vor der Verteilung (RParallel.par_lapply setzt in jeder Aufgabe den Merker in_unit). Die
# Nachbildung von R's Zufall (RRng, Export set_seed) ist mit Etappe 9.6c entfallen.
module SLib

const _DEPS = joinpath(@__DIR__, "..", "deps", "deps.jl")
isfile(_DEPS) || error("SimLev: C-Bibliothek fehlt – Pkg.build(\"SimLev\") mit C-Compiler ausführen")
include(_DEPS)
include_dependency(_DEPS)
isfile(LIBSLC) || error("SimLev: C-Bibliothek fehlt – Pkg.build(\"SimLev\") mit C-Compiler ausführen")
include_dependency(LIBSLC)

"Zufallsstrom (Zustand xoshiro256**, 32 Byte; Layout wie `sl_rng`)."
mutable struct Stream
    s::NTuple{4,UInt64}
end

const _G = Stream((0x0, 0x0, 0x0, 0x0))
const _LOCK = ReentrantLock()
const _COUNTER = Ref{UInt64}(0)

version() = unsafe_string(ccall((:sl_version, LIBSLC), Cstring, ()))

function _entropy!(st::Stream)
    _COUNTER[] += 1
    ccall((:sl_rng_seed_entropy, LIBSLC), Cvoid, (Ref{Stream}, UInt64, UInt64, UInt64),
          st, time_ns(), UInt64(getpid()), _COUNTER[])
    st
end

__init__() = (lock(() -> _entropy!(_G), _LOCK); nothing)

# ── Kontext ────────────────────────────────────────────────────────────────

function _ctx()
    cx = ccall((:sl_ctx_alloc, LIBSLC), Ptr{Cvoid}, ())
    cx == C_NULL && error("SimLev: kein Speicher für den Kontext der C-Bibliothek")
    cx
end

# Warnungen in Reihenfolge ausgeben, bei Fehler error(msg); gibt den Kontext frei
function _finish(cx::Ptr{Cvoid}, st::Cint)
    try
        nw = ccall((:sl_ctx_nwarn, LIBSLC), Cint, (Ptr{Cvoid},), cx)
        for i in 0:(nw - 1)
            msg = unsafe_string(ccall((:sl_ctx_warn, LIBSLC), Cstring, (Ptr{Cvoid}, Cint), cx, i))
            @warn msg
        end
        st == 0 || error(unsafe_string(ccall((:sl_ctx_msg, LIBSLC), Cstring, (Ptr{Cvoid},), cx)))
    finally
        ccall((:sl_ctx_free, LIBSLC), Cvoid, (Ptr{Cvoid},), cx)
    end
    nothing
end

# ── Seed, Ströme, Regeln C.5 ───────────────────────────────────────────────

_seed_text(seed) = seed isa Integer && !(seed isa Bool) ? string(seed) : (t = repr(seed); length(t) <= 60 ? t : first(t, 57) * "...")

"Seed prüfen: `Integer` (kein `Bool`) mit |seed| < 2^53 (Entwurf C.5, Regel 2)."
function check_seed(seed)
    ok = seed isa Integer && !(seed isa Bool) && abs(big(seed)) < big(2)^53
    ok || error("seed: ganze Zahl erwartet (erhalten: $(_seed_text(seed)))")
    Int64(seed)
end

"""
    simlev_seed(seed = nothing)

Zufallszustand von SimLev setzen. Mit einer ganzen Zahl (`|seed| < 2^53`) entsteht ein
reproduzierbarer Zustand; ohne Argument (oder mit `nothing`) ein neuer Zustand aus Uhrzeit,
Prozessnummer und einem Zähler, der nicht reproduzierbar ist. Beim Laden des Pakets geschieht
dasselbe. Der Zustand ist prozessweit (mit Sperre) und liefert in
R, Python und Julia bei gleichem `seed` und gleicher Aufruffolge bitgleiche Ziehungen.
Generator ist xoshiro256** (Blackman, Vigna 2021) mit SplitMix64-Seeding (Steele, Lea, Flood
2014); unabhängige Ströme je Einheit entstehen durch Sprünge um 2^128 Schritte.

Die zufälligen Funktionen von SimLev (Argument `seed`, z. B. `bootstrap`, `bootstrap_study`,
`scenario_copula`, `regime_hmm`) ziehen aus diesem Zustand:

* `seed = nothing`: der Aufruf zieht **genau einmal** einen Startwert k (0 … 2^31 - 1) und rechnet
  wie mit `seed = k`; `bootstrap`/`bootstrap_study` legen k unter `seed` ab. Nach
  `simlev_seed(s)` ist so auch eine Folge von Aufrufen mit `seed = nothing` reproduzierbar.
* `seed = s`: der globale Zustand bleibt unberührt.
* Funktionen mit `cores` geben jedem Pfad einen eigenen Strom; das Ergebnis hängt nicht von
  `cores`, `chunk_size` oder der Zahl der Threads (`julia -t`) ab.
* R's `set.seed()` wirkt auf SimLev nicht (die Nachbildung `set_seed` ist seit 9.6c entfallen).

```julia
simlev_seed(42)
a = sharpe_test(x, y; method = "bootstrap", B = 50)   # seed = nothing: ein Zug aus dem Zustand
simlev_seed(42)
b = sharpe_test(x, y; method = "bootstrap", B = 50)   # gleich a
```

Gibt `seed` zurück.
"""
function simlev_seed(seed = nothing)
    if seed === nothing
        lock(() -> _entropy!(_G), _LOCK)
    else
        s = check_seed(seed)
        lock(_LOCK) do
            ccall((:sl_rng_seed, LIBSLC), Cvoid, (Ref{Stream}, Int64), _G, s)
        end
    end
    seed
end

"Neuer Strom aus einem Seed."
function Stream(seed::Integer)
    st = Stream((0x0, 0x0, 0x0, 0x0))
    ccall((:sl_rng_seed, LIBSLC), Cvoid, (Ref{Stream}, Int64), st, check_seed(seed))
    st
end

_in_unit() = get(task_local_storage(), :simlev_in_unit, false)::Bool

"`f()` als parallele Einheit ausführen: G ist darin gesperrt (Entwurf C.5, Regel 7)."
in_unit(f) = task_local_storage(f, :simlev_in_unit, true)

_global_check() = _in_unit() && error("interner Fehler: globaler Zufallszustand in paralleler Einheit")

"Regel 3: nächster Startwert aus G (0 … 2^31 - 1); G rückt um eine Ausgabe vor."
function next_seed()
    _global_check()
    lock(_LOCK) do
        Int(ccall((:sl_rng_seed31, LIBSLC), Int32, (Ref{Stream},), _G))
    end
end

"Regeln 3 und 4: `nothing` → `next_seed()`, sonst geprüft."
resolve_seed(seed) = seed === nothing ? next_seed() : check_seed(seed)

"Hauptstrom einer zufälligen Funktion (Regeln 3 bis 5): `Stream(resolve_seed(seed))`."
main_stream(seed) = Stream(resolve_seed(seed))

"Regel 6: Ströme je Einheit U_i = J^i(S_0), i = 1 … n."
function streams(stream, n::Integer)
    base = stream isa Stream ? stream : Stream(stream)
    n < 0 && error("Ströme: Anzahl negativ")
    out = [Stream((0x0, 0x0, 0x0, 0x0)) for _ in 1:n]
    buf = Vector{NTuple{4,UInt64}}(undef, n)
    cx = _ctx()
    st = ccall((:sl_rng_streams, LIBSLC), Cint, (Ptr{Cvoid}, Ref{Stream}, Int64, Ptr{NTuple{4,UInt64}}),
               cx, Stream(base.s), Int64(n), buf)
    _finish(cx, st)
    for i in 1:n
        out[i].s = buf[i]
    end
    out
end

"Zustand als 4 Hex-Wörter (Gleichlauf, Prüfung)."
function state_hex(stream = nothing)
    s = if stream === nothing
        _global_check()
        lock(() -> _G.s, _LOCK)
    else
        stream.s
    end
    [string(v; base = 16, pad = 16) for v in s]
end

# Ziehung auf einer Kopie des Zustands; bei Erfolg zurückschreiben
function _draw(f, stream, args...)
    if stream === nothing
        _global_check()
        lock(_LOCK) do
            tmp = Stream(_G.s)
            r = f(tmp, args...)
            _G.s = tmp.s
            r
        end
    else
        tmp = Stream(stream.s)
        r = f(tmp, args...)
        stream.s = tmp.s
        r
    end
end

function _count(n)
    (n isa Integer && !(n isa Bool) && 0 <= n <= 2^52) || error("interner Fehler: n muss eine ganze Zahl >= 0 sein")
    Int64(n)
end

"rohe 64-Bit-Ausgaben als Hex (Testvektoren)."
function u64(n; stream = nothing)
    v = _draw(stream) do st
        [ccall((:sl_rng_next, LIBSLC), UInt64, (Ref{Stream},), st) for _ in 1:_count(n)]
    end
    [string(x; base = 16, pad = 16) for x in v]
end

for (jl, c) in ((:runif, :sl_runif), (:rnorm, :sl_rnorm), (:rgamma, :sl_rgamma))
    @eval function $(Symbol("_", jl))(st::Stream, n::Int64, a::Float64, b::Float64)
        out = Vector{Float64}(undef, n)
        cx = _ctx()
        s = ccall(($(QuoteNode(c)), LIBSLC), Cint, (Ptr{Cvoid}, Ref{Stream}, Int64, Float64, Float64, Ptr{Float64}),
                  cx, st, n, a, b, out)
        _finish(cx, s)
        out
    end
end
for (jl, c) in ((:rexp, :sl_rexp), (:rgeom, :sl_rgeom), (:rchisq, :sl_rchisq))
    @eval function $(Symbol("_", jl))(st::Stream, n::Int64, a::Float64)
        out = Vector{Float64}(undef, n)
        cx = _ctx()
        s = ccall(($(QuoteNode(c)), LIBSLC), Cint, (Ptr{Cvoid}, Ref{Stream}, Int64, Float64, Ptr{Float64}),
                  cx, st, n, a, out)
        _finish(cx, s)
        out
    end
end

runif(n, min = 0.0, max = 1.0; stream = nothing) = _draw(_runif, stream, _count(n), Float64(min), Float64(max))
rnorm(n, mean = 0.0, sd = 1.0; stream = nothing) = _draw(_rnorm, stream, _count(n), Float64(mean), Float64(sd))
rgamma(n, shape, scale = 1.0; stream = nothing) = _draw(_rgamma, stream, _count(n), Float64(shape), Float64(scale))
rexp(n, rate = 1.0; stream = nothing) = _draw(_rexp, stream, _count(n), Float64(rate))
rgeom(n, prob; stream = nothing) = _draw(_rgeom, stream, _count(n), Float64(prob))
rchisq(n, df; stream = nothing) = _draw(_rchisq, stream, _count(n), Float64(df))

"Stichprobe aus 1 … n (wie R's `sample.int`); Ergebnis `Vector{Int32}`."
function sample(n, size = n; replace = false, prob = nothing, stream = nothing)
    nn = _count(n); sz = _count(size)
    pr = prob === nothing ? nothing : Vector{Float64}(prob)
    pr === nothing || length(pr) == nn || error("sample: Länge von prob passt nicht zu n")
    _draw(stream) do st
        out = Vector{Int32}(undef, sz)
        cx = _ctx()
        pp = pr === nothing ? Ptr{Float64}(C_NULL) : pr
        s = ccall((:sl_sample, LIBSLC), Cint, (Ptr{Cvoid}, Ref{Stream}, Int64, Int64, Cint, Ptr{Float64}, Ptr{Int32}),
                  cx, st, nn, sz, Cint(replace), pp, out)
        _finish(cx, s)
        out
    end
end

# ── Verteilungen (Parameter skalar; Form des Arguments bleibt) ─────────────

_vec(x) = x isa AbstractArray ? Array{Float64}(x) : Float64[x]
_shape(x, out) = x isa AbstractArray ? reshape(out, size(x)) : out[1]

for (jl, c) in ((:erfc, :sl_erfc_v), (:lgamma, :sl_lgamma), (:plogis, :sl_plogis), (:qlogis, :sl_qlogis))
    @eval function $jl(x)
        v = _vec(x); out = similar(v)
        cx = _ctx()
        s = ccall(($(QuoteNode(c)), LIBSLC), Cint, (Ptr{Cvoid}, Int64, Ptr{Float64}, Ptr{Float64}), cx, length(v), v, out)
        _finish(cx, s)
        _shape(x, out)
    end
end
for (jl, c) in ((:_pnorm, :sl_pnorm), (:_qnorm, :sl_qnorm), (:_dnorm, :sl_dnorm), (:_pbeta, :sl_pbeta))
    @eval function $jl(x, a::Float64, b::Float64, flag::Bool)
        v = _vec(x); out = similar(v)
        cx = _ctx()
        s = ccall(($(QuoteNode(c)), LIBSLC), Cint, (Ptr{Cvoid}, Int64, Ptr{Float64}, Float64, Float64, Cint, Ptr{Float64}),
                  cx, length(v), v, a, b, Cint(flag), out)
        _finish(cx, s)
        _shape(x, out)
    end
end
for (jl, c) in ((:_pt, :sl_pt), (:_qt, :sl_qt))
    @eval function $jl(x, df::Float64, flag::Bool)
        v = _vec(x); out = similar(v)
        cx = _ctx()
        s = ccall(($(QuoteNode(c)), LIBSLC), Cint, (Ptr{Cvoid}, Int64, Ptr{Float64}, Float64, Cint, Ptr{Float64}),
                  cx, length(v), v, df, Cint(flag), out)
        _finish(cx, s)
        _shape(x, out)
    end
end

pnorm(q, mean = 0.0, sd = 1.0; lower_tail = true) = _pnorm(q, Float64(mean), Float64(sd), Bool(lower_tail))
qnorm(p, mean = 0.0, sd = 1.0; lower_tail = true) = _qnorm(p, Float64(mean), Float64(sd), Bool(lower_tail))
dnorm(x, mean = 0.0, sd = 1.0; log = false) = _dnorm(x, Float64(mean), Float64(sd), Bool(log))
pbeta(q, shape1, shape2; lower_tail = true) = _pbeta(q, Float64(shape1), Float64(shape2), Bool(lower_tail))
pt(q, df; lower_tail = true) = _pt(q, Float64(df), Bool(lower_tail))
qt(p, df; lower_tail = true) = _qt(p, Float64(df), Bool(lower_tail))

# 9.2: lineare Algebra, Matrixprodukt, kleinste Quadrate, Stineman, Spline, Kerndichte
include("slib_linalg.jl")
include("slib_opt.jl")   # 9.3: Optimierer der C-Bibliothek slc (optim, Prüfhilfen)
include("slib_models.jl")   # 9.4: Modelle (GARCH/GJR, GPD, DCC, MS-GARCH und HMM, Bootstrap-Kerne)

end # module SLib

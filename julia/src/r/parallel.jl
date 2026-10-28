# RParallel – Nachbildung von SimLev's `.par_lapply` (r/R/bootstrap.R):
# `parallel::mclapply(X, FUN, mc.cores = cores, mc.preschedule = FALSE,
# mc.set.seed = FALSE)`. Vorlage: python/simlev/_r/parallel.py.
#
# Verhalten wie R (Etappe 5, siehe julia/DEVELOPING.md):
# * `cores` wird ganzzahlig abgeschnitten; unter zwei Kernen oder mit höchstens
#   einem Element ist es `lapply` (der Zufallsstrom läuft fortlaufend weiter).
# * Sonst startet jedes Element mit dem Zufallszustand des Aufrufers; danach ist
#   der Zustand des Aufrufers unverändert.
# * Ergebnisse in der Reihenfolge von `X`; Warnungen der Elemente gehen verloren
#   (R: im Kindprozess); Meldungen und Ausgaben über `r_stderr()`/`r_stdout()`
#   erscheinen in der Reihenfolge der Elemente (R: Reihenfolge der Fertigstellung).
# * Fehler: Ausgaben der Elemente davor, dann der erste Fehler in
#   Elementreihenfolge (wie die sequentielle Fassung).
#
# Echte Parallelität mit `Threads.@spawn`, wenn Julia mit mehreren Threads läuft
# (`julia -t auto`, `JULIA_NUM_THREADS`), sonst nacheinander mit derselben
# Semantik. Jede Aufgabe rechnet mit einer eigenen Kopie des Zufallszustands
# (`RRng.with_state`) und einem eigenen Ausgabepuffer (task-lokaler Speicher).
module RParallel

import ..SimLev
using Base.CoreLogging: with_logger, NullLogger

export par_lapply, r_stderr, r_stdout, suppress_messages

const _OUT_KEY = :SimLev_RParallel_capture
const _MUTE_KEY = :SimLev_RParallel_mute

# ── Ausgaben je Aufgabe ──────────────────────────────────────────────────

"Ausgaben eines Elements als Folge (Strom, Bytes); Strom 1 = stdout, 2 = stderr."
struct Capture
    chunks::Vector{Tuple{Int,Vector{UInt8}}}
end
Capture() = Capture(Tuple{Int,Vector{UInt8}}[])

struct _CapStream <: IO
    cap::Capture
    k::Int
end
function _add!(c::_CapStream, bytes::Vector{UInt8})
    ch = c.cap.chunks
    if !isempty(ch) && ch[end][1] == c.k
        append!(ch[end][2], bytes)
    else
        push!(ch, (c.k, bytes))
    end
    nothing
end
Base.unsafe_write(c::_CapStream, p::Ptr{UInt8}, n::UInt) = (_add!(c, copy(unsafe_wrap(Array, p, n))); Int(n))
Base.write(c::_CapStream, b::UInt8) = (_add!(c, UInt8[b]); 1)
Base.isopen(::_CapStream) = true
Base.iswritable(::_CapStream) = true
Base.flush(::_CapStream) = nothing

@inline function _tls_get(key, default)
    tls = current_task().storage
    tls === nothing && return default
    return get(tls::IdDict{Any,Any}, key, default)
end

"""
    r_stderr()

Ziel für R-`message()`: der Ausgabepuffer der laufenden `par_lapply`-Aufgabe,
`devnull` unter [`suppress_messages`](@ref), sonst `stderr`.
"""
function r_stderr()
    _tls_get(_MUTE_KEY, false) === true && return devnull
    c = _tls_get(_OUT_KEY, nothing)
    return c === nothing ? stderr : _CapStream(c::Capture, 2)
end

"Ziel für `cat`/`print`: der Ausgabepuffer der laufenden `par_lapply`-Aufgabe, sonst `stdout`."
function r_stdout()
    c = _tls_get(_OUT_KEY, nothing)
    return c === nothing ? stdout : _CapStream(c::Capture, 1)
end

"`suppressMessages(f())`: Meldungen über `r_stderr()` verwerfen (nur in der laufenden Aufgabe)."
suppress_messages(f) = task_local_storage(f, _MUTE_KEY, true)

function _replay(cap::Capture)
    isempty(cap.chunks) && return nothing
    for (k, b) in cap.chunks
        write(k == 1 ? r_stdout() : r_stderr(), b)
    end
    flush(stdout); flush(stderr)
    nothing
end

# ── Zufallszustand des Aufrufers (sequentielle Fassung) ─────────────────

_R() = SimLev.RRng
_kind_get() = collect(String, _R().rng_kind())

"Zustand wie `.Random.seed` samt RNGkind (auch ohne `.Random.seed`)."
function rng_snapshot()
    has = _R().has_random_seed()
    seed = has ? _R().get_random_seed() : nothing
    kind = _kind_get()
    has || (_R().has_random_seed() && _R().rm_random_seed())
    return (has, seed, kind)
end
"Zustand aus [`rng_snapshot`](@ref) wiederherstellen."
function rng_reset(snap)
    has, seed, kind = snap
    if has
        _R().set_random_seed(seed)
    else
        _R().rng_kind(kind[1], kind[2], kind[3])
        _R().has_random_seed() && _R().rm_random_seed()
    end
end

# ── par_lapply ───────────────────────────────────────────────────────────

"`as.integer(mc.cores)` für `cores > 1` (R schneidet ab)."
_ncores(cores) = cores isa Integer ? Int(cores) : unsafe_trunc(Int, Float64(cores))

"""
    par_lapply(X, FUN, cores = 1)

Port von `.par_lapply(X, FUN, cores)`; Ergebnis `Vector{Any}` in der Reihenfolge
von `X`. Parallel mit `Threads.@spawn`, wenn `Threads.nthreads() > 1`.
"""
function par_lapply(X, FUN, cores = 1)
    xs = collect(X)
    (cores === nothing || cores <= 1 || length(xs) <= 1) && return Any[FUN(x) for x in xs]
    n = min(_ncores(cores), length(xs))
    n < 2 && return Any[FUN(x) for x in xs]          # mclapply: cores < 2 -> lapply
    nt = Threads.nthreads()
    nt < 2 && return _sequential(xs, FUN)
    return _threaded(xs, FUN, min(n, nt))
end

"Fork-Semantik nacheinander: jedes Element mit dem Zustand des Aufrufers."
function _sequential(xs, FUN)
    snap = rng_snapshot()
    out = Any[]
    try
        for x in xs
            rng_reset(snap)
            push!(out, with_logger(() -> FUN(x), NullLogger()))
        end
    finally
        rng_reset(snap)
    end
    return out
end

function _threaded(xs, FUN, n::Int)
    nx = length(xs)
    snap = _R().copy_state()            # Zustand des Aufrufers (bleibt unverändert)
    res = Vector{Any}(undef, nx)
    caps = Vector{Capture}(undef, nx)
    status = zeros(Int, nx)             # 0 offen, 1 fertig, 2 Fehler
    next = Threads.Atomic{Int}(1)
    stop = Threads.Atomic{Int}(nx + 1)  # kleinster Index mit Fehler
    done = Channel{Int}(nx)
    function work()
        while true
            i = Threads.atomic_add!(next, 1)
            (i > nx || i >= stop[]) && break
            cap = Capture()
            st = _R().TaskState(_R()._copy(snap.S), _R()._copy(snap.RG), _R()._copy(snap.RP))
            try
                res[i] = task_local_storage(_OUT_KEY, cap) do
                    _R().with_state(st) do
                        with_logger(() -> FUN(xs[i]), NullLogger())
                    end
                end
                status[i] = 1
            catch e
                res[i] = e
                status[i] = 2
                Threads.atomic_min!(stop, i)
            end
            caps[i] = cap
            put!(done, i)               # danach liest der Elternprozess res, status, caps
        end
    end
    tasks = [Threads.@spawn(work()) for _ in 1:n]
    ready = falses(nx)
    emitted = 0
    err = nothing
    try
        while emitted < nx
            ready[take!(done)] = true
            while emitted < nx && ready[emitted+1]
                i = emitted + 1
                _replay(caps[i])
                if status[i] == 2
                    err = res[i]
                    break
                end
                emitted = i
            end
            err === nothing || break
        end
    finally
        foreach(wait, tasks)
        close(done)
    end
    err === nothing || throw(err)
    return res
end

end # module

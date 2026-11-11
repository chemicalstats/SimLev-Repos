# Herkunft:           nachgebildet nach R 4.3.3, src/library/parallel/R/unix/mclapply.R (nur das
#                     Verhalten: Reihenfolge, Fehler, Ausgaben)
# Rechte:             The R Core Team, teils Robert Gentleman und Ross Ihaka, The R Foundation (laut
#                     Kopf der jeweiligen R-Quelle)
# Lizenz der Vorlage: GPL (>= 2) laut Kopf der R-Quellen; in SimLev unter GPL-3
# Änderungen:         Übertragung nach Python bzw. Julia (Julia nach der Python-Fassung) im von
#                     SimLev genutzten Umfang.
# RParallel – Nachbildung von SimLev's `.par_lapply` (r/R/bootstrap.R):
# `parallel::mclapply(X, FUN, mc.cores = cores, mc.preschedule = FALSE,
# mc.set.seed = FALSE)`. Vorlage: python/simlev/_r/parallel.py.
#
# Verhalten wie R (siehe julia/DEVELOPING.md; Zufall seit 1.0.0):
# * `cores` wird ganzzahlig abgeschnitten; unter zwei Kernen oder mit höchstens
#   einem Element ist es `lapply`.
# * Zufall: jede Einheit läuft als parallele
#   Einheit (`SimLev.SLib.in_unit`, Merker je Aufgabe): der globale Zufallszustand
#   von SimLev ist darin gesperrt, auch bei `cores = 1`. Zufällige Einheiten
#   bekommen ihren Strom als Argument; das Ergebnis hängt nicht von `cores` oder
#   der Zahl der Threads ab. Die frühere Kopie des R-Zufallszustands je Aufgabe
#   (`RRng.with_state`) entfällt.
# * Ergebnisse in der Reihenfolge von `X`; seit 1.6.4 (Entscheidung 133) bei jedem `cores` Meldungen, Ausgaben
#   über `r_stderr()`/`r_stdout()` und Warnungen (Logger) wie mit `cores = 1` in der Reihenfolge der Elemente (bis
#   dahin gingen Warnungen bei fester Zahl ≥ 2 verloren). Direkte Ausgaben mit `println`/`print` auf
#   `stdout`/`stderr` (etwa in Funktionen des Anwenders) erscheinen mit mehreren Aufgaben in der Reihenfolge der
#   Fertigstellung.
# * Fehler: Ausgaben der Elemente davor, dann der erste Fehler in
#   Elementreihenfolge (wie die sequentielle Fassung).
#
# Echte Parallelität mit `Threads.@spawn`, wenn Julia mit mehreren Threads läuft
# (`julia -t auto`, `JULIA_NUM_THREADS`), sonst nacheinander mit derselben
# Semantik. Jede Aufgabe rechnet mit einem eigenen Ausgabepuffer (task-lokaler
# Speicher).
module RParallel

import ..SimLev
using Base.CoreLogging: with_logger

export par_lapply, r_stderr, r_stdout, suppress_messages, with_message_stream

const _OUT_KEY = :SimLev_RParallel_capture
const _MUTE_KEY = :SimLev_RParallel_mute
const _MSG_KEY = :SimLev_RParallel_messages
const _CAP_KEY = :SimLev_RParallel_thread_cap   # Kern-Threads je Aufgabe (seit 1.6.4, Entscheidung 41c)

# ── Ausgaben je Aufgabe ──────────────────────────────────────────────────

"""Ausgaben eines Elements als Folge (Strom, Bytes); Strom 1 = stdout, 2 = stderr. Seit 1.6.4 (`cores = "auto"`)
zusätzlich Strom 3 = Warnung (Index in `logs`) und 4 = Hinweis zu SIMLEV_THREADS (Merker)."""
struct Capture
    chunks::Vector{Tuple{Int,Vector{UInt8}}}
    logs::Vector{Any}
end
Capture() = Capture(Tuple{Int,Vector{UInt8}}[], Any[])

const _PAR_LAST = Ref{Tuple{Int,Int,Int}}((0, 0, 0))   # letzter Plan von cores = "auto" (seit 1.6.4; intern, für Proben)
const _REC_KEY = :SimLev_RParallel_record   # Mitschnitt von Warnungen und Hinweis in Aufgaben (seit 1.6.4)

"""Logger einer parallelen Aufgabe (seit 1.6.4; seit Entscheidung 133 auch bei fester Zahl): legt jede Meldung, die
der Logger der aufrufenden Aufgabe annehmen würde, in der Folge der Ausgaben ab; die Wiedergabe gibt sie an diesen
Logger weiter."""
struct _RecLogger <: Base.CoreLogging.AbstractLogger
    cap::Capture
    parent::Base.CoreLogging.AbstractLogger
end
Base.CoreLogging.min_enabled_level(l::_RecLogger) = Base.CoreLogging.min_enabled_level(l.parent)
Base.CoreLogging.shouldlog(l::_RecLogger, level, _module, group, id) =
    Base.CoreLogging.shouldlog(l.parent, level, _module, group, id)
Base.CoreLogging.catch_exceptions(l::_RecLogger) = Base.CoreLogging.catch_exceptions(l.parent)
function Base.CoreLogging.handle_message(l::_RecLogger, level, message, _module, group, id, file, line; kwargs...)
    push!(l.cap.logs, (level, message, _module, group, id, file, line, collect(kwargs)))
    push!(l.cap.chunks, (3, UInt8[]))
    nothing
end

"""Hinweis zu SIMLEV_THREADS in einer parallelen Aufgabe zurückstellen (`SLib.nthreads`, seit 1.6.4): Merker
in der Folge der Ausgaben (einmal je Element), die Wiedergabe zeigt den Hinweis höchstens einmal je Sitzung an der
Stelle wie nacheinander. Außerhalb solcher Aufgaben `false`."""
function defer_hint()
    _tls_get(_REC_KEY, false) === true || return false
    c = _tls_get(_OUT_KEY, nothing)
    c === nothing && return false
    cap = c::Capture
    any(ch -> ch[1] == 4, cap.chunks) || push!(cap.chunks, (4, UInt8[]))
    return true
end

struct _CapStream <: IO
    cap::Capture
    k::Int
end
# seit 1.6.3: angehängt ohne Zwischenkopie, kopiert nur, wenn ein neuer Abschnitt den Vektor ablegt (gleiche Abschnitte)
function Base.unsafe_write(c::_CapStream, p::Ptr{UInt8}, n::UInt)
    ch = c.cap.chunks
    src = unsafe_wrap(Array, p, n)
    (!isempty(ch) && ch[end][1] == c.k) ? append!(ch[end][2], src) : push!(ch, (c.k, copy(src)))
    return Int(n)
end
function Base.write(c::_CapStream, b::UInt8)
    ch = c.cap.chunks
    (!isempty(ch) && ch[end][1] == c.k) ? push!(ch[end][2], b) : push!(ch, (c.k, UInt8[b]))
    return 1
end
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
    m = _tls_get(_MSG_KEY, nothing)
    m === nothing || return m::IO
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

"""
    with_message_stream(f, io)

`withCallingHandlers(f(), message = …)`: Meldungen über `r_stderr()` gehen während `f()` (in der
laufenden Aufgabe) an den Strom `io`, der sie umformt und weitergibt (Fonds-Wrapper: Präfix der
inneren Rechnung). `io` sollte beim Anlegen das bisherige `r_stderr()` als Ziel übernehmen;
`suppress_messages` innerhalb von `f` verwirft weiter.
"""
function with_message_stream(f, io::IO)
    tls = task_local_storage()
    had = haskey(tls, _MSG_KEY)
    old = had ? tls[_MSG_KEY] : nothing
    tls[_MSG_KEY] = io
    try
        return f()
    finally
        had ? (tls[_MSG_KEY] = old) : delete!(tls, _MSG_KEY)
    end
end

function _replay(cap::Capture)
    isempty(cap.chunks) && return nothing
    nl = 0
    for (k, b) in cap.chunks
        if k == 3                      # Warnung an den Logger der aufrufenden Aufgabe (seit 1.6.4)
            nl += 1
            level, message, _module, group, id, file, line, kw = cap.logs[nl]
            lg = Base.CoreLogging.current_logger()
            if level >= Base.CoreLogging.min_enabled_level(lg) && Base.CoreLogging.shouldlog(lg, level, _module, group, id)
                Base.CoreLogging.handle_message(lg, level, message, _module, group, id, file, line; kw...)
            end
        elseif k == 4                  # Hinweis zu SIMLEV_THREADS höchstens einmal je Sitzung (seit 1.6.4)
            if !SimLev.SLib._THREADS_HINT[]
                SimLev.SLib._THREADS_HINT[] = true
                println(r_stderr(), SimLev.chk_msg("hinweis.prozessoren", "SIMLEV_THREADS", SimLev.SLib.nprocs()))
            end
        else
            write(k == 1 ? r_stdout() : r_stderr(), b)
        end
    end
    flush(stdout); flush(stderr)
    nothing
end

"""Kern-Threads der laufenden `par_lapply`-Aufgabe (seit 1.6.4, Entscheidung 41c): Zahl der Prozessoren ÷ Zahl der
parallelen Aufgaben, mindestens 1; außerhalb `nothing` (R `.sl_state\$thread_cap`)."""
thread_cap() = _tls_get(_CAP_KEY, nothing)

# ── Einheit ───────────────────────────────────────

"`FUN(x)` als parallele Einheit: der globale Zufallszustand von SimLev ist darin gesperrt."
_unit(FUN, x) = SimLev.SLib.in_unit(() -> FUN(x))

# ── par_lapply ───────────────────────────────────────────────────────────

"`as.integer(mc.cores)` für `cores > 1` (R schneidet ab)."
_ncores(cores) = cores isa Integer ? Int(cores) : unsafe_trunc(Int, Float64(cores))

"""
    par_lapply(X, FUN, cores = 1)

R: `.par_lapply(X, FUN, cores)`; Ergebnis `Vector{Any}` in der Reihenfolge
von `X`. Parallel mit `Threads.@spawn`, wenn `Threads.nthreads() > 1`. Eine feste Zahl ≥ 2 verteilt seit 1.6.4
(Entscheidung 133) über denselben Weg wie `cores = "auto"` (`_threaded` mit Mitschnitt der Warnungen), nur ohne
Messung: min(cores, Elemente, Threads) Aufgaben; Ausgaben, Meldungen, Warnungen und Fehler wie `cores = 1`. Mit einem
Thread nacheinander wie `cores = 1` (bis dahin `_sequential`: Warnungen verworfen). Im Paket K42 PAR rechnete
`"auto"` die Studien nacheinander (Schlüsselwort `tasks = false`, entfallen mit K43 T2-R1/T2-R9).
"""
function par_lapply(X, FUN, cores = 1)
    xs = collect(X)
    cores isa AbstractString && cores == "auto" && return _auto(xs, FUN)   # seit 1.6.4: Planer
    (cores === nothing || cores <= 1 || length(xs) <= 1) && return Any[_unit(FUN, x) for x in xs]
    n = min(_ncores(cores), length(xs))
    n < 2 && return Any[_unit(FUN, x) for x in xs]   # mclapply: cores < 2 -> lapply
    nt = Threads.nthreads()
    if nt < 2
        _PRECOMPILE_THREADED[] || return Any[_unit(FUN, x) for x in xs]
        return _threaded(xs, FUN, min(n, 2))   # nur in der Arbeitslast beim Vorkompilieren (seit 1.6.3)
    end
    return _threaded(xs, FUN, min(n, nt))
end

"Nur für die Vorkompilier-Arbeitslast (precompile.jl): `_threaded` auch mit einem Thread übersetzen (J4, seit 1.6.3)."
const _PRECOMPILE_THREADED = Ref(false)

"""
    _auto(xs, FUN)

`cores = "auto"` (seit 1.6.4, Entscheidungen 41b/41c; wie R `.par_lapply_auto`). Ergebnis, Ausgaben, Warnungen und
Fehler wie `cores = 1`:
* Messen: die ersten Elemente laufen nacheinander in der aufrufenden Aufgabe, bis die Startzeit eines weiteren Laufs
  (`SLib.par_probe`) vergangen ist (mindestens zwei Elemente); Rechenzeit je Element = Mittel ohne das erste
  (Übersetzung, Anlaufkosten), bei nur einem Element dessen Zeit.
* Planen: `SLib.par_plan` (Kern `sl_par_plan`) wählt Aufgaben c (höchstens `Threads.nthreads()`) und Kern-Threads je
  Aufgabe; c = 1: der Rest nacheinander.
* Verteilen (c > 1): `_threaded` mit Mitschnitt der Warnungen (`_RecLogger`) und des Hinweises zu SIMLEV_THREADS; die
  Wiedergabe in Elementreihenfolge gibt Warnungen an den Logger der aufrufenden Aufgabe.
* Mit einem Thread (`julia` ohne `-t`) oder einem Prozessor: nacheinander.
* Im Paket K42 PAR rechneten die Studien hier nacheinander (`tasks = false`), weil mit mehreren Aufgaben
  gelegentlich das Ergebnis einer Einheit abwich; die Ursachen sind seit K43 KR behoben (T2-R1 `local res` in
  `bootstrap_study`, T2-B3 Formatierpuffer je Thread, T2-B7 Sperre in `planning_lumpsum_vs_dca`), seitdem verteilt
  `"auto"` überall (Entscheidung 134).
"""
function _auto(xs, FUN)
    n = length(xs)
    _PAR_LAST[] = (n, 1, 0)             # letzter Plan (gemessene Elemente, Aufgaben, Threads; intern, für Proben)
    (n <= 1 || Threads.nthreads() < 2 || SimLev.SLib.nprocs() < 2) && return Any[_unit(FUN, x) for x in xs]
    probe = SimLev.SLib.par_probe(2)
    res = Any[]
    k = 0; t_first = 0.0; t_rest = 0.0
    while true
        t0 = time_ns()
        push!(res, _unit(FUN, xs[k+1]))
        dt = (time_ns() - t0) / 1e9
        k += 1
        k == 1 ? (t_first = dt) : (t_rest += dt)
        (k >= n || (k >= 2 && t_first + t_rest >= probe)) && break
    end
    k >= n && return res
    u = k >= 2 ? t_rest / (k - 1) : t_first
    c, cap = SimLev.SLib.par_plan(n - k, u, 0.0; sys = 2, max_runs = Threads.nthreads())
    _PAR_LAST[] = (k, c, cap)
    rest = xs[k+1:n]
    if c < 2
        for x in rest
            push!(res, _unit(FUN, x))
        end
        return res
    end
    append!(res, _threaded(rest, FUN, c; cap = cap))
    return res
end

"""Elemente auf `n` Aufgaben (`Threads.@spawn`), dynamisch zugeteilt; Wiedergabe in Elementreihenfolge. Seit 1.6.4 für
`"auto"` und feste Zahlen gleich (Entscheidung 133): Warnungen über `_RecLogger` mitgeschnitten und an den Logger der
aufrufenden Aufgabe weitergegeben, der Hinweis zu SIMLEV_THREADS zurückgestellt (`defer_hint`); bis dahin verwarf eine
feste Zahl die Warnungen (`NullLogger`, Schlüsselwort `record`). `cap`: Kern-Threads je Aufgabe (Plan von `"auto"`),
sonst Prozessoren ÷ n."""
function _threaded(xs, FUN, n::Int; cap::Union{Nothing,Int} = nothing)
    nx = length(xs)
    res = Vector{Any}(undef, nx)
    caps = Vector{Capture}(undef, nx)
    status = zeros(Int, nx)             # 0 offen, 1 fertig, 2 Fehler
    next = Threads.Atomic{Int}(1)
    stop = Threads.Atomic{Int}(nx + 1)  # kleinster Index mit Fehler
    done = Channel{Int}(nx)
    # Hinweis zu SIMLEV_THREADS höchstens einmal je Sitzung, bei der Wiedergabe an der Stelle wie nacheinander
    # Kern-Threads je Aufgabe (seit 1.6.4, Entscheidung 41c; cores = "auto": aus dem Plan)
    tcap = cap === nothing ? max(1, SimLev.SLib.nprocs() ÷ n) : cap
    parent_logger = Base.CoreLogging.current_logger()
    function work()
        task_local_storage(_CAP_KEY, tcap)
        task_local_storage(_REC_KEY, true)
        while true
            i = Threads.atomic_add!(next, 1)
            (i > nx || i >= stop[]) && break
            capture = Capture()         # seit 1.6.4 eigener Name (bis dahin überschrieb er die Thread-Grenze)
            lg = _RecLogger(capture, parent_logger)
            try
                res[i] = task_local_storage(_OUT_KEY, capture) do
                    with_logger(() -> _unit(FUN, xs[i]), lg)
                end
                status[i] = 1
            catch e
                res[i] = e
                status[i] = 2
                Threads.atomic_min!(stop, i)
            end
            caps[i] = capture
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
    catch e
        # Strg-C (seit 1.6.4, K43 T2-R6): keine neuen Einheiten mehr; laufende enden nach ihrem Aufruf, dann erneut
        # auslösen (bis dahin rechneten die Aufgaben alle restlichen Einheiten, bevor der Abbruch ankam). Jede Ausnahme
        # beim Warten bricht ab: trifft Strg-C das Warten in take!, kommt sie auch als Fehler der Sperre des Channels
        # ("unlock count must match lock count") an
        Threads.atomic_min!(stop, 0)
        rethrow()
    finally
        foreach(wait, tasks)
        close(done)
    end
    err === nothing || throw(err)
    return res
end

end # module

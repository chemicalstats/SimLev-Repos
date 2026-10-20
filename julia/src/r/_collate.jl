# ─────────────────────────────────────────────────────────────────────────────
# Zeichenketten-Kollation wie R 4.3.3 (`Scollate` in src/main/util.c),
# eingebunden in RStats. Vorlage: python/simlev/_r/_collate.py.
#
# R vergleicht und sortiert Zeichenketten (sort, order, rank, factor-Stufen,
# table, split, `<`/`>`, min/max) mit `Scollate`:
# * Ist LC_ALL (oder, wenn leer, LC_COLLATE) "C", oder ist das
#   Kollations-Locale "C"/"POSIX" (R_ICU_LOCALE, sonst das Locale aus
#   LC_ALL/LC_COLLATE/LANG), nimmt R strcoll im C-Locale = UTF-8-Bytes.
# * Sonst öffnet R über ICU `uloc_setDefault(<locale>)` + `ucol_open(NULL)`
#   einen Collator ohne weitere Attribute und vergleicht mit
#   `ucol_strcollIter` (UTF-8). Unter LC_ALL=C.UTF-8 ist das "root"
#   (icuGetCollate()): a A b B.
# Hier dasselbe per ccall auf die System-ICU (libicui18n.so.<N>, Funktionen
# mit Versionssuffix _<N>, automatisch ermittelt; Pfad über $SIMLEV_ICU).
# SIMLEV_COLLATE=C erzwingt die Byte-Reihenfolge (wie R unter LC_ALL=C),
# SIMLEV_COLLATE=icu:root die ICU-Kollation "root" (wie R unter C.UTF-8) unabhängig vom Locale.
# Ohne ICU: Codepunkte (= UTF-8-Bytes) mit einmaliger Warnung, nicht bitgleich.
# ─────────────────────────────────────────────────────────────────────────────

mutable struct _CollState
    init::Bool
    mode::Symbol            # :icu, :bytes, :codepoint
    coll::Ptr{Cvoid}
    f_cmp8::Ptr{Cvoid}      # ucol_strcollUTF8 (oder C_NULL)
    f_cmp16::Ptr{Cvoid}     # ucol_strcoll
    f_key::Ptr{Cvoid}       # ucol_getSortKey
    f_loc::Ptr{Cvoid}       # ucol_getLocaleByType
    f_close::Ptr{Cvoid}
    warned::Bool
end

const _COLL = _CollState(false, :bytes, C_NULL, C_NULL, C_NULL, C_NULL, C_NULL, C_NULL, false)

function _env_collate_locale()
    sc = get(ENV, "SIMLEV_COLLATE", "")
    # ICU mit festem Locale, unabhängig von LC_ALL (z. B. "icu:root" wie R unter C.UTF-8)
    startswith(lowercase(sc), "icu:") && return false, (length(sc) > 4 ? sc[5:end] : "root")
    envl = get(ENV, "LC_ALL", "")
    isempty(envl) && (envl = get(ENV, "LC_COLLATE", ""))
    use_c = envl == "C"
    p = get(ENV, "R_ICU_LOCALE", "")
    isempty(p) || return use_c, p
    loc = ""
    for v in ("LC_ALL", "LC_COLLATE", "LANG")
        loc = get(ENV, v, "")
        isempty(loc) || break
    end
    return use_c, isempty(loc) ? "C" : loc
end

function _icu_candidates()
    cands = String[]
    env = get(ENV, "SIMLEV_ICU", "")
    isempty(env) || push!(cands, env)
    for d in ("/usr/lib/x86_64-linux-gnu", "/lib/x86_64-linux-gnu", "/usr/lib/aarch64-linux-gnu",
              "/usr/lib64", "/usr/lib", "/usr/local/lib", "/opt/homebrew/opt/icu4c/lib", "/usr/local/opt/icu4c/lib")
        isdir(d) || continue
        hits = Tuple{Int,String}[]
        for f in readdir(d)
            m = match(r"^libicui18n\.(?:so\.(\d+)|(\d+)\.dylib)$", f)
            m === nothing && continue
            push!(hits, (parse(Int, something(m.captures[1], m.captures[2])), joinpath(d, f)))
        end
        sort!(hits; by = h -> -h[1])
        append!(cands, last.(hits))
    end
    push!(cands, "libicui18n")
    return env, cands
end

function _icu_suffix(h, path::AbstractString)
    sufs = String[]
    m = match(r"libicui18n\.(?:so\.)?(\d+)", basename(path))
    m === nothing || push!(sufs, "_" * m.captures[1])
    push!(sufs, "")
    append!(sufs, ["_$v" for v in 99:-1:40])
    for s in sufs
        Libc.Libdl.dlsym(h, Symbol("ucol_open" * s); throw_error = false) === nothing || return s
    end
    return nothing
end

_sym(h, nm, suf) = something(Libc.Libdl.dlsym(h, Symbol(nm * suf); throw_error = false), C_NULL)

function _collate_init!()
    S = _COLL
    S.init && return S
    S.init = true
    S.mode = :bytes
    sc = uppercase(get(ENV, "SIMLEV_COLLATE", ""))
    sc in ("C", "POSIX", "BYTES") && return S
    use_c, loc = _env_collate_locale()
    (use_c || loc in ("C", "POSIX")) && return S
    env, cands = _icu_candidates()
    for c in cands
        h = Libc.Libdl.dlopen(c, Libc.Libdl.RTLD_LAZY | Libc.Libdl.RTLD_LOCAL; throw_error = false)
        suf = h === nothing ? nothing : _icu_suffix(h, c)
        if suf === nothing
            if !isempty(env) && c == env
                @warn "SIMLEV_ICU=$env: keine ICU-Bibliothek (libicui18n) mit ucol_open ladbar; suche die System-ICU."
            end
            continue
        end
        f_open = _sym(h, "ucol_open", suf)
        f_def = _sym(h, "uloc_setDefault", suf)
        f_cmp8 = _sym(h, "ucol_strcollUTF8", suf)
        f_cmp16 = _sym(h, "ucol_strcoll", suf)
        (f_open == C_NULL || f_def == C_NULL || (f_cmp8 == C_NULL && f_cmp16 == C_NULL)) && continue
        st = Ref{Cint}(0)
        ccall(f_def, Cvoid, (Cstring, Ref{Cint}), loc, st)
        st[] > 0 && error("failed to set ICU locale ($(st[]))")
        coll = ccall(f_open, Ptr{Cvoid}, (Ptr{UInt8}, Ref{Cint}), C_NULL, st)
        (st[] > 0 || coll == C_NULL) && error("failed to open ICU collator ($(st[]))")
        S.coll = coll
        S.f_cmp8 = f_cmp8
        S.f_cmp16 = f_cmp16
        S.f_key = _sym(h, "ucol_getSortKey", suf)
        S.f_loc = _sym(h, "ucol_getLocaleByType", suf)
        S.f_close = _sym(h, "ucol_close", suf)
        S.mode = :icu
        return S
    end
    S.mode = :codepoint
    return S
end

"Liest SIMLEV_COLLATE/SIMLEV_ICU/Locale-Variablen beim nächsten Vergleich neu ein."
function collate_reset()
    S = _COLL
    if S.init && S.coll != C_NULL && S.f_close != C_NULL
        ccall(S.f_close, Cvoid, (Ptr{Cvoid},), S.coll)
    end
    S.init = false; S.mode = :bytes; S.coll = C_NULL; S.warned = false
    S.f_cmp8 = S.f_cmp16 = S.f_key = S.f_loc = S.f_close = C_NULL
    return nothing
end

"Kollationsweg: :icu (wie R), :bytes (C-Locale) oder :codepoint (Ersatzweg ohne ICU)."
collate_mode() = _collate_init!().mode

"Locale des ICU-Collators (wie `icuGetCollate()`), sonst `nothing`."
function collate_locale()
    S = _collate_init!()
    (S.mode !== :icu || S.f_loc == C_NULL) && return nothing
    st = Ref{Cint}(0)
    p = ccall(S.f_loc, Cstring, (Ptr{Cvoid}, Cint, Ref{Cint}), S.coll, 0, st)
    return p == C_NULL ? nothing : unsafe_string(p)
end

function _warn_cp(S)
    if !S.warned
        S.warned = true
        @warn "Zeichenketten-Kollation: keine ICU-Bibliothek (libicui18n) gefunden, Vergleich nach Codepunkten (nicht bitgleich zu R; Pfad über SIMLEV_ICU setzen, SIMLEV_COLLATE=C für Byte-Reihenfolge)."
    end
end

_bytecmp(a::AbstractString, b::AbstractString) = (c = cmp(String(a), String(b)); c < 0 ? -1 : c > 0 ? 1 : 0)

"""
    str_collate(a, b) -> Int

Vergleich zweier Zeichenketten wie R's `Scollate`: -1, 0 oder 1 (ICU-Collator
wie R; unter `SIMLEV_COLLATE=C` bzw. `LC_ALL=C` UTF-8-Bytes; ohne ICU
Codepunkte mit einmaliger Warnung).
"""
function str_collate(a::AbstractString, b::AbstractString)
    S = _collate_init!()
    if S.mode === :icu
        sa = String(a); sb = String(b)
        if S.f_cmp8 != C_NULL
            st = Ref{Cint}(0)
            r = ccall(S.f_cmp8, Cint, (Ptr{Cvoid}, Ptr{UInt8}, Cint, Ptr{UInt8}, Cint, Ref{Cint}),
                      S.coll, sa, sizeof(sa), sb, sizeof(sb), st)
            st[] > 0 && error("could not collate using ICU")
            return Int(r)
        end
        ua = transcode(UInt16, sa); ub = transcode(UInt16, sb)
        return Int(ccall(S.f_cmp16, Cint, (Ptr{Cvoid}, Ptr{UInt16}, Cint, Ptr{UInt16}, Cint),
                         S.coll, ua, length(ua), ub, length(ub)))
    end
    S.mode === :codepoint && _warn_cp(S)
    return _bytecmp(a, b)
end

"""
    collate_key(s) -> Vector{UInt8}

Sortierschlüssel: `collate_key(a) < collate_key(b)` genau dann, wenn
`str_collate(a, b) < 0` (Gleichheit ebenso).
"""
function collate_key(s::AbstractString)
    S = _collate_init!()
    ss = String(s)
    if S.mode === :icu && S.f_key != C_NULL
        u = transcode(UInt16, ss)
        size = 64 + 4 * length(u)
        while true
            buf = Vector{UInt8}(undef, size)
            need = Int(ccall(S.f_key, Cint, (Ptr{Cvoid}, Ptr{UInt16}, Cint, Ptr{UInt8}, Cint),
                             S.coll, u, length(u), buf, size))
            need <= size && return buf[1:max(need - 1, 0)]
            size = need
        end
    end
    S.mode === :codepoint && _warn_cp(S)
    S.mode === :icu && error("ucol_getSortKey nicht verfügbar")
    return Vector{UInt8}(codeunits(ss))
end

"`lt`-Funktion für `sort`/`sortperm` auf Zeichenketten nach R's Kollation."
str_lt(a, b) = str_collate(a, b) < 0

"""
    r_isless(a, b)

`isless` mit R's Reihenfolge: Zeichenketten über [`str_collate`](@ref), alles
andere wie `isless` (für `sort(...; lt = r_isless)` von Faktorstufen u. Ä.).
"""
r_isless(a::AbstractString, b::AbstractString) = str_collate(a, b) < 0
r_isless(a, b) = isless(a, b)

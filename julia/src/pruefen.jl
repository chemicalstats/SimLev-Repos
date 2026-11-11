# ─────────────────────────────────────────────────────────────────────────────
# Einheitliche Eingabeprüfung (seit 1.6.4, Entscheidung 05.11.2026; Gegenstück zu r/R/pruefen.R)
#
# Prüfhilfen für die öffentlichen Funktionen: vorhanden, richtiger Typ, plausibler Wertebereich. Bei einem
# Verstoß bricht die Hilfe mit dem Text aus der Tabelle `eingabe` ab (core/meldungen.tsv, `_MELD_EINGABE` in
# meldungen.jl): deutsch, "<funktion>: <argument> muss …", in R, Python und Julia zeichengleich (der Eingabewert
# steht nicht im Text); Fehler wie die übrigen Meldungen mit `error()`. Gegenstücke mit gleichen Namen und gleicher
# Semantik: r/R/pruefen.R, python/simlev/_pruefen.py.
#
# Regeln (wie R, auch wo R selbst still annimmt; Entscheidungen des Nutzers vom 05.11.2026):
# - Länge 1: Vektoren und Tupel der Länge 1 zählen wie Einzelwerte (R: c(TRUE) ist TRUE); die Hilfen geben den
#   Einzelwert zurück (`chk_scalar`).
# - Zahl: `Real` außer `Bool` (kein Text, kein `missing`), ein Wert, nicht NaN, endlich; ganze Zahl zusätzlich
#   x == trunc(x) (2 und 2.0 sind ganz, 2.5 nicht).
# - Wahrheitswert: nur `Bool`; keine Zahl, kein Text "FALSE", nie `nothing` (wer den Standard will, lässt das
#   Argument weg).
# - Text: `AbstractString`; Leerraum (auch Unicode) wird nicht abgeschnitten.
# - Datum: `Date`, `DateTime` oder Text, den as.Date liest; keine Zahl.
# - Tabelle: nur `RFrame` (wie R data.frame); die Meldung sagt, wie man umwandelt.
# - Signalspalte: Wahrheitswerte oder Zahlen 0/1, NA erlaubt; andere Zahlen (2, 0.5) nicht.
# - `nothing` (R NULL) nur, wo null_ok = true (nie bei Wahrheitswerten); `missing` gilt als NA.
# - Meldungen nennen den Eingabewert nicht (nur Funktion, Argument, Spalten- bzw. Asset-Namen und Grenzen).
# - Kategorie (R-Faktor, `RFactor`): weder als Argument noch als Spalte (`chk_nofactor`, `chk_col_nofactor`).
# - Ganze Zahl: nie abschneiden, 2.5 ist ein Fehler (Entscheidung 19); Obergrenzen mit `chk_max` (16, 36) und den
#   gemeinsamen Werten `SL_MAX_*` (Laufzeiten 100 Jahre, Entscheidung 46); Jahre mit `chk_jahre` (47).
# - Namen eigener Kennzahlen eindeutig, nicht leer, keine feste Spalte (`chk_kennzahlen`; Entscheidungen 28 und 43).
# - NA in Basiszins- und CAPE-Reihen ist ein Fehler (`chk_col_nona`, `chk_nona`; Entscheidung 17).
# - Zahl aus Text nur mit ASCII-Zeichen (`chk_as_num`; Entscheidung 27).
# - Unbekannte und doppelte Schlüsselwort-Argumente vor dem Aufruf melden (`chk_dots`; Entscheidung 21).
# ─────────────────────────────────────────────────────────────────────────────

"Text der Tabelle eingabe (nur `%s`-Platzhalter, der Reihe nach ersetzt)."
function chk_msg(key::AbstractString, args...)
    parts = split(_MELD_EINGABE[key], "%s")
    length(parts) == length(args) + 1 || error("chk_msg: Vorlage '$key' erwartet $(length(parts) - 1) Werte")
    io = IOBuffer()
    for (i, p) in enumerate(parts)
        print(io, p)
        i <= length(args) && print(io, args[i])
    end
    return String(take!(io))
end

"Abbruch mit einem Text der Tabelle eingabe."
chk_stop(key::AbstractString, args...) = error(chk_msg(key, args...))

"Zahl in einer Meldung wie `format(x, digits = 15)`."
chk_fmt(x) = r_format1(Float64(x); digits = 15)
chk_fmt(x::Union{Signed,Unsigned}) = r_format1(x; digits = 15)   # ganze Zahlen wie R-integer (Entscheidung 63)

"Bereichstext wie R `chk_range_text` (z. B. \"> 0\", \"≥ 0 und ≤ 1\")."
function chk_range_text(lo = nothing, hi = nothing, lo_open::Bool = false, hi_open::Bool = false)
    p = String[]
    lo === nothing || push!(p, chk_msg(lo_open ? "bereich.gt" : "bereich.ge", chk_fmt(lo)))
    hi === nothing || push!(p, chk_msg(hi_open ? "bereich.lt" : "bereich.le", chk_fmt(hi)))
    return length(p) == 2 ? chk_msg("bereich.und", p[1], p[2]) : (isempty(p) ? "" : p[1])
end

"Vektor oder Tupel der Länge 1 als Einzelwert (R: `c(x)` ist `x`); alles andere (auch Text) unverändert."
chk_scalar(@nospecialize(x)) = (x isa Union{AbstractArray,Tuple} && length(x) == 1) ? first(x) : x

_chk_numscalar(@nospecialize(x)) = x isa Real && !(x isa Bool)
_chk_finite(@nospecialize(x)) = _chk_numscalar(x) && isfinite(Float64(x))

"Einzelne endliche Zahl, optional im Bereich [lo, hi] (lo_open/hi_open: Grenze ausgeschlossen)."
function chk_num1(@nospecialize(x), fn, arg; lo = nothing, hi = nothing, lo_open::Bool = false, hi_open::Bool = false,
                  null_ok::Bool = false)
    x = chk_scalar(x)
    x === nothing && null_ok && return x
    ok = _chk_finite(x)
    rng = lo !== nothing || hi !== nothing
    if ok && rng
        v = Float64(x)
        ok = (lo === nothing || (lo_open ? v > lo : v >= lo)) && (hi === nothing || (hi_open ? v < hi : v <= hi))
    end
    if !ok
        rng && chk_stop("zahl_bereich", fn, arg, chk_range_text(lo, hi, lo_open, hi_open))
        chk_stop("zahl", fn, arg)
    end
    return x
end

"Wahrscheinlichkeit bzw. Anteil in [0, 1]."
chk_prob(@nospecialize(x), fn, arg; null_ok::Bool = false) = chk_num1(x, fn, arg; lo = 0, hi = 1, null_ok = null_ok)

"""Einzelne ganze Zahl ≥ lo (2 und 2.0 sind ganz, 2.5 nicht; nie abgeschnitten); mit `hi`: von lo bis hi (Meldung
ganz_bis)."""
function chk_int1(@nospecialize(x), fn, arg; lo = 1, null_ok::Bool = false, hi = nothing)
    x = chk_scalar(x)
    x === nothing && null_ok && return x
    ok = _chk_finite(x) && Float64(x) == trunc(Float64(x)) && Float64(x) >= lo
    if hi !== nothing
        (ok && Float64(x) <= hi) || chk_stop("ganz_bis", fn, arg, chk_fmt(lo), chk_fmt(hi))
    else
        ok || chk_stop("ganz", fn, arg, chk_fmt(lo))
    end
    return x
end

_chk_vals(@nospecialize(x)) = x isa NamedTuple ? collect(values(x)) : x isa AbstractDict ? collect(values(x)) :
    x isa AbstractVector{<:Pair} ? [p.second for p in x] : x isa Union{AbstractArray,Tuple} ? vec(collect(x)) : Any[x]

"Vektor ganzer Zahlen ≥ lo (ohne NA; nie abgeschnitten; R `chk_intvec`)."
function chk_intvec(@nospecialize(x), fn, arg; lo = 1)
    vals = _chk_vals(x)
    (!isempty(vals) && all(v -> _chk_finite(v) && Float64(v) == trunc(Float64(v)) && Float64(v) >= lo, vals)) ||
        chk_stop("ganz_vektor", fn, arg, chk_range_text(lo))
    return x
end

"""Zahl der Prozesse (seit 1.6.4, Entscheidung 41b): `"auto"` (Standard seit 1.6.4: Planer in `RParallel.par_lapply`)
oder ganze Zahl ≥ 1 (sonst Fehler mit Meldung `par.cores`, Entscheidung 113); mehr als die Zahl der Prozessoren (`SLib.nprocs`) wird mit
einem Hinweis begrenzt (R `chk_cores`). Ergebnis: `"auto"` bzw. die Zahl."""
function chk_cores(@nospecialize(cores), fn, arg = "cores")
    v = chk_scalar(cores)
    v isa AbstractString && v == "auto" && return "auto"
    (_chk_finite(v) && Float64(v) == trunc(Float64(v)) && Float64(v) >= 1) ||
        chk_stop("par.cores", fn, arg)       # seit 1.6.4 (Entscheidung 113; vorher Meldung ganz)
    cores = v
    mx = SLib.nprocs()
    if cores > mx
        println(RParallel.r_stderr(), chk_msg("hinweis.prozessoren", string(fn, ": ", arg), mx))
        cores = mx
    end
    return cores
end

"""Obergrenze (seit 1.6.4, Entscheidungen 16 und 36): Zahl bzw. alle Werte ≤ hi; `nothing`, Text und NA prüft der
Aufrufer vorher. Die Grenze steht als ganze Zahl ohne Exponent in der Meldung (R `chk_max`)."""
function chk_max(@nospecialize(x), hi, fn, arg)
    any(v -> _chk_numscalar(v) && !isnan(Float64(v)) && Float64(v) > hi, _chk_vals(chk_scalar(x))) &&
        chk_stop("obergrenze", fn, arg, @sprintf("%.0f", hi))
    return x
end

# Gemeinsame Obergrenzen (seit 1.6.4; Entscheidung 46 ersetzt die 1 000 Jahre aus 16 und 36 durch 100 Jahre; gleiche
# Namen und Werte in r/R/pruefen.R und python/simlev/_pruefen.py, für alle Bereiche)
const SL_MAX_JAHRE = 100        # Laufzeiten in Jahren (years, max_years, horizon in Jahren)
const SL_MAX_TAGE = 36600       # Laufzeiten in Tagen bzw. Tagesperioden (path_length, planning_goal(horizon)): 100 Jahre
const SL_MAX_MONATE = 1200      # Laufzeiten in Monaten (planning_lumpsum_vs_dca(months)): 100 Jahre
const SL_MAX_N = 1e8            # Anzahlen (n, n_sim, B)
const SL_MAX_GITTER = 1e6       # Gitterpunkte (n_grid)

"""Laufzeit in ganzen Jahren (seit 1.6.4, Entscheidungen 19, 46 und 47): ganze Zahl ≥ 1 (Meldung ganz) und höchstens
`SL_MAX_JAHRE` (Meldung obergrenze); auch bei unterjähriger `frequency` nur ganze Jahre (R `chk_jahre`). Ergebnis:
der Einzelwert."""
function chk_jahre(@nospecialize(x), fn, arg; null_ok::Bool = false)
    x = chk_scalar(x)
    x === nothing && null_ok && return x
    x = chk_int1(x, fn, arg)
    chk_max(x, SL_MAX_JAHRE, fn, arg)
    return x
end

"Aufzählung \"a, b oder c\" (Namen in Meldungen; R `chk_oder`)."
function chk_oder(x)
    v = String[string(e) for e in x]
    length(v) <= 1 && return join(v)
    return string(join(v[1:end-1], ", "), " oder ", v[end])
end

"""Namen eigener Kennzahlen (seit 1.6.4, Entscheidungen 28 und 43): `nm` = Namen des Ergebnisses von `metrics()`
(`nothing` oder weniger Namen als Werte = unbenannt), `n` = seine Länge; bei `n > 0` Fehler, wenn unbenannt, ein Name
leer, doppelt oder gleich einer festen Spalte der Ergebnistabelle (`fixed`) ist (R `chk_kennzahlen`)."""
function chk_kennzahlen(nm, n::Integer, fixed, fn)
    if n > 0
        bad = nm === nothing || length(nm) != n || any(k -> !(k isa AbstractString) || isempty(k), nm) ||
              length(unique(nm)) != length(nm) || any(k -> k in fixed, nm)
        bad && chk_stop("n2.kennzahl_namen", fn, chk_oder(fixed))
    end
    return nm
end

"Einzelner Wahrheitswert true/false (nur `Bool`; `nothing` ist ein Fehler)."
function chk_bool1(@nospecialize(x), fn, arg)
    x = chk_scalar(x)
    x isa Bool || chk_stop("wahr", fn, arg)
    return x
end

"Einzelner Text (leer erlaubt)."
function chk_text1(@nospecialize(x), fn, arg; null_ok::Bool = false)
    x = chk_scalar(x)
    x === nothing && null_ok && return x
    x isa AbstractString || chk_stop("text", fn, arg)
    return x
end

"Einzelner, nicht leerer Name (z. B. Spalten- oder Asset-Name)."
function chk_name1(@nospecialize(x), fn, arg; null_ok::Bool = false)
    x = chk_scalar(x)
    x === nothing && null_ok && return x
    (x isa AbstractString && !isempty(x)) || chk_stop("name", fn, arg)
    return x
end

"Einer von mehreren Texten (ohne Teilübereinstimmung)."
function chk_choice(@nospecialize(x), fn, arg, choices; null_ok::Bool = false)
    x = chk_scalar(x)
    x === nothing && null_ok && return x
    (x isa AbstractString && x in choices) || chk_stop("auswahl", fn, arg, join(("\"$c\"" for c in choices), ", "))
    return x
end

"Einzelnes Datum (Date, DateTime oder Text wie as.Date); Ergebnis als `Date`."
function chk_date1(@nospecialize(x), fn, arg; null_ok::Bool = false)
    x = chk_scalar(x)
    x === nothing && null_ok && return x
    z = x isa Union{AbstractString,Date,DateTime} ? _as_date(x) : nothing
    z === nothing && chk_stop("datum", fn, arg)
    return from_days(z)
end

"Numerischer Vektor (mindestens eine Zahl; `missing`/NaN als NA erlaubt; benannt als NamedTuple/Dict/Paare)."
function chk_numvec(@nospecialize(x), fn, arg; null_ok::Bool = false)
    x === nothing && null_ok && return x
    vals = x isa NamedTuple ? collect(values(x)) : x isa AbstractDict ? collect(values(x)) :
           x isa AbstractVector{<:Pair} ? [p.second for p in x] : x isa Union{AbstractVector,Tuple} ? collect(x) : Any[x]
    isna(v) = v === missing || (v isa AbstractFloat && isnan(v))
    ok = !isempty(vals) && all(v -> _chk_numscalar(v) || isna(v), vals) && any(_chk_numscalar, vals)
    ok || chk_stop("zahlen", fn, arg)
    return x
end

"Länge n."
function chk_len(@nospecialize(x), n, fn, arg)
    (x === nothing ? 0 : length(x)) == n || chk_stop("laenge", fn, arg, chk_fmt(n))
    return x
end

"""Nur Tabelle: `RFrame` (wie R data.frame; seit E0b kein NamedTuple, Dict oder Paar-Vektor mehr); die Meldung
nennt die Umwandlung. Der interne Rahmen `_Frame` (Aufrufe innerhalb von SimLev) gilt als Tabelle."""
function chk_df(@nospecialize(x), fn, arg; null_ok::Bool = false)
    x === nothing && null_ok && return x
    (x isa RFrame || x isa _Frame) || chk_stop("tabelle", fn, arg, chk_msg("tabelle.formen"))
    return x
end

_chk_names(@nospecialize(data)) = data isa _Frame ? data.names : data isa RFrame ? names(data) :
    data isa NamedTuple ? [String(k) for k in keys(data)] : data isa AbstractDict ? [String(string(k)) for k in keys(data)] :
    [String(string(p.first)) for p in data]

"Spalten vorhanden (Meldung nennt die fehlenden in der gegebenen Reihenfolge)."
function chk_cols(@nospecialize(data), cols, fn)
    nms = _chk_names(data)
    miss = String[]
    for c in cols
        (c in nms || c in miss) || push!(miss, String(c))
    end
    isempty(miss) || chk_stop("spalten", fn, join(("'$c'" for c in miss), ", "))
    return data
end

"Spaltentyp \"numerisch\" (Zahlen), \"logisch\" (Wahrheitswerte) oder \"logisch_oder_numerisch\" wie R."
function chk_col_type(@nospecialize(data), col, fn, type::AbstractString = "numerisch")
    fr = data isa _Frame ? data : _to_frame(data)
    k = get(fr.kinds, col, :none)
    (type == "logisch" ? k == :logical : type == "numerisch" ? k == :numeric : k in (:logical, :numeric)) || chk_stop("spalte_typ", fn, col, chk_msg("typ." * type))
    return data
end

"Keine Kategorie (R-Faktor, `RFactor`) als Argument (Entscheidungen 15 und 22; R `chk_nofactor`)."
function chk_nofactor(@nospecialize(x), fn, arg)
    x isa RFmt.RFactor && chk_stop("faktor", fn, arg)
    return x
end

"Spalte kein Faktor (R rechnete sonst mit den Codes)."
function chk_col_nofactor(@nospecialize(data), col, fn)
    fr = data isa _Frame ? data : _to_frame(data)
    get(fr.kinds, col, :none) == :factor && chk_stop("spalte_faktor", fn, col)
    return data
end

"""Signalspalte: Wahrheitswerte (mit NA) oder Zahlen 0/1 (NaN/missing als NA erlaubt); andere Zahlen (2, 0.5), Text,
Faktor und Datum nicht (R `chk_col_signal`)."""
function chk_col_signal(@nospecialize(data), col, fn)
    fr = data isa _Frame ? data : _to_frame(data)
    k = get(fr.kinds, col, :none)
    ok = k == :logical
    if k == :numeric
        ok = all(v -> v === missing || isnan(Float64(v)) || v == 0 || v == 1, fr.cols[col])
    end
    ok || chk_stop("spalte_signal", fn, col)
    return data
end

_chk_isna(@nospecialize(v)) = v === missing || v === nothing || (v isa AbstractFloat && isnan(v))

"""Spalte ohne NA (seit 1.6.4, Entscheidung 17: Basiszins- und CAPE-Reihen); `hint` aus der Tabelle eingabe (z. B.
`chk_msg("hinweis.basiszins")`) oder ""."""
function chk_col_nona(@nospecialize(data), col, fn, hint = "")
    fr = data isa _Frame ? data : _to_frame(data)
    any(_chk_isna, fr.cols[col]) && chk_stop("spalte_na", fn, col, hint)
    return data
end

"Werte ohne NA (Vektor oder Matrix; Entscheidung 17)."
function chk_nona(@nospecialize(x), fn, arg, hint = "")
    any(_chk_isna, _chk_vals(x)) && chk_stop("na", fn, arg, hint)
    return x
end

"""Zahl aus Text wie R `as.numeric()` (NA bei ungültigem Text), aber nur mit ASCII-Zeichen (Ziffern, Vorzeichen,
Punkt, Exponent, ASCII-Leerraum); andere Zeichen (z. B. U+00A0, fremde Ziffern) ergeben NA (Entscheidung 27; R
`chk_as_num`)."""
chk_as_num(s::AbstractString) = isascii(s) ? r_as_numeric(s) : NA
chk_as_num(::Missing) = NA

"""Argumente aus Schlüsselwörtern (seit 1.6.4, Entscheidung 21): Namen müssen in `allowed` stehen (sonst
„unbekanntes Argument“) und dürfen nicht in `taken` (vom Aufrufer selbst gesetzt) vorkommen (sonst „doppeltes
Argument“); R `chk_dots`."""
function chk_dots(nm, allowed, fn; taken = String[])
    nms = String[string(k) for k in nm if string(k) != ""]
    for k in nms
        (k in allowed || k in taken) || chk_stop("argument_unbekannt", fn, k)
    end
    seen = Set{String}()
    for k in nms
        (k in seen || k in taken) && chk_stop("argument_doppelt", fn, k)
        push!(seen, k)
    end
    return nms
end

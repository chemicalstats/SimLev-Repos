# Herkunft:           übersetzt aus R 4.3.3, src/main/format.c, printutils.c, printvector.c,
#                     printarray.c, print.c, paste.c, sprintf.c, util.c; src/nmath/fround.c,
#                     fprec.c; nachgebildet nach R 4.3.3, src/library/base/R/format.R, dataframe.R,
#                     factor.R, dates.R
# Rechte:             The R Core Team, teils Robert Gentleman und Ross Ihaka, The R Foundation (laut
#                     Kopf der jeweiligen R-Quelle); fprec.c: Übersetzung einer Fortran-Routine von
#                     W. Fullerton (Los Alamos); sprintf.c: ursprünglich Jonathan Rougier
# Lizenz der Vorlage: GPL (>= 2) laut Kopf der R-Quellen; in SimLev unter GPL-3
# Änderungen:         Übertragung nach Python bzw. Julia (Julia nach der Python-Fassung) im von
#                     SimLev genutzten Umfang: Datumsformat und -lesen rechnet der C-Kern
#                     core/slc_rbase_date.cpp.
# RFmt – format(), prettyNum(), formatC(), sprintf(), Datumsformate.
# Vorlage: python/simlev/_r/fmt.py; R 4.3.3 format.c, format.R, sprintf.c,
# util.c (str_signif), dates.R.

"`.Internal(format(...))` (do_format) → Liste von Zeichenketten (nothing = NA)."
function _format_internal(v::_V; trim = false, digits = nothing, nsmall = 0, width = nothing, justify = "left",
                          na_encode = true, scientific = nothing, decimal_mark = nothing)
    digits === nothing && (digits = _OPT[:digits])
    scipen = _OPT[:scipen]
    if scientific !== nothing
        scipen = scientific isa Bool ? (scientific ? -99 : 310) : Int(scientific)
    end
    dec = decimal_mark === nothing ? _OPT[:OutDec] : decimal_mark
    wd = width === nothing ? 0 : Int(width)
    n = length(v)
    n == 0 && return _Str[]
    t = v.type
    if t === :logical
        w = max(trim ? 0 : _format_logical(v), wd)
        return _Str[_encode_logical(v.l[i], v.na[i], w) for i in 1:n]
    elseif t === :integer
        w = max(trim ? 0 : _format_integer(v), wd)
        return _Str[_encode_integer(v.i[i], v.na[i], w) for i in 1:n]
    elseif t === :double
        w, d, e = _format_real(v, digits, nsmall, scipen)
        trim && (w = 0)
        w = max(w, wd)
        return _encode_reals(v, w, d, e, dec)
    elseif t === :character
        adj = justify
        w = wd
        if adj != "none"
            for s in v.s
                if s !== nothing
                    w = max(w, _strwid(s))
                elseif na_encode
                    w = max(w, 2)
                end
            end
        else
            w = 0
        end
        out = _Str[]
        for s in v.s
            if !na_encode && s === nothing
                push!(out, nothing)
                continue
            end
            s0 = s === nothing ? "NA" : s
            b = w - _strwid(s0)
            left = right = ""
            if b > 0 && adj != "left"
                b0 = adj == "centre" ? b ÷ 2 : b
                left = " "^b0
                b -= b0
            end
            b > 0 && adj != "right" && (right = " "^b)
            push!(out, left * s0 * right)
        end
        return out
    end
    error(string(t))
end

# Ergebnis wie das Eingabeobjekt formen (Matrix → Matrix, RFrame → RFrame)
function _keep_dim(x, res)
    a = res isa AbstractVector ? res : [res]
    if x isa SimLev.NamedMat
        return SimLev.NamedMat(reshape(collect(a), size(x)); rownames = x.rownames, colnames = x.colnames)
    elseif x isa AbstractMatrix
        return reshape(collect(a), size(x))
    end
    return res
end

"""
    format(x, fmt = nothing; trim = false, digits = nothing, nsmall = 0, justify = "left",
           width = nothing, na_encode = true, scientific = nothing, big_mark = "",
           big_interval = 3, small_mark = "", small_interval = 5, decimal_mark = nothing,
           zero_print = nothing, drop0trailing = false, type = nothing)

`format(x, ...)` wie R's `format.default`/`format.Date`/`format.factor`.
`fmt` (oder `format =`) nur für Datumswerte (`strftime`-Angabe); ein `Bool`
an dieser Stelle gilt als `trim`. `type` erzwingt einen R-Typ (z. B.
"integer"). Ergebnis: `String` bei Skalaren, sonst Vektor (`RVector` bei
Namen, Matrix/`NamedMat`/`RFrame` bei solchen Eingaben); NA (bei
`na_encode = false`) als `missing`. Für `RFrame` wie R's `format.data.frame`
mit `justify = "none"` als Standard (Textspalten ohne Auffüllen).
"""
function format(x, fmt = nothing; format = fmt, trim = false, digits = nothing, nsmall = 0, justify = "left",
                width = nothing, na_encode = true, scientific = nothing, big_mark = "", big_interval = 3,
                small_mark = "", small_interval = 5, decimal_mark = nothing, zero_print = nothing,
                drop0trailing = false, type = nothing)
    _format(x, format; trim, digits, nsmall, justify, width, na_encode, scientific, big_mark, big_interval,
            small_mark, small_interval, decimal_mark, zero_print, drop0trailing, type)
end
# seit 1.6.4 (RP) wie R format.data.frame: dort ist justify standardmäßig "none", Textspalten werden nicht aufgefüllt
# (bis 1.6.3 "left" wie format.default: c("x ", "yy") statt c("x", "yy")); mit justify = "left" wie bisher
function format(x::SimLev.RFrame, fmt = nothing; format = fmt, trim = false, digits = nothing, nsmall = 0,
                justify = "none", width = nothing, na_encode = true, scientific = nothing, big_mark = "",
                big_interval = 3, small_mark = "", small_interval = 5, decimal_mark = nothing, zero_print = nothing,
                drop0trailing = false, type = nothing)
    _format(x, format; trim, digits, nsmall, justify, width, na_encode, scientific, big_mark, big_interval,
            small_mark, small_interval, decimal_mark, zero_print, drop0trailing, type)
end
const r_format = format

function _format(x, fmt; trim = false, digits = nothing, nsmall = 0, justify = "left", width = nothing,
                 na_encode = true, scientific = nothing, big_mark = "", big_interval = 3, small_mark = "",
                 small_interval = 5, decimal_mark = nothing, zero_print = nothing, drop0trailing = false, type = nothing)
    if fmt isa Bool
        trim, fmt = fmt, nothing
    end
    if x isa SimLev.RFrame
        y = copy(x)
        if !(fmt === nothing && trim === false && nsmall == 0 && width === nothing && scientific === nothing &&
             big_mark == "" && big_interval == 3 && small_mark == "" && small_interval == 5 && decimal_mark === nothing &&
             zero_print === nothing && drop0trailing === false && type === nothing)
            # seit 1.6.4 wie R format.data.frame (C-041): alle Angaben gehen an format() jeder Spalte (bis 1.6.3 nur
            # digits, na_encode und justify; width, nsmall usw. fielen still weg)
            for j in 1:SimLev.ncol(y)
                r = _format(getfield(x, :cols)[j], fmt; trim, digits, nsmall, justify, width, na_encode, scientific,
                            big_mark, big_interval, small_mark, small_interval, decimal_mark, zero_print, drop0trailing, type)
                r isa SimLev.RVector && (r = r.values)
                getfield(y, :cols)[j] = r isa AbstractVector ? r : [r]
            end
            return y
        end
        SimLev.ncol(x) > 0 && (digits = _chk_digits(digits))   # seit 1.6.4 wie R je Spalte (C-012)
        for j in 1:SimLev.ncol(y)
            getfield(y, :cols)[j] = _jvec(_fmt_column(getfield(x, :cols)[j]; digits, na_encode, justify))
        end
        return y
    end
    if x isa AbstractMatrix
        return _keep_dim(x, _format(vec(x isa SimLev.NamedMat ? x.data : x), fmt; trim, digits, nsmall, justify, width,
                                    na_encode, scientific, big_mark, big_interval, small_mark, small_interval,
                                    decimal_mark, zero_print, drop0trailing, type))
    end
    v = _as_v(x, type)
    if v.type === :Date
        # seit 1.6.4 (C-057) wie R format.POSIXlt: NA in der Vorlage „missing value where TRUE/FALSE needed“, keine bzw.
        # keine Textvorlage „invalid 'format' argument“ (bis 1.6.3 MethodError bzw. TypeError)
        fl = fmt === nothing ? Any["%Y-%m-%d"] : fmt isa AbstractVector || fmt isa Tuple ? collect(Any, fmt) : Any[fmt]
        any(t -> t === missing || (t isa AbstractFloat && isnan(t)), fl) && error("missing value where TRUE/FALSE needed")
        (isempty(fl) || !all(t -> t isa AbstractString, fl)) && error("invalid 'format' argument")
        r = _format_date_list(v.d, _Str[String(t) for t in fl])
        n = length(v.d)
        for i in eachindex(r)   # NaN (nicht NA) wie R als "NaN" (seit 1.6.4, C-057)
            k = mod1(i, n)
            isnan(v.d[k]) && !v.na[k] && (r[i] = "NaN")
        end
        return _out(r, v)
    end
    # seit 1.6.4 (C-012, C-056, Entscheidung 77) wie R format.default/do_format: justify über match.arg, dann trim,
    # digits (1 bis 22), nsmall (0 bis 20), width, na.encode und scientific in dieser Reihenfolge mit R's Meldungen
    justify = _r_match_arg(justify, ("left", "right", "centre", "none"))
    trim = _r_lgl_arg(trim, "trim")
    digits = _chk_digits(digits)
    nsmall = _chk_nsmall(nsmall)
    if width !== nothing
        width = _r_as_int1(width)
        width === nothing && error("invalid 'width' argument")
    end
    na_encode = _r_lgl_arg(na_encode, "na.encode")
    if scientific !== nothing
        sa = scientific isa AbstractVector || scientific isa Tuple ? collect(scientific) : [scientific]
        (length(sa) != 1 || sa[1] isa AbstractString) && error("invalid 'scientific' argument")
        sv = sa[1]
        scientific = sv === missing ? nothing : sv isa Bool ? sv :
                     (si = _r_as_int1(sv); si === nothing ? -2147483648 : si)
    end
    if v.type === :factor
        v = _Vs(_as_character_list(v); names = v.names, scalar = v.scalar)
    end
    v.type === :NULL && return "NULL"
    if v.type === :character
        return _out(_format_internal(v; trim, digits, nsmall, width, justify, na_encode, scientific), v)
    end
    dec = decimal_mark === nothing ? _OPT[:OutDec] : decimal_mark
    r = _format_internal(v; trim, digits, nsmall, width, justify = "right", na_encode, scientific, decimal_mark = dec)
    r = _pretty_num_chr(r; big_mark, big_interval, small_mark, small_interval, decimal_mark = dec, input_d_mark = dec,
                        preserve_width = trim ? "individual" : "common", zero_print, drop0trailing)
    return _out(r, v)
end

# ── prettyNum ──────────────────────────────────────────────────────────────

_rlen(s::AbstractString) = length(s)

"`.format.zeros`."
function _format_zeros(x::Vector{_Str}, zero_print; replace = false)
    zero_print === nothing && return x
    nx = [_r_strtod(s)[1] for s in x]
    i0 = [i for i in eachindex(nx) if nx[i] == 0]
    isempty(i0) && return x
    zero_print isa Bool && (zero_print = zero_print ? "0" : " ")
    x = copy(x)
    nz = _rlen(zero_print)
    if !replace && any(i -> _rlen(x[i]) < nz, i0)
        @warn "'zero.print' is truncated to fit into formatted zeros; consider 'replace=TRUE'"
    end
    zc = collect(zero_print)
    for i in i0
        s = x[i]
        if replace
            x[i] = zero_print
            continue
        end
        cs = collect(s)
        nc = length(cs)
        p = findfirst(==('0'), cs)
        ind0 = p === nothing ? -1 : p
        i2 = min(nc, nz - 1 + ind0)
        i1 = max(1, i2 - nz + 1)
        k = i2 - i1 + 1
        if k > 0
            cs = vcat(cs[1:i1-1], zc[1:min(k, length(zc))], cs[i1+min(k, length(zc)):end])
        end
        if nc > i2
            cs = vcat(cs[1:i2], fill(' ', nc - i2))
        end
        x[i] = String(cs)
    end
    return x
end

"strsplit(s, sep, fixed = TRUE)[[1]] (ohne leeres Endstück)."
function _strsplit_fixed(s::String, sep::String)
    out = String[]
    while !isempty(s)
        r = findfirst(sep, s)
        if r === nothing
            push!(out, s)
            break
        end
        push!(out, s[1:prevind(s, first(r))])
        s = s[nextind(s, last(r)):end]
    end
    return out
end

function _pretty_num_chr(x::Vector{_Str}; big_mark = "", big_interval = 3, small_mark = "", small_interval = 5,
                         decimal_mark = ".", input_d_mark = nothing, preserve_width = "common", zero_print = nothing,
                         replace_zero = false, drop0trailing = false, not_char = false)
    input_d_mark === nothing && (input_d_mark = decimal_mark)
    n_mark = big_mark == "" && small_mark == "" && (not_char || decimal_mark == input_d_mark)
    if big_mark == decimal_mark && big_mark != ""
        @warn "'big.mark' and 'decimal.mark' are both '$(big_mark)', which could be confusing"
    end
    n_zero = zero_print === nothing && !drop0trailing
    n_mark && n_zero && return x
    n_mark && !drop0trailing && return _format_zeros(x, zero_print; replace = replace_zero)
    xs = String[s === nothing ? "NA" : s for s in x]
    B = String[]; A = String[]; iN = Bool[]
    for s in xs
        parts = _strsplit_fixed(s, input_d_mark)
        length(parts) > 2 && (parts = [join(parts[1:end-1], input_d_mark), parts[end]])
        push!(B, isempty(parts) ? "NA" : parts[1])
        if length(parts) >= 2
            push!(A, parts[2]); push!(iN, false)
        else
            push!(A, ""); push!(iN, true)
        end
    end
    if big_mark != ""
        pat = Regex("[0-9]{$(big_interval + 1),}")
        sub = Regex("([0-9]{$(big_interval)})\\B")
        rb = reverse(big_mark)
        for i in eachindex(B)
            occursin(pat, B[i]) && (B[i] = reverse(replace(reverse(B[i]), sub => m -> m * rb)))
        end
    end
    if small_mark != ""
        pat = Regex("[0-9]{$(small_interval + 1),}")
        sub = Regex("([0-9]{$(small_interval)}\\B)")
        for i in eachindex(A)
            occursin(pat, A[i]) && (A[i] = replace(A[i], sub => m -> m * small_mark))
        end
    end
    if drop0trailing
        idx = [i for i in eachindex(A) if !iN[i]]
        a = A[idx]
        has_e = [j for j in eachindex(a) if occursin('e', a[j])]
        if !isempty(has_e)
            for j in eachindex(a)
                a[j] = j in has_e ? replace(a[j], r"e[+-]0+$" => "") : replace(a[j], r"0+$" => "")
            end
        else
            a = [replace(s, r"0+$" => "") for s in a]
        end
        A[idx] = a
        iN = [isempty(s) for s in A]
    end
    res = _Str[B[i] * (iN[i] ? "" : decimal_mark) * A[i] for i in eachindex(B)]
    res = _format_zeros(res, zero_print; replace = replace_zero)
    if preserve_width != "none"
        dlen = [_rlen(res[i]) - _rlen(xs[i]) for i in eachindex(res)]
        if any(>(0), dlen)
            if preserve_width == "individual"
                for i in eachindex(res)
                    dlen[i] > 0 && (res[i] = replace(res[i], Regex("^ {1,$(dlen[i])}") => ""))
                end
            elseif preserve_width == "common"
                w = maximum(_strwid(s) for s in res)
                res = _Str[" "^(w - _strwid(s)) * s for s in res]
            end
        end
    end
    return res
end

# ── formatC ────────────────────────────────────────────────────────────────

"""
    formatC(x; width = nothing, digits = nothing, format = nothing, flag = "", mode = nothing,
            big_mark = "", big_interval = 3, small_mark = "", small_interval = 5,
            decimal_mark = nothing, preserve_width = "individual", zero_print = nothing,
            replace_zero = true, drop0trailing = false)

`formatC(...)` wie R; `format` ∈ "d", "f", "e", "E", "g", "G", "fg", "s".
Matrizen (auch `NamedMat`) und `RFrame` behalten ihre Form.
"""
function formatC(x; width = nothing, digits = nothing, format = nothing, flag = "", mode = nothing, big_mark = "",
                 big_interval = 3, small_mark = "", small_interval = 5, decimal_mark = nothing,
                 preserve_width = "individual", zero_print = nothing, replace_zero = true, drop0trailing = false)
    kw = (; width, digits, format, flag, mode, big_mark, big_interval, small_mark, small_interval, decimal_mark,
          preserve_width, zero_print, replace_zero, drop0trailing)
    if x isa AbstractMatrix
        return _keep_dim(x, formatC(vec(x isa SimLev.NamedMat ? x.data : x); kw...))
    elseif x isa SimLev.RFrame
        cols = getfield(x, :cols)
        allnum = all(c -> nonmissingtype(eltype(c)) <: Real && !(nonmissingtype(eltype(c)) <: Bool), cols)
        flat = allnum ? reduce(vcat, [Float64[_tofloat(z) for z in c] for c in cols]; init = Float64[]) :
                        reduce(vcat, [collect(Any, c) for c in cols]; init = Any[])
        r = formatC(flat; kw...)
        r = r isa AbstractVector ? r : [r]
        y = copy(x)
        n = SimLev.nrow(x)
        for j in eachindex(cols)
            getfield(y, :cols)[j] = r[(j-1)*n+1:j*n]
        end
        return y
    end
    dec = decimal_mark === nothing ? _OPT[:OutDec] : decimal_mark
    v = _as_v(x)
    v.type === :factor && (v = _Vi(copy(v.i), copy(v.na); names = v.names, scalar = v.scalar))
    v.type === :Date && (v = _Vd(copy(v.d), copy(v.na), falses(length(v)) |> collect; names = v.names, scalar = v.scalar))
    flag = string(flag)
    nf = collect(flag)
    all(c -> c in "0+- #'I", nf) || error("'flag' should contain only characters from [0+- #'I]")
    function format_char(strs, width, flag)
        if width === nothing
            width = 0
        elseif _isnan_num(width)   # seit 1.6.4 wie R (width < 0L ist NA)
            error("missing value where TRUE/FALSE needed")
        elseif width < 0
            flag = "-"
            width = -width
        end
        cv = _Vs(collect(_Str, strs))
        width !== nothing && _r_as_int1(width) === nothing && error("invalid 'width' argument")   # wie R do_format
        return _format_internal(cv; width, justify = flag == "-" ? "left" : "right")
    end
    n = length(v)
    n == 0 && return String[]
    if mode === nothing
        mode = String(v.type)
    elseif mode in ("double", "real", "integer")
        mode == "real" && (mode = "double")
        v = _coerce(v, Symbol(mode))
    elseif mode != "character"
        error("'mode' must be \"double\" (\"real\"), \"integer\" or \"character\"")
    end
    if mode == "character" || format == "s"
        mode != "character" && @warn "coercing argument to \"character\" for format=\"s\""
        return _out(format_char(_as_character_list(v), width, flag), v)
    end
    if format === nothing
        format = mode == "integer" ? "d" : "g"
    else
        if format in ("f", "e", "E", "g", "G", "fg")
            if mode == "integer"
                mode = "double"
                v = _coerce(v, :double)
            end
        elseif format == "d"
            if mode != "integer"
                mode = "integer"
                v = _coerce(v, :integer)
            end
        else
            error("'format' must be one of {\"f\",\"e\",\"E\",\"g\",\"G\", \"fg\", \"s\"}")
        end
    end
    v.type === :logical && error("unsupported type ")   # seit 1.6.4 wie R (C-049): formatC(<logisch>) ist ein Fehler
    if mode == "integer"
        vals = Float64.(v.i)
        ok = .!v.na
    else
        vals = copy(v.d)
        ok = isfinite.(v.d)
    end
    some_special = !all(ok)
    rQ = nothing
    if some_special
        sub = _subset(v, [i for i in 1:n if !ok[i]])
        rQ = _Str[s === nothing ? "NA" : s for s in _as_character_list(sub)]
        vals = Float64[ok[i] ? vals[i] : 0.0 for i in 1:n]
    end
    width === nothing && digits === nothing && (width = 1)
    if digits === nothing
        digits = mode == "integer" ? 2 : 4
    elseif digits < 0
        digits = 6
    else
        max_digits = format != "f" ? 50 : 324
        if digits > max_digits
            @warn "'digits' reduced to $(max_digits)"
            digits = max_digits
        end
    end
    width === nothing && (width = digits + 1)
    _isnan_num(width) && error("missing value where TRUE/FALSE needed")   # seit 1.6.4 wie R (width == 0L ist NA)
    width == 0 && (width = digits)
    # seit 1.6.4 (C-011, FW6-6) wie R: width außerhalb des int-Bereichs wird NA (Warnung bei as.integer in i.strlen und
    # bei asInteger im Kern), und R kann dann bzw. ab i.strlen >= 2147483645 den Puffer nicht anlegen; bis 1.6.3 Absturz
    if _r_as_int1(width) === nothing
        @warn "NAs introduced by coercion to integer range"
        error("cannot allocate memory block of size 16777216 Tb")
    end
    width = Int(trunc(width)); digits = Int(digits)
    istrlen = Int[]
    for xv in vals
        if format == "fg" || format == "f"
            xEx = floor(Int, _log10(abs(xv + (xv == 0))))
            base = Int(xv < 0 || flag != "") + digits
            if format == "f"
                base += 2 + max(xEx, 0)
            else
                base += 1 + max(xEx, digits, digits + (-xEx) + 1) + length(nf)
            end
            push!(istrlen, max(abs(width), base))
        else
            push!(istrlen, max(abs(width), digits + 8))
        end
    end
    !isempty(istrlen) && maximum(istrlen) >= 2147483645 && error("cannot allocate memory block of size 16777216 Tb")
    digits > 0 && '#' in nf && (digits = -digits)
    r = _str_signif(vals, mode, width, digits, format, flag, istrlen)
    if some_special
        fc = format_char(rQ, width, flag)
        j = 0
        for i in 1:n
            if !ok[i]
                j += 1
                r[i] = fc[j]
            end
        end
    end
    if big_mark != "" || small_mark != "" || dec != "." || zero_print !== nothing || drop0trailing
        r = _pretty_num_chr(r; big_mark, big_interval, small_mark, small_interval, decimal_mark = dec, input_d_mark = ".",
                            preserve_width, zero_print, replace_zero, drop0trailing)
    end
    return _out(r, v)
end

"`str_signif` aus util.c (C-Kern sl_r_str_signif über snprintf, seit 1.6.0)."
_str_signif(vals::Vector{Float64}, type, width::Int, digits::Int, format, flag::String, istrlen::Vector{Int}) =
    _Str[t for t in SimLev._rb_str_signif(vals, type == "integer", width, digits, String(format), flag, Int64.(istrlen))]

# ── sprintf ────────────────────────────────────────────────────────────────

const _SP_TYPE = Dict(:logical => 0, :integer => 1, :double => 2, :character => 3, :factor => 4, :Date => 5)

"Argument von sprintf für den C-Kern (SimLev._SpArg)."
function _sp_arg(v::_V)
    t = v.type
    t === :character && return SimLev._SpArg(3, nothing, Union{Nothing,String}[s === nothing ? nothing : String(s) for s in v.s])
    if t === :double || t === :Date
        x = Float64[v.na[i] ? SimLev.NA : v.d[i] for i in 1:length(v.d)]
        return SimLev._SpArg(_SP_TYPE[t], x, t === :Date ?
            Union{Nothing,String}[s === nothing ? nothing : String(s) for s in _format_date_list(v.d, _Str["%Y-%m-%d"])] : nothing)
    end
    if t === :factor
        iv = Int32[v.na[i] ? typemin(Int32) : Int32(v.i[i]) for i in 1:length(v.i)]
        return SimLev._SpArg(4, iv, Union{Nothing,String}[v.na[i] ? nothing : v.levels[v.i[i]] for i in 1:length(v.i)])
    end
    t === :integer && return SimLev._SpArg(1, Int32[v.na[i] ? typemin(Int32) : Int32(v.i[i]) for i in 1:length(v.i)])
    t === :logical && return SimLev._SpArg(0, Int32[v.na[i] ? typemin(Int32) : Int32(v.l[i]) for i in 1:length(v.l)])
    t === :NULL && return SimLev._SpArg(2, Float64[])
    error("unsupported type")
end

function _sprintf_warn(nunused::Int, nfmt::Int, f1)
    if nfmt == 1
        f1 = f1 === nothing ? "NA" : f1
        @warn nunused == 1 ? "one argument not used by format '$(f1)'" : "$(nunused) arguments not used by format '$(f1)'"
    else
        @warn nunused == 1 ? "one argument not used by format" : "$(nunused) arguments not used by format"
    end
end

"""
    r_sprintf(fmt, args...)

`sprintf(fmt, ...)` mit R's Vektorsemantik (Recycling über `fmt` und alle
Argumente; NA → "NA"; `Inf`/`-Inf`/`NaN` wie R; `%s` von Zahlen =
as.character mit 15 Stellen; `%d` nur für ganzzahlige Werte; `%n\$`,
`*`). Zahlen formatiert die C-Bibliothek (`snprintf`) wie in R. Liefert
`String`, wenn alles Länge 1 hat, sonst `Vector{String}`.
"""
function r_sprintf(fmt, args...)
    fv = _as_v(fmt, "character")
    a = _V[_as_v(x) for x in args]
    scal = fv.scalar && all(v -> v.scalar, a)
    # C-Kern sl_r_sprintf (seit 1.6.0): Umwandlungen über snprintf wie R
    res, nunused = SimLev._rb_sprintf(Union{Nothing,String}[s === nothing ? nothing : String(s) for s in fv.s],
                                      SimLev._SpArg[_sp_arg(v) for v in a], Int(_OPT[:scipen])::Int,
                                      String(_OPT[:OutDec])::String)
    nunused > 0 && _sprintf_warn(nunused, length(fv.s), isempty(fv.s) ? nothing : fv.s[1])
    scal && length(res) == 1 && return res[1]
    return res
end
const sprintf = r_sprintf

# ── Datum ──────────────────────────────────────────────────────────────────
# format.Date/strftime (C-Locale) rechnet der gemeinsame Kern core/slc_rbase_date.cpp (wie Python).
# %OS ohne Ziffer nach digits_secs (set_options); Ergebnis über 2048 Bytes ist ein Fehler wie in R.

function _format_date_list(days::AbstractVector{Float64}, fmts::AbstractVector)
    n = length(days)
    n == 0 && return _Str[]
    nf = length(fmts)
    out = _Str[]
    sizehint!(out, max(n, nf))
    ds = _digits_secs()
    buf = Vector{UInt8}(undef, 2048)
    for i in 1:max(n, nf)
        z = days[mod1(i, n)]
        f = fmts[mod1(i, nf)]
        if isinf(z)   # seit 1.6.4 wie R 4.3.3 (C-057): "Inf", "-Inf" bei jeder Vorlage ("NaN": Aufrufer mit NA-Maske)
            push!(out, z > 0 ? "Inf" : "-Inf")
        elseif isnan(z) || f === nothing || f === missing || !(abs(z) < 1e14)
            push!(out, nothing)
        else
            push!(out, SimLev._rb_strftime(floor(Int64, z), String(f), ds, buf))
        end
    end
    return out
end

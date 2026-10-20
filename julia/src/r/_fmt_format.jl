# RFmt – format(), prettyNum(), formatC(), sprintf(), Datumsformate.
# Vorlage: python/simlev/_r/fmt.py; R 4.3.3 format.c, format.R, sprintf.c,
# util.c (str_signif), dates.R.

const _JUST = ("left", "right", "centre", "none")

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
`na_encode = false`) als `missing`.
"""
function format(x, fmt = nothing; format = fmt, trim = false, digits = nothing, nsmall = 0, justify = "left",
                width = nothing, na_encode = true, scientific = nothing, big_mark = "", big_interval = 3,
                small_mark = "", small_interval = 5, decimal_mark = nothing, zero_print = nothing,
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
        return _out(_format_date_list(v.d, _Str[fmt === nothing ? "%Y-%m-%d" : fmt]), v)
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

"`format.info(x)`: [w] bzw. [w, d, e] für double."
function format_info(x; digits = nothing, nsmall = 0)
    v = _as_v(x)
    v.type === :double && return collect(_format_real(v, digits, nsmall))
    v.type === :integer && return [_format_integer(v)]
    v.type === :logical && return [_format_logical(v)]
    return [_format_string(_as_character_list(v))]
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

"""
    prettyNum(x; big_mark = "", big_interval = 3, small_mark = "", small_interval = 5,
              decimal_mark = nothing, input_d_mark = nothing, preserve_width = "common",
              zero_print = nothing, replace_zero = false, drop0trailing = false, kw...)

`prettyNum(x, ...)`: Tausender-/Dezimaltrenner in formatierte Zahlen.
"""
function prettyNum(x; big_mark = "", big_interval = 3, small_mark = "", small_interval = 5, decimal_mark = nothing,
                   input_d_mark = nothing, preserve_width = "common", zero_print = nothing, replace_zero = false,
                   drop0trailing = false, kw...)
    dec = decimal_mark === nothing ? _OPT[:OutDec] : decimal_mark
    idm = input_d_mark === nothing ? dec : input_d_mark
    v = _as_v(x)
    if v.type !== :character
        strs = _Str[]
        for i in 1:length(v)
            r = _format(_subset(v, [i]), nothing; big_mark, big_interval, small_mark, small_interval, decimal_mark = dec,
                        zero_print, drop0trailing, kw...)
            r = r isa AbstractVector ? r[1] : r
            push!(strs, r === missing ? nothing : r)
        end
        res = _pretty_num_chr(strs; big_mark, big_interval, small_mark, small_interval, decimal_mark = dec,
                              input_d_mark = idm, preserve_width, zero_print, replace_zero, drop0trailing, not_char = true)
    else
        res = _pretty_num_chr(copy(v.s); big_mark, big_interval, small_mark, small_interval, decimal_mark = dec,
                              input_d_mark = idm, preserve_width, zero_print, replace_zero, drop0trailing)
    end
    return _out(res, v)
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
        elseif width < 0
            flag = "-"
            width = -width
        end
        cv = _Vs(collect(_Str, strs))
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
    if v.type === :logical
        v = _coerce(v, :integer)
        mode = "integer"
    end
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
    width == 0 && (width = digits)
    width = Int(width); digits = Int(digits)
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

"`str_signif` aus util.c (snprintf mit Puffergröße i.strlen + 2)."
function _str_signif(vals::Vector{Float64}, type, width::Int, digits::Int, format, flag::String, istrlen::Vector{Int})
    dig = abs(digits)
    rm_trailing_0 = digits >= 0
    do_fg = format == "fg"
    width == 0 && error("width cannot be zero")
    out = _Str[]
    if format == "d"
        type == "integer" || error("'type' must be \"integer\" for  \"d\"-format")
        form = "%" * _fl_w(flag, width) * "*d"
        for (i, xv) in enumerate(vals)
            push!(out, _cut(_snprintf_w(form, abs(width), Int(xv)), istrlen[i] + 2))
        end
        return out
    end
    # negative Breite über '*' wirkt in glibc wie das Flag '-' (Auffüllen mit
    # Leerzeichen); im Julia-Prozess nimmt glibc dafür einen anderen Pfad, der
    # mit '0' auffüllt – daher Betrag und Flag explizit übergeben
    form = "%" * _fl_w(flag, width) * "*.*" * (do_fg ? "g" : format)
    width = abs(width)
    f0 = "%" * flag * ".*f"
    for (i, xx) in enumerate(vals)
        lim = istrlen[i] + 2
        if do_fg
            if xx == 0.0
                push!(out, "0")
                continue
            end
            xxx = abs(xx)
            iex = floor(Int, _log10(xxx) + 1e-12)
            X = fround(xxx / _cpow(10.0, Float64(iex)) + 1e-12, Float64(dig - 1))
            if iex > 0 && X >= 10
                xx = X * _cpow(10.0, Float64(iex))
                iex += 1
            end
            iex == -4 && abs(xx) < 1e-4 && (iex = -5)
            if iex < -4
                s = _cut(_snprintf_p(f0, dig - 1 + -iex, xx), lim)
                if rm_trailing_0
                    b = codeunits(s)
                    j = length(b)
                    while j >= 1 && b[j] == UInt8('0')
                        j -= 1
                    end
                    s = String(b[1:j])
                end
                push!(out, s)
            else
                push!(out, _snprintf_wd(form, width, iex >= dig ? iex + 1 : dig, xx, lim))
            end
        else
            push!(out, _snprintf_wd(form, width, dig, xx, lim))
        end
    end
    return out
end

_fl_w(flag, width) = width < 0 ? flag * "-" : flag

_snprintf_p(fmt::String, p::Integer, x::Float64) = SimLev._c_sprintf(fmt, Int32(p), x)

# ── sprintf ────────────────────────────────────────────────────────────────

const _SPEC_CHARS = "diosfeEgGxXaA"

# findspec(): Position (1-basiert) des Umwandlungszeichens nach Flags/Breite/Genauigkeit
function _findspec(f::String)
    b = codeunits(f)
    (isempty(b) || b[1] != UInt8('%')) && return 1
    p = 2
    while p <= length(b)
        c = Char(b[p])
        (c in "-+ #." || c == '*' || ('0' <= c <= '9')) || break
        p += 1
    end
    return p
end
# checkfmt(): true = Fehler (Umwandlung nicht in pattern)
function _checkfmt(f::String, pattern::String)
    (isempty(f) || f[1] != '%') && return true
    p = _findspec(f)
    p > ncodeunits(f) && return true
    return !(Char(codeunits(f)[p]) in pattern)
end

function _sprintf_cvt(fmtp::String, x)
    nc = x isa Float64 ? _snprintf(fmtp, x) : x isa Integer ? _snprintf(fmtp, x) : _snprintf(fmtp, String(x))
    ncodeunits(nc) > 8192 && error("required resulting string length $(ncodeunits(nc)) is greater than maximal 8192")
    return nc
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
    nargs = length(a)
    nfmt = length(fv)
    nfmt == 0 && return String[]
    for v in a
        length(v) == 0 && return String[]
    end
    lens = [length(v) for v in a]
    function check_maxlen()
        ml = nfmt
        for l in lens
            ml = max(ml, l)
        end
        ml % nfmt != 0 && error("arguments cannot be recycled to the same length")
        for l in lens
            ml % l != 0 && error("arguments cannot be recycled to the same length")
        end
        ml
    end
    maxlen = check_maxlen()
    used = falses(nargs)
    results = String[]
    for ns in 0:maxlen-1
        f0 = fv.s[ns % nfmt + 1]
        formatString = f0 === nothing ? "NA" : f0
        fb = codeunits(formatString)
        n = length(fb)
        out = IOBuffer()
        cur = 1
        cnt = 0
        while cur <= n
            if fb[cur] == UInt8('%')
                if cur < n && fb[cur+1] == UInt8('%')
                    print(out, '%')
                    cur += 2
                    continue
                end
                # chunk = strcspn(curFormat + 1, "diosfeEgGxXaA") + 2
                j = cur + 1
                while j <= n && !(Char(fb[j]) in _SPEC_CHARS)
                    j += 1
                end
                j > n && error("unrecognised format specification '$(String(fb[cur:end]))'")
                fmt_ = String(fb[cur:j])
                cur = j + 1
                nthis = -1
                fbs = codeunits(fmt_)
                if length(fbs) > 3 && UInt8('1') <= fbs[2] <= UInt8('9')
                    vv = Int(fbs[2] - UInt8('0'))
                    if fbs[3] == UInt8('$')
                        vv > nargs && error("reference to non-existent argument $vv")
                        nthis = vv - 1
                        fmt_ = "%" * String(fbs[4:end])
                    elseif UInt8('0') <= fbs[3] <= UInt8('9') && fbs[4] == UInt8('$')
                        vv = 10vv + Int(fbs[3] - UInt8('0'))
                        vv > nargs && error("reference to non-existent argument $vv")
                        nthis = vv - 1
                        fmt_ = "%" * String(fbs[5:end])
                    end
                end
                has_star = false
                star_arg = 0
                sp = findfirst('*', fmt_)
                if sp !== nothing
                    nstar = -1
                    st = codeunits(fmt_)[sp:end]
                    if length(st) > 3 && UInt8('1') <= st[2] <= UInt8('9')
                        vv = Int(st[2] - UInt8('0'))
                        if st[3] == UInt8('$')
                            vv > nargs && error("reference to non-existent argument $vv")
                            nstar = vv - 1
                            fmt_ = fmt_[1:sp] * String(st[4:end])
                        elseif UInt8('0') <= st[3] <= UInt8('9') && st[4] == UInt8('$')
                            vv = 10vv + Int(st[3] - UInt8('0'))
                            vv > nargs && error("reference to non-existent argument $vv")
                            nstar = vv - 1
                            fmt_ = fmt_[1:sp] * String(st[5:end])
                        end
                    end
                    if nstar < 0
                        cnt >= nargs && error("too few arguments")
                        nstar = cnt
                        cnt += 1
                    end
                    occursin('*', fmt_[sp+1:end]) &&
                        error("at most one asterisk '*' is supported in each conversion specification")
                    sv = a[nstar+1]
                    used[nstar+1] = true
                    if ns == 0 && sv.type === :double
                        sv = _coerce(sv, :integer)
                        a[nstar+1] = sv
                    end
                    (sv.type !== :integer || length(sv) < 1 || sv.na[ns % length(sv) + 1]) &&
                        error("argument for '*' conversion specification must be a number")
                    star_arg = sv.i[ns % length(sv) + 1]
                    has_star = true
                end
                if fmt_[end] == '%'
                    print(out, has_star ? _snprintf(fmt_, star_arg) : fmt_)
                    continue
                end
                if nthis < 0
                    cnt >= nargs && error("too few arguments")
                    nthis = cnt
                    cnt += 1
                end
                used[nthis+1] = true
                fmtp = has_star ? replace(fmt_, "*" => string(star_arg)) : fmt_
                if ns == 0
                    th = a[nthis+1]
                    sc = Char(codeunits(fmtp)[min(_findspec(fmtp), ncodeunits(fmtp))])
                    if sc in "dioxX"
                        if th.type === :double
                            exact = true
                            for i in 1:length(th)
                                th.na[i] && continue
                                r = th.d[i]
                                if !isfinite(r) || !(abs(r) < 2147483648.0) || Float64(trunc(r)) != r
                                    exact = false
                                    break
                                end
                            end
                            exact && (a[nthis+1] = _coerce(th, :integer))
                        end
                    elseif sc in "aAefgEG"
                        if !(th.type in (:double, :character, :Date))
                            a[nthis+1] = _coerce(th.type === :factor ? _coerce(th, :integer) : th, :double)
                        end
                    elseif sc == 's'
                        if th.type !== :character
                            a[nthis+1] = _Vs(_as_character_list(th))
                        end
                    end
                    lens[nthis+1] = length(a[nthis+1])
                end
                th = a[nthis+1]
                thislen = length(th)
                thislen == 0 && error("coercion has changed vector length to 0")
                i = ns % thislen + 1
                t = th.type
                if t === :factor
                    th = _coerce(th, :integer)
                    t = :integer
                end
                if t === :logical
                    _checkfmt(fmtp, "di") && error("invalid format '$(fmtp)'; use format %d or %i for logical objects")
                    if th.na[i]
                        print(out, _sprintf_cvt(fmtp[1:end-1] * "s", "NA"))
                    else
                        print(out, _sprintf_cvt(fmtp, Int(th.l[i])))
                    end
                elseif t === :integer
                    _checkfmt(fmtp, "dioxX") &&
                        error("invalid format '$(fmtp)'; use format %d, %i, %o, %x or %X for integer objects")
                    if th.na[i]
                        print(out, _sprintf_cvt(fmtp[1:end-1] * "s", "NA"))
                    else
                        print(out, _sprintf_cvt(fmtp, th.i[i]))
                    end
                elseif t === :double || t === :Date
                    _checkfmt(fmtp, "aAfeEgG") &&
                        error("invalid format '$(fmtp)'; use format %f, %e, %g or %a for numeric objects")
                    x = th.d[i]
                    if isfinite(x)
                        print(out, _sprintf_cvt(fmtp, x))
                    else
                        p = findfirst('.', fmtp)
                        f2 = p !== nothing ? fmtp[1:p-1] * "s" : fmtp[1:end-1] * "s"
                        sp_ = occursin(' ', f2)
                        if isnan(x)
                            isna = th.na[i] || SimLev.isna_strict(x)
                            word = isna ? "NA" : "NaN"
                            print(out, _sprintf_cvt(f2, sp_ ? " " * word : word))
                        elseif x > 0
                            print(out, _sprintf_cvt(f2, occursin('+', f2) ? "+Inf" : sp_ ? " Inf" : "Inf"))
                        else
                            print(out, _sprintf_cvt(f2, "-Inf"))
                        end
                    end
                elseif t === :character
                    _checkfmt(fmtp, "s") && error("invalid format '$(fmtp)'; use format %s for character objects")
                    s = th.s[i]
                    s = s === nothing ? "NA" : s
                    if codeunits(fmtp)[2] != UInt8('s')
                        print(out, _sprintf_cvt(fmtp, s))
                    else
                        print(out, s)
                    end
                else
                    error("unsupported type")
                end
            else
                j = cur
                while j <= n && fb[j] != UInt8('%')
                    j += 1
                end
                write(out, fb[cur:j-1])
                cur = j
            end
        end
        if ns == 0
            maxlen = check_maxlen()
        end
        push!(results, String(take!(out)))
    end
    nunused = count(!, used)
    if nunused > 0
        if nfmt == 1
            f1 = fv.s[1] === nothing ? "NA" : fv.s[1]
            @warn nunused == 1 ? "one argument not used by format '$(f1)'" : "$(nunused) arguments not used by format '$(f1)'"
        else
            @warn nunused == 1 ? "one argument not used by format" : "$(nunused) arguments not used by format"
        end
    end
    scal && length(results) == 1 && return results[1]
    return results
end
const sprintf = r_sprintf

# ── Datum ──────────────────────────────────────────────────────────────────

const _MON = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October",
              "November", "December"]
const _WDAY = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

"Tage seit 1970-01-01 → (Jahr, Monat, Tag), proleptisch gregorianisch."
function _civil(z::Int)
    z += 719468
    era = fld(z, 146097)
    doe = z - era * 146097
    yoe = fld(doe - fld(doe, 1460) + fld(doe, 36524) - fld(doe, 146096), 365)
    y = yoe + era * 400
    doy = doe - (365 * yoe + fld(yoe, 4) - fld(yoe, 100))
    mp = fld(5 * doy + 2, 153)
    d = doy - fld(153 * mp + 2, 5) + 1
    m = mp < 10 ? mp + 3 : mp - 9
    return (y + (m <= 2 ? 1 : 0), m, d)
end

function _days_from_civil(y::Int, m::Int, d::Int)
    y -= m <= 2 ? 1 : 0
    era = fld(y, 400)
    yoe = y - era * 400
    doy = fld(153 * (m + (m > 2 ? -3 : 9)) + 2, 5) + d - 1
    doe = yoe * 365 + fld(yoe, 4) - fld(yoe, 100) + doy
    return era * 146097 + doe - 719468
end

function _iso_week(z::Int, wday::Int)
    wd = mod(wday + 6, 7)
    th = z - wd + 3
    ty, _, _ = _civil(th)
    jan1 = _days_from_civil(ty, 1, 1)
    return ty, fld(th - jan1, 7) + 1
end

const _COMPOSITE = Dict('F' => "%Y-%m-%d", 'D' => "%m/%d/%y", 'x' => "%m/%d/%y", 'T' => "%H:%M:%S", 'X' => "%H:%M:%S",
                        'R' => "%H:%M", 'r' => "%I:%M:%S %p", 'c' => "%a %b %e %H:%M:%S %Y")

"glibc-`strftime` (C-Locale) für ein Datum (Tage seit 1970-01-01, 00:00 UTC)."
function _strftime1(z::Int, fmt::String)
    y, m, d = _civil(z)
    wday = mod(z + 4, 7)
    yday = z - _days_from_civil(y, 1, 1)
    out = IOBuffer()
    cs = collect(fmt)
    n = length(cs)
    i = 1
    while i <= n
        c = cs[i]
        if c != '%'
            print(out, c)
            i += 1
            continue
        end
        start = i
        i += 1
        pad = nothing
        upcase = swcase = false
        while i <= n && cs[i] in "-_0^#"
            if cs[i] == '^'
                upcase = true
            elseif cs[i] == '#'
                swcase = true
            else
                pad = cs[i]
            end
            i += 1
        end
        width = 0
        while i <= n && isdigit(cs[i])
            width = width * 10 + (cs[i] - '0')
            i += 1
        end
        i <= n && cs[i] in "EO" && (i += 1)
        if i > n
            print(out, String(cs[start:end]))
            break
        end
        k = cs[i]
        i += 1
        function num(v, digits, fill = '0')
            neg = v < 0
            s = string(abs(v))
            pad == '-' && return (neg ? "-" : "") * s
            if pad == '_'
                fill = ' '
            elseif pad == '0'
                fill = '0'
            end
            tw = max(width, digits) - (neg ? 1 : 0)
            fill == '0' && return (neg ? "-" : "") * lpad(s, tw, '0')
            return lpad((neg ? "-" : "") * s, tw + (neg ? 1 : 0))
        end
        yearish(v) = (pad == '-' || width == 0) ? string(v) : num(v, 1)
        function text(t, swap_lower = false)
            if upcase
                t = uppercase(t)
            elseif swcase
                t = swap_lower ? lowercase(t) : uppercase(t)
            end
            width > length(t) && (t = string(pad == '0' ? '0' : ' ')^(width - length(t)) * t)
            return t
        end
        if k == 'Y'
            print(out, yearish(y))
        elseif k == 'C'
            print(out, yearish(fld(y, 100)))
        elseif k == 'G' || k == 'g' || k == 'V'
            gy, gw = _iso_week(z, wday)
            print(out, k == 'G' ? yearish(gy) : num(k == 'g' ? mod(gy, 100) : gw, 2))
        elseif k == 'y'
            print(out, num(mod(y, 100), 2))
        elseif k == 'm'
            print(out, num(m, 2))
        elseif k == 'd'
            print(out, num(d, 2))
        elseif k == 'e'
            print(out, num(d, 2, ' '))
        elseif k == 'j'
            print(out, num(yday + 1, 3))
        elseif k == 'u'
            print(out, num(wday == 0 ? 7 : wday, 1))
        elseif k == 'w'
            print(out, num(wday, 1))
        elseif k == 'U'
            print(out, num(fld(yday + 7 - wday, 7), 2))
        elseif k == 'W'
            print(out, num(fld(yday + 7 - mod(wday + 6, 7), 7), 2))
        elseif k in "HMS"
            print(out, num(0, 2))
        elseif k == 'I'
            print(out, num(12, 2))
        elseif k == 'k'
            print(out, num(0, 2, ' '))
        elseif k == 'l'
            print(out, num(12, 2, ' '))
        elseif k == 's'
            print(out, num(z * 86400, 1))
        elseif k == 'b' || k == 'h'
            print(out, text(_MON[m][1:3]))
        elseif k == 'B'
            print(out, text(_MON[m]))
        elseif k == 'a'
            print(out, text(_WDAY[wday+1][1:3]))
        elseif k == 'A'
            print(out, text(_WDAY[wday+1]))
        elseif k == 'p'
            print(out, text("AM", true))
        elseif k == 'P'
            print(out, text("am"))
        elseif k == 'Z'
            print(out, text("UTC", true))
        elseif k == 'z'
            print(out, "+0000")
        elseif haskey(_COMPOSITE, k)
            print(out, text(_strftime1(z, _COMPOSITE[k])))
        elseif k == 'n'
            print(out, '\n')
        elseif k == 't'
            print(out, '\t')
        elseif k == '%'
            print(out, '%')
        else
            print(out, String(cs[start:i-1]))
        end
    end
    return String(take!(out))
end

function _format_date_list(days::AbstractVector{Float64}, fmts::AbstractVector)
    n = length(days)
    n == 0 && return _Str[]
    nf = length(fmts)
    out = _Str[]
    for i in 1:max(n, nf)
        z = days[mod1(i, n)]
        f = fmts[mod1(i, nf)]
        if isnan(z) || f === nothing || f === missing || !isfinite(z)
            push!(out, nothing)
        else
            push!(out, _strftime1(floor(Int, z), String(f)))
        end
    end
    return out
end

"""
    format_date(x, fmt = "%Y-%m-%d")

`format(<Date>, fmt)` wie `format.Date`/`strftime` in der C-Locale. `x`:
`Date`, Tage seit 1970-01-01 (Zahl), ISO-Text oder Vektor davon; NA → `missing`.
"""
function format_date(x, fmt = "%Y-%m-%d")
    v = _as_v(x)
    if v.type in (:double, :integer)
        v = _coerce(v, :Date)
    elseif v.type === :character
        days = Float64[]
        for s in v.s
            d = s === nothing || length(s) < 10 ? nothing : tryparse(Date, s[1:10], dateformat"yyyy-mm-dd")
            push!(days, d === nothing ? NaN : _days(d))
        end
        v = _Vdate(days, Bool[isnan(z) for z in days]; names = v.names, scalar = v.scalar)
    end
    fv = _as_v(fmt, "character")
    return _out(_format_date_list(v.d, fv.s), v)
end

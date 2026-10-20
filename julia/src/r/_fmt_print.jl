# RFmt – Druckausgabe: Vektoren, Faktoren, Matrizen, data.frames, Listen, cat.
# Vorlage: python/simlev/_r/fmt.py; R 4.3.3 printvector.c, printmatrix.c,
# printutils.c, print.c, factor.R, dataframe.R.

_vec_label(i, labwidth) = " "^(labwidth - _index_width(i) - 2) * "[" * string(i) * "]"

function _type0(v::_V)
    v.type === :logical ? "logical(0)" : v.type === :integer ? "integer(0)" :
    v.type === :double ? "numeric(0)" : v.type === :character ? "character(0)" : "NULL"
end

# (Breite, Kodierer ww -> Elemente) für Zahlen/Logik
function _encode_elems(v::_V, digits = nothing)
    t = v.type
    n = length(v)
    if t === :double
        w, d, e = _format_real(v, digits)
        return w, ww -> _encode_reals(v, ww, d, e, _OPT[:OutDec])
    elseif t === :integer
        return _format_integer(v), ww -> _Str[_encode_integer(v.i[i], v.na[i], ww) for i in 1:n]
    elseif t === :logical
        return _format_logical(v), ww -> _Str[_encode_logical(v.l[i], v.na[i], ww) for i in 1:n]
    end
    error(string(t))
end

"printVector → Zeilen."
function _print_vector_lines(v::_V, quote_ = true, right = false, digits = nothing, indx = true)
    n = length(v)
    width_opt = _OPT[:width]
    gap = 1
    n == 0 && return [_type0(v)]
    lines = String[]
    if indx
        labwidth = _index_width(n) + 2
        cur = _vec_label(1, labwidth)
        width = labwidth
    else
        labwidth = 0
        cur = ""
        width = 0
    end
    if v.type === :character
        q = quote_ ? '"' : _NOQ
        w = _format_string(v.s, q)
        just = right ? "right" : "left"
        for i in 1:n
            if i > 1 && width + w + gap > width_opt
                push!(lines, cur)
                if indx
                    cur = _vec_label(i, labwidth); width = labwidth
                else
                    cur = ""; width = 0
                end
            end
            cur *= " " * _encode_string(v.s[i], w, q, just)
            width += w + gap
        end
    else
        w, enc = _encode_elems(v, digits)
        w += gap
        strs = enc(w)
        for i in 1:n
            if i > 1 && width + w > width_opt
                push!(lines, cur)
                if indx
                    cur = _vec_label(i, labwidth); width = labwidth
                else
                    cur = ""; width = 0
                end
            end
            cur *= strs[i]
            width += w
        end
    end
    push!(lines, cur)
    return lines
end

function _print_named_vector_lines(v::_V, names, quote_ = true, digits = nothing)
    n = length(v)
    gap = 1
    n == 0 && return ["named " * _type0(v)]
    q = quote_ ? '"' : _NOQ
    if v.type === :character
        w = _format_string(v.s, q)
        enc = nothing
    else
        w, enc = _encode_elems(v, digits)
    end
    wn = _format_string(names)
    w < wn && (w = wn)
    strs = v.type === :character ? _Str[_encode_string(s, w, q, "right") for s in v.s] : enc(w)
    nperline = _OPT[:width] ÷ (w + gap)
    nperline <= 0 && (nperline = 1)
    nlines = n ÷ nperline + (n % nperline != 0 ? 1 : 0)
    lines = String[]
    for i in 0:nlines-1
        ks = (i*nperline+1):min(n, (i + 1) * nperline)
        push!(lines, join(_encode_string(names[k], w, _NOQ, "right") * " " for k in ks))
        push!(lines, join(strs[k] * " " for k in ks))
    end
    return lines
end

function _print_vec_v(v::_V, digits = nothing, quote_ = nothing, right = false)
    v.type !== :factor && quote_ === nothing && (quote_ = true)
    v.type === :NULL && return ["NULL"]
    v.type === :factor && return _print_factor_lines(v, quote_ === true, nothing, right)
    if v.type === :Date
        length(v) == 0 && return ["Date of length 0"]
        v = _V(:character, Float64[], Int[], Bool[], _format_date_list(v.d, _Str["%Y-%m-%d"]), copy(v.na),
               falses(length(v)) |> collect, v.names, String[], false, false)
    end
    v.names !== nothing && return _print_named_vector_lines(v, v.names, quote_, digits)
    return _print_vector_lines(v, quote_, right, digits)
end

"""
    print_vector(x; names = nothing, digits = nothing, quote_ = nothing, right = false, type = nothing)

Text von `print(x)` eines atomaren Vektors (auch Date, factor), ohne
abschließenden Zeilenumbruch. `RVector` mit Namen druckt benannt; `type`
erzwingt einen R-Typ (z. B. "integer" für ganzzahlige Werte als Float64).
"""
function print_vector(x; names = nothing, digits = nothing, quote_ = nothing, right = false, type = nothing)
    v = _as_v(x, type)
    names !== nothing && (v.names = _strnames(names))
    return join(_print_vec_v(v, digits, quote_, right), "\n")
end

function _print_factor_lines(v::_V, quote_ = false, max_levels = nothing, right = false)
    n = length(v)
    lines = String[]
    if n == 0
        push!(lines, (v.ordered ? "ordered" : "factor") * "()")
    else
        cv = _Vs(_as_character_list(v); names = v.names)
        append!(lines, _print_vec_v(cv, nothing, quote_, right))
    end
    maxl = max_levels === nothing ? true : max_levels
    if maxl !== false && maxl != 0
        q = quote_ ? '"' : _NOQ
        lev = String[_encode_string(s, 0, q, "none") for s in v.levels]
        nl = length(lev)
        colsep = v.ordered ? " < " : " "
        T0 = "Levels: "
        if maxl isa Bool
            width = _OPT[:width] - (length(T0) + 3 + 1 + 3)
            lenl = cumsum(Int[nchar(s, "width") + length(colsep) for s in lev])
            if nl <= 1 || lenl[nl] <= width
                maxl = nl
            else
                maxl = max(1, findfirst(>(width), lenl) - 1)
            end
        end
        drop = nl > maxl
        parts = drop ? vcat(lev[1:max(1, maxl - 1)], ["..."], maxl > 1 ? [lev[nl]] : String[]) : lev
        txt = (drop ? string(nl) * " " : "") * T0 * join(parts, colsep)
        append!(lines, split(txt, '\n'))
    end
    return String.(lines)
end

"""
    print_factor(x; quote_ = false, max_levels = nothing, levels = nothing, ordered = false, right = false)

`print(<factor>)`. `x`: `RFactor` oder Werte (mit `levels`, sonst sortierte
eindeutige Werte).
"""
function print_factor(x; quote_ = false, max_levels = nothing, levels = nothing, ordered = false, right = false)
    if levels !== nothing
        f = r_factor(x; levels, ordered)
        v = _Vf(f.codes, f.levels; ordered = f.ordered)
    else
        v = _as_v(x)
        if v.type !== :factor
            f = r_factor(_Vs(_as_character_list(v)); ordered)
            v = _Vf(f.codes, f.levels; names = v.names, ordered)
        end
    end
    return join(_print_factor_lines(v, quote_, max_levels, right), "\n")
end

# ── Matrizen ───────────────────────────────────────────────────────────────

"printMatrix. cols: Vektor von _V je Spalte (gleicher Typ)."
function _matrix_lines(cols::Vector{_V}, ctype::Symbol, r::Int, c::Int, rl, cl, rn = nothing, cn = nothing,
                       quote_::Char = _NOQ, right = false, digits = nothing)
    r == 0 && c == 0 && return ["<0 x 0 matrix>"]
    gap = 1
    width_opt = _OPT[:width]
    rlabw = rl !== nothing ? _format_string(rl) : _index_width(r + 1) + 3
    lbloff = 0
    if rn !== nothing
        rnw = _strwid(rn)
        lbloff = rnw < rlabw + 2 ? 2 : rnw - rlabw
        rlabw += lbloff
    end
    is_str = ctype === :character
    w = Int[]
    enc = Tuple{Int,Int,String}[]
    for j in 1:c
        col = cols[j]
        if is_str
            wj = _format_string(col.s, quote_)
        elseif ctype === :double
            wj, dj, ej = _format_real(col, digits)
            push!(enc, (dj, ej, ""))
        elseif ctype === :integer
            wj = _format_integer(col)
        elseif ctype === :logical
            wj = _format_logical(col)
        else
            error(string(ctype))
        end
        clabw = cl !== nothing ? (cl[j] === nothing ? 4 : _strwid(cl[j])) : _index_width(j) + 3
        wj < clabw && (wj = clabw)
        is_str || (wj += gap)
        push!(w, wj)
    end
    if ctype === :double
        enc = [(enc[j][1], enc[j][2], _realfmt(w[j], enc[j][1], enc[j][2])) for j in 1:c]
    end
    function row_label(i)
        if rl !== nothing
            s = rl[i]
            l = s === nothing ? 4 : _strwid(s)
            return " "^lbloff * _encode_string(s, l, _NOQ, "left") * " "^(rlabw - l - lbloff)
        end
        return " "^(rlabw - 3 - _index_width(i)) * "[" * string(i) * ",]"
    end
    function col_label(j)
        if is_str
            if cl !== nothing
                s = cl[j]
                l = s === nothing ? 4 : _strwid(s)
                right && return " "^(gap + w[j] - l) * _encode_string(s, l, _NOQ, "right")
                return " "^gap * _encode_string(s, l, _NOQ, "left") * " "^(w[j] - l)
            end
            return " "^gap * "[," * string(j) * "]" * " "^(w[j] - _index_width(j) - 3)
        end
        if cl !== nothing
            s = cl[j]
            l = s === nothing ? 4 : _strwid(s)
            return " "^(w[j] - l) * _encode_string(s, l, _NOQ, "left")
        end
        return " "^(w[j] - _index_width(j) - 3) * "[," * string(j) * "]"
    end
    function cell(i, j)
        col = cols[j]
        is_str && return " "^gap * _encode_string(col.s[i], w[j], quote_, right ? "right" : "left")
        if ctype === :double
            dj, ej, f = enc[j]
            return _encode_real(col.d[i], w[j], dj, ej, _OPT[:OutDec], col.na[i], f)
        end
        ctype === :integer && return _encode_integer(col.i[i], col.na[i], w[j])
        return _encode_logical(col.l[i], col.na[i], w[j])
    end
    lines = String[]
    function head()
        cn !== nothing && push!(lines, " "^rlabw * cn)
        if rn !== nothing
            return _strwid(rn) < rlabw ? rn * " "^(rlabw - length(rn)) : rn
        end
        return " "^rlabw
    end
    extra = is_str ? gap : 0
    if c == 0
        cur = head()
        for i in 1:r
            push!(lines, cur)
            cur = row_label(i)
        end
        push!(lines, cur)
        return lines
    end
    jmin = 1
    while jmin <= c
        width = rlabw
        jmax = jmin
        while true
            width += w[jmax] + extra
            jmax += 1
            (jmax <= c && width + w[jmax] + extra < width_opt) || break
        end
        cur = head()
        cur *= join(col_label(j) for j in jmin:jmax-1)
        for i in 1:r
            push!(lines, cur)
            cur = row_label(i) * join(cell(i, j) for j in jmin:jmax-1)
        end
        push!(lines, cur)
        jmin = jmax
    end
    return lines
end

"""
    print_matrix(m; rownames = nothing, colnames = nothing, quote_ = true, right = false,
                 digits = nothing, type = nothing, dimnames_names = nothing)

`print(<matrix>)`: `Matrix` oder `NamedMat` (dimnames). `type` erzwingt den
R-Typ ("integer", "double", "logical", "character"); `dimnames_names` =
(Zeilentitel, Spaltentitel) = `names(dimnames(m))`.
"""
function print_matrix(m; rownames = nothing, colnames = nothing, quote_ = true, right = false, digits = nothing,
                      type = nothing, dimnames_names = nothing)
    rl = cl = nothing
    if m isa SimLev.NamedMat
        rl = _strnames(m.rownames)
        cl = _strnames(m.colnames)
        a = m.data
    elseif m isa AbstractMatrix
        a = m
    elseif m isa AbstractVector
        a = reshape(collect(m), :, 1)
    else
        error("print_matrix: Matrix erwartet")
    end
    rownames !== nothing && (rl = _strnames(rownames))
    colnames !== nothing && (cl = _strnames(colnames))
    r, c = size(a)
    whole = length(a) == 0 && type === nothing ? _Vl(Bool[], Bool[]) : _as_v(vec(a), type)
    ctype = whole.type
    if ctype === :factor
        whole = _coerce(whole, :character); ctype = :character
    end
    if ctype === :Date
        whole = _Vs(_format_date_list(whole.d, _Str["%Y-%m-%d"])); ctype = :character
    end
    cols = _V[_subset(whole, (j-1)*r+1:j*r) for j in 1:c]
    rn, cn = dimnames_names === nothing ? (nothing, nothing) : dimnames_names
    q = (quote_ === nothing || quote_ === true) ? '"' : _NOQ
    return join(_matrix_lines(cols, ctype, r, c, rl, cl, rn, cn, q, right, digits), "\n")
end

# ── data.frame ─────────────────────────────────────────────────────────────

_df_rownames(df::SimLev.RFrame) = df.rownames === nothing ? _Str[string(i) for i in 1:SimLev.nrow(df)] : _strnames(df.rownames)

"format() einer data.frame-Spalte (wie in format.data.frame) → Vector{nothing/String}."
function _fmt_column(col; digits = nothing, na_encode = false, justify = "none", type = nothing)
    v = _as_v(col isa SimLev.RVector ? col.values : col, type)
    v.names = nothing
    v.scalar = false
    v.type === :Date && return _format_date_list(v.d, _Str["%Y-%m-%d"])
    v.type === :factor && (v = _Vs(_as_character_list(v)))
    v.type === :character && return _format_internal(v; digits, justify, na_encode)
    return _format_internal(v; digits, justify = "right", na_encode)
end

_as_frame(df::SimLev.RFrame) = df
_as_frame(df::NamedTuple) = SimLev.RFrame((String(k) => v for (k, v) in pairs(df))...)
_as_frame(df::AbstractDict) = SimLev.RFrame((String(k) => v for (k, v) in df)...)
_as_frame(df::AbstractVector{<:Pair}) = SimLev.RFrame((String(p.first) => p.second for p in df)...)

"""
    format_data_frame(df; digits = nothing, na_encode = false, justify = "none", types = nothing)

`format.data.frame`: Vektor der formatierten Spalten (`String`/`missing`).
"""
function format_data_frame(df; digits = nothing, na_encode = false, justify = "none", types = nothing)
    df = _as_frame(df)
    nms = names(df)
    return [_jvec(_fmt_column(getfield(df, :cols)[j]; digits, na_encode, justify,
                              type = types === nothing ? nothing : get(types, nms[j], nothing))) for j in eachindex(nms)]
end

"""
    print_data_frame(df; row_names = true, digits = nothing, right = true, quote_ = false, types = nothing)

Text von `print(<data.frame>)` wie `print.data.frame`. `row_names`: `true`,
`false` oder eigene Zeilennamen; `types`: Spaltenname → R-Typ, falls der
Julia-Typ nicht passt (z. B. "integer" für ganzzahlige Float64-Spalten).
"""
function print_data_frame(df; row_names = true, digits = nothing, right = true, quote_ = false, types = nothing)
    df = _as_frame(df)
    n = SimLev.nrow(df)
    nc = SimLev.ncol(df)
    nc == 0 && return "data frame with 0 columns and $n row" * (n == 1 ? "" : "s")
    if n == 0
        return print_vector(names(df); quote_ = false) * "\n<0 rows> (or 0-length row.names)"
    end
    nms = names(df)
    cols = [_fmt_column(getfield(df, :cols)[j]; digits, type = types === nothing ? nothing : get(types, nms[j], nothing))
            for j in 1:nc]
    rl = row_names === true ? _df_rownames(df) :
         (row_names === false || row_names === nothing) ? _Str["" for _ in 1:n] : _Str[string(s) for s in row_names]
    cl = _Str[s for s in nms]
    vcols = _V[_Vs(c) for c in cols]
    q = quote_ === true ? '"' : _NOQ
    return join(_matrix_lines(vcols, :character, n, nc, rl, cl, nothing, nothing, q, right, nothing), "\n")
end

# ── Listen und Verteiler ───────────────────────────────────────────────────

const _RESERVED = Set(["if", "else", "repeat", "while", "function", "for", "next", "break", "TRUE", "FALSE", "NULL",
                       "Inf", "NaN", "NA", "NA_integer_", "NA_real_", "NA_character_", "NA_complex_", "in"])

function _is_valid_name(s::AbstractString)
    isempty(s) && return false
    c = first(s)
    (isletter(c) || c == '.') || return false
    if c == '.' && length(s) > 1
        isdigit(collect(s)[2]) && return false
    end
    all(ch -> isletter(ch) || isdigit(ch) || ch == '.' || ch == '_', s) || return false
    s == "..." && return true
    s in _RESERVED && return false
    occursin(r"^\.\.\d+$", s) && return false
    return true
end

# Objekt mit registrierter print-Methode (S3-Klasse)?
function _own_printer(x)
    (x isa SimLev.RList || x isa SimLev.RFrame || x isa SimLev.RVector) || return nothing
    return SimLev._dispatch(SimLev._PRINTERS, x, "print")
end

_is_list(x) = x isa SimLev.RList || x isa Tuple || (x isa AbstractVector && eltype(x) === Any) || x isa AbstractDict

"PrintValueRec → Zeilen."
function _print_lines(x, tag = "", digits = nothing, quote_ = nothing)
    x === nothing && return ["NULL"]
    f = _own_printer(x)
    f !== nothing && return String.(split(sprint(f, x), '\n'; keepempty = true)) |> _chop_last
    if x isa SimLev.RFrame
        return split(print_data_frame(x; digits), '\n') .|> String
    elseif x isa AbstractMatrix
        return split(print_matrix(x; digits, quote_), '\n') .|> String
    elseif _is_list(x)
        return _print_list_lines(x, tag, digits, quote_)
    end
    return _print_vec_v(_as_v(x), digits, quote_)
end
_chop_last(l::Vector{String}) = (length(l) > 1 && isempty(l[end])) ? l[1:end-1] : l

function _list_items(x)
    if x isa SimLev.RList
        return [(k, v) for (k, v) in x], true
    elseif x isa AbstractDict
        return [(string(k), v) for (k, v) in x], true
    end
    return [(nothing, v) for v in x], false
end

function _print_list_lines(x, tag = "", digits = nothing, quote_ = nothing)
    items, named = _list_items(x)
    isempty(items) && return [named ? "named list()" : "list()"]
    lines = String[]
    for (i, (nm, val)) in enumerate(items)
        i > 1 && push!(lines, "")
        t = (named && nm !== nothing && nm != "") ? tag * (_is_valid_name(nm) ? "\$" * nm : "\$`" * nm * "`") :
            tag * "[[" * string(i) * "]]"
        push!(lines, t)
        if _is_list(val) && _own_printer(val) === nothing
            append!(lines, _print_list_lines(val, t, digits, quote_))
        else
            append!(lines, _print_lines(val, t, digits, quote_))
        end
    end
    push!(lines, "")
    if x isa SimLev.RList && !isempty(SimLev.r_class(x))
        push!(lines, "attr(,\"class\")")
        append!(lines, _print_vector_lines(_Vs(_Str[s for s in SimLev.r_class(x)])))
    end
    return lines
end

"""
    print_list(x; digits = nothing, quote_ = nothing)

`print(<list>)`: `RList`/`Dict` = benannte Liste, `Vector{Any}`/`Tuple` = unbenannte.
"""
print_list(x; digits = nothing, quote_ = nothing) = join(_print_list_lines(x, "", digits, quote_), "\n")

"""
    print_default(x; digits = nothing, quote_ = nothing, right = false, row_names = true)

Verteiler wie `print()`: RFrame → print.data.frame, Matrix → printMatrix,
Liste → print(<list>), RFactor → print.factor, sonst Vektor; Objekte mit
registrierter Klasse über ihre print-Methode.
"""
function print_default(x; digits = nothing, quote_ = nothing, right = false, row_names = true)
    f = _own_printer(x)
    f !== nothing && return sprint(f, x)
    x isa SimLev.RFrame && return print_data_frame(x; row_names, digits)
    x isa AbstractMatrix && return print_matrix(x; digits, quote_, right)
    _is_list(x) && return print_list(x; digits, quote_)
    return print_vector(x; digits, quote_, right)
end

# ── cat ────────────────────────────────────────────────────────────────────

function _cat_items(x)
    v = _as_v(x)
    t = v.type
    t === :NULL && return String[]
    if t === :double
        res = String[]
        for i in 1:length(v)
            xi = v.d[i]
            if v.na[i]
                push!(res, "NA")
                continue
            end
            w, d, e = _format_real([xi], [false])
            push!(res, _encode_real(xi, 0, d, e, _OPT[:OutDec], false))
        end
        return res
    end
    t === :integer && return String[v.na[i] ? "NA" : string(v.i[i]) for i in 1:length(v)]
    t === :logical && return String[v.na[i] ? "NA" : (v.l[i] ? "TRUE" : "FALSE") for i in 1:length(v)]
    t === :character && return String[s === nothing ? "NA" : s for s in v.s]
    t === :Date && return _cat_items(_Vd(copy(v.d), copy(v.na), falses(length(v)) |> collect))
    t === :factor && return String[v.na[i] ? "NA" : string(v.i[i]) for i in 1:length(v)]
    error(string(t))
end

"""
    cat_str(args...; sep = " ", fill = false)

Text, den `cat(..., sep = sep)` ausgäbe (Zahlen mit 7 signifikanten Stellen
je Element wie R).
"""
function cat_str(args...; sep = " ", fill = false)
    seps = sep isa AbstractString ? [String(sep)] : String[string(s) for s in sep]
    nlsep = any(s -> occursin('\n', s), seps)
    out = IOBuffer()
    ntot = 0
    for (iobj, a) in enumerate(args)
        if iobj != 1 && a !== nothing
            print(out, seps[ntot % length(seps) + 1])
            ntot += 1
        end
        items = _cat_items(a)
        n = length(items)
        for i in 1:n
            print(out, items[i])
            if i < n
                print(out, seps[ntot % length(seps) + 1])
                ntot += 1
            end
        end
    end
    (fill !== false || nlsep) && print(out, '\n')
    return String(take!(out))
end

"`cat(...)`: schreibt nach `stdout` (bzw. `file`)."
function r_cat(args...; sep = " ", fill = false, file = nothing)
    print(file === nothing ? stdout : file, cat_str(args...; sep, fill))
    return nothing
end

# ── Standarddruck für RList/RFrame (SimLev._DEFAULT_PRINT) ────────────────

function _default_print(io::IO, x)
    if x isa SimLev.RFrame
        cls = SimLev.r_class(x)
        if isempty(cls) || "data.frame" in cls
            print(io, print_data_frame(x))
        else
            print(io, print_data_frame(x))
        end
    elseif x isa SimLev.RList
        print(io, join(_print_list_lines(x), "\n"))
    else
        print(io, print_default(x))
    end
    return nothing
end

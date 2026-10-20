"""
Nachbildung des optionalen R-Pakets imputeTS 3.4 (Teil: Interpolation).

Nachgebildet sind `na_interpolation(x; option, maxgap, yp, method)` für die
Optionen `"stine"` (stinepack `stinterp`, siehe `RStinepack`) und
`"linear"` (`approx` mit `rule = 2`) sowie `na_locf(x; option, na_remaining,
maxgap)`, das `na_interpolation` für NA am Rand der Stineman-Interpolation
braucht (mit dem C++-Kern `locf` aus `src/locf.cpp`, der auch über `Inf`
hinweg fortschreibt). Eingabeprüfungen, Sonderfälle (keine NA, weniger als
zwei Werte, nicht numerisch), `maxgap` und alle Meldungen wie in imputeTS;
Vektoren (auch `RVector` mit Namen) und numerische Matrizen (spaltenweise,
mit der Warnung von imputeTS für Spalten, die scheitern).

Nicht nachgebildet: `option = "spline"`, `na_remaining = "rm"`/`"mean"` und
Eingaben als data.frame, tibble oder ts (Fehler mit deutscher Meldung); die
unendliche Rekursion von `na_locf` für Reihen ohne einen endlichen Wert (R
bricht mit „C stack usage … is too close to the limit“ ab) endet mit einem
eigenen Fehler.

SimLev nutzt `na_interpolation(…; option = "stine")` in `.fill_na`, wenn
`SimLev.RSuggests.has("imputeTS")` gilt. Vorlage: `python/simlev/_r/imputets.py`.
"""
module RImputeTS

import ..SimLev
import ..SimLev: RList, RVector, RFrame, NA

export na_interpolation, na_locf

const _SP = SimLev.RStinepack

_warn(msg) = (@warn String(msg); nothing)

"R-`if (option == value)` für ein Argument `option`."
function _if_str_eq(option, value::AbstractString)
    option === nothing && error("argument is of length zero")
    if option isa Union{AbstractVector,Tuple}
        a = collect(option)
        isempty(a) && error("argument is of length zero")
        length(a) > 1 && error("the condition has length > 1")
        option = a[1]
    end
    (option === missing || (option isa AbstractFloat && isnan(option))) &&
        error("missing value where TRUE/FALSE needed")
    option isa Symbol && (option = String(option))
    # Zahlen und Wahrheitswerte vergleicht R als Text ("1", "TRUE"): nie gleich `value`
    return option isa AbstractString && option == value
end

"`is.finite(maxgap) && maxgap >= 0`."
_maxgap_active(maxgap) = maxgap isa Real && !(maxgap isa Bool) && isfinite(maxgap) && maxgap >= 0

"Positionen, die `maxgap` wieder auf NA setzt (`inverse.rle` nach `rle(is.na(x))`)."
function _maxgap_mask(na::Vector{Bool}, maxgap)
    out = falses(length(na))
    i = 1; n = length(na)
    while i <= n
        j = i
        while j < n && na[j+1] == na[i]
            j += 1
        end
        if na[i] && !((j - i + 1) <= maxgap)
            out[i:j] .= true
        end
        i = j + 1
    end
    return out
end

"C++-Kern `locf(x, reverse)` aus imputeTS `src/locf.cpp`."
function _locf_core(z0::Vector{Float64}, reverse::Bool)
    z = copy(z0); n = length(z)
    if !reverse
        for i in 2:n
            (!isfinite(z[i]) && isfinite(z[i-1])) && (z[i] = z[i-1])
        end
    else
        for i in n-1:-1:1
            (!isfinite(z[i]) && isfinite(z[i+1])) && (z[i] = z[i+1])
        end
    end
    return z
end

_wrap(x, data) = x isa RVector ? RVector(data; names = x.names) : data
_as_is(x) = x isa Tuple ? collect(x) : x

function _not_supported(x)
    x isa RFrame && error("imputeTS-Nachbildung: Eingaben als data.frame sind nicht nachgebildet.")
    (x isa AbstractDict || x isa NamedTuple) && error("imputeTS-Nachbildung: Eingaben als data.frame sind nicht nachgebildet.")
    nothing
end

_ncol(x) = x isa AbstractMatrix ? size(x, 2) : nothing

"""
    na_locf(x; option = "locf", na_remaining = "rev", maxgap = Inf)

Fehlende Werte durch den letzten (`"locf"`) oder nächsten (`"nocb"`) Wert
ersetzen (imputeTS `na_locf`). `na_remaining`: `"rev"` (aus der
Gegenrichtung füllen) oder `"keep"`. Lücken mit mehr als `maxgap` NA
bleiben NA.
"""
na_locf(x; option = "locf", na_remaining = "rev", maxgap = Inf) = _na_locf(x, option, na_remaining, maxgap, 0)

function _na_locf(x, option, na_remaining, maxgap, depth::Int)
    _not_supported(x)
    ncol = _ncol(x)
    if ncol !== nothing && ncol > 1
        data = Float64.(x)
        for i in 1:ncol
            col = data[:, i]
            any(isnan, col) || continue
            try
                data[:, i] = _na_locf(col, option, na_remaining, maxgap, depth)
            catch cond
                cond isa ErrorException || rethrow()
                _warn("na_locf: No imputation performed for column $i of the input dataset.\n                Reason: $(cond.msg)")
            end
        end
        return data
    end
    kind, vals, _ = _SP.classify(x)
    missindx = _SP.isna_vals(kind, vals)
    any(missindx) || return _as_is(x)
    all(missindx) && error("Input data has only NA values. At least 1 non-NA data point required in the time series to apply na_locf.")
    kind == "num" || error("Input x is not numeric.")
    data = copy(vals)
    imputed = if _if_str_eq(option, "locf")
        _locf_core(data, false)
    elseif _if_str_eq(option, "nocb")
        _locf_core(data, true)
    else
        error("Wrong parameter 'option' given. Value must be either 'locf' or 'nocb'.")
    end
    data[missindx] = imputed[missindx]
    if !any(isnan, data) || _if_str_eq(na_remaining, "keep")
        # nichts zu tun
    elseif _if_str_eq(na_remaining, "rev")
        depth > 200 && error("imputeTS-Nachbildung: na_locf ohne endlichen Wert (R: unendliche Rekursion, " *
                             "„C stack usage … is too close to the limit“).")
        if _if_str_eq(option, "locf")
            data = _na_locf(data, "nocb", "rev", Inf, depth + 1)
        elseif _if_str_eq(option, "nocb")
            data = _na_locf(data, "locf", "rev", Inf, depth + 1)
        end
    elseif _if_str_eq(na_remaining, "rm") || _if_str_eq(na_remaining, "mean")
        error("imputeTS-Nachbildung: na_remaining = 'rm'/'mean' ist nicht nachgebildet.")
    else
        error("Wrong parameter 'na_remaining' given. Value must be either 'keep', 'rm', 'mean' or 'rev'.")
    end
    if _maxgap_active(maxgap)
        ncol !== nothing && error("'x' must be a vector of an atomic type")
        data[_maxgap_mask(missindx, maxgap)] .= NA
    end
    ncol !== nothing && return reshape(data, :, 1)
    return _wrap(x, data)
end

"""
    na_interpolation(x; option = "linear", maxgap = Inf, yp, method)

Fehlende Werte interpolieren (imputeTS `na_interpolation`): `option =
"linear"` (`approx` mit `rule = 2`) oder `"stine"` (Stineman, stinepack
`stinterp`; `yp` und `method` werden durchgereicht); `"spline"` ist nicht
nachgebildet. Lücken mit mehr als `maxgap` NA bleiben NA. Numerische
Matrizen spaltenweise (jede Spalte ohne `yp`/`method`, wie R).
"""
function na_interpolation(x; option = "linear", maxgap = Inf, yp = _SP.MISSING, method = _SP.MISSING)
    _not_supported(x)
    ncol = _ncol(x)
    if ncol !== nothing && ncol > 1
        data = Float64.(x)
        for i in 1:ncol
            col = data[:, i]
            any(isnan, col) || continue
            try
                data[:, i] = na_interpolation(col; option = option, maxgap = maxgap)
            catch cond
                cond isa ErrorException || rethrow()
                _warn("na_interpolation: No imputation performed for column $i of the input dataset.\n                Reason: $(cond.msg)")
            end
        end
        return data
    end
    kind, vals, _ = _SP.classify(x)
    missindx = _SP.isna_vals(kind, vals)
    any(missindx) || return _as_is(x)
    count(!, missindx) < 2 && error("At least 2 non-NA data points required in the time series to apply na_interpolation.")
    kind == "num" || error("Input x is not numeric.")
    n = length(vals)
    indx = findall(!, missindx)
    allx = Float64.(collect(1:n))
    interp = if _if_str_eq(option, "linear")
        (yp === _SP.MISSING && method === _SP.MISSING) ||
            error("imputeTS-Nachbildung: weitere Argumente für approx sind nicht nachgebildet.")
        r = SimLev.RStats.approx(Float64.(indx), vals[indx]; xout = allx, rule = 2)
        Float64.(r["y"])
    elseif _if_str_eq(option, "spline")
        error("imputeTS-Nachbildung: option = 'spline' ist nicht nachgebildet.")
    elseif _if_str_eq(option, "stine")
        ip = Float64.(_SP.stinterp(Float64.(indx), vals[indx], allx; yp = yp, method = method)["y"])
        any(isnan, ip) && (ip = Float64.(na_locf(ip; na_remaining = "rev")))
        ip
    else
        error("Wrong parameter 'option' given. Value must be either 'linear', 'spline' or 'stine'.")
    end
    data = copy(vals)
    data[missindx] = interp[missindx]
    if _maxgap_active(maxgap)
        ncol !== nothing && error("'x' must be a vector of an atomic type")
        data[_maxgap_mask(missindx, maxgap)] .= NA
    end
    ncol !== nothing && return reshape(data, :, 1)
    return _wrap(x, data)
end

end # module

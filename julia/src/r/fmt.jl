# RFmt – R-Formatierung und Druckausgabe (format, formatC, sprintf, round, print …)
#
# Zeichengenaue Nachbildung von R 4.3.3 (format.c, printutils.c,
# printvector.c, printmatrix.c, print.c, paste.c, sprintf.c, util.c,
# nmath/fround.c, nmath/fprec.c, base/R/format.R, dataframe.R, factor.R,
# dates.R); Vorlage python/simlev/_r/fmt.py. Zahlen formatiert wie in R die
# C-Bibliothek (glibc `snprintf` über ccall), `log10`/`pow` aus der glibc-libm,
# `scientific()` mit x87-long-double (SimLev.F80, glibc-`powl`-Tabelle).
#
# Eingaben (R-Typ aus dem Julia-Typ):
#   Float64 / Vector{Float64}        double (SimLev.NA = NA, sonst NaN = NaN)
#   Int / Vector{Int}                integer (|x| > 2^31-1 → double)
#   Bool / Vector{Bool}              logical
#   String / Vector{String}          character
#   Date / Vector{Date}              Date
#   missing in Vektoren              NA des jeweiligen Typs; `missing` allein = logical NA
#   RFactor (r_factor)               factor
#   RVector                          benannter Vektor
#   Matrix / NamedMat                Matrix (mit dimnames)
#   RFrame                           data.frame
#   RList / Vector{Any} / Tuple      Liste (beim Drucken)
#
# Alle print_*-Funktionen liefern den Text, den R mit
# `paste(capture.output(print(x)), collapse = "\n")` erzeugt. NA in
# Zeichenergebnissen ist `missing`.
#
# Namen mit Präfix `r_` wegen Base: `r_round`, `r_sprintf` (auch als
# `sprintf`), `r_cat`; `format` steht auch als `r_format` bereit.
module RFmt

import ..SimLev
using Dates: Dates, Date, DateTime, @dateformat_str

export set_options, get_option, NA_REAL, R_NAN,
       r_round, signif, fround, fprec,
       as_character, paste, paste0, to_string,
       r_format, format_date, format_info, formatC, prettyNum, r_sprintf,
       nchar, encode_string, RFactor, r_factor,
       print_vector, print_matrix, print_data_frame, format_data_frame, print_factor,
       print_list, print_default, r_cat, cat_str

include("_fmt_core.jl")
include("_fmt_format.jl")
include("_fmt_print.jl")

SimLev._DEFAULT_PRINT[] = _default_print
function __init__()
    SimLev._DEFAULT_PRINT[] = _default_print
end

end # module

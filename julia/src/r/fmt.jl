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
#                     core/slc_rbase_date.cpp; seit 1.6.0 round/signif, formatReal/encodeReal,
#                     as.character für Zahlen, formatC (str_signif) und sprintf der C-Kern
#                     core/slc_rbase_fmt.cpp (eine Fassung für Python und Julia).
# RFmt – R-Formatierung und Druckausgabe (format, formatC, sprintf, round, print …)
#
# Zeichengenaue Nachbildung von R 4.3.3 (format.c, printutils.c,
# printvector.c, printmatrix.c, print.c, paste.c, sprintf.c, util.c,
# nmath/fround.c, nmath/fprec.c, base/R/format.R, dataframe.R, factor.R,
# dates.R); Gegenstück python/simlev/_r/fmt.py. Zahlen formatiert seit 1.6.0 der C-Kern
# core/slc_rbase_fmt.cpp (round/signif, formatReal/encodeReal, formatC, sprintf über `snprintf`
# der C-Bibliothek wie R, `scientific()` in long double über `sl_r_scientific`).
#
# Eingaben (R-Typ aus dem Julia-Typ):
#   Float64 / Vector{Float64}        double (SimLev.NA = NA, sonst NaN = NaN)
#   Int / Vector{Int}                integer (|x| > 2^31-1 → double)
#   Bool / Vector{Bool}              logical
#   String / Vector{String}          character
#   Date / Vector{Date}              Date
#   missing in Vektoren              NA des jeweiligen Typs; `missing` allein = logical NA
#   RFactor                          factor
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
# `sprintf`); `format` steht auch als `r_format` bereit.
module RFmt

import ..SimLev
using Dates: Dates, Date, DateTime, @dateformat_str

export set_options,
       r_round, signif, fround, fprec,
       as_character, paste, paste0,
       r_format, formatC, r_sprintf,
       nchar, RFactor,
       print_vector, print_matrix, print_data_frame,
       print_list, print_default

include("_fmt_core.jl")
include("_fmt_format.jl")
include("_fmt_print.jl")

SimLev._DEFAULT_PRINT[] = _default_print
function __init__()
    SimLev._DEFAULT_PRINT[] = _default_print
end

end # module

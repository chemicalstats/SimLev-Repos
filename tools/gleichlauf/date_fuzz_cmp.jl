# N10: Vergleich des Datumskerns core/slc_rbase_date.c (über libslc) mit R (date_fuzz.R).
#   julia --project=julia tools/gleichlauf/date_fuzz_cmp.jl <ordner>
using SimLev

function unesc(s)
    io = IOBuffer(); cs = collect(s); i = 1
    while i <= length(cs)
        if cs[i] == '\\' && i < length(cs)
            print(io, cs[i+1] == 'n' ? '\n' : cs[i+1] == 't' ? '\t' : '\\'); i += 2
        else
            print(io, cs[i]); i += 1
        end
    end
    String(take!(io))
end
esc(s) = replace(s, "\\" => "\\\\", "\t" => "\\t", "\n" => "\\n")

const D = ARGS[1]
function cmp_fmt(file, show)
    rows = [split(l, '\t') for l in eachline(joinpath(D, file))]
    nf = 0
    for r in rows
        g = SimLev.RFmt._format_date_list([parse(Float64, r[1])], [unesc(r[2])])[1]
        g = g === nothing ? "<NA>" : esc(g)
        if g != r[3]
            nf += 1
            nf <= show && println("format  Tag $(r[1])  Format $(repr(r[2])): R $(repr(r[3]))  Julia $(repr(g))")
        end
    end
    return nf, length(rows)
end
nf, n1 = cmp_fmt("fmt.tsv", 5)
println("format.Date (dokumentierte Umwandlungen): $(n1 - nf)/$n1 textgleich")
ns, n2 = cmp_fmt("fmt_sys.tsv", 0)
println("format.Date (systemabhängige Formen, nur Bericht): $(n2 - ns)/$n2 textgleich")
prow = [split(l, '\t') for l in eachline(joinpath(D, "parse.tsv"))]
np = 0
for r in prow
    v = SimLev._rb_strptime_ymd(unesc(r[1]), r[2][1])
    g = v === nothing ? "NA" : string(v)
    if g != r[3]
        global np += 1
        np <= 5 && println("as.Date $(repr(r[1])) ($(r[2])): R $(r[3])  Julia $g")
    end
end
println("as.Date:     $(length(prow) - np)/$(length(prow)) gleich")
println("Gesamt: ", nf + np == 0 ? "gleich" : "ABWEICHUNG")
exit(nf + np == 0 ? 0 : 1)

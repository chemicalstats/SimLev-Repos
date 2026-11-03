# N10/N11: Vergleich des Datumskerns core/slc_rbase_date.c (über libslc) mit R (date_fuzz.R).
#   julia --project=julia tests/gleichlauf/date_fuzz_cmp.jl <ordner>
# Wie date_fuzz_cmp.py: fmt.tsv, fmt_sys.tsv (seit N11 Prüfziel), fmt_os.tsv (digits.secs, N11), parse.tsv;
# Ende 1 bei Abweichung.
using SimLev
const F = SimLev.RFmt

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
        ds = length(r) < 4 || r[4] == "NULL" ? nothing : parse(Float64, r[4])
        old = F.set_options(; digits_secs = ds)
        g = try
            x = F._format_date_list([parse(Float64, r[1])], [unesc(r[2])])[1]
            x === nothing ? "<NA>" : esc(x)
        catch e
            e isa ErrorException ? "<ERR>" : rethrow()
        finally
            F.set_options(; old...)
        end
        if g != r[3]
            nf += 1
            nf <= show && println("format  Tag $(r[1])  Format $(repr(r[2]))$(length(r) < 4 ? "" : "  digits.secs " * r[4]): ",
                                  "R $(repr(first(r[3], 200)))  Julia $(repr(first(g, 200)))")
        end
    end
    return nf, length(rows)
end
bad = 0
for (file, what) in (("fmt.tsv", "dokumentierte Umwandlungen"), ("fmt_sys.tsv", "systemabhängige Formen wie glibc"),
                     ("fmt_os.tsv", "%OS mit digits.secs"))
    isfile(joinpath(D, file)) || continue
    nf, n1 = cmp_fmt(file, 5)
    global bad += nf
    println("format.Date ($what): $(n1 - nf)/$n1 textgleich")
end
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
println("Gesamt: ", bad + np == 0 ? "gleich" : "ABWEICHUNG")
exit(bad + np == 0 ? 0 : 1)

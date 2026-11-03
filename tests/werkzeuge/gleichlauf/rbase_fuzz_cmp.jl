# Vergleich der Kerne core/slc_rbase*.c (seit 1.2.0; seit 1.3.0 auch slc_rbase_num.c über seine Nutzer) über die Julia-Hüllen (libslc, ccall) mit R (tests/werkzeuge/gleichlauf/rbase_fuzz.R).
#   julia --project=julia tests/werkzeuge/gleichlauf/rbase_fuzz_cmp.jl <ordner>
using SimLev
using Logging
disable_logging(Logging.Warn)   # Warnungen von %% (Genauigkeit) nicht ausgeben
const S = SimLev
const D = ARGS[1]
isna(v) = isnan(v) && (reinterpret(UInt64, v) & 0xFFFFFFFF) == 1954
function same(a, b)
    a = Float64.(vec([a;])); b = Float64.(vec([b;]))
    length(a) == length(b) || return false
    all(i -> reinterpret(UInt64, a[i]) == reinterpret(UInt64, b[i]) || (isnan(a[i]) && isnan(b[i]) && isna(a[i]) == isna(b[i])), eachindex(a))
end
mutable struct Rd; a::Vector{Float64}; p::Int; end
Rd(k) = Rd(reinterpret(Float64, read(joinpath(D, k * ".bin"))) |> collect, 1)
function nxt(r::Rd)
    n = r.a[r.p]; r.p += 1
    n < 0 && return nothing
    v = r.a[r.p:r.p+Int(n)-1]; r.p += Int(n); v
end
done(r::Rd) = r.p > length(r.a)
stats = Dict{String,Vector{Int}}()
chk(k, got, exp) = (s = get!(stats, k, [0, 0]); s[1] += 1; ok = (got === nothing || exp === nothing) ? (got === exp) : same(got, exp); ok || (s[2] += 1))

r = Rd("sums")
while !done(r)
    x = nxt(r); narm = nxt(r)[1] != 0; rs = [nxt(r) for _ in 1:8]
    xn = filter(!isnan, x)
    chk("sum", S._rb_sum(x, narm), rs[1]); chk("prod", S._rb_prod(x, narm), rs[2])
    chk("mean", S._rb_mean(narm ? xn : x), rs[3]); chk("var", S._rb_var(xn), rs[4])
    chk("cumsum", S._rb_cumsum(x), rs[5]); chk("cumprod", S._rb_cumprod(x), rs[6])
    chk("cummax", S._rb_cummax(x), rs[7]); chk("cummin", S._rb_cummin(x), rs[8])
end
r = Rd("meanint"); while !done(r); x = nxt(r); chk("mean_int", S._rb_mean_int(Int64.(x)), nxt(r)); end
r = Rd("margins")
while !done(r)
    nr = Int(nxt(r)[1]); nc = Int(nxt(r)[1]); x = nxt(r); narm = nxt(r)[1] != 0; rs = [nxt(r) for _ in 1:4]
    for (i, (rows, mean)) in enumerate(((false, false), (false, true), (true, false), (true, true)))
        chk("margsums", S._rb_margsums(x, nr, nc, narm, mean, rows), rs[i])
    end
end
r = Rd("pow"); while !done(r); x = nxt(r); y = nxt(r)[1]; chk("pow", S._rb_pow(x, y), nxt(r)); end
r = Rd("order")
while !done(r)
    nk = Int(nxt(r)[1]); keys = nxt(r); dec = nxt(r) .!= 0; nl = Int(nxt(r)[1]); e = nxt(r)
    n = length(keys) ÷ nk
    chk("order", Float64.(S._rb_order([keys[(k-1)*n+1:k*n] for k in 1:nk], collect(dec), nl)), e)
end
const TM = ["average", "first", "last", "min", "max"]
r = Rd("rank"); while !done(r); x = nxt(r); t = Int(nxt(r)[1]); chk("rank", S._rb_rank(x, TM[t+1]), nxt(r)); end
r = Rd("psort"); while !done(r); x = nxt(r); k = Int64.(nxt(r)); chk("psort", S._rb_psort(x, k), nxt(r)); end
r = Rd("quantile"); while !done(r); x = nxt(r); p = nxt(r); t = Int(nxt(r)[1]); chk("quantile", S._rb_quantile(x, p, t), nxt(r)); end
r = Rd("tabulate"); while !done(r); b = nxt(r); nb = Int(nxt(r)[1]); chk("tabulate", Float64.(S._rb_tabulate(b, nb)), nxt(r)); end
r = Rd("findint")
while !done(r); v = nxt(r); x = nxt(r); fl = nxt(r) .!= 0; chk("findInterval", S._rb_findinterval(v, x, fl[1], fl[2], fl[3]), nxt(r)); end
r = Rd("cov")
while !done(r)
    n = Int(nxt(r)[1]); ncx = Int(nxt(r)[1]); x = nxt(r); ncy = Int(nxt(r)[1]); y = nxt(r)
    use = Int(nxt(r)[1]); kend = nxt(r)[1] != 0; cr = nxt(r)[1] != 0; e = nxt(r)
    got = nothing
    if !(isempty(x) && !(use in (4, 5)))
        got = try
            S._rb_cov(x, n, ncx, ncy > 0 ? y : nothing, ncy, use, kend, cr)[1]
        catch
            nothing
        end
    end
    chk("cov", got, e)
end
# 12 (seit 1.3.0) Nutzer von slc_rbase_num.c: R_strtod (as.numeric), %% und %/%, format (scientific())
if isfile(joinpath(D, "strtod.bin"))
    r = Rd("strtod")
    while !done(r)
        s = String(Char.(Int.(nxt(r)))); e = nxt(r)
        chk("as.numeric", [S.RExpr._str2num(s)[1]], e)
    end
    if isfile(joinpath(D, "strtod_long.bin"))
        r = Rd("strtod_long")
        while !done(r)
            s = String(Char.(Int.(nxt(r)))); e = nxt(r); w = nxt(r)
            v, bad = S.RExpr._str2num(s)
            chk("as.numeric lang (RExpr)", [v, Float64(bad)], vcat(e, w))
            z, isna_, _, bad2 = S.RFmt._r_strtod(s)
            chk("as.numeric lang (RFmt)", [isna_ ? S.NA : z, Float64(bad2)], vcat(e, w))
        end
    end
    r = Rd("mod")
    while !done(r)
        x = nxt(r)[1]; y = nxt(r)[1]; e1 = nxt(r); e2 = nxt(r)
        g1 = S.RExpr.r_fmod(x, y)
        chk("%%", [g1], e1); chk("%/%", [S.RExpr.r_idiv(x, y)], e2)
        # %% streng (alle 64 Bit, auch Vorzeichen und Nutzlast eines NaN)
        st = get!(stats, "%% streng", [0, 0]); st[1] += 1
        reinterpret(UInt64, g1) == reinterpret(UInt64, e1[1]) || (st[2] += 1)
    end
    r = Rd("format")
    while !done(r)
        x = nxt(r); dg = Int(nxt(r)[1]); e = String(Char.(Int.(nxt(r))))
        for (nm, g) in (("format (RFmt)", join(S.RFmt.r_format(x; digits = dg), "|")),
                        ("format (rformat)", join(S.r_format(x; digits = dg), "|")))
            st = get!(stats, nm, [0, 0]); st[1] += 1
            g == e || (st[2] += 1; st[2] <= 3 && println("Beispiel $nm: $x digits $dg: Julia $(repr(g)) R $(repr(e))"))
        end
    end
end
bad = 0
for k in sort(collect(keys(stats)))
    global bad += stats[k][2]
    println(rpad(k, 14), lpad(stats[k][1], 7), " Fälle, ", stats[k][2], " abweichend (NaN-Vorzeichen nicht gezählt)")
end
println("GESAMT ", bad == 0 ? "ok" : "$bad ABWEICHUNGEN")
exit(bad == 0 ? 0 : 1)

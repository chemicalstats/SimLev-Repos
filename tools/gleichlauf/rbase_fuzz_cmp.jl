# N8: Vergleich der Kerne core/slc_rbase*.c über die Julia-Hüllen (libslc, ccall) mit R (tools/gleichlauf/rbase_fuzz.R).
#   julia --project=julia tools/gleichlauf/rbase_fuzz_cmp.jl <ordner>
using SimLev
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
bad = 0
for k in sort(collect(keys(stats)))
    global bad += stats[k][2]
    println(rpad(k, 14), lpad(stats[k][1], 7), " Fälle, ", stats[k][2], " abweichend (NaN-Vorzeichen nicht gezählt)")
end
println("GESAMT ", bad == 0 ? "ok" : "$bad ABWEICHUNGEN")
exit(bad == 0 ? 0 : 1)

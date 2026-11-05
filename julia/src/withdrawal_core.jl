# WithdrawalCore – .wd_simulate aus core/withdrawal_core_impl.h: geteilter C++-Kern wie in R und Python über
# die C-ABI-Hülle core/simlev_cabi.cpp (CAbi). Der frühere Julia-Port (rule_amount, pmt_due,
# FIFO-Steuer) ist seit 1.2.0 entfallen. Seit 1.5.0 auch die Auswertung je Pfad (wd_metrics, wd_pwr,
# wd_annual_prod, wd_tariff_compact). Gegenstück zu python/simlev/_withdrawal_core.py.
module WithdrawalCore

import ..SimLev
using ..SimLev: CAbi, LIBSLC

export wd_simulate, wd_metrics, wd_pwr, wd_annual_prod, wd_tariff_compact

# Eingaben der Kerne: alle nur gelesen (const in core/simlev_cabi.cpp); seit 1.6.3 eine Matrix{Float64} ohne Kopie
# (bis 1.6.2 je Aufruf kopiert, bei 10 000 x 480 Pfaden rund 150 MB je withdrawal_simulation)
function _mat(x, nr = 0)
    x isa Matrix{Float64} && return x
    x isa SimLev.NamedMat{Float64} && return x.data
    x isa SimLev.NamedMat && return Matrix{Float64}(x.data)
    x isa AbstractMatrix && return Matrix{Float64}(x)
    x isa Number && return fill(Float64(x), 1, 1)
    v = Float64[Float64(z) for z in vec(collect(x))]
    return isempty(v) ? zeros(nr, 0) : reshape(v, length(v), 1)
end
_dv(x) = x === nothing ? Float64[] : x isa Number ? [Float64(x)] : Float64[Float64(v) for v in vec(collect(x))]
_iv(x) = x === nothing ? Int[] : x isa Number ? [Int(x)] : Int[Int(v) for v in vec(collect(x))]

"""
    wd_simulate(R, INF, CAPE, BASE, ppy, rule, rp, start_timing, start_value, income_real,
                tax_on, tax_rate, tfs, spb_annual, vp_on, cost, basis_ratio, loss0, keep,
                lot_n = [], lot_basis = [], lot_vp = [], lot_group = [], spb_first = -1, horizon_end = false,
                tariff_par = [], zve = [])

Schneller Entnahme-Kern (`.wd_simulate`); Rückgabe RList wie die R-Liste.
"""
function wd_simulate(R, INF, CAPE, BASE, ppy, rule, rp, start_timing, start_value, income_real,
                     tax_on, tax_rate, tfs, spb_annual, vp_on, cost, basis_ratio, loss0, keep,
                     lot_n = Float64[], lot_basis = Float64[], lot_vp = Float64[], lot_group = Int[],
                     spb_first = -1.0, horizon_end = false, tariff_par = Float64[], zve = Float64[])
    R = _mat(R)
    INF = _mat(INF)
    CAPE = _mat(CAPE, size(R, 1))
    BASE = _mat(BASE)
    np_, paths = size(R)
    lot_n = _dv(lot_n); lot_basis = _dv(lot_basis); lot_vp = _dv(lot_vp)
    lot_group = Cint[Cint(v) for v in _iv(lot_group)]
    ppy = Int(clamp(Int128(ppy), typemin(Cint), typemax(Cint)))
    rp = _dv(rp); income_real = _dv(income_real)
    keep = Bool(keep); horizon_end = Bool(horizon_end)
    tariff_par = _dv(tariff_par); zve = _dv(zve)
    # Abmessungen der Ergebnisse wie im Kern (bei ppy < 1 meldet der Kern den Fehler vorher)
    ny = ppy >= 1 ? cld(np_, ppy) : 0
    wd = keep ? (ny + 1, paths) : (0, 0)
    ed = horizon_end ? (ny + 1, paths) : (0, 0)
    wealth = Matrix{Float64}(undef, wd); spend = Matrix{Float64}(undef, ny, paths)
    planned = Matrix{Float64}(undef, ny, paths)
    terminal = Vector{Float64}(undef, paths); terminal_nom = Vector{Float64}(undef, paths)
    taxes = Vector{Float64}(undef, paths); depl = Vector{Float64}(undef, paths); fail = Vector{Float64}(undef, paths)
    wealth_end = Matrix{Float64}(undef, ed); taxes_end = Matrix{Float64}(undef, ed)
    # Jahreszeilen des Tarifwegs (25 Zeilen, (ny + 1) x Pfade Spalten; ohne Tarifweg leer)
    td = Bool(tax_on) && !isempty(tariff_par) ? (25, (ny + 1) * paths) : (0, 0)
    tariff_years = Matrix{Float64}(undef, td)
    outs = (wealth, spend, planned, terminal, terminal_nom, taxes, depl, fail, wealth_end, taxes_end, tariff_years)
    mats = (R, INF, CAPE, BASE)
    dims = Int64[size(R, 1), size(R, 2), size(INF, 1), size(INF, 2), size(CAPE, 1), size(CAPE, 2),
                 size(BASE, 1), size(BASE, 2)]
    odims = zeros(Int64, 8)
    GC.@preserve mats outs begin
        mp = Ptr{Float64}[pointer(m) for m in mats]
        op = Ptr{Float64}[pointer(o) for o in outs]
        ol = Int64[length(o) for o in outs]
        CAbi.check(ccall((:simlev_c_wd_simulate, LIBSLC), Cint,
                         (Ptr{Ptr{Float64}}, Ptr{Int64}, Int64, Int64, Ptr{Float64}, Int64, Cint, Float64,
                          Ptr{Float64}, Int64, Cint, Float64, Float64, Float64, Cint, Float64, Float64, Float64,
                          Cint, Ptr{Float64}, Int64, Ptr{Float64}, Int64, Ptr{Float64}, Int64, Ptr{Cint}, Int64,
                          Float64, Cint, Ptr{Float64}, Int64, Ptr{Float64}, Int64, Ptr{Ptr{Float64}}, Ptr{Int64},
                          Ptr{Int64}),
                         mp, dims, ppy, Int(rule), rp, length(rp), Bool(start_timing), Float64(start_value),
                         income_real, length(income_real), Bool(tax_on), Float64(tax_rate), Float64(tfs),
                         Float64(spb_annual), Bool(vp_on), Float64(cost), Float64(basis_ratio), Float64(loss0),
                         keep, lot_n, length(lot_n), lot_basis, length(lot_basis), lot_vp, length(lot_vp),
                         lot_group, length(lot_group), Float64(spb_first), horizon_end, tariff_par, length(tariff_par),
                         zve, length(zve), op, ol, odims))
    end
    out = SimLev.RList("wealth" => wealth, "spending" => spend, "planned" => planned, "terminal_real" => terminal,
                       "terminal_nominal" => terminal_nom, "taxes_real" => taxes, "failed" => fail,
                       "depletion_period" => depl, "wealth_end" => wealth_end, "taxes_end" => taxes_end)
    isempty(tariff_par) || (out["tariff_years"] = tariff_years)   # Jahreszeilen nur mit Tarifweg
    return out
end

# ── Auswertung je Pfad (seit 1.5.0) ─────────────────────────────────────────────────────────────────────────────

_hv(H) = H === nothing ? nothing : Cint[Cint(v) for v in H]

"""
    wd_metrics(sp, nfy, H, gamma, start_value)

Kennzahlen der Entnahmen je Pfad (R: `.wd_metrics`): RList mit `mean_spending`, `min_spending`,
`spending_drawdown`, `ce_spending`, `total_spending`; `H` `nothing` oder Horizont je Pfad.
"""
function wd_metrics(sp, nfy, H, gamma, start_value)
    sp = _mat(sp)
    ny, np_ = size(sp)
    outs = ntuple(_ -> Vector{Float64}(undef, np_), 5)
    hv = _hv(H)
    GC.@preserve sp outs hv begin
        op = Ptr{Float64}[pointer(o) for o in outs]
        CAbi.check(ccall((:simlev_c_wd_metrics, LIBSLC), Cint,
                         (Ptr{Float64}, Int64, Int64, Int64, Ptr{Cint}, Float64, Float64, Ptr{Ptr{Float64}}),
                         sp, ny, np_, Int(nfy), hv === nothing ? C_NULL : pointer(hv), Float64(gamma),
                         Float64(start_value), op))
    end
    return SimLev.RList("mean_spending" => outs[1], "min_spending" => outs[2], "spending_drawdown" => outs[3],
                        "ce_spending" => outs[4], "total_spending" => outs[5])
end

"""
    wd_pwr(AR, legacy, H = nothing) -> (pwr, status, path)

Perfect Withdrawal Rate je Spalte (R: `.wd_pwr`); status 1 nicht endlich, 2 Median < 0.5, 3 negativ (dann pwr
unvollständig, path der erste ungültige Pfad mit `H`).
"""
function wd_pwr(AR, legacy, H = nothing)
    AR = _mat(AR)
    ny, np_ = size(AR)
    out = Vector{Float64}(undef, np_)
    st = Ref{Int32}(0); path = Ref{Int64}(0)
    hv = _hv(H)
    GC.@preserve AR out hv begin
        CAbi.check(ccall((:simlev_c_wd_pwr, LIBSLC), Cint,
                         (Ptr{Float64}, Int64, Int64, Float64, Ptr{Cint}, Ptr{Float64}, Ptr{Int32}, Ptr{Int64}),
                         AR, ny, np_, Float64(legacy), hv === nothing ? C_NULL : pointer(hv), out, st, path))
    end
    return out, Int(st[]), Int(path[])
end

"Produkt je Block von `ppy` Zeilen (R: `.wd_annual_prod`): Matrix `(nr ÷ ppy) × nc`."
function wd_annual_prod(real, ppy)
    real = _mat(real)
    nr, nc = size(real)
    out = Matrix{Float64}(undef, nr ÷ Int(ppy), nc)
    CAbi.check(ccall((:simlev_c_wd_annual_prod, LIBSLC), Cint, (Ptr{Float64}, Int64, Int64, Int64, Ptr{Float64}),
                     real, nr, nc, Int(ppy), out))
    return out
end

"Jahreszeilen des Tarifwegs ohne Jahre NA (R: `.wd_tariff_compact`): Matrix mit Pfad und den 25 Zeilen."
function wd_tariff_compact(M::Matrix{Float64}, ny)
    N = size(M, 2)
    nk = ccall((:simlev_c_wd_tariff_count, LIBSLC), Int64, (Ptr{Float64}, Int64), M, N)
    out = Matrix{Float64}(undef, nk, size(M, 1) + 1)
    CAbi.check(ccall((:simlev_c_wd_tariff_compact, LIBSLC), Cint, (Ptr{Float64}, Int64, Int64, Int64, Ptr{Float64}),
                     M, N, Int(ny), nk, out))
    return out
end

end # module

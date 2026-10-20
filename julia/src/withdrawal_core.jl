# WithdrawalCore – Port von r/src/withdrawal_core.cpp (.wd_simulate)
#
# Rechenreihenfolge 1:1 aus dem C++-Code (IEEE-Doubles, std::pow = glibc pow
# über RLibm.pow). std::min/std::max werden mit ihrer exakten Semantik bei NaN
# nachgebildet. Vorlage: python/simlev/_withdrawal_core.py.
module WithdrawalCore

import ..SimLev
using Dates

export wd_simulate, rule_amount, pmt_due

# Parameter-Slots (siehe R: .wd_param_vector), 1-basiert
const P_RATE, P_CEIL, P_FLOOR, P_CUT, P_RAISE, P_CPR_YEARS, P_INFL_CAP, P_SMOOTH,
      P_EXP_RET, P_CAPE_A, P_CAPE_B, P_RATCH_THR, P_RATCH_GAP, P_EXTRA,
      P_MIN_REAL, P_MAX_REAL, P_AGE, P_MAX_AGE, P_FV, P_FLOOR95, P_SKIP_NEG, P_MAX_RATE = 1:22
const P_N = 22
# Zustands-Slots
const S_T, S_WPREV, S_W1, S_P1, S_WR0, S_LAST_RATCH, S_PREAL_AFTER, S_CPI1 = 1:8
const S_N = 8

"`std::min(a, b)`."
@inline _min(a, b) = b < a ? b : a
"`std::max(a, b)`."
@inline _max(a, b) = a < b ? b : a
@inline _pow(x::Float64, y::Float64) = SimLev.RLibm.pow(x, y)

"Annuität (vorschüssig) je 1 Kapital."
function pmt_due(r::Float64, n::Float64)
    n <= 1.0 && return 1.0
    abs(r) < 1e-12 && return 1.0 / n
    return r / ((1.0 - _pow(1.0 + r, -n)) * (1.0 + r))
end

"Regelberechnung; `st` wird fortgeschrieben, Rückgabe nominaler Jahresbetrag."
function rule_amount(rule::Int, rp::Vector{Float64}, st::Vector{Float64}, P::Float64, infl_prev::Float64,
                     cpi_rel::Float64, r_prev::Float64, cape::Float64, years_rem::Float64)
    st[S_T] += 1.0
    t = st[S_T]
    rate = rp[P_RATE]
    W = 0.0
    P < 0 && (P = 0.0)
    first = t <= 1.0
    if first
        st[S_P1] = P
        st[S_CPI1] = cpi_rel
        st[S_LAST_RATCH] = 1.0
    end
    W1_real = st[S_W1] / _max(st[S_CPI1], 1e-12)
    if rule == 1
        W = first ? rate * P : st[S_WPREV] * infl_prev
    elseif rule == 2
        W = rate * P
    elseif rule == 3
        if first
            W = rate * P
        else
            base = st[S_WPREV] * infl_prev
            target = rate * P
            W = _min(_max(target, base * (1.0 - rp[P_FLOOR])), base * (1.0 + rp[P_CEIL]))
        end
    elseif rule == 4
        if first
            W = rate * P
        else
            W = st[S_WPREV]
            inc = _min(infl_prev, 1.0 + rp[P_INFL_CAP])
            cand = W * inc
            skip = rp[P_SKIP_NEG] > 0.5 && r_prev < 0.0 && (P <= 0 || cand / P > st[S_WR0])
            skip || (W = cand)
            wr = P > 0 ? W / P : Inf
            if wr > st[S_WR0] * (1.0 + rp[P_CEIL]) && years_rem > rp[P_CPR_YEARS]
                W *= (1.0 - rp[P_CUT])
            elseif wr < st[S_WR0] * (1.0 - rp[P_FLOOR])
                W *= (1.0 + rp[P_RAISE])
            end
        end
    elseif rule == 5
        if first
            W = rate * P
        else
            W = _min(_max(rate * P, (1.0 - rp[P_FLOOR]) * W1_real * cpi_rel), (1.0 + rp[P_CEIL]) * W1_real * cpi_rel)
        end
    elseif rule == 6
        W = first ? rate * P : _max(rate * P, rp[P_FLOOR95] * st[S_WPREV])
    elseif rule == 7
        if first
            W = rate * P
        else
            W = st[S_WPREV] * infl_prev
            p_real = P / cpi_rel
            p1_real = st[S_P1] / st[S_CPI1]
            if p_real > rp[P_RATCH_THR] * p1_real && t - st[S_LAST_RATCH] >= rp[P_RATCH_GAP]
                W *= (1.0 + rp[P_RAISE])
                st[S_LAST_RATCH] = t
            end
        end
    elseif rule == 8
        W = first ? rate * P : rp[P_SMOOTH] * st[S_WPREV] * infl_prev + (1.0 - rp[P_SMOOTH]) * rate * P
    elseif rule == 9
        W = P / _max(1.0, years_rem)
    elseif rule == 10
        n = rp[P_MAX_AGE] - (rp[P_AGE] + t - 1.0)
        pct = n <= 1.0 ? 1.0 : _min(pmt_due(rp[P_EXP_RET], n), rp[P_MAX_RATE])
        W = pct * P
    elseif rule == 11
        r = rp[P_EXP_RET]
        n = _max(1.0, years_rem)
        p_real = P / cpi_rel
        fv_disc = rp[P_FV] / _pow(1.0 + r, n)
        W = _max(0.0, (p_real - fv_disc) * pmt_due(r, n)) * cpi_rel
    elseif rule == 12
        W = (rp[P_CAPE_A] + (cape > 0 ? rp[P_CAPE_B] / cape : 0.0)) * P
    elseif rule == 13
        base = first ? rate * P : W1_real * cpi_rel
        gain = first ? 0.0 : _max(0.0, P / cpi_rel - st[S_PREAL_AFTER])
        W = base + rp[P_EXTRA] * gain * cpi_rel
    elseif rule == 14
        n = _max(1.0, years_rem)
        pm = pmt_due(rp[P_EXP_RET], n) * P
        W = first ? pm : rp[P_SMOOTH] * st[S_WPREV] * infl_prev + (1.0 - rp[P_SMOOTH]) * pm
    else
        error("Unbekannte Entnahmeregel $rule")
    end
    rp[P_MIN_REAL] > 0 && (W = _max(W, rp[P_MIN_REAL] * cpi_rel))
    isfinite(rp[P_MAX_REAL]) && (W = _min(W, rp[P_MAX_REAL] * cpi_rel))
    (!isfinite(W) || W < 0) && (W = 0.0)
    if first
        st[S_W1] = W
        st[S_WR0] = P > 0 ? W / P : 0.0
    end
    st[S_WPREV] = W
    st[S_PREAL_AFTER] = _max(0.0, P - W) / cpi_rel
    return W
end

mutable struct _TaxState
    loss::Float64
    spb::Float64
end
Base.copy(t::_TaxState) = _TaxState(t.loss, t.spb)

function _tax_on_gain(gain::Float64, tfs::Float64, rate::Float64, ts::_TaxState)
    taxable = gain * (1.0 - tfs)
    if taxable <= 0
        ts.loss += -taxable
        return 0.0
    end
    use = _min(ts.loss, taxable)
    ts.loss -= use
    taxable -= use
    use = _min(ts.spb, taxable)
    ts.spb -= use
    taxable -= use
    return taxable * rate
end

function _gross_for_net(X, V, basis, tfs, rate, cost, ts::_TaxState, tax_on::Bool)
    keep = 1.0 - cost
    X <= 0 && return 0.0
    (!tax_on || V <= 0) && return X / keep
    g = keep - basis / V
    g <= 0 && return X / keep
    a = g * (1.0 - tfs)
    A = ts.loss + ts.spb
    (X / keep) * a <= A && return X / keep
    return (X - A * rate) / (keep - a * rate)
end

mutable struct _FifoLots
    ng::Int
    n0::Vector{Float64}
    bu::Vector{Float64}
    vpu::Vector{Float64}
    w::Vector{Float64}
    gs::Vector{Int}      # 0-basiert wie C++
    ge::Vector{Int}
    ptr::Vector{Int}
    nf::Vector{Float64}
    vp_acc::Float64
end
_FifoLots() = _FifoLots(0, Float64[], Float64[], Float64[], Float64[], Int[], Int[], Int[], Float64[], 0.0)

function _reset!(F::_FifoLots)
    for g in 1:F.ng
        F.ptr[g] = F.gs[g]
        F.nf[g] = F.n0[F.gs[g]+1]
    end
    F.vp_acc = 0.0
end

"Verkauf aus FIFO-Lots; Rückgabe (G, gain, all)."
function _sell!(F::_FifoLots, X::Float64, u::Float64, keep::Float64, tfs::Float64, rate::Float64, ts::_TaxState)
    A = ts.loss + ts.spb
    c1 = 1.0 - tfs
    Gd = 0.0
    C = 0.0
    all_ = false
    ng, w, ptr, ge, nf, bu, vpu, n0 = F.ng, F.w, F.ptr, F.ge, F.nf, F.bu, F.vpu, F.n0
    while true
        L = Inf
        s = 0.0
        any_ = false
        done = false
        for g in 1:ng
            w[g] == 0.0 && continue
            if ptr[g] >= ge[g]
                done = true
                break
            end
            j = ptr[g] + 1
            val = nf[g] * u
            ln = val / w[g]
            ln < L && (L = ln)
            s += w[g] * (keep - (bu[j] + vpu[j] + F.vp_acc) * nf[g] / val)
            any_ = true
        end
        if done || !any_ || !isfinite(L)
            all_ = true
            for g in 1:ng
                for j in ptr[g]:ge[g]-1
                    nn = j == ptr[g] ? nf[g] : n0[j+1]
                    C += keep * nn * u - (bu[j+1] + vpu[j+1] + F.vp_acc) * nn
                    Gd += nn * u
                end
                ptr[g] = ge[g]
                nf[g] = 0.0
            end
            break
        end
        T0 = c1 * C - A
        k = c1 * s
        net(t) = (tx = T0 + k * t; keep * (Gd + t) - (tx > 0 ? rate * tx : 0.0))
        t = L
        if net(L) >= X
            tk = k != 0.0 ? -T0 / k : -1.0
            cuts = (0.0, (tk > 0.0 && tk < L) ? tk : L, L)
            t = L
            for q in 1:2
                a = cuts[q]
                b = cuts[q+1]
                (b <= a && q > 1) && continue
                taxed = T0 + k * 0.5 * (a + b) > 0.0
                r = taxed ? (X - keep * Gd + rate * T0) / (keep - rate * k) : (X - keep * Gd) / keep
                if r <= b * (1.0 + 1e-12) + 1e-12
                    t = _min(_max(r, a), b)
                    break
                end
            end
        end
        for g in 1:ng
            w[g] == 0.0 && continue
            j = ptr[g] + 1
            val = nf[g] * u
            part = w[g] * t
            cost_u = bu[j] + vpu[j] + F.vp_acc
            if abs(part) >= abs(val) * (1.0 - 1e-12)
                C += keep * val - cost_u * nf[g]
                ptr[g] += 1
                nf[g] = ptr[g] < ge[g] ? n0[ptr[g]+1] : 0.0
            else
                du = part / u
                C += keep * part - cost_u * du
                nf[g] -= du
            end
        end
        Gd += t
        t < L && break
    end
    return Gd, C, all_
end

function _mat(x, nr = 0)
    x isa SimLev.NamedMat && return Matrix{Float64}(x.data)
    x isa AbstractMatrix && return Matrix{Float64}(x)
    x isa Number && return fill(Float64(x), 1, 1)
    v = Float64[Float64(z) for z in vec(collect(x))]
    return isempty(v) ? zeros(nr, 0) : reshape(v, length(v), 1)
end
_dv(x) = x === nothing ? Float64[] : x isa Number ? [Float64(x)] : Float64[Float64(v) for v in vec(collect(x))]
_iv(x) = x === nothing ? Int[] : x isa Number ? [Int(x)] : Int[Int(v) for v in vec(collect(x))]

mutable struct _PathState
    u::Float64
    n::Float64
    basis::Float64
    cpi::Float64
    vp_pending::Float64
    vp_due::Float64
    tax_sum::Float64
    failed::Bool
    depl_p::Float64
end

"""
    wd_simulate(R, INF, CAPE, BASE, ppy, rule, rp, start_timing, start_value, income_real,
                tax_on, tax_rate, tfs, spb_annual, vp_on, cost, basis_ratio, loss0, keep,
                lot_n = [], lot_basis = [], lot_vp = [], lot_group = [], spb_first = -1, horizon_end = false)

Schneller Entnahme-Kern (`.wd_simulate`); Rückgabe RList wie die R-Liste.
"""
function wd_simulate(R, INF, CAPE, BASE, ppy, rule, rp, start_timing, start_value, income_real,
                     tax_on, tax_rate, tfs, spb_annual, vp_on, cost, basis_ratio, loss0, keep,
                     lot_n = Float64[], lot_basis = Float64[], lot_vp = Float64[], lot_group = Int[],
                     spb_first = -1.0, horizon_end = false)
    R = _mat(R)
    INF = _mat(INF)
    CAPE = _mat(CAPE, size(R, 1))
    BASE = _mat(BASE)
    np_, paths = size(R)
    lot_n = _dv(lot_n); lot_basis = _dv(lot_basis); lot_vp = _dv(lot_vp); lot_group = _iv(lot_group)
    nlot = length(lot_n)
    (length(lot_basis) != nlot || length(lot_vp) != nlot || length(lot_group) != nlot) &&
        error("Lot-Vektoren haben verschiedene Längen")
    tax_on = Bool(tax_on)
    use_lots = tax_on && nlot > 0
    FL = _FifoLots()
    if use_lots
        tot = 0.0
        for j in 1:nlot
            if !(lot_n[j] > 0.0 || lot_n[j] < 0.0) || !isfinite(lot_basis[j]) || !isfinite(lot_vp[j])
                error("Lot $j: Einheiten müssen ungleich 0 und alle Werte endlich sein")
            end
            j > 1 && lot_group[j] < lot_group[j-1] && error("Lots müssen nach Gruppe sortiert sein")
            tot += lot_n[j]
        end
        tot > 0.0 || error("Summe der Lot-Einheiten muss positiv sein")
        for j in 1:nlot
            if j == 1 || lot_group[j] != lot_group[j-1]
                push!(FL.gs, j - 1); push!(FL.ge, j - 1); push!(FL.w, 0.0)
            end
            FL.ge[end] = j
            FL.w[end] += lot_n[j] / tot
            push!(FL.n0, lot_n[j])
            push!(FL.bu, lot_basis[j] / lot_n[j])
            push!(FL.vpu, lot_vp[j] / lot_n[j])
        end
        FL.ng = length(FL.gs)
        FL.ptr = zeros(Int, FL.ng)
        FL.nf = zeros(FL.ng)
    end
    ppy = Int(ppy); rule = Int(rule)
    rp = _dv(rp)
    ppy < 1 && error("ppy muss >= 1 sein")
    length(rp) < P_N && error("Parametervektor zu kurz ($(length(rp)) statt $P_N)")
    (size(INF, 1) != np_ || size(INF, 2) != paths) &&
        error("Inflationsmatrix $(size(INF, 1)) x $(size(INF, 2)) passt nicht zu den Renditen $np_ x $paths")
    has_cape = size(CAPE, 2) > 0
    if has_cape && (size(CAPE, 1) < np_ || size(CAPE, 2) != paths)
        error("CAPE-Matrix $(size(CAPE, 1)) x $(size(CAPE, 2)) passt nicht zu den Renditen $np_ x $paths")
    end
    vp_on = Bool(vp_on)
    if tax_on && vp_on && (size(BASE, 1) < np_ || size(BASE, 2) != paths)
        error("Basiszins-Matrix $(size(BASE, 1)) x $(size(BASE, 2)) passt nicht zu den Renditen $np_ x $paths")
    end
    income_real = _dv(income_real)
    np_ > 0 && length(income_real) < 1 && error("income_real darf nicht leer sein")
    ny = (np_ + ppy - 1) ÷ ppy
    keep = Bool(keep); horizon_end = Bool(horizon_end); start_timing = Bool(start_timing)
    tax_rate = Float64(tax_rate); tfs = Float64(tfs); spb_annual = Float64(spb_annual); cost = Float64(cost)
    start_value = Float64(start_value); basis_ratio = Float64(basis_ratio); loss0 = Float64(loss0)
    spb_first = Float64(spb_first)
    wealth = keep ? zeros(ny + 1, paths) : zeros(0, 0)
    spend = zeros(ny, paths)
    planned = zeros(ny, paths)
    terminal = zeros(paths)
    terminal_nom = zeros(paths)
    taxes = zeros(paths)
    depl = zeros(paths)
    fail = zeros(paths)
    wealth_end = horizon_end ? zeros(ny + 1, paths) : zeros(0, 0)
    taxes_end = horizon_end ? zeros(ny + 1, paths) : zeros(0, 0)
    has_base = size(BASE, 2) == paths && size(BASE, 1) >= np_
    inc_n = length(income_real)
    st = zeros(S_N)
    for k in 1:paths
        fill!(st, 0.0)
        S = _PathState(1.0, start_value, start_value * basis_ratio, 1.0, 0.0, 0.0, 0.0, false, SimLev.NA)
        cpi_dec = 1.0
        yr_ret = 1.0
        W = 0.0
        u0 = 1.0
        ts = _TaxState(loss0, spb_annual)
        use_lots && _reset!(FL)

        function sale(target::Float64, V::Float64)
            all_ = false
            u = S.u
            if use_lots
                G, gain, all_ = _sell!(FL, target, u, 1.0 - cost, tfs, tax_rate, ts)
                all_ && (G = V)
                tax = _tax_on_gain(gain, tfs, tax_rate, ts)
            else
                G = _gross_for_net(target, V, S.basis, tfs, tax_rate, cost, ts, tax_on)
                if G >= V
                    G = V
                    all_ = true
                end
                bpart = S.basis * G / V
                tax = tax_on ? _tax_on_gain(G * (1.0 - cost) - bpart, tfs, tax_rate, ts) : 0.0
                S.basis -= bpart
            end
            S.n -= G / u
            if all_
                S.n = 0.0
                S.basis = 0.0
            end
            return G, tax, all_
        end

        function settle_end()
            add = 0.0
            if S.vp_pending > 0
                t0 = _TaxState(ts.loss, spb_annual)
                vtax0 = _tax_on_gain(S.vp_pending, tfs, tax_rate, t0)
                V = S.n * S.u
                paid_all = true
                if vtax0 > 0 && V > 0
                    G, tax, _ = sale(vtax0, V)
                    net = G * (1.0 - cost) - tax
                    add = tax + _min(net, vtax0)
                    paid_all = net >= vtax0 * (1.0 - 1e-12)
                end
                tn = _TaxState(ts.loss, spb_annual)
                vtax1 = _tax_on_gain(S.vp_pending, tfs, tax_rate, tn)
                S.vp_pending = 0.0
                diff = vtax1 - vtax0
                if paid_all && vtax0 > 0 && diff != 0.0
                    ts.loss = tn.loss; ts.spb = tn.spb
                    if diff > 0
                        V = S.n * S.u
                        if V > 0
                            G, tax, _ = sale(diff, V)
                            net = G * (1.0 - cost) - tax
                            add += tax + _min(net, diff)
                        end
                    else
                        if S.u > 0
                            S.n += -diff / S.u
                            S.basis += -diff
                        end
                        add += diff
                    end
                end
            end
            return add
        end

        V_ys = 0.0
        plan_all = false
        if horizon_end
            wealth_end[1, k] = start_value
            taxes_end[1, k] = 0.0
        end
        for p in 0:np_-1
            y = p ÷ ppy
            ypos = p % ppy
            V = S.n * S.u
            if ypos == 0
                keep && (wealth[y+1, k] = V / S.cpi)
                ts.spb = (y == 0 && spb_first >= 0.0) ? spb_first : spb_annual
                if S.vp_pending > 0
                    S.vp_due += _tax_on_gain(S.vp_pending, tfs, tax_rate, ts)
                    S.vp_pending = 0.0
                end
                cpi = S.cpi
                infl_prev = y == 0 ? 1.0 : cpi / cpi_dec
                cp = has_cape ? CAPE[p+1, k] : 0.0
                W = rule_amount(rule, rp, st, V, infl_prev, cpi, yr_ret - 1.0, cp, Float64(ny - y))
                planned[y+1, k] = W / cpi
                cpi_dec = cpi
                yr_ret = 1.0
                u0 = S.u
                V_ys = V
                plan_all = (rule in (9, 10, 11, 14)) && V_ys > 0 && W <= V_ys * (1.0 + 1e-9) &&
                           (W >= V_ys * (1.0 - 1e-12) || y == ny - 1)
            end
            inc = income_real[_min(y, inc_n - 1)+1] * S.cpi / ppy
            need = _max(0.0, W / ppy - inc)
            function withdraw()
                target = need + S.vp_due
                paid_vp = 0.0
                paid = 0.0
                Vw = S.n * S.u
                if target > 0 && Vw > 0
                    G, tax, _ = sale(target, Vw)
                    net = G * (1.0 - cost) - tax
                    S.tax_sum += (tax + S.vp_due) / S.cpi
                    paid_vp = _min(net, S.vp_due)
                    paid = net - paid_vp
                    S.tax_sum -= (S.vp_due - paid_vp) / S.cpi
                end
                S.vp_due = 0.0
                spend[y+1, k] += (paid + inc) / S.cpi
                if paid < need - 1e-8 * _max(1.0, need) && !(plan_all && S.n <= 0.0)
                    if !S.failed
                        S.failed = true
                        S.depl_p = Float64(p + 1)
                    end
                end
            end
            start_timing && withdraw()
            S.u *= R[p+1, k]
            S.u < 0 && (S.u = 0.0)
            S.cpi *= INF[p+1, k]
            yr_ret *= R[p+1, k]
            start_timing || withdraw()
            if ypos == ppy - 1 && tax_on && vp_on && S.n > 0
                br = _max(0.0, BASE[p+1, k]) / 100.0
                vp_ps = _max(0.0, _min(u0 * 0.7 * br, S.u - u0))
                vp = S.n * vp_ps
                if vp > 0
                    S.vp_pending += vp
                    S.basis += vp
                    use_lots && (FL.vp_acc += vp_ps)
                end
            end
            if horizon_end && ypos == ppy - 1 && p < np_ - 1
                n_s, b_s, vpp_s = S.n, S.basis, S.vp_pending
                ts_s = copy(ts)
                if use_lots
                    ptr_s, nf_s, acc_s = copy(FL.ptr), copy(FL.nf), FL.vp_acc
                end
                add = settle_end()
                wealth_end[y+2, k] = S.n * S.u / S.cpi
                taxes_end[y+2, k] = S.tax_sum + add / S.cpi
                S.n, S.basis, S.vp_pending = n_s, b_s, vpp_s
                ts.loss = ts_s.loss; ts.spb = ts_s.spb
                if use_lots
                    FL.ptr = ptr_s; FL.nf = nf_s; FL.vp_acc = acc_s
                end
            end
        end
        S.tax_sum += settle_end() / S.cpi
        Vend = S.n * S.u
        keep && (wealth[ny+1, k] = Vend / S.cpi)
        if horizon_end
            wealth_end[ny+1, k] = Vend / S.cpi
            taxes_end[ny+1, k] = S.tax_sum
        end
        terminal[k] = Vend / S.cpi
        terminal_nom[k] = Vend
        taxes[k] = S.tax_sum
        fail[k] = S.failed ? 1.0 : 0.0
        depl[k] = S.depl_p
    end
    return SimLev.RList("wealth" => wealth, "spending" => spend, "planned" => planned, "terminal_real" => terminal,
                        "terminal_nominal" => terminal_nom, "taxes_real" => taxes, "failed" => fail,
                        "depletion_period" => depl, "wealth_end" => wealth_end, "taxes_end" => taxes_end)
end

end # module

"""Entnahme-Kern (Port von ``r/src/withdrawal_core.cpp``, ``.wd_simulate``).

Rechenreihenfolge 1:1 aus dem C++-Code (IEEE-Doubles, ``std::pow`` = libm
``pow`` über :func:`math.pow`). ``std::min``/``std::max`` werden mit ihrer
exakten Semantik bei NaN nachgebildet.
"""
from __future__ import annotations

import math

import numpy as np

__all__ = ["wd_simulate", "rule_amount", "pmt_due"]

_INF = math.inf
_NAN = float("nan")      # R's NaN
from ._r.fmt import NA_REAL as _NA   # R's NA_real_ (wie NA_REAL in withdrawal_core.cpp)

# Parameter-Slots (siehe R: .wd_param_vector)
(P_RATE, P_CEIL, P_FLOOR, P_CUT, P_RAISE, P_CPR_YEARS, P_INFL_CAP, P_SMOOTH,
 P_EXP_RET, P_CAPE_A, P_CAPE_B, P_RATCH_THR, P_RATCH_GAP, P_EXTRA,
 P_MIN_REAL, P_MAX_REAL, P_AGE, P_MAX_AGE, P_FV, P_FLOOR95, P_SKIP_NEG, P_MAX_RATE,
 P_N) = range(23)
# Zustands-Slots
S_T, S_WPREV, S_W1, S_P1, S_WR0, S_LAST_RATCH, S_PREAL_AFTER, S_CPI1, S_N = range(9)


def _min(a, b):
    """``std::min(a, b)``."""
    return b if b < a else a


def _max(a, b):
    """``std::max(a, b)``."""
    return b if a < b else a


def _pow(x, y):
    try:
        return math.pow(x, y)
    except ValueError:
        return _NAN
    except OverflowError:
        return _INF if (x > 0 or y != math.floor(y) or int(y) % 2 == 0) else -_INF


def _isfinite(x):
    return not (math.isinf(x) or math.isnan(x))


class WdError(ValueError):
    """Fehler des Kerns (Rcpp ``stop``)."""


def pmt_due(r, n):
    """Annuität (vorschüssig) je 1 Kapital."""
    if n <= 1.0:
        return 1.0
    if math.fabs(r) < 1e-12:
        return 1.0 / n
    return r / ((1.0 - _pow(1.0 + r, -n)) * (1.0 + r))


def rule_amount(rule, rp, st, P, infl_prev, cpi_rel, r_prev, cape, years_rem):
    """Regelberechnung; ``st`` (Liste) wird fortgeschrieben, Rückgabe nominaler Jahresbetrag."""
    st[S_T] += 1.0
    t = st[S_T]
    rate = rp[P_RATE]
    W = 0.0
    if P < 0:
        P = 0.0
    first = t <= 1.0
    if first:
        st[S_P1] = P
        st[S_CPI1] = cpi_rel
        st[S_LAST_RATCH] = 1.0
    W1_real = st[S_W1] / _max(st[S_CPI1], 1e-12)
    if rule == 1:
        W = rate * P if first else st[S_WPREV] * infl_prev
    elif rule == 2:
        W = rate * P
    elif rule == 3:
        if first:
            W = rate * P
        else:
            base = st[S_WPREV] * infl_prev
            target = rate * P
            W = _min(_max(target, base * (1.0 - rp[P_FLOOR])), base * (1.0 + rp[P_CEIL]))
    elif rule == 4:
        if first:
            W = rate * P
        else:
            W = st[S_WPREV]
            inc = _min(infl_prev, 1.0 + rp[P_INFL_CAP])
            cand = W * inc
            skip = rp[P_SKIP_NEG] > 0.5 and r_prev < 0.0 and (P <= 0 or cand / P > st[S_WR0])
            if not skip:
                W = cand
            wr = W / P if P > 0 else _INF
            if wr > st[S_WR0] * (1.0 + rp[P_CEIL]) and years_rem > rp[P_CPR_YEARS]:
                W *= (1.0 - rp[P_CUT])
            elif wr < st[S_WR0] * (1.0 - rp[P_FLOOR]):
                W *= (1.0 + rp[P_RAISE])
    elif rule == 5:
        if first:
            W = rate * P
        else:
            W = _min(_max(rate * P, (1.0 - rp[P_FLOOR]) * W1_real * cpi_rel), (1.0 + rp[P_CEIL]) * W1_real * cpi_rel)
    elif rule == 6:
        W = rate * P if first else _max(rate * P, rp[P_FLOOR95] * st[S_WPREV])
    elif rule == 7:
        if first:
            W = rate * P
        else:
            W = st[S_WPREV] * infl_prev
            p_real = P / cpi_rel
            p1_real = st[S_P1] / st[S_CPI1]
            if p_real > rp[P_RATCH_THR] * p1_real and t - st[S_LAST_RATCH] >= rp[P_RATCH_GAP]:
                W *= (1.0 + rp[P_RAISE])
                st[S_LAST_RATCH] = t
    elif rule == 8:
        W = rate * P if first else rp[P_SMOOTH] * st[S_WPREV] * infl_prev + (1.0 - rp[P_SMOOTH]) * rate * P
    elif rule == 9:
        W = P / _max(1.0, years_rem)
    elif rule == 10:
        n = rp[P_MAX_AGE] - (rp[P_AGE] + t - 1.0)
        pct = 1.0 if n <= 1.0 else _min(pmt_due(rp[P_EXP_RET], n), rp[P_MAX_RATE])
        W = pct * P
    elif rule == 11:
        r = rp[P_EXP_RET]
        n = _max(1.0, years_rem)
        p_real = P / cpi_rel
        fv_disc = rp[P_FV] / _pow(1.0 + r, n)
        W = _max(0.0, (p_real - fv_disc) * pmt_due(r, n)) * cpi_rel
    elif rule == 12:
        W = (rp[P_CAPE_A] + (rp[P_CAPE_B] / cape if cape > 0 else 0.0)) * P
    elif rule == 13:
        base = rate * P if first else W1_real * cpi_rel
        gain = 0.0 if first else _max(0.0, P / cpi_rel - st[S_PREAL_AFTER])
        W = base + rp[P_EXTRA] * gain * cpi_rel
    elif rule == 14:
        n = _max(1.0, years_rem)
        pm = pmt_due(rp[P_EXP_RET], n) * P
        W = pm if first else rp[P_SMOOTH] * st[S_WPREV] * infl_prev + (1.0 - rp[P_SMOOTH]) * pm
    else:
        raise WdError("Unbekannte Entnahmeregel %d" % rule)
    if rp[P_MIN_REAL] > 0:
        W = _max(W, rp[P_MIN_REAL] * cpi_rel)
    if _isfinite(rp[P_MAX_REAL]):
        W = _min(W, rp[P_MAX_REAL] * cpi_rel)
    if not _isfinite(W) or W < 0:
        W = 0.0
    if first:
        st[S_W1] = W
        st[S_WR0] = W / P if P > 0 else 0.0
    st[S_WPREV] = W
    st[S_PREAL_AFTER] = _max(0.0, P - W) / cpi_rel
    return W


class _TaxState:
    __slots__ = ("loss", "spb")

    def __init__(self, loss, spb):
        self.loss = loss
        self.spb = spb

    def copy(self):
        return _TaxState(self.loss, self.spb)


def _tax_on_gain(gain, tfs, rate, ts):
    taxable = gain * (1.0 - tfs)
    if taxable <= 0:
        ts.loss += -taxable
        return 0.0
    use = _min(ts.loss, taxable)
    ts.loss -= use
    taxable -= use
    use = _min(ts.spb, taxable)
    ts.spb -= use
    taxable -= use
    return taxable * rate


def _gross_for_net(X, V, basis, tfs, rate, cost, ts, tax_on):
    keep = 1.0 - cost
    if X <= 0:
        return 0.0
    if not tax_on or V <= 0:
        return X / keep
    g = keep - basis / V
    if g <= 0:
        return X / keep
    a = g * (1.0 - tfs)
    A = ts.loss + ts.spb
    if (X / keep) * a <= A:
        return X / keep
    return (X - A * rate) / (keep - a * rate)


class _FifoLots:
    def __init__(self):
        self.ng = 0
        self.n0, self.bu, self.vpu, self.w = [], [], [], []
        self.gs, self.ge = [], []
        self.ptr, self.nf = [], []
        self.vp_acc = 0.0

    def reset(self):
        for g in range(self.ng):
            self.ptr[g] = self.gs[g]
            self.nf[g] = self.n0[self.gs[g]]
        self.vp_acc = 0.0

    def sell(self, X, u, keep, tfs, rate, ts):
        """Rückgabe (G, gain, all)."""
        A = ts.loss + ts.spb
        c1 = 1.0 - tfs
        Gd = 0.0
        C = 0.0
        all_ = False
        ng, w, ptr, ge, nf, bu, vpu, n0 = self.ng, self.w, self.ptr, self.ge, self.nf, self.bu, self.vpu, self.n0
        while True:
            L = _INF
            s = 0.0
            any_ = False
            done = False
            for g in range(ng):
                if w[g] == 0.0:
                    continue
                if ptr[g] >= ge[g]:
                    done = True
                    break
                j = ptr[g]
                val = nf[g] * u
                ln = val / w[g]
                if ln < L:
                    L = ln
                s += w[g] * (keep - (bu[j] + vpu[j] + self.vp_acc) * nf[g] / val)
                any_ = True
            if done or not any_ or not _isfinite(L):
                all_ = True
                for g in range(ng):
                    for j in range(ptr[g], ge[g]):
                        nn = nf[g] if j == ptr[g] else n0[j]
                        C += keep * nn * u - (bu[j] + vpu[j] + self.vp_acc) * nn
                        Gd += nn * u
                    ptr[g] = ge[g]
                    nf[g] = 0.0
                break
            T0 = c1 * C - A
            k = c1 * s

            def net(t, T0=T0, k=k, Gd=Gd):
                tx = T0 + k * t
                return keep * (Gd + t) - (rate * tx if tx > 0 else 0.0)

            t = L
            if net(L) >= X:
                tk = -T0 / k if k != 0.0 else -1.0
                cuts = (0.0, tk if (tk > 0.0 and tk < L) else L, L)
                t = L
                for q in range(2):
                    a = cuts[q]
                    b = cuts[q + 1]
                    if b <= a and q > 0:
                        continue
                    taxed = T0 + k * 0.5 * (a + b) > 0.0
                    r = (X - keep * Gd + rate * T0) / (keep - rate * k) if taxed else (X - keep * Gd) / keep
                    if r <= b * (1.0 + 1e-12) + 1e-12:
                        t = _min(_max(r, a), b)
                        break
            for g in range(ng):
                if w[g] == 0.0:
                    continue
                j = ptr[g]
                val = nf[g] * u
                part = w[g] * t
                cost_u = bu[j] + vpu[j] + self.vp_acc
                if math.fabs(part) >= math.fabs(val) * (1.0 - 1e-12):
                    C += keep * val - cost_u * nf[g]
                    ptr[g] += 1
                    nf[g] = n0[ptr[g]] if ptr[g] < ge[g] else 0.0
                else:
                    du = part / u
                    C += keep * part - cost_u * du
                    nf[g] -= du
            Gd += t
            if t < L:
                break
        return Gd, C, all_


def _mat(x, nr=None):
    a = np.asarray(x, dtype=np.float64)
    if a.ndim == 1:
        a = a.reshape(-1, 1) if a.size else a.reshape(nr or 0, 0)
    return a


def wd_simulate(R, INF, CAPE, BASE, ppy, rule, rp, start_timing, start_value, income_real,
                tax_on, tax_rate, tfs, spb_annual, vp_on, cost, basis_ratio, loss0, keep,
                lot_n=(), lot_basis=(), lot_vp=(), lot_group=(), spb_first=-1.0, horizon_end=False):
    """Schneller Entnahme-Kern (``.wd_simulate``); Rückgabe ``dict`` wie die R-Liste."""
    R = _mat(R)
    INF = _mat(INF)
    CAPE = _mat(CAPE, R.shape[0])
    BASE = _mat(BASE)
    np_, paths = R.shape
    lot_n = [float(v) for v in np.asarray(lot_n, dtype=np.float64).ravel()]
    lot_basis = [float(v) for v in np.asarray(lot_basis, dtype=np.float64).ravel()]
    lot_vp = [float(v) for v in np.asarray(lot_vp, dtype=np.float64).ravel()]
    lot_group = [int(v) for v in np.asarray(lot_group).ravel()]
    nlot = len(lot_n)
    if len(lot_basis) != nlot or len(lot_vp) != nlot or len(lot_group) != nlot:
        raise WdError("Lot-Vektoren haben verschiedene Längen")
    use_lots = bool(tax_on) and nlot > 0
    FL = _FifoLots()
    if use_lots:
        tot = 0.0
        for j in range(nlot):
            if not (lot_n[j] > 0.0 or lot_n[j] < 0.0) or not _isfinite(lot_basis[j]) or not _isfinite(lot_vp[j]):
                raise WdError("Lot %d: Einheiten müssen ungleich 0 und alle Werte endlich sein" % (j + 1))
            if j > 0 and lot_group[j] < lot_group[j - 1]:
                raise WdError("Lots müssen nach Gruppe sortiert sein")
            tot += lot_n[j]
        if not (tot > 0.0):
            raise WdError("Summe der Lot-Einheiten muss positiv sein")
        for j in range(nlot):
            if j == 0 or lot_group[j] != lot_group[j - 1]:
                FL.gs.append(j)
                FL.ge.append(j)
                FL.w.append(0.0)
            FL.ge[-1] = j + 1
            FL.w[-1] += lot_n[j] / tot
            FL.n0.append(lot_n[j])
            FL.bu.append(lot_basis[j] / lot_n[j])
            FL.vpu.append(lot_vp[j] / lot_n[j])
        FL.ng = len(FL.gs)
        FL.ptr = [0] * FL.ng
        FL.nf = [0.0] * FL.ng
    ppy = int(ppy)
    rule = int(rule)
    rp = [float(v) for v in np.asarray(rp, dtype=np.float64).ravel()]
    if ppy < 1:
        raise WdError("ppy muss >= 1 sein")
    if len(rp) < P_N:
        raise WdError("Parametervektor zu kurz (%d statt %d)" % (len(rp), P_N))
    if INF.shape[0] != np_ or INF.shape[1] != paths:
        raise WdError("Inflationsmatrix %d x %d passt nicht zu den Renditen %d x %d"
                      % (INF.shape[0], INF.shape[1], np_, paths))
    has_cape = CAPE.shape[1] > 0
    if has_cape and (CAPE.shape[0] < np_ or CAPE.shape[1] != paths):
        raise WdError("CAPE-Matrix %d x %d passt nicht zu den Renditen %d x %d"
                      % (CAPE.shape[0], CAPE.shape[1], np_, paths))
    if tax_on and vp_on and (BASE.shape[0] < np_ or BASE.shape[1] != paths):
        raise WdError("Basiszins-Matrix %d x %d passt nicht zu den Renditen %d x %d"
                      % (BASE.shape[0], BASE.shape[1], np_, paths))
    income_real = [float(v) for v in np.asarray(income_real, dtype=np.float64).ravel()]
    if np_ > 0 and len(income_real) < 1:
        raise WdError("income_real darf nicht leer sein")
    ny = (np_ + ppy - 1) // ppy
    keep = bool(keep)
    horizon_end = bool(horizon_end)
    tax_on = bool(tax_on)
    vp_on = bool(vp_on)
    start_timing = bool(start_timing)
    tax_rate = float(tax_rate)
    tfs = float(tfs)
    spb_annual = float(spb_annual)
    cost = float(cost)
    start_value = float(start_value)
    basis_ratio = float(basis_ratio)
    loss0 = float(loss0)
    spb_first = float(spb_first)
    wealth = np.zeros((ny + 1, paths) if keep else (0, 0))
    spend = np.zeros((ny, paths))
    planned = np.zeros((ny, paths))
    terminal = np.zeros(paths)
    terminal_nom = np.zeros(paths)
    taxes = np.zeros(paths)
    depl = np.zeros(paths)
    fail = np.zeros(paths)
    wealth_end = np.zeros((ny + 1, paths) if horizon_end else (0, 0))
    taxes_end = np.zeros((ny + 1, paths) if horizon_end else (0, 0))
    Rc = R.T.tolist()
    Ic = INF.T.tolist()
    Cc = CAPE.T.tolist() if has_cape else None
    Bc = BASE.T.tolist() if (BASE.ndim == 2 and BASE.shape[1] == paths and BASE.shape[0] >= np_) else None
    inc_n = len(income_real)
    keep_c = 1.0 - cost

    for k in range(paths):
        st = [0.0] * S_N
        S = {"u": 1.0, "n": start_value, "basis": start_value * basis_ratio, "cpi": 1.0, "vp_pending": 0.0,
             "vp_due": 0.0, "tax_sum": 0.0, "failed": False, "depl_p": _NA}
        cpi_dec = 1.0
        yr_ret = 1.0
        W = 0.0
        u0 = 1.0
        ts = _TaxState(loss0, spb_annual)
        if use_lots:
            FL.reset()

        def sale(target, V):
            """Verkauf für Netto-Ziel; Rückgabe (G, tax, all); mindert n."""
            nonlocal ts
            all_ = False
            u = S["u"]
            if use_lots:
                G, gain, all_ = FL.sell(target, u, 1.0 - cost, tfs, tax_rate, ts)
                if all_:
                    G = V
                tax = _tax_on_gain(gain, tfs, tax_rate, ts)
            else:
                G = _gross_for_net(target, V, S["basis"], tfs, tax_rate, cost, ts, tax_on)
                if G >= V:
                    G = V
                    all_ = True
                bpart = S["basis"] * G / V
                tax = _tax_on_gain(G * (1.0 - cost) - bpart, tfs, tax_rate, ts) if tax_on else 0.0
                S["basis"] -= bpart
            S["n"] -= G / u
            if all_:
                S["n"] = 0.0
                S["basis"] = 0.0
            return G, tax, all_

        def settle_end():
            nonlocal ts
            add = 0.0
            if S["vp_pending"] > 0:
                t0 = _TaxState(ts.loss, spb_annual)
                vtax0 = _tax_on_gain(S["vp_pending"], tfs, tax_rate, t0)
                V = S["n"] * S["u"]
                paid_all = True
                if vtax0 > 0 and V > 0:
                    G, tax, _a = sale(vtax0, V)
                    net = G * (1.0 - cost) - tax
                    add = tax + _min(net, vtax0)
                    paid_all = net >= vtax0 * (1.0 - 1e-12)
                tn = _TaxState(ts.loss, spb_annual)
                vtax1 = _tax_on_gain(S["vp_pending"], tfs, tax_rate, tn)
                S["vp_pending"] = 0.0
                diff = vtax1 - vtax0
                if paid_all and vtax0 > 0 and diff != 0.0:
                    ts = tn
                    if diff > 0:
                        V = S["n"] * S["u"]
                        if V > 0:
                            G, tax, _a = sale(diff, V)
                            net = G * (1.0 - cost) - tax
                            add += tax + _min(net, diff)
                    else:
                        if S["u"] > 0:
                            S["n"] += -diff / S["u"]
                            S["basis"] += -diff
                        add += diff
            return add

        V_ys = 0.0
        plan_all = False
        if horizon_end:
            wealth_end[0, k] = start_value
            taxes_end[0, k] = 0.0
        Rk = Rc[k]
        Ik = Ic[k]
        for p in range(np_):
            y = p // ppy
            ypos = p % ppy
            V = S["n"] * S["u"]
            if ypos == 0:
                if keep:
                    wealth[y, k] = V / S["cpi"]
                ts.spb = spb_first if (y == 0 and spb_first >= 0.0) else spb_annual
                if S["vp_pending"] > 0:
                    S["vp_due"] += _tax_on_gain(S["vp_pending"], tfs, tax_rate, ts)
                    S["vp_pending"] = 0.0
                cpi = S["cpi"]
                infl_prev = 1.0 if y == 0 else cpi / cpi_dec
                cp = Cc[k][p] if has_cape else 0.0
                W = rule_amount(rule, rp, st, V, infl_prev, cpi, yr_ret - 1.0, cp, float(ny - y))
                planned[y, k] = W / cpi
                cpi_dec = cpi
                yr_ret = 1.0
                u0 = S["u"]
                V_ys = V
                plan_all = (rule in (9, 10, 11, 14)) and V_ys > 0 and W <= V_ys * (1.0 + 1e-9) and \
                    (W >= V_ys * (1.0 - 1e-12) or y == ny - 1)
            inc = income_real[_min(y, inc_n - 1)] * S["cpi"] / ppy
            need = _max(0.0, W / ppy - inc)

            def withdraw(y=y, p=p, inc=inc, need=need):
                target = need + S["vp_due"]
                paid_vp = 0.0
                paid = 0.0
                V = S["n"] * S["u"]
                if target > 0 and V > 0:
                    G, tax, _a = sale(target, V)
                    net = G * (1.0 - cost) - tax
                    S["tax_sum"] += (tax + S["vp_due"]) / S["cpi"]
                    paid_vp = _min(net, S["vp_due"])
                    paid = net - paid_vp
                    S["tax_sum"] -= (S["vp_due"] - paid_vp) / S["cpi"]
                S["vp_due"] = 0.0
                spend[y, k] += (paid + inc) / S["cpi"]
                if paid < need - 1e-8 * _max(1.0, need) and not (plan_all and S["n"] <= 0.0):
                    if not S["failed"]:
                        S["failed"] = True
                        S["depl_p"] = float(p + 1)

            if start_timing:
                withdraw()
            S["u"] *= Rk[p]
            if S["u"] < 0:
                S["u"] = 0.0
            S["cpi"] *= Ik[p]
            yr_ret *= Rk[p]
            if not start_timing:
                withdraw()
            if ypos == ppy - 1 and tax_on and vp_on and S["n"] > 0:
                br = _max(0.0, Bc[k][p]) / 100.0
                vp_ps = _max(0.0, _min(u0 * 0.7 * br, S["u"] - u0))
                vp = S["n"] * vp_ps
                if vp > 0:
                    S["vp_pending"] += vp
                    S["basis"] += vp
                    if use_lots:
                        FL.vp_acc += vp_ps
            if horizon_end and ypos == ppy - 1 and p < np_ - 1:
                n_s, b_s, vpp_s = S["n"], S["basis"], S["vp_pending"]
                ts_s = ts.copy()
                if use_lots:
                    ptr_s, nf_s, acc_s = list(FL.ptr), list(FL.nf), FL.vp_acc
                add = settle_end()
                wealth_end[y + 1, k] = S["n"] * S["u"] / S["cpi"]
                taxes_end[y + 1, k] = S["tax_sum"] + add / S["cpi"]
                S["n"], S["basis"], S["vp_pending"] = n_s, b_s, vpp_s
                ts = ts_s
                if use_lots:
                    FL.ptr, FL.nf, FL.vp_acc = ptr_s, nf_s, acc_s
        S["tax_sum"] += settle_end() / S["cpi"]
        Vend = S["n"] * S["u"]
        if keep:
            wealth[ny, k] = Vend / S["cpi"]
        if horizon_end:
            wealth_end[ny, k] = Vend / S["cpi"]
            taxes_end[ny, k] = S["tax_sum"]
        terminal[k] = Vend / S["cpi"]
        terminal_nom[k] = Vend
        taxes[k] = S["tax_sum"]
        fail[k] = 1.0 if S["failed"] else 0.0
        depl[k] = S["depl_p"]
    return {"wealth": wealth, "spending": spend, "planned": planned, "terminal_real": terminal,
            "terminal_nominal": terminal_nom, "taxes_real": taxes, "failed": fail, "depletion_period": depl,
            "wealth_end": wealth_end, "taxes_end": taxes_end}

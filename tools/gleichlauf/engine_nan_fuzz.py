"""N10: Zufallsprüfung der Engine-Kerne (simulation/fifo/tax_core_impl.h) mit NA, NaN und Inf.

    python3 tools/gleichlauf/engine_nan_fuzz.py gen <ordner> [fälle je Kern] [seed]   # Fälle: cases.R, cases.jl, cases.py
    Rscript tools/gleichlauf/engine_nan_fuzz.R <ordner>                             # R  -> r.txt
    python3 tools/gleichlauf/engine_nan_fuzz.py py <ordner>                         # Python -> py.txt
    julia --project=julia tools/gleichlauf/engine_nan_fuzz.jl <ordner>              # Julia -> jl.txt
    python3 tools/gleichlauf/engine_nan_fuzz.py cmp <ordner> [r.txt ...]            # Vergleich je Kern

Je Fall ein Aufruf eines der 15 Engine-Kerne auf einem zufälligen Zustand, in dem NA (still und
signalisierend, auch mit Vorzeichen), NaN (beide Vorzeichen), ±Inf, ±0 und gewöhnliche Zahlen gemischt
sind. Ausgegeben werden alle Felder, die der Kern lesen oder schreiben kann (Status, Report, Lots,
Totals, Ergebnis) als 64-Bit-Muster; verglichen wird streng (alle 64 Bit, auch Nutzlast und Vorzeichen
eines NaN). Endliche Zahlen sind Vielfache von 1/64 (in allen drei Sprachen exakt lesbar).
"""
import os
import random
import struct
import sys

KERNE = ["dca", "buy_report", "sell_report", "total_report", "buy", "market_update", "market_update_batch",
         "fifo_consume", "fifo_price", "fifo_vp", "private_sale_tax", "flat_rate", "sell_count", "p20_tax", "vp_tax"]
SIM_KERNE = KERNE[:8]
STATUS = ["count", "price", "worth", "money", "total", "target", "actual", "differ"]
REPORT = ["worth", "money", "flows", "total", "share"]
LOT = ["date", "count", "price", "remaining", "original", "vp"]
TOTALS = ["total_taxes", "loss_capital_gains", "sparer_pauschbetrag_remaining", "sparer_pauschbetrag_used_total",
          "cgt_base_taxed_ytd", "cgt_loss_added_ytd", "cgt_loss_used_ytd"]

# besondere Werte: Name -> Bitmuster
SPEZIAL = {"NA": 0x7FF00000000007A2, "qNA": 0x7FF80000000007A2, "mNA": 0xFFF80000000007A2,
           "NaN": 0x7FF8000000000000, "mNaN": 0xFFF8000000000000, "Inf": 0x7FF0000000000000,
           "mInf": 0xFFF0000000000000, "m0": 0x8000000000000000}


def b2d(b):
    return struct.unpack("<d", struct.pack("<Q", b))[0]


def d2b(x):
    return struct.unpack("<Q", struct.pack("<d", float(x)))[0]


class Spez(float):
    """float mit Namen für die Ausgabe nach R/Julia (Bitmuster bleibt erhalten)."""
    def __new__(cls, name):
        o = float.__new__(cls, b2d(SPEZIAL[name]))
        o.name = name
        return o


def gen_cases(n, seed):
    rg = random.Random(seed)

    def num(p_spez=0.45, lo=-40, hi=200):
        u = rg.random()
        if u < p_spez:
            return Spez(rg.choices(list(SPEZIAL), weights=[30, 8, 3, 25, 8, 8, 5, 4])[0])
        if u < p_spez + 0.06:
            return 0.0
        return rg.randint(lo * 64, hi * 64) / 64.0

    def pos(p_spez=0.35):
        return num(p_spez, lo=-2, hi=60)

    def lots(k):
        out = []
        for _ in range(k):
            out.append({"date": rg.randint(15000, 20500), "count": pos(), "price": num(), "remaining": pos(),
                        "original": pos(), "vp": pos()})
        return out

    def sim(na, nd, nlots_max=4):
        names = ["a", "b", "c"][:na]
        st = {nm: {f: num() for f in STATUS} for nm in names}
        d0 = rg.randint(15000, 20000)
        mk = {nm: {"asset_day": list(range(d0, d0 + nd)), "asset_price": [num() for _ in range(nd)]} for nm in names}
        tr = {}
        for nm in names:
            bl = lots(rg.randint(0, nlots_max))
            tr[nm] = {"buys": bl, "buy_count": len(bl), "fifo_front": rg.randint(1, len(bl) + 1)}
        rp = {nm: {f: [num() for _ in range(nd)] for f in REPORT} for nm in names}
        return {"assets": names, "status": st, "market": mk, "trades": tr, "report": rp}

    def totals():
        return {f: num() for f in TOTALS}

    cases = []
    for k in KERNE:
        for i in range(n):
            c = {"id": "%s_%04d" % (k, i + 1), "k": k}
            if k in SIM_KERNE:
                na, nd = rg.randint(1, 3), rg.randint(1, 5)
                s = sim(na, nd)
                c["sim"] = s
                nm = rg.choice(s["assets"])
                idx = rg.randint(1, nd)
                a = {}
                if k == "dca":
                    a = {"name": nm, "flows": num(), "index": idx}
                elif k in ("buy_report", "buy"):
                    a = {"name": nm, "index": idx, "tc": pos(), "tp": num(), "mp": num()}
                elif k == "sell_report":
                    a = {"name": nm, "index": idx, "tc": pos(), "tp": num(), "mp": num(), "cgt": num()}
                elif k in ("total_report", "market_update"):
                    a = {"index": idx}
                elif k == "market_update_batch":
                    s0 = rg.randint(1, nd)
                    a = {"s": s0, "e": rg.randint(s0, nd)}
                elif k == "fifo_consume":
                    a = {"name": nm, "tc": pos()}
                c["a"] = a
            elif k in ("p20_tax", "vp_tax"):
                c["totals"] = totals()
                c["a"] = {"x": num(), "bonus": rg.choice([0.0, 0.3, 0.15, num()]), "rate": rg.choice([0.26375, 0.25, num()]),
                          "spb": rg.random() < 0.7}
            else:
                bl = lots(rg.randint(0, 5))
                c["buys"] = bl
                front = rg.randint(1, len(bl) + 1)
                if k in ("fifo_price", "fifo_vp"):
                    c["a"] = {"units": pos(), "front": front}
                elif k == "private_sale_tax":
                    c["a"] = {"front": front, "tc": pos(), "sp": num(), "date": rg.randint(15000, 21000)}
                elif k == "flat_rate":
                    y0 = rg.randint(15000, 20000)
                    c["a"] = {"front": front, "br": rg.choice([0.0255, 0.0229, num()]), "ysp": num(), "mp": num(),
                              "soy": y0, "eoy": y0 + 364}
                elif k == "sell_count":
                    c["a"] = {"front": front, "target": num(), "tp": num(), "shares": pos(), "fractions": rg.random() < 0.5,
                              "regime": rg.randint(0, 3), "bonus": rg.choice([0.0, 0.3, num()]), "pool": num(),
                              "rate": rg.choice([0.26375, num()])}
            cases.append(c)
    return cases


# ── Ausgabe der Fälle als R- und Julia-Quelltext ─────────────────────────────

def _num_r(x):
    if isinstance(x, Spez):
        return ".S$s" + x.name
    return repr(float(x))


def _num_jl(x):
    if isinstance(x, Spez):
        return "S_" + x.name
    return repr(float(x))


def to_r(v, dates=False):
    if isinstance(v, bool):
        return "TRUE" if v else "FALSE"
    if isinstance(v, int):
        return "%dL" % v
    if isinstance(v, float):
        return _num_r(v)
    if isinstance(v, str):
        return '"%s"' % v
    raise TypeError(type(v))


def r_lot(l):
    return "list(date = .D(%d), type = \"Buy\", count = %s, price = %s, remaining = %s, original = %s, vp = %s)" % (
        l["date"], *(_num_r(l[f]) for f in LOT[1:]))


def r_vec(xs):
    return "c(%s)" % ", ".join(_num_r(x) for x in xs) if xs else "numeric(0)"


def r_case(c):
    p = ['id = "%s"' % c["id"], 'k = "%s"' % c["k"]]
    if "sim" in c:
        s = c["sim"]
        nm = s["assets"]
        st = ", ".join("%s = list(%s)" % (a, ", ".join("%s = %s" % (f, _num_r(s["status"][a][f])) for f in STATUS)) for a in nm)
        mk = ", ".join("%s = list(asset_day = .D(c(%s)), asset_price = %s)" % (
            a, ", ".join(str(d) for d in s["market"][a]["asset_day"]), r_vec(s["market"][a]["asset_price"])) for a in nm)
        tr = ", ".join("%s = list(buys = list(%s), buy_count = %dL, fifo_front = %dL)" % (
            a, ", ".join(r_lot(l) for l in s["trades"][a]["buys"]), s["trades"][a]["buy_count"], s["trades"][a]["fifo_front"])
            for a in nm)
        rp = ", ".join("%s = list(%s)" % (a, ", ".join("%s = %s" % (f, r_vec(s["report"][a][f])) for f in REPORT)) for a in nm)
        p.append("sim = list(assets = c(%s), status = list(%s), market = list(%s), trades = list(%s), report = list(%s), "
                 "totals = list(loss_capital_gains = 0))" % (", ".join('"%s"' % a for a in nm), st, mk, tr, rp))
    if "buys" in c:
        p.append("buys = list(%s)" % ", ".join(r_lot(l) for l in c["buys"]))
    if "totals" in c:
        p.append("totals = list(%s)" % ", ".join("%s = %s" % (f, _num_r(c["totals"][f])) for f in TOTALS))
    p.append("a = list(%s)" % ", ".join("%s = %s" % (k, to_r(v)) for k, v in c["a"].items()))
    return "list(%s)" % ", ".join(p)


def jl_vec(xs):
    return "Float64[%s]" % ", ".join(_num_jl(x) for x in xs)


def jl_lot(l):
    return "Lot(%d, %s)" % (l["date"], ", ".join(_num_jl(l[f]) for f in LOT[1:]))


def jl_case(c):
    p = ['id = "%s"' % c["id"], 'k = "%s"' % c["k"]]
    if "sim" in c:
        s = c["sim"]
        nm = s["assets"]
        p.append("names = [%s]" % ", ".join('"%s"' % a for a in nm))
        p.append("status = [%s]" % ", ".join("Status(%s)" % ", ".join(_num_jl(s["status"][a][f]) for f in STATUS) for a in nm))
        p.append("days = [%s]" % ", ".join("Int[%s]" % ", ".join(str(d) for d in s["market"][a]["asset_day"]) for a in nm))
        p.append("prices = [%s]" % ", ".join(jl_vec(s["market"][a]["asset_price"]) for a in nm))
        p.append("buys = [%s]" % ", ".join("Lot[%s]" % ", ".join(jl_lot(l) for l in s["trades"][a]["buys"]) for a in nm))
        p.append("front = [%s]" % ", ".join(str(s["trades"][a]["fifo_front"]) for a in nm))
        p.append("report = [%s]" % ", ".join("(%s,)" % ", ".join(jl_vec(s["report"][a][f]) for f in REPORT) for a in nm))
    if "buys" in c:
        p.append("lots = Lot[%s]" % ", ".join(jl_lot(l) for l in c["buys"]))
    if "totals" in c:
        p.append("totals = (%s,)" % ", ".join("%s = %s" % (f, _num_jl(c["totals"][f])) for f in TOTALS))
    a = []
    for k, v in c["a"].items():
        if k == "name":
            v = c["sim"]["assets"].index(v) + 1
            a.append("name = %d" % v)
        elif isinstance(v, bool):
            a.append("%s = %s" % (k, "true" if v else "false"))
        elif isinstance(v, int):
            a.append("%s = %d" % (k, v))
        else:
            a.append("%s = %s" % (k, _num_jl(v)))
    p.append("a = (%s,)" % ", ".join(a))
    return "(%s,)" % ", ".join(p)


def write_cases(d, n, seed):
    os.makedirs(d, exist_ok=True)
    cs = gen_cases(n, seed)
    with open(os.path.join(d, "meta.txt"), "w") as f:
        f.write("%d %d\n" % (n, seed))
    with open(os.path.join(d, "cases.R"), "w") as f:
        f.write("CASES <- list(\n%s\n)\n" % ",\n".join(r_case(c) for c in cs))
    with open(os.path.join(d, "cases.jl"), "w") as f:
        f.write("const CASES = Any[]\n")
        for c in cs:
            f.write("push!(CASES, %s)\n" % jl_case(c))
    print("%d Fälle (%d je Kern, seed %d) in %s" % (len(cs), n, seed, d))


# ── Python-Lauf ──────────────────────────────────────────────────────────────

def _hex(x):
    return "%016x" % d2b(x)


def _line(out, cid, path, vals, ints=False):
    if ints:
        out.append("%s %s %s" % (cid, path, " ".join("i%d" % int(v) for v in vals)))
    else:
        out.append("%s %s %s" % (cid, path, " ".join(_hex(v) for v in vals)))


def py_sim(c):
    import numpy as np
    s = c["sim"]
    return {"assets": list(s["assets"]),
            "status": {a: {f: float(s["status"][a][f]) for f in STATUS} for a in s["assets"]},
            "market": {a: {"asset_day": np.array(s["market"][a]["asset_day"], dtype=np.int64),
                           "asset_price": np.array([float(x) for x in s["market"][a]["asset_price"]], dtype=np.float64)}
                       for a in s["assets"]},
            "trades": {a: {"buys": [py_lot(l) for l in s["trades"][a]["buys"]], "buy_count": s["trades"][a]["buy_count"],
                           "fifo_front": s["trades"][a]["fifo_front"]} for a in s["assets"]},
            "report": {a: {f: np.array([float(x) for x in s["report"][a][f]], dtype=np.float64) for f in REPORT}
                       for a in s["assets"]},
            "totals": {"loss_capital_gains": 0.0}}


def py_lot(l):
    d = {"date": l["date"], "type": "Buy"}
    for f in LOT[1:]:
        d[f] = float(l[f])
    return d


def emit_sim(out, cid, sim):
    for a in sim["assets"]:
        for f in STATUS:
            _line(out, cid, "status/%s/%s" % (a, f), [sim["status"][a][f]])
        for f in REPORT:
            _line(out, cid, "report/%s/%s" % (a, f), list(sim["report"][a][f]))
        t = sim["trades"][a]
        _line(out, cid, "trades/%s/fifo_front" % a, [t["fifo_front"]], ints=True)
        n = max(len(t["buys"]), int(t["buy_count"]))
        _line(out, cid, "trades/%s/n" % a, [n], ints=True)
        for j, l in enumerate(t["buys"][:n]):
            _line(out, cid, "trades/%s/%d" % (a, j + 1), [float(l["date"])] + [float(l.get(f, 0.0)) for f in LOT[1:]])


def run_py(d):
    sys.path.append(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "python"))
    from simlev import _core as C
    n, seed = (int(x) for x in open(os.path.join(d, "meta.txt")).read().split())
    out = []
    for c in gen_cases(n, seed):
        k, a, cid = c["k"], c["a"], c["id"]
        try:
            if k in SIM_KERNE:
                sim = py_sim(c)
                f = {"dca": lambda: C.dca_flows_allocation(sim, a["name"], float(a["flows"]), a["index"]),
                     "buy_report": lambda: C.calculate_buy_report(sim, a["name"], a["index"], float(a["tc"]), float(a["tp"]),
                                                                  float(a["mp"])),
                     "sell_report": lambda: C.calculate_sell_report(sim, a["name"], a["index"], float(a["tc"]),
                                                                    float(a["tp"]), float(a["mp"]), float(a["cgt"])),
                     "total_report": lambda: C.calculate_total_report(sim, sim["assets"], a["index"]),
                     "buy": lambda: C.perform_trade_buy_cpp(sim, a["name"], a["index"], float(a["tc"]), float(a["tp"]),
                                                            float(a["mp"])),
                     "market_update": lambda: C.perform_market_update(sim, sim["assets"], a["index"]),
                     "market_update_batch": lambda: C.batch_market_update(sim, sim["assets"], a["s"], a["e"]),
                     "fifo_consume": lambda: C.fifo_consume(sim, a["name"], float(a["tc"]))}[k]
                f()
                emit_sim(out, cid, sim)
            elif k in ("p20_tax", "vp_tax"):
                t = {f: float(c["totals"][f]) for f in TOTALS}
                fn = C.p20_tax if k == "p20_tax" else C.vp_tax
                r = fn(float(a["x"]), float(a["bonus"]), t, float(a["rate"]), a["spb"])
                for key, v in r.items():
                    _line(out, cid, "res/" + key, [v])
                for f in TOTALS:
                    _line(out, cid, "totals/" + f, [t[f]])
            else:
                b = [py_lot(l) for l in c["buys"]]
                if k == "fifo_price":
                    _line(out, cid, "res", [C._calculate_fifo_price(b, float(a["units"]), a["front"])])
                elif k == "fifo_vp":
                    _line(out, cid, "res", [C._calculate_fifo_vorabpauschale(b, float(a["units"]), a["front"])])
                elif k == "private_sale_tax":
                    r = C._calculate_private_sale_tax(b, a["front"], float(a["tc"]), float(a["sp"]), a["date"])
                    for key, v in r.items():
                        _line(out, cid, "res/" + key, [v])
                elif k == "flat_rate":
                    r = C.flat_rate(b, a["front"], float(a["br"]), float(a["ysp"]), float(a["mp"]), a["soy"], a["eoy"])
                    _line(out, cid, "res/total_vp", [r["total_vp"]])
                    _line(out, cid, "res/lot_indices", list(r["lot_indices"]), ints=True)
                    _line(out, cid, "res/lot_vps", list(r["lot_vps"]))
                elif k == "sell_count":
                    r = C.sell_count(b, a["front"], float(a["target"]), float(a["tp"]), float(a["shares"]), a["fractions"],
                                     a["regime"], float(a["bonus"]), float(a["pool"]), float(a["rate"]))
                    for key, v in r.items():
                        _line(out, cid, "res/" + key, [v])
        except Exception as e:  # noqa: BLE001
            out.append("%s FEHLER %s" % (cid, type(e).__name__))
    with open(os.path.join(d, "py.txt"), "w") as f:
        f.write("\n".join(out) + "\n")
    print("Python: %d Zeilen" % len(out))


# ── Vergleich ────────────────────────────────────────────────────────────────

def load(fn):
    res = {}
    for ln in open(fn):
        cid, rest = ln.rstrip("\n").split(" ", 1)
        res.setdefault(cid, []).append(rest)
    return res


def cmp(d, files):
    data = {f: load(os.path.join(d, f)) for f in files}
    ref = data[files[0]]
    status = 0
    print("%-22s %6s %s" % ("Kern", "Fälle", "  ".join("%-12s" % ("gleich " + f.split(".")[0]) for f in files[1:])))
    for k in KERNE:
        ids = sorted(i for i in ref if i.rsplit("_", 1)[0] == k)
        row = []
        for f in files[1:]:
            ok = sum(1 for i in ids if data[f].get(i) == ref[i])
            if ok != len(ids):
                status = 1
            row.append("%-12s" % ("%d/%d" % (ok, len(ids))))
        print("%-22s %6d %s" % (k, len(ids), "  ".join(row)))
    for f in files[1:]:
        bad = [i for i in ref if data[f].get(i) != ref[i]]
        for i in sorted(bad)[:3]:
            print("Beispiel %s %s:" % (f, i))
            for x, y in zip(ref[i], data[f].get(i, [])):
                if x != y:
                    print("   %s: %s\n   %s: %s" % (files[0], x, f, y))
    print("Gesamt: %s" % ("bitgleich" if status == 0 else "ABWEICHUNG"))
    return status


if __name__ == "__main__":
    cmd, d = sys.argv[1], sys.argv[2]
    if cmd == "gen":
        write_cases(d, int(sys.argv[3]) if len(sys.argv) > 3 else 1000, int(sys.argv[4]) if len(sys.argv) > 4 else 20261101)
    elif cmd == "py":
        run_py(d)
    elif cmd == "cmp":
        sys.exit(cmp(d, sys.argv[3:] or ["r.txt", "py.txt", "jl.txt"]))
    else:
        sys.exit("unbekannter Befehl " + cmd)

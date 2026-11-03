#!/usr/bin/env python3
"""Zufallsfälle über simulation() (seit 1.4.0) (tests/werkzeuge/gleichlauf/sim_fuzz.R) – R neu gegen die Referenz aus R 1.3.0.

Aufruf: python3 -I tests/werkzeuge/gleichlauf/sim_fuzz_cmp.py <referenz/sim_fuzz.jsonl.gz> <neu/sim_fuzz.jsonl.gz>
(ebenso für den Datums-Fuzz tests/werkzeuge/gleichlauf/sched_fuzz.R, Modul sched_fuzz, und seit 1.5.0 für approx_fuzz.R und
wd_fuzz.R mit der Referenz aus R 1.4.2)

Vergleicht jeden Fall und den Eingabespeicher (Zeile 1) der beiden Bereichsdateien streng: gleicher JSON-Baum (Zahlen als Hex-Literale, also
bitgleich einschließlich NA/NaN und Vorzeichen der Null), gleiche Konsolenausgabe, gleiche print()-Ausgabe,
gleiche Warnungen und Fehlertexte. Dazu die Zahl der Fälle auf dem Weg der Tagesengine im C++-Kern (ohne
Steuer, Splits und details; nach dem Code des Falls). Ende 1 bei einer Abweichung oder fehlenden Fällen.

Seit 1.4.1: Die Aufrufe der Bedingungen (r_calls, nur R) sind gleich bis auf die Kopfzeilen, die R 1.3.0 aus festen
Ausdrücken der Phasen nachbildete (Aufrufe von .perform_trade_buy/.perform_trade_sell/.perform_asset_split,
if-Ausdrücke, max(), stats::uniroot): diese müssen jetzt genau der Aufruf von simulation() im Fall sein
(r_calls.sim_call), beim internen Zinsfuß ohne simulation() (.xirr_rate direkt) ohne Aufruf ("NULL").
"""
import gzip
import json
import sys


def load(p):
    """Bereichsdatei → {"_inputs": Kopf, <id>: Fall, ...} (seit 1.4.1 eine Datei statt je Fall eine)."""
    with gzip.open(p, "rt", encoding="utf-8") as fh:
        out = {"_inputs": json.loads(fh.readline())}
        for ln in fh:
            if ln.strip():
                c = json.loads(ln)
                out[c["id"]] = c
    return out


def first_diff(a, b, path=""):
    if type(a) is not type(b):
        return path or "/"
    if isinstance(a, dict):
        for k in sorted(set(a) | set(b)):
            if k not in a or k not in b:
                return "%s/%s" % (path, k)
            d = first_diff(a[k], b[k], "%s/%s" % (path, k))
            if d:
                return d
        return None
    if isinstance(a, list):
        if len(a) != len(b):
            return path + " (Länge)"
        for i, (x, y) in enumerate(zip(a, b)):
            d = first_diff(x, y, "%s[%d]" % (path, i))
            if d:
                return d
        return None
    return None if a == b else (path or "/")


# Kopfzeilen, die R 1.3.0 aus festen Ausdrücken nachbildete (r/R/sim_engine_calls.R, bis 1.4.0)
FIXED_HEADS = (".perform_trade_buy(", ".perform_trade_sell(", ".perform_asset_split(", "if (", "max(", "stats::uniroot(")


def cmp_calls(a, b):
    """r_calls von R 1.3.0 (a) und R neu (b): None, wenn gleich bis auf die begründeten Kopfzeilen, sonst Pfad.
    Zweiter Wert: Zahl der begründet geänderten Kopfzeilen je Art."""
    changed = {}
    if set(a) - {"sim_call"} != set(b) - {"sim_call"} or a.get("sim_call") != b.get("sim_call"):
        return "/r_calls", changed
    want = b.get("sim_call", "NULL")
    def one(x, y, path):
        if x == y:
            return None
        if isinstance(x, str) and isinstance(y, str) and x.startswith(FIXED_HEADS) and y == want:
            head = x.split("(")[0].strip() or x[:3]
            changed[head] = changed.get(head, 0) + 1
            return None
        return path
    wa, wb = a.get("warnings") or [], b.get("warnings") or []
    if len(wa) != len(wb):
        return "/r_calls/warnings (Länge)", changed
    for i, (x, y) in enumerate(zip(wa, wb)):
        d = one(x, y, "/r_calls/warnings[%d]" % i)
        if d:
            return d, changed
    return one(a.get("error"), b.get("error"), "/r_calls/error"), changed


def main(argv):
    R, N = load(argv[1]), load(argv[2])
    fr, fn = sorted(R), sorted(N)
    bad = 0
    for f in sorted(set(fr) ^ set(fn)):
        print("FEHLT %s (%s)" % (f, "neu" if f in fr else "Referenz"))
        bad += 1
    n = engine = errors = warned = 0
    heads = {}
    for f in sorted(set(fr) & set(fn)):
        a, b = dict(R[f]), dict(N[f])
        ca, cb = a.pop("r_calls", None), b.pop("r_calls", None)
        d = first_diff(a, b)
        if not d and (ca is None) != (cb is None):
            d = "/r_calls"
        if not d and ca is not None:
            d, ch = cmp_calls(ca, cb)
            for k, v in ch.items():
                heads[k] = heads.get(k, 0) + v
        if d:
            print("ABWEICHUNG %s: %s" % (f, d))
            bad += 1
        if f.startswith("_"):
            continue
        n += 1
        code = a.get("r", "")
        if "tax = " not in code and "splits = " not in code and "details = TRUE" not in code and "error" not in a:
            engine += 1
        errors += "error" in a
        warned += bool(a.get("warnings"))
    print("sim_fuzz: %d Fälle, davon %d ohne Steuer/Splits/details (Tagesengine), %d mit Fehler, %d mit Warnungen"
          % (n, engine, errors, warned))
    print("sim_fuzz: Kopfzeilen seit 1.4.1 Aufruf von simulation() bzw. ohne Aufruf: %d%s"
          % (sum(heads.values()), " (%s)" % ", ".join("%s %d" % kv for kv in sorted(heads.items())) if heads else ""))
    print("sim_fuzz: %d/%d Einträge gleich" % (len(set(fr) & set(fn)) - bad + len(set(fr) ^ set(fn)) * 0,
                                              len(set(fr) | set(fn))) if bad else
          "sim_fuzz: alle %d Fälle gleich (R neu = Referenz)" % (len(fr) - 1))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

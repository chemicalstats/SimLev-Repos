#!/usr/bin/env python3
"""Flache simulation()-Argumente (bis 6.2) nach Anhang C in Bausteine übersetzen (Etappe 6.3).

Nur Standardbibliothek. Zwei Anwendungen:

1. Engine-Fälle ``golden/cases`` und ``golden/extra`` (lassen sich nicht neu erzeugen, der Startwert
   der Zufallsfälle ist unbekannt). Die flachen ``args`` eines Falls werden in Bausteine übersetzt,
   die Strategie bekommt die Namen aus 6.3 (``asset_spread`` → ``spread``, ``asset_bonus`` →
   ``partial_exemption``). Die erwarteten Ergebnisse bleiben unverändert::

       python3 golden/tools/blocks_from_flat.py golden/cases golden/extra          # umstellen (an Ort und Stelle)
       python3 golden/tools/blocks_from_flat.py --check golden/cases golden/extra  # nur prüfen, ob umgestellt

   Ein Baustein steht im Fall als ``{"block": "<Konstruktor>", "args": {...}}``; ``compare_golden``
   (Python, Julia) baut daraus die Bausteine. Ein Baustein in einem Baustein (``income``, ``harvest``)
   hat dieselbe Form.

2. Programmtext (Tests, Beispiele, Generatoren): ``convert_args(items, lang)`` übersetzt die
   Argumentliste eines Aufrufs (Liste von (Name, Ausdruck)); Ausdrücke bleiben Text, nur
   Schalter (``dca_mode = TRUE`` …) und Steuermodus müssen Literale sein.

Regeln (Anhang C, Entscheidungen 6.3):

- ``dca_mode`` FALSE oder fehlt: kein Sparplan (``dca_*`` entfallen); sonst
  ``dca_plan(value, span, days, unit, anchor, start, skip, fill_deficits = balance_dca)``.
- ``balance_mode`` TRUE: ``rebalance_plan(span, days, unit, anchor, start, skip, thresh, thresh_type,
  event_col, event_mode, event_weight)``. ``balance_mode`` FALSE mit ``event_col``: Rebalancing nur an
  Ereignistagen ohne Umschichten am ersten Tag, also ``rebalance_plan(event_col, event_mode = "replace",
  skip = TRUE, …)``; die Kalenderargumente entfallen (sie wirkten nicht). ``balance_mode`` TRUE mit
  ``event_mode = "replace"``: ``skip`` entfällt (es wirkte nicht; mit Bausteinen hieße ``skip = TRUE``
  dort „ohne Umschichten am ersten Tag“). Ohne beides entfallen ``balance_*`` und ``event_*``.
- ``split_mode`` TRUE: ``split_rule(thresh = split_thresh)``.
- ``tax_mode = "person"``: ``tax_profile(rate = tax_rate, church_tax, sparer_pauschbetrag,
  private_sale_threshold, base_rate, guenstigerpruefung = use_guenstigerpruefung, income, harvest)``;
  ``use_sparer_pauschbetrag = FALSE`` wird ``sparer_pauschbetrag = 0``; ``base_rate_flex = TRUE`` wird
  ``base_rate = base_rate_data``; ``taxable_income``/``tax_tariff`` → ``income_tariff(taxable_income,
  tariff)``, sonst ``marginal_tax_rate`` → ``income_rate(marginal_rate, soli_rate)`` mit
  ``soli_rate = soli_rate_income_tax`` (Standard 5.5) bei ``include_soli_on_income_tax = TRUE``;
  ``harvest_mode = TRUE`` → ``harvest_rule(day = harvest_day, loss_pot = harvest_loss_pot)``.
- ``tax_mode = "funds"`` (Fondsmodus): seit Etappe 6.5c entfernt, nicht übersetzbar (``Manual``).
- ``tax_mode = "none"`` oder fehlt: Steuerargumente entfallen.
- ``order_fee``/``dca_fee`` → ``costs = sim_costs(order_fee, dca_fee)``; ``spread`` entfällt (war wirkungslos).
- ``start_value``, ``risk_free``, ``fractions``, ``liquidate``, ``details`` bleiben.
"""
from __future__ import annotations

import gzip
import json
import os
import sys

FLAT = ["spread", "dca_mode", "dca_value", "dca_span", "dca_days", "dca_unit", "dca_anchor", "dca_start", "dca_skip",
        "balance_mode", "balance_span", "balance_days", "balance_unit", "balance_anchor", "balance_start",
        "balance_skip", "balance_dca", "balance_thresh", "balance_thresh_type", "tax_mode", "tax_rate",
        "marginal_tax_rate", "use_guenstigerpruefung", "private_sale_threshold", "sparer_pauschbetrag",
        "use_sparer_pauschbetrag", "include_soli_on_income_tax", "soli_rate_income_tax", "base_rate",
        "base_rate_flex", "base_rate_data", "funds_fee", "bonus_fee", "split_mode", "split_thresh", "event_col",
        "event_mode", "event_weight", "church_tax", "order_fee", "dca_fee", "harvest_mode", "harvest_day",
        "harvest_loss_pot", "taxable_income", "tax_tariff"]
KEEP = ["data", "strategy", "start_value", "risk_free", "fractions", "liquidate", "details"]
BLOCK_ORDER = ["costs", "dca", "rebalance", "splits", "tax"]
STRATEGY_RENAME = {"asset_spread": "spread", "asset_bonus": "partial_exemption"}


class Manual(Exception):
    """Nicht eindeutig übersetzbar (z. B. Schalter als Variable): von Hand umstellen."""


class Block:
    """Baustein: Konstruktorname und geordnete Argumente (Name → Wert bzw. Block)."""

    def __init__(self, ctor, args):
        self.ctor, self.args = ctor, args

    def to_json(self):
        return {"block": self.ctor, "args": {k: (v.to_json() if isinstance(v, Block) else v) for k, v in self.args}}


# ── Werte: JSON (Fälle) oder Programmtext ─────────────────────────────────────

class JsonVal:
    """Werte aus einem JSON-Fall (bool, str, Zahl, Liste, None)."""

    @staticmethod
    def truth(v, name):
        if v is True or v is False:
            return v
        if v is None:
            return False
        raise Manual("%s = %r ist kein logischer Wert" % (name, v))

    @staticmethod
    def string(v, name):
        if v is None:
            return None
        if isinstance(v, list) and len(v) >= 1 and all(isinstance(x, str) for x in v):
            return v[0]   # match.arg-Standard c("a", "b") → erstes Element
        if isinstance(v, str):
            return v
        raise Manual("%s = %r ist keine Zeichenkette" % (name, v))

    @staticmethod
    def is_null(v):
        return v is None

    @staticmethod
    def num_is_pos(v, name):
        if v is None:
            return False
        if isinstance(v, (int, float)) and not isinstance(v, bool):
            return v > 0
        raise Manual("%s = %r ist keine Zahl" % (name, v))

    @staticmethod
    def lit(kind, x):
        return {"true": True, "false": False, "zero": 0, "five": 5.5}[kind] if x is None else x


class CodeVal:
    """Werte als Programmtext in R, Python oder Julia."""

    def __init__(self, lang, qstyle=None):
        self.lang = lang
        self.qstyle = qstyle   # Anführungszeichen für neue Zeichenketten ('"', "'" oder '\\"' in Code-Zeichenketten)

    @staticmethod
    def _bare(v):
        return v.strip().replace('\\"', '"').replace("\\'", "'")

    def truth(self, v, name):
        if v is None:
            return False
        s = self._bare(v)
        if s in ("TRUE", "True", "true", "T"):
            return True
        if s in ("FALSE", "False", "false", "F", "NULL", "None", "nothing"):
            return False
        raise Manual("%s = %s ist kein Literal" % (name, s))

    def string(self, v, name):
        if v is None:
            return None
        s = self._bare(v)
        if len(s) >= 2 and s[0] == s[-1] and s[0] in "\"'":
            return s[1:-1]
        raise Manual("%s = %s ist keine Zeichenketten-Konstante" % (name, s))

    def is_null(self, v):
        return v is None or self._bare(v) in ("NULL", "None", "nothing")

    def num_is_pos(self, v, name):
        if v is None:
            return False
        s = self._bare(v)
        try:
            return float(s) > 0
        except ValueError:
            raise Manual("%s = %s ist keine Zahl-Konstante" % (name, s)) from None

    def lit(self, kind, x):
        if x is not None:
            return x
        if kind == "true":
            return {"R": "TRUE", "py": "True", "jl": "true"}[self.lang]
        if kind == "false":
            return {"R": "FALSE", "py": "False", "jl": "false"}[self.lang]
        return {"zero": "0", "five": "5.5"}[kind]

    def quote(self, s):
        q = self.qstyle or ('"' if self.lang != "py" else "'")
        return "%s%s%s" % (q, s, q)


# ── Übersetzung ────────────────────────────────────────────────────────────────

class _Track(dict):
    """dict, das gelesene Schlüssel festhält (für die Liste der entfallenen Argumente)."""

    def __init__(self, *a):
        super().__init__(*a)
        self.read = set()

    def __getitem__(self, k):
        self.read.add(k)
        return super().__getitem__(k)


def dropped(flat, V):
    """Flache Argumente, die bei der Übersetzung ohne Gegenstück entfallen (sie wirkten nicht oder nur als
    Warnung bzw. Fehler)."""
    t = _Track(flat)
    _kept, blocks = convert(t, V)
    on = set()
    if "dca" in blocks: on.add("dca_mode")
    if "rebalance" in blocks: on.add("balance_mode")
    if "splits" in blocks: on.add("split_mode")
    if "tax" in blocks: on.add("tax_mode")
    if "tax" in blocks:
        on |= {"use_sparer_pauschbetrag", "base_rate_flex", "include_soli_on_income_tax", "harvest_mode"} & set(flat)
    return [k for k in flat if k in FLAT and k not in t.read and k not in on]


def convert(flat, V):
    """flat: dict Name → Wert (nur angegebene Argumente). V: JsonVal oder CodeVal.
    Ergebnis: (kept: dict der bleibenden Argumente, blocks: dict Name → Block)."""
    unknown = [k for k in flat if k not in FLAT and k not in KEEP]
    if unknown:
        raise Manual("unbekannte Argumente: %s" % ", ".join(unknown))
    g = flat.get
    has = lambda k: k in flat
    kept = {k: flat[k] for k in flat if k in KEEP}
    blocks = {}

    def pick(names, rename=None):
        out = []
        for k in names:
            if has(k):
                out.append(((rename or {}).get(k, k.split("_", 1)[1] if "_" in k else k), flat[k]))
        return out

    # Kosten
    if has("order_fee") or has("dca_fee"):
        blocks["costs"] = Block("sim_costs", [(k, flat[k]) for k in ("order_fee", "dca_fee") if has(k)])
    # Sparplan
    if V.truth(g("dca_mode"), "dca_mode"):
        a = [(n, flat[k]) for k, n in (("dca_value", "value"), ("dca_span", "span"), ("dca_days", "days"),
                                         ("dca_unit", "unit"), ("dca_anchor", "anchor"), ("dca_start", "start"),
                                         ("dca_skip", "skip"), ("balance_dca", "fill_deficits")) if has(k)]
        blocks["dca"] = Block("dca_plan", a)
    # Rebalancing
    bm = V.truth(g("balance_mode"), "balance_mode")
    ev = has("event_col") and not V.is_null(g("event_col"))
    if bm or ev:
        em = V.string(g("event_mode"), "event_mode") if has("event_mode") else "additional"
        cal = (("balance_span", "span"), ("balance_days", "days"), ("balance_unit", "unit"),
               ("balance_anchor", "anchor"), ("balance_start", "start"), ("balance_skip", "skip"))
        rest = (("balance_thresh", "thresh"), ("balance_thresh_type", "thresh_type"))
        a = []
        if not bm:   # nur Ereignistage, kein Umschichten am ersten Tag
            a += [(n, flat[k]) for k, n in rest if has(k)]
            a += [("event_col", flat["event_col"]), ("event_mode", V.quote("replace") if isinstance(V, CodeVal) else "replace"),
                  ("skip", V.lit("true", None))]
            if has("event_weight"):
                a.append(("event_weight", flat["event_weight"]))
        else:
            a += [(n, flat[k]) for k, n in cal if has(k) and not (k == "balance_skip" and ev and em == "replace")]
            a += [(n, flat[k]) for k, n in rest if has(k)]
            if ev:
                a.append(("event_col", flat["event_col"]))
                if has("event_mode"):
                    a.append(("event_mode", flat["event_mode"]))
                if has("event_weight"):
                    a.append(("event_weight", flat["event_weight"]))
        blocks["rebalance"] = Block("rebalance_plan", a)
    # Splits
    if V.truth(g("split_mode"), "split_mode"):
        blocks["splits"] = Block("split_rule", [("thresh", flat["split_thresh"])] if has("split_thresh") else [])
    # Steuern
    tm = V.string(g("tax_mode"), "tax_mode") if has("tax_mode") else "none"
    if tm not in ("none", "person"):
        raise Manual("tax_mode = %r" % tm + (" (Fondsmodus, seit Etappe 6.5c entfernt)" if tm == "funds" else ""))
    if tm == "person":
        a = []
        if has("tax_rate"):
            a.append(("rate", flat["tax_rate"]))
        if has("church_tax"):
            a.append(("church_tax", flat["church_tax"]))
        if has("use_sparer_pauschbetrag") and not V.truth(g("use_sparer_pauschbetrag"), "use_sparer_pauschbetrag"):
            a.append(("sparer_pauschbetrag", V.lit("zero", None)))
        elif has("sparer_pauschbetrag"):
            a.append(("sparer_pauschbetrag", flat["sparer_pauschbetrag"]))
        if has("private_sale_threshold"):
            a.append(("private_sale_threshold", flat["private_sale_threshold"]))
        if V.truth(g("base_rate_flex"), "base_rate_flex"):
            if has("base_rate_data"):
                a.append(("base_rate", flat["base_rate_data"]))
            else:
                raise Manual("base_rate_flex = TRUE ohne base_rate_data")
        elif has("base_rate"):
            a.append(("base_rate", flat["base_rate"]))
        if has("use_guenstigerpruefung"):
            a.append(("guenstigerpruefung", flat["use_guenstigerpruefung"]))
        if has("taxable_income") and not V.is_null(g("taxable_income")):
            ia = [("taxable_income", flat["taxable_income"])]
            if has("tax_tariff") and not V.is_null(g("tax_tariff")):
                ia.append(("tariff", flat["tax_tariff"]))
            a.append(("income", Block("income_tariff", ia)))
        elif has("marginal_tax_rate") and not V.is_null(g("marginal_tax_rate")):
            ia = [("marginal_rate", flat["marginal_tax_rate"])]
            if V.truth(g("include_soli_on_income_tax"), "include_soli_on_income_tax"):
                ia.append(("soli_rate", flat["soli_rate_income_tax"] if has("soli_rate_income_tax") else V.lit("five", None)))
            a.append(("income", Block("income_rate", ia)))
        if V.truth(g("harvest_mode"), "harvest_mode"):
            ha = [(n, flat[k]) for k, n in (("harvest_day", "day"), ("harvest_loss_pot", "loss_pot")) if has(k)]
            a.append(("harvest", Block("harvest_rule", ha)))
        blocks["tax"] = Block("tax_profile", a)
    return kept, blocks


# ── 1. Engine-Fälle ──────────────────────────────────────────────────────────

def is_converted(args):
    return not any(k in FLAT for k in args) or any(isinstance(v, dict) and "block" in v for v in args.values())


def convert_case(d):
    """JSON-Fall (dict) an Ort und Stelle umstellen; True, wenn geändert."""
    changed = False
    for nm, a in d.get("strategy", {}).items():
        if any(k in a for k in STRATEGY_RENAME):
            d["strategy"][nm] = {STRATEGY_RENAME.get(k, k): v for k, v in a.items()}
            changed = True
    args = d.get("args", {})
    if not is_converted(args):
        kept, blocks = convert(args, JsonVal)
        # sparer_pauschbetrag = 0 heißt aus: das Ergebnis meldet dann den Jahresbetrag 0 (bisher mit
        # use_sparer_pauschbetrag = FALSE den angegebenen Betrag), die Druckausgabe ohne Zeile "SPB genutzt"
        if args.get("use_sparer_pauschbetrag") is False and args.get("tax_mode") == "person" and "result" in d:
            d["result"]["tax_report"]["sparer_pauschbetrag_annual"] = "0x0p+0"
            d["result"]["print"] = "\n".join(l for l in d["result"]["print"].split("\n")
                                              if not l.startswith("  SPB genutzt:"))
        # Meldungen mit Bausteinen nennen den Baustein (Fehlerfälle: nur das Auftreten wird verglichen)
        if "error" in d:
            for old, new in (("simulation: balance_start (", "simulation: start von rebalance_plan() ("),
                             ("simulation: dca_start (", "simulation: start von dca_plan() (")):
                d["error"] = d["error"].replace(old, new)
        new = {}
        for k, v in args.items():
            if k in kept:
                new[k] = v
        for b in BLOCK_ORDER:
            if b in blocks:
                new[b] = blocks[b].to_json()
        d["args"] = new
        d.setdefault("args_flat", args)   # alte Form zur Nachvollziehbarkeit
        changed = True
    return changed


def _read(p):
    op = gzip.open if p.endswith(".gz") else open
    with op(p, "rt", encoding="utf-8") as fh:
        return json.load(fh)


def _write(p, d):
    txt = json.dumps(d, ensure_ascii=False, separators=(",", ":"))
    if p.endswith(".gz"):
        with open(p, "wb") as fh:
            with gzip.GzipFile(filename="", mode="wb", fileobj=fh, compresslevel=9, mtime=0) as gz:
                gz.write(txt.encode("utf-8"))
    else:
        with open(p, "w", encoding="utf-8") as fh:
            fh.write(txt)


def main(argv):
    check = "--check" in argv
    paths = [a for a in argv if not a.startswith("--")]
    files = []
    for p in paths:
        if os.path.isdir(p):
            files += sorted(os.path.join(p, f) for f in os.listdir(p) if f.endswith((".json.gz", ".json")))
        else:
            files.append(p)
    n_changed = 0
    for f in files:
        d = _read(f)
        if check:
            if not is_converted(d.get("args", {})) or any(k in a for a in d.get("strategy", {}).values() for k in STRATEGY_RENAME):
                print("nicht umgestellt:", f)
                n_changed += 1
            continue
        if convert_case(d):
            _write(f, d)
            n_changed += 1
    print("%s: %d von %d Fällen %s" % ("Prüfung" if check else "Umstellung", n_changed, len(files),
                                        "nicht umgestellt" if check else "umgestellt"))
    return 1 if (check and n_changed) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

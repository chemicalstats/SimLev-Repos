"""Asset-Konfiguration und Strategie-Objekte (Port von ``asset_config.R`` und ``strategy.R``).

R-Objekte mit Klasse werden als :class:`simlev._r.rlist.RList` abgebildet
(``x["asset_share"]`` und ``x.asset_share`` gleichwertig); ``print()`` bzw. ``str(x)``
liefern die Ausgabe der R-``print``-Methode.
"""
from __future__ import annotations

import datetime as _dt
import warnings
from typing import Any, Iterable, Mapping

import numpy as np

from ._r.rlist import RList
from ._r.rformat import r_deparse, r_format1, r_sprintf
from ._r.rnum import r_sum

__all__ = [
    "AssetConfig",
    "Strategy",
    "asset_config",
    "create_strategy",
    "validate_strategy",
    "add_asset",
    "update_asset",
    "remove_asset",
]

_ASSET_CLASSES = ("etf", "etn", "etc", "certificate", "etn_standard", "etn_deliverable")
_ACTION_TYPES = ("bnh", "signal")
_VALID_REGIMES = ("investment_fund", "capital_gains", "private_sale")
_FIELDS = ("asset_class", "action_type", "asset_share", "asset_spread", "asset_bonus",
           "deliverable", "asset_start", "tax_regime", "signal_buy", "signal_sell")


def _pmatch(value: str, choices: tuple) -> int | None:
    if value in choices:
        return choices.index(value)
    if not value:
        return None
    hits = [i for i, c in enumerate(choices) if c.startswith(value)]
    return hits[0] if len(hits) == 1 else None


def _match_arg(value: Any, choices: Iterable[str], argname: str = "arg") -> str:
    """Nachbildung von R's ``match.arg`` (inkl. eindeutiger Präfixe und R-Meldungen)."""
    choices = tuple(choices)
    if value is None:
        return choices[0]
    if isinstance(value, (list, tuple)):
        if tuple(value) == choices:
            return choices[0]
        if not all(isinstance(v, str) for v in value):
            raise ValueError("'arg' must be NULL or a character vector")
        if len(value) > 1:
            raise ValueError("'arg' must be of length 1")
        if len(value) == 0:
            value = ""
        else:
            value = value[0]
    if not isinstance(value, str):
        raise ValueError("'arg' must be NULL or a character vector")
    i = _pmatch(value, choices)
    if i is None:
        chs = [c for c in dict.fromkeys(choices) if c]
        raise ValueError(("'arg' should be %s" if len(chs) == 1 else "'arg' should be one of %s")
                         % ", ".join("“%s”" % c for c in chs))
    return choices[i]


def _is_num1(x: Any) -> bool:
    return isinstance(x, (int, float, np.integer, np.floating)) and not isinstance(x, (bool, np.bool_)) \
        and x == x


def _to_date(x: Any) -> _dt.date | None:
    from .engine import _as_date
    z = _as_date(x)
    if z is None:
        return None
    return _dt.date(1970, 1, 1) + _dt.timedelta(days=int(z))


class AssetConfig(RList):
    """Validierte Konfiguration eines Assets (R-Klasse ``asset_config``)."""

    r_class = ("asset_config", "list")

    def format(self) -> str:
        lines = ["Asset-Konfiguration", "-------------------",
                 "  Klasse:       %s" % self["asset_class"],
                 "  Aktion:       %s" % self["action_type"],
                 r_sprintf("  Anteil:       %.1f%%", self["asset_share"] * 100),
                 "  Steuerregime: %s" % self["tax_regime"]]
        if self["asset_class"] == "etf":
            lines.append(r_sprintf("  Teilfrei.:    %.0f%%", self["asset_bonus"]))
        if self["asset_class"] in ("etn", "etc"):
            lines.append("  Lieferbar:    %s" % ("TRUE" if self["deliverable"] else "FALSE"))
        return "\n".join(lines)

    def print(self) -> "AssetConfig":
        print(self.format())
        return self

    def summary(self) -> "AssetConfig":
        """``summary.asset_config``: wie ``print``."""
        return self.print()


def asset_config(
    asset_class: str | Iterable[str] = _ASSET_CLASSES,
    action_type: str | Iterable[str] = _ACTION_TYPES,
    asset_share: float = 1.0,
    asset_spread: float = 0.1,
    asset_bonus: float = 0.0,
    deliverable: bool = False,
    asset_start: Any = None,
    tax_regime: str | None = None,
    signal_buy: str | None = None,
    signal_sell: str | None = None,
) -> AssetConfig:
    """Asset-Konfiguration erstellen und prüfen (R: ``asset_config()``).

    Raten in Prozent: ``asset_spread=0.1`` = 0,1 % voller Bid-Ask-Spread, ``asset_bonus=30`` =
    30 % Teilfreistellung; ``asset_share`` ist ein Anteil in (0, 1]. ``asset_start`` (Datum oder
    ``"JJJJ-MM-TT"``) wird als ``datetime.date`` gespeichert.
    """
    asset_class = _match_arg(asset_class, _ASSET_CLASSES, "asset_class")
    action_type = _match_arg(action_type, _ACTION_TYPES, "action_type")
    if asset_class == "etn_standard":
        warnings.warn("asset_config: asset_class = \"etn_standard\" ist veraltet; stattdessen asset_class = \"etn\" mit "
                      "deliverable = FALSE verwenden.", stacklevel=2)
        asset_class = "etn"
        deliverable = False
    elif asset_class == "etn_deliverable":
        warnings.warn("asset_config: asset_class = \"etn_deliverable\" ist veraltet; stattdessen asset_class = \"etn\" mit "
                      "deliverable = TRUE verwenden.", stacklevel=2)
        asset_class = "etn"
        deliverable = True
    for x, arg in ((asset_share, "asset_share"), (asset_spread, "asset_spread"), (asset_bonus, "asset_bonus")):
        if not _is_num1(x):
            raise ValueError("asset_config: %s muss eine einzelne Zahl sein, nicht %s." % (arg, r_deparse(x)))
    if asset_share <= 0 or asset_share > 1:
        raise ValueError("asset_config: asset_share muss ein Anteil größer 0 und höchstens 1 sein (z. B. 0.6 für "
                         "60 %%), nicht %s%s." % (r_format1(asset_share),
                                                  ("; für %s %% asset_share = %s angeben"
                                                   % (r_format1(asset_share), r_format1(asset_share / 100)))
                                                  if 1 < asset_share <= 100 else ""))
    if asset_spread < 0:
        raise ValueError("asset_config: asset_spread muss >= 0 sein (voller Spread in Prozent, z. B. 0.1 für 0,1 %%), "
                         "nicht %s." % r_format1(asset_spread))
    if asset_bonus < 0 or asset_bonus > 100:
        raise ValueError("asset_config: asset_bonus muss zwischen 0 und 100 liegen (Teilfreistellung in Prozent, z. B. 30 "
                         "für 30 %%), nicht %s." % r_format1(asset_bonus))
    if 0 < asset_bonus < 1:
        warnings.warn("asset_config: asset_bonus = %s wird als %s %% Teilfreistellung gelesen (Prozent-Konvention); "
                      "gemeint war vermutlich %s." % (r_format1(asset_bonus), r_format1(asset_bonus),
                                                     r_format1(asset_bonus * 100)), stacklevel=2)
    if asset_start is not None:
        st = _to_date(asset_start) if not isinstance(asset_start, (list, tuple)) or len(asset_start) == 1 else None
        if st is None:
            raise ValueError("asset_config: asset_start = %s ist kein Datum (erwartet Date oder \"JJJJ-MM-TT\")."
                             % r_deparse(asset_start))
        asset_start = st
    if action_type == "signal" and (signal_buy is None or signal_sell is None):
        raise ValueError("asset_config: bei action_type = \"signal\" müssen signal_buy und signal_sell angegeben werden "
                         "(Namen der Signalspalten in data).")
    if tax_regime is None:
        tax_regime = {"etf": "investment_fund",
                      "etn": "private_sale" if deliverable else "capital_gains",
                      "etc": "private_sale" if deliverable else "capital_gains",
                      "certificate": "capital_gains"}[asset_class]
    elif tax_regime not in _VALID_REGIMES:
        raise ValueError("asset_config: tax_regime = %s ist ungültig; erlaubt sind %s (oder NULL: aus asset_class "
                         "abgeleitet)." % (r_deparse(tax_regime), ", ".join(_VALID_REGIMES)))
    cfg = AssetConfig()
    for k, v in (("asset_class", asset_class), ("action_type", action_type), ("asset_share", asset_share),
                 ("asset_spread", asset_spread), ("asset_bonus", asset_bonus), ("deliverable", deliverable),
                 ("asset_start", asset_start), ("tax_regime", tax_regime), ("signal_buy", signal_buy),
                 ("signal_sell", signal_sell)):
        cfg[k] = v
    return cfg


def _call_asset_config(m: Mapping[str, Any]) -> AssetConfig:
    """``do.call(asset_config, <Liste>)`` (unbekannte Felder sind ein Fehler wie in R)."""
    unknown = [k for k in m if k not in _FIELDS]
    if unknown:
        raise ValueError("unused argument%s (%s)" % ("s" if len(unknown) > 1 else "",
                                                     ", ".join("%s = %s" % (k, r_deparse(m[k])) for k in unknown)))
    return asset_config(**{k: v for k, v in m.items()})


class Strategy(RList):
    """Geordnete Sammlung benannter :class:`AssetConfig`-Objekte (R-Klasse ``strategy``)."""

    r_class = ("strategy", "list")

    def format(self) -> str:
        lines = ["Anlagestrategie (%d %s)" % (len(self), "Asset" if len(self) == 1 else "Assets"),
                 "================================", ""]
        for name, asset in self.items():
            lines.append("%s:" % name)
            lines.append(r_sprintf("  Klasse: %s | Anteil: %.0f%% | Steuer: %s", asset["asset_class"],
                                   asset["asset_share"] * 100, asset["tax_regime"]))
        return "\n".join(lines)

    def print(self) -> "Strategy":
        print(self.format())
        return self

    def summary_text(self) -> str:
        """Text von ``summary.strategy``."""
        out = ["Strategie-Übersicht: %d %s" % (len(self), "Asset" if len(self) == 1 else "Assets"), ""]
        total_share = r_sum([a["asset_share"] for a in self.values()])
        out.append(r_sprintf("Gesamtgewicht: %.1f%%", total_share * 100))
        if abs(total_share - 1) > 0.001:
            out.append("  (Hinweis: Summe ist nicht 100%)")
        out.append("")
        out.append("Nach Steuerregime:")
        regimes = [a["tax_regime"] for a in self.values()]
        for r in dict.fromkeys(regimes):
            n = sum(1 for x in regimes if x == r)
            out.append("  %s: %d %s" % (r, n, "Asset" if n == 1 else "Assets"))
        return "\n".join(out)

    def summary(self) -> "Strategy":
        """``summary.strategy``: druckt die Übersicht und gibt die Strategie zurück."""
        print(self.summary_text())
        return self


def create_strategy(*args: Any, assets: Mapping[str, Any] | None = None, **named: Any) -> Strategy:
    """Strategie aus benannten Asset-Konfigurationen erstellen (R: ``create_strategy()``).

    Beispiel::

        create_strategy(WORLD=asset_config("etf", asset_share=0.7, asset_bonus=30),
                        BONDS=asset_config("etf", asset_share=0.3))

    Alternativ ein ``dict`` über ``assets=``. Einfache ``dict``-Angaben werden mit
    :func:`asset_config` geprüft; die Gewichte werden nicht normiert.
    """
    n_dots = len(args) + len(named)
    if assets is not None and n_dots > 0:
        raise ValueError("create_strategy: Assets entweder über ... oder über assets angeben, nicht beides.")
    dots: list = [(None, a) for a in args] + list(named.items())
    if assets is not None:
        if not isinstance(assets, Mapping):
            raise ValueError("create_strategy: assets muss eine benannte Liste sein (Name = Kursspalte in data), nicht %s."
                             % ("eine unbenannte Liste" if isinstance(assets, (list, tuple)) else type(assets).__name__))
        dots = list(assets.items())
    if not dots:
        raise ValueError("create_strategy: mindestens eine Asset-Konfiguration angeben, z. B. create_strategy(ETF = "
                         "asset_config(\"etf\")).")
    if any(k is None or str(k) == "" for k, _ in dots):
        raise ValueError("create_strategy: alle Assets müssen benannt sein (Name = Kursspalte in data), z. B. "
                         "create_strategy(ETF = asset_config(\"etf\")).")
    out = Strategy()
    for name, cfg in dots:
        name = str(name)
        if isinstance(cfg, AssetConfig):
            out[name] = cfg
        elif isinstance(cfg, Mapping):
            out[name] = _call_asset_config(cfg)
        else:
            raise ValueError("create_strategy: Asset '%s' muss ein asset_config()-Objekt oder eine Liste sein, nicht %s."
                             % (name, _r_class(cfg)))
    return out


def _r_class(x: Any) -> str:
    if x is None:
        return "NULL"
    if isinstance(x, bool):
        return "logical"
    if isinstance(x, (int, float)):
        return "numeric"
    if isinstance(x, str):
        return "character"
    if isinstance(x, RList) and x.r_class:
        return x.r_class[0]
    if isinstance(x, Mapping):
        return "list"
    return type(x).__name__


def validate_strategy(strategy: Strategy, data: Any = None) -> bool:
    """Strategie (und optional die Spalten von ``data``) prüfen; ``True`` oder Fehler."""
    if not isinstance(strategy, Strategy):
        raise ValueError("validate_strategy: strategy muss ein Objekt der Klasse \"strategy\" sein (aus create_strategy()), "
                         "nicht %s." % _r_class(strategy))
    for name, a in strategy.items():
        if not isinstance(a, AssetConfig):
            raise ValueError("validate_strategy: Asset '%s' ist kein asset_config()-Objekt (Klasse %s)."
                             % (name, _r_class(a)))
    if data is not None:
        cols = [str(c) for c in (data.columns if hasattr(data, "columns") else data.keys())]
        missing = [n for n in strategy if n not in cols]
        if missing:
            raise ValueError("validate_strategy: Kursspalte(n) %s fehlen in data (je Asset eine Spalte gleichen Namens; "
                             "vorhanden: %s)." % (", ".join("'%s'" % m for m in missing), ", ".join(cols)))
        for name, a in strategy.items():
            if a["action_type"] == "signal":
                if a["signal_buy"] not in cols:
                    raise ValueError("validate_strategy: signal_buy-Spalte '%s' fehlt in data (Asset '%s')."
                                     % (a["signal_buy"], name))
                if a["signal_sell"] not in cols:
                    raise ValueError("validate_strategy: signal_sell-Spalte '%s' fehlt in data (Asset '%s')."
                                     % (a["signal_sell"], name))
    return True


def add_asset(strategy: Strategy, name: str, asset: AssetConfig) -> Strategy:
    """Asset hinzufügen bzw. ersetzen (gibt eine neue Strategie zurück)."""
    if not isinstance(strategy, Strategy):
        raise ValueError("add_asset: strategy muss ein Objekt der Klasse \"strategy\" sein (aus create_strategy()), nicht %s."
                         % _r_class(strategy))
    if not isinstance(asset, AssetConfig):
        raise ValueError("add_asset: asset muss ein asset_config()-Objekt sein, nicht %s." % _r_class(asset))
    out = Strategy(strategy)
    out[name] = asset
    return out


def update_asset(strategy: Strategy, name: str, **updates: Any) -> Strategy:
    """Felder eines Assets ändern und mit :func:`asset_config` neu prüfen.

    Ändert sich ``asset_class`` oder ``deliverable`` ohne Angabe von ``tax_regime``, wird ein
    bisher automatisch abgeleitetes Steuerregime neu abgeleitet (explizite Werte bleiben).
    """
    if not isinstance(strategy, Strategy):
        raise ValueError("update_asset: strategy muss ein Objekt der Klasse \"strategy\" sein (aus create_strategy()), "
                         "nicht %s." % _r_class(strategy))
    if name not in strategy:
        raise ValueError("update_asset: Asset '%s' ist nicht in der Strategie (vorhanden: %s)."
                         % (name, ", ".join(strategy.keys())))
    asset = dict(strategy[name])
    if any(k in updates for k in ("asset_class", "deliverable")) and "tax_regime" not in updates:
        try:
            with warnings.catch_warnings():
                warnings.simplefilter("ignore")
                tmp = dict(asset)
                tmp["tax_regime"] = None
                derived = _call_asset_config(tmp)["tax_regime"]
        except Exception:  # noqa: BLE001
            derived = None
        if derived == asset.get("tax_regime"):
            asset["tax_regime"] = None
    for param, value in updates.items():
        if param not in asset:
            warnings.warn("update_asset: unbekannter Parameter '%s' wird ignoriert (möglich: %s)."
                          % (param, ", ".join(asset.keys())), stacklevel=2)
            continue
        asset[param] = value
    out = Strategy(strategy)
    out[name] = _call_asset_config(asset)
    return out


def remove_asset(strategy: Strategy, name: str) -> Strategy:
    """Asset entfernen (Warnung, wenn die Strategie danach leer ist)."""
    if not isinstance(strategy, Strategy):
        raise ValueError("remove_asset: strategy muss ein Objekt der Klasse \"strategy\" sein (aus create_strategy()), "
                         "nicht %s." % _r_class(strategy))
    if name not in strategy:
        raise ValueError("remove_asset: Asset '%s' ist nicht in der Strategie (vorhanden: %s)."
                         % (name, ", ".join(strategy.keys())))
    out = Strategy(strategy)
    del out[name]
    if not out:
        warnings.warn("remove_asset: Nach dem Entfernen von '%s' enthält die Strategie keine Assets mehr." % name,
                      stacklevel=2)
    return out


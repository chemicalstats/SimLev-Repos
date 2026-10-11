"""Asset-Konfiguration und Strategie-Objekte (Port von asset_config.R / strategy.R)."""
from __future__ import annotations

import warnings
from typing import Any, Iterable, Mapping

from ._rnum import r_sum

__all__ = [
    "AssetConfig",
    "Strategy",
    "asset_config",
    "create_strategy",
    "validate_strategy",
    "add_asset",
    "update_asset",
    "remove_asset",
    "migrate_strategy",
    "as_list",
]

_ASSET_CLASSES = ("etf", "etn", "etc", "certificate", "etn_standard", "etn_deliverable")
_ACTION_TYPES = ("bnh", "signal")
_VALID_REGIMES = ("investment_fund", "capital_gains", "private_sale")
_FIELDS = (
    "asset_class", "action_type", "asset_share", "asset_spread", "asset_bonus",
    "deliverable", "asset_start", "tax_regime", "signal_buy", "signal_sell",
)


def _match_arg(value: Any, choices: Iterable[str], argname: str) -> str:
    """Nachbildung von R's ``match.arg`` (inkl. eindeutiger Präfixe)."""
    choices = tuple(choices)
    if value is None:
        return choices[0]
    if isinstance(value, (list, tuple)):
        if tuple(value) == choices:
            return choices[0]
        if len(value) != 1:
            raise ValueError(f"'{argname}' must be of length 1")
        value = value[0]
    value = str(value)
    if value in choices:
        return value
    hits = [c for c in choices if c.startswith(value)] if value else []
    if len(hits) == 1:
        return hits[0]
    raise ValueError(
        f"'arg' should be one of {', '.join(repr(c) for c in choices)}"
        f" (argument '{argname}')"
    )


class AssetConfig(dict):
    """Validierte Konfiguration eines Assets (entspricht R-Klasse ``asset_config``).

    Verhält sich wie ein ``dict``; Felder sind zusätzlich als Attribute lesbar.
    """

    def __getattr__(self, item: str) -> Any:
        try:
            return self[item]
        except KeyError as exc:
            raise AttributeError(item) from exc

    def __repr__(self) -> str:
        return self._format()

    def _format(self) -> str:
        lines = [
            "Asset Configuration",
            "-------------------",
            "  Class:        %s" % self["asset_class"],
            "  Action:       %s" % self["action_type"],
            "  Share:        %.1f%%" % (self["asset_share"] * 100),
            "  Tax Regime:   %s" % self["tax_regime"],
        ]
        if self["asset_class"] == "etf":
            lines.append("  Teilfrei.:    %.0f%%" % self["asset_bonus"])
        if self["asset_class"] in ("etn", "etc"):
            lines.append("  Deliverable:  %s" % ("TRUE" if self["deliverable"] else "FALSE"))
        return "\n".join(lines)

    def print(self) -> "AssetConfig":
        print(self._format())
        return self

    def summary(self) -> "AssetConfig":
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
    """Erstellt und validiert die Konfiguration eines Assets.

    Alle Raten folgen der Paket-Konvention **in Prozent**: ``asset_spread=0.1``
    bedeutet 0,1 % vollen Bid-Ask-Spread, ``asset_bonus=30`` bedeutet 30 %
    Teilfreistellung. ``asset_share`` ist ein relatives Zielgewicht in (0, 1].
    """
    asset_class = _match_arg(asset_class, _ASSET_CLASSES, "asset_class")
    action_type = _match_arg(action_type, _ACTION_TYPES, "action_type")

    if asset_class == "etn_standard":
        warnings.warn("asset_class 'etn_standard' is deprecated. Use 'etn' with deliverable = FALSE.")
        asset_class = "etn"
        deliverable = False
    elif asset_class == "etn_deliverable":
        warnings.warn("asset_class 'etn_deliverable' is deprecated. Use 'etn' with deliverable = TRUE.")
        asset_class = "etn"
        deliverable = True

    if asset_share <= 0 or asset_share > 1:
        raise ValueError("asset_share must be between 0 (exclusive) and 1 (inclusive)")
    if asset_spread < 0:
        raise ValueError("asset_spread must be non-negative")
    if asset_bonus < 0 or asset_bonus > 100:
        raise ValueError("asset_bonus must be between 0 and 100 percent (e.g., 30 for 30%)")
    if action_type == "signal" and (signal_buy is None or signal_sell is None):
        raise ValueError("signal_buy and signal_sell must be specified when action_type = 'signal'")

    if tax_regime is None:
        tax_regime = {
            "etf": "investment_fund",
            "etn": "private_sale" if deliverable else "capital_gains",
            "etc": "private_sale" if deliverable else "capital_gains",
            "certificate": "capital_gains",
        }[asset_class]
    elif tax_regime not in _VALID_REGIMES:
        raise ValueError("Invalid tax_regime. Must be one of: %s" % ", ".join(_VALID_REGIMES))

    return AssetConfig(
        asset_class=asset_class,
        action_type=action_type,
        asset_share=asset_share,
        asset_spread=asset_spread,
        asset_bonus=asset_bonus,
        deliverable=deliverable,
        asset_start=asset_start,
        tax_regime=tax_regime,
        signal_buy=signal_buy,
        signal_sell=signal_sell,
    )


def _config_from_mapping(m: Mapping[str, Any]) -> AssetConfig:
    kwargs = {k: v for k, v in m.items() if k in _FIELDS}
    unknown = [k for k in m if k not in _FIELDS]
    if unknown:
        raise TypeError("unused argument(s): %s" % ", ".join(unknown))
    return asset_config(**kwargs)


class Strategy(dict):
    """Geordnete Sammlung benannter :class:`AssetConfig`-Objekte (R-Klasse ``strategy``)."""

    def __repr__(self) -> str:
        return self._format()

    def _format(self) -> str:
        lines = ["Investment Strategy (%d assets)" % len(self), "================================", ""]
        for name, asset in self.items():
            lines.append("%s:" % name)
            lines.append("  Class: %s | Share: %.0f%% | Tax: %s"
                         % (asset["asset_class"], asset["asset_share"] * 100, asset["tax_regime"]))
        return "\n".join(lines)

    def print(self) -> "Strategy":
        print(self._format())
        return self

    def summary(self) -> "Strategy":
        out = ["Strategy Summary: %d assets" % len(self), ""]
        total_share = r_sum([a["asset_share"] for a in self.values()])
        out.append("Total allocation: %.1f%%" % (total_share * 100))
        if abs(total_share - 1) > 0.001:
            out.append("  (Note: Does not sum to 100%)")
        out.append("")
        out.append("By Tax Regime:")
        regimes = [a["tax_regime"] for a in self.values()]
        seen: list[str] = []
        for r in regimes:
            if r not in seen:
                seen.append(r)
        for r in seen:
            out.append("  %s: %d asset(s)" % (r, sum(1 for x in regimes if x == r)))
        print("\n".join(out))
        return self


def create_strategy(*args: Any, assets: Mapping[str, Any] | None = None, **named: Any) -> Strategy:
    """Erstellt eine Strategie aus benannten Asset-Konfigurationen.

    Beispiel::

        create_strategy(
            WORLD=asset_config("etf", asset_share=0.7, asset_bonus=30),
            BONDS=asset_config("etf", asset_share=0.3),
        )

    Alternativ kann ein Mapping über ``assets=`` übergeben werden.
    """
    if args:
        raise ValueError("All assets must be named")
    if assets is not None and named:
        raise ValueError("Provide either ... arguments or 'assets', not both")
    dots: dict[str, Any] = dict(named)
    if assets is not None:
        if not isinstance(assets, Mapping):
            raise ValueError("'assets' must be a named list")
        dots = dict(assets)
    if not dots:
        raise ValueError("At least one asset configuration is required")
    if any(not str(k) for k in dots):
        raise ValueError("All assets must be named")
    out = Strategy()
    for name, cfg in dots.items():
        if isinstance(cfg, AssetConfig):
            out[name] = cfg
        elif isinstance(cfg, Mapping):
            out[name] = _config_from_mapping(cfg)
        else:
            raise ValueError("Asset '%s' must be an asset_config object or list" % name)
    return out


def validate_strategy(strategy: Strategy, data: Any = None) -> bool:
    """Prüft eine Strategie und – optional – ob alle Spalten in ``data`` existieren."""
    if not isinstance(strategy, Strategy):
        raise ValueError("Object is not a strategy")
    for name, a in strategy.items():
        if not isinstance(a, AssetConfig):
            raise ValueError("Asset '%s' is not an asset_config object" % name)
    if data is not None:
        cols = list(data.columns) if hasattr(data, "columns") else list(data.keys())
        missing = [n for n in strategy if n not in cols]
        if missing:
            raise ValueError("Assets not found in data: %s" % ", ".join(missing))
        for name, a in strategy.items():
            if a["action_type"] == "signal":
                if a["signal_buy"] not in cols:
                    raise ValueError("Signal column '%s' not found (asset '%s')" % (a["signal_buy"], name))
                if a["signal_sell"] not in cols:
                    raise ValueError("Signal column '%s' not found (asset '%s')" % (a["signal_sell"], name))
    return True


def add_asset(strategy: Strategy, name: str, asset: AssetConfig) -> Strategy:
    """Fügt ein Asset hinzu (gibt eine neue Strategie zurück)."""
    if not isinstance(strategy, Strategy):
        raise ValueError("First argument must be a strategy object")
    if not isinstance(asset, AssetConfig):
        raise ValueError("asset must be an asset_config object")
    out = Strategy(strategy)
    out[name] = asset
    return out


def update_asset(strategy: Strategy, name: str, **updates: Any) -> Strategy:
    """Aktualisiert Felder eines Assets und validiert es neu."""
    if not isinstance(strategy, Strategy):
        raise ValueError("First argument must be a strategy object")
    if name not in strategy:
        raise ValueError("Asset '%s' not found in strategy" % name)
    asset = dict(strategy[name])
    for param, value in updates.items():
        if param not in asset:
            warnings.warn("Unknown parameter '%s' ignored" % param)
            continue
        asset[param] = value
    out = Strategy(strategy)
    out[name] = asset_config(**asset)
    return out


def remove_asset(strategy: Strategy, name: str) -> Strategy:
    """Entfernt ein Asset."""
    if not isinstance(strategy, Strategy):
        raise ValueError("First argument must be a strategy object")
    if name not in strategy:
        raise ValueError("Asset '%s' not found in strategy" % name)
    out = Strategy(strategy)
    del out[name]
    if not out:
        warnings.warn("Strategy is now empty")
    return out


def migrate_strategy(old_strategy: Mapping[str, Mapping[str, Any]], verbose: bool = True) -> Strategy:
    """Wandelt Strategien mit veralteten Assetklassen in das aktuelle Format um."""
    out = Strategy()
    for name, asset in old_strategy.items():
        asset = dict(asset)
        if asset.get("asset_class") == "etn_deliverable":
            if verbose:
                print("Migrating %s: etn_deliverable -> etn + deliverable=TRUE" % name)
            asset["asset_class"] = "etn"
            asset["deliverable"] = True
        elif asset.get("asset_class") == "etn_standard":
            if verbose:
                print("Migrating %s: etn_standard -> etn + deliverable=FALSE" % name)
            asset["asset_class"] = "etn"
            asset["deliverable"] = False
        out[name] = _config_from_mapping(asset)
    return out


def as_list(x: Any) -> Any:
    """Entfernt die Klassen-Hülle (Strategie -> einfaches ``dict`` aus ``dict``)."""
    if isinstance(x, Strategy):
        return {k: dict(v) for k, v in x.items()}
    if isinstance(x, Mapping):
        return dict(x)
    return list(x)

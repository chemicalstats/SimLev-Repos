"""Tests für asset_config und Strategie-Funktionen (Port von test-asset_config.R / test-strategy.R / test-tax.R)."""
import warnings

import numpy as np
import pandas as pd
import pytest

from simlev import (AssetConfig, Strategy, add_asset, as_list, asset_config, create_strategy, migrate_strategy,
                    remove_asset, update_asset, validate_strategy)


def test_etf_configuration():
    cfg = asset_config(asset_class="etf", asset_share=0.7, asset_bonus=30)
    assert isinstance(cfg, AssetConfig)
    assert cfg.asset_class == "etf"
    assert cfg.asset_share == 0.7
    assert cfg.asset_bonus == 30
    assert cfg.tax_regime == "investment_fund"
    assert cfg.deliverable is False


@pytest.mark.parametrize("cls,deliv,regime", [
    ("etf", False, "investment_fund"),
    ("etn", True, "private_sale"),
    ("etn", False, "capital_gains"),
    ("etc", True, "private_sale"),
    ("etc", False, "capital_gains"),
    ("certificate", False, "capital_gains"),
])
def test_tax_regime_inference(cls, deliv, regime):
    assert asset_config(asset_class=cls, deliverable=deliv).tax_regime == regime


def test_tax_regime_override():
    assert asset_config(asset_class="etf", tax_regime="capital_gains").tax_regime == "capital_gains"


@pytest.mark.parametrize("old,deliv,regime", [("etn_deliverable", True, "private_sale"),
                                              ("etn_standard", False, "capital_gains")])
def test_backward_compatibility(old, deliv, regime):
    with pytest.warns(UserWarning, match="deprecated"):
        cfg = asset_config(asset_class=old)
    assert cfg.asset_class == "etn"
    assert cfg.deliverable is deliv
    assert cfg.tax_regime == regime


@pytest.mark.parametrize("share", [0, 1.5, -0.1])
def test_asset_share_validation(share):
    with pytest.raises(ValueError, match="between 0"):
        asset_config(asset_share=share)


def test_signal_requires_columns():
    with pytest.raises(ValueError, match="signal_buy and signal_sell"):
        asset_config(action_type="signal")
    cfg = asset_config(action_type="signal", signal_buy="buy_col", signal_sell="sell_col")
    assert cfg.signal_buy == "buy_col" and cfg.signal_sell == "sell_col"


def test_invalid_tax_regime():
    with pytest.raises(ValueError, match="Invalid tax_regime"):
        asset_config(tax_regime="invalid")


def test_partial_matching_like_r():
    assert asset_config("cert").asset_class == "certificate"
    assert asset_config(action_type="sig", signal_buy="a", signal_sell="b").action_type == "signal"


def test_print_asset_config(capsys):
    asset_config(asset_class="etf", asset_bonus=30).print()
    out = capsys.readouterr().out
    assert "Asset Configuration" in out and "etf" in out and "investment_fund" in out


def _two_asset():
    return create_strategy(SPY=asset_config("etf", "bnh", 0.6, 0.1, 30),
                           BND=asset_config("etf", "bnh", 0.4, 0.05, 0))


def test_create_strategy():
    s = _two_asset()
    assert isinstance(s, Strategy)
    assert list(s) == ["SPY", "BND"]


def test_create_strategy_assets_param_and_plain_dicts():
    s = create_strategy(assets={"A": {"asset_class": "etf", "asset_share": 1.0}})
    assert isinstance(s["A"], AssetConfig)
    with pytest.raises(ValueError):
        create_strategy(assets={"A": asset_config()}, B=asset_config())


def test_create_strategy_rejects_empty():
    with pytest.raises(ValueError, match="At least one"):
        create_strategy()


def test_validate_strategy_columns():
    s = _two_asset()
    df = pd.DataFrame({"date": pd.date_range("2020-01-01", periods=3), "SPY": [1, 2, 3], "BND": [1, 2, 3]})
    assert validate_strategy(s, df)
    with pytest.raises(ValueError, match="Assets not found in data: BND"):
        validate_strategy(s, df.drop(columns="BND"))
    sig = create_strategy(SPY=asset_config("etf", "signal", signal_buy="b", signal_sell="s"))
    with pytest.raises(ValueError, match="Signal column 'b' not found"):
        validate_strategy(sig, df)


def test_add_update_remove():
    s = _two_asset()
    s2 = add_asset(s, "GOLD", asset_config("etc", asset_share=0.1, deliverable=True))
    assert "GOLD" in s2 and "GOLD" not in s
    s3 = update_asset(s2, "SPY", asset_share=0.5)
    assert s3["SPY"].asset_share == 0.5
    with pytest.warns(UserWarning, match="Unknown parameter"):
        update_asset(s2, "SPY", nonsense=1)
    with pytest.raises(ValueError, match="not found"):
        update_asset(s2, "XXX", asset_share=0.5)
    s4 = remove_asset(s3, "GOLD")
    assert list(s4) == ["SPY", "BND"]
    with pytest.warns(UserWarning, match="empty"):
        remove_asset(create_strategy(A=asset_config()), "A")


def test_migrate_strategy(capsys):
    old = {"G": {"asset_class": "etn_deliverable", "asset_share": 1.0}}
    new = migrate_strategy(old)
    assert new["G"].asset_class == "etn" and new["G"].deliverable is True
    assert "Migrating G" in capsys.readouterr().out


def test_print_and_summary(capsys):
    s = _two_asset()
    s.print()
    s.summary()
    out = capsys.readouterr().out
    assert "Investment Strategy (2 assets)" in out
    assert "Total allocation: 100.0%" in out


def test_as_list():
    lst = as_list(_two_asset())
    assert type(lst) is dict and type(lst["SPY"]) is dict

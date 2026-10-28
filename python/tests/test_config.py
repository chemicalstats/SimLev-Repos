"""Port von test-asset_config.R und test-strategy.R (SimLev 0.5.0)."""
import datetime as dt

import pandas as pd
import pytest

from simlev import (AssetConfig, Strategy, strategy_add_asset, asset_config, rebalance_trigger, create_strategy,
                    strategy_remove_asset, strategy_update_asset, strategy_validate)


# ── asset_config ──────────────────────────────────────────────────────────
def test_etf_configuration():
    cfg = asset_config(asset_class="etf", share=0.7, partial_exemption=30)
    assert isinstance(cfg, AssetConfig)
    assert cfg.asset_class == "etf" and cfg["share"] == 0.7 and cfg.partial_exemption == 30
    assert cfg.tax_regime == "investment_fund"
    assert cfg.deliverable is False
    assert list(cfg.keys()) == ["asset_class", "trading", "share", "spread", "partial_exemption",
                                "deliverable", "start", "tax_regime", "signal_buy", "signal_sell"]


def test_deliverable_regimes():
    assert asset_config(asset_class="etc", deliverable=True).tax_regime == "private_sale"
    assert asset_config(asset_class="etn", deliverable=False).tax_regime == "capital_gains"
    assert asset_config(asset_class="certificate").tax_regime == "capital_gains"


@pytest.mark.parametrize("old,deliv,regime", [("etn_deliverable", True, "private_sale"),
                                              ("etn_standard", False, "capital_gains")])
def test_backward_compatibility(old, deliv, regime):
    with pytest.warns(UserWarning, match='asset_class = "%s" ist veraltet' % old):
        cfg = asset_config(asset_class=old)
    assert cfg.asset_class == "etn" and cfg.deliverable is deliv and cfg.tax_regime == regime


def test_asset_share_validation():
    with pytest.raises(ValueError, match=r"share muss ein Anteil größer 0 und höchstens 1 sein .*nicht 0\."):
        asset_config(share=0)
    with pytest.raises(ValueError, match=r"nicht 1\.5; für 1\.5 % share = 0\.015 angeben"):
        asset_config(share=1.5)
    with pytest.raises(ValueError, match=r"nicht -0\.1\."):
        asset_config(share=-0.1)
    with pytest.raises(ValueError, match=r'share muss eine einzelne Zahl sein, nicht "0.5"'):
        asset_config(share="0.5")


def test_other_validations():
    with pytest.raises(ValueError, match="müssen signal_buy und signal_sell angegeben werden"):
        asset_config(trading="signal")
    cfg = asset_config(trading="signal", signal_buy="buy_col", signal_sell="sell_col")
    assert (cfg.signal_buy, cfg.signal_sell) == ("buy_col", "sell_col")
    with pytest.raises(ValueError, match='tax_regime = "invalid" ist ungültig'):
        asset_config(tax_regime="invalid")
    with pytest.raises(ValueError, match="spread muss >= 0 sein"):
        asset_config(spread=-1)
    with pytest.raises(ValueError, match="partial_exemption muss zwischen 0 und 100 liegen"):
        asset_config(partial_exemption=101)
    with pytest.warns(UserWarning, match="partial_exemption = 0.3 wird als 0.3 % Teilfreistellung gelesen"):
        asset_config(partial_exemption=0.3)
    with pytest.raises(ValueError, match="'arg' should be one of “etf”, “etn”"):
        asset_config(asset_class="xyz")
    with pytest.raises(ValueError, match='start = "abc" ist kein Datum'):
        asset_config(start="abc")
    assert asset_config(start="2016-07-15").start == dt.date(2016, 7, 15)


def test_print_asset_config():
    out = str(asset_config(asset_class="etf", partial_exemption=30))
    assert out == ("Asset-Konfiguration\n-------------------\n  Klasse:       etf\n  Aktion:       bnh\n"
                   "  Anteil:       100.0%\n  Steuerregime: investment_fund\n  Teilfrei.:    30%")
    assert str(asset_config(asset_class="etc", deliverable=True)).endswith("  Lieferbar:    TRUE")


# ── Strategie ─────────────────────────────────────────────────────────────
def test_create_strategy():
    s = create_strategy(ETF=asset_config(asset_class="etf"), Gold=asset_config(asset_class="etc"))
    assert isinstance(s, Strategy) and list(s) == ["ETF", "Gold"]
    s2 = create_strategy(assets={"ETF": {"asset_class": "etf", "share": 0.7},
                                 "Bond": {"asset_class": "etf", "share": 0.3, "partial_exemption": 0}})
    assert isinstance(s2.ETF, AssetConfig) and isinstance(s2["Bond"], AssetConfig)


def test_create_strategy_errors():
    with pytest.raises(ValueError, match="mindestens eine Asset-Konfiguration"):
        create_strategy()
    with pytest.raises(ValueError, match="alle Assets müssen benannt sein"):
        create_strategy(asset_config())
    with pytest.raises(ValueError, match="nicht beides"):
        create_strategy(A=asset_config(), assets={"B": asset_config()})
    with pytest.raises(ValueError, match="Asset 'A' muss ein asset_config\\(\\)-Objekt oder eine Liste sein, nicht numeric"):
        create_strategy(A=5)


def test_validate_strategy():
    s = create_strategy(ETF=asset_config(asset_class="etf"))
    assert strategy_validate(s, data=pd.DataFrame({"date": [pd.Timestamp("2024-01-01")], "ETF": [100]}))
    with pytest.raises(ValueError, match=r"Kursspalte\(n\) 'ETF' fehlen in data"):
        strategy_validate(s, data=pd.DataFrame({"date": [pd.Timestamp("2024-01-01")], "Other": [100]}))
    s2 = create_strategy(ETF=asset_config(trading="signal", signal_buy="buy_signal", signal_sell="sell_signal"))
    assert strategy_validate(s2, data=pd.DataFrame({"ETF": [100], "buy_signal": [True], "sell_signal": [False]}))
    with pytest.raises(ValueError, match="signal_buy-Spalte 'buy_signal' fehlt in data"):
        strategy_validate(s2, data=pd.DataFrame({"ETF": [100]}))
    with pytest.raises(ValueError, match='strategy muss ein Objekt der Klasse "strategy"'):
        strategy_validate({})


def test_add_update_remove():
    s = create_strategy(ETF=asset_config(share=0.5))
    s = strategy_add_asset(s, "Gold", asset_config(asset_class="etc"))
    assert list(s) == ["ETF", "Gold"]
    s = strategy_update_asset(s, "ETF", share=0.8)
    assert s.ETF.share == 0.8
    with pytest.raises(ValueError, match="Asset 'Unknown' ist nicht in der Strategie"):
        strategy_update_asset(s, "Unknown", share=0.5)
    with pytest.warns(UserWarning, match="unbekannter Parameter 'nonsense' wird ignoriert"):
        strategy_update_asset(s, "ETF", nonsense=1)
    s = strategy_remove_asset(s, "Gold")
    assert list(s) == ["ETF"]
    with pytest.warns(UserWarning, match="keine Assets mehr"):
        strategy_remove_asset(s, "ETF")


def test_update_asset_rederives_regime():
    # R1-25: abgeleitetes Steuerregime wird nach Änderung von deliverable neu abgeleitet
    s = create_strategy(G=asset_config(asset_class="etc", deliverable=True))
    assert strategy_update_asset(s, "G", deliverable=False).G.tax_regime == "capital_gains"
    s2 = create_strategy(G=asset_config(asset_class="etc", deliverable=True, tax_regime="investment_fund"))
    assert strategy_update_asset(s2, "G", deliverable=False).G.tax_regime == "investment_fund"


def test_print_and_summary(capsys):
    s = create_strategy(ETF=asset_config(share=0.7), Gold=asset_config(share=0.3, asset_class="etc"))
    assert str(s) == ("Anlagestrategie (2 Assets)\n================================\n\nETF:\n"
                      "  Klasse: etf | Anteil: 70% | Steuer: investment_fund\nGold:\n"
                      "  Klasse: etc | Anteil: 30% | Steuer: capital_gains")
    s.summary()
    out = capsys.readouterr().out
    assert "Strategie-Übersicht: 2 Assets" in out and "Gesamtgewicht: 100.0%" in out
    assert "  investment_fund: 1 Asset" in out


# ── rebalance_trigger ─────────────────────────────────────────────────
def test_trigger_first_observation_reference():
    # R1-21: Referenz = erster nicht fehlender Wert, NA löst nicht aus
    d = pd.DataFrame({"lev": [float("nan"), float("nan"), 2, 2.2, 2.5, 2.4, float("nan"), 3]})
    assert list(rebalance_trigger(d, "abs_leverage", threshold=15, lev_col="lev").rebal_trigger) == \
        [False, False, False, True, True, False, False, True]
    assert list(rebalance_trigger(d, "rel_leverage", threshold=10, lev_col="lev").rebal_trigger) == \
        [False, False, False, True, True, False, False, True]
    with pytest.raises(ValueError, match="Spalte 'zz' fehlt"):
        rebalance_trigger(d, "vol_band", vol_col="zz")
    with pytest.raises(ValueError, match="benötigt eine nicht-leere Liste 'triggers'"):
        rebalance_trigger(d, "combined")

"""Schnellstart: 70/30-Portfolio mit jährlichem Rebalancing und deutscher Besteuerung."""
import numpy as np
import pandas as pd

import simlev

# 1. Preisdaten: eine Datumsspalte plus eine Preisspalte je Asset
rng = np.random.default_rng(42)
n = 365 * 10
data = pd.DataFrame({
    "date": pd.date_range("2015-01-01", periods=n, freq="D"),
    "WORLD": 100 * np.cumprod(1 + rng.normal(4e-4, 0.010, n)),
    "BONDS": 50 * np.cumprod(1 + rng.normal(1e-4, 0.003, n)),
})

# 2. Strategie: Gewichte, Spread und Teilfreistellung (in Prozent)
strategy = simlev.create_strategy(
    WORLD=simlev.asset_config("etf", action_type="bnh", asset_share=0.7, asset_spread=0.1, asset_bonus=30),
    BONDS=simlev.asset_config("etf", action_type="bnh", asset_share=0.3, asset_spread=0.1, asset_bonus=0),
)

# 3. Simulation
result = simlev.simulation(
    data, strategy,
    start_value=10000,
    balance_mode=True, balance_span=1, balance_unit="year",
    tax_mode="person", tax_rate=26.375,
    liquidate=True,
    risk_free=2,
)

print(result)
fig = result.plot()                      # Dashboard (matplotlib)
fig.savefig("dashboard.png", dpi=110)

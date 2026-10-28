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
    WORLD=simlev.asset_config(asset_class="etf", trading="bnh", share=0.7, spread=0.1, partial_exemption=30),
    BONDS=simlev.asset_config(asset_class="etf", trading="bnh", share=0.3, spread=0.1, partial_exemption=0),
)

# 3. Simulation
result = simlev.simulation(
    data, strategy,
    start_value=10000,
    rebalance=simlev.rebalance_plan(span=1, unit="year"),
    tax=simlev.tax_profile(rate=26.375),
    liquidate=True,
    risk_free=2,
)

print(result)
p = result.plot()                        # Dashboard als SVG (SimLevPlot; Werte je Panel in p.data)
p.save("dashboard.svg")

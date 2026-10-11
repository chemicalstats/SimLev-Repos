"""SimLev – Backtesting für ETF-, Hebel- und Multi-Asset-Strategien mit deutscher
Investmentbesteuerung.

Python-Portierung des gleichnamigen R-Pakets. Die Engine rechnet bitgleich zur
R-Version (getestet unter Linux x86-64).
"""
from .config import (
    AssetConfig,
    Strategy,
    add_asset,
    as_list,
    asset_config,
    create_strategy,
    migrate_strategy,
    remove_asset,
    update_asset,
    validate_strategy,
)
from .engine import simulation
from .result import SimLevResult
from .trigger import compute_rebal_trigger

__version__ = "0.1.0"

__all__ = [
    "AssetConfig",
    "SimLevResult",
    "Strategy",
    "add_asset",
    "as_list",
    "asset_config",
    "compute_rebal_trigger",
    "create_strategy",
    "export_dashboard",
    "export_html_dashboard",
    "migrate_strategy",
    "plot_interactive",
    "remove_asset",
    "simulation",
    "update_asset",
    "validate_strategy",
]


def export_dashboard(x, filename: str = "dashboard.pdf", width: float = 14, height: float = 10, **kwargs):
    """Speichert das Dashboard als PDF (oder anderes von matplotlib unterstütztes Format)."""
    from .dashboard import export_dashboard as _impl
    return _impl(x, filename=filename, width=width, height=height, **kwargs)


def export_html_dashboard(x, filename: str = "dashboard.html"):
    """Erstellt ein interaktives HTML-Dashboard."""
    from .dashboard import export_html_dashboard as _impl
    return _impl(x, filename=filename)


def plot_interactive(x, file=None, panels=("performance", "drawdown", "weights"), max_points=6000,
                     open=None, engine="auto"):
    """Interaktives HTML-Dashboard mit Tooltips (eigenständig oder über plotly)."""
    from .interactive import plot_interactive as _impl
    return _impl(x, file=file, panels=panels, max_points=max_points, open=open, engine=engine)

"""Interaktives HTML-Dashboard (Port von plot_interactive.R).

Ohne zusätzliche Pakete entsteht eine vollständig eigenständige HTML-Datei
(Inline-SVG + JavaScript), die offline in jedem Browser funktioniert. Ist
``plotly`` installiert, kann wahlweise eine plotly-Figur erzeugt werden.
"""
from __future__ import annotations

import math
import os
import sys
import tempfile
import webbrowser
from typing import Any, Sequence

import numpy as np

from ._dates import fmt_date
from ._rnum import r_cumsum

__all__ = ["plot_interactive"]

_PANELS = ("performance", "drawdown", "weights")
_PAL = ("#2C7FB8", "#D95F02", "#1B9E77", "#7570B3", "#E7298A", "#66A61E", "#E6AB02", "#A6761D")


def _thin_index(n: int, max_points: int) -> np.ndarray:
    """``unique(c(round(seq(1, n, length.out = max_points)), n))`` wie in R (1-basiert)."""
    if n <= max_points:
        return np.arange(1, n + 1)
    n1 = max_points - 1
    by = (n - 1) / n1
    seq = [1.0] + [1.0 + k * by for k in range(1, n1)] + [float(n)]
    idx = np.rint(np.array(seq))
    out: list[int] = []
    seen = set()
    for v in list(idx.astype(int)) + [n]:
        if v not in seen:
            seen.add(v)
            out.append(int(v))
    return np.array(out)


def _build_data(x, max_points: int) -> dict:
    dates = np.asarray(x.dates).astype("datetime64[D]").astype(np.int64)
    n = dates.size
    keep = _thin_index(n, max_points) - 1
    assets = list(x.report.keys())
    totals = [np.asarray(x.report[a]["total"], dtype=float)[keep] for a in assets]
    tot_sum = totals[0].copy()
    for t in totals[1:]:
        tot_sum = tot_sum + t
    flows = np.asarray(x.report[assets[0]]["flows"], dtype=float).copy()
    for a in assets[1:]:
        flows = flows + np.asarray(x.report[a]["flows"], dtype=float)
    invested = r_cumsum(flows)[keep]
    dd = np.asarray(x.drawdowns, dtype=float)[keep]
    weights = []
    for t in totals:
        with np.errstate(divide="ignore", invalid="ignore"):
            weights.append(np.where(tot_sum > 0, 100 * t / tot_sum, 0.0))
    return {
        "dates": [fmt_date(int(z)) for z in dates[keep]],
        "filled": np.asarray(x.filled, dtype=bool)[keep],
        "assets": assets,
        "worth": np.asarray(x.worth, dtype=float)[keep],
        "invested": invested,
        "totals": totals,
        "weights": weights,
        "drawdown": 100 * dd,
        "result": x,
    }


def _num2js(v) -> str:
    v = np.asarray(v, dtype=float)
    parts = ["%.6g" % a if math.isfinite(a) else "null" for a in v]
    return "[" + ",".join(parts) + "]"


def _chr2js(v) -> str:
    return '["' + '","'.join(v) + '"]'


def _plotly_figure(d: dict, panels: Sequence[str]):
    import plotly.graph_objects as go
    from plotly.subplots import make_subplots
    rows = [p for p in _PANELS if p in panels]
    fig = make_subplots(rows=len(rows), cols=1, shared_xaxes=True)
    r = 1
    if "performance" in rows:
        for a, t in zip(d["assets"], d["totals"]):
            fig.add_trace(go.Scatter(x=d["dates"], y=t, name=a, mode="lines"), row=r, col=1)
        fig.add_trace(go.Scatter(x=d["dates"], y=d["worth"], name="Gesamt", mode="lines", line={"width": 3}),
                      row=r, col=1)
        fig.add_trace(go.Scatter(x=d["dates"], y=d["invested"], name="Einzahlungen", mode="lines",
                                 line={"dash": "dot"}), row=r, col=1)
        fig.update_yaxes(title_text="EUR", row=r, col=1)
        r += 1
    if "drawdown" in rows:
        fig.add_trace(go.Scatter(x=d["dates"], y=d["drawdown"], mode="lines", fill="tozeroy",
                                 name="Drawdown %"), row=r, col=1)
        r += 1
    if "weights" in rows:
        for a, w in zip(d["assets"], d["weights"]):
            fig.add_trace(go.Scatter(x=d["dates"], y=w, name=a + " %", mode="lines"), row=r, col=1)
    return fig


def _js_panel(pid: str, title: str, series: list[dict], unit: str, fill_first: bool = False) -> str:
    ser = []
    for s in series:
        w = s.get("width", 1.6)
        ws = ("%d" % w) if float(w).is_integer() else repr(float(w))
        ser.append('{name:"%s",col:"%s",w:%s,dash:%s,v:%s}' % (
            s["name"], s["col"], ws, "true" if s.get("dash") else "false", _num2js(s["vals"])))
    return 'makePanel("%s","%s",[%s],"%s",%s);' % (pid, title, ",".join(ser), unit,
                                                  "true" if fill_first else "false")


def _stat_line(x) -> str:
    def p(fmt: str, v: Any) -> str:
        return "NA" if v is None or (isinstance(v, float) and math.isnan(v)) else fmt % v
    s = x.statistics
    return "CAGR %s%% &middot; Sharpe %s &middot; Max. Drawdown %s%%" % (
        p("%.2f", 100 * x.cagr if not math.isnan(x.cagr) else math.nan),
        p("%.2f", s.get("sharpe", math.nan)),
        p("%.1f", 100 * s.get("max_drawdown", math.nan)))


def _build_html(d: dict, panels: Sequence[str]) -> str:
    series_perf = [{"name": a, "col": _PAL[i % len(_PAL)], "vals": d["totals"][i], "width": 1.4}
                   for i, a in enumerate(d["assets"])]
    series_perf.append({"name": "Gesamt", "col": "#111111", "vals": d["worth"], "width": 2.4})
    series_perf.append({"name": "Einzahlungen", "col": "#888888", "vals": d["invested"], "width": 1.4,
                        "dash": True})
    series_w = [{"name": a, "col": _PAL[i % len(_PAL)], "vals": d["weights"][i], "width": 1.6}
                for i, a in enumerate(d["assets"])]
    calls, divs = [], []
    if "performance" in panels:
        divs.append('<div class="panel" id="performance"></div>')
        calls.append(_js_panel("performance", "Portfolio Performance", series_perf, " EUR"))
    if "drawdown" in panels:
        divs.append('<div class="panel" id="drawdown"></div>')
        calls.append(_js_panel("drawdown", "Drawdown",
                               [{"name": "Drawdown", "col": "#C0392B", "vals": d["drawdown"], "width": 1.6}],
                               " %", fill_first=True))
    if "weights" in panels:
        divs.append('<div class="panel" id="weights"></div>')
        calls.append(_js_panel("weights", "Asset-Gewichte", series_w, " %"))
    stat_line = _stat_line(d["result"])
    return (_HTML_HEAD + stat_line + _HTML_SUB + "\n".join(divs) + _HTML_MID1 + _chr2js(d["dates"]) + ";\nvar FILLED="
            + _num2js(d["filled"].astype(float)) + _HTML_SCRIPT + "\n".join(calls) + _HTML_TAIL)


def plot_interactive(x, file: str | None = None, panels: Sequence[str] = _PANELS, max_points: int = 6000,
                     open: bool | None = None, engine: str = "auto"):
    """Interaktives Dashboard mit Hover-Tooltips, synchronem Fadenkreuz und klickbarer Legende.

    ``engine``: ``"auto"`` (plotly, falls installiert, sonst eigener HTML-Writer),
    ``"plotly"`` oder ``"html"``. Rückgabe: Pfad der HTML-Datei bzw. die
    plotly-Figur.
    """
    from .config import _match_arg
    engine = _match_arg(engine, ("auto", "plotly", "html"), "engine")
    if isinstance(panels, str):
        panels = [panels]
    panels = [_match_arg(p, _PANELS, "panels") for p in panels]
    if file is None:
        fd, file = tempfile.mkstemp(prefix="simlev_dashboard_", suffix=".html")
        os.close(fd)
    if open is None:
        open = bool(getattr(sys, "ps1", None)) or "ipykernel" in sys.modules
    has_plotly = True
    try:
        import plotly  # noqa: F401
    except Exception:  # noqa: BLE001
        has_plotly = False
    if engine == "auto":
        engine = "plotly" if has_plotly else "html"
    if engine == "plotly" and not has_plotly:
        import warnings
        warnings.warn("plotly ist nicht installiert - nutze den eingebauten HTML-Writer.")
        engine = "html"
    d = _build_data(x, max_points)
    if engine == "plotly":
        return _plotly_figure(d, panels)
    html = _build_html(d, panels)
    with __import__("builtins").open(file, "w", encoding="utf-8") as fh:
        fh.write(html + "\n")
    if open:
        webbrowser.open("file://" + os.path.abspath(file))
    return file


_HTML_HEAD = """<!DOCTYPE html><html lang="de"><head><meta charset="utf-8">
<title>SimLev Dashboard</title><style>
body{font-family:system-ui,Segoe UI,Arial,sans-serif;margin:18px;background:#fafafa;color:#222}
h1{font-size:20px;margin:0 0 2px}.sub{color:#666;font-size:13px;margin-bottom:14px}
.panel{background:#fff;border:1px solid #e3e3e3;border-radius:8px;margin-bottom:14px;padding:10px 12px 4px}
.ptitle{font-weight:600;font-size:14px;margin-bottom:2px}
.legend span{display:inline-block;margin-right:14px;font-size:12px;cursor:pointer;user-select:none}
.legend .off{opacity:.35;text-decoration:line-through}
.legend i{display:inline-block;width:18px;height:3px;margin-right:5px;vertical-align:middle}
svg{display:block;width:100%;height:260px}
.tip{position:fixed;pointer-events:none;background:rgba(20,20,20,.92);color:#fff;
padding:7px 10px;border-radius:6px;font-size:12px;line-height:1.5;display:none;z-index:9;max-width:340px}
.tip b{color:#9cf}.axis{font-size:10px;fill:#777}
</style></head><body>
<h1>SimLev &ndash; Interaktives Dashboard</h1>
<div class="sub">"""

_HTML_SUB = """ &middot; Hover f&uuml;r Details, Legende klickbar</div>
"""

_HTML_MID1 = """
<div class="tip" id="tip"></div>
<script>
"use strict";
var DATES="""

_HTML_SCRIPT = """;
var N=DATES.length, tip=document.getElementById("tip"), PANELS=[];
function fmt(v,u){return v==null?"&ndash;":(Math.abs(v)>=1000?v.toLocaleString("de-DE",{maximumFractionDigits:0}):v.toLocaleString("de-DE",{maximumFractionDigits:2}))+u}
function makePanel(id,title,series,unit,fillFirst){
 var host=document.getElementById(id); if(!host)return;
 host.innerHTML='<div class="ptitle">'+title+'</div><div class="legend"></div>';
 var leg=host.querySelector(".legend");
 var svg=document.createElementNS("http://www.w3.org/2000/svg","svg");
 host.appendChild(svg);
 var P={id:id,series:series,unit:unit,fillFirst:fillFirst,svg:svg,on:series.map(function(){return true})};
 series.forEach(function(s,i){
   var el=document.createElement("span");
   el.innerHTML='<i style="background:'+s.col+'"></i>'+s.name;
   el.onclick=function(){P.on[i]=!P.on[i];el.classList.toggle("off");draw(P)};
   leg.appendChild(el);
 });
 PANELS.push(P); draw(P);
 svg.addEventListener("mousemove",function(e){hover(e,P)});
 svg.addEventListener("mouseleave",function(){tip.style.display="none";
   PANELS.forEach(function(q){var c=q.svg.querySelector(".xh");if(c)c.setAttribute("opacity",0)})});
}
function extent(P){var lo=Infinity,hi=-Infinity;
 P.series.forEach(function(s,i){if(!P.on[i])return;
  for(var k=0;k<N;k++){var v=s.v[k];if(v==null)continue;if(v<lo)lo=v;if(v>hi)hi=v}});
 if(lo===Infinity){lo=0;hi=1} if(lo===hi){hi=lo+1} return [lo,hi];}
function draw(P){
 var W=P.svg.clientWidth||900,H=260,L=62,R=12,T=10,B=24;
 P.geo={W:W,H:H,L:L,R:R,T:T,B:B};
 var ex=extent(P),lo=ex[0],hi=ex[1],pad=(hi-lo)*0.05;lo-=pad;hi+=pad;
 P.lo=lo;P.hi=hi;
 function X(k){return L+(W-L-R)*k/(N-1)} function Y(v){return T+(H-T-B)*(1-(v-lo)/(hi-lo))}
 P.X=X;P.Y=Y;
 var g='<line class="xh" x1="0" x2="0" y1="'+T+'" y2="'+(H-B)+'" stroke="#999" stroke-dasharray="3,3" opacity="0"/>';
 for(var t=0;t<=4;t++){var v=lo+(hi-lo)*t/4,y=Y(v);
   g+='<line x1="'+L+'" x2="'+(W-R)+'" y1="'+y+'" y2="'+y+'" stroke="#eee"/>'+
      '<text class="axis" x="'+(L-6)+'" y="'+(y+3)+'" text-anchor="end">'+fmt(v,"")+'</text>'}
 for(var q=0;q<=5;q++){var k=Math.round((N-1)*q/5);
   g+='<text class="axis" x="'+X(k)+'" y="'+(H-8)+'" text-anchor="middle">'+DATES[k].slice(0,7)+'</text>'}
 P.series.forEach(function(s,i){if(!P.on[i])return;
  var dstr="",first=true;
  for(var k=0;k<N;k++){var v=s.v[k];if(v==null){first=true;continue}
    dstr+=(first?"M":"L")+X(k).toFixed(1)+" "+Y(v).toFixed(1);first=false}
  if(P.fillFirst&&i===0){
    var area=dstr+"L"+X(N-1).toFixed(1)+" "+Y(Math.min(0,P.hi)).toFixed(1)+
             "L"+X(0).toFixed(1)+" "+Y(Math.min(0,P.hi)).toFixed(1)+"Z";
    g+='<path d="'+area+'" fill="'+s.col+'" opacity="0.18"/>'}
  g+='<path d="'+dstr+'" fill="none" stroke="'+s.col+'" stroke-width="'+s.w+'"'+
     (s.dash?' stroke-dasharray="5,4"':"")+'/>'});
 P.svg.setAttribute("viewBox","0 0 "+W+" "+H);
 P.svg.innerHTML=g;
}
function hover(e,src){
 var r=src.svg.getBoundingClientRect(),g=src.geo;
 var frac=(e.clientX-r.left-g.L)/(r.width-g.L-g.R);
 var k=Math.max(0,Math.min(N-1,Math.round(frac*(N-1))));
 PANELS.forEach(function(P){
   var gg=P.geo,x=P.X(k),c=P.svg.querySelector(".xh");
   if(c){c.setAttribute("x1",x);c.setAttribute("x2",x);c.setAttribute("opacity",1)}});
 var h="<b>"+DATES[k]+"</b>"+(FILLED[k]?" (aufgef&uuml;llt)":"");
 PANELS.forEach(function(P){
   P.series.forEach(function(s,i){if(!P.on[i])return;
     h+='<br><i style="display:inline-block;width:10px;height:10px;border-radius:2px;background:'+
        s.col+';margin-right:5px"></i>'+s.name+": <b>"+fmt(s.v[k],P.unit)+"</b>"})});
 tip.innerHTML=h;tip.style.display="block";
 tip.style.left=Math.min(e.clientX+16,window.innerWidth-360)+"px";
 tip.style.top=(e.clientY+14)+"px";
}
"""

_HTML_TAIL = """
window.addEventListener("resize",function(){PANELS.forEach(draw)});
</script></body></html>"""

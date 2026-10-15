#' Interaktives Dashboard fuer SimLev-Ergebnisse (Hover-Tooltips)
#'
#' Erzeugt ein interaktives Dashboard: Beim Ueberfahren der Grafiken mit der
#' Maus erscheinen Datum und Werte aller Serien (Crosshair ueber alle Panels,
#' Serien lassen sich per Klick auf die Legende ein-/ausblenden).
#'
#' Standardmaessig (\code{engine = "auto"}) wird \pkg{plotly} verwendet, sofern
#' es installiert ist; andernfalls schreibt SimLev ein vollstaendig
#' \strong{eigenstaendiges HTML-Dashboard ohne jede Abhaengigkeit}
#' (Inline-SVG + JavaScript), das offline in jedem Browser funktioniert.
#'
#' @param x Ein \code{SimLevResult}-Objekt aus \code{\link{simulation}}.
#' @param file Zieldatei (\code{.html}). \code{NULL} = temporaere Datei.
#' @param panels Zeichenvektor (ein oder mehrere Werte): \code{"performance"}
#'   (Depotwert je Asset, Gesamt und Summe der Einzahlungen einschliesslich Startwert in EUR,
#'   brutto vor Kaufkosten wie \code{x$invested}),
#'   \code{"drawdown"} (\code{x$drawdowns} in Prozent; mit Sparplan zeitgewichtet),
#'   \code{"weights"} (Ist-Gewichte in Prozent). Die Kopfzeile zeigt CAGR, Sharpe und
#'   Max. Drawdown aus dem Ergebnis; mit Sparplan als "CAGR (geldgewichtet)" und
#'   "Max. Drawdown (zeitgewichtet)" beschriftet.
#'   Standard: alle drei.
#' @param max_points Ganzzahl. Punkte pro Serie werden fuer die Darstellung
#'   gleichmaessig auf hoechstens diesen Wert ausgeduennt (Render-Performance);
#'   Standard 6000 zeigt 45 Jahre fluessig.
#' @param open Logisch. Datei nach dem Schreiben im Browser oeffnen?
#'   Standard: \code{interactive()}.
#' @param engine \code{"auto"} (Standard), \code{"plotly"} oder
#'   \code{"html"} (eingebauter abhaengigkeitsfreier Writer). Mit plotly wird
#'   keine Datei geschrieben; \code{file} und \code{open} wirken dann nicht.
#' @param ... Derzeit ungenutzt.
#'
#' @return Beim HTML-Writer unsichtbar der Pfad zur erzeugten HTML-Datei; bei
#'   plotly (auch ueber \code{engine = "auto"}) sichtbar das plotly-Objekt.
#'
#' @examples
#' \dontrun{
#' r <- simulation(data, strategy, start_value = 10000)
#' plot_interactive(r)                          # Browser oeffnet Dashboard
#' plot_interactive(r, file = "backtest.html", panels = c("performance", "drawdown"))
#' }
#' @export
#' @noRd
plot_interactive <- function(x, ...) UseMethod("plot_interactive")

#' @rdname plot_interactive
#' @export
#' @noRd
plot_interactive.SimLevResult <- function(x, file = NULL,
                                          panels = c("performance", "drawdown", "weights"),
                                          max_points = 6000,
                                          open = interactive(),
                                          engine = c("auto", "plotly", "html"),
                                          ...) {
  engine <- match.arg(engine)
  panels <- match.arg(panels, c("performance", "drawdown", "weights"),
                      several.ok = TRUE)
  if (is.null(file)) file <- tempfile("simlev_dashboard_", fileext = ".html")

  if (engine == "auto") {
    engine <- if (requireNamespace("plotly", quietly = TRUE)) "plotly" else "html"
  }
  if (engine == "plotly" && !requireNamespace("plotly", quietly = TRUE)) {
    warning("plotly ist nicht installiert - nutze den eingebauten HTML-Writer.")
    engine <- "html"
  }

  dat <- .build_dashboard_data(x, max_points)

  if (engine == "plotly") {
    return(.plot_interactive_plotly(dat, panels))
  }

  html <- .build_dashboard_html(dat, panels)
  writeLines(html, file, useBytes = TRUE)
  if (isTRUE(open)) utils::browseURL(file)
  invisible(file)
}


# ── Datenaufbereitung (mit gleichmaessiger Ausduennung) ───────────────────────
.build_dashboard_data <- function(x, max_points) {
  n <- length(x$dates)
  keep <- if (n > max_points) {
    unique(c(round(seq(1L, n, length.out = max_points)), n))
  } else seq_len(n)

  assets <- names(x$report)
  totals <- lapply(x$report, function(a) a$total[keep])
  tot_sum <- Reduce(`+`, totals)
  fi <- .dashboard_returns(x)                 # Sparplan-Kennung, Einzahlungssumme (Start + Sparraten)
  invested <- fi$invested[keep]

  dd <- if (!is.null(x$drawdowns)) x$drawdowns[keep] else {
    w <- x$worth; -(cummax(w) - w) / cummax(w) * 0 + (w / cummax(w) - 1)
  }[keep]

  list(
    dates    = format(x$dates[keep], "%Y-%m-%d"),
    filled   = as.logical(x$filled[keep]),
    assets   = assets,
    worth    = x$worth[keep],
    invested = invested,
    totals   = totals,
    weights  = lapply(totals, function(t) ifelse(tot_sum > 0, 100 * t / tot_sum, 0)),
    drawdown = 100 * dd,
    stats    = x$statistics,
    cagr     = x$cagr,
    external_flows = fi$external_flows
  )
}

.num2js <- function(v) {
  s <- sprintf("%.6g", v)
  s[!is.finite(v)] <- "null"
  paste0("[", paste(s, collapse = ","), "]")
}
.chr2js <- function(v) paste0('["', paste(v, collapse = '","'), '"]')

# ── plotly-Zweig (nur wenn beim Anwender installiert) ─────────────────────────
.plot_interactive_plotly <- function(d, panels) {
  plots <- list()
  if ("performance" %in% panels) {
    p <- plotly::plot_ly(x = d$dates)
    for (a in d$assets) p <- plotly::add_lines(p, y = d$totals[[a]], name = a)
    p <- plotly::add_lines(p, y = d$worth, name = "Gesamt",
                           line = list(width = 3))
    p <- plotly::add_lines(p, y = d$invested, name = "Einzahlungen (inkl. Start, brutto)",
                           line = list(dash = "dot"))
    plots <- c(plots, list(plotly::layout(p, yaxis = list(title = "EUR"))))
  }
  if ("drawdown" %in% panels) {
    plots <- c(plots, list(plotly::plot_ly(
      x = d$dates, y = d$drawdown, type = "scatter", mode = "lines",
      fill = "tozeroy", name = "Drawdown %")))
  }
  if ("weights" %in% panels) {
    p <- plotly::plot_ly(x = d$dates)
    for (a in d$assets) {
      p <- plotly::add_lines(p, y = d$weights[[a]], name = paste0(a, " %"))
    }
    plots <- c(plots, list(p))
  }
  plotly::subplot(plots, nrows = length(plots), shareX = TRUE,
                  titleY = TRUE)
}

# ── eingebauter HTML-Writer: eigenstaendig, SVG + reines JavaScript ───────────
.build_dashboard_html <- function(d, panels) {
  pal <- c("#2C7FB8", "#D95F02", "#1B9E77", "#7570B3", "#E7298A",
           "#66A61E", "#E6AB02", "#A6761D")

  series_perf <- c(
    lapply(seq_along(d$assets), function(i) list(
      name = d$assets[i], col = pal[(i - 1) %% length(pal) + 1],
      vals = d$totals[[i]], width = 1.4)),
    list(list(name = "Gesamt", col = "#111111", vals = d$worth, width = 2.4)),
    list(list(name = "Einzahlungen (inkl. Start, brutto)", col = "#888888", vals = d$invested,
              width = 1.4, dash = TRUE)))

  series_w <- lapply(seq_along(d$assets), function(i) list(
    name = d$assets[i], col = pal[(i - 1) %% length(pal) + 1],
    vals = d$weights[[i]], width = 1.6))

  js_panel <- function(id, title, series, unit, fill_first = FALSE) {
    ser <- vapply(series, function(s) sprintf(
      '{name:"%s",col:"%s",w:%s,dash:%s,v:%s}',
      s$name, s$col, s$width %||% 1.6,
      if (isTRUE(s$dash)) "true" else "false", .num2js(s$vals)),
      character(1))
    sprintf('makePanel("%s","%s",[%s],"%s",%s);',
            id, title, paste(ser, collapse = ","), unit,
            if (fill_first) "true" else "false")
  }

  calls <- c()
  divs <- c()
  if ("performance" %in% panels) {
    divs <- c(divs, '<div class="panel" id="performance"></div>')
    calls <- c(calls, js_panel("performance", "Wertentwicklung des Depots",
                               series_perf, " EUR"))
  }
  if ("drawdown" %in% panels) {
    divs <- c(divs, '<div class="panel" id="drawdown"></div>')
    calls <- c(calls, js_panel("drawdown", if (isTRUE(d$external_flows)) "Drawdown (zeitgewichtet)" else "Drawdown",
      list(list(name = "Drawdown", col = "#C0392B", vals = d$drawdown,
                width = 1.6)), " %", fill_first = TRUE))
  }
  if ("weights" %in% panels) {
    divs <- c(divs, '<div class="panel" id="weights"></div>')
    calls <- c(calls, js_panel("weights", "Asset-Gewichte", series_w, " %"))
  }

  # Mit Sparplan: CAGR geldgewichtet (XIRR), Drawdown zeitgewichtet (wie x$statistics)
  stat_line <- if (!is.null(d$stats)) sprintf(
    if (isTRUE(d$external_flows)) "CAGR (geldgewichtet) %.2f%% &middot; Sharpe %.2f &middot; Max. Drawdown (zeitgewichtet) %.1f%%"
    else "CAGR %.2f%% &middot; Sharpe %.2f &middot; Max. Drawdown %.1f%%",
    100 * (d$cagr %||% NA), d$stats$sharpe %||% NA,   # R1-20: CAGR steht in x$cagr, Sharpe in statistics$sharpe
    100 * (d$stats$max_drawdown %||% NA)) else ""

  paste0('<!DOCTYPE html><html lang="de"><head><meta charset="utf-8">
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
<div class="sub">', stat_line, ' &middot; Hover f&uuml;r Details, Legende klickbar</div>
', paste(divs, collapse = "\n"), '
<div class="tip" id="tip"></div>
<script>
"use strict";
var DATES=', .chr2js(d$dates), ';
var FILLED=', .num2js(as.numeric(d$filled)), ';
var N=DATES.length, tip=document.getElementById("tip"), PANELS=[];
function fmt(v,u){return v==null?"&ndash;":(Math.abs(v)>=1000?v.toLocaleString("de-DE",{maximumFractionDigits:0}):v.toLocaleString("de-DE",{maximumFractionDigits:2}))+u}
function makePanel(id,title,series,unit,fillFirst){
 var host=document.getElementById(id); if(!host)return;
 host.innerHTML=\'<div class="ptitle">\'+title+\'</div><div class="legend"></div>\';
 var leg=host.querySelector(".legend");
 var svg=document.createElementNS("http://www.w3.org/2000/svg","svg");
 host.appendChild(svg);
 var P={id:id,series:series,unit:unit,fillFirst:fillFirst,svg:svg,on:series.map(function(){return true})};
 series.forEach(function(s,i){
   var el=document.createElement("span");
   el.innerHTML=\'<i style="background:\'+s.col+\'"></i>\'+s.name;
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
 var g=\'<line class="xh" x1="0" x2="0" y1="\'+T+\'" y2="\'+(H-B)+\'" stroke="#999" stroke-dasharray="3,3" opacity="0"/>\';
 for(var t=0;t<=4;t++){var v=lo+(hi-lo)*t/4,y=Y(v);
   g+=\'<line x1="\'+L+\'" x2="\'+(W-R)+\'" y1="\'+y+\'" y2="\'+y+\'" stroke="#eee"/>\'+
      \'<text class="axis" x="\'+(L-6)+\'" y="\'+(y+3)+\'" text-anchor="end">\'+fmt(v,"")+\'</text>\'}
 for(var q=0;q<=5;q++){var k=Math.round((N-1)*q/5);
   g+=\'<text class="axis" x="\'+X(k)+\'" y="\'+(H-8)+\'" text-anchor="middle">\'+DATES[k].slice(0,7)+\'</text>\'}
 P.series.forEach(function(s,i){if(!P.on[i])return;
  var dstr="",first=true;
  for(var k=0;k<N;k++){var v=s.v[k];if(v==null){first=true;continue}
    dstr+=(first?"M":"L")+X(k).toFixed(1)+" "+Y(v).toFixed(1);first=false}
  if(P.fillFirst&&i===0){
    var area=dstr+"L"+X(N-1).toFixed(1)+" "+Y(Math.min(0,P.hi)).toFixed(1)+
             "L"+X(0).toFixed(1)+" "+Y(Math.min(0,P.hi)).toFixed(1)+"Z";
    g+=\'<path d="\'+area+\'" fill="\'+s.col+\'" opacity="0.18"/>\'}
  g+=\'<path d="\'+dstr+\'" fill="none" stroke="\'+s.col+\'" stroke-width="\'+s.w+\'"\'+
     (s.dash?\' stroke-dasharray="5,4"\':"")+\'/>\'});
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
     h+=\'<br><i style="display:inline-block;width:10px;height:10px;border-radius:2px;background:\'+
        s.col+\';margin-right:5px"></i>\'+s.name+": <b>"+fmt(s.v[k],P.unit)+"</b>"})});
 tip.innerHTML=h;tip.style.display="block";
 tip.style.left=Math.min(e.clientX+16,window.innerWidth-360)+"px";
 tip.style.top=(e.clientY+14)+"px";
}
', paste(calls, collapse = "\n"), '
window.addEventListener("resize",function(){PANELS.forEach(draw)});
</script></body></html>')
}

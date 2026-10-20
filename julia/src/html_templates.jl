# HTML-/JavaScript-Vorlagen des interaktiven Dashboards (zeichengleich zum R-Paket 0.5.0,
# plot_interactive.R; erzeugt aus den Vorlagen der Python-Fassung).

const _HTML_HEAD = "<!DOCTYPE html><html lang=\"de\"><head><meta charset=\"utf-8\">
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
<div class=\"sub\">"

const _HTML_SUB = " &middot; Hover f&uuml;r Details, Legende klickbar</div>
"

const _HTML_MID1 = "
<div class=\"tip\" id=\"tip\"></div>
<script>
\"use strict\";
var DATES="

const _HTML_SCRIPT = ";
var N=DATES.length, tip=document.getElementById(\"tip\"), PANELS=[];
function fmt(v,u){return v==null?\"&ndash;\":(Math.abs(v)>=1000?v.toLocaleString(\"de-DE\",{maximumFractionDigits:0}):v.toLocaleString(\"de-DE\",{maximumFractionDigits:2}))+u}
function makePanel(id,title,series,unit,fillFirst){
 var host=document.getElementById(id); if(!host)return;
 host.innerHTML='<div class=\"ptitle\">'+title+'</div><div class=\"legend\"></div>';
 var leg=host.querySelector(\".legend\");
 var svg=document.createElementNS(\"http://www.w3.org/2000/svg\",\"svg\");
 host.appendChild(svg);
 var P={id:id,series:series,unit:unit,fillFirst:fillFirst,svg:svg,on:series.map(function(){return true})};
 series.forEach(function(s,i){
   var el=document.createElement(\"span\");
   el.innerHTML='<i style=\"background:'+s.col+'\"></i>'+s.name;
   el.onclick=function(){P.on[i]=!P.on[i];el.classList.toggle(\"off\");draw(P)};
   leg.appendChild(el);
 });
 PANELS.push(P); draw(P);
 svg.addEventListener(\"mousemove\",function(e){hover(e,P)});
 svg.addEventListener(\"mouseleave\",function(){tip.style.display=\"none\";
   PANELS.forEach(function(q){var c=q.svg.querySelector(\".xh\");if(c)c.setAttribute(\"opacity\",0)})});
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
 var g='<line class=\"xh\" x1=\"0\" x2=\"0\" y1=\"'+T+'\" y2=\"'+(H-B)+'\" stroke=\"#999\" stroke-dasharray=\"3,3\" opacity=\"0\"/>';
 for(var t=0;t<=4;t++){var v=lo+(hi-lo)*t/4,y=Y(v);
   g+='<line x1=\"'+L+'\" x2=\"'+(W-R)+'\" y1=\"'+y+'\" y2=\"'+y+'\" stroke=\"#eee\"/>'+
      '<text class=\"axis\" x=\"'+(L-6)+'\" y=\"'+(y+3)+'\" text-anchor=\"end\">'+fmt(v,\"\")+'</text>'}
 for(var q=0;q<=5;q++){var k=Math.round((N-1)*q/5);
   g+='<text class=\"axis\" x=\"'+X(k)+'\" y=\"'+(H-8)+'\" text-anchor=\"middle\">'+DATES[k].slice(0,7)+'</text>'}
 P.series.forEach(function(s,i){if(!P.on[i])return;
  var dstr=\"\",first=true;
  for(var k=0;k<N;k++){var v=s.v[k];if(v==null){first=true;continue}
    dstr+=(first?\"M\":\"L\")+X(k).toFixed(1)+\" \"+Y(v).toFixed(1);first=false}
  if(P.fillFirst&&i===0){
    var area=dstr+\"L\"+X(N-1).toFixed(1)+\" \"+Y(Math.min(0,P.hi)).toFixed(1)+
             \"L\"+X(0).toFixed(1)+\" \"+Y(Math.min(0,P.hi)).toFixed(1)+\"Z\";
    g+='<path d=\"'+area+'\" fill=\"'+s.col+'\" opacity=\"0.18\"/>'}
  g+='<path d=\"'+dstr+'\" fill=\"none\" stroke=\"'+s.col+'\" stroke-width=\"'+s.w+'\"'+
     (s.dash?' stroke-dasharray=\"5,4\"':\"\")+'/>'});
 P.svg.setAttribute(\"viewBox\",\"0 0 \"+W+\" \"+H);
 P.svg.innerHTML=g;
}
function hover(e,src){
 var r=src.svg.getBoundingClientRect(),g=src.geo;
 var frac=(e.clientX-r.left-g.L)/(r.width-g.L-g.R);
 var k=Math.max(0,Math.min(N-1,Math.round(frac*(N-1))));
 PANELS.forEach(function(P){
   var gg=P.geo,x=P.X(k),c=P.svg.querySelector(\".xh\");
   if(c){c.setAttribute(\"x1\",x);c.setAttribute(\"x2\",x);c.setAttribute(\"opacity\",1)}});
 var h=\"<b>\"+DATES[k]+\"</b>\"+(FILLED[k]?\" (aufgef&uuml;llt)\":\"\");
 PANELS.forEach(function(P){
   P.series.forEach(function(s,i){if(!P.on[i])return;
     h+='<br><i style=\"display:inline-block;width:10px;height:10px;border-radius:2px;background:'+
        s.col+';margin-right:5px\"></i>'+s.name+\": <b>\"+fmt(s.v[k],P.unit)+\"</b>\"})});
 tip.innerHTML=h;tip.style.display=\"block\";
 tip.style.left=Math.min(e.clientX+16,window.innerWidth-360)+\"px\";
 tip.style.top=(e.clientY+14)+\"px\";
}
"

const _HTML_TAIL = "
window.addEventListener(\"resize\",function(){PANELS.forEach(draw)});
</script></body></html>"

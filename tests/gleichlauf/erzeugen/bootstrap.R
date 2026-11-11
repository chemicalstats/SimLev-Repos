# tests/gleichlauf/erzeugen/bootstrap.R – Bereich bootstrap als Szenarien und Tabellen (seit 1.4.2; bis 1.4.1 Einzelfälle je Modul und Funktion).
# Bootstrap der Pfade (Verfahren, Hilfsreihen, Hebel-ETFs, Regimemodelle, effektive Stichprobe) und Studien
# (bootstrap_study, Kennzahlen, Wahrscheinlichkeiten), Eingabeprüfungen.
#   gleichlauf  Szenarien: je Szenario ein Aufruf bzw. eine kurze Aufrufkette, die mehrere Ergebnisse zugleich prüft
#               (Teile; Name = bisherige Fallkennung). Feld note: "prüft: …"
#   fehler      je Funktion eine Tabelle "Eingabe -> Meldung" (jede Zeile ein eigener Aufruf)
#   ausgabe     print()/summary() als Tabelle
# Herkunft der Erwartung: R. Daten und Hilfen wie in tests/werkzeuge/breite/bootstrap.R (Breitenprüfung mit allen bisherigen Fällen).
# Aufruf (Repo-Wurzel): LC_ALL=C.UTF-8 R_LIBS=<R-Bibliothek mit SimLev> Rscript tests/gleichlauf/erzeugen/bootstrap.R
# Ausgabe tests/{gleichlauf,fehler,ausgabe}/faelle/bootstrap.jsonl.gz (Format: ref_tools.R, Szenarien: szenario_tools.R).
source("tests/gleichlauf/erzeugen/ref_tools.R"); source("tests/gleichlauf/erzeugen/szenario_tools.R")
ref_bereich("bootstrap")
EIN <- list()   # Eingaben je bisherigem Fall (Momentaufnahme an der Stelle, an der der Fall im alten Generator stand)

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# Modul bootstrap
# ════════════════════════════════════════════════════════════════════════════════════════════════════
P <- "from simlev.bootstrap import *\nfrom simlev.withdrawal import *\nimport simlev.bootstrap as B\n"
CFG_R <- "cfg <- bootstrap_config(c(us = 'us', eu = 'eu'), regime_index = 'us', aux = c(rate = 'rate'),
  letfs = list(list(base = 'eu', leverage = 2, finance = 'rate', expense = 0.5), list(base = 'us', leverage = -1, finance = 'rate', expense = 0.6)))\n"
CFG_P <- "cfg = bootstrap_config({'us': 'us', 'eu': 'eu'}, regime_index='us', aux={'rate': 'rate'},
  letfs=[{'base': 'eu', 'leverage': 2, 'finance': 'rate', 'expense': 0.5}, {'base': 'us', 'leverage': -1, 'finance': 'rate', 'expense': 0.6}])\n"
JP <- "using SimLev.Bootstrap, SimLev.Withdrawal\nconst B = SimLev.Bootstrap\n"
CFG_J <- 'cfg = bootstrap_config((us = "us", eu = "eu"), regime_index = "us", aux = (rate = "rate",),
  letfs = [(base = "eu", leverage = 2, finance = "rate", expense = 0.5), (base = "us", leverage = -1, finance = "rate", expense = 0.6)])\n'
# ── Daten ───────────────────────────────────────────────────────────────────
set.seed(5); n <- 400
us <- 1 + rnorm(n, 3e-4, 0.011)
d <- data.frame(us = us, eu = us * (1 + rnorm(n, 0, 0.004)), rate = 2 + cumsum(rnorm(n, 0, 0.005)))
set.seed(21); n2 <- 300
dp <- data.frame(us = 100 * cumprod(c(1, 1 + rnorm(n2, 3e-4, 0.01))), cpi = 100 * 1.02^((0:n2) / 365),
                 infl = 2, zins = 2 + sin((0:n2) / 40))
set.seed(3); dv <- data.frame(us = 1 + rnorm(200, 0, 0.3)); dv$us[dv$us <= 0.05] <- 0.05
I <- list(d = d, dp = dp, dv = dv)
EIN[["bootstrap/cfg_auxtype_empty"]] <- list()
EIN[["bootstrap/cfg_negfin"]] <- list()
errs <- list(
  unnamed = c("bootstrap_config(c('a'))", "bootstrap_config(['a'])",
    'bootstrap_config(["a"])'),
  emptyname = c("bootstrap_config(c(a = 'a', 'b'))", "bootstrap_config(pd.Series(['a', 'b'], index=['a', '']))",
    'bootstrap_config(SL.RVector(["a", "b"]; names = ["a", ""]))'),
  dupidx = c("bootstrap_config(c(a = 'a', a = 'b'))", "bootstrap_config(pd.Series(['a', 'b'], index=['a', 'a']))",
    'bootstrap_config(["a" => "a", "a" => "b"])'),
  auxunnamed = c("bootstrap_config(c(a = 'a'), aux = 'x')", "bootstrap_config({'a': 'a'}, aux='x')",
    'bootstrap_config((a = "a",), aux = "x")'),
  base_missing = c("bootstrap_config(c(a = 'a'), letfs = list(list(leverage = 2)))", "bootstrap_config({'a': 'a'}, letfs=[{'leverage': 2}])",
    'bootstrap_config((a = "a",), letfs = [(leverage = 2,)])'),
  base_bad = c("bootstrap_config(c(a = 'a'), letfs = list(list(base = 'x')))", "bootstrap_config({'a': 'a'}, letfs=[{'base': 'x'}])",
    'bootstrap_config((a = "a",), letfs = [(base = "x",)])'),
  lev0 = c("bootstrap_config(c(a = 'a'), letfs = list(list(base = 'a', leverage = 0)))", "bootstrap_config({'a': 'a'}, letfs=[{'base': 'a', 'leverage': 0}])",
    'bootstrap_config((a = "a",), letfs = [(base = "a", leverage = 0)])'),
  fin_bad = c("bootstrap_config(c(a = 'a'), letfs = list(list(base = 'a', finance = 'rate')))", "bootstrap_config({'a': 'a'}, letfs=[{'base': 'a', 'finance': 'rate'}])",
    'bootstrap_config((a = "a",), letfs = [(base = "a", finance = "rate")])'),
  exp_neg = c("bootstrap_config(c(a = 'a'), letfs = list(list(base = 'a', expense = -1)))", "bootstrap_config({'a': 'a'}, letfs=[{'base': 'a', 'expense': -1}])",
    'bootstrap_config((a = "a",), letfs = [(base = "a", expense = -1)])'),
  days_bad = c("bootstrap_config(c(a = 'a'), letfs = list(list(base = 'a', days = 'tage')))", "bootstrap_config({'a': 'a'}, letfs=[{'base': 'a', 'days': 'tage'}])",
    'bootstrap_config((a = "a",), letfs = [(base = "a", days = "tage")])'),
  fin_level = c("bootstrap_config(c(us = 'us'), aux = c(z = 'z'), aux_type = c(z = 'level'), letfs = list(list(base = 'us', finance = 'z')))",
                "bootstrap_config({'us': 'us'}, aux={'z': 'z'}, aux_type={'z': 'level'}, letfs=[{'base': 'us', 'finance': 'z'}])",
    'bootstrap_config((us = "us",), aux = (z = "z",), aux_type = (z = "level",), letfs = [(base = "us", finance = "z")])'),
  days_level = c("bootstrap_config(c(us = 'us'), aux = c(z = 'z'), aux_type = c(z = 'level'), letfs = list(list(base = 'us', days = 'z')))",
                 "bootstrap_config({'us': 'us'}, aux={'z': 'z'}, aux_type={'z': 'level'}, letfs=[{'base': 'us', 'days': 'z'}])",
    'bootstrap_config((us = "us",), aux = (z = "z",), aux_type = (z = "level",), letfs = [(base = "us", days = "z")])'),
  dupnames = c("bootstrap_config(c(a = 'a'), aux = c(a_l2 = 'x'), letfs = list(list(base = 'a')))", "bootstrap_config({'a': 'a'}, aux={'a_l2': 'x'}, letfs=[{'base': 'a'}])",
    'bootstrap_config((a = "a",), aux = (a_l2 = "x",), letfs = [(base = "a",)])'),
  regime_bad = c("bootstrap_config(c(a = 'a'), regime_index = 'b')", "bootstrap_config({'a': 'a'}, regime_index='b')",
    'bootstrap_config((a = "a",), regime_index = "b")'),
  at_notaux = c("bootstrap_config(c(us = 'us'), aux = c(cpi = 'cpi'), aux_type = c(cp = 'level'))", "bootstrap_config({'us': 'us'}, aux={'cpi': 'cpi'}, aux_type={'cp': 'level'})",
    'bootstrap_config((us = "us",), aux = (cpi = "cpi",), aux_type = (cp = "level",))'),
  at_noaux = c("bootstrap_config(c(us = 'us'), aux_type = c(cpi = 'level', x = 'rate'))", "bootstrap_config({'us': 'us'}, aux_type={'cpi': 'level', 'x': 'rate'})",
    'bootstrap_config((us = "us",), aux_type = (cpi = "level", x = "rate"))'),
  at_value = c("bootstrap_config(c(us = 'us'), aux = c(cpi = 'cpi'), aux_type = c(cpi = 'niveau'))", "bootstrap_config({'us': 'us'}, aux={'cpi': 'cpi'}, aux_type={'cpi': 'niveau'})",
    'bootstrap_config((us = "us",), aux = (cpi = "cpi",), aux_type = (cpi = "niveau",))'),
  at_unnamed = c("bootstrap_config(c(us = 'us'), aux = c(cpi = 'cpi'), aux_type = 'level')", "bootstrap_config({'us': 'us'}, aux={'cpi': 'cpi'}, aux_type='level')",
    'bootstrap_config((us = "us",), aux = (cpi = "cpi",), aux_type = "level")'),
  at_dup = c("bootstrap_config(c(us = 'us'), aux = c(cpi = 'cpi'), aux_type = c(cpi = 'level', cpi = 'rate'))", "bootstrap_config({'us': 'us'}, aux={'cpi': 'cpi'}, aux_type=pd.Series(['level', 'rate'], index=['cpi', 'cpi']))",
    'bootstrap_config((us = "us",), aux = (cpi = "cpi",), aux_type = ["cpi" => "level", "cpi" => "rate"])'),
  cross_bad = c("bootstrap_config(c(us = 'us'), cross = 'x')", "bootstrap_config({'us': 'us'}, cross='x')",
    'bootstrap_config((us = "us",), cross = "x")'))
for (k in names(errs)) EIN[[paste0("bootstrap/", paste0("cfg_err_", k))]] <- list()
# ── bootstrap_block_length ────────────────────────────────────────────────────────────
set.seed(1); xa <- as.numeric(arima.sim(list(ar = 0.6), 1500)); xi <- rnorm(800)
Ib <- list(xa = xa, xi = xi, M = cbind(a = xa[1:800], b = xi))
EIN[["bootstrap/bl_const"]] <- list()
for (m in c("raw", "stationary", "wild", "regime", "evt", "tails", "reset", "garch", "gjr_garch")) EIN[[paste0("bootstrap/", 
    m)]] <- I
EIN[["bootstrap/bs_garch_const"]] <- list()
# MS-GARCH-Verfahren mit Parametern (eigene Schätzung .ms_garch_fit), Fehlerwege der Prüfung
MS <- list(
  bs_ms_ar = c("ms_ar_garch_m", "list()", "{}", "(;)"),
  bs_ms_sgarch = c("ms_garch", "list(ms_garch_model = 'sGARCH')", "{'ms_garch_model': 'sGARCH'}", '(ms_garch_model = "sGARCH",)'),
  bs_ms_K3 = c("ms_garch", "list(ms_n_regimes = 3)", "{'ms_n_regimes': 3}", "(ms_n_regimes = 3,)"),
  bs_tvtp_K3 = c("tvtp_ms_garch", "list(tvtp_n_regimes = 3)", "{'tvtp_n_regimes': 3}", "(tvtp_n_regimes = 3,)"),
  bs_ms_err_egarch = c("ms_garch", "list(ms_garch_model = 'eGARCH')", "{'ms_garch_model': 'eGARCH'}", '(ms_garch_model = "eGARCH",)'),
  bs_ms_err_K1 = c("tvtp_ms_garch", "list(tvtp_n_regimes = 1)", "{'tvtp_n_regimes': 1}", "(tvtp_n_regimes = 1,)"))
for (k in names(MS)) {
    a <- MS[[k]]
    EIN[[paste0("bootstrap/", k)]] <- I
}
# Zusatzreihen als Niveau / Rate, Kursniveaus, Attribut aux_level
CF3_R <- "cfg3 <- bootstrap_config(c(us = 'us'), aux = c(cpi = 'cpi', zins = 'zins', infl = 'infl'), input = 'prices', aux_type = c(cpi = 'level', zins = 'rate'), letfs = list(list(base = 'us', leverage = 3, finance = 'zins', spread = 0.5)))\n"
CF3_J <- 'cfg3 = bootstrap_config((us = "us",), aux = (cpi = "cpi", zins = "zins", infl = "infl"), input = "prices", aux_type = (cpi = "level", zins = "rate"), letfs = [(base = "us", leverage = 3, finance = "zins", spread = 0.5)])\n'
CF3_P <- "cfg3 = bootstrap_config({'us': 'us'}, aux={'cpi': 'cpi', 'zins': 'zins', 'infl': 'infl'}, input='prices', aux_type={'cpi': 'level', 'zins': 'rate'}, letfs=[{'base': 'us', 'leverage': 3, 'finance': 'zins', 'spread': 0.5}])\n"
for (m in c("stationary", "wild", "evt", "garch", "block")) {
    EIN[[paste0("bootstrap/", paste0("aux_level_", m))]] <- I
}
EIN[["bootstrap/ess_internal_ms"]] <- list()
EIN[["bootstrap/calc_ess"]] <- list()
EIN[["bootstrap/main_stream"]] <- list()
# Fehler und Warnungen
E <- list(
  method = c("bootstrap(d, cfg, 'foo', n = 1)", "bootstrap(d, cfg, method='foo', n=1)",
    'bootstrap(d, cfg, "foo"; n = 1)'),
  n0 = c("bootstrap(d, cfg, n = 0)", "bootstrap(d, cfg, n=0)",
    'bootstrap(d, cfg; n = 0)'),
  nchr = c("bootstrap(d, cfg, n = 'a')", "bootstrap(d, cfg, n='a')",
    'bootstrap(d, cfg; n = "a")'),
  pl = c("bootstrap(d, cfg, n = 1, path_length = 2.5)", "bootstrap(d, cfg, n=1, path_length=2.5)",
    'bootstrap(d, cfg; n = 1, path_length = 2.5)'),
  pl0 = c("bootstrap(d, cfg, n = 1, path_length = 0)", "bootstrap(d, cfg, n=1, path_length=0)",
    'bootstrap(d, cfg; n = 1, path_length = 0)'),
  wildpl = c("bootstrap(d, cfg, 'wild', n = 1, path_length = 10)", "bootstrap(d, cfg, method='wild', n=1, path_length=10)",
    'bootstrap(d, cfg, "wild"; n = 1, path_length = 10)'),
  resetpl = c("bootstrap(d, cfg, 'reset', n = 1, path_length = 10)", "bootstrap(d, cfg, method='reset', n=1, path_length=10)",
    'bootstrap(d, cfg, "reset"; n = 1, path_length = 10)'),
  cfg = c("bootstrap(d, list(a = 1), n = 1)", "bootstrap(d, {'a': 1}, n=1)",
    'bootstrap(d, (a = 1,); n = 1)'),
  data = c("bootstrap(1:3, cfg, n = 1)", "bootstrap([1, 2, 3], cfg, n=1)",
    'bootstrap([1, 2, 3], cfg; n = 1)'),
  empty = c("bootstrap(d[0, ], cfg, n = 1)", "bootstrap(d.iloc[:0], cfg, n=1)",
    'bootstrap(SL.rows(d, Int[]), cfg; n = 1)'),
  col = c("bootstrap(d[, c('us', 'rate')], cfg, n = 1)", "bootstrap(d[['us', 'rate']], cfg, n=1)",
    'bootstrap(SL.RFrame("us" => d.us, "rate" => d.rate), cfg; n = 1)'),
  allna = c("dd <- d[1:5, ]; dd$us <- NA; bootstrap(dd, cfg, n = 1)", "dd = d.iloc[:5].copy(); dd['us'] = simlev._r.fmt.NA_REAL; bootstrap(dd, cfg, n=1)",
    '(dd = SL.rows(d, 1:5); dd.us .= SL.NA; bootstrap(dd, cfg; n = 1))'),
  inf = c("dd <- d[1:50, ]; dd$eu[c(7, 9)] <- Inf; dd$us[30] <- -Inf; bootstrap(dd, cfg, n = 1)", "dd = d.iloc[:50].copy(); dd.loc[[6, 8], 'eu'] = np.inf; dd.loc[29, 'us'] = -np.inf; bootstrap(dd, cfg, n=1)",
    '(dd = SL.rows(d, 1:50); dd.eu[[7, 9]] .= Inf; dd.us[30] = -Inf; bootstrap(dd, cfg; n = 1))'),
  neg = c("dd <- d[1:50, ]; dd$eu[7] <- -0.5; bootstrap(dd, cfg, n = 1)", "dd = d.iloc[:50].copy(); dd.loc[6, 'eu'] = -0.5; bootstrap(dd, cfg, n=1)",
    '(dd = SL.rows(d, 1:50); dd.eu[7] = -0.5; bootstrap(dd, cfg; n = 1))'),
  L = c("bootstrap(d, cfg, 'stationary', n = 1, params = list(L = 0.5))", "bootstrap(d, cfg, method='stationary', n=1, params={'L': 0.5})",
    'bootstrap(d, cfg, "stationary"; n = 1, params = (L = 0.5,))'),
  Lvec = c("bootstrap(d, cfg, 'stationary', n = 1, params = list(L = c(5, 10)))", "bootstrap(d, cfg, method='stationary', n=1, params={'L': [5, 10]})",
    'bootstrap(d, cfg, "stationary"; n = 1, params = (L = [5, 10],))'),
  bl = c("bootstrap(d, cfg, 'block', n = 1, params = list(block_length = 400))", "bootstrap(d, cfg, method='block', n=1, params={'block_length': 400})",
    'bootstrap(d, cfg, "block"; n = 1, params = (block_length = 400,))'),
  blc = c("bootstrap(d, cfg, 'circular', n = 1, params = list(block_length = 2.5))", "bootstrap(d, cfg, method='circular', n=1, params={'block_length': 2.5})",
    'bootstrap(d, cfg, "circular"; n = 1, params = (block_length = 2.5,))'),
  wt = c("bootstrap(d, cfg, 'wild', n = 1, params = list(wild_type = 3))", "bootstrap(d, cfg, method='wild', n=1, params={'wild_type': 3})",
    'bootstrap(d, cfg, "wild"; n = 1, params = (wild_type = 3,))'),
  pb = c("bootstrap(d, cfg, 'reset', n = 1, params = list(p_break = 1.5))", "bootstrap(d, cfg, method='reset', n=1, params={'p_break': 1.5})",
    'bootstrap(d, cfg, "reset"; n = 1, params = (p_break = 1.5,))'))
for (k in names(E)) EIN[[paste0("bootstrap/", paste0("bs_err_", k))]] <- I
# seit 1.0.0: Daten im Generator erzeugt und als Eingabe gespeichert (die Fallcodes ziehen nicht mehr mit R's Zufall bzw. RNG)
set.seed(8); xh <- 1 + c(rnorm(380, 0, 0.01), -rexp(20, 10))
# ── bootstrap_validate ─────────────────────────────────────────────────────
VB_R <- "b <- bootstrap(d, bootstrap_config(c(us = 'us')), 'stationary', n = 4, params = list(L = 20), seed = 1, progress = FALSE, path_length = 20)\n"
VB_P <- "b = bootstrap(d, bootstrap_config({'us': 'us'}), method='stationary', n=4, params={'L': 20}, seed=1, progress=False, path_length=20)\n"
VB_J <- 'b = bootstrap(d, bootstrap_config((us = "us",)), "stationary"; n = 4, params = (L = 20,), seed = 1, progress = false, path_length = 20)\n'
EIN[["bootstrap/vb_err_class"]] <- list()
# ── bootstrap_data ─────────────────────────────────────────────────────────
BD_R <- paste0(CFG_R, "b <- bootstrap(d, cfg, 'stationary', n = 2, params = list(L = 20), seed = 1, progress = FALSE, path_length = 8)\n")
BD_P <- paste0(CFG_P, "b = bootstrap(d, cfg, method='stationary', n=2, params={'L': 20}, seed=1, progress=False, path_length=8)\n")
BD_J <- paste0(CFG_J, 'b = bootstrap(d, cfg, "stationary"; n = 2, params = (L = 20,), seed = 1, progress = false, path_length = 8)\n')
EIN[["bootstrap/bd_err_matrix"]] <- list()
# ── wquantile ──────────────────────────────────────────────────────────────
set.seed(5); wx <- rnorm(40); ww <- runif(40)
Iw <- list(wx = wx, ww = ww)
# ── simulation-basierte Teile: bootstrap_study_metrics, bootstrap_study, probability ──
set.seed(1); ns <- 365   # bis 1.4.1 ns <- 2 * 365 (kürzer, Abdeckung gleich)
ds <- data.frame(date = seq.Date(as.Date("2015-01-01"), by = "day", length.out = ns))
ds$aktien <- 100 * cumprod(1 + rnorm(ns, 3e-4, 0.01)); ds$zins <- 2
Is <- c(I, list(ds = ds))
STR_R <- "cfgs <- bootstrap_config(c(akt = 'aktien'), aux = c(zins = 'zins'), input = 'prices', letfs = list(list(base = 'akt', leverage = 2, finance = 'zins', expense = 0.6)))
sma <- function(df, k = 30) { s <- stats::filter(df$akt_l2, rep(1 / k, k), sides = 1); list(buy = df$akt_l2 >= s, sell = df$akt_l2 < s) }
strats <- list(bnh = create_strategy(akt_l2 = asset_config('etf', 'bnh', partial_exemption = 30, spread = 0.1)),
  sma = list(strategy = create_strategy(letf = asset_config('etf', 'signal', partial_exemption = 30, signal_buy = 'buy', signal_sell = 'sell', spread = 0.1)), signal = sma, map = c(letf = 'akt_l2')))\n"
STR_P <- "cfgs = bootstrap_config({'akt': 'aktien'}, aux={'zins': 'zins'}, input='prices', letfs=[{'base': 'akt', 'leverage': 2, 'finance': 'zins', 'expense': 0.6}])
def _filt(x, k):
    x = np.asarray(x, dtype=float); f = 1.0 / k; out = np.full(len(x), simlev._r.fmt.NA_REAL)
    for i in range(k - 1, len(x)):
        z = 0.0
        for j in range(k):
            z += f * x[i - j]
        out[i] = z
    return out
def sma(df, k=30):
    s = _filt(df['akt_l2'], k); v = df['akt_l2'].to_numpy()
    with np.errstate(invalid='ignore'):
        return {'buy': v >= s, 'sell': v < s}
strats = {'bnh': simlev.create_strategy(akt_l2=simlev.asset_config(asset_class='etf', trading='bnh', partial_exemption=30, spread=0.1)),
  'sma': {'strategy': simlev.create_strategy(letf=simlev.asset_config(asset_class='etf', trading='signal', partial_exemption=30, signal_buy='buy', signal_sell='sell', spread=0.1)), 'signal': sma, 'map': {'letf': 'akt_l2'}}}\n"
STR_J <- 'cfgs = bootstrap_config((akt = "aktien",), aux = (zins = "zins",), input = "prices", letfs = [(base = "akt", leverage = 2, finance = "zins", expense = 0.6)])
function sma(df; k = 30)
    x = df["akt_l2"]; s = fill(SL.NA, length(x))
    for i in k:length(x)
        z = 0.0
        for j in 0:k-1
            z += (1 / k) * x[i - j]
        end
        s[i] = z
    end
    (buy = x .>= s, sell = x .< s)
end
strats = (bnh = create_strategy(akt_l2 = asset_config("etf", "bnh", partial_exemption = 30, spread = 0.1)),
  sma = (strategy = create_strategy(letf = asset_config("etf", "signal", partial_exemption = 30, signal_buy = "buy", signal_sell = "sell", spread = 0.1)), signal = sma, map = (letf = "akt_l2",)))
'
SE <- list(
  nostrat = c("bootstrap_study(ds, cfgs, n = 2)", "bootstrap_study(ds, cfgs, n=2)",
    'bootstrap_study(ds, cfgs; n = 2)'),
  unnamed = c("bootstrap_study(ds, cfgs, n = 2, strategies = list(strats$bnh))", "bootstrap_study(ds, cfgs, n=2, strategies=[strats['bnh']])",
    'bootstrap_study(ds, cfgs; n = 2, strategies = [strats.bnh])'),
  bench = c("bootstrap_study(ds, cfgs, n = 2, strategies = strats, benchmark = 'x')", "bootstrap_study(ds, cfgs, n=2, strategies=strats, benchmark='x')",
    'bootstrap_study(ds, cfgs; n = 2, strategies = strats, benchmark = "x")'),
  keepaux = c("bootstrap_study(ds, cfgs, n = 2, strategies = strats, keep_aux = 'cpi')", "bootstrap_study(ds, cfgs, n=2, strategies=strats, keep_aux='cpi')",
    'bootstrap_study(ds, cfgs; n = 2, strategies = strats, keep_aux = "cpi")'),
  burnin = c("bootstrap_study(ds, cfgs, n = 2, strategies = strats, path_length = 50, burn_in = 50)", "bootstrap_study(ds, cfgs, n=2, strategies=strats, path_length=50, burn_in=50)",
    'bootstrap_study(ds, cfgs; n = 2, strategies = strats, path_length = 50, burn_in = 50)'),
  dates = c("bootstrap_study(ds, cfgs, n = 2, strategies = strats, path_length = 50, dates = as.Date('2001-01-01') + 0:10)", "bootstrap_study(ds, cfgs, n=2, strategies=strats, path_length=50, dates=np.datetime64('2001-01-01') + np.arange(11))",
    'bootstrap_study(ds, cfgs; n = 2, strategies = strats, path_length = 50, dates = Date(2001, 1, 1) .+ Day.(0:10))'),
  short = c("bootstrap_study(ds, cfgs, n = 2, strategies = strats, path_length = 300, keep_returns = 'year')", "bootstrap_study(ds, cfgs, n=2, strategies=strats, path_length=300, keep_returns='year')",
    'bootstrap_study(ds, cfgs; n = 2, strategies = strats, path_length = 300, keep_returns = "year")'),
  kr = c("bootstrap_study(ds, cfgs, n = 2, strategies = strats, keep_returns = 'week')", "bootstrap_study(ds, cfgs, n=2, strategies=strats, keep_returns='week')",
    'bootstrap_study(ds, cfgs; n = 2, strategies = strats, keep_returns = "week")'))
for (k in names(SE)) EIN[[paste0("bootstrap/", paste0("study_err_", k))]] <- Is
EIN[["bootstrap/prob_err"]] <- list()
# bootstrap_probability: Bedingungen in R-Syntax (gemeinsamer Auswerter, Modul rexpr) auf einer festen Ergebnistabelle
set.seed(11)
PT <- data.frame(strategy = rep(c("a", "b"), each = 6), path = rep(1:6, 2), weight = c(rep(1, 6), 0.5, 1, 1.5, 2, 1, 1),
                 cagr = c(round(rnorm(11, 0.05, 0.08), 4), NA), max_drawdown = round(runif(12, 0.05, 0.6), 3),
                 sharpe = round(rnorm(12, 0.4, 0.5), 3))
PB_R <- "st <- structure(list(results = PT), class = 'SimLevBootstrapStudy'); thr <- 0.02; f2 <- function(x) x > 0.3\n"
PB_P <- "st = B.SimLevBootstrapStudy(results=PT); thr = 0.02\ndef f2(x):\n    return x > 0.3\n"
PB_J <- 'st = SL.RList(; class = ["SimLevBootstrapStudy"]); st["results"] = PT; thr = 0.02; f2(x) = x .> 0.3\n'
PBC <- list(a1 = "!cagr < 0", a2 = "cagr > 0 & !is.na(sharpe) | path %in% c(1, 2)", a3 = "path %% 2 == 0",
            a4 = "cagr > quantile(cagr, 0.5, na.rm = TRUE)", a5 = "if (mean(cagr, na.rm = TRUE) > 0) sharpe > 0 else max_drawdown < 0.3",
            a6 = "cagr >= median(cagr, na.rm = TRUE) - sd(cagr, na.rm = TRUE)", a7 = "max_drawdown <= max(max_drawdown) / 2",
            a8 = "f2(sharpe)", a9 = "cagr[path] > 0 & path >= 2L", b1 = "TRUE", b2 = "mean(cagr, na.rm = TRUE) > 0", b3 = "NA",
            b4 = "c(TRUE, FALSE)", b5 = "rep(c(TRUE, NA), 4)", b6 = "\"TRUE\"", b7 = "sharpe > 0.2 |\n cagr < 0", b8 = "max_drawdown > 0.3 # Kommentar\n")
pbq <- function(x) paste0("'", gsub("\n", "\\n", gsub("'", "\\'", x, fixed = TRUE), fixed = TRUE), "'")
pbj <- function(x) paste0('"', gsub("$", "\\$", gsub("\n", "\\n", gsub('"', '\\"', x, fixed = TRUE), fixed = TRUE), fixed = TRUE), '"')
EIN[["bootstrap/prob_rsyntax"]] <- list(PT = PT)
EIN[["bootstrap/prob_scalar"]] <- list(PT = PT)
SB_R <- "cfgb <- bootstrap_config(c(akt = 'aktien'), input = 'prices'); bnh <- create_strategy(akt = asset_config('etf', 'bnh', spread = 0.1))\n"
SB_P <- "cfgb = bootstrap_config({'akt': 'aktien'}, input='prices'); bnh = simlev.create_strategy(akt=simlev.asset_config(asset_class='etf', trading='bnh', spread=0.1))\nimport tempfile, os\n"
SB_J <- 'cfgb = bootstrap_config((akt = "aktien",), input = "prices"); bnh = create_strategy(akt = asset_config("etf", "bnh", spread = 0.1))\n'
KE <- list(neg = c("-1", "-1", "-1"), frac = c("1.5", "1.5", "1.5"), na = c("NA", "simlev._r.fmt.NA_REAL", "SL.NA"),
           chr = c("'a'", "'a'", '"a"'), vec = c("c(1, 2)", "[1, 2]", "[1, 2]"))
for (k in names(KE)) EIN[[paste0("bootstrap/", paste0("study_err_keep_", k))]] <- Is

# Vorspann je Szenario bzw. Tabellenzeile (gemeinsame Objekte des Moduls)
VOR <- list(r = r"()",
            py = r"(from simlev.bootstrap import *
from simlev.withdrawal import *
import simlev.bootstrap as B)",
            jl = r"(using SimLev.Bootstrap, SimLev.Withdrawal
const B = SimLev.Bootstrap)")

ref_init("bootstrap", gruppe = "gleichlauf")
SZ("konfiguration_hilfsreihen", "bootstrap_config mit leerem aux_type und eine alte Konfiguration ohne aux_type (Pfade mit Hilfsreihe)", vor = VOR, teile = list(
  cfg_auxtype_empty = teil(
    r"(bootstrap_config(c(us = 'us'), aux = c(cpi = 'cpi'), aux_type = character(0), cross = 'j', input = 'p'))",
    r"(result = bootstrap_config({'us': 'us'}, aux={'cpi': 'cpi'}, aux_type=[], cross='j', input='p'))",
    r"(result = bootstrap_config((us = "us",), aux = (cpi = "cpi",), aux_type = String[], cross = "j", input = "p"))", druck = TRUE, inp = ein("bootstrap/cfg_auxtype_empty", c())),
  aux_noattr_old = teil(
    r"(cfg <- bootstrap_config(c(us = 'us'), aux = c(cpi = 'cpi'), input = 'prices'); cfg$aux_type <- NULL; cfg$aux_type_set <- NULL; b <- bootstrap(dp, cfg, 'stationary', n = 2, params = list(L = 20), seed = 4, progress = FALSE); c(b$paths, lapply(b$paths, attr, 'aux_level')))",
    r"(cfg = bootstrap_config({'us': 'us'}, aux={'cpi': 'cpi'}, input='prices'); del cfg['aux_type']; del cfg['aux_type_set']; b = bootstrap(dp, cfg, method='stationary', n=2, params={'L': 20}, seed=4, progress=False); result = b['paths'] + [p.attrs['aux_level'] for p in b['paths']])",
    r"(cfg = bootstrap_config((us = "us",), aux = (cpi = "cpi",), input = "prices"); delete!(cfg, "aux_type"); delete!(cfg, "aux_type_set"); b = bootstrap(dp, cfg, "stationary"; n = 2, params = (L = 20,), seed = 4, progress = false); result = vcat(b["paths"], [p.attrs["aux_level"] for p in b["paths"]]))", inp = ein("bootstrap/aux_noattr_old", c("dp")))))
SZ("blocklaenge_schaetzen", "bootstrap_block_length für quadrierte Renditen, Matrix, kurze, konstante und trendbehaftete Reihe", vor = VOR, teile = list(
  bl_sq = teil(
    r"(bootstrap_block_length(xi, 'squared'))",
    r"(result = bootstrap_block_length(xi, transform='squared'))",
    r"(result = bootstrap_block_length(xi, "squared"))", inp = ein("bootstrap/bl_sq", c("xi"))),
  bl_mat = teil(
    r"(bootstrap_block_length(M))",
    r"(result = bootstrap_block_length(M))",
    r"(result = bootstrap_block_length(M))", inp = ein("bootstrap/bl_mat", c("M"))),
  bl_short = teil(
    r"(bootstrap_block_length(xa[1:15]))",
    r"(result = bootstrap_block_length(xa[:15]))",
    r"(result = bootstrap_block_length(xa[1:15]))", inp = ein("bootstrap/bl_short", c("xa"))),
  bl_const = teil(
    r"(bootstrap_block_length(rep(1, 50)))",
    r"(result = bootstrap_block_length(np.ones(50)))",
    r"(result = bootstrap_block_length(ones(50)))", inp = ein("bootstrap/bl_const", c())),
  bl_trend = teil(
    r"(bootstrap_block_length(cumsum(xi)))",
    r"(result = bootstrap_block_length(np.cumsum(xi)))",
    r"(result = bootstrap_block_length(SL.r_cumsum(xi)))", inp = ein("bootstrap/bl_trend", c("xi")))))
SZ("zwei_maerkte_mit_hebel_und_zins", "bootstrap() mit zwei Märkten, Regime-Index, Zinsreihe und Hebel-ETFs: Rücksetzen, circular (Blocklänge 25, Pfadlänge 600), evt mit beiden Rändern, block mit automatischer Blocklänge", vor = VOR, gemein = teil(
    r"(cfg <- bootstrap_config(c(us = 'us', eu = 'eu'), regime_index = 'us', aux = c(rate = 'rate'),
  letfs = list(list(base = 'eu', leverage = 2, finance = 'rate', expense = 0.5), list(base = 'us', leverage = -1, finance = 'rate', expense = 0.6))))",
    r"(cfg = bootstrap_config({'us': 'us', 'eu': 'eu'}, regime_index='us', aux={'rate': 'rate'},
  letfs=[{'base': 'eu', 'leverage': 2, 'finance': 'rate', 'expense': 0.5}, {'base': 'us', 'leverage': -1, 'finance': 'rate', 'expense': 0.6}]))",
    r"(cfg = bootstrap_config((us = "us", eu = "eu"), regime_index = "us", aux = (rate = "rate",),
  letfs = [(base = "eu", leverage = 2, finance = "rate", expense = 0.5), (base = "us", leverage = -1, finance = "rate", expense = 0.6)]))"), teile = list(
  bs_reset = teil(
    r"(b <- bootstrap(d, cfg, 'reset', n = 2, seed = 1, progress = FALSE); b)",
    r"(result = bootstrap(d, cfg, method='reset', n=2, seed=1, progress=False))",
    r"(result = bootstrap(d, cfg, "reset"; n = 2, seed = 1, progress = false))", druck = TRUE, inp = ein("bootstrap/bs_reset", c("d"))),
  bs_circularparamslistblocklength25pathlength600 = teil(
    r"(b <- bootstrap(d, cfg, 'circular', n = 2, seed = 1, progress = FALSE, params = list(block_length = 25), path_length = 600); b)",
    r"(result = bootstrap(d, cfg, method='circular', n=2, seed=1, progress=False, params={'block_length': 25}, path_length=600))",
    r"(result = bootstrap(d, cfg, "circular"; n = 2, seed = 1, progress = false, params = (block_length = 25,), path_length = 600))", druck = TRUE, inp = ein("bootstrap/bs_circularparamslistblocklength25pathlength600", c("d"))),
  bs_evtparamslisttailprob01bothtails = teil(
    r"(b <- bootstrap(d, cfg, 'evt', n = 2, seed = 1, progress = FALSE, params = list(tail_prob = 0.1, both_tails = FALSE)); b)",
    r"(result = bootstrap(d, cfg, method='evt', n=2, seed=1, progress=False, params={'tail_prob': 0.1, 'both_tails': False}))",
    r"(result = bootstrap(d, cfg, "evt"; n = 2, seed = 1, progress = false, params = (tail_prob = 0.1, both_tails = false)))", druck = TRUE, inp = ein("bootstrap/bs_evtparamslisttailprob01bothtails", c("d"))),
  bs_blockparamslistblocklengthautopathlength90 = teil(
    r"(b <- bootstrap(d, cfg, 'block', n = 2, seed = 1, progress = FALSE, params = list(block_length = 'auto'), path_length = 90); b)",
    r"(result = bootstrap(d, cfg, method='block', n=2, seed=1, progress=False, params={'block_length': 'auto'}, path_length=90))",
    r"(result = bootstrap(d, cfg, "block"; n = 2, seed = 1, progress = false, params = (block_length = "auto",), path_length = 90))", druck = TRUE, inp = ein("bootstrap/bs_blockparamslistblocklengthautopathlength90", c("d")))))
SZ("regimewechsel_modelle", "bootstrap() mit MS-GARCH: AR-Anteil, drei Regime, zeitvariable Übergänge (TVTP) mit drei Regimen", vor = VOR, gemein = teil(
    r"(cfg <- bootstrap_config(c(us = 'us', eu = 'eu'), regime_index = 'us', aux = c(rate = 'rate'),
  letfs = list(list(base = 'eu', leverage = 2, finance = 'rate', expense = 0.5), list(base = 'us', leverage = -1, finance = 'rate', expense = 0.6))))",
    r"(cfg = bootstrap_config({'us': 'us', 'eu': 'eu'}, regime_index='us', aux={'rate': 'rate'},
  letfs=[{'base': 'eu', 'leverage': 2, 'finance': 'rate', 'expense': 0.5}, {'base': 'us', 'leverage': -1, 'finance': 'rate', 'expense': 0.6}]))",
    r"(cfg = bootstrap_config((us = "us", eu = "eu"), regime_index = "us", aux = (rate = "rate",),
  letfs = [(base = "eu", leverage = 2, finance = "rate", expense = 0.5), (base = "us", leverage = -1, finance = "rate", expense = 0.6)]))"), teile = list(
  bs_ms_ar = teil(
    r"(bootstrap(d, cfg, 'ms_ar_garch_m', n = 1, seed = 1, params = list()))",
    r"(result = bootstrap(d, cfg, method='ms_ar_garch_m', n=1, seed=1, params={}))",
    r"(result = bootstrap(d, cfg, "ms_ar_garch_m"; n = 1, seed = 1, params = (;)))", druck = TRUE, inp = ein("bootstrap/bs_ms_ar", c("d"))),
  bs_ms_K3 = teil(
    r"(bootstrap(d, cfg, 'ms_garch', n = 1, seed = 1, params = list(ms_n_regimes = 3)))",
    r"(result = bootstrap(d, cfg, method='ms_garch', n=1, seed=1, params={'ms_n_regimes': 3}))",
    r"(result = bootstrap(d, cfg, "ms_garch"; n = 1, seed = 1, params = (ms_n_regimes = 3,)))", druck = TRUE, inp = ein("bootstrap/bs_ms_K3", c("d"))),
  bs_tvtp_K3 = teil(
    r"(bootstrap(d, cfg, 'tvtp_ms_garch', n = 1, seed = 1, params = list(tvtp_n_regimes = 3)))",
    r"(result = bootstrap(d, cfg, method='tvtp_ms_garch', n=1, seed=1, params={'tvtp_n_regimes': 3}))",
    r"(result = bootstrap(d, cfg, "tvtp_ms_garch"; n = 1, seed = 1, params = (tvtp_n_regimes = 3,)))", druck = TRUE, inp = ein("bootstrap/bs_tvtp_K3", c("d")))))
SZ("hilfsreihen_als_niveau", "Hilfsreihen als Niveau (CPI, Zins, Inflation) bei evt und garch", vor = VOR, gemein = teil(
    r"(cfg3 <- bootstrap_config(c(us = 'us'), aux = c(cpi = 'cpi', zins = 'zins', infl = 'infl'), input = 'prices', aux_type = c(cpi = 'level', zins = 'rate'), letfs = list(list(base = 'us', leverage = 3, finance = 'zins', spread = 0.5))))",
    r"(cfg3 = bootstrap_config({'us': 'us'}, aux={'cpi': 'cpi', 'zins': 'zins', 'infl': 'infl'}, input='prices', aux_type={'cpi': 'level', 'zins': 'rate'}, letfs=[{'base': 'us', 'leverage': 3, 'finance': 'zins', 'spread': 0.5}]))",
    r"(cfg3 = bootstrap_config((us = "us",), aux = (cpi = "cpi", zins = "zins", infl = "infl"), input = "prices", aux_type = (cpi = "level", zins = "rate"), letfs = [(base = "us", leverage = 3, finance = "zins", spread = 0.5)]))"), teile = list(
  aux_level_evt = teil(
    r"(b <- suppressWarnings(bootstrap(dp, cfg3, 'evt', n = 2, seed = 2, progress = FALSE, params = list(block_length = 10))); c(b$paths, lapply(b$paths, attr, 'aux_level')))",
    r"(b = bootstrap(dp, cfg3, method='evt', n=2, seed=2, progress=False, params={'block_length': 10}); result = b['paths'] + [p.attrs['aux_level'] for p in b['paths']])",
    r"(result = B._quiet(() -> (b = bootstrap(dp, cfg3, "evt"; n = 2, seed = 2, progress = false, params = (block_length = 10,)); vcat(b["paths"], [p.attrs["aux_level"] for p in b["paths"]]))))", inp = ein("bootstrap/aux_level_evt", c("dp"))),
  aux_level_garch = teil(
    r"(b <- suppressWarnings(bootstrap(dp, cfg3, 'garch', n = 2, seed = 2, progress = FALSE, params = list(block_length = 10))); c(b$paths, lapply(b$paths, attr, 'aux_level')))",
    r"(b = bootstrap(dp, cfg3, method='garch', n=2, seed=2, progress=False, params={'block_length': 10}); result = b['paths'] + [p.attrs['aux_level'] for p in b['paths']])",
    r"(result = B._quiet(() -> (b = bootstrap(dp, cfg3, "garch"; n = 2, seed = 2, progress = false, params = (block_length = 10,)); vcat(b["paths"], [p.attrs["aux_level"] for p in b["paths"]]))))", inp = ein("bootstrap/aux_level_garch", c("dp")))))
SZ("sonderfaelle_der_daten", "Knock-out des Hebel-ETF, Matrix statt Tabelle, seed = NULL (Zufallsstrom aus simlev_seed)", vor = VOR, teile = list(
  letf_knockout = teil(
    r"(dd <- d[1:200, ]; dd$us[100] <- 0.7; b <- bootstrap(dd, bootstrap_config(c(us = 'us'), letfs = list(list(base = 'us', leverage = 4, finance = 1))), 'block', params = list(block_length = 199), n = 1, seed = 2, progress = FALSE); b$paths)",
    r"(dd = d.iloc[:200].copy(); dd.loc[99, 'us'] = 0.7; b = bootstrap(dd, bootstrap_config({'us': 'us'}, letfs=[{'base': 'us', 'leverage': 4, 'finance': 1}]), method='block', params={'block_length': 199}, n=1, seed=2, progress=False); result = b['paths'])",
    r"(dd = SL.rows(d, 1:200); dd.us[100] = 0.7; b = bootstrap(dd, bootstrap_config((us = "us",), letfs = [(base = "us", leverage = 4, finance = 1)]), "block"; params = (block_length = 199,), n = 1, seed = 2, progress = false); result = b["paths"])", inp = ein("bootstrap/letf_knockout", c("d"))),
  bs_matrix_data = teil(
    r"(m <- as.matrix(d); b <- bootstrap(m, bootstrap_config(c(us = 'us'), aux = c(r = 'rate')), 'raw', n = 1, seed = 9, progress = FALSE, path_length = 6); b$paths)",
    r"(result = bootstrap(d, bootstrap_config({'us': 'us'}, aux={'r': 'rate'}), method='raw', n=1, seed=9, progress=False, path_length=6)['paths'])",
    r"(m = SL.NamedMat(hcat(d.us, d.eu, d.rate); colnames = ["us", "eu", "rate"]); result = bootstrap(m, bootstrap_config((us = "us",), aux = (r = "rate",)), "raw"; n = 1, seed = 9, progress = false, path_length = 6)["paths"])", inp = ein("bootstrap/bs_matrix_data", c("d"))),
  seed_null = teil(
    r"(simlev_seed(3); b <- bootstrap(d, bootstrap_config(c(us = 'us')), 'raw', n = 1, progress = FALSE, path_length = 5); list(b$seed, b$paths, SimLev:::.sl_runif(2)))",
    r"(simlev.simlev_seed(3); b = bootstrap(d, bootstrap_config({'us': 'us'}), method='raw', n=1, progress=False, path_length=5); result = [b['seed'], b['paths'], simlev._lib.runif(2)])",
    r"(SL.simlev_seed(3); b = bootstrap(d, bootstrap_config((us = "us",)), "raw"; n = 1, progress = false, path_length = 5); result = [b["seed"], b["paths"], SL.SLib.runif(2)])", inp = ein("bootstrap/seed_null", c("d")))))
SZ("effektive_stichprobe", "ess = TRUE bei block, wild, regime (Gitter), tails (Druck), raw und stationary; unendliche Blocklänge", vor = VOR, teile = list(
  ess_default_block = teil(
    r"(b <- bootstrap(d[1:60, ], bootstrap_config(c(us = 'us')), 'block', n = 9, ess = TRUE, seed = 2, progress = FALSE, path_length = 20); list(b$weights, b$ess_design, length(b$paths)))",
    r"(b = bootstrap(d.iloc[:60], bootstrap_config({'us': 'us'}), method='block', n=9, ess=True, seed=2, progress=False, path_length=20); result = [b['weights'], b['ess_design'], len(b['paths'])])",
    r"(b = bootstrap(SL.rows(d, 1:60), bootstrap_config((us = "us",)), "block"; n = 9, ess = true, seed = 2, progress = false, path_length = 20); result = [b["weights"], b["ess_design"], length(b["paths"])])", inp = ein("bootstrap/ess_default_block", c("d"))),
  ess_wild_group = teil(
    r"(b <- bootstrap(d, bootstrap_config(c(us = 'us')), 'wild', n = 5, ess = TRUE, seed = 3, progress = FALSE); list(b$weights, b$ess_design))",
    r"(b = bootstrap(d, bootstrap_config({'us': 'us'}), method='wild', n=5, ess=True, seed=3, progress=False); result = [b['weights'], b['ess_design']])",
    r"(b = bootstrap(d, bootstrap_config((us = "us",)), "wild"; n = 5, ess = true, seed = 3, progress = false); result = [b["weights"], b["ess_design"]])", inp = ein("bootstrap/ess_wild_group", c("d"))),
  ess_mixed_group = teil(
    r"(b <- bootstrap(d, bootstrap_config(c(us = 'us')), 'regime', n = 10, ess = TRUE, ess_grid = list(n_regimes = c(2, 3), vol_window = c(10, 20, 40)), seed = 3, progress = FALSE, path_length = 25); list(b$weights, b$ess_design, b$param_values))",
    r"(b = bootstrap(d, bootstrap_config({'us': 'us'}), method='regime', n=10, ess=True, ess_grid={'n_regimes': [2, 3], 'vol_window': [10, 20, 40]}, seed=3, progress=False, path_length=25); result = [b['weights'], b['ess_design'], b['param_values']])",
    r"(b = bootstrap(d, bootstrap_config((us = "us",)), "regime"; n = 10, ess = true, ess_grid = (n_regimes = [2, 3], vol_window = [10, 20, 40]), seed = 3, progress = false, path_length = 25); result = [b["weights"], b["ess_design"], b["param_values"]])", inp = ein("bootstrap/ess_mixed_group", c("d"))),
  ess_tails_print = teil(
    r"(bootstrap(d, bootstrap_config(c(us = 'us')), 'tails', n = 8, ess = TRUE, seed = 5, progress = FALSE, path_length = 20))",
    r"(result = bootstrap(d, bootstrap_config({'us': 'us'}), method='tails', n=8, ess=True, seed=5, progress=False, path_length=20))",
    r"(result = bootstrap(d, bootstrap_config((us = "us",)), "tails"; n = 8, ess = true, seed = 5, progress = false, path_length = 20))", druck = TRUE, inp = ein("bootstrap/ess_tails_print", c("d"))),
  ess_none = teil(
    r"(b <- bootstrap(d, bootstrap_config(c(us = 'us')), 'raw', n = 2, ess = TRUE, seed = 1, progress = FALSE, path_length = 10); list(b$ess, b$ess_design, b$paths))",
    r"(b = bootstrap(d, bootstrap_config({'us': 'us'}), method='raw', n=2, ess=True, seed=1, progress=False, path_length=10); result = [b['ess'], b['ess_design'], b['paths']])",
    r"(b = bootstrap(d, bootstrap_config((us = "us",)), "raw"; n = 2, ess = true, seed = 1, progress = false, path_length = 10); result = [b["ess"], b["ess_design"], b["paths"]])", inp = ein("bootstrap/ess_none", c("d"))),
  vb_ess = teil(
    r"(b <- bootstrap(d, bootstrap_config(c(us = 'us')), 'stationary', n = 5, ess = TRUE, ess_grid = list(L = c(5, 50)), seed = 1, progress = FALSE, path_length = 10); b$paths[[2]][3, 1] <- NaN; x <- bootstrap_validate(b, verbose = FALSE); list(x$weights, x$param_values))",
    r"(b = bootstrap(d, bootstrap_config({'us': 'us'}), method='stationary', n=5, ess=True, ess_grid={'L': [5, 50]}, seed=1, progress=False, path_length=10); b['paths'][1].iloc[2, 0] = np.nan; x = bootstrap_validate(b, verbose=False); result = [x['weights'], x['param_values']])",
    r"(b = bootstrap(d, bootstrap_config((us = "us",)), "stationary"; n = 5, ess = true, ess_grid = (L = [5, 50],), seed = 1, progress = false, path_length = 10); b["paths"][2][3, 1] = NaN; x = bootstrap_validate(b; verbose = false); result = [x["weights"], x["param_values"]])", inp = ein("bootstrap/vb_ess", c("d"))),
  vb_inf = teil(
    r"(b <- bootstrap(d, bootstrap_config(c(us = 'us')), 'stationary', n = 4, params = list(L = 20), seed = 1, progress = FALSE, path_length = 20)
b$paths[[4]][2, 1] <- Inf; bootstrap_validate(b)$weights)",
    r"(b = bootstrap(d, bootstrap_config({'us': 'us'}), method='stationary', n=4, params={'L': 20}, seed=1, progress=False, path_length=20)
b['paths'][3].iloc[1, 0] = np.inf; result = bootstrap_validate(b)['weights'])",
    r"(b = bootstrap(d, bootstrap_config((us = "us",)), "stationary"; n = 4, params = (L = 20,), seed = 1, progress = false, path_length = 20)
b["paths"][4][2, 1] = Inf; result = bootstrap_validate(b)["weights"])", inp = ein("bootstrap/vb_inf", c("d")))))
SZ("interne_hilfen", ".ess_design, .calculate_ess und der Haupt-Zufallsstrom (Zustand nach simlev_seed)", vor = VOR, teile = list(
  ess_internal_ms = teil(
    r"(SimLev:::.ess_design('ms_garch', NULL, 20L, 1000L))",
    r"(result = B._ess_design('ms_garch', None, 20, 1000))",
    r"(result = B._ess_design("ms_garch", nothing, 20, 1000))", inp = ein("bootstrap/ess_internal_ms", c())),
  calc_ess = teil(
    r"(c(SimLev:::.calculate_ess(1000, 'regime', list(n_regimes = 3), list(trans = matrix(c(.9, .1, .2, .8), 2))), SimLev:::.calculate_ess(10, 'evt', list(tail_prob = 0.6)), SimLev:::.calculate_ess(100, 'tvtp_ms_garch', list())))",
    r"(result = [B._calculate_ess(1000, 'regime', {'n_regimes': 3}, {'trans': np.array([[.9, .2], [.1, .8]])}), B._calculate_ess(10, 'evt', {'tail_prob': 0.6}), B._calculate_ess(100, 'tvtp_ms_garch', {})])",
    r"(result = [B._calculate_ess(1000, "regime", (n_regimes = 3,), (trans = [.9 .2; .1 .8],)), B._calculate_ess(10, "evt", (tail_prob = 0.6,)), B._calculate_ess(100, "tvtp_ms_garch", (;))])", inp = ein("bootstrap/calc_ess", c())),
  main_stream = teil(
    r"(simlev_seed(42); a <- SimLev:::.sl_state_hex(SimLev:::.sl_main_stream(NULL)); b <- SimLev:::.sl_state_hex(SimLev:::.sl_main_stream(1)); c1 <- SimLev:::.sl_runif(1); simlev_seed(42); k <- SimLev:::.sl_next_seed(); e <- SimLev:::.sl_state_hex(SimLev:::.sl_stream(k)); list(a, b, c1, k, identical(a, e)))",
    r"(simlev.simlev_seed(42); a = simlev._lib.main_stream(None).hex(); b = simlev._lib.main_stream(1).hex(); c1 = simlev._lib.runif(1); simlev.simlev_seed(42); k = simlev._lib.next_seed(); e = simlev._lib.Stream(k).hex(); result = [a, b, c1, k, a == e])",
    r"(SL.simlev_seed(42); a = SL.SLib.state_hex(SL.SLib.main_stream(nothing)); b = SL.SLib.state_hex(SL.SLib.main_stream(1)); c1 = SL.SLib.runif(1); SL.simlev_seed(42); k = SL.SLib.next_seed(); e = SL.SLib.state_hex(SL.SLib.Stream(k)); result = Any[a, b, c1, k, a == e])", inp = ein("bootstrap/main_stream", c()))))
SZ("studie_mit_kennzahlen", "bootstrap_study mit Hebel-ETF, Zinsreihe und Signalstrategie (gleitender Durchschnitt über 40 Tage, NA-Signale nach der Einschwingzeit von 35 Tagen), daraus summary() mit Kennzahlen und Quantilen; ess mit summary und bootstrap_probability; bootstrap_study_metrics einer Simulation", vor = VOR,
  gemein = teil(
    r"(cfgs <- bootstrap_config(c(akt = 'aktien'), aux = c(zins = 'zins'), input = 'prices', letfs = list(list(base = 'akt', leverage = 2, finance = 'zins', expense = 0.6)))
sma <- function(df, k = 40) { s <- stats::filter(df$akt_l2, rep(1 / k, k), sides = 1); list(buy = df$akt_l2 >= s, sell = df$akt_l2 < s) }
strats <- list(bnh = create_strategy(akt_l2 = asset_config('etf', 'bnh', partial_exemption = 30, spread = 0.1)),
  sma = list(strategy = create_strategy(letf = asset_config('etf', 'signal', partial_exemption = 30, signal_buy = 'buy', signal_sell = 'sell', spread = 0.1)), signal = sma, map = c(letf = 'akt_l2')))
st <- bootstrap_study(ds, cfgs, 'stationary', n = 3, params = list(L = 30), path_length = 400, burn_in = 35, seed = 1, progress = FALSE, benchmark = 'bnh', strategies = strats, chunk_size = 2); st$elapsed <- 0)",
    r"(cfgs = bootstrap_config({'akt': 'aktien'}, aux={'zins': 'zins'}, input='prices', letfs=[{'base': 'akt', 'leverage': 2, 'finance': 'zins', 'expense': 0.6}])
def _filt(x, k):
    x = np.asarray(x, dtype=float); f = 1.0 / k; out = np.full(len(x), simlev._r.fmt.NA_REAL)
    for i in range(k - 1, len(x)):
        z = 0.0
        for j in range(k):
            z += f * x[i - j]
        out[i] = z
    return out
def sma(df, k=40):
    s = _filt(df['akt_l2'], k); v = df['akt_l2'].to_numpy()
    with np.errstate(invalid='ignore'):
        return {'buy': v >= s, 'sell': v < s}
strats = {'bnh': simlev.create_strategy(akt_l2=simlev.asset_config(asset_class='etf', trading='bnh', partial_exemption=30, spread=0.1)),
  'sma': {'strategy': simlev.create_strategy(letf=simlev.asset_config(asset_class='etf', trading='signal', partial_exemption=30, signal_buy='buy', signal_sell='sell', spread=0.1)), 'signal': sma, 'map': {'letf': 'akt_l2'}}}
st = bootstrap_study(ds, cfgs, 'stationary', n=3, params={'L': 30}, path_length=400, burn_in=35, seed=1, progress=False, benchmark='bnh', strategies=strats, chunk_size=2); st['elapsed'] = 0)",
    r"(cfgs = bootstrap_config((akt = "aktien",), aux = (zins = "zins",), input = "prices", letfs = [(base = "akt", leverage = 2, finance = "zins", expense = 0.6)])
function sma(df; k = 40)
    x = df["akt_l2"]; s = fill(SL.NA, length(x))
    for i in k:length(x)
        z = 0.0
        for j in 0:k-1
            z += (1 / k) * x[i - j]
        end
        s[i] = z
    end
    (buy = x .>= s, sell = x .< s)
end
strats = (bnh = create_strategy(akt_l2 = asset_config("etf", "bnh", partial_exemption = 30, spread = 0.1)),
  sma = (strategy = create_strategy(letf = asset_config("etf", "signal", partial_exemption = 30, signal_buy = "buy", signal_sell = "sell", spread = 0.1)), signal = sma, map = (letf = "akt_l2",)))
st = bootstrap_study(ds, cfgs, "stationary"; n = 3, params = (L = 30,), path_length = 400, burn_in = 35, seed = 1, progress = false, benchmark = "bnh", strategies = strats, chunk_size = 2); st["elapsed"] = 0)"),
  teile = list(
  sm_basic = teil(
    r"(res <- simulation(ds, create_strategy(aktien = asset_config('etf', 'bnh', spread = 0.1))); bootstrap_study_metrics(res))",
    r"(res = simlev.simulation(ds, simlev.create_strategy(aktien=simlev.asset_config(asset_class='etf', trading='bnh', spread=0.1))); result = bootstrap_study_metrics(res))",
    r"(res = simulation(ds, create_strategy(aktien = asset_config("etf", "bnh", spread = 0.1))); result = bootstrap_study_metrics(res))", inp = ein("bootstrap/sm_basic", c("ds"))),
  study_basic = teil(
    r"(st)",
    r"(result = st)",
    r"(result = st)", druck = TRUE, inp = ein("bootstrap/study_basic", c("ds"))),
  study_summary = teil(
    r"(summary(st, metrics = c('cagr', 'max_drawdown', 'dd_q50', 'final_value', 'taxes', 'trades', 'foo'), probs = c(0.1, 0.5)))",
    r"(result = summary(st, metrics=['cagr', 'max_drawdown', 'dd_q50', 'final_value', 'taxes', 'trades', 'foo'], probs=[0.1, 0.5]))",
    r"(result = r_summary(st; metrics = ["cagr", "max_drawdown", "dd_q50", "final_value", "taxes", "trades", "foo"], probs = [0.1, 0.5]))", druck = TRUE),
  study_ess = teil(
    r"(st <- bootstrap_study(ds, bootstrap_config(c(akt = 'aktien'), input = 'prices'), 'stationary', n = 4, ess = TRUE, ess_grid = list(L = c(10, 50)), path_length = 200, seed = 4, progress = FALSE, strategies = list(a = create_strategy(akt = asset_config('etf', 'bnh', spread = 0.1)))); st$elapsed <- 0; list(st, summary(st), bootstrap_probability(st, cagr > 0)))",
    r"(st = bootstrap_study(ds, bootstrap_config({'akt': 'aktien'}, input='prices'), 'stationary', n=4, ess=True, ess_grid={'L': [10, 50]}, path_length=200, seed=4, progress=False, strategies={'a': simlev.create_strategy(akt=simlev.asset_config(asset_class='etf', trading='bnh', spread=0.1))}); st['elapsed'] = 0; result = [st, summary(st), bootstrap_probability(st, 'cagr > 0')])",
    r"(st = bootstrap_study(ds, bootstrap_config((akt = "aktien",), input = "prices"), "stationary"; n = 4, ess = true, ess_grid = (L = [10, 50],), path_length = 200, seed = 4, progress = false, strategies = (a = create_strategy(akt = asset_config("etf", "bnh", spread = 0.1)),)); st["elapsed"] = 0; result = [st, r_summary(st), bootstrap_probability(st, "cagr > 0")])", inp = ein("bootstrap/study_ess", c("ds")))))
SZ("studie_in_teilen", "bootstrap_study mit chunk_dir (löschen bzw. behalten; zweiter Lauf lädt die Chunks und gleicht dem Lauf ohne chunk_dir; Dateinamen ohne Sprachkennung, seit 1.6.3) und Signal-Tabelle mit Argumenten", vor = VOR, gemein = teil(
    r"(cfgb <- bootstrap_config(c(akt = 'aktien'), input = 'prices'); bnh <- create_strategy(akt = asset_config('etf', 'bnh', spread = 0.1)))",
    r"(cfgb = bootstrap_config({'akt': 'aktien'}, input='prices'); bnh = simlev.create_strategy(akt=simlev.asset_config(asset_class='etf', trading='bnh', spread=0.1))
import tempfile, os)",
    r"(cfgb = bootstrap_config((akt = "aktien",), input = "prices"); bnh = create_strategy(akt = asset_config("etf", "bnh", spread = 0.1)))"), teile = list(
  study_chunkdir = teil(
    r"(td <- tempfile(); a <- bootstrap_study(ds, cfgb, 'raw', n = 4, path_length = 200, seed = 2, chunk_size = 2, chunk_dir = td, progress = FALSE, keep_returns = 'month', strategies = list(b = bnh)); b <- bootstrap_study(ds, cfgb, 'raw', n = 4, path_length = 200, seed = 2, chunk_size = 2, chunk_dir = td, progress = FALSE, keep_returns = 'month', strategies = list(b = bnh)); o <- bootstrap_study(ds, cfgb, 'raw', n = 4, path_length = 200, seed = 2, chunk_size = 2, progress = FALSE, keep_returns = 'month', strategies = list(b = bnh)); list(a$results, b$results, b$returns, length(list.files(td)), sort(sub('_r[.]rds$', '', list.files(td))), o$results, o$returns))",
    r"(td = os.path.join(tempfile.mkdtemp(), 'x'); a = bootstrap_study(ds, cfgb, 'raw', n=4, path_length=200, seed=2, chunk_size=2, chunk_dir=td, progress=False, keep_returns='month', strategies={'b': bnh}); b = bootstrap_study(ds, cfgb, 'raw', n=4, path_length=200, seed=2, chunk_size=2, chunk_dir=td, progress=False, keep_returns='month', strategies={'b': bnh}); o = bootstrap_study(ds, cfgb, 'raw', n=4, path_length=200, seed=2, chunk_size=2, progress=False, keep_returns='month', strategies={'b': bnh}); result = [a['results'], b['results'], b['returns'], len(os.listdir(td)), sorted(f[:-len('_py.pkl')] if f.endswith('_py.pkl') else f for f in os.listdir(td)), o['results'], o['returns']])",
    r"(td = joinpath(mktempdir(), "x"); a = bootstrap_study(ds, cfgb, "raw"; n = 4, path_length = 200, seed = 2, chunk_size = 2, chunk_dir = td, progress = false, keep_returns = "month", strategies = (b = bnh,)); b = bootstrap_study(ds, cfgb, "raw"; n = 4, path_length = 200, seed = 2, chunk_size = 2, chunk_dir = td, progress = false, keep_returns = "month", strategies = (b = bnh,)); o = bootstrap_study(ds, cfgb, "raw"; n = 4, path_length = 200, seed = 2, chunk_size = 2, progress = false, keep_returns = "month", strategies = (b = bnh,)); result = [a["results"], b["results"], b["returns"], length(readdir(td)), sort([replace(f, r"_jl\.bin$" => "") for f in readdir(td)]), o["results"], o["returns"]])", inp = ein("bootstrap/study_chunkdir", c("ds"))),
  study_keep_chunkdir = teil(
    r"(td <- tempfile(); a <- bootstrap_study(ds, cfgb, 'raw', n = 4, path_length = 120, seed = 2, chunk_size = 2, chunk_dir = td, progress = FALSE, keep_paths = 3, strategies = list(b = bnh)); b <- bootstrap_study(ds, cfgb, 'raw', n = 4, path_length = 120, seed = 2, chunk_size = 2, chunk_dir = td, progress = FALSE, keep_paths = 1, strategies = list(b = bnh)); c0 <- bootstrap_study(ds, cfgb, 'raw', n = 4, path_length = 120, seed = 2, chunk_size = 2, chunk_dir = td, progress = FALSE, keep_paths = 0, strategies = list(b = bnh)); list(length(a$paths), length(b$paths), length(c0$paths), sort(sub('_r[.]rds$', '', list.files(td)), method = 'radix'), b$paths[[1]], a$results, c0$results))",
    r"(td = os.path.join(tempfile.mkdtemp(), 'x'); a = bootstrap_study(ds, cfgb, 'raw', n=4, path_length=120, seed=2, chunk_size=2, chunk_dir=td, progress=False, keep_paths=3, strategies={'b': bnh}); b = bootstrap_study(ds, cfgb, 'raw', n=4, path_length=120, seed=2, chunk_size=2, chunk_dir=td, progress=False, keep_paths=1, strategies={'b': bnh}); c0 = bootstrap_study(ds, cfgb, 'raw', n=4, path_length=120, seed=2, chunk_size=2, chunk_dir=td, progress=False, keep_paths=0, strategies={'b': bnh}); result = [len(a['paths']), len(b['paths']), len(c0['paths']), sorted(f[:-len('_py.pkl')] if f.endswith('_py.pkl') else f for f in os.listdir(td)), b['paths'][0], a['results'], c0['results']])",
    r"(td = joinpath(mktempdir(), "x"); a = bootstrap_study(ds, cfgb, "raw"; n = 4, path_length = 120, seed = 2, chunk_size = 2, chunk_dir = td, progress = false, keep_paths = 3, strategies = (b = bnh,)); b = bootstrap_study(ds, cfgb, "raw"; n = 4, path_length = 120, seed = 2, chunk_size = 2, chunk_dir = td, progress = false, keep_paths = 1, strategies = (b = bnh,)); c0 = bootstrap_study(ds, cfgb, "raw"; n = 4, path_length = 120, seed = 2, chunk_size = 2, chunk_dir = td, progress = false, keep_paths = 0, strategies = (b = bnh,)); result = [length(a["paths"]), length(b["paths"]), length(c0["paths"]), sort([replace(f, r"_jl\.bin$" => "") for f in readdir(td)]), b["paths"][1], a["results"], c0["results"]])", inp = ein("bootstrap/study_keep_chunkdir", c("ds"))),
  study_sigdf_args = teil(
    r"(sg <- function(df) { df$akt <- df$akt * 2; df }; st <- bootstrap_study(ds, cfgb, 'raw', n = 2, path_length = 150, seed = 3, progress = FALSE, sim_args = list(start_value = 500), strategies = list(a = bnh, b = list(strategy = bnh, signal = sg, args = list(start_value = 2000)))); st$results)",
    r"(def sg(df):
    df = df.copy(); df['akt'] = df['akt'] * 2; return df
st = bootstrap_study(ds, cfgb, 'raw', n=2, path_length=150, seed=3, progress=False, sim_args={'start_value': 500}, strategies={'a': bnh, 'b': {'strategy': bnh, 'signal': sg, 'args': {'start_value': 2000}}}); result = st['results'])",
    r"(function sg(df)
    df = copy(df); df["akt"] = df["akt"] .* 2; df
end
st = bootstrap_study(ds, cfgb, "raw"; n = 2, path_length = 150, seed = 3, progress = false, sim_args = (start_value = 500,), strategies = (a = bnh, b = (strategy = bnh, signal = sg, args = (start_value = 2000,)))); result = st["results"])", inp = ein("bootstrap/study_sigdf_args", c("ds")))))
SZ("wahrscheinlichkeiten_aus_studie", "bootstrap_probability in einem Aufruf mit Bedingungen in R-Syntax und als Skalar", vor = VOR, gemein = teil(
    r"(st <- structure(list(results = PT), class = 'SimLevBootstrapStudy'); thr <- 0.02; f2 <- function(x) x > 0.3)",
    r"(st = B.SimLevBootstrapStudy(results=PT); thr = 0.02
def f2(x):
    return x > 0.3)",
    r"(st = SL.RList(; class = ["SimLevBootstrapStudy"]); st["results"] = PT; thr = 0.02; f2(x) = x .> 0.3)"), teile = list(
  prob_rsyntax_scalar = teil(
    r"(bootstrap_probability(st, cagr > thr, a1 = !cagr < 0, a2 = cagr > 0 & !is.na(sharpe) | path %in% c(1, 2), a3 = path %% 2 == 0, a4 = cagr > quantile(cagr, 0.5, na.rm = TRUE), a5 = if (mean(cagr, na.rm = TRUE) > 0) sharpe > 0 else max_drawdown < 0.3, a6 = cagr >= median(cagr, na.rm = TRUE) - sd(cagr, na.rm = TRUE), a7 = max_drawdown <= max(max_drawdown) / 2, a8 = f2(sharpe), a9 = cagr[path] > 0 & path >= 2L, b1 = TRUE, b2 = mean(cagr, na.rm = TRUE) > 0, b3 = NA, b4 = c(TRUE, FALSE), b5 = rep(c(TRUE, NA), 4), b6 = "TRUE"))",
    r"(result = bootstrap_probability(st, 'cagr > thr', a1='!cagr < 0', a2='cagr > 0 & !is.na(sharpe) | path %in% c(1, 2)', a3='path %% 2 == 0', a4='cagr > quantile(cagr, 0.5, na.rm = TRUE)', a5='if (mean(cagr, na.rm = TRUE) > 0) sharpe > 0 else max_drawdown < 0.3', a6='cagr >= median(cagr, na.rm = TRUE) - sd(cagr, na.rm = TRUE)', a7='max_drawdown <= max(max_drawdown) / 2', a8='f2(sharpe)', a9='cagr[path] > 0 & path >= 2L', b1='TRUE', b2='mean(cagr, na.rm = TRUE) > 0', b3='NA', b4='c(TRUE, FALSE)', b5='rep(c(TRUE, NA), 4)', b6='"TRUE"'))",
    r"-(result = bootstrap_probability(st, "cagr > thr"; a1 = "!cagr < 0", a2 = "cagr > 0 & !is.na(sharpe) | path %in% c(1, 2)", a3 = "path %% 2 == 0", a4 = "cagr > quantile(cagr, 0.5, na.rm = TRUE)", a5 = "if (mean(cagr, na.rm = TRUE) > 0) sharpe > 0 else max_drawdown < 0.3", a6 = "cagr >= median(cagr, na.rm = TRUE) - sd(cagr, na.rm = TRUE)", a7 = "max_drawdown <= max(max_drawdown) / 2", a8 = "f2(sharpe)", a9 = "cagr[path] > 0 & path >= 2L", b1 = "TRUE", b2 = "mean(cagr, na.rm = TRUE) > 0", b3 = "NA", b4 = "c(TRUE, FALSE)", b5 = "rep(c(TRUE, NA), 4)", b6 = "\"TRUE\"", env = @__MODULE__))-", inp = ein("bootstrap/prob_rsyntax", c("PT")))))
ref_done()

ref_init("bootstrap", gruppe = "fehler")
TB("bootstrap_config", "Meldungen und Warnungen von bootstrap_config je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("cfg_negfin",
    r"(bootstrap_config(c(a = 'a'), letfs = list(list(base = 'a', finance = -1))))",
    r"(result = bootstrap_config({'a': 'a'}, letfs=[{'base': 'a', 'finance': -1}]))",
    r"(result = bootstrap_config((a = "a",), letfs = [(base = "a", finance = -1)]))", print = TRUE, inp = ein("bootstrap/cfg_negfin", c())),
  zeile("cfg_err_unnamed",
    r"(bootstrap_config(c('a')))",
    r"(result = bootstrap_config(['a']))",
    r"(result = bootstrap_config(["a"]))", inp = ein("bootstrap/cfg_err_unnamed", c())),
  zeile("cfg_err_dupidx",
    r"(bootstrap_config(c(a = 'a', a = 'b')))",
    r"(result = bootstrap_config(pd.Series(['a', 'b'], index=['a', 'a'])))",
    r"(result = bootstrap_config(["a" => "a", "a" => "b"]))", inp = ein("bootstrap/cfg_err_dupidx", c())),
  zeile("cfg_err_auxunnamed",
    r"(bootstrap_config(c(a = 'a'), aux = 'x'))",
    r"(result = bootstrap_config({'a': 'a'}, aux='x'))",
    r"(result = bootstrap_config((a = "a",), aux = "x"))", inp = ein("bootstrap/cfg_err_auxunnamed", c())),
  zeile("cfg_err_base_missing",
    r"(bootstrap_config(c(a = 'a'), letfs = list(list(leverage = 2))))",
    r"(result = bootstrap_config({'a': 'a'}, letfs=[{'leverage': 2}]))",
    r"(result = bootstrap_config((a = "a",), letfs = [(leverage = 2,)]))", inp = ein("bootstrap/cfg_err_base_missing", c())),
  zeile("cfg_err_base_bad",
    r"(bootstrap_config(c(a = 'a'), letfs = list(list(base = 'x'))))",
    r"(result = bootstrap_config({'a': 'a'}, letfs=[{'base': 'x'}]))",
    r"(result = bootstrap_config((a = "a",), letfs = [(base = "x",)]))", inp = ein("bootstrap/cfg_err_base_bad", c())),
  zeile("cfg_err_lev0",
    r"(bootstrap_config(c(a = 'a'), letfs = list(list(base = 'a', leverage = 0))))",
    r"(result = bootstrap_config({'a': 'a'}, letfs=[{'base': 'a', 'leverage': 0}]))",
    r"(result = bootstrap_config((a = "a",), letfs = [(base = "a", leverage = 0)]))", inp = ein("bootstrap/cfg_err_lev0", c())),
  zeile("cfg_err_fin_bad",
    r"(bootstrap_config(c(a = 'a'), letfs = list(list(base = 'a', finance = 'rate'))))",
    r"(result = bootstrap_config({'a': 'a'}, letfs=[{'base': 'a', 'finance': 'rate'}]))",
    r"(result = bootstrap_config((a = "a",), letfs = [(base = "a", finance = "rate")]))", inp = ein("bootstrap/cfg_err_fin_bad", c())),
  zeile("cfg_err_exp_neg",
    r"(bootstrap_config(c(a = 'a'), letfs = list(list(base = 'a', expense = -1))))",
    r"(result = bootstrap_config({'a': 'a'}, letfs=[{'base': 'a', 'expense': -1}]))",
    r"(result = bootstrap_config((a = "a",), letfs = [(base = "a", expense = -1)]))", inp = ein("bootstrap/cfg_err_exp_neg", c())),
  zeile("cfg_err_days_bad",
    r"(bootstrap_config(c(a = 'a'), letfs = list(list(base = 'a', days = 'tage'))))",
    r"(result = bootstrap_config({'a': 'a'}, letfs=[{'base': 'a', 'days': 'tage'}]))",
    r"(result = bootstrap_config((a = "a",), letfs = [(base = "a", days = "tage")]))", inp = ein("bootstrap/cfg_err_days_bad", c())),
  zeile("cfg_err_fin_level",
    r"(bootstrap_config(c(us = 'us'), aux = c(z = 'z'), aux_type = c(z = 'level'), letfs = list(list(base = 'us', finance = 'z'))))",
    r"(result = bootstrap_config({'us': 'us'}, aux={'z': 'z'}, aux_type={'z': 'level'}, letfs=[{'base': 'us', 'finance': 'z'}]))",
    r"(result = bootstrap_config((us = "us",), aux = (z = "z",), aux_type = (z = "level",), letfs = [(base = "us", finance = "z")]))", inp = ein("bootstrap/cfg_err_fin_level", c())),
  zeile("cfg_err_days_level",
    r"(bootstrap_config(c(us = 'us'), aux = c(z = 'z'), aux_type = c(z = 'level'), letfs = list(list(base = 'us', days = 'z'))))",
    r"(result = bootstrap_config({'us': 'us'}, aux={'z': 'z'}, aux_type={'z': 'level'}, letfs=[{'base': 'us', 'days': 'z'}]))",
    r"(result = bootstrap_config((us = "us",), aux = (z = "z",), aux_type = (z = "level",), letfs = [(base = "us", days = "z")]))", inp = ein("bootstrap/cfg_err_days_level", c())),
  zeile("cfg_err_dupnames",
    r"(bootstrap_config(c(a = 'a'), aux = c(a_l2 = 'x'), letfs = list(list(base = 'a'))))",
    r"(result = bootstrap_config({'a': 'a'}, aux={'a_l2': 'x'}, letfs=[{'base': 'a'}]))",
    r"(result = bootstrap_config((a = "a",), aux = (a_l2 = "x",), letfs = [(base = "a",)]))", inp = ein("bootstrap/cfg_err_dupnames", c())),
  zeile("cfg_err_regime_bad",
    r"(bootstrap_config(c(a = 'a'), regime_index = 'b'))",
    r"(result = bootstrap_config({'a': 'a'}, regime_index='b'))",
    r"(result = bootstrap_config((a = "a",), regime_index = "b"))", inp = ein("bootstrap/cfg_err_regime_bad", c())),
  zeile("cfg_err_at_noaux",
    r"(bootstrap_config(c(us = 'us'), aux_type = c(cpi = 'level', x = 'rate')))",
    r"(result = bootstrap_config({'us': 'us'}, aux_type={'cpi': 'level', 'x': 'rate'}))",
    r"(result = bootstrap_config((us = "us",), aux_type = (cpi = "level", x = "rate")))", inp = ein("bootstrap/cfg_err_at_noaux", c())),
  zeile("cfg_err_at_value",
    r"(bootstrap_config(c(us = 'us'), aux = c(cpi = 'cpi'), aux_type = c(cpi = 'niveau')))",
    r"(result = bootstrap_config({'us': 'us'}, aux={'cpi': 'cpi'}, aux_type={'cpi': 'niveau'}))",
    r"(result = bootstrap_config((us = "us",), aux = (cpi = "cpi",), aux_type = (cpi = "niveau",)))", inp = ein("bootstrap/cfg_err_at_value", c())),
  zeile("cfg_err_at_unnamed",
    r"(bootstrap_config(c(us = 'us'), aux = c(cpi = 'cpi'), aux_type = 'level'))",
    r"(result = bootstrap_config({'us': 'us'}, aux={'cpi': 'cpi'}, aux_type='level'))",
    r"(result = bootstrap_config((us = "us",), aux = (cpi = "cpi",), aux_type = "level"))", inp = ein("bootstrap/cfg_err_at_unnamed", c())),
  zeile("cfg_err_at_dup",
    r"(bootstrap_config(c(us = 'us'), aux = c(cpi = 'cpi'), aux_type = c(cpi = 'level', cpi = 'rate')))",
    r"(result = bootstrap_config({'us': 'us'}, aux={'cpi': 'cpi'}, aux_type=pd.Series(['level', 'rate'], index=['cpi', 'cpi'])))",
    r"(result = bootstrap_config((us = "us",), aux = (cpi = "cpi",), aux_type = ["cpi" => "level", "cpi" => "rate"]))", inp = ein("bootstrap/cfg_err_at_dup", c())),
  zeile("cfg_err_letf_base_factor",
    r"(bootstrap_config(c(a = 'a'), letfs = list(list(base = factor('a')))))",
    r"(result = bootstrap_config({'a': 'a'}, letfs=[{'base': pd.Categorical(['a'])}]))",
    r"(result = bootstrap_config((a = "a",), letfs = [(base = SL.RFmt.RFactor([1], ["a"]),)]))", inp = list()),
  zeile("cfg_err_letf_lev_lgl",
    r"(bootstrap_config(c(a = 'a'), letfs = list(list(base = 'a', leverage = TRUE))))",
    r"(result = bootstrap_config({'a': 'a'}, letfs=[{'base': 'a', 'leverage': True}]))",
    r"(result = bootstrap_config((a = "a",), letfs = [(base = "a", leverage = true,)]))", inp = list()),
  zeile("cfg_err_letf_fin_na",
    r"(bootstrap_config(c(a = 'a'), letfs = list(list(base = 'a', finance = NA))))",
    r"(result = bootstrap_config({'a': 'a'}, letfs=[{'base': 'a', 'finance': simlev._r.fmt.NA_REAL}]))",
    r"(result = bootstrap_config((a = "a",), letfs = [(base = "a", finance = SL.NA,)]))", inp = list()),
  zeile("cfg_err_letf_fin_vec",
    r"(bootstrap_config(c(a = 'a'), letfs = list(list(base = 'a', finance = c(1, 2)))))",
    r"(result = bootstrap_config({'a': 'a'}, letfs=[{'base': 'a', 'finance': [1, 2]}]))",
    r"(result = bootstrap_config((a = "a",), letfs = [(base = "a", finance = [1, 2],)]))", inp = list()),
  zeile("cfg_err_letf_exp_inf",
    r"(bootstrap_config(c(a = 'a'), letfs = list(list(base = 'a', expense = Inf))))",
    r"(result = bootstrap_config({'a': 'a'}, letfs=[{'base': 'a', 'expense': float('inf')}]))",
    r"(result = bootstrap_config((a = "a",), letfs = [(base = "a", expense = Inf,)]))", inp = list()),
  zeile("cfg_err_letf_days_vec",
    r"(bootstrap_config(c(a = 'a'), letfs = list(list(base = 'a', days = c(1, 3)))))",
    r"(result = bootstrap_config({'a': 'a'}, letfs=[{'base': 'a', 'days': [1, 3]}]))",
    r"(result = bootstrap_config((a = "a",), letfs = [(base = "a", days = [1, 3],)]))", inp = list()),
  zeile("cfg_err_letf_spread_chr",
    r"(bootstrap_config(c(a = 'a'), letfs = list(list(base = 'a', spread = 'x'))))",
    r"(result = bootstrap_config({'a': 'a'}, letfs=[{'base': 'a', 'spread': 'x'}]))",
    r"(result = bootstrap_config((a = "a",), letfs = [(base = "a", spread = "x",)]))", inp = list()),
  zeile("cfg_err_letf_rb_vec",
    r"(bootstrap_config(c(a = 'a'), letfs = list(list(base = 'a', rate_basis = c(360, 365)))))",
    r"(result = bootstrap_config({'a': 'a'}, letfs=[{'base': 'a', 'rate_basis': [360, 365]}]))",
    r"(result = bootstrap_config((a = "a",), letfs = [(base = "a", rate_basis = [360, 365],)]))", inp = list()),
  zeile("cfg_err_letf_tb_lgl",
    r"(bootstrap_config(c(a = 'a'), letfs = list(list(base = 'a', ter_basis = FALSE))))",
    r"(result = bootstrap_config({'a': 'a'}, letfs=[{'base': 'a', 'ter_basis': False}]))",
    r"(result = bootstrap_config((a = "a",), letfs = [(base = "a", ter_basis = false,)]))", inp = list()),
  zeile("cfg_err_letf_name_na",
    r"(bootstrap_config(c(a = 'a'), letfs = list(list(base = 'a', name = NA_character_))))",
    r"(result = bootstrap_config({'a': 'a'}, letfs=[{'base': 'a', 'name': simlev._r.fmt.NA_REAL}]))",
    r"(result = bootstrap_config((a = "a",), letfs = [(base = "a", name = missing,)]))", inp = list())))
TB("bootstrap", "Meldungen und Warnungen von bootstrap je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("bs_err_method_num",   # seit 1.6.4 (K43 RS B3, Meldung mit Funktionsnamen, Entscheidung 155)
    r"(bootstrap(data.frame(a = 1 + sin(1:50) / 100), bootstrap_config(c(a = 'a')), method = 1))",
    r"(result = bootstrap(pd.DataFrame({'a': 1 + np.sin(np.arange(1, 51)) / 100}), bootstrap_config({'a': 'a'}), method=1))",
    r"(result = bootstrap(RFrame("a" => 1 .+ sin.(1:50) ./ 100), bootstrap_config(Dict("a" => "a")); method = 1))", inp = list()),
  zeile("bs_garch",
    r"(cfg <- bootstrap_config(c(us = 'us', eu = 'eu'), regime_index = 'us', aux = c(rate = 'rate'),
  letfs = list(list(base = 'eu', leverage = 2, finance = 'rate', expense = 0.5), list(base = 'us', leverage = -1, finance = 'rate', expense = 0.6)))
b <- bootstrap(d, cfg, 'garch', n = 2, seed = 1, progress = FALSE); b)",
    r"(cfg = bootstrap_config({'us': 'us', 'eu': 'eu'}, regime_index='us', aux={'rate': 'rate'},
  letfs=[{'base': 'eu', 'leverage': 2, 'finance': 'rate', 'expense': 0.5}, {'base': 'us', 'leverage': -1, 'finance': 'rate', 'expense': 0.6}])
result = bootstrap(d, cfg, method='garch', n=2, seed=1, progress=False))",
    r"(cfg = bootstrap_config((us = "us", eu = "eu"), regime_index = "us", aux = (rate = "rate",),
  letfs = [(base = "eu", leverage = 2, finance = "rate", expense = 0.5), (base = "us", leverage = -1, finance = "rate", expense = 0.6)])
result = bootstrap(d, cfg, "garch"; n = 2, seed = 1, progress = false))", print = TRUE, inp = ein("bootstrap/bs_garch", c("d"))),
  zeile("bs_wild_allfail",
    r"(bootstrap(dv, bootstrap_config(c(us = 'us')), 'wild', n = 2, params = list(wild_type = 2), seed = 1, progress = FALSE, max_tries = 1))",
    r"(result = bootstrap(dv, bootstrap_config({'us': 'us'}), method='wild', n=2, params={'wild_type': 2}, seed=1, progress=False, max_tries=1))",
    r"(result = bootstrap(dv, bootstrap_config((us = "us",)), "wild"; n = 2, params = (wild_type = 2,), seed = 1, progress = false, max_tries = 1))", inp = ein("bootstrap/bs_wild_allfail", c("dv"))),
  zeile("bs_garch_const",
    r"(bootstrap(data.frame(us = rep(1.0001, 50)), bootstrap_config(c(us = 'us')), 'garch', n = 1, seed = 1))",
    r"(result = bootstrap(pd.DataFrame({'us': np.full(50, 1.0001)}), bootstrap_config({'us': 'us'}), method='garch', n=1, seed=1))",
    r"(result = bootstrap(SL.RFrame("us" => fill(1.0001, 50)), bootstrap_config((us = "us",)), "garch"; n = 1, seed = 1))", inp = ein("bootstrap/bs_garch_const", c())),
  zeile("bs_ms_err_egarch",
    r"(cfg <- bootstrap_config(c(us = 'us', eu = 'eu'), regime_index = 'us', aux = c(rate = 'rate'),
  letfs = list(list(base = 'eu', leverage = 2, finance = 'rate', expense = 0.5), list(base = 'us', leverage = -1, finance = 'rate', expense = 0.6)))
bootstrap(d, cfg, 'ms_garch', n = 1, seed = 1, params = list(ms_garch_model = 'eGARCH')))",
    r"(cfg = bootstrap_config({'us': 'us', 'eu': 'eu'}, regime_index='us', aux={'rate': 'rate'},
  letfs=[{'base': 'eu', 'leverage': 2, 'finance': 'rate', 'expense': 0.5}, {'base': 'us', 'leverage': -1, 'finance': 'rate', 'expense': 0.6}])
result = bootstrap(d, cfg, method='ms_garch', n=1, seed=1, params={'ms_garch_model': 'eGARCH'}))",
    r"(cfg = bootstrap_config((us = "us", eu = "eu"), regime_index = "us", aux = (rate = "rate",),
  letfs = [(base = "eu", leverage = 2, finance = "rate", expense = 0.5), (base = "us", leverage = -1, finance = "rate", expense = 0.6)])
result = bootstrap(d, cfg, "ms_garch"; n = 1, seed = 1, params = (ms_garch_model = "eGARCH",)))", inp = ein("bootstrap/bs_ms_err_egarch", c("d"))),
  zeile("aux_level_err",
    r"(dd <- dp; dd$cpi[40] <- -1; bootstrap(dd, bootstrap_config(c(us = 'us'), aux = c(cpi = 'cpi'), input = 'prices', aux_type = c(cpi = 'level')), 'raw', n = 1, seed = 1))",
    r"(dd = dp.copy(); dd.loc[39, 'cpi'] = -1; result = bootstrap(dd, bootstrap_config({'us': 'us'}, aux={'cpi': 'cpi'}, input='prices', aux_type={'cpi': 'level'}), method='raw', n=1, seed=1))",
    r"(dd = copy(dp); dd.cpi[40] = -1; result = bootstrap(dd, bootstrap_config((us = "us",), aux = (cpi = "cpi",), input = "prices", aux_type = (cpi = "level",)), "raw"; n = 1, seed = 1))", inp = ein("bootstrap/aux_level_err", c("dp"))),
  zeile("bs_err_method",
    r"(cfg <- bootstrap_config(c(us = 'us', eu = 'eu'), regime_index = 'us', aux = c(rate = 'rate'),
  letfs = list(list(base = 'eu', leverage = 2, finance = 'rate', expense = 0.5), list(base = 'us', leverage = -1, finance = 'rate', expense = 0.6)))
bootstrap(d, cfg, 'foo', n = 1))",
    r"(cfg = bootstrap_config({'us': 'us', 'eu': 'eu'}, regime_index='us', aux={'rate': 'rate'},
  letfs=[{'base': 'eu', 'leverage': 2, 'finance': 'rate', 'expense': 0.5}, {'base': 'us', 'leverage': -1, 'finance': 'rate', 'expense': 0.6}])
result = bootstrap(d, cfg, method='foo', n=1))",
    r"(cfg = bootstrap_config((us = "us", eu = "eu"), regime_index = "us", aux = (rate = "rate",),
  letfs = [(base = "eu", leverage = 2, finance = "rate", expense = 0.5), (base = "us", leverage = -1, finance = "rate", expense = 0.6)])
result = bootstrap(d, cfg, "foo"; n = 1))", inp = ein("bootstrap/bs_err_method", c("d"))),
  zeile("bs_err_n0",
    r"(cfg <- bootstrap_config(c(us = 'us', eu = 'eu'), regime_index = 'us', aux = c(rate = 'rate'),
  letfs = list(list(base = 'eu', leverage = 2, finance = 'rate', expense = 0.5), list(base = 'us', leverage = -1, finance = 'rate', expense = 0.6)))
bootstrap(d, cfg, n = 0))",
    r"(cfg = bootstrap_config({'us': 'us', 'eu': 'eu'}, regime_index='us', aux={'rate': 'rate'},
  letfs=[{'base': 'eu', 'leverage': 2, 'finance': 'rate', 'expense': 0.5}, {'base': 'us', 'leverage': -1, 'finance': 'rate', 'expense': 0.6}])
result = bootstrap(d, cfg, n=0))",
    r"(cfg = bootstrap_config((us = "us", eu = "eu"), regime_index = "us", aux = (rate = "rate",),
  letfs = [(base = "eu", leverage = 2, finance = "rate", expense = 0.5), (base = "us", leverage = -1, finance = "rate", expense = 0.6)])
result = bootstrap(d, cfg; n = 0))", inp = ein("bootstrap/bs_err_n0", c("d"))),
  zeile("bs_err_cores",   # Standard "auto"; ungültig -> Meldung par.cores (seit 1.6.4, Entscheidung 113)
    r"(cfg <- bootstrap_config(c(us = 'us', eu = 'eu'), regime_index = 'us', aux = c(rate = 'rate'),
  letfs = list(list(base = 'eu', leverage = 2, finance = 'rate', expense = 0.5), list(base = 'us', leverage = -1, finance = 'rate', expense = 0.6)))
bootstrap(d, cfg, n = 1, cores = 0))",
    r"(cfg = bootstrap_config({'us': 'us', 'eu': 'eu'}, regime_index='us', aux={'rate': 'rate'},
  letfs=[{'base': 'eu', 'leverage': 2, 'finance': 'rate', 'expense': 0.5}, {'base': 'us', 'leverage': -1, 'finance': 'rate', 'expense': 0.6}])
result = bootstrap(d, cfg, n=1, cores=0))",
    r"(cfg = bootstrap_config((us = "us", eu = "eu"), regime_index = "us", aux = (rate = "rate",),
  letfs = [(base = "eu", leverage = 2, finance = "rate", expense = 0.5), (base = "us", leverage = -1, finance = "rate", expense = 0.6)])
result = bootstrap(d, cfg; n = 1, cores = 0))", inp = ein("bootstrap/bs_err_n0", c("d"))),
  zeile("bs_err_pl0",
    r"(cfg <- bootstrap_config(c(us = 'us', eu = 'eu'), regime_index = 'us', aux = c(rate = 'rate'),
  letfs = list(list(base = 'eu', leverage = 2, finance = 'rate', expense = 0.5), list(base = 'us', leverage = -1, finance = 'rate', expense = 0.6)))
bootstrap(d, cfg, n = 1, path_length = 0))",
    r"(cfg = bootstrap_config({'us': 'us', 'eu': 'eu'}, regime_index='us', aux={'rate': 'rate'},
  letfs=[{'base': 'eu', 'leverage': 2, 'finance': 'rate', 'expense': 0.5}, {'base': 'us', 'leverage': -1, 'finance': 'rate', 'expense': 0.6}])
result = bootstrap(d, cfg, n=1, path_length=0))",
    r"(cfg = bootstrap_config((us = "us", eu = "eu"), regime_index = "us", aux = (rate = "rate",),
  letfs = [(base = "eu", leverage = 2, finance = "rate", expense = 0.5), (base = "us", leverage = -1, finance = "rate", expense = 0.6)])
result = bootstrap(d, cfg; n = 1, path_length = 0))", inp = ein("bootstrap/bs_err_pl0", c("d"))),
  zeile("bs_err_wildpl",
    r"(cfg <- bootstrap_config(c(us = 'us', eu = 'eu'), regime_index = 'us', aux = c(rate = 'rate'),
  letfs = list(list(base = 'eu', leverage = 2, finance = 'rate', expense = 0.5), list(base = 'us', leverage = -1, finance = 'rate', expense = 0.6)))
bootstrap(d, cfg, 'wild', n = 1, path_length = 10))",
    r"(cfg = bootstrap_config({'us': 'us', 'eu': 'eu'}, regime_index='us', aux={'rate': 'rate'},
  letfs=[{'base': 'eu', 'leverage': 2, 'finance': 'rate', 'expense': 0.5}, {'base': 'us', 'leverage': -1, 'finance': 'rate', 'expense': 0.6}])
result = bootstrap(d, cfg, method='wild', n=1, path_length=10))",
    r"(cfg = bootstrap_config((us = "us", eu = "eu"), regime_index = "us", aux = (rate = "rate",),
  letfs = [(base = "eu", leverage = 2, finance = "rate", expense = 0.5), (base = "us", leverage = -1, finance = "rate", expense = 0.6)])
result = bootstrap(d, cfg, "wild"; n = 1, path_length = 10))", inp = ein("bootstrap/bs_err_wildpl", c("d"))),
  zeile("bs_err_cfg",
    r"(cfg <- bootstrap_config(c(us = 'us', eu = 'eu'), regime_index = 'us', aux = c(rate = 'rate'),
  letfs = list(list(base = 'eu', leverage = 2, finance = 'rate', expense = 0.5), list(base = 'us', leverage = -1, finance = 'rate', expense = 0.6)))
bootstrap(d, list(a = 1), n = 1))",
    r"(cfg = bootstrap_config({'us': 'us', 'eu': 'eu'}, regime_index='us', aux={'rate': 'rate'},
  letfs=[{'base': 'eu', 'leverage': 2, 'finance': 'rate', 'expense': 0.5}, {'base': 'us', 'leverage': -1, 'finance': 'rate', 'expense': 0.6}])
result = bootstrap(d, {'a': 1}, n=1))",
    r"(cfg = bootstrap_config((us = "us", eu = "eu"), regime_index = "us", aux = (rate = "rate",),
  letfs = [(base = "eu", leverage = 2, finance = "rate", expense = 0.5), (base = "us", leverage = -1, finance = "rate", expense = 0.6)])
result = bootstrap(d, (a = 1,); n = 1))", inp = ein("bootstrap/bs_err_cfg", c("d"))),
  zeile("bs_err_data",
    r"(cfg <- bootstrap_config(c(us = 'us', eu = 'eu'), regime_index = 'us', aux = c(rate = 'rate'),
  letfs = list(list(base = 'eu', leverage = 2, finance = 'rate', expense = 0.5), list(base = 'us', leverage = -1, finance = 'rate', expense = 0.6)))
bootstrap(1:3, cfg, n = 1))",
    r"(cfg = bootstrap_config({'us': 'us', 'eu': 'eu'}, regime_index='us', aux={'rate': 'rate'},
  letfs=[{'base': 'eu', 'leverage': 2, 'finance': 'rate', 'expense': 0.5}, {'base': 'us', 'leverage': -1, 'finance': 'rate', 'expense': 0.6}])
result = bootstrap([1, 2, 3], cfg, n=1))",
    r"(cfg = bootstrap_config((us = "us", eu = "eu"), regime_index = "us", aux = (rate = "rate",),
  letfs = [(base = "eu", leverage = 2, finance = "rate", expense = 0.5), (base = "us", leverage = -1, finance = "rate", expense = 0.6)])
result = bootstrap([1, 2, 3], cfg; n = 1))", inp = ein("bootstrap/bs_err_data", c())),
  zeile("bs_err_empty",
    r"(cfg <- bootstrap_config(c(us = 'us', eu = 'eu'), regime_index = 'us', aux = c(rate = 'rate'),
  letfs = list(list(base = 'eu', leverage = 2, finance = 'rate', expense = 0.5), list(base = 'us', leverage = -1, finance = 'rate', expense = 0.6)))
bootstrap(d[0, ], cfg, n = 1))",
    r"(cfg = bootstrap_config({'us': 'us', 'eu': 'eu'}, regime_index='us', aux={'rate': 'rate'},
  letfs=[{'base': 'eu', 'leverage': 2, 'finance': 'rate', 'expense': 0.5}, {'base': 'us', 'leverage': -1, 'finance': 'rate', 'expense': 0.6}])
result = bootstrap(d.iloc[:0], cfg, n=1))",
    r"(cfg = bootstrap_config((us = "us", eu = "eu"), regime_index = "us", aux = (rate = "rate",),
  letfs = [(base = "eu", leverage = 2, finance = "rate", expense = 0.5), (base = "us", leverage = -1, finance = "rate", expense = 0.6)])
result = bootstrap(SL.rows(d, Int[]), cfg; n = 1))", inp = ein("bootstrap/bs_err_empty", c("d"))),
  zeile("bs_err_col",
    r"(cfg <- bootstrap_config(c(us = 'us', eu = 'eu'), regime_index = 'us', aux = c(rate = 'rate'),
  letfs = list(list(base = 'eu', leverage = 2, finance = 'rate', expense = 0.5), list(base = 'us', leverage = -1, finance = 'rate', expense = 0.6)))
bootstrap(d[, c('us', 'rate')], cfg, n = 1))",
    r"(cfg = bootstrap_config({'us': 'us', 'eu': 'eu'}, regime_index='us', aux={'rate': 'rate'},
  letfs=[{'base': 'eu', 'leverage': 2, 'finance': 'rate', 'expense': 0.5}, {'base': 'us', 'leverage': -1, 'finance': 'rate', 'expense': 0.6}])
result = bootstrap(d[['us', 'rate']], cfg, n=1))",
    r"(cfg = bootstrap_config((us = "us", eu = "eu"), regime_index = "us", aux = (rate = "rate",),
  letfs = [(base = "eu", leverage = 2, finance = "rate", expense = 0.5), (base = "us", leverage = -1, finance = "rate", expense = 0.6)])
result = bootstrap(SL.RFrame("us" => d.us, "rate" => d.rate), cfg; n = 1))", inp = ein("bootstrap/bs_err_col", c("d"))),
  zeile("bs_err_allna",
    r"(cfg <- bootstrap_config(c(us = 'us', eu = 'eu'), regime_index = 'us', aux = c(rate = 'rate'),
  letfs = list(list(base = 'eu', leverage = 2, finance = 'rate', expense = 0.5), list(base = 'us', leverage = -1, finance = 'rate', expense = 0.6)))
dd <- d[1:5, ]; dd$us <- NA; bootstrap(dd, cfg, n = 1))",
    r"(cfg = bootstrap_config({'us': 'us', 'eu': 'eu'}, regime_index='us', aux={'rate': 'rate'},
  letfs=[{'base': 'eu', 'leverage': 2, 'finance': 'rate', 'expense': 0.5}, {'base': 'us', 'leverage': -1, 'finance': 'rate', 'expense': 0.6}])
result = dd = d.iloc[:5].copy(); dd['us'] = simlev._r.fmt.NA_REAL; bootstrap(dd, cfg, n=1))",
    r"(cfg = bootstrap_config((us = "us", eu = "eu"), regime_index = "us", aux = (rate = "rate",),
  letfs = [(base = "eu", leverage = 2, finance = "rate", expense = 0.5), (base = "us", leverage = -1, finance = "rate", expense = 0.6)])
result = (dd = SL.rows(d, 1:5); dd.us .= SL.NA; bootstrap(dd, cfg; n = 1)))", inp = ein("bootstrap/bs_err_allna", c("d"))),
  zeile("bs_err_inf",
    r"(cfg <- bootstrap_config(c(us = 'us', eu = 'eu'), regime_index = 'us', aux = c(rate = 'rate'),
  letfs = list(list(base = 'eu', leverage = 2, finance = 'rate', expense = 0.5), list(base = 'us', leverage = -1, finance = 'rate', expense = 0.6)))
dd <- d[1:50, ]; dd$eu[c(7, 9)] <- Inf; dd$us[30] <- -Inf; bootstrap(dd, cfg, n = 1))",
    r"(cfg = bootstrap_config({'us': 'us', 'eu': 'eu'}, regime_index='us', aux={'rate': 'rate'},
  letfs=[{'base': 'eu', 'leverage': 2, 'finance': 'rate', 'expense': 0.5}, {'base': 'us', 'leverage': -1, 'finance': 'rate', 'expense': 0.6}])
result = dd = d.iloc[:50].copy(); dd.loc[[6, 8], 'eu'] = np.inf; dd.loc[29, 'us'] = -np.inf; bootstrap(dd, cfg, n=1))",
    r"(cfg = bootstrap_config((us = "us", eu = "eu"), regime_index = "us", aux = (rate = "rate",),
  letfs = [(base = "eu", leverage = 2, finance = "rate", expense = 0.5), (base = "us", leverage = -1, finance = "rate", expense = 0.6)])
result = (dd = SL.rows(d, 1:50); dd.eu[[7, 9]] .= Inf; dd.us[30] = -Inf; bootstrap(dd, cfg; n = 1)))", inp = ein("bootstrap/bs_err_inf", c("d"))),
  zeile("bs_err_neg",
    r"(cfg <- bootstrap_config(c(us = 'us', eu = 'eu'), regime_index = 'us', aux = c(rate = 'rate'),
  letfs = list(list(base = 'eu', leverage = 2, finance = 'rate', expense = 0.5), list(base = 'us', leverage = -1, finance = 'rate', expense = 0.6)))
dd <- d[1:50, ]; dd$eu[7] <- -0.5; bootstrap(dd, cfg, n = 1))",
    r"(cfg = bootstrap_config({'us': 'us', 'eu': 'eu'}, regime_index='us', aux={'rate': 'rate'},
  letfs=[{'base': 'eu', 'leverage': 2, 'finance': 'rate', 'expense': 0.5}, {'base': 'us', 'leverage': -1, 'finance': 'rate', 'expense': 0.6}])
result = dd = d.iloc[:50].copy(); dd.loc[6, 'eu'] = -0.5; bootstrap(dd, cfg, n=1))",
    r"(cfg = bootstrap_config((us = "us", eu = "eu"), regime_index = "us", aux = (rate = "rate",),
  letfs = [(base = "eu", leverage = 2, finance = "rate", expense = 0.5), (base = "us", leverage = -1, finance = "rate", expense = 0.6)])
result = (dd = SL.rows(d, 1:50); dd.eu[7] = -0.5; bootstrap(dd, cfg; n = 1)))", inp = ein("bootstrap/bs_err_neg", c("d"))),
  zeile("bs_err_L",
    r"(cfg <- bootstrap_config(c(us = 'us', eu = 'eu'), regime_index = 'us', aux = c(rate = 'rate'),
  letfs = list(list(base = 'eu', leverage = 2, finance = 'rate', expense = 0.5), list(base = 'us', leverage = -1, finance = 'rate', expense = 0.6)))
bootstrap(d, cfg, 'stationary', n = 1, params = list(L = 0.5)))",
    r"(cfg = bootstrap_config({'us': 'us', 'eu': 'eu'}, regime_index='us', aux={'rate': 'rate'},
  letfs=[{'base': 'eu', 'leverage': 2, 'finance': 'rate', 'expense': 0.5}, {'base': 'us', 'leverage': -1, 'finance': 'rate', 'expense': 0.6}])
result = bootstrap(d, cfg, method='stationary', n=1, params={'L': 0.5}))",
    r"(cfg = bootstrap_config((us = "us", eu = "eu"), regime_index = "us", aux = (rate = "rate",),
  letfs = [(base = "eu", leverage = 2, finance = "rate", expense = 0.5), (base = "us", leverage = -1, finance = "rate", expense = 0.6)])
result = bootstrap(d, cfg, "stationary"; n = 1, params = (L = 0.5,)))", inp = ein("bootstrap/bs_err_L", c("d"))),
  zeile("bs_err_blc",
    r"(cfg <- bootstrap_config(c(us = 'us', eu = 'eu'), regime_index = 'us', aux = c(rate = 'rate'),
  letfs = list(list(base = 'eu', leverage = 2, finance = 'rate', expense = 0.5), list(base = 'us', leverage = -1, finance = 'rate', expense = 0.6)))
bootstrap(d, cfg, 'circular', n = 1, params = list(block_length = 2.5)))",
    r"(cfg = bootstrap_config({'us': 'us', 'eu': 'eu'}, regime_index='us', aux={'rate': 'rate'},
  letfs=[{'base': 'eu', 'leverage': 2, 'finance': 'rate', 'expense': 0.5}, {'base': 'us', 'leverage': -1, 'finance': 'rate', 'expense': 0.6}])
result = bootstrap(d, cfg, method='circular', n=1, params={'block_length': 2.5}))",
    r"(cfg = bootstrap_config((us = "us", eu = "eu"), regime_index = "us", aux = (rate = "rate",),
  letfs = [(base = "eu", leverage = 2, finance = "rate", expense = 0.5), (base = "us", leverage = -1, finance = "rate", expense = 0.6)])
result = bootstrap(d, cfg, "circular"; n = 1, params = (block_length = 2.5,)))", inp = ein("bootstrap/bs_err_blc", c("d"))),
  zeile("bs_err_wt",
    r"(cfg <- bootstrap_config(c(us = 'us', eu = 'eu'), regime_index = 'us', aux = c(rate = 'rate'),
  letfs = list(list(base = 'eu', leverage = 2, finance = 'rate', expense = 0.5), list(base = 'us', leverage = -1, finance = 'rate', expense = 0.6)))
bootstrap(d, cfg, 'wild', n = 1, params = list(wild_type = 3)))",
    r"(cfg = bootstrap_config({'us': 'us', 'eu': 'eu'}, regime_index='us', aux={'rate': 'rate'},
  letfs=[{'base': 'eu', 'leverage': 2, 'finance': 'rate', 'expense': 0.5}, {'base': 'us', 'leverage': -1, 'finance': 'rate', 'expense': 0.6}])
result = bootstrap(d, cfg, method='wild', n=1, params={'wild_type': 3}))",
    r"(cfg = bootstrap_config((us = "us", eu = "eu"), regime_index = "us", aux = (rate = "rate",),
  letfs = [(base = "eu", leverage = 2, finance = "rate", expense = 0.5), (base = "us", leverage = -1, finance = "rate", expense = 0.6)])
result = bootstrap(d, cfg, "wild"; n = 1, params = (wild_type = 3,)))", inp = ein("bootstrap/bs_err_wt", c("d"))),
  zeile("bs_err_pb",
    r"(cfg <- bootstrap_config(c(us = 'us', eu = 'eu'), regime_index = 'us', aux = c(rate = 'rate'),
  letfs = list(list(base = 'eu', leverage = 2, finance = 'rate', expense = 0.5), list(base = 'us', leverage = -1, finance = 'rate', expense = 0.6)))
bootstrap(d, cfg, 'reset', n = 1, params = list(p_break = 1.5)))",
    r"(cfg = bootstrap_config({'us': 'us', 'eu': 'eu'}, regime_index='us', aux={'rate': 'rate'},
  letfs=[{'base': 'eu', 'leverage': 2, 'finance': 'rate', 'expense': 0.5}, {'base': 'us', 'leverage': -1, 'finance': 'rate', 'expense': 0.6}])
result = bootstrap(d, cfg, method='reset', n=1, params={'p_break': 1.5}))",
    r"(cfg = bootstrap_config((us = "us", eu = "eu"), regime_index = "us", aux = (rate = "rate",),
  letfs = [(base = "eu", leverage = 2, finance = "rate", expense = 0.5), (base = "us", leverage = -1, finance = "rate", expense = 0.6)])
result = bootstrap(d, cfg, "reset"; n = 1, params = (p_break = 1.5,)))", inp = ein("bootstrap/bs_err_pb", c("d"))),
  zeile("bs_warn_prices",
    r"(b <- bootstrap(dp, bootstrap_config(c(us = 'us')), 'raw', n = 1, seed = 1, progress = FALSE, path_length = 3); b$paths)",
    r"(result = bootstrap(dp, bootstrap_config({'us': 'us'}), method='raw', n=1, seed=1, progress=False, path_length=3)['paths'])",
    r"(result = bootstrap(dp, bootstrap_config((us = "us",)), "raw"; n = 1, seed = 1, progress = false, path_length = 3)["paths"])", inp = ein("bootstrap/bs_warn_prices", c("dp")))))
TB(".fit_tail", "Meldungen und Warnungen von .fit_tail je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("fit_tail",
    r"(list(SimLev:::.fit_tail(d$us, 0.05, 'left'), SimLev:::.fit_tail(d$us, 0.05, 'right'), SimLev:::.fit_tail(d$us[1:150], 0.05, 'left'), SimLev:::.fit_tail(d$us[1:60], 0.05, 'left')))",
    r"(result = [B._fit_tail(d['us'].to_numpy(), 0.05, 'left'), B._fit_tail(d['us'].to_numpy(), 0.05, 'right'), B._fit_tail(d['us'].to_numpy()[:150], 0.05, 'left'), B._fit_tail(d['us'].to_numpy()[:60], 0.05, 'left')])",
    r"(result = [B._fit_tail(d.us, 0.05, "left"), B._fit_tail(d.us, 0.05, "right"), B._fit_tail(d.us[1:150], 0.05, "left"), B._fit_tail(d.us[1:60], 0.05, "left")])", inp = ein("bootstrap/fit_tail", c("d")))))
TB("bootstrap_validate", "Meldungen und Warnungen von bootstrap_validate je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("vb_minrows",
    r"(b <- bootstrap(d, bootstrap_config(c(us = 'us')), 'stationary', n = 4, params = list(L = 20), seed = 1, progress = FALSE, path_length = 20)
bootstrap_validate(b, min_rows = 30))",
    r"(b = bootstrap(d, bootstrap_config({'us': 'us'}), method='stationary', n=4, params={'L': 20}, seed=1, progress=False, path_length=20)
result = bootstrap_validate(b, min_rows=30))",
    r"(b = bootstrap(d, bootstrap_config((us = "us",)), "stationary"; n = 4, params = (L = 20,), seed = 1, progress = false, path_length = 20)
result = bootstrap_validate(b; min_rows = 30))", inp = ein("bootstrap/vb_minrows", c("d"))),
  zeile("vb_err_class",
    r"(bootstrap_validate(list(paths = list())))",
    r"(result = bootstrap_validate({'paths': []}))",
    r"(result = bootstrap_validate((paths = [],)))", inp = ein("bootstrap/vb_err_class", c())),
  zeile("vb_err_empty",
    r"(b <- bootstrap(d, bootstrap_config(c(us = 'us')), 'stationary', n = 4, params = list(L = 20), seed = 1, progress = FALSE, path_length = 20)
b$paths <- list(); bootstrap_validate(b))",
    r"(b = bootstrap(d, bootstrap_config({'us': 'us'}), method='stationary', n=4, params={'L': 20}, seed=1, progress=False, path_length=20)
b['paths'] = []; result = bootstrap_validate(b))",
    r"(b = bootstrap(d, bootstrap_config((us = "us",)), "stationary"; n = 4, params = (L = 20,), seed = 1, progress = false, path_length = 20)
b["paths"] = []; result = bootstrap_validate(b))", inp = ein("bootstrap/vb_err_empty", c("d")))))
TB("bootstrap_data", "Meldungen und Warnungen von bootstrap_data je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("bd_err_len",
    r"(cfg <- bootstrap_config(c(us = 'us', eu = 'eu'), regime_index = 'us', aux = c(rate = 'rate'),
  letfs = list(list(base = 'eu', leverage = 2, finance = 'rate', expense = 0.5), list(base = 'us', leverage = -1, finance = 'rate', expense = 0.6)))
b <- bootstrap(d, cfg, 'stationary', n = 2, params = list(L = 20), seed = 1, progress = FALSE, path_length = 8)
bootstrap_data(b, dates = as.Date('2001-01-01') + 0:3))",
    r"(cfg = bootstrap_config({'us': 'us', 'eu': 'eu'}, regime_index='us', aux={'rate': 'rate'},
  letfs=[{'base': 'eu', 'leverage': 2, 'finance': 'rate', 'expense': 0.5}, {'base': 'us', 'leverage': -1, 'finance': 'rate', 'expense': 0.6}])
b = bootstrap(d, cfg, method='stationary', n=2, params={'L': 20}, seed=1, progress=False, path_length=8)
result = bootstrap_data(b, dates=np.datetime64('2001-01-01') + np.arange(4)))",
    r"(cfg = bootstrap_config((us = "us", eu = "eu"), regime_index = "us", aux = (rate = "rate",),
  letfs = [(base = "eu", leverage = 2, finance = "rate", expense = 0.5), (base = "us", leverage = -1, finance = "rate", expense = 0.6)])
b = bootstrap(d, cfg, "stationary"; n = 2, params = (L = 20,), seed = 1, progress = false, path_length = 8)
result = bootstrap_data(b; dates = Date(2001, 1, 1) .+ Day.(0:3)))", inp = ein("bootstrap/bd_err_len", c("d"))),
  zeile("bd_err_matrix",
    r"(bootstrap_data(matrix(1:4, 2, dimnames = list(NULL, c('a', 'b')))))",
    r"(result = bootstrap_data(pd.DataFrame({'a': [1, 2], 'b': [3, 4]})))",
    r"(result = bootstrap_data(SL.NamedMat([1.0 3; 2 4]; colnames = ["a", "b"])))", inp = ein("bootstrap/bd_err_matrix", c()))))
TB("bootstrap_study", "Meldungen und Warnungen von bootstrap_study je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("study_err_method",   # seit 1.6.4 (K43 RS B3, Meldung mit Funktionsnamen, Entscheidung 155)
    r"(bootstrap_study(data.frame(a = 1 + sin(1:50) / 100), bootstrap_config(c(a = 'a')), method = 'zz', strategies = list(s = create_strategy(a = asset_config('etf')))))",
    r"(result = bootstrap_study(pd.DataFrame({'a': 1 + np.sin(np.arange(1, 51)) / 100}), bootstrap_config({'a': 'a'}), method='zz', strategies={'s': simlev.create_strategy(a=simlev.asset_config(asset_class='etf'))}))",
    r"(result = bootstrap_study(RFrame("a" => 1 .+ sin.(1:50) ./ 100), bootstrap_config(Dict("a" => "a")); method = "zz", strategies = RList("s" => create_strategy(a = asset_config("etf")))))", inp = list()),
  zeile("study_err_empty",   # seit 1.6.4 (K43 RS B3, Meldung mit Funktionsnamen, Entscheidung 155)
    r"(bootstrap_study(data.frame(a = numeric(0)), bootstrap_config(c(a = 'a')), strategies = list(s = create_strategy(a = asset_config('etf')))))",
    r"(result = bootstrap_study(pd.DataFrame({'a': np.array([], dtype=float)}), bootstrap_config({'a': 'a'}), strategies={'s': simlev.create_strategy(a=simlev.asset_config(asset_class='etf'))}))",
    r"(result = bootstrap_study(RFrame("a" => Float64[]), bootstrap_config(Dict("a" => "a")); strategies = RList("s" => create_strategy(a = asset_config("etf")))))", inp = list()),
  zeile("study_err_col",   # seit 1.6.4 (K43 RS B3, Meldung mit Funktionsnamen, Entscheidung 155)
    r"(bootstrap_study(data.frame(a = 1 + sin(1:50) / 100), bootstrap_config(c(b = 'b')), strategies = list(s = create_strategy(a = asset_config('etf')))))",
    r"(result = bootstrap_study(pd.DataFrame({'a': 1 + np.sin(np.arange(1, 51)) / 100}), bootstrap_config({'b': 'b'}), strategies={'s': simlev.create_strategy(a=simlev.asset_config(asset_class='etf'))}))",
    r"(result = bootstrap_study(RFrame("a" => 1 .+ sin.(1:50) ./ 100), bootstrap_config(Dict("b" => "b")); strategies = RList("s" => create_strategy(a = asset_config("etf")))))", inp = list()),
  zeile("study_errfail",
    r"(bootstrap_study(ds, bootstrap_config(c(akt = 'aktien'), input = 'prices'), 'raw', n = 2, path_length = 100, seed = 1, progress = FALSE, strategies = list(sig = list(strategy = create_strategy(akt = asset_config('etf', 'signal', signal_buy = 'b', signal_sell = 's', spread = 0.1)), signal = function(df) stop('Spalte fehlt')))))",
    r"(def bad(df):
    raise ValueError('Spalte fehlt')
result = bootstrap_study(ds, bootstrap_config({'akt': 'aktien'}, input='prices'), 'raw', n=2, path_length=100, seed=1, progress=False, strategies={'sig': {'strategy': simlev.create_strategy(akt=simlev.asset_config(asset_class='etf', trading='signal', signal_buy='b', signal_sell='s', spread=0.1)), 'signal': bad}}))",
    r"(bad(df) = error("Spalte fehlt"); result = bootstrap_study(ds, bootstrap_config((akt = "aktien",), input = "prices"), "raw"; n = 2, path_length = 100, seed = 1, progress = false, strategies = (sig = (strategy = create_strategy(akt = asset_config("etf", "signal", signal_buy = "b", signal_sell = "s", spread = 0.1)), signal = bad),)))", inp = ein("bootstrap/study_errfail", c("ds"))),
  zeile("study_partial",
    r"(st <- bootstrap_study(ds, bootstrap_config(c(akt = 'aktien'), input = 'prices'), 'raw', n = 2, path_length = 100, seed = 1, progress = FALSE, strategies = list(ok = create_strategy(akt = asset_config('etf', 'bnh', spread = 0.1)), kaputt = list(strategy = create_strategy(akt = asset_config('etf', 'bnh', spread = 0.1)), signal = function(df) NULL), w = list(strategy = create_strategy(akt = asset_config('etf', 'bnh', spread = 0.1)), signal = function(df) { warning('Achtung'); warning('Achtung'); list(x = df$akt > 100) }))); st$elapsed <- 0; list(st$results, st$errors, st$warnings))",
    r"(def wsig(df):
    import warnings as _w
    _w.warn('Achtung'); _w.warn('Achtung')
    return {'x': df['akt'].to_numpy() > 100}
st = bootstrap_study(ds, bootstrap_config({'akt': 'aktien'}, input='prices'), 'raw', n=2, path_length=100, seed=1, progress=False, strategies={'ok': simlev.create_strategy(akt=simlev.asset_config(asset_class='etf', trading='bnh', spread=0.1)), 'kaputt': {'strategy': simlev.create_strategy(akt=simlev.asset_config(asset_class='etf', trading='bnh', spread=0.1)), 'signal': lambda df: None}, 'w': {'strategy': simlev.create_strategy(akt=simlev.asset_config(asset_class='etf', trading='bnh', spread=0.1)), 'signal': wsig}}); result = [st['results'], st['errors'], st['warnings']])",
    r"(function wsig(df)
    @warn "Achtung"; @warn "Achtung"
    (x = df["akt"] .> 100,)
end
st = bootstrap_study(ds, bootstrap_config((akt = "aktien",), input = "prices"), "raw"; n = 2, path_length = 100, seed = 1, progress = false, strategies = (ok = create_strategy(akt = asset_config("etf", "bnh", spread = 0.1)), kaputt = (strategy = create_strategy(akt = asset_config("etf", "bnh", spread = 0.1)), signal = df -> nothing), w = (strategy = create_strategy(akt = asset_config("etf", "bnh", spread = 0.1)), signal = wsig))); result = [st["results"], st["errors"], st["warnings"]])", inp = ein("bootstrap/study_partial", c("ds"))),
  zeile("study_unused",
    r"(bootstrap_study(ds, bootstrap_config(c(akt = 'aktien'), input = 'prices'), 'raw', n = 2, path_length = 100, seed = 1, progress = FALSE, sim_args = list(taxmode = 'person'), strategies = list(bnh = create_strategy(akt = asset_config('etf', 'bnh', spread = 0.1)))))",
    r"(result = bootstrap_study(ds, bootstrap_config({'akt': 'aktien'}, input='prices'), 'raw', n=2, path_length=100, seed=1, progress=False, sim_args={'taxmode': 'person'}, strategies={'bnh': simlev.create_strategy(akt=simlev.asset_config(asset_class='etf', trading='bnh', spread=0.1))}))",
    r"(result = bootstrap_study(ds, bootstrap_config((akt = "aktien",), input = "prices"), "raw"; n = 2, path_length = 100, seed = 1, progress = false, sim_args = (taxmode = "person",), strategies = (bnh = create_strategy(akt = asset_config("etf", "bnh", spread = 0.1)),)))", inp = ein("bootstrap/study_unused", c("ds"))),
  zeile("study_err_nostrat",
    r"(cfgs <- bootstrap_config(c(akt = 'aktien'), aux = c(zins = 'zins'), input = 'prices', letfs = list(list(base = 'akt', leverage = 2, finance = 'zins', expense = 0.6)))
sma <- function(df, k = 30) { s <- stats::filter(df$akt_l2, rep(1 / k, k), sides = 1); list(buy = df$akt_l2 >= s, sell = df$akt_l2 < s) }
strats <- list(bnh = create_strategy(akt_l2 = asset_config('etf', 'bnh', partial_exemption = 30, spread = 0.1)),
  sma = list(strategy = create_strategy(letf = asset_config('etf', 'signal', partial_exemption = 30, signal_buy = 'buy', signal_sell = 'sell', spread = 0.1)), signal = sma, map = c(letf = 'akt_l2')))
bootstrap_study(ds, cfgs, n = 2))",
    r"(cfgs = bootstrap_config({'akt': 'aktien'}, aux={'zins': 'zins'}, input='prices', letfs=[{'base': 'akt', 'leverage': 2, 'finance': 'zins', 'expense': 0.6}])
def _filt(x, k):
    x = np.asarray(x, dtype=float); f = 1.0 / k; out = np.full(len(x), simlev._r.fmt.NA_REAL)
    for i in range(k - 1, len(x)):
        z = 0.0
        for j in range(k):
            z += f * x[i - j]
        out[i] = z
    return out
def sma(df, k=30):
    s = _filt(df['akt_l2'], k); v = df['akt_l2'].to_numpy()
    with np.errstate(invalid='ignore'):
        return {'buy': v >= s, 'sell': v < s}
strats = {'bnh': simlev.create_strategy(akt_l2=simlev.asset_config(asset_class='etf', trading='bnh', partial_exemption=30, spread=0.1)),
  'sma': {'strategy': simlev.create_strategy(letf=simlev.asset_config(asset_class='etf', trading='signal', partial_exemption=30, signal_buy='buy', signal_sell='sell', spread=0.1)), 'signal': sma, 'map': {'letf': 'akt_l2'}}}
result = bootstrap_study(ds, cfgs, n=2))",
    r"(cfgs = bootstrap_config((akt = "aktien",), aux = (zins = "zins",), input = "prices", letfs = [(base = "akt", leverage = 2, finance = "zins", expense = 0.6)])
function sma(df; k = 30)
    x = df["akt_l2"]; s = fill(SL.NA, length(x))
    for i in k:length(x)
        z = 0.0
        for j in 0:k-1
            z += (1 / k) * x[i - j]
        end
        s[i] = z
    end
    (buy = x .>= s, sell = x .< s)
end
strats = (bnh = create_strategy(akt_l2 = asset_config("etf", "bnh", partial_exemption = 30, spread = 0.1)),
  sma = (strategy = create_strategy(letf = asset_config("etf", "signal", partial_exemption = 30, signal_buy = "buy", signal_sell = "sell", spread = 0.1)), signal = sma, map = (letf = "akt_l2",)))
result = bootstrap_study(ds, cfgs; n = 2))", inp = ein("bootstrap/study_err_nostrat", c("ds"))),
  zeile("study_err_bench",
    r"(cfgs <- bootstrap_config(c(akt = 'aktien'), aux = c(zins = 'zins'), input = 'prices', letfs = list(list(base = 'akt', leverage = 2, finance = 'zins', expense = 0.6)))
sma <- function(df, k = 30) { s <- stats::filter(df$akt_l2, rep(1 / k, k), sides = 1); list(buy = df$akt_l2 >= s, sell = df$akt_l2 < s) }
strats <- list(bnh = create_strategy(akt_l2 = asset_config('etf', 'bnh', partial_exemption = 30, spread = 0.1)),
  sma = list(strategy = create_strategy(letf = asset_config('etf', 'signal', partial_exemption = 30, signal_buy = 'buy', signal_sell = 'sell', spread = 0.1)), signal = sma, map = c(letf = 'akt_l2')))
bootstrap_study(ds, cfgs, n = 2, strategies = strats, benchmark = 'x'))",
    r"(cfgs = bootstrap_config({'akt': 'aktien'}, aux={'zins': 'zins'}, input='prices', letfs=[{'base': 'akt', 'leverage': 2, 'finance': 'zins', 'expense': 0.6}])
def _filt(x, k):
    x = np.asarray(x, dtype=float); f = 1.0 / k; out = np.full(len(x), simlev._r.fmt.NA_REAL)
    for i in range(k - 1, len(x)):
        z = 0.0
        for j in range(k):
            z += f * x[i - j]
        out[i] = z
    return out
def sma(df, k=30):
    s = _filt(df['akt_l2'], k); v = df['akt_l2'].to_numpy()
    with np.errstate(invalid='ignore'):
        return {'buy': v >= s, 'sell': v < s}
strats = {'bnh': simlev.create_strategy(akt_l2=simlev.asset_config(asset_class='etf', trading='bnh', partial_exemption=30, spread=0.1)),
  'sma': {'strategy': simlev.create_strategy(letf=simlev.asset_config(asset_class='etf', trading='signal', partial_exemption=30, signal_buy='buy', signal_sell='sell', spread=0.1)), 'signal': sma, 'map': {'letf': 'akt_l2'}}}
result = bootstrap_study(ds, cfgs, n=2, strategies=strats, benchmark='x'))",
    r"(cfgs = bootstrap_config((akt = "aktien",), aux = (zins = "zins",), input = "prices", letfs = [(base = "akt", leverage = 2, finance = "zins", expense = 0.6)])
function sma(df; k = 30)
    x = df["akt_l2"]; s = fill(SL.NA, length(x))
    for i in k:length(x)
        z = 0.0
        for j in 0:k-1
            z += (1 / k) * x[i - j]
        end
        s[i] = z
    end
    (buy = x .>= s, sell = x .< s)
end
strats = (bnh = create_strategy(akt_l2 = asset_config("etf", "bnh", partial_exemption = 30, spread = 0.1)),
  sma = (strategy = create_strategy(letf = asset_config("etf", "signal", partial_exemption = 30, signal_buy = "buy", signal_sell = "sell", spread = 0.1)), signal = sma, map = (letf = "akt_l2",)))
result = bootstrap_study(ds, cfgs; n = 2, strategies = strats, benchmark = "x"))", inp = ein("bootstrap/study_err_bench", c("ds"))),
  zeile("study_err_keepaux",
    r"(cfgs <- bootstrap_config(c(akt = 'aktien'), aux = c(zins = 'zins'), input = 'prices', letfs = list(list(base = 'akt', leverage = 2, finance = 'zins', expense = 0.6)))
sma <- function(df, k = 30) { s <- stats::filter(df$akt_l2, rep(1 / k, k), sides = 1); list(buy = df$akt_l2 >= s, sell = df$akt_l2 < s) }
strats <- list(bnh = create_strategy(akt_l2 = asset_config('etf', 'bnh', partial_exemption = 30, spread = 0.1)),
  sma = list(strategy = create_strategy(letf = asset_config('etf', 'signal', partial_exemption = 30, signal_buy = 'buy', signal_sell = 'sell', spread = 0.1)), signal = sma, map = c(letf = 'akt_l2')))
bootstrap_study(ds, cfgs, n = 2, strategies = strats, keep_aux = 'cpi'))",
    r"(cfgs = bootstrap_config({'akt': 'aktien'}, aux={'zins': 'zins'}, input='prices', letfs=[{'base': 'akt', 'leverage': 2, 'finance': 'zins', 'expense': 0.6}])
def _filt(x, k):
    x = np.asarray(x, dtype=float); f = 1.0 / k; out = np.full(len(x), simlev._r.fmt.NA_REAL)
    for i in range(k - 1, len(x)):
        z = 0.0
        for j in range(k):
            z += f * x[i - j]
        out[i] = z
    return out
def sma(df, k=30):
    s = _filt(df['akt_l2'], k); v = df['akt_l2'].to_numpy()
    with np.errstate(invalid='ignore'):
        return {'buy': v >= s, 'sell': v < s}
strats = {'bnh': simlev.create_strategy(akt_l2=simlev.asset_config(asset_class='etf', trading='bnh', partial_exemption=30, spread=0.1)),
  'sma': {'strategy': simlev.create_strategy(letf=simlev.asset_config(asset_class='etf', trading='signal', partial_exemption=30, signal_buy='buy', signal_sell='sell', spread=0.1)), 'signal': sma, 'map': {'letf': 'akt_l2'}}}
result = bootstrap_study(ds, cfgs, n=2, strategies=strats, keep_aux='cpi'))",
    r"(cfgs = bootstrap_config((akt = "aktien",), aux = (zins = "zins",), input = "prices", letfs = [(base = "akt", leverage = 2, finance = "zins", expense = 0.6)])
function sma(df; k = 30)
    x = df["akt_l2"]; s = fill(SL.NA, length(x))
    for i in k:length(x)
        z = 0.0
        for j in 0:k-1
            z += (1 / k) * x[i - j]
        end
        s[i] = z
    end
    (buy = x .>= s, sell = x .< s)
end
strats = (bnh = create_strategy(akt_l2 = asset_config("etf", "bnh", partial_exemption = 30, spread = 0.1)),
  sma = (strategy = create_strategy(letf = asset_config("etf", "signal", partial_exemption = 30, signal_buy = "buy", signal_sell = "sell", spread = 0.1)), signal = sma, map = (letf = "akt_l2",)))
result = bootstrap_study(ds, cfgs; n = 2, strategies = strats, keep_aux = "cpi"))", inp = ein("bootstrap/study_err_keepaux", c("ds"))),
  zeile("study_err_burnin",
    r"(cfgs <- bootstrap_config(c(akt = 'aktien'), aux = c(zins = 'zins'), input = 'prices', letfs = list(list(base = 'akt', leverage = 2, finance = 'zins', expense = 0.6)))
sma <- function(df, k = 30) { s <- stats::filter(df$akt_l2, rep(1 / k, k), sides = 1); list(buy = df$akt_l2 >= s, sell = df$akt_l2 < s) }
strats <- list(bnh = create_strategy(akt_l2 = asset_config('etf', 'bnh', partial_exemption = 30, spread = 0.1)),
  sma = list(strategy = create_strategy(letf = asset_config('etf', 'signal', partial_exemption = 30, signal_buy = 'buy', signal_sell = 'sell', spread = 0.1)), signal = sma, map = c(letf = 'akt_l2')))
bootstrap_study(ds, cfgs, n = 2, strategies = strats, path_length = 50, burn_in = 50))",
    r"(cfgs = bootstrap_config({'akt': 'aktien'}, aux={'zins': 'zins'}, input='prices', letfs=[{'base': 'akt', 'leverage': 2, 'finance': 'zins', 'expense': 0.6}])
def _filt(x, k):
    x = np.asarray(x, dtype=float); f = 1.0 / k; out = np.full(len(x), simlev._r.fmt.NA_REAL)
    for i in range(k - 1, len(x)):
        z = 0.0
        for j in range(k):
            z += f * x[i - j]
        out[i] = z
    return out
def sma(df, k=30):
    s = _filt(df['akt_l2'], k); v = df['akt_l2'].to_numpy()
    with np.errstate(invalid='ignore'):
        return {'buy': v >= s, 'sell': v < s}
strats = {'bnh': simlev.create_strategy(akt_l2=simlev.asset_config(asset_class='etf', trading='bnh', partial_exemption=30, spread=0.1)),
  'sma': {'strategy': simlev.create_strategy(letf=simlev.asset_config(asset_class='etf', trading='signal', partial_exemption=30, signal_buy='buy', signal_sell='sell', spread=0.1)), 'signal': sma, 'map': {'letf': 'akt_l2'}}}
result = bootstrap_study(ds, cfgs, n=2, strategies=strats, path_length=50, burn_in=50))",
    r"(cfgs = bootstrap_config((akt = "aktien",), aux = (zins = "zins",), input = "prices", letfs = [(base = "akt", leverage = 2, finance = "zins", expense = 0.6)])
function sma(df; k = 30)
    x = df["akt_l2"]; s = fill(SL.NA, length(x))
    for i in k:length(x)
        z = 0.0
        for j in 0:k-1
            z += (1 / k) * x[i - j]
        end
        s[i] = z
    end
    (buy = x .>= s, sell = x .< s)
end
strats = (bnh = create_strategy(akt_l2 = asset_config("etf", "bnh", partial_exemption = 30, spread = 0.1)),
  sma = (strategy = create_strategy(letf = asset_config("etf", "signal", partial_exemption = 30, signal_buy = "buy", signal_sell = "sell", spread = 0.1)), signal = sma, map = (letf = "akt_l2",)))
result = bootstrap_study(ds, cfgs; n = 2, strategies = strats, path_length = 50, burn_in = 50))", inp = ein("bootstrap/study_err_burnin", c("ds"))),
  zeile("study_err_dates",
    r"(cfgs <- bootstrap_config(c(akt = 'aktien'), aux = c(zins = 'zins'), input = 'prices', letfs = list(list(base = 'akt', leverage = 2, finance = 'zins', expense = 0.6)))
sma <- function(df, k = 30) { s <- stats::filter(df$akt_l2, rep(1 / k, k), sides = 1); list(buy = df$akt_l2 >= s, sell = df$akt_l2 < s) }
strats <- list(bnh = create_strategy(akt_l2 = asset_config('etf', 'bnh', partial_exemption = 30, spread = 0.1)),
  sma = list(strategy = create_strategy(letf = asset_config('etf', 'signal', partial_exemption = 30, signal_buy = 'buy', signal_sell = 'sell', spread = 0.1)), signal = sma, map = c(letf = 'akt_l2')))
bootstrap_study(ds, cfgs, n = 2, strategies = strats, path_length = 50, dates = as.Date('2001-01-01') + 0:10))",
    r"(cfgs = bootstrap_config({'akt': 'aktien'}, aux={'zins': 'zins'}, input='prices', letfs=[{'base': 'akt', 'leverage': 2, 'finance': 'zins', 'expense': 0.6}])
def _filt(x, k):
    x = np.asarray(x, dtype=float); f = 1.0 / k; out = np.full(len(x), simlev._r.fmt.NA_REAL)
    for i in range(k - 1, len(x)):
        z = 0.0
        for j in range(k):
            z += f * x[i - j]
        out[i] = z
    return out
def sma(df, k=30):
    s = _filt(df['akt_l2'], k); v = df['akt_l2'].to_numpy()
    with np.errstate(invalid='ignore'):
        return {'buy': v >= s, 'sell': v < s}
strats = {'bnh': simlev.create_strategy(akt_l2=simlev.asset_config(asset_class='etf', trading='bnh', partial_exemption=30, spread=0.1)),
  'sma': {'strategy': simlev.create_strategy(letf=simlev.asset_config(asset_class='etf', trading='signal', partial_exemption=30, signal_buy='buy', signal_sell='sell', spread=0.1)), 'signal': sma, 'map': {'letf': 'akt_l2'}}}
result = bootstrap_study(ds, cfgs, n=2, strategies=strats, path_length=50, dates=np.datetime64('2001-01-01') + np.arange(11)))",
    r"(cfgs = bootstrap_config((akt = "aktien",), aux = (zins = "zins",), input = "prices", letfs = [(base = "akt", leverage = 2, finance = "zins", expense = 0.6)])
function sma(df; k = 30)
    x = df["akt_l2"]; s = fill(SL.NA, length(x))
    for i in k:length(x)
        z = 0.0
        for j in 0:k-1
            z += (1 / k) * x[i - j]
        end
        s[i] = z
    end
    (buy = x .>= s, sell = x .< s)
end
strats = (bnh = create_strategy(akt_l2 = asset_config("etf", "bnh", partial_exemption = 30, spread = 0.1)),
  sma = (strategy = create_strategy(letf = asset_config("etf", "signal", partial_exemption = 30, signal_buy = "buy", signal_sell = "sell", spread = 0.1)), signal = sma, map = (letf = "akt_l2",)))
result = bootstrap_study(ds, cfgs; n = 2, strategies = strats, path_length = 50, dates = Date(2001, 1, 1) .+ Day.(0:10)))", inp = ein("bootstrap/study_err_dates", c("ds"))),
  zeile("study_err_short",
    r"(cfgs <- bootstrap_config(c(akt = 'aktien'), aux = c(zins = 'zins'), input = 'prices', letfs = list(list(base = 'akt', leverage = 2, finance = 'zins', expense = 0.6)))
sma <- function(df, k = 30) { s <- stats::filter(df$akt_l2, rep(1 / k, k), sides = 1); list(buy = df$akt_l2 >= s, sell = df$akt_l2 < s) }
strats <- list(bnh = create_strategy(akt_l2 = asset_config('etf', 'bnh', partial_exemption = 30, spread = 0.1)),
  sma = list(strategy = create_strategy(letf = asset_config('etf', 'signal', partial_exemption = 30, signal_buy = 'buy', signal_sell = 'sell', spread = 0.1)), signal = sma, map = c(letf = 'akt_l2')))
bootstrap_study(ds, cfgs, n = 2, strategies = strats, path_length = 300, keep_returns = 'year'))",
    r"(cfgs = bootstrap_config({'akt': 'aktien'}, aux={'zins': 'zins'}, input='prices', letfs=[{'base': 'akt', 'leverage': 2, 'finance': 'zins', 'expense': 0.6}])
def _filt(x, k):
    x = np.asarray(x, dtype=float); f = 1.0 / k; out = np.full(len(x), simlev._r.fmt.NA_REAL)
    for i in range(k - 1, len(x)):
        z = 0.0
        for j in range(k):
            z += f * x[i - j]
        out[i] = z
    return out
def sma(df, k=30):
    s = _filt(df['akt_l2'], k); v = df['akt_l2'].to_numpy()
    with np.errstate(invalid='ignore'):
        return {'buy': v >= s, 'sell': v < s}
strats = {'bnh': simlev.create_strategy(akt_l2=simlev.asset_config(asset_class='etf', trading='bnh', partial_exemption=30, spread=0.1)),
  'sma': {'strategy': simlev.create_strategy(letf=simlev.asset_config(asset_class='etf', trading='signal', partial_exemption=30, signal_buy='buy', signal_sell='sell', spread=0.1)), 'signal': sma, 'map': {'letf': 'akt_l2'}}}
result = bootstrap_study(ds, cfgs, n=2, strategies=strats, path_length=300, keep_returns='year'))",
    r"(cfgs = bootstrap_config((akt = "aktien",), aux = (zins = "zins",), input = "prices", letfs = [(base = "akt", leverage = 2, finance = "zins", expense = 0.6)])
function sma(df; k = 30)
    x = df["akt_l2"]; s = fill(SL.NA, length(x))
    for i in k:length(x)
        z = 0.0
        for j in 0:k-1
            z += (1 / k) * x[i - j]
        end
        s[i] = z
    end
    (buy = x .>= s, sell = x .< s)
end
strats = (bnh = create_strategy(akt_l2 = asset_config("etf", "bnh", partial_exemption = 30, spread = 0.1)),
  sma = (strategy = create_strategy(letf = asset_config("etf", "signal", partial_exemption = 30, signal_buy = "buy", signal_sell = "sell", spread = 0.1)), signal = sma, map = (letf = "akt_l2",)))
result = bootstrap_study(ds, cfgs; n = 2, strategies = strats, path_length = 300, keep_returns = "year"))", inp = ein("bootstrap/study_err_short", c("ds"))),
  zeile("study_err_keep_neg",
    r"(cfgb <- bootstrap_config(c(akt = 'aktien'), input = 'prices'); bnh <- create_strategy(akt = asset_config('etf', 'bnh', spread = 0.1))
bootstrap_study(ds, cfgb, 'raw', n = 2, path_length = 100, seed = 1, progress = FALSE, keep_paths = -1, strategies = list(b = bnh)))",
    r"(cfgb = bootstrap_config({'akt': 'aktien'}, input='prices'); bnh = simlev.create_strategy(akt=simlev.asset_config(asset_class='etf', trading='bnh', spread=0.1))
import tempfile, os
result = bootstrap_study(ds, cfgb, 'raw', n=2, path_length=100, seed=1, progress=False, keep_paths=-1, strategies={'b': bnh}))",
    r"(cfgb = bootstrap_config((akt = "aktien",), input = "prices"); bnh = create_strategy(akt = asset_config("etf", "bnh", spread = 0.1))
result = bootstrap_study(ds, cfgb, "raw"; n = 2, path_length = 100, seed = 1, progress = false, keep_paths = -1, strategies = (b = bnh,)))", inp = ein("bootstrap/study_err_keep_neg", c("ds"))),
  zeile("study_err_cores",   # Standard "auto"; ungültig -> Meldung par.cores (seit 1.6.4, Entscheidung 113)
    r"(cfgb <- bootstrap_config(c(akt = 'aktien'), input = 'prices'); bnh <- create_strategy(akt = asset_config('etf', 'bnh', spread = 0.1))
bootstrap_study(ds, cfgb, 'raw', n = 2, path_length = 100, seed = 1, progress = FALSE, cores = 0, strategies = list(b = bnh)))",
    r"(cfgb = bootstrap_config({'akt': 'aktien'}, input='prices'); bnh = simlev.create_strategy(akt=simlev.asset_config(asset_class='etf', trading='bnh', spread=0.1))
import tempfile, os
result = bootstrap_study(ds, cfgb, 'raw', n=2, path_length=100, seed=1, progress=False, cores=0, strategies={'b': bnh}))",
    r"(cfgb = bootstrap_config((akt = "aktien",), input = "prices"); bnh = create_strategy(akt = asset_config("etf", "bnh", spread = 0.1))
result = bootstrap_study(ds, cfgb, "raw"; n = 2, path_length = 100, seed = 1, progress = false, cores = 0, strategies = (b = bnh,)))", inp = ein("bootstrap/study_err_keep_neg", c("ds"))),
  zeile("study_err_chunk_alt",
    r"(cfgb <- bootstrap_config(c(akt = 'aktien'), input = 'prices'); bnh <- create_strategy(akt = asset_config('etf', 'bnh', spread = 0.1))
td <- tempfile(); dir.create(td); file.create(file.path(td, 'chunk_00001_seed2.rds'))
bootstrap_study(ds, cfgb, 'raw', n = 2, path_length = 100, seed = 2, chunk_dir = td, progress = FALSE, strategies = list(b = bnh)))",
    r"(cfgb = bootstrap_config({'akt': 'aktien'}, input='prices'); bnh = simlev.create_strategy(akt=simlev.asset_config(asset_class='etf', trading='bnh', spread=0.1))
import tempfile, os
td = tempfile.mkdtemp(); open(os.path.join(td, 'chunk_00001_seed2.rds'), 'w').close()
result = bootstrap_study(ds, cfgb, 'raw', n=2, path_length=100, seed=2, chunk_dir=td, progress=False, strategies={'b': bnh}))",
    r"(cfgb = bootstrap_config((akt = "aktien",), input = "prices"); bnh = create_strategy(akt = asset_config("etf", "bnh", spread = 0.1))
td = mktempdir(); touch(joinpath(td, "chunk_00001_seed2.rds"))
result = bootstrap_study(ds, cfgb, "raw"; n = 2, path_length = 100, seed = 2, chunk_dir = td, progress = false, strategies = (b = bnh,)))", inp = ein("bootstrap/study_err_keep_neg", c("ds"))),
  zeile("study_err_chunk_jl",   # Datei von Julia: fremd für R und Python (für Julia die eigene, leere Datei; seit 1.6.4 nur Python, T2-R15)
    r"(cfgb <- bootstrap_config(c(akt = 'aktien'), input = 'prices'); bnh <- create_strategy(akt = asset_config('etf', 'bnh', spread = 0.1))
td <- tempfile(); dir.create(td); file.create(file.path(td, 'chunk_00001_seed2_jl.bin'))
bootstrap_study(ds, cfgb, 'raw', n = 2, path_length = 100, seed = 2, chunk_dir = td, progress = FALSE, strategies = list(b = bnh)))",
    r"(cfgb = bootstrap_config({'akt': 'aktien'}, input='prices'); bnh = simlev.create_strategy(akt=simlev.asset_config(asset_class='etf', trading='bnh', spread=0.1))
import tempfile, os
td = tempfile.mkdtemp(); open(os.path.join(td, 'chunk_00001_seed2_jl.bin'), 'w').close()
result = bootstrap_study(ds, cfgb, 'raw', n=2, path_length=100, seed=2, chunk_dir=td, progress=False, strategies={'b': bnh}))",
    r"(cfgb = bootstrap_config((akt = "aktien",), input = "prices"); bnh = create_strategy(akt = asset_config("etf", "bnh", spread = 0.1))
td = mktempdir(); touch(joinpath(td, "chunk_00001_seed2_jl.bin"))
result = bootstrap_study(ds, cfgb, "raw"; n = 2, path_length = 100, seed = 2, chunk_dir = td, progress = false, strategies = (b = bnh,)))", inp = ein("bootstrap/study_err_keep_neg", c("ds")), nur = "py"),
  zeile("study_err_chunk_py",   # Datei von Python: fremd für R und Julia (seit 1.6.4, T2-R15)
    r"(cfgb <- bootstrap_config(c(akt = 'aktien'), input = 'prices'); bnh <- create_strategy(akt = asset_config('etf', 'bnh', spread = 0.1))
td <- tempfile(); dir.create(td); file.create(file.path(td, 'chunk_00001_seed2_py.pkl'))
bootstrap_study(ds, cfgb, 'raw', n = 2, path_length = 100, seed = 2, chunk_dir = td, progress = FALSE, strategies = list(b = bnh)))",
    r"(cfgb = bootstrap_config({'akt': 'aktien'}, input='prices'); bnh = simlev.create_strategy(akt=simlev.asset_config(asset_class='etf', trading='bnh', spread=0.1))
import tempfile, os
td = tempfile.mkdtemp(); open(os.path.join(td, 'chunk_00001_seed2_py.pkl'), 'w').close()
result = bootstrap_study(ds, cfgb, 'raw', n=2, path_length=100, seed=2, chunk_dir=td, progress=False, strategies={'b': bnh}))",
    r"(cfgb = bootstrap_config((akt = "aktien",), input = "prices"); bnh = create_strategy(akt = asset_config("etf", "bnh", spread = 0.1))
td = mktempdir(); touch(joinpath(td, "chunk_00001_seed2_py.pkl"))
result = bootstrap_study(ds, cfgb, "raw"; n = 2, path_length = 100, seed = 2, chunk_dir = td, progress = false, strategies = (b = bnh,)))", inp = ein("bootstrap/study_err_keep_neg", c("ds")), nur = "jl"),
  zeile("study_metrics_fail",
    r"(cfgb <- bootstrap_config(c(akt = 'aktien'), input = 'prices'); bnh <- create_strategy(akt = asset_config('etf', 'bnh', spread = 0.1))
bootstrap_study(ds, cfgb, 'raw', n = 2, path_length = 100, seed = 1, progress = FALSE, metrics = function(res) NULL, strategies = list(a = bnh)))",
    r"(cfgb = bootstrap_config({'akt': 'aktien'}, input='prices'); bnh = simlev.create_strategy(akt=simlev.asset_config(asset_class='etf', trading='bnh', spread=0.1))
import tempfile, os
result = bootstrap_study(ds, cfgb, 'raw', n=2, path_length=100, seed=1, progress=False, metrics=lambda res: None, strategies={'a': bnh}))",
    r"(cfgb = bootstrap_config((akt = "aktien",), input = "prices"); bnh = create_strategy(akt = asset_config("etf", "bnh", spread = 0.1))
result = bootstrap_study(ds, cfgb, "raw"; n = 2, path_length = 100, seed = 1, progress = false, metrics = res -> nothing, strategies = (a = bnh,)))", inp = ein("bootstrap/study_metrics_fail", c("ds"))),
  zeile("study_metrics_err",
    r"(cfgb <- bootstrap_config(c(akt = 'aktien'), input = 'prices'); bnh <- create_strategy(akt = asset_config('etf', 'bnh', spread = 0.1))
bootstrap_study(ds, cfgb, 'raw', n = 2, path_length = 100, seed = 1, progress = FALSE, metrics = function(res) stop('kaputt'), strategies = list(a = bnh)))",
    r"(cfgb = bootstrap_config({'akt': 'aktien'}, input='prices'); bnh = simlev.create_strategy(akt=simlev.asset_config(asset_class='etf', trading='bnh', spread=0.1))
import tempfile, os
def mf(res):
    raise ValueError('kaputt')
result = bootstrap_study(ds, cfgb, 'raw', n=2, path_length=100, seed=1, progress=False, metrics=mf, strategies={'a': bnh}))",
    r"(cfgb = bootstrap_config((akt = "aktien",), input = "prices"); bnh = create_strategy(akt = asset_config("etf", "bnh", spread = 0.1))
mf(res) = error("kaputt")
result = bootstrap_study(ds, cfgb, "raw"; n = 2, path_length = 100, seed = 1, progress = false, metrics = mf, strategies = (a = bnh,)))", inp = ein("bootstrap/study_metrics_err", c("ds"))),
  zeile("study_print_paired",
    r"(cfgb <- bootstrap_config(c(akt = 'aktien'), input = 'prices'); bnh <- create_strategy(akt = asset_config('etf', 'bnh', spread = 0.1))
st <- bootstrap_study(ds, cfgb, 'stationary', n = 3, params = list(L = 20), path_length = 150, seed = 6, progress = FALSE, benchmark = 'a', strategies = list(a = bnh, h = create_strategy(akt = asset_config('etf', 'bnh', share = 0.5, spread = 0.1)))); st$elapsed <- 2.25; st)",
    r"(cfgb = bootstrap_config({'akt': 'aktien'}, input='prices'); bnh = simlev.create_strategy(akt=simlev.asset_config(asset_class='etf', trading='bnh', spread=0.1))
import tempfile, os
st = bootstrap_study(ds, cfgb, 'stationary', n=3, params={'L': 20}, path_length=150, seed=6, progress=False, benchmark='a', strategies={'a': bnh, 'h': simlev.create_strategy(akt=simlev.asset_config(asset_class='etf', trading='bnh', share=0.5, spread=0.1))}); st['elapsed'] = 2.25; result = st)",
    r"(cfgb = bootstrap_config((akt = "aktien",), input = "prices"); bnh = create_strategy(akt = asset_config("etf", "bnh", spread = 0.1))
st = bootstrap_study(ds, cfgb, "stationary"; n = 3, params = (L = 20,), path_length = 150, seed = 6, progress = false, benchmark = "a", strategies = (a = bnh, h = create_strategy(akt = asset_config("etf", "bnh", share = 0.5, spread = 0.1)))); st["elapsed"] = 2.25; result = st)", print = TRUE, inp = ein("bootstrap/study_print_paired", c("ds")))))
TB("bootstrap_probability", "Meldungen und Warnungen von bootstrap_probability je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("prob_err",
    r"(bootstrap_probability(list(), cagr > 0))",
    r"(result = bootstrap_probability({}, 'cagr > 0'))",
    r"(result = bootstrap_probability((;), "cagr > 0"))", inp = ein("bootstrap/prob_err", c()))))
ref_done()

ref_schreiben()

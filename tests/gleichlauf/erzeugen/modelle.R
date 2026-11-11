# tests/gleichlauf/erzeugen/modelle.R – Bereich modelle als Szenarien und Tabellen (seit 1.4.2; bis 1.4.1 Einzelfälle je Modul und Funktion).
# Modelle: Regime (HMM), Abhängigkeit (Kendall, Copulas, DCC, Bedingungen, Quantilsregression, Tail-Regression,
# CoVaR, Teilmengen nach Regimen), Eingabeprüfungen (MS-GARCH nur Fehlerfälle).
#   gleichlauf  Szenarien: je Szenario ein Aufruf bzw. eine kurze Aufrufkette, die mehrere Ergebnisse zugleich prüft
#               (Teile; Name = bisherige Fallkennung). Feld note: "prüft: …"
#   fehler      je Funktion eine Tabelle "Eingabe -> Meldung" (jede Zeile ein eigener Aufruf)
#   ausgabe     print()/summary() als Tabelle
# Herkunft der Erwartung: R. Daten und Hilfen wie in tests/werkzeuge/breite/modelle.R (Breitenprüfung mit allen bisherigen Fällen).
# Aufruf (Repo-Wurzel): LC_ALL=C.UTF-8 R_LIBS=<R-Bibliothek mit SimLev> Rscript tests/gleichlauf/erzeugen/modelle.R
# Ausgabe tests/{gleichlauf,fehler,ausgabe}/faelle/modelle.jsonl.gz (Format: ref_tools.R, Szenarien: szenario_tools.R).
source("tests/gleichlauf/erzeugen/ref_tools.R"); source("tests/gleichlauf/erzeugen/szenario_tools.R")
ref_bereich("modelle")
EIN <- list()   # Eingaben je bisherigem Fall (Momentaufnahme an der Stelle, an der der Fall im alten Generator stand)

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# Modul ms_garch
# ════════════════════════════════════════════════════════════════════════════════════════════════════
P <- "from simlev import ms_garch as M\n"
J <- function(code) paste0("const M = SimLev.MsGarch\n", code)
# ── Daten (je n = 500 Tagesrenditen, Mittelwert ungefähr 0) ─────────────────
# Simulation eines MS-GJR-GARCH(1,1) mit parallelen Varianzpfaden je Regime
sim_msgjr <- function(n, om, al, ga, be, P, seed) {
  set.seed(seed); K <- length(om)
  hk <- om / (1 - al - ga / 2 - be); s <- 1L; y <- numeric(n)
  for (t in seq_len(n)) {
    if (t > 1) { s <- sample.int(K, 1, prob = P[s, ]); e <- y[t - 1]
      hk <- om + (al + ga * (e < 0)) * e^2 + be * hk }
    y[t] <- sqrt(hk[s]) * rnorm(1)
  }
  y
}
n <- 500
# garch1: ein Regime sGARCH(1,1) (wie die Testdaten in test-bootstrap.R)
set.seed(3); om <- 2e-6; al <- 0.08; be <- 0.9; s2 <- om / (1 - al - be); e <- numeric(n)
for (t in 1:n) { e[t] <- sqrt(s2) * rnorm(1); s2 <- om + al * e[t]^2 + be * s2 }
# sg3: drei Regime sGARCH; gjr2: zwei Regime GJR-GARCH
Y <- list(
  garch1 = 3e-4 + e,
  sg3 = sim_msgjr(n, c(1e-6, 4e-6, 2e-5), c(0.03, 0.05, 0.08), c(0, 0, 0), c(0.94, 0.90, 0.85),
                  matrix(c(0.99, 0.007, 0.003, 0.01, 0.98, 0.01, 0.005, 0.025, 0.97), 3, byrow = TRUE), 1),
  gjr2 = sim_msgjr(n, c(2e-6, 2e-5), c(0.02, 0.05), c(0.04, 0.10), c(0.92, 0.85),
                   matrix(c(0.99, 0.01, 0.03, 0.97), 2, byrow = TRUE), 7))
for (nm in names(Y)) for (K in 2:3) for (model in c("sGARCH", "gjrGARCH")) {
    EIN[[paste0("ms_garch/", sprintf("fit_%s_K%d_%s", nm, K, model))]] <- list(y = Y[[nm]])
}
# ── Fehlerwege der Prüfung (.ms_garch_check) ────────────────────────────────
I <- list(y = Y$gjr2[1:100])
errs <- list(
  err_egarch = c("2, 'eGARCH'", "2, 'eGARCH'", '2, "eGARCH"'),
  err_K1 = c("1, 'sGARCH'", "1, 'sGARCH'", '1, "sGARCH"'),
  err_K25 = c("2.5, 'sGARCH'", "2.5, 'sGARCH'", '2.5, "sGARCH"'),
  err_Kvec = c("c(2, 10), 'sGARCH'", "[2, 10], 'sGARCH'", '[2, 10], "sGARCH"'),
  err_modelNA = c("2, NA_character_", "2, None", "2, missing"))
for (k in names(errs)) {
    a <- errs[[k]]
    EIN[[paste0("ms_garch/", paste0("fit_", k))]] <- I
}

# Vorspann je Szenario bzw. Tabellenzeile (gemeinsame Objekte des Moduls)
VOR <- list(r = r"()",
            py = r"(from simlev import ms_garch as M)",
            jl = r"(const M = SimLev.MsGarch)")

ref_init("ms_garch", gruppe = "fehler")
TB(".ms_garch_fit", "Meldungen und Warnungen von .ms_garch_fit je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("fit_err_Kvec",
    r"(SimLev:::.ms_garch_fit(y, c(2, 10), 'sGARCH'))",
    r"(result = M._ms_garch_fit(y, [2, 10], 'sGARCH'))",
    r"(result = M._ms_garch_fit(y, [2, 10], "sGARCH"))", inp = ein("ms_garch/fit_err_Kvec", c("y"))),
  zeile("fit_err_modelNA",
    r"(SimLev:::.ms_garch_fit(y, 2, NA_character_))",
    r"(result = M._ms_garch_fit(y, 2, None))",
    r"(result = M._ms_garch_fit(y, 2, missing))", inp = ein("ms_garch/fit_err_modelNA", c("y")))))
ref_done()

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# Modul regimes
# ════════════════════════════════════════════════════════════════════════════════════════════════════
P <- "from simlev import _dependence_core as C\nfrom simlev import regimes as RG\n"
J <- 'C = SL.DependenceCore\nRG = SL.Regimes\n'
# ── Kerne und Hilfen ─────────────────────────────────────────────────────
set.seed(6); Tn <- 200; K <- 3
B <- matrix(runif(Tn * K, 0.1, 1), Tn); A <- matrix(runif(K * K), K); A <- A / rowSums(A); p0 <- rep(1 / K, K)
set.seed(2); Xl <- matrix(rnorm(60), 20); mu <- c(0.1, -0.2, 0.05); S <- crossprod(matrix(rnorm(9), 3)) + diag(3)
set.seed(3); VI <- list()
for (k in 2:4) {
  lB <- matrix(round(rnorm(200 * k), 1), 200, k)
  A <- matrix(runif(k * k), k); A[1, k] <- 0; A <- A / rowSums(A)
  VI[[paste0("lB", k)]] <- lB; VI[[paste0("A", k)]] <- A
}
VI$lBn <- VI$lB3; VI$lBn[50, 2] <- NaN; VI$lBn[60, ] <- NA
EIN[["regimes/viterbi"]] <- VI
# ── regime_hmm ───────────────────────────────────────────────────────────
set.seed(1); n <- 4 * 365
d <- data.frame(date = seq.Date(as.Date("2010-01-01"), by = "day", length.out = n))
vol <- rep(rep(c(0.006, 0.02), c(300, 150)), length.out = n)
d$aktien <- 100 * exp(cumsum(rnorm(n, 2e-4, vol)))
d$anleihen <- 100 * exp(cumsum(rnorm(n, 1e-4, vol / 3)))
d$aktien[c(20, 21, 500)] <- NA
H <- list(d = d)
# Bekannte Referenzwerte
set.seed(11); n <- 730   # bis 1.4.1 n <- 4 * 365 (kürzer, Abdeckung gleich)
d7 <- data.frame(date = seq.Date(as.Date("2010-01-01"), by = "day", length.out = n))
vol <- rep(rep(c(0.006, 0.02), c(300, 120)), length.out = n)
d7$a <- 100 * exp(cumsum(rnorm(n, 2e-4, vol))); d7$b <- 100 * exp(cumsum(rnorm(n, 1e-4, vol / 2)))
EIN[["regimes/hmm_err_k1"]] <- list(d = d[1:10, ])
EIN[["regimes/hmm_err_few"]] <- list(d = d[1:900, ])
df <- d[1:400, ]; df$flat <- 100
EIN[["regimes/hmm_err_flat"]] <- list(df = df)
# ── regime_states ────────────────────────────────────────────────────────
PH <- paste0(P, "hmm = RG.regime_hmm(d, 'aktien', k=2)\n")
JH <- paste0(J, 'hmm = RG.regime_hmm(d, "aktien"; k = 2)\n')
dq <- seq.Date(as.Date("2009-12-01"), as.Date("2014-03-01"), by = "week")
EIN[["regimes/states_smoothed"]] <- list(d = d, dq = dq)
EIN[["regimes/states_viterbi"]] <- list(d = d, dq = dq)
EIN[["regimes/states_err"]] <- list(d = d, dq = dq)

# Vorspann je Szenario bzw. Tabellenzeile (gemeinsame Objekte des Moduls)
VOR <- list(r = r"()",
            py = r"(from simlev import _dependence_core as C
from simlev import regimes as RG)",
            jl = r"(C = SL.DependenceCore
RG = SL.Regimes)")

ref_init("regimes", gruppe = "gleichlauf")
SZ("hmm_wochen", "regime_hmm mit zwei Regimen auf Wochenrenditen (Ergebnis, Druck, Grafikdaten)", vor = VOR, teile = list(
  hmm_week = teil(
    r"(regime_hmm(d, 'aktien', k = 2))",
    r"(result = RG.regime_hmm(d, 'aktien', k=2))",
    r"(result = RG.regime_hmm(d, "aktien"; k = 2))", druck = TRUE, inp = ein("regimes/hmm_week", c("d")))))
ref_done()

ref_init("regimes", gruppe = "fehler")
TB(".hmm_viterbi", "Meldungen und Warnungen von .hmm_viterbi je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("viterbi",
    r"(list(SimLev:::.hmm_viterbi(lB2, log(A2), log(rep(1/2, 2))), SimLev:::.hmm_viterbi(lB3, log(A3), log(rep(1/3, 3))), SimLev:::.hmm_viterbi(lB4, log(A4), log(rep(1/4, 4))),
  SimLev:::.hmm_viterbi(lB3, matrix(0, 3, 3), c(-Inf, 0, 0)), SimLev:::.hmm_viterbi(lBn, log(A3), log(rep(1/3, 3)))))",
    r"(L = simlev._r.libm.log
result = [RG._hmm_viterbi(lB2, L(A2), L(np.full(2, 1/2))), RG._hmm_viterbi(lB3, L(A3), L(np.full(3, 1/3))), RG._hmm_viterbi(lB4, L(A4), L(np.full(4, 1/4))),
  RG._hmm_viterbi(lB3, np.zeros((3, 3)), [-np.inf, 0, 0]), RG._hmm_viterbi(lBn, L(A3), L(np.full(3, 1/3)))])",
    r"(L(x) = SL.RLibm.log.(x)
result = [RG._hmm_viterbi(lB2, L(A2), L(fill(1/2, 2))), RG._hmm_viterbi(lB3, L(A3), L(fill(1/3, 3))), RG._hmm_viterbi(lB4, L(A4), L(fill(1/4, 4))),
  RG._hmm_viterbi(lB3, zeros(3, 3), [-Inf, 0, 0]), RG._hmm_viterbi(lBn, L(A3), L(fill(1/3, 3)))])", inp = ein("regimes/viterbi", c("lB2", "A2", "lB3", "A3", "lB4", "A4", "lBn")))))
TB("regime_hmm", "Meldungen und Warnungen von regime_hmm je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("hmm_err_k1",
    r"(regime_hmm(d, 'aktien', k = 1))",
    r"(result = RG.regime_hmm(d, 'aktien', k=1))",
    r"(result = RG.regime_hmm(d, "aktien"; k = 1))", inp = ein("regimes/hmm_err_k1", c("d"))),
  zeile("hmm_err_few",
    r"(regime_hmm(d, 'aktien', k = 3))",
    r"(result = RG.regime_hmm(d, 'aktien', k=3))",
    r"(result = RG.regime_hmm(d, "aktien"; k = 3))", inp = ein("regimes/hmm_err_few", c("d"))),
  zeile("hmm_err_flat",
    r"(regime_hmm(df, c('aktien', 'flat'), frequency = 'day'))",
    r"(result = RG.regime_hmm(df, ['aktien', 'flat'], frequency='day'))",
    r"(result = RG.regime_hmm(df, ["aktien", "flat"]; frequency = "day"))", inp = ein("regimes/hmm_err_flat", c("df"))),
  zeile("states_smoothed",
    r"(hmm <- regime_hmm(d, 'aktien', k = 2); list(regime_states(hmm, dq, 'smoothed'), regime_states(hmm, format(dq), 'smoothed', 'probability')))",
    r"(hmm = RG.regime_hmm(d, 'aktien', k=2)
result = [RG.regime_states(hmm, dq, type='smoothed'), RG.regime_states(hmm, [str(v) for v in dq], type='smoothed', output='probability')])",
    r"(hmm = RG.regime_hmm(d, "aktien"; k = 2)
result = [RG.regime_states(hmm, dq; type = "smoothed"), RG.regime_states(hmm, Dates.format.(dq, "yyyy-mm-dd"); type = "smoothed", output = "probability")])", inp = ein("regimes/states_smoothed", c("d", "dq"))),
  zeile("states_viterbi",
    r"(hmm <- regime_hmm(d, 'aktien', k = 2); regime_states(hmm, data.frame(date = dq), 'viterbi'))",
    r"(hmm = RG.regime_hmm(d, 'aktien', k=2)
result = RG.regime_states(hmm, pd.DataFrame({'date': dq}), type='viterbi'))",
    r"(hmm = RG.regime_hmm(d, "aktien"; k = 2)
result = RG.regime_states(hmm, SL.RFrame("date" => dq); type = "viterbi"))", inp = ein("regimes/states_viterbi", c("d", "dq"))),
  zeile("states_err",
    r"(hmm <- regime_hmm(d, 'aktien', k = 2); regime_states(hmm, dq, 'viterbi', 'probability'))",
    r"(hmm = RG.regime_hmm(d, 'aktien', k=2)
result = RG.regime_states(hmm, dq, type='viterbi', output='probability'))",
    r"(hmm = RG.regime_hmm(d, "aktien"; k = 2)
result = RG.regime_states(hmm, dq; type = "viterbi", output = "probability"))", inp = ein("regimes/states_err", c("d", "dq")))))
ref_done()

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# Modul dependence
# ════════════════════════════════════════════════════════════════════════════════════════════════════
`%||%` <- function(a, b) if (is.null(a)) b else a
P <- "from simlev import _dependence_core as C\nfrom simlev import dependence as D\n"
J <- 'D = SL.Dependence\nC = SL.DependenceCore\nsub(m, r, c) = SL.NamedMat(m.data[r, c]; colnames = m.colnames[c])\n'
qcase <- function(id, specs) {
    inp <- list()
    rc <- character(0)
    pc <- character(0)
    jc <- character(0)
    for (i in seq_along(specs)) {
        s <- specs[[i]]
        b0 <- s$b0 %||% qr.coef(qr(s$X), s$y)
        sc <- s$sc %||% max(sd(s$y), 1e-12)
        inp[[paste0("y", i)]] <- s$y
        inp[[paste0("X", i)]] <- s$X
        inp[[paste0("b", i)]] <- as.numeric(b0)
        inp[[paste0("s", i)]] <- sc
        mi <- s$maxit %||% 2000L
        rc <- c(rc, sprintf("{b <- SimLev:::.quantile_reg_core(y%d, X%d, %.17g, b%d, s%d, 1e-10, %dL); list(beta = as.numeric(b), optimal = attr(b, 'optimal'))}", 
            i, i, s$tau, i, i, mi))
        pc <- c(pc, sprintf("qrc(y%d, X%d, %.17g, b%d, s%d, %d)", i, i, s$tau, i, i, mi))
        jc <- c(jc, sprintf("qrc(y%d, X%d, %.17g, b%d, s%d, %d)", i, i, s$tau, i, i, mi))
    }
    EIN[[paste0("dependence/", id)]] <<- inp
}
PQ <- paste0(P, "def qrc(y, X, tau, b0, sc, maxit=2000):\n",
             "    y = np.atleast_1d(np.asarray(y, float)); X = np.asarray(X, float).reshape(len(y), -1)\n",
             "    b, o = C.quantile_reg_core(y, X, tau, np.atleast_1d(np.asarray(b0, float)), sc, 1e-10, maxit)\n",
             "    return {'beta': b, 'optimal': o}\n")
JQ <- paste0(J, "function qrc(y, X, tau, b0, sc, maxit = 2000)\n",
             "    y = y isa Real ? [Float64(y)] : Float64.(y); X = reshape(Float64.(X), length(y), :)\n",
             "    b, o = C.quantile_reg_core(y, X, tau, b0 isa Real ? [Float64(b0)] : Float64.(b0), sc, 1e-10, maxit)\n",
             "    return SL.RList(\"beta\" => b, \"optimal\" => o)\nend\n")
sp <- function(y, X, tau, b0 = NULL, sc = NULL, maxit = NULL) list(y = y, X = X, tau = tau, b0 = b0, sc = sc, maxit = maxit)
# ── Kerne ────────────────────────────────────────────────────────────────
set.seed(3)
K <- list()
for (n in c(5, 50, 800)) { x <- rnorm(n); y <- x + rnorm(n); K[[length(K) + 1]] <- list(x = x, y = y)
  K[[length(K) + 1]] <- list(x = round(x), y = round(y)) }
K[[length(K) + 1]] <- list(x = c(1, 1, 1, 2), y = c(3, 3, 3, 3))
K[[length(K) + 1]] <- list(x = 1, y = 2)
for (i in seq_along(K)) EIN[[paste0("dependence/", sprintf("kendall_core_%02d", i))]] <- K[[i]]
set.seed(7); M <- matrix(rnorm(300), ncol = 3, dimnames = list(NULL, c("a", "b", "c")))
Mt <- round(M * 2)
# NA in der letzten Spalte (seit 1.5.2): R 4.3.3 liest in cov_na_1 (stats/src/cov.c) für Kendall das nicht
# gesetzte xm[j] einer NA-Spalte j links von einer vollständigen Spalte; das gab zufällig "the standard deviation
# is zero". Mit der NA-Spalte rechts davon wird xm[j] nicht gelesen; Werte wie vorher (NA-Spalte, ein Paar gerechnet).
Mn <- M; Mn[5, 3] <- NA
EIN[["dependence/kendall_na"]] <- list(Mn = Mn)
# DCC-Filter. Seit 1.0.0 neu gefasst: der frühere Kern .dcc_filter (dependence_core.cpp) und seine Ports
# (Python _dependence_core, Julia DependenceCore) sind entfallen; dieselben Aufrufe über den
# slc-Filter (R .sl_dcc_filter, Python simlev._lib.dcc_filter, Julia SLib.dcc_filter).
set.seed(11); Z <- matrix(rnorm(600), 200); Z[, 2] <- 0.5 * Z[, 1] + Z[, 2]; Z[, 3] <- Z[, 3] - 0.3 * Z[, 1]
Qb <- cor(Z)
Qs <- matrix(c(1, 1, 1, 1), 2)
# Quantilsregressions-Kern
set.seed(5); n <- 300; x <- rnorm(n); y <- 0.4 * x + rt(n, 3); X <- cbind(1, x)
qcase("qr_core_t", lapply(c(0.01, 0.1, 0.5, 0.9, 0.99), function(tau) sp(y, X, tau)))
qcase("qr_core_int", list(sp(y, X[, 1, drop = FALSE], 0.3), sp(c(1, 2, 3, 4), matrix(1, 4, 1), 0.5), sp(c(1, 3, 3, 1, 2, 
    2), matrix(1, 6, 1), 0.5), sp(c(5, 1, 4, 2, 3, 3, 1), matrix(1, 7, 1), 0.2)))
set.seed(4); n <- 600; Xd <- cbind(1, matrix(sample(0:2, n * 3, TRUE), n)); yd <- sample(0:3, n, TRUE) + 0
qcase("qr_core_discrete", list(sp(yd, Xd, 0.05), sp(yd, Xd, 0.5), sp(yd, Xd, 0.8)))
for (s in 1:5) {
    set.seed(s)
    n <- 14
    Xs <- cbind(1, matrix(sample(0:1, n * 2, TRUE), n))
    ys <- sample(0:2, n, TRUE) + 0
    if (qr(Xs)$rank < 3) 
        next
    qcase(sprintf("qr_core_small%d", s), list(sp(ys, Xs, 0.1), sp(ys, Xs, 0.5), sp(ys, Xs, 0.8)))
}
set.seed(9); n <- 200; x <- rnorm(n); yy <- 1 + 2 * x + rnorm(n) * (1 + abs(x)); XX <- cbind(1, x, x^2)
qcase("qr_core_start", list(sp(yy, XX, 0.02, b0 = c(0, 0, 0)), sp(yy, XX, 0.97, b0 = c(5, -1, 2), sc = 0.1), sp(yy, XX, 0.5, 
    b0 = c(1, 2, 0))))
yr <- round(yy); Xr <- cbind(1, round(x, 1))
qcase("qr_core_round", list(sp(yr, Xr, 0.1), sp(yr, Xr, 0.5), sp(yr, Xr, 0.95), sp(c(yr, yr), rbind(Xr, Xr), 0.25)))
set.seed(12); n <- 120; xt <- sample(1:5, n, TRUE); yt <- xt + sample(c(-1, 0, 0, 1), n, TRUE)
qcase("qr_core_ties", list(sp(yt, cbind(1, xt), 0.5), sp(yt, cbind(1, xt), 0.3), sp(yt, cbind(1, xt), 0.9), sp(yt, cbind(1, 
    xt), 0.01)))
# kurze MM-Stufen: Austauschschritte und LP-Nachweis (auch gescheitert)
set.seed(21)
for (blk in 1:4) {
    specs <- list()
    for (r in 1:10) {
        n <- sample(8:60, 1)
        p <- sample(1:3, 1)
        disc <- runif(1) < 0.5
        X <- cbind(1, matrix(if (disc) 
            sample(0:2, n * (p - 1), TRUE) + 0
        else round(rnorm(n * (p - 1)), 1), n))
        y <- if (disc) 
            sample(0:3, n, TRUE) + 0
        else round(rt(n, 2), 1)
        if (qr(X)$rank < p) 
            next
        specs[[length(specs) + 1]] <- sp(y, X, sample(c(0.01, 0.03, 0.1, 0.5, 0.9, 0.97, 0.99), 1), maxit = sample(c(1L, 
            2L, 3L, 2000L), 1))
    }
    qcase(sprintf("qr_core_short%d", blk), specs)
}
qcase("qr_core_sing", list(sp(c(1, 2, 3), cbind(1, c(1, 1, 1)), 0.5, b0 = c(0, 0))))
# ── Daten ────────────────────────────────────────────────────────────────
mkdata <- function(seed = 1, n = 3 * 365, start = "2015-01-01") {
  set.seed(seed)
  d <- data.frame(date = seq.Date(as.Date(start), by = "day", length.out = n))
  infl <- 2 + cumsum(rnorm(n, 0, 0.05)); e1 <- rnorm(n); e2 <- rnorm(n); rho <- ifelse(infl > 2, 0.5, -0.3)
  d$stocks <- 100 * exp(cumsum(0.01 * e1))
  d$bonds <- 100 * exp(cumsum(0.005 * (rho * e1 + sqrt(1 - rho^2) * e2)))
  d$gold <- 100 * exp(cumsum(0.008 * rnorm(n) - 0.002 * e1))
  d$inflation <- infl
  d$zins <- round(1 + cumsum(rnorm(n, 0, 0.02)), 1)
  d$regime <- rep(rep(1:2, each = 200), length.out = n)
  d
}
d1 <- mkdata(1)
dna <- d1; dna$stocks[c(5, 6, 300)] <- NA; dna$bonds[1:3] <- NA; dna$inflation[c(10, 400)] <- NA
# Hilfen: Datumssortierung, Kursprüfung, Renditen
du <- d1[c(3, 1, 2, 4:40), c("date", "stocks")]
dm <- d1[1:20, 1:2]; dm$date[c(4, 9)] <- NA
EIN[["dependence/sort_dates_na"]] <- list(dm = dm)
dd <- d1[c(1:10, 3, 5, 5, 7), 1:2]
dd7 <- d1[c(1:10, 1:7), 1:2]
EIN[["dependence/check_prices_inf"]] <- list(d1 = d1[1:5, ])
for (fr in c("week", "month", "day")) EIN[[paste0("dependence/", paste0("returns_", fr))]] <- list(dna = dna)
dfl <- d1[1:200, c("date", "stocks", "bonds")]; dfl$stocks[50:60] <- dfl$stocks[50]; dfl$bonds[50:60] <- dfl$bonds[50]
EIN[["dependence/returns_err1"]] <- list(d1 = d1[1:5, ])
EIN[["dependence/returns_err2"]] <- list(d1 = d1[1:5, ])
dneg <- d1[1:50, 1:3]; dneg$bonds[20] <- -1
# Copula-Dichten und Tail-Koeffizienten
set.seed(2); uu <- runif(60); vv <- runif(60); uu[1] <- 1e-9; vv[2] <- 1 - 1e-9
fams <- list(list("gaussian", c(.5, NA)), list("gaussian", -0.9), list("t", c(-.4, 5)), list("t", c(0.7, 30)), list("clayton", 2),
             list("clayton_90", 1.5), list("clayton_180", 0.3), list("clayton_270", 1.5), list("gumbel", 1.8), list("gumbel_90", 1.2),
             list("gumbel_180", 2), list("gumbel_270", 3), list("frank", -4), list("frank", 1e-9), list("frank", 12), list("clayton", 1e-4))
for (i in seq_along(fams)) {
    f <- fams[[i]]
    EIN[[paste0("dependence/", sprintf("cop_%02d_%s", i, f[[1]]))]] <- list(uu = uu, vv = vv, p = f[[2]])
}
EIN[["dependence/cop_bad"]] <- list(uu = uu, vv = vv)
# copula_fit
set.seed(1); n <- 300
z <- matrix(rnorm(2 * n), ncol = 2) %*% chol(matrix(c(1, .6, .6, 1), 2)); w <- sqrt(rchisq(n, 4) / 4)
CX <- list(x = z[, 1] / w, y = z[, 2] / w, yn = -z[, 2])
set.seed(3); th <- 3; u <- runif(200); t <- runif(200); v <- ((t^(-th / (1 + th)) - 1) * u^(-th) + 1)^(-1 / th)
xna <- CX$x[1:60]; yna <- CX$y[1:60]; xna[c(3, 9)] <- NA; yna[20] <- Inf
EIN[["dependence/fitcop_err_len"]] <- list()
EIN[["dependence/fitcop_err_n"]] <- list()
EIN[["dependence/fitcop_err_fam"]] <- CX[c("x", "y")]
EIN[["dependence/fitcop_err_const"]] <- list()
# tail_dependence
set.seed(1); z0 <- rnorm(500); tx <- z0 + rnorm(500); ty <- z0 + rnorm(500)
txs <- tx[1:30]; tys <- round(ty[1:30]); txs[2] <- NaN
EIN[["dependence/tail_err_q2"]] <- list(tx = tx, ty = ty)
EIN[["dependence/tail_err_len"]] <- list()
EIN[["dependence/tail_err_n"]] <- list()
# DCC
set.seed(1); n <- 300
RR <- cbind(a = rnorm(n, 0, 0.01), b = rnorm(n, 0, 0.01), c = rnorm(n, 0, 0.012))
RR[, "b"] <- 0.5 * RR[, "a"] + sqrt(0.75) * RR[, "b"]
EIN[["dependence/dcc_fit3"]] <- list(RR = RR)
EIN[["dependence/dcc_err_n"]] <- list(RR = RR)
RC <- RR; RC[, "c"] <- 0.001
EIN[["dependence/dcc_err_const"]] <- list(RC = RC)
RS <- cbind(RR, d = RR[, "a"] * 2)
# Regime aus Zustandsvariablen
set.seed(5); cvx <- rnorm(200); cvd <- sample(1:2, 200, TRUE); cvd2 <- c(rep(0, 150), 1:50)
rg <- function(...) { r <- SimLev:::.dep_regimes(...); list(regime = as.character(r$regime), levels = levels(r$regime), breaks = r$breaks) }
JR <- paste0(J, "function rg(a...)\n    code, lab, br = D._dep_regimes(a...)\n    SL.RList(\"regime\" => Union{Missing,String}[c > 0 ? lab[c] : missing for c in code], \"levels\" => lab, \"breaks\" => br)\nend\n")
PR <- paste0(P, "def rg(*a):\n    code, lab, br = D._dep_regimes(*a)\n    return {'regime': [lab[c - 1] if c > 0 else None for c in code], 'levels': lab, 'breaks': br}\n")
EIN[["dependence/regimes_q"]] <- list(cvx = cvx, cvd = cvd, cvd2 = cvd2)
EIN[["dependence/regimes_breaks"]] <- list(cvx = cvx)
EIN[["dependence/regimes_err"]] <- list(cvx = cvx)
# .dep_reg_cor
set.seed(8); XR <- matrix(rnorm(300), 100); rk <- factor(sample(c("a", "b", "c"), 100, TRUE, prob = c(.45, .45, .1)), levels = c("a", "b", "c"))
XR[rk == "b", 2] <- 1
# dependence_analysis
DA <- list(d1 = d1)
d400 <- d1[1:420, ]
dsh <- d1[1:300, ]; dsh$inflation[1:200] <- NA
EIN[["dependence/da_warn"]] <- list(dsh = dsh)
EIN[["dependence/da_err1"]] <- list(d1 = d1[1:10, ])
EIN[["dependence/da_err2"]] <- list(d1 = d1[1:400, ])
# quantile_regression
set.seed(1); x <- rnorm(200); y <- 1 + 2 * x + rnorm(200) * (1 + abs(x)); x2 <- rnorm(200)
QI <- list(x = x, y = y, x2 = x2)
for (tv in list("0", "1", "c(0.1, 0.2)", "NA", "'a'")) EIN[[paste0("dependence/", sprintf("qreg_err_tau_%s", gsub("[^a-z0-9]", 
    "", tv)))]] <- QI
# Warnung (Optimalität nicht nachgewiesen) bei sehr kurzen MM-Stufen
set.seed(21); wq <- NULL
for (s in 1:400) { n <- sample(8:60, 1); p <- sample(1:3, 1); disc <- runif(1) < 0.5
  X <- matrix(if (disc) sample(0:2, n * (p - 1), TRUE) + 0 else round(rnorm(n * (p - 1)), 1), n)
  yy <- if (disc) sample(0:3, n, TRUE) + 0 else round(rt(n, 2), 1); tau <- sample(c(0.01, 0.03, 0.1, 0.5, 0.9, 0.97, 0.99), 1)
  if (qr(cbind(1, X))$rank < p) next
  w <- tryCatch({ quantile_regression(yy, X, tau, maxit = 1L); NULL }, warning = function(w) TRUE)
  if (isTRUE(w)) { wq <- list(yy = yy, X = X, tau = tau); break } }
if (!is.null(wq)) EIN[["dependence/qreg_warn"]] <- wq
EIN[["dependence/treg_multi"]] <- list(dna = dna)
dsp <- d1; dsp$event <- 0; dsp$event[c(100, 101, 102, 103, 104, 105, 106)] <- 1
EIN[["dependence/treg_fail"]] <- list(dsp = dsp)
EIN[["dependence/treg_err"]] <- list(d1 = d1[1:100, ])
# tail_covar
dp <- d1; dp$port <- 0.6 * dp$stocks / dp$stocks[1] + 0.4 * dp$bonds / dp$bonds[1]
EIN[["dependence/covar_basic"]] <- list(dp = dp)
# dependence_validate
set.seed(4); n <- 600   # bis 1.4.1 n <- 1200 (kürzer, Abdeckung gleich)
e <- matrix(rnorm(2 * n), ncol = 2) %*% chol(matrix(c(1, .5, .5, 1), 2))
h <- data.frame(us = exp(0.01 * e[, 1]), eu = exp(0.01 * e[, 2]), jp = exp(0.012 * rnorm(n)), infl = rep(c(1, 5, 1), c(400, 400, 400)))
cfg <- bootstrap_config(c(us = "us", eu = "eu"))
PB <- paste0(P, "from simlev import bootstrap as BS\n")
JB <- paste0(J, "BS = SL.Bootstrap\n")
EIN[["dependence/valdep"]] <- list(h = h)
EIN[["dependence/valdep_err1"]] <- list(h = h[1:5, ])
# regime_subset
rs <- function(...) { s <- regime_subset(...); list(data = s, episodes = attr(s, "episodes")) }
JS <- paste0(J, "rs(a...; k...) = (s = D.regime_subset(a...; k...); SL.RList(\"data\" => s, \"episodes\" => SL.attrs(s)[\"episodes\"]))\n")
PS <- paste0(P, "def rs(*a, **k):\n    s = D.regime_subset(*a, **k)\n    return {'data': s, 'episodes': s.attrs['episodes']}\n")
hs <- h[1:100, ]; hs$infl <- c(rep(1, 20), rep(5, 30), 1, 1, rep(5, 3), rep(1, 20), rep(5, 25))
hd <- d1[1:60, c("date", "stocks", "regime")]; lg <- c(rep(TRUE, 10), NA, rep(FALSE, 20), rep(TRUE, 29)); lg[45] <- NA
EIN[["dependence/rsub_date"]] <- list(hd = hd, lg = lg)
EIN[["dependence/rsub_err1"]] <- list(hs = hs)
EIN[["dependence/rsub_err2"]] <- list(hs = hs)
# regime_subset: Bedingungen in R-Syntax (gemeinsamer Auswerter, Modul rexpr)
hs2 <- hs; hs2$lbl <- ifelse(hs$infl > 3, "hoch", "tief")
RSX <- c("!infl < 4", "infl >= 4 & !is.na(us)", "infl %in% c(5)", "if (TRUE) infl > thr2 else FALSE", "as.character(infl > 4)",
         "infl > 4\n", "infl > 4 # Kommentar", "(us > 1) + (infl > 4) == 2L", "infl > c(1, 6)")
rsq <- function(x) paste0("'", gsub("\n", "\\n", x, fixed = TRUE), "'")
rsj <- function(x) paste0('"', gsub("\n", "\\n", x, fixed = TRUE), '"')
EIN[["dependence/rsub_rsyntax"]] <- list(hs = hs, hs2 = hs2)
for (k in seq_along(RSE <- c("infl >", "zz > 1", "infl[1] > 0", "infl > 2 &&& us", "lbl > 1"))) EIN[[paste0("dependence/", 
    sprintf("rsub_rs_err%d", k))]] <- list(hs = hs)

# Vorspann je Szenario bzw. Tabellenzeile (gemeinsame Objekte des Moduls)
VOR <- list(r = r"()",
            py = r"(from simlev import _dependence_core as C
from simlev import dependence as D)",
            jl = r"(D = SL.Dependence
C = SL.DependenceCore
sub(m, r, c) = SL.NamedMat(m.data[r, c]; colnames = m.colnames[c]))")

ref_init("dependence", gruppe = "gleichlauf")
SZ("kendall_und_copulas", ".kendall_tau_core, .kendall mit NA, Copula-Likelihood und Tail-Abhängigkeit für t und Frank", vor = VOR, teile = list(
  kendall_core_08 = teil(
    r"(SimLev:::.kendall_tau_core(x, y))",
    r"(result = C.kendall_tau_core(x, y))",
    r"(result = C.kendall_tau_core(x, y))", inp = ein("dependence/kendall_core_08", c("x", "y"))),
  kendall_na = teil(
    r"(list(SimLev:::.kendall(Mn), SimLev:::.kendall(Mn[, 1], Mn[, 3]), SimLev:::.kendall(1:5, c(1, 1, 1, 1, 1))))",
    r"(result = [D._kendall(Mn), D._kendall(Mn.iloc[:, 0], Mn.iloc[:, 2]), D._kendall(np.arange(1, 6), np.ones(5))])",
    r"(result = [D._kendall(Mn), D._kendall(Mn[:, 1], Mn[:, 3]), D._kendall(1:5, ones(5))])", inp = ein("dependence/kendall_na", c("Mn"))),
  cop_04_t = teil(
    r"(list(SimLev:::.cop_ll('t', p, uu, vv), SimLev:::.cop_lambda('t', p)))",
    r"(result = [D._cop_ll('t', p, uu, vv), D._cop_lambda('t', p)])",
    r"(result = [D._cop_ll("t", p, uu, vv), D._cop_lambda("t", p)])", inp = ein("dependence/cop_04_t", c("uu", "vv", "p"))),
  cop_14_frank = teil(
    r"(list(SimLev:::.cop_ll('frank', p, uu, vv), SimLev:::.cop_lambda('frank', p)))",
    r"(result = [D._cop_ll('frank', p, uu, vv), D._cop_lambda('frank', p)])",
    r"(result = [D._cop_ll("frank", p, uu, vv), D._cop_lambda("frank", p)])", inp = ein("dependence/cop_14_frank", c("uu", "vv", "p")))))
SZ("regime_einteilung", ".dep_regimes nach Quantilen (2, 5 Klassen, konstante Reihe) und nach Grenzen (auch skaliert)", vor = VOR, teile = list(
  regimes_q = teil(
    r"(list(rg(cvx), rg(cvx, NULL, 2L), rg(cvx, NULL, 5L), rg(cvd), rg(cvd2), rg(rep(3, 40))))",
    r"(def rg(*a):
    code, lab, br = D._dep_regimes(*a)
    return {'regime': [lab[c - 1] if c > 0 else None for c in code], 'levels': lab, 'breaks': br}
result = [rg(cvx), rg(cvx, None, 2), rg(cvx, None, 5), rg(cvd), rg(cvd2), rg(np.full(40, 3.))])",
    r"(function rg(a...)
    code, lab, br = D._dep_regimes(a...)
    SL.RList("regime" => Union{Missing,String}[c > 0 ? lab[c] : missing for c in code], "levels" => lab, "breaks" => br)
end
result = [rg(cvx), rg(cvx, nothing, 2), rg(cvx, nothing, 5), rg(cvd), rg(cvd2), rg(fill(3.0, 40))])", inp = ein("dependence/regimes_q", c("cvx", "cvd", "cvd2"))),
  regimes_breaks = teil(
    r"(list(rg(cvx, c(-Inf, 0, Inf)), rg(cvx, c(-1, 0.5, 1)), rg(cvx * 1000, c(-Inf, -123.4567, 2345.678, Inf)), rg(cvx, c(1, -1, 0))))",
    r"(def rg(*a):
    code, lab, br = D._dep_regimes(*a)
    return {'regime': [lab[c - 1] if c > 0 else None for c in code], 'levels': lab, 'breaks': br}
result = [rg(cvx, [-np.inf, 0, np.inf]), rg(cvx, [-1, 0.5, 1]), rg(cvx * 1000, [-np.inf, -123.4567, 2345.678, np.inf]), rg(cvx, [1, -1, 0])])",
    r"(function rg(a...)
    code, lab, br = D._dep_regimes(a...)
    SL.RList("regime" => Union{Missing,String}[c > 0 ? lab[c] : missing for c in code], "levels" => lab, "breaks" => br)
end
result = [rg(cvx, [-Inf, 0, Inf]), rg(cvx, [-1, 0.5, 1]), rg(cvx .* 1000, [-Inf, -123.4567, 2345.678, Inf]), rg(cvx, [1, -1, 0])])", inp = ein("dependence/regimes_breaks", c("cvx")))))
SZ("abhaengigkeitsanalyse", "dependence_analysis ohne Copulas, mit Bedingungen (Inflation, Regime), Grenzen, monatlich, DCC scheitert (identische Reihen); dependence_dcc mit drei Reihen", vor = VOR, teile = list(
  da_basic = teil(
    r"(dependence_analysis(d1, c('stocks', 'bonds'), copulas = FALSE))",
    r"(result = D.dependence_analysis(d1, ['stocks', 'bonds'], copulas=False))",
    r"(result = D.dependence_analysis(d1, ["stocks", "bonds"]; copulas = false))", druck = TRUE, inp = ein("dependence/da_basic", c("d1"))),
  da_cond = teil(
    r"(dependence_analysis(d1, c('stocks', 'bonds', 'gold'), conditions = c('inflation', 'regime'), B = 19, seed = 1, dcc = FALSE))",
    r"(result = D.dependence_analysis(d1, ['stocks', 'bonds', 'gold'], conditions=['inflation', 'regime'], B=19, seed=1, dcc=False))",
    r"(result = D.dependence_analysis(d1, ["stocks", "bonds", "gold"]; conditions = ["inflation", "regime"], B = 19, seed = 1, dcc = false))", druck = TRUE, inp = ein("dependence/da_cond", c("d1"))),
  da_breaks = teil(
    r"(dependence_analysis(d1, c('stocks', 'bonds'), conditions = 'inflation', breaks = list(inflation = c(-Inf, 2, Inf)), quantiles = c(0.1, 0.25), B = 9, block = 4, seed = 3, tail_q = 0.2, window = 20))",
    r"(result = D.dependence_analysis(d1, ['stocks', 'bonds'], conditions='inflation', breaks={'inflation': [-np.inf, 2, np.inf]}, quantiles=[0.1, 0.25], B=9, block=4, seed=3, tail_q=0.2, window=20))",
    r"(result = D.dependence_analysis(d1, ["stocks", "bonds"]; conditions = "inflation", breaks = Dict("inflation" => [-Inf, 2, Inf]), quantiles = [0.1, 0.25], B = 9, block = 4, seed = 3, tail_q = 0.2, window = 20))", druck = TRUE, inp = ein("dependence/da_breaks", c("d1"))),
  da_month = teil(
    r"(dependence_analysis(d1, c('stocks', 'gold'), frequency = 'month', conditions = 'zins', n_regimes = 2L, B = 0))",
    r"(result = D.dependence_analysis(d1, ['stocks', 'gold'], frequency='month', conditions='zins', n_regimes=2, B=0))",
    r"(result = D.dependence_analysis(d1, ["stocks", "gold"]; frequency = "month", conditions = "zins", n_regimes = 2, B = 0))", druck = TRUE, inp = ein("dependence/da_month", c("d1"))),
  da_dccfail = teil(
    r"(x <- d1; x$b2 <- x$bonds; dependence_analysis(x, c('stocks', 'bonds', 'b2'), copulas = FALSE))",
    r"(x = d1.copy(); x['b2'] = x['bonds']; result = D.dependence_analysis(x, ['stocks', 'bonds', 'b2'], copulas=False))",
    r"(x = copy(d1); x["b2"] = copy(x["bonds"]); result = D.dependence_analysis(x, ["stocks", "bonds", "b2"]; copulas = false))", druck = TRUE, inp = ein("dependence/da_dccfail", c("d1"))),
  dcc_fit3 = teil(
    r"(dependence_dcc(unname(RR)))",
    r"(result = D.dependence_dcc(RR.to_numpy()))",
    r"(result = D.dependence_dcc(RR.data))", inp = ein("dependence/dcc_fit3", c("RR")))))
SZ("quantils_und_tail_regression", "quantile_regression (mit und ohne Regressor), tail_regression (eine und zwei Bedingungen, monatlich mit NA), tail_covar", vor = VOR, teile = list(
  qreg_basic = teil(
    r"(list(quantile_regression(y, x, 0.9), quantile_regression(y, NULL, 0.3), quantile_regression(y, cbind(a = x, b = x2), 0.5), quantile_regression(y, data.frame(u = x), 0.1, intercept = FALSE)))",
    r"(result = [D.quantile_regression(y, X=x, tau=0.9), D.quantile_regression(y, X=None, tau=0.3), D.quantile_regression(y, X=pd.DataFrame({'a': x, 'b': x2}), tau=0.5), D.quantile_regression(y, X=pd.DataFrame({'u': x}), tau=0.1, intercept=False)])",
    r"(result = [D.quantile_regression(y, x, 0.9), D.quantile_regression(y, nothing, 0.3), D.quantile_regression(y, SL.NamedMat(hcat(x, x2); colnames = ["a", "b"]), 0.5), D.quantile_regression(y, SL.RFrame("u" => x), 0.1; intercept = false)])", inp = ein("dependence/qreg_basic", c("x", "y", "x2"))),
  treg_basic = teil(
    r"(tail_regression(d1, 'bonds', 'inflation', quantiles = c(0.1, 0.5, 0.9), B = 19, seed = 1))",
    r"(result = D.tail_regression(d1, 'bonds', 'inflation', quantiles=[0.1, 0.5, 0.9], B=19, seed=1))",
    r"(result = D.tail_regression(d1, "bonds", "inflation"; quantiles = [0.1, 0.5, 0.9], B = 19, seed = 1))", druck = TRUE, inp = ein("dependence/treg_basic", c("d1"))),
  treg_multi = teil(
    r"(tail_regression(dna, 'stocks', c('inflation', 'zins'), quantiles = 0.25, frequency = 'month', B = 9, block = 3, seed = 2))",
    r"(result = D.tail_regression(dna, 'stocks', ['inflation', 'zins'], quantiles=0.25, frequency='month', B=9, block=3, seed=2))",
    r"(result = D.tail_regression(dna, "stocks", ["inflation", "zins"]; quantiles = 0.25, frequency = "month", B = 9, block = 3, seed = 2))", druck = TRUE, inp = ein("dependence/treg_multi", c("dna"))),
  covar_basic = teil(
    r"(tail_covar(dp, 'port', c('stocks', 'bonds')))",
    r"(result = D.tail_covar(dp, 'port', ['stocks', 'bonds']))",
    r"(result = D.tail_covar(dp, "port", ["stocks", "bonds"]))", druck = TRUE, inp = ein("dependence/covar_basic", c("dp")))))
SZ("teilmengen_nach_bedingung", "Bootstrap mit Abhängigkeit (valdep), regime_subset nach Datum und mit Bedingungen in R-Syntax", vor = VOR, teile = list(
  valdep = teil(
    r"(b <- bootstrap(h, cfg, 'stationary', n = 6, params = list(L = 20), seed = 1, progress = FALSE); dependence_validate(b, h, agg = 5, max_paths = 4))",
    r"(from simlev import bootstrap as BS
cfg = BS.bootstrap_config({'us': 'us', 'eu': 'eu'})
b = BS.bootstrap(h, cfg, method='stationary', n=6, params={'L': 20}, seed=1, progress=False)
result = D.dependence_validate(b, h, agg=5, max_paths=4))",
    r"(BS = SL.Bootstrap
cfg = BS.bootstrap_config(SL.named("us" => "us", "eu" => "eu"))
b = BS.bootstrap(h, cfg; method = "stationary", n = 6, params = Dict("L" => 20), seed = 1, progress = false)
result = D.dependence_validate(b, h; agg = 5, max_paths = 4))", inp = ein("dependence/valdep", c("h"))),
  rsub_date = teil(
    r"(rs(hd, lg, min_run = 5L))",
    r"(def rs(*a, **k):
    s = D.regime_subset(*a, **k)
    return {'data': s, 'episodes': s.attrs['episodes']}
result = rs(hd, lg, min_run=5))",
    r"(rs(a...; k...) = (s = D.regime_subset(a...; k...); SL.RList("data" => s, "episodes" => SL.attrs(s)["episodes"]))
result = rs(hd, lg; min_run = 5))", inp = ein("dependence/rsub_date", c("hd", "lg"))),
  rsub_rsyntax = teil(
    r"-(thr2 <<- 3; list(rs(hs, "!infl < 4"), rs(hs, "infl >= 4 & !is.na(us)"), rs(hs, "infl %in% c(5)"), rs(hs, "if (TRUE) infl > thr2 else FALSE"), rs(hs, "as.character(infl > 4)"), rs(hs, "infl > 4\n"), rs(hs, "infl > 4 # Kommentar"), rs(hs, "(us > 1) + (infl > 4) == 2L"), rs(hs, "infl > c(1, 6)"), rs(hs, 'infl > mean(infl)', min_run = 3), rs(hs2, 'lbl == "hoch" & us > 0.99')))-",
    r"(def rs(*a, **k):
    s = D.regime_subset(*a, **k)
    return {'data': s, 'episodes': s.attrs['episodes']}
thr2 = 3
result = [rs(hs, '!infl < 4'), rs(hs, 'infl >= 4 & !is.na(us)'), rs(hs, 'infl %in% c(5)'), rs(hs, 'if (TRUE) infl > thr2 else FALSE'), rs(hs, 'as.character(infl > 4)'), rs(hs, 'infl > 4\n'), rs(hs, 'infl > 4 # Kommentar'), rs(hs, '(us > 1) + (infl > 4) == 2L'), rs(hs, 'infl > c(1, 6)'), rs(hs, 'infl > mean(infl)', min_run=3), rs(hs2, 'lbl == "hoch" & us > 0.99')])",
    r"-(rs(a...; k...) = (s = D.regime_subset(a...; k...); SL.RList("data" => s, "episodes" => SL.attrs(s)["episodes"]))
thr2 = 3
result = [rs(hs, "!infl < 4"; env = @__MODULE__), rs(hs, "infl >= 4 & !is.na(us)"; env = @__MODULE__), rs(hs, "infl %in% c(5)"; env = @__MODULE__), rs(hs, "if (TRUE) infl > thr2 else FALSE"; env = @__MODULE__), rs(hs, "as.character(infl > 4)"; env = @__MODULE__), rs(hs, "infl > 4\n"; env = @__MODULE__), rs(hs, "infl > 4 # Kommentar"; env = @__MODULE__), rs(hs, "(us > 1) + (infl > 4) == 2L"; env = @__MODULE__), rs(hs, "infl > c(1, 6)"; env = @__MODULE__), rs(hs, "infl > mean(infl)"; min_run = 3), rs(hs2, "lbl == \"hoch\" & us > 0.99")])-", inp = ein("dependence/rsub_rsyntax", c("hs", "hs2")), oben = TRUE)))
ref_done()

ref_init("dependence", gruppe = "fehler")
TB(".dep_sort_dates", "Meldungen und Warnungen von .dep_sort_dates je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("sort_dates_na",
    r"(SimLev:::.dep_sort_dates(dm))",
    r"(result = D._dep_sort_dates(dm))",
    r"(result = D._dep_sort_dates(dm))", inp = ein("dependence/sort_dates_na", c("dm")))))
TB(".dep_check_prices", "Meldungen und Warnungen von .dep_check_prices je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("check_prices_inf",
    r"(SimLev:::.dep_check_prices(c(1, Inf), 'b', d1$date[1:2]))",
    r"(result = D._dep_check_prices(np.array([1, np.inf]), 'b', d1['date'].to_numpy()[:2]))",
    r"(result = D._dep_check_prices([1, Inf], "b", d1["date"][1:2]))", inp = ein("dependence/check_prices_inf", c("d1")))))
TB(".dep_returns", "Meldungen und Warnungen von .dep_returns je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("returns_err1",
    r"(SimLev:::.dep_returns(as.matrix(d1[, 2:3]), 'stocks'))",
    r"(result = D._dep_returns(d1.iloc[:, 1:3].to_numpy(), 'stocks'))",
    r"(result = D._dep_returns(hcat(d1["stocks"], d1["bonds"]), "stocks"))", inp = ein("dependence/returns_err1", c("d1"))),
  zeile("returns_err2",
    r"(SimLev:::.dep_returns(d1, c('stocks', 'xx'), 'yy'))",
    r"(result = D._dep_returns(d1, ['stocks', 'xx'], 'yy'))",
    r"(result = D._dep_returns(d1, ["stocks", "xx"], "yy"))", inp = ein("dependence/returns_err2", c("d1")))))
TB(".cop_ll", "Meldungen und Warnungen von .cop_ll je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("cop_bad",
    r"(SimLev:::.cop_ll('student', 1, uu, vv))",
    r"(result = D._cop_ll('student', 1, uu, vv))",
    r"(result = D._cop_ll("student", 1, uu, vv))", inp = ein("dependence/cop_bad", c("uu", "vv")))))
TB("copula_fit", "Meldungen und Warnungen von copula_fit je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("fitcop_err_len",
    r"(copula_fit(1:30, 1:29))",
    r"(result = D.copula_fit(np.arange(1, 31), np.arange(1, 30)))",
    r"(result = D.copula_fit(1:30, 1:29))", inp = ein("dependence/fitcop_err_len", c())),
  zeile("fitcop_err_n",
    r"(copula_fit(c(1:19, NA), 1:20))",
    r"(result = D.copula_fit(np.r_[np.arange(1., 20), simlev._r.fmt.NA_REAL], np.arange(1, 21)))",
    r"(result = D.copula_fit(vcat(1.0:19.0, SL.NA), 1:20))", inp = ein("dependence/fitcop_err_n", c())),
  zeile("fitcop_err_fam",
    r"(copula_fit(x, y, c('t', 'gaussian_90', 'joe', 'gumbel_45')))",
    r"(result = D.copula_fit(x, y, families=['t', 'gaussian_90', 'joe', 'gumbel_45']))",
    r"(result = D.copula_fit(x, y, ["t", "gaussian_90", "joe", "gumbel_45"]))", inp = ein("dependence/fitcop_err_fam", c("x", "y"))),
  zeile("fitcop_err_const",
    r"(copula_fit(rep(1, 30), 1:30))",
    r"(result = D.copula_fit(np.ones(30), np.arange(1, 31)))",
    r"(result = D.copula_fit(ones(30), 1:30))", inp = ein("dependence/fitcop_err_const", c()))))
TB("tail_dependence", "Meldungen und Warnungen von tail_dependence je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("tail_err_q2",
    r"(tail_dependence(tx, ty, numeric(0)))",
    r"(result = D.tail_dependence(tx, ty, q=[]))",
    r"(result = D.tail_dependence(tx, ty, Float64[]))", inp = ein("dependence/tail_err_q2", c("tx", "ty"))),
  zeile("tail_err_len",
    r"(tail_dependence(1:3, 1:4))",
    r"(result = D.tail_dependence(np.arange(1, 4), np.arange(1, 5)))",
    r"(result = D.tail_dependence(1:3, 1:4))", inp = ein("dependence/tail_err_len", c())),
  zeile("tail_err_n",
    r"(tail_dependence(c(1, NA), c(2, 3)))",
    r"(result = D.tail_dependence(np.array([1, simlev._r.fmt.NA_REAL]), np.array([2., 3])))",
    r"(result = D.tail_dependence([1, SL.NA], [2.0, 3]))", inp = ein("dependence/tail_err_n", c()))))
TB("dependence_dcc", "Meldungen und Warnungen von dependence_dcc je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("dcc_err_n",
    r"(dependence_dcc(RR[1:99, ]))",
    r"(result = D.dependence_dcc(RR.iloc[:99]))",
    r"(result = D.dependence_dcc(sub(RR, 1:99, :)))", inp = ein("dependence/dcc_err_n", c("RR"))),
  zeile("dcc_err_const",
    r"(dependence_dcc(RC))",
    r"(result = D.dependence_dcc(RC))",
    r"(result = D.dependence_dcc(RC))", inp = ein("dependence/dcc_err_const", c("RC")))))
TB("rg", "Meldungen und Warnungen von rg je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("regimes_err",
    r"(rg(cvx, c(-Inf, 0, 0, Inf)))",
    r"(def rg(*a):
    code, lab, br = D._dep_regimes(*a)
    return {'regime': [lab[c - 1] if c > 0 else None for c in code], 'levels': lab, 'breaks': br}
result = rg(cvx, [-np.inf, 0, 0, np.inf]))",
    r"(function rg(a...)
    code, lab, br = D._dep_regimes(a...)
    SL.RList("regime" => Union{Missing,String}[c > 0 ? lab[c] : missing for c in code], "levels" => lab, "breaks" => br)
end
result = rg(cvx, [-Inf, 0, 0, Inf]))", inp = ein("dependence/regimes_err", c("cvx")))))
TB("dependence_analysis", "Meldungen und Warnungen von dependence_analysis je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("da_warn",
    r"(dependence_analysis(dsh, c('stocks', 'bonds'), conditions = 'inflation', copulas = FALSE))",
    r"(result = D.dependence_analysis(dsh, ['stocks', 'bonds'], conditions='inflation', copulas=False))",
    r"(result = D.dependence_analysis(dsh, ["stocks", "bonds"]; conditions = "inflation", copulas = false))", print = TRUE, inp = ein("dependence/da_warn", c("dsh"))),
  zeile("da_err1",
    r"(dependence_analysis(d1, 'stocks'))",
    r"(result = D.dependence_analysis(d1, 'stocks'))",
    r"(result = D.dependence_analysis(d1, "stocks"))", inp = ein("dependence/da_err1", c("d1"))),
  zeile("da_err2",
    r"(dependence_analysis(d1, c('stocks', 'bonds'), frequency = 'month'))",
    r"(result = D.dependence_analysis(d1, ['stocks', 'bonds'], frequency='month'))",
    r"(result = D.dependence_analysis(d1, ["stocks", "bonds"]; frequency = "month"))", inp = ein("dependence/da_err2", c("d1")))))
TB("quantile_regression", "Meldungen und Warnungen von quantile_regression je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("qreg_err_tau_0",
    r"(quantile_regression(y, x, 0))",
    r"(result = D.quantile_regression(y, X=x, tau=0))",
    r"(result = D.quantile_regression(y, x, 0))", inp = ein("dependence/qreg_err_tau_0", c("x", "y"))),
  zeile("qreg_err_y",
    r"(quantile_regression(letters, x))",
    r"(result = D.quantile_regression(np.array(list('abc'), dtype=object), X=x))",
    r"(result = D.quantile_regression(string.(collect("abcdefghijklmnopqrstuvwxyz")), x))", inp = ein("dependence/qreg_err_y", c("x"))),
  zeile("qreg_err_df",
    r"(quantile_regression(y, data.frame(a = x, f = factor(x > 0), g = 'z')))",
    r"(result = D.quantile_regression(y, X=pd.DataFrame({'a': x, 'f': pd.Categorical(x > 0), 'g': 'z'})))",
    r"(result = D.quantile_regression(y, SL.RFrame("a" => x, "f" => SL.RFmt.RFactor([v > 0 ? 2 : 1 for v in x], ["FALSE", "TRUE"]), "g" => fill("z", length(x)))))", inp = ein("dependence/qreg_err_df", c("x", "y"))),
  zeile("qreg_err_rows",
    r"(quantile_regression(y, x[-1]))",
    r"(result = D.quantile_regression(y, X=x[1:]))",
    r"(result = D.quantile_regression(y, x[2:end]))", inp = ein("dependence/qreg_err_rows", c("x", "y"))),
  zeile("qreg_err_noreg",
    r"(quantile_regression(y, NULL, intercept = FALSE))",
    r"(result = D.quantile_regression(y, X=None, intercept=False))",
    r"(result = D.quantile_regression(y, nothing; intercept = false))", inp = ein("dependence/qreg_err_noreg", c("y"))),
  zeile("qreg_err_few",
    r"(quantile_regression(y[1:2], cbind(x, x2)[1:2, ]))",
    r"(result = D.quantile_regression(y[:2], X=np.column_stack([x, x2])[:2]))",
    r"(result = D.quantile_regression(y[1:2], hcat(x, x2)[1:2, :]))", inp = ein("dependence/qreg_err_few", c("x", "y", "x2"))),
  zeile("qreg_err_coll",
    r"(quantile_regression(y, cbind(a = x, b = 2 * x, c = 1)))",
    r"(result = D.quantile_regression(y, X=pd.DataFrame({'a': x, 'b': 2 * x, 'c': 1.0})))",
    r"(result = D.quantile_regression(y, SL.NamedMat(hcat(x, 2 .* x, ones(length(x))); colnames = ["a", "b", "c"])))", inp = ein("dependence/qreg_err_coll", c("x", "y"))),
  zeile("qreg_err_X",
    r"(quantile_regression(y, matrix(letters[1:2], 200, 1)))",
    r"(result = D.quantile_regression(y, X=np.full((200, 1), 'a', dtype=object)))",
    r"(result = D.quantile_regression(y, fill("a", 200, 1)))", inp = ein("dependence/qreg_err_X", c("y"))),
  zeile("qreg_warn",
    r"(quantile_regression(yy, X, tau, maxit = 1L))",
    r"(result = D.quantile_regression(yy, X=X, tau=tau, maxit=1))",
    r"(result = D.quantile_regression(yy, X, tau; maxit = 1))", inp = ein("dependence/qreg_warn", c("yy", "X", "tau")))))
TB("tail_regression", "Meldungen und Warnungen von tail_regression je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("treg_fail",
    r"(tail_regression(dsp, 'stocks', 'event', quantiles = c(0.5), B = 15, seed = 4))",
    r"(result = D.tail_regression(dsp, 'stocks', 'event', quantiles=[0.5], B=15, seed=4))",
    r"(result = D.tail_regression(dsp, "stocks", "event"; quantiles = [0.5], B = 15, seed = 4))", print = TRUE, inp = ein("dependence/treg_fail", c("dsp"))),
  zeile("treg_err",
    r"(tail_regression(d1[1:100, ], 'stocks', 'zins'))",
    r"(result = D.tail_regression(d1.iloc[:100], 'stocks', 'zins'))",
    r"(result = D.tail_regression(d1, "stocks", "zins"))", inp = ein("dependence/treg_err", c("d1")))))
TB("dependence_validate", "Meldungen und Warnungen von dependence_validate je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("valdep_err1",
    r"(dependence_validate(list(), h))",
    r"(result = D.dependence_validate({}, h))",
    r"(result = D.dependence_validate(SL.RList(), h))", inp = ein("dependence/valdep_err1", c("h")))))
TB("regime_subset", "Meldungen und Warnungen von regime_subset je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("rsub_err1",
    r"(regime_subset(hs, 'infl > 10'))",
    r"(result = D.regime_subset(hs, 'infl > 10'))",
    r"(result = D.regime_subset(hs, "infl > 10"))", inp = ein("dependence/rsub_err1", c("hs"))),
  zeile("rsub_err2",
    r"(regime_subset(hs, c(TRUE, FALSE)))",
    r"(result = D.regime_subset(hs, [True, False]))",
    r"(result = D.regime_subset(hs, [true, false]))", inp = ein("dependence/rsub_err2", c("hs")))))
ref_done()

ref_schreiben()

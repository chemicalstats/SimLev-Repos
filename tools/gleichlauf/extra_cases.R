# Zusatzfaelle der Gleichlaufpruefung (Etappe 9.1, Entwurf C.8): Exporte und interne Huellen ohne
# Fall in den Generatoren golden/modules/gen_*.R. Modul "slc": simlev_seed() und die Ziehungen und
# Verteilungen der C-Bibliothek slc (.sl_* in R, simlev._lib in Python, SimLev.SLib in Julia).
#
# Aufruf aus der Repo-Wurzel (tools/gleichlauf/run.sh setzt SIMLEV_MODULE_DIR):
#   SIMLEV_MODULE_DIR=<ordner> R_LIBS=<R-Bibliothek> Rscript tools/gleichlauf/extra_cases.R
# Die Faelle werden immer vollstaendig erzeugt (SIMLEV_GEN_SUBSET gilt hier nicht).
Sys.setenv(SIMLEV_GEN_SUBSET = "1")
source("golden/modules/ref_tools.R")
ref_init("slc")

P <- "import numpy as np\nimport simlev._lib as L\n"
J <- "const L = SL.SLib\n"
cs <- function(id, r, py, jl, inputs = list())
  ref_case(id, r = paste0("sl <- asNamespace('SimLev')\n", r), py = paste0(P, py), jl = paste0(J, jl), inputs = inputs)

# ── simlev_seed, Testvektoren, Zustand ──
for (s in c(0, 1, -1, 42, 2^53 - 1, -(2^53 - 1), 123456789)) {
  id <- paste0("seed_", gsub("-", "m", format(s, scientific = FALSE)))
  cs(id, r = sprintf("simlev_seed(%s); list(sl$.sl_state_hex(), sl$.sl_u64(5))", format(s, scientific = FALSE)),
     py = sprintf("simlev.simlev_seed(%s); result = [L.state_hex(), L.u64(5)]", format(s, scientific = FALSE)),
     jl = sprintf("simlev_seed(%s); result = Any[L.state_hex(), L.u64(5)]", format(s, scientific = FALSE)))
}
cs("seed_rueckgabe", r = "simlev_seed(17)", py = "result = simlev.simlev_seed(17)", jl = "result = simlev_seed(17)")
cs("seed_fehler_bruch", r = "simlev_seed(1.5)", py = "result = simlev.simlev_seed(1.5)", jl = "result = simlev_seed(1.5)")
cs("seed_fehler_gross", r = "simlev_seed(2^53)", py = "result = simlev.simlev_seed(2**53)", jl = "result = simlev_seed(2^53)")
cs("next_seed", r = "simlev_seed(5); c(sl$.sl_next_seed(), sl$.sl_next_seed(), sl$.sl_next_seed())",
   py = "simlev.simlev_seed(5); result = np.array([L.next_seed(), L.next_seed(), L.next_seed()], dtype=np.int32)",
   jl = "simlev_seed(5); result = Int32[L.next_seed(), L.next_seed(), L.next_seed()]")
cs("einheit_sperre", r = "sl$.sl_in_unit(sl$.sl_runif(1))",
   py = "with L.in_unit():\n    result = L.runif(1)", jl = "result = L.in_unit(() -> L.runif(1))")

# ── Stroeme je Einheit ──
cs("stroeme", r = "u <- sl$.sl_streams(sl$.sl_stream(9), 4); lapply(u, function(s) c(sl$.sl_state_hex(s), sl$.sl_u64(2, stream = s)))",
   py = "u = L.streams(L.Stream(9), 4)\nresult = [L.state_hex(s) + L.u64(2, stream=s) for s in u]",
   jl = "u = L.streams(L.Stream(9), 4)\nresult = Any[vcat(L.state_hex(s), L.u64(2; stream = s)) for s in u]")
cs("strom_und_global", r = "simlev_seed(3); s <- sl$.sl_stream(3); list(sl$.sl_runif(3, stream = s), sl$.sl_runif(3), sl$.sl_state_hex(s), sl$.sl_state_hex())",
   py = "simlev.simlev_seed(3); s = L.Stream(3)\nresult = [L.runif(3, stream=s), L.runif(3), L.state_hex(s), L.state_hex()]",
   jl = "simlev_seed(3); s = L.Stream(3)\nresult = Any[L.runif(3; stream = s), L.runif(3), L.state_hex(s), L.state_hex()]")

# ── Ziehungen ──
draws <- list(
  runif = list(r = "sl$.sl_runif(200, -2, 3)", py = "L.runif(200, -2.0, 3.0)", jl = "L.runif(200, -2.0, 3.0)"),
  runif_gleich = list(r = "sl$.sl_runif(3, 2, 2)", py = "L.runif(3, 2.0, 2.0)", jl = "L.runif(3, 2.0, 2.0)"),
  runif_nan = list(r = "sl$.sl_runif(3, 3, 2)", py = "L.runif(3, 3.0, 2.0)", jl = "L.runif(3, 3.0, 2.0)"),
  rnorm = list(r = "sl$.sl_rnorm(300, 1, 2)", py = "L.rnorm(300, 1.0, 2.0)", jl = "L.rnorm(300, 1.0, 2.0)"),
  rnorm_sd0 = list(r = "sl$.sl_rnorm(3, 1, 0)", py = "L.rnorm(3, 1.0, 0.0)", jl = "L.rnorm(3, 1.0, 0.0)"),
  rnorm_nan = list(r = "sl$.sl_rnorm(2, 0, -1)", py = "L.rnorm(2, 0.0, -1.0)", jl = "L.rnorm(2, 0.0, -1.0)"),
  rexp = list(r = "sl$.sl_rexp(200, 0.5)", py = "L.rexp(200, 0.5)", jl = "L.rexp(200, 0.5)"),
  rgeom = list(r = "sl$.sl_rgeom(200, 0.05)", py = "L.rgeom(200, 0.05)", jl = "L.rgeom(200, 0.05)"),
  rgeom_eins = list(r = "sl$.sl_rgeom(3, 1)", py = "L.rgeom(3, 1.0)", jl = "L.rgeom(3, 1.0)"),
  rgeom_nan = list(r = "sl$.sl_rgeom(2, 0)", py = "L.rgeom(2, 0.0)", jl = "L.rgeom(2, 0.0)"),
  rgamma_klein = list(r = "sl$.sl_rgamma(200, 0.3)", py = "L.rgamma(200, 0.3)", jl = "L.rgamma(200, 0.3)"),
  rgamma = list(r = "sl$.sl_rgamma(200, 4.5, 2)", py = "L.rgamma(200, 4.5, 2.0)", jl = "L.rgamma(200, 4.5, 2.0)"),
  rchisq = list(r = "sl$.sl_rchisq(200, 5)", py = "L.rchisq(200, 5.0)", jl = "L.rchisq(200, 5.0)"),
  rchisq_nan = list(r = "sl$.sl_rchisq(2, -1)", py = "L.rchisq(2, -1.0)", jl = "L.rchisq(2, -1.0)"),
  sample_perm = list(r = "sl$.sl_sample(50)", py = "L.sample(50)", jl = "L.sample(50)"),
  sample_teil = list(r = "sl$.sl_sample(1000, 7)", py = "L.sample(1000, 7)", jl = "L.sample(1000, 7)"),
  sample_rep = list(r = "sl$.sl_sample(6, 100, TRUE)", py = "L.sample(6, 100, True)", jl = "L.sample(6, 100; replace = true)"),
  sample_prob = list(r = "sl$.sl_sample(5, 100, TRUE, c(0.1, 0, 2, 0.5, 1.4))",
                     py = "L.sample(5, 100, True, [0.1, 0.0, 2.0, 0.5, 1.4])",
                     jl = "L.sample(5, 100; replace = true, prob = [0.1, 0.0, 2.0, 0.5, 1.4])"),
  sample_prob_ohne = list(r = "sl$.sl_sample(5, 3, FALSE, c(0.1, 0, 2, 0.5, 1.4))",
                          py = "L.sample(5, 3, False, [0.1, 0.0, 2.0, 0.5, 1.4])",
                          jl = "L.sample(5, 3; replace = false, prob = [0.1, 0.0, 2.0, 0.5, 1.4])"),
  sample_fehler = list(r = "sl$.sl_sample(3, 5)", py = "L.sample(3, 5)", jl = "L.sample(3, 5)"),
  sample_gewichte = list(r = "sl$.sl_sample(3, 2, TRUE, c(1, -1, 1))", py = "L.sample(3, 2, True, [1.0, -1.0, 1.0])",
                         jl = "L.sample(3, 2; replace = true, prob = [1.0, -1.0, 1.0])")
)
for (nm in names(draws)) {
  d <- draws[[nm]]
  cs(paste0("zieh_", nm), r = sprintf("simlev_seed(2026); x <- %s; list(x, sl$.sl_state_hex())", d$r),
     py = sprintf("simlev.simlev_seed(2026); x = %s\nresult = [x, L.state_hex()]", d$py),
     jl = sprintf("simlev_seed(2026); x = %s\nresult = Any[x, L.state_hex()]", d$jl))
}

# ── Verteilungen (Eingaben als Baeume: in allen Sprachen dieselben double-Werte) ──
xs <- c(NA, NaN, -Inf, -40, -38.4, -37.6, -20, -5.01, -5, -1, -0.3, -0, 0, 1e-300, 0.25, 1, 4.99, 5, 8.3, 30, Inf)
ps <- c(NA, NaN, -0.1, 0, 4.9e-324, 1e-300, 1e-20, 2.8e-7, 0.01, 0.075, 0.3, 0.5, 0.7, 0.925, 1 - 1e-10, 1 - 2^-53, 1, 1.5)
pos <- c(NA, NaN, -1, 0, 1e-300, 1e-10, 0.3, 0.5, 1, 1.5, 2, 2.5, 3.7, 9.99, 10, 10.01, 171.5, 1e6, 1e300, Inf)
ts <- c(NA, NaN, -Inf, -1e200, -1e10, -50, -5, -2, -0.3, 0, 0.3, 2, 5, 50, 1e10, Inf)
bx <- c(NA, NaN, -0.5, 0, 1e-300, 1e-10, 0.01, 0.3, 0.5, 0.88, 0.97, 0.999999, 1, 1.5)
dist <- list(
  pnorm = c("sl$.sl_pnorm(x)", "L.pnorm(x)", "L.pnorm(x)", "xs"),
  pnorm_oben = c("sl$.sl_pnorm(x, lower.tail = FALSE)", "L.pnorm(x, lower_tail=False)", "L.pnorm(x; lower_tail = false)", "xs"),
  pnorm_musd = c("sl$.sl_pnorm(x, 1, 2)", "L.pnorm(x, 1.0, 2.0)", "L.pnorm(x, 1.0, 2.0)", "xs"),
  pnorm_sd0 = c("sl$.sl_pnorm(x, 0.25, 0)", "L.pnorm(x, 0.25, 0.0)", "L.pnorm(x, 0.25, 0.0)", "xs"),
  pnorm_sdneg = c("sl$.sl_pnorm(x, 0, -1)", "L.pnorm(x, 0.0, -1.0)", "L.pnorm(x, 0.0, -1.0)", "xs"),
  qnorm = c("sl$.sl_qnorm(x)", "L.qnorm(x)", "L.qnorm(x)", "ps"),
  qnorm_oben = c("sl$.sl_qnorm(x, 2, 3, lower.tail = FALSE)", "L.qnorm(x, 2.0, 3.0, lower_tail=False)", "L.qnorm(x, 2.0, 3.0; lower_tail = false)", "ps"),
  qnorm_sd0 = c("sl$.sl_qnorm(x, 1, 0)", "L.qnorm(x, 1.0, 0.0)", "L.qnorm(x, 1.0, 0.0)", "ps"),
  dnorm = c("sl$.sl_dnorm(x)", "L.dnorm(x)", "L.dnorm(x)", "xs"),
  dnorm_log = c("sl$.sl_dnorm(x, 1, 2, log = TRUE)", "L.dnorm(x, 1.0, 2.0, log=True)", "L.dnorm(x, 1.0, 2.0; log = true)", "xs"),
  erfc = c("sl$.sl_erfc(x)", "L.erfc(x)", "L.erfc(x)", "xs"),
  lgamma = c("sl$.sl_lgamma(x)", "L.lgamma(x)", "L.lgamma(x)", "pos"),
  pt_3 = c("sl$.sl_pt(x, 3)", "L.pt(x, 3.0)", "L.pt(x, 3.0)", "ts"),
  pt_05_oben = c("sl$.sl_pt(x, 0.5, lower.tail = FALSE)", "L.pt(x, 0.5, lower_tail=False)", "L.pt(x, 0.5; lower_tail = false)", "ts"),
  pt_gross = c("sl$.sl_pt(x, 4e5)", "L.pt(x, 4e5)", "L.pt(x, 4e5)", "ts"),
  pt_inf = c("sl$.sl_pt(x, Inf)", "L.pt(x, np.inf)", "L.pt(x, Inf)", "ts"),
  pt_nan = c("sl$.sl_pt(x, -1)", "L.pt(x, -1.0)", "L.pt(x, -1.0)", "ts"),
  qt_1 = c("sl$.sl_qt(x, 1)", "L.qt(x, 1.0)", "L.qt(x, 1.0)", "ps"),
  qt_2 = c("sl$.sl_qt(x, 2)", "L.qt(x, 2.0)", "L.qt(x, 2.0)", "ps"),
  qt_5 = c("sl$.sl_qt(x, 5.5)", "L.qt(x, 5.5)", "L.qt(x, 5.5)", "ps"),
  qt_30_oben = c("sl$.sl_qt(x, 30, lower.tail = FALSE)", "L.qt(x, 30.0, lower_tail=False)", "L.qt(x, 30.0; lower_tail = false)", "ps"),
  qt_klein = c("sl$.sl_qt(x, 0.5)", "L.qt(x, 0.5)", "L.qt(x, 0.5)", "ps"),
  pbeta = c("sl$.sl_pbeta(x, 2, 3)", "L.pbeta(x, 2.0, 3.0)", "L.pbeta(x, 2.0, 3.0)", "bx"),
  pbeta_klein = c("sl$.sl_pbeta(x, 6.4, 0.0118, lower.tail = FALSE)", "L.pbeta(x, 6.4, 0.0118, lower_tail=False)", "L.pbeta(x, 6.4, 0.0118; lower_tail = false)", "bx"),
  pbeta_gross = c("sl$.sl_pbeta(x, 1e5, 3)", "L.pbeta(x, 1e5, 3.0)", "L.pbeta(x, 1e5, 3.0)", "bx"),
  pbeta_beide = c("sl$.sl_pbeta(x, 30, 40)", "L.pbeta(x, 30.0, 40.0)", "L.pbeta(x, 30.0, 40.0)", "bx"),
  pbeta_nan = c("sl$.sl_pbeta(x, 0, 1)", "L.pbeta(x, 0.0, 1.0)", "L.pbeta(x, 0.0, 1.0)", "bx"),
  plogis = c("sl$.sl_plogis(x)", "L.plogis(x)", "L.plogis(x)", "xs"),
  qlogis = c("sl$.sl_qlogis(x)", "L.qlogis(x)", "L.qlogis(x)", "ps")
)
grids <- list(xs = xs, ps = ps, pos = pos, ts = ts, bx = bx)
for (nm in names(dist)) {
  d <- dist[[nm]]
  cs(paste0("vert_", nm), r = d[1], py = paste0("result = ", d[2]), jl = paste0("result = ", d[3]),
     inputs = list(x = grids[[d[4]]]))
}

# ── zufaellige Gitter (dicht) ──
set.seed(91)
gx <- c(stats::runif(400, -40, 9), stats::rnorm(200))
gp <- c(10^stats::runif(300, -300, 0), stats::runif(200))
for (nu in c(1.5, 4, 25)) {
  cs(sprintf("gitter_pt_%s", sub("\\.", "_", format(nu))), r = sprintf("sl$.sl_pt(x, %s)", format(nu)),
     py = sprintf("result = L.pt(x, %s)", format(nu)), jl = sprintf("result = L.pt(x, %s)", format(nu)), inputs = list(x = gx))
  cs(sprintf("gitter_qt_%s", sub("\\.", "_", format(nu))), r = sprintf("sl$.sl_qt(x, %s)", format(nu)),
     py = sprintf("result = L.qt(x, %s)", format(nu)), jl = sprintf("result = L.qt(x, %s)", format(nu)), inputs = list(x = gp))
}
cs("gitter_pnorm", r = "sl$.sl_pnorm(x)", py = "result = L.pnorm(x)", jl = "result = L.pnorm(x)", inputs = list(x = gx))
cs("gitter_qnorm", r = "sl$.sl_qnorm(x)", py = "result = L.qnorm(x)", jl = "result = L.qnorm(x)", inputs = list(x = gp))
cs("gitter_lgamma", r = "sl$.sl_lgamma(abs(x))", py = "result = L.lgamma(np.abs(x))", jl = "result = L.lgamma(abs.(x))", inputs = list(x = gx))

ref_done()

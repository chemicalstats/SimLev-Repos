# Referenzfälle für stats::nlminb (PORT-Bibliothek) in simlev._r.stats bzw.
# SimLev.RStats (ohne Zusatzpakete).
# Aufruf aus der Repo-Wurzel:
#   LC_ALL=C.UTF-8 R_LIBS=<R-Bibliothek mit SimLev> Rscript golden/modules/gen_r_nlminb.R
source("golden/modules/ref_tools.R")
ref_init("r_nlminb")

HDR <- "import math\nimport simlev._r.stats as st\nimport simlev._r.base as rb\nfrom simlev._r import libm\n"
JHDR <- "const st = SL.RStats\n"
NL <- "o <- %s; o[c('par', 'objective', 'convergence', 'iterations', 'evaluations', 'message')]"
cs <- function(id, r, py, jl, inputs = list(), wrap = TRUE)
  ref_case(id, r = if (wrap) sprintf(NL, r) else r, py = paste0(HDR, py), inputs = inputs,
           jl = paste0(JHDR, jl))

## ── Testfunktionen (in R, Python und Julia mit derselben Rechenreihenfolge) ──
FR_R <- "fr <- function(x) 100 * (x[2] - x[1] * x[1])^2 + (1 - x[1])^2; grr <- function(x) c(-400 * x[1] * (x[2] - x[1] * x[1]) - 2 * (1 - x[1]), 200 * (x[2] - x[1] * x[1])); hsr <- function(x) matrix(c(1200 * x[1] * x[1] - 400 * x[2] + 2, -400 * x[1], -400 * x[1], 200), 2, 2);"
FR_P <- paste0("def fr(x):\n    a = x[1] - x[0]*x[0]; b = 1 - x[0]\n    return 100*(a*a) + b*b\n",
               "def grr(x):\n    return np.array([-400*x[0]*(x[1] - x[0]*x[0]) - 2*(1 - x[0]), 200*(x[1] - x[0]*x[0])])\n",
               "def hsr(x):\n    return np.array([[1200*x[0]*x[0] - 400*x[1] + 2, -400*x[0]], [-400*x[0], 200.0]])\n")
FR_J <- paste0("fr(x) = (a = x[2] - x[1]*x[1]; b = 1 - x[1]; 100*(a*a) + b*b)\n",
               "grr(x) = [-400*x[1]*(x[2] - x[1]*x[1]) - 2*(1 - x[1]), 200*(x[2] - x[1]*x[1])]\n",
               "hsr(x) = [1200*x[1]*x[1] - 400*x[2] + 2 -400*x[1]; -400*x[1] 200.0]\n")
# Quadrat mit Kopplung und Quartik (n = 3)
FQ_R <- "fq <- function(x) { s <- 0; for (i in seq_along(x)) { t <- i * (x[i] - i/3); s <- s + t * t + 0.1 * x[i]^4 }; s + x[1] * x[2] - 0.5 * x[2] * x[3] }; gq <- function(x) { g <- numeric(length(x)); for (i in seq_along(x)) g[i] <- 2 * i * i * (x[i] - i/3) + 0.4 * x[i]^3; g[1] <- g[1] + x[2]; g[2] <- g[2] + x[1] - 0.5 * x[3]; g[3] <- g[3] - 0.5 * x[2]; g }; hq <- function(x) { H <- diag(2 * (1:3)^2 + 1.2 * x^2); H[1, 2] <- H[2, 1] <- 1; H[2, 3] <- H[3, 2] <- -0.5; H };"
FQ_P <- paste0("def fq(x):\n    s = 0.0\n    for i in range(len(x)):\n        t = (i + 1)*(x[i] - (i + 1)/3)\n        s = s + t*t + 0.1*math.pow(float(x[i]), 4)\n    return s + x[0]*x[1] - 0.5*x[1]*x[2]\n",
               "def gq(x):\n    g = np.zeros(len(x))\n    for i in range(len(x)):\n        g[i] = 2*(i + 1)*(i + 1)*(x[i] - (i + 1)/3) + 0.4*math.pow(float(x[i]), 3)\n    g[0] = g[0] + x[1]; g[1] = g[1] + x[0] - 0.5*x[2]; g[2] = g[2] - 0.5*x[1]\n    return g\n",
               "def hq(x):\n    H = np.diag([2.0*(i + 1)**2 + 1.2*(x[i]*x[i]) for i in range(3)])\n    H[0, 1] = H[1, 0] = 1.0; H[1, 2] = H[2, 1] = -0.5\n    return H\n")
FQ_J <- paste0("function fq(x)\n    s = 0.0\n    for i in 1:length(x)\n        t = i*(x[i] - i/3)\n        s = s + t*t + 0.1*SL.RLibm.pow(x[i], 4)\n    end\n    s + x[1]*x[2] - 0.5*x[2]*x[3]\nend\n",
               "function gq(x)\n    g = zeros(length(x))\n    for i in 1:length(x)\n        g[i] = 2*i*i*(x[i] - i/3) + 0.4*SL.RLibm.pow(x[i], 3)\n    end\n    g[1] = g[1] + x[2]; g[2] = g[2] + x[1] - 0.5*x[3]; g[3] = g[3] - 0.5*x[2]\n    g\nend\n",
               "function hq(x)\n    H = zeros(3, 3)\n    for i in 1:3\n        H[i, i] = 2.0*i*i + 1.2*(x[i]*x[i])\n    end\n    H[1, 2] = H[2, 1] = 1.0; H[2, 3] = H[3, 2] = -0.5\n    H\nend\n")
# eindimensional
F1_R <- "f1 <- function(x) (x - 3)^2 + exp(0.2 * x); g1 <- function(x) 2 * (x - 3) + 0.2 * exp(0.2 * x); h1 <- function(x) matrix(2 + 0.04 * exp(0.2 * x), 1, 1);"
F1_P <- "def f1(x):\n    x = float(x[0]); return (x - 3)*(x - 3) + math.exp(0.2*x)\ndef g1(x):\n    x = float(x[0]); return 2*(x - 3) + 0.2*math.exp(0.2*x)\ndef h1(x):\n    x = float(x[0]); return np.array([[2 + 0.04*math.exp(0.2*x)]])\n"
F1_J <- "f1(x) = (x - 3)*(x - 3) + SL.RLibm.exp(0.2*x)\ng1(x) = 2*(x - 3) + 0.2*SL.RLibm.exp(0.2*x)\nh1(x) = fill(2 + 0.04*SL.RLibm.exp(0.2*x), 1, 1)\n"

## ── ohne Schranken: drmnf / drmng / drmnh ──────────────────────────────
cs("fr_f", paste0(FR_R, sprintf(NL, "nlminb(c(-1.2, 1), fr)")),
   paste0(FR_P, "result = st.nlminb(np.array([-1.2, 1]), fr)"),
   paste0(FR_J, "result = st.nlminb([-1.2, 1.0], fr)"), wrap = FALSE)
cs("fr_g", paste0(FR_R, sprintf(NL, "nlminb(c(-1.2, 1), fr, grr)")),
   paste0(FR_P, "result = st.nlminb(np.array([-1.2, 1]), fr, grr)"),
   paste0(FR_J, "result = st.nlminb([-1.2, 1.0], fr, grr)"), wrap = FALSE)
cs("fr_h", paste0(FR_R, sprintf(NL, "nlminb(c(-1.2, 1), fr, grr, hsr)")),
   paste0(FR_P, "result = st.nlminb(np.array([-1.2, 1]), fr, grr, hsr)"),
   paste0(FR_J, "result = st.nlminb([-1.2, 1.0], fr, grr, hsr)"), wrap = FALSE)
cs("fr_f_far", paste0(FR_R, sprintf(NL, "nlminb(c(3, -4), fr)")),
   paste0(FR_P, "result = st.nlminb(np.array([3.0, -4]), fr)"),
   paste0(FR_J, "result = st.nlminb([3.0, -4.0], fr)"), wrap = FALSE)
cs("fq_f", paste0(FQ_R, sprintf(NL, "nlminb(c(0.5, -0.3, 1), fq)")),
   paste0(FQ_P, "result = st.nlminb(np.array([0.5, -0.3, 1]), fq)"),
   paste0(FQ_J, "result = st.nlminb([0.5, -0.3, 1], fq)"), wrap = FALSE)
cs("fq_g", paste0(FQ_R, sprintf(NL, "nlminb(c(0.5, -0.3, 1), fq, gq)")),
   paste0(FQ_P, "result = st.nlminb(np.array([0.5, -0.3, 1]), fq, gq)"),
   paste0(FQ_J, "result = st.nlminb([0.5, -0.3, 1], fq, gq)"), wrap = FALSE)
cs("fq_h", paste0(FQ_R, sprintf(NL, "nlminb(c(0.5, -0.3, 1), fq, gq, hq)")),
   paste0(FQ_P, "result = st.nlminb(np.array([0.5, -0.3, 1]), fq, gq, hq)"),
   paste0(FQ_J, "result = st.nlminb([0.5, -0.3, 1], fq, gq, hq)"), wrap = FALSE)
cs("fq_scale", paste0(FQ_R, sprintf(NL, "nlminb(c(0.5, -0.3, 1), fq, scale = c(1, 10, 0.1))")),
   paste0(FQ_P, "result = st.nlminb(np.array([0.5, -0.3, 1]), fq, scale=np.array([1, 10, 0.1]))"),
   paste0(FQ_J, "result = st.nlminb([0.5, -0.3, 1], fq; scale = [1, 10, 0.1])"), wrap = FALSE)
cs("fq_scale_h", paste0(FQ_R, sprintf(NL, "nlminb(c(0.5, -0.3, 1), fq, gq, hq, scale = 3)")),
   paste0(FQ_P, "result = st.nlminb(np.array([0.5, -0.3, 1]), fq, gq, hq, scale=3)"),
   paste0(FQ_J, "result = st.nlminb([0.5, -0.3, 1], fq, gq, hq; scale = 3)"), wrap = FALSE)
cs("f1_f", paste0(F1_R, sprintf(NL, "nlminb(0, f1)")),
   paste0(F1_P, "result = st.nlminb(0, f1)"), paste0(F1_J, "result = st.nlminb(0.0, f1)"), wrap = FALSE)
cs("f1_g", paste0(F1_R, sprintf(NL, "nlminb(0, f1, g1)")),
   paste0(F1_P, "result = st.nlminb(0, f1, g1)"), paste0(F1_J, "result = st.nlminb(0.0, f1, g1)"), wrap = FALSE)
cs("f1_h", paste0(F1_R, sprintf(NL, "nlminb(0, f1, g1, h1)")),
   paste0(F1_P, "result = st.nlminb(0, f1, g1, h1)"), paste0(F1_J, "result = st.nlminb(0.0, f1, g1, h1)"), wrap = FALSE)
# benannte Startwerte und zusätzliche Argumente (...)
cs("named_dots", paste0("fd <- function(p, a, b) (p['u'] - a)^2 + 3 * (p['v'] - b)^2 + p['u'] * p['v'];", sprintf(NL, "nlminb(c(u = 1, v = 2), fd, a = 0.5, b = -1)")),
   "def fd(p, a, b):\n    u = p['u']; v = p['v']\n    return (u - a)*(u - a) + 3*((v - b)*(v - b)) + u*v\nresult = st.nlminb(pd.Series([1.0, 2.0], index=['u', 'v']), fd, a=0.5, b=-1)",
   "fd(p; a, b) = (p[\"u\"] - a)*(p[\"u\"] - a) + 3*((p[\"v\"] - b)*(p[\"v\"] - b)) + p[\"u\"]*p[\"v\"]\nresult = st.nlminb(SL.RVector([1.0, 2.0]; names = [\"u\", \"v\"]), fd; a = 0.5, b = -1)", wrap = FALSE)
cs("named_arglist", paste0("fa <- function(p, arglist) { w <- arglist$w; s <- 0; for (i in seq_along(p)) s <- s + w[i] * (p[i] - i)^2; s };", sprintf(NL, "nlminb(c(a = 0, b = 0, c = 0), fa, arglist = list(w = c(1, 4, 9)), scale = 1/c(1, 2, 3))")),
   "def fa(p, arglist):\n    w = arglist['w']; s = 0.0\n    for i in range(len(p)):\n        d = p.iloc[i] - (i + 1)\n        s = s + w[i]*(d*d)\n    return s\nresult = st.nlminb(pd.Series([0.0, 0, 0], index=['a', 'b', 'c']), fa, arglist={'w': np.array([1.0, 4, 9])}, scale=1/np.array([1, 2, 3.0]))",
   "function fa(p; arglist)\n    w = arglist[\"w\"]; s = 0.0\n    for i in 1:length(p.values)\n        d = p[i] - i\n        s = s + w[i]*(d*d)\n    end\n    s\nend\nresult = st.nlminb(SL.RVector([0.0, 0, 0]; names = [\"a\", \"b\", \"c\"]), fa; arglist = Dict(\"w\" => [1.0, 4, 9]), scale = 1 ./ [1, 2, 3.0])", wrap = FALSE)

## ── mit Schranken: drmnfb / drmngb / drmnhb ────────────────────────────
for (v in c("f", "g", "h")) {
  ar <- switch(v, f = "fr", g = "fr, grr", h = "fr, grr, hsr")
  cs(paste0("fr_b_", v), paste0(FR_R, sprintf(NL, sprintf("nlminb(c(-1.2, 1), %s, lower = -5, upper = 5)", ar))),
     paste0(FR_P, sprintf("result = st.nlminb(np.array([-1.2, 1]), %s, lower=-5, upper=5)", ar)),
     paste0(FR_J, sprintf("result = st.nlminb([-1.2, 1.0], %s; lower = -5, upper = 5)", ar)), wrap = FALSE)
  cs(paste0("fr_bact_", v), paste0(FR_R, sprintf(NL, sprintf("nlminb(c(-1.2, 1), %s, lower = c(-2, 1.5), upper = c(2, 3))", ar))),
     paste0(FR_P, sprintf("result = st.nlminb(np.array([-1.2, 1]), %s, lower=np.array([-2, 1.5]), upper=np.array([2, 3]))", ar)),
     paste0(FR_J, sprintf("result = st.nlminb([-1.2, 1.0], %s; lower = [-2, 1.5], upper = [2, 3])", ar)), wrap = FALSE)
  cs(paste0("fr_bout_", v), paste0(FR_R, sprintf(NL, sprintf("nlminb(c(3, 3), %s, lower = c(-2, 1.5), upper = c(0.5, 3))", ar))),
     paste0(FR_P, sprintf("result = st.nlminb(np.array([3.0, 3]), %s, lower=np.array([-2, 1.5]), upper=np.array([0.5, 3]))", ar)),
     paste0(FR_J, sprintf("result = st.nlminb([3.0, 3.0], %s; lower = [-2, 1.5], upper = [0.5, 3])", ar)), wrap = FALSE)
  arq <- switch(v, f = "fq", g = "fq, gq", h = "fq, gq, hq")
  cs(paste0("fq_b_", v), paste0(FQ_R, sprintf(NL, sprintf("nlminb(c(0.5, -0.3, 1), %s, lower = c(0, -Inf, 0.2), upper = c(0.1, 0, 0.5))", arq))),
     paste0(FQ_P, sprintf("result = st.nlminb(np.array([0.5, -0.3, 1]), %s, lower=np.array([0, -math.inf, 0.2]), upper=np.array([0.1, 0, 0.5]))", arq)),
     paste0(FQ_J, sprintf("result = st.nlminb([0.5, -0.3, 1], %s; lower = [0, -Inf, 0.2], upper = [0.1, 0, 0.5])", arq)), wrap = FALSE)
  cs(paste0("fq_bfix_", v), paste0(FQ_R, sprintf(NL, sprintf("nlminb(c(0.5, -0.3, 1), %s, lower = c(-1, -0.3, -1), upper = c(1, -0.3, 1))", arq))),
     paste0(FQ_P, sprintf("result = st.nlminb(np.array([0.5, -0.3, 1]), %s, lower=np.array([-1, -0.3, -1]), upper=np.array([1, -0.3, 1]))", arq)),
     paste0(FQ_J, sprintf("result = st.nlminb([0.5, -0.3, 1], %s; lower = [-1, -0.3, -1], upper = [1, -0.3, 1])", arq)), wrap = FALSE)
  ar1 <- switch(v, f = "f1", g = "f1, g1", h = "f1, g1, h1")
  cs(paste0("f1_b_", v), paste0(F1_R, sprintf(NL, sprintf("nlminb(0.5, %s, lower = 0, upper = 1)", ar1))),
     paste0(F1_P, sprintf("result = st.nlminb(0.5, %s, lower=0, upper=1)", ar1)),
     paste0(F1_J, sprintf("result = st.nlminb(0.5, %s; lower = 0, upper = 1)", ar1)), wrap = FALSE)
}
cs("allfixed", paste0(FQ_R, sprintf(NL, "nlminb(c(0.5, 0.5, 0.5), fq, lower = c(1, 1, 1), upper = c(1, 1, 1))")),
   paste0(FQ_P, "result = st.nlminb(np.array([0.5, 0.5, 0.5]), fq, lower=np.array([1.0, 1, 1]), upper=np.array([1.0, 1, 1]))"),
   paste0(FQ_J, "result = st.nlminb([0.5, 0.5, 0.5], fq; lower = [1.0, 1, 1], upper = [1.0, 1, 1])"), wrap = FALSE)
cs("lower_only", "nlminb(5, function(x) (x - 1)^2 + 0.5 * x, lower = 1)",
   "result = st.nlminb(5, lambda x: (x[0] - 1)*(x[0] - 1) + 0.5*x[0], lower=1)",
   "result = st.nlminb(5.0, x -> (x - 1)*(x - 1) + 0.5*x; lower = 1)")
cs("upper_only_g", "nlminb(c(-3, 4), function(x) (x[1] + 1)^2 + (x[2] - 2)^2, function(x) c(2 * (x[1] + 1), 2 * (x[2] - 2)), upper = c(Inf, 1))",
   "result = st.nlminb(np.array([-3.0, 4]), lambda x: (x[0] + 1)*(x[0] + 1) + (x[1] - 2)*(x[1] - 2), lambda x: np.array([2*(x[0] + 1), 2*(x[1] - 2)]), upper=np.array([math.inf, 1]))",
   "result = st.nlminb([-3.0, 4], x -> (x[1] + 1)*(x[1] + 1) + (x[2] - 2)*(x[2] - 2), x -> [2*(x[1] + 1), 2*(x[2] - 2)]; upper = [Inf, 1])")

## ── control ─────────────────────────────────────────────────────────────
cs("ctl_evalmax", paste0(FR_R, sprintf(NL, "nlminb(c(-1.2, 1), fr, control = list(eval.max = 10))")),
   paste0(FR_P, "result = st.nlminb(np.array([-1.2, 1]), fr, control={'eval.max': 10})"),
   paste0(FR_J, "result = st.nlminb([-1.2, 1.0], fr; control = (; Symbol(\"eval.max\") => 10))"), wrap = FALSE)
cs("ctl_itermax", paste0(FR_R, sprintf(NL, "nlminb(c(-1.2, 1), fr, grr, lower = -5, upper = 5, control = list(iter.max = 5))")),
   paste0(FR_P, "result = st.nlminb(np.array([-1.2, 1]), fr, grr, lower=-5, upper=5, control={'iter.max': 5})"),
   paste0(FR_J, "result = st.nlminb([-1.2, 1.0], fr, grr; lower = -5, upper = 5, control = [\"iter.max\" => 5])"), wrap = FALSE)
cs("ctl_maxiter_partial", paste0(FR_R, sprintf(NL, "nlminb(c(-1.2, 1), fr, grr, hsr, control = list(maxit = 3, eval = 50))")),
   paste0(FR_P, "result = st.nlminb(np.array([-1.2, 1]), fr, grr, hsr, control={'maxit': 3, 'eval': 50})"),
   paste0(FR_J, "result = st.nlminb([-1.2, 1.0], fr, grr, hsr; control = [\"maxit\" => 3, \"eval\" => 50])"), wrap = FALSE)
cs("ctl_trace", paste0(FQ_R, sprintf(NL, "nlminb(c(0.5, -0.3, 1), fq, control = list(trace = 1))")),
   paste0(FQ_P, "result = st.nlminb(np.array([0.5, -0.3, 1]), fq, control={'trace': 1})"),
   paste0(FQ_J, "result = st.nlminb([0.5, -0.3, 1], fq; control = [\"trace\" => 1])"), wrap = FALSE)
cs("ctl_trace3_b", paste0(FR_R, sprintf(NL, "nlminb(c(-1.2, 1), fr, grr, lower = c(-2, 1.5), upper = c(2, 3), control = list(trace = 3))")),
   paste0(FR_P, "result = st.nlminb(np.array([-1.2, 1]), fr, grr, lower=np.array([-2, 1.5]), upper=np.array([2, 3]), control={'trace': 3})"),
   paste0(FR_J, "result = st.nlminb([-1.2, 1.0], fr, grr; lower = [-2, 1.5], upper = [2, 3], control = [\"trace\" => 3])"), wrap = FALSE)
cs("ctl_trace_h", paste0(FR_R, sprintf(NL, "nlminb(c(-1.2, 1), fr, grr, hsr, control = list(trace = 2))")),
   paste0(FR_P, "result = st.nlminb(np.array([-1.2, 1]), fr, grr, hsr, control={'trace': 2})"),
   paste0(FR_J, "result = st.nlminb([-1.2, 1.0], fr, grr, hsr; control = [\"trace\" => 2])"), wrap = FALSE)
cs("ctl_tols", paste0(FQ_R, sprintf(NL, "nlminb(c(0.5, -0.3, 1), fq, control = list(rel.tol = 1e-4, x.tol = 1e-3, xf.tol = 1e-10, abs.tol = 1e-3))")),
   paste0(FQ_P, "result = st.nlminb(np.array([0.5, -0.3, 1]), fq, control={'rel.tol': 1e-4, 'x.tol': 1e-3, 'xf.tol': 1e-10, 'abs.tol': 1e-3})"),
   paste0(FQ_J, "result = st.nlminb([0.5, -0.3, 1], fq; control = [\"rel.tol\" => 1e-4, \"x.tol\" => 1e-3, \"xf.tol\" => 1e-10, \"abs.tol\" => 1e-3])"), wrap = FALSE)
cs("ctl_abstol", "nlminb(5, function(x) (x - 1)^2, control = list(abs.tol = 1e-10))",
   "result = st.nlminb(5, lambda x: (x[0] - 1)*(x[0] - 1), control={'abs.tol': 1e-10})",
   "result = st.nlminb(5.0, x -> (x - 1)*(x - 1); control = [\"abs.tol\" => 1e-10])")
cs("ctl_steps", paste0(FR_R, sprintf(NL, "nlminb(c(-1.2, 1), fr, control = list(step.min = 0.01, step.max = 0.1, sing.tol = 1e-8, scale.init = 2, diff.g = 1e-6))")),
   paste0(FR_P, "result = st.nlminb(np.array([-1.2, 1]), fr, control={'step.min': 0.01, 'step.max': 0.1, 'sing.tol': 1e-8, 'scale.init': 2, 'diff.g': 1e-6})"),
   paste0(FR_J, "result = st.nlminb([-1.2, 1.0], fr; control = [\"step.min\" => 0.01, \"step.max\" => 0.1, \"sing.tol\" => 1e-8, \"scale.init\" => 2, \"diff.g\" => 1e-6])"), wrap = FALSE)
cs("ctl_steps_bh", paste0(FQ_R, sprintf(NL, "nlminb(c(0.5, -0.3, 1), fq, gq, hq, lower = -0.5, upper = 0.6, control = list(step.min = 1e-3, step.max = 1e-2))")),
   paste0(FQ_P, "result = st.nlminb(np.array([0.5, -0.3, 1]), fq, gq, hq, lower=-0.5, upper=0.6, control={'step.min': 1e-3, 'step.max': 1e-2})"),
   paste0(FQ_J, "result = st.nlminb([0.5, -0.3, 1], fq, gq, hq; lower = -0.5, upper = 0.6, control = [\"step.min\" => 1e-3, \"step.max\" => 1e-2])"), wrap = FALSE)
cs("ctl_relrange", "nlminb(1, function(x) (x - 2)^2, control = list(rel.tol = 1))",
   "result = st.nlminb(1, lambda x: (x[0] - 2)*(x[0] - 2), control={'rel.tol': 1})",
   "result = st.nlminb(1.0, x -> (x - 2)*(x - 2); control = [\"rel.tol\" => 1])")
cs("ctl_difgrange", "nlminb(1, function(x) (x - 2)^2, control = list(diff.g = 2))",
   "result = st.nlminb(1, lambda x: (x[0] - 2)*(x[0] - 2), control={'diff.g': 2})",
   "result = st.nlminb(1.0, x -> (x - 2)*(x - 2); control = [\"diff.g\" => 2])")
cs("ctl_unknown1", "nlminb(1, function(x) (x - 2)^2, control = list(foo = 1))",
   "result = st.nlminb(1, lambda x: (x[0] - 2)*(x[0] - 2), control={'foo': 1})",
   "result = st.nlminb(1.0, x -> (x - 2)*(x - 2); control = [\"foo\" => 1])")
cs("ctl_unknown2", "nlminb(1, function(x) (x - 2)^2, control = list(foo = 1, x = 2, eval = 3))",
   "result = st.nlminb(1, lambda x: (x[0] - 2)*(x[0] - 2), control={'foo': 1, 'x': 2, 'eval': 3})",
   "result = st.nlminb(1.0, x -> (x - 2)*(x - 2); control = [\"foo\" => 1, \"x\" => 2, \"eval\" => 3])")
cs("ctl_unknown_mixed", "nlminb(1, function(x) (x - 2)^2, control = list(rel.tol = 1e-12, s = 1))",
   "result = st.nlminb(1, lambda x: (x[0] - 2)*(x[0] - 2), control={'rel.tol': 1e-12, 's': 1})",
   "result = st.nlminb(1.0, x -> (x - 2)*(x - 2); control = [\"rel.tol\" => 1e-12, \"s\" => 1])")
cs("ctl_tracebool", "nlminb(c(1, 1), function(x) (x[1] - 2)^2 + (x[2] + 1)^4, control = list(trace = TRUE, iter.max = 6))",
   "result = st.nlminb(np.array([1.0, 1]), lambda x: (x[0] - 2)*(x[0] - 2) + math.pow(float(x[1]) + 1, 4), control={'trace': True, 'iter.max': 6})",
   "result = st.nlminb([1.0, 1], x -> (x[1] - 2)*(x[1] - 2) + SL.RLibm.pow(x[2] + 1, 4); control = [\"trace\" => true, \"iter.max\" => 6])")

cs("ctl_na_rel", "nlminb(1, function(x) (x - 2)^2, control = list(rel.tol = NA))",
   "result = st.nlminb(1, lambda x: (x[0] - 2)*(x[0] - 2), control={'rel.tol': simlev.NA})",
   "result = st.nlminb(1.0, x -> (x - 2)*(x - 2); control = [\"rel.tol\" => SL.NA])")
cs("ctl_na_eval", "nlminb(1, function(x) (x - 2)^2, control = list(eval.max = NA))",
   "result = st.nlminb(1, lambda x: (x[0] - 2)*(x[0] - 2), control={'eval.max': simlev.NA})",
   "result = st.nlminb(1.0, x -> (x - 2)*(x - 2); control = [\"eval.max\" => SL.NA])")
cs("ctl_big_eval", "nlminb(1, function(x) (x - 2)^2, control = list(eval.max = 3e9))",
   "result = st.nlminb(1, lambda x: (x[0] - 2)*(x[0] - 2), control={'eval.max': 3e9})",
   "result = st.nlminb(1.0, x -> (x - 2)*(x - 2); control = [\"eval.max\" => 3e9])")
cs("ctl_iter0", "nlminb(1, function(x) (x - 2)^2, control = list(iter.max = 0))",
   "result = st.nlminb(1, lambda x: (x[0] - 2)*(x[0] - 2), control={'iter.max': 0})",
   "result = st.nlminb(1.0, x -> (x - 2)*(x - 2); control = [\"iter.max\" => 0])")
cs("ctl_eval1", "nlminb(1, function(x) (x - 2)^2, control = list(eval.max = 1))",
   "result = st.nlminb(1, lambda x: (x[0] - 2)*(x[0] - 2), control={'eval.max': 1})",
   "result = st.nlminb(1.0, x -> (x - 2)*(x - 2); control = [\"eval.max\" => 1])")
cs("ctl_abs_neg", "nlminb(1, function(x) (x - 2)^2, control = list(abs.tol = -1))",
   "result = st.nlminb(1, lambda x: (x[0] - 2)*(x[0] - 2), control={'abs.tol': -1})",
   "result = st.nlminb(1.0, x -> (x - 2)*(x - 2); control = [\"abs.tol\" => -1])")
cs("ctl_stepmin0", "nlminb(1, function(x) (x - 2)^2, control = list(step.min = 0))",
   "result = st.nlminb(1, lambda x: (x[0] - 2)*(x[0] - 2), control={'step.min': 0})",
   "result = st.nlminb(1.0, x -> (x - 2)*(x - 2); control = [\"step.min\" => 0])")
cs("scale_na", "nlminb(c(1, 2), function(x) (x[1] - 2)^2 + x[2]^2, scale = c(1, NA))",
   "result = st.nlminb(np.array([1.0, 2]), lambda x: (x[0] - 2)*(x[0] - 2) + x[1]*x[1], scale=np.array([1, simlev.NA]))",
   "result = st.nlminb([1.0, 2], x -> (x[1] - 2)*(x[1] - 2) + x[2]*x[2]; scale = [1, SL.NA])")
cs("obj_vec", "nlminb(1, function(x) c(3, 4))", "result = st.nlminb(1, lambda x: np.array([3.0, 4]))",
   "result = st.nlminb(1.0, x -> [3.0, 4])")
cs("obj_chr", "nlminb(1, function(x) 'a')", "result = st.nlminb(1, lambda x: 'a')", "result = st.nlminb(1.0, x -> \"a\")")
cs("obj_null", "nlminb(1, function(x) NULL)", "result = st.nlminb(1, lambda x: None)", "result = st.nlminb(1.0, x -> nothing)")
cs("obj_lgl", "nlminb(c(0, 0), function(x) x[1] > 0.5 || x[2] < -0.5, lower = -1, upper = 1)",
   "result = st.nlminb(np.array([0.0, 0]), lambda x: bool(x[0] > 0.5 or x[1] < -0.5), lower=-1, upper=1)",
   "result = st.nlminb([0.0, 0], x -> x[1] > 0.5 || x[2] < -0.5; lower = -1, upper = 1)")

## ── Sonderfälle, Fehlschläge, Fehler ────────────────────────────────────
cs("nan_start", "nlminb(1, function(x) NaN)",
   "result = st.nlminb(1, lambda x: math.nan)", "result = st.nlminb(1.0, x -> NaN)")
cs("na_start_b", "nlminb(c(1, 2), function(x) NA, lower = 0)",
   "result = st.nlminb(np.array([1.0, 2]), lambda x: simlev.NA, lower=0)", "result = st.nlminb([1.0, 2], x -> SL.NA; lower = 0)")
cs("nan_region", paste0("fn <- function(x) if (x[1] > 1.5) NaN else (x[1] - 2)^2 + (x[2] - 1)^2;", sprintf(NL, "nlminb(c(0, 0), fn)")),
   "def fn(x):\n    if x[0] != x[0]:\n        raise ValueError('missing value where TRUE/FALSE needed')\n    return math.nan if x[0] > 1.5 else (x[0] - 2)*(x[0] - 2) + (x[1] - 1)*(x[1] - 1)\nresult = st.nlminb(np.array([0.0, 0]), fn)",
   "fn(x) = isnan(x[1]) ? error(\"missing value where TRUE/FALSE needed\") : x[1] > 1.5 ? NaN : (x[1] - 2)*(x[1] - 2) + (x[2] - 1)*(x[2] - 1)\nresult = st.nlminb([0.0, 0], fn)", wrap = FALSE)
cs("inf_region_g", paste0("fn <- function(x) if (x[1] * x[1] + x[2] * x[2] > 4) Inf else (x[1] - 3)^2 + x[2]^2; gn <- function(x) c(2 * (x[1] - 3), 2 * x[2]);", sprintf(NL, "nlminb(c(0, 1), fn, gn)")),
   "def fn(x):\n    return math.inf if x[0]*x[0] + x[1]*x[1] > 4 else (x[0] - 3)*(x[0] - 3) + x[1]*x[1]\ndef gn(x):\n    return np.array([2*(x[0] - 3), 2*x[1]])\nresult = st.nlminb(np.array([0.0, 1]), fn, gn)",
   "fn(x) = x[1]*x[1] + x[2]*x[2] > 4 ? Inf : (x[1] - 3)*(x[1] - 3) + x[2]*x[2]\ngn(x) = [2*(x[1] - 3), 2*x[2]]\nresult = st.nlminb([0.0, 1], fn, gn)", wrap = FALSE)
cs("singular", "nlminb(c(1, 1), function(x) (x[1] + x[2])^2)",
   "result = st.nlminb(np.array([1.0, 1]), lambda x: (x[0] + x[1])*(x[0] + x[1]))",
   "result = st.nlminb([1.0, 1], x -> (x[1] + x[2])*(x[1] + x[2]))")
cs("kink", "nlminb(1, function(x) abs(x - 0.3))",
   "result = st.nlminb(1, lambda x: abs(x[0] - 0.3))", "result = st.nlminb(1.0, x -> abs(x - 0.3))")
cs("falseconv", "nlminb(c(2, 2), function(x) sqrt(abs(x[1])) + abs(x[2]))",
   "result = st.nlminb(np.array([2.0, 2]), lambda x: math.sqrt(abs(x[0])) + abs(x[1]))",
   "result = st.nlminb([2.0, 2], x -> sqrt(abs(x[1])) + abs(x[2]))")
cs("unbounded_below", "nlminb(1, function(x) -exp(x), control = list(eval.max = 30, iter.max = 30))",
   "result = st.nlminb(1, lambda x: -libm.exp(float(x[0])), control={'eval.max': 30, 'iter.max': 30})",
   "result = st.nlminb(1.0, x -> -SL.RLibm.exp(x); control = [\"eval.max\" => 30, \"iter.max\" => 30])")
cs("bad_bounds", "nlminb(1, function(x) (x - 2)^2, lower = 3, upper = 1)",
   "result = st.nlminb(1, lambda x: (x[0] - 2)*(x[0] - 2), lower=3, upper=1)",
   "result = st.nlminb(1.0, x -> (x - 2)*(x - 2); lower = 3, upper = 1)")
cs("bad_scale", "nlminb(c(1, 1), function(x) (x[1] - 2)^2 + x[2]^2, scale = c(1, -1))",
   "result = st.nlminb(np.array([1.0, 1]), lambda x: (x[0] - 2)*(x[0] - 2) + x[1]*x[1], scale=np.array([1, -1]))",
   "result = st.nlminb([1.0, 1], x -> (x[1] - 2)*(x[1] - 2) + x[2]*x[2]; scale = [1, -1])")
cs("err_lower_na", "nlminb(1, function(x) (x - 2)^2, lower = NA)",
   "result = st.nlminb(1, lambda x: (x[0] - 2)*(x[0] - 2), lower=simlev.NA)",
   "result = st.nlminb(1.0, x -> (x - 2)*(x - 2); lower = SL.NA)")
cs("err_empty", "nlminb(numeric(0), function(x) 1)",
   "result = st.nlminb(np.array([]), lambda x: 1.0)", "result = st.nlminb(Float64[], x -> 1.0)")
cs("err_fn", "nlminb(1, function(x) stop('Abbruch in der Zielfunktion'))",
   "def fn(x):\n    raise ValueError('Abbruch in der Zielfunktion')\nresult = st.nlminb(1, fn)",
   "fn(x) = error(\"Abbruch in der Zielfunktion\")\nresult = st.nlminb(1.0, fn)")
cs("err_gr_len", "nlminb(1, function(x) (x - 2)^2, function(x) c(1, 2))",
   "result = st.nlminb(1, lambda x: (x[0] - 2)*(x[0] - 2), lambda x: np.array([1.0, 2]))",
   "result = st.nlminb(1.0, x -> (x - 2)*(x - 2), x -> [1.0, 2])")
cs("err_gr_na", "nlminb(c(1, 2), function(x) (x[1] - 2)^2 + x[2]^2, function(x) c(NA, 1), lower = 0)",
   "result = st.nlminb(np.array([1.0, 2]), lambda x: (x[0] - 2)*(x[0] - 2) + x[1]*x[1], lambda x: np.array([simlev.NA, 1]), lower=0)",
   "result = st.nlminb([1.0, 2], x -> (x[1] - 2)*(x[1] - 2) + x[2]*x[2], x -> [SL.NA, 1]; lower = 0)")
cs("err_hess_lgl", "nlminb(1, function(x) (x - 2)^2, function(x) 2 * (x - 2), TRUE)",
   "result = st.nlminb(1, lambda x: (x[0] - 2)*(x[0] - 2), lambda x: 2*(x[0] - 2), True)",
   "result = st.nlminb(1.0, x -> (x - 2)*(x - 2), x -> 2*(x - 2), true)")
cs("err_hess_dim", "nlminb(1, function(x) (x - 2)^2, function(x) 2 * (x - 2), function(x) 2)",
   "result = st.nlminb(1, lambda x: (x[0] - 2)*(x[0] - 2), lambda x: 2*(x[0] - 2), lambda x: 2.0)",
   "result = st.nlminb(1.0, x -> (x - 2)*(x - 2), x -> 2*(x - 2), x -> 2.0)")
cs("err_hess_int", "nlminb(1, function(x) (x - 2)^2, function(x) 2 * (x - 2), function(x) matrix(2L))",
   "result = st.nlminb(1, lambda x: (x[0] - 2)*(x[0] - 2), lambda x: 2*(x[0] - 2), lambda x: np.array([[2]]))",
   "result = st.nlminb(1.0, x -> (x - 2)*(x - 2), x -> 2*(x - 2), x -> fill(2, 1, 1))")
cs("err_hess_na", "nlminb(c(1, 1), function(x) (x[1] - 2)^2 + x[2]^2, function(x) c(2 * (x[1] - 2), 2 * x[2]), function(x) matrix(c(2, NaN, 0, 2), 2), lower = -1, upper = 3)",
   "result = st.nlminb(np.array([1.0, 1]), lambda x: (x[0] - 2)*(x[0] - 2) + x[1]*x[1], lambda x: np.array([2*(x[0] - 2), 2*x[1]]), lambda x: np.array([[2.0, 0], [math.nan, 2]]), lower=-1, upper=3)",
   "result = st.nlminb([1.0, 1], x -> (x[1] - 2)*(x[1] - 2) + x[2]*x[2], x -> [2*(x[1] - 2), 2*x[2]], x -> [2.0 0; NaN 2]; lower = -1, upper = 3)")
cs("hess_upper_ignored", "nlminb(c(1, 1), function(x) (x[1] - 2)^2 + x[2]^2, function(x) c(2 * (x[1] - 2), 2 * x[2]), function(x) matrix(c(2, 0, 99, 2), 2))",
   "result = st.nlminb(np.array([1.0, 1]), lambda x: (x[0] - 2)*(x[0] - 2) + x[1]*x[1], lambda x: np.array([2*(x[0] - 2), 2*x[1]]), lambda x: np.array([[2.0, 99], [0, 2]]))",
   "result = st.nlminb([1.0, 1], x -> (x[1] - 2)*(x[1] - 2) + x[2]*x[2], x -> [2*(x[1] - 2), 2*x[2]], x -> [2.0 99; 0 2])")
cs("hess_without_gr", "nlminb(1, function(x) (x - 2)^2, NULL, function(x) matrix(2))",
   "result = st.nlminb(1, lambda x: (x[0] - 2)*(x[0] - 2), None, lambda x: np.array([[2.0]]))",
   "result = st.nlminb(1.0, x -> (x - 2)*(x - 2), nothing, x -> fill(2.0, 1, 1))")
cs("indef_hess", "fi <- function(x) x[1]^4 - 3 * x[1]^2 + x[2]^2 + x[1] * x[2]; gi <- function(x) c(4 * x[1]^3 - 6 * x[1] + x[2], 2 * x[2] + x[1]); hi <- function(x) matrix(c(12 * x[1]^2 - 6, 1, 1, 2), 2); list(nlminb(c(0.1, 0.1), fi, gi, hi)[c('par', 'objective', 'iterations', 'evaluations', 'message')], nlminb(c(0, 0), fi, gi, hi, lower = c(-0.5, -1), upper = c(0.5, 1))[c('par', 'objective', 'iterations', 'evaluations', 'message')])",
   "def fi(x):\n    a = float(x[0]); b = float(x[1])\n    return math.pow(a, 4) - 3*(a*a) + b*b + a*b\ndef gi(x):\n    a = float(x[0]); b = float(x[1])\n    return np.array([4*math.pow(a, 3) - 6*a + b, 2*b + a])\ndef hi(x):\n    a = float(x[0])\n    return np.array([[12*(a*a) - 6, 1.0], [1.0, 2.0]])\nks = ['par', 'objective', 'iterations', 'evaluations', 'message']\nr1 = st.nlminb(np.array([0.1, 0.1]), fi, gi, hi); r2 = st.nlminb(np.array([0.0, 0]), fi, gi, hi, lower=np.array([-0.5, -1]), upper=np.array([0.5, 1]))\nresult = [{k: r1[k] for k in ks}, {k: r2[k] for k in ks}]",
   "fi(x) = SL.RLibm.pow(x[1], 4) - 3*(x[1]*x[1]) + x[2]*x[2] + x[1]*x[2]\ngi(x) = [4*SL.RLibm.pow(x[1], 3) - 6*x[1] + x[2], 2*x[2] + x[1]]\nhi(x) = [12*(x[1]*x[1]) - 6 1.0; 1.0 2.0]\nks = [\"par\", \"objective\", \"iterations\", \"evaluations\", \"message\"]\nr1 = st.nlminb([0.1, 0.1], fi, gi, hi); r2 = st.nlminb([0.0, 0], fi, gi, hi; lower = [-0.5, -1], upper = [0.5, 1])\nresult = [SL.RList([k => r1[k] for k in ks]...), SL.RList([k => r2[k] for k in ks]...)]",
   wrap = FALSE)

## ── höhere Dimension (n = 8), quadratisch mit Kopplung ─────────────────
set.seed(5)
Mq <- matrix(rnorm(64), 8, 8); Aq <- crossprod(Mq) / 8 + diag(0.2, 8); bq <- rnorm(8)
QA_R <- "fA <- function(x) { s <- 0; for (i in 1:8) for (j in 1:8) s <- s + x[i] * (A[i, j] * x[j]); t <- 0; for (i in 1:8) t <- t + b[i] * x[i]; 0.5 * s - t }; gA <- function(x) { g <- numeric(8); for (i in 1:8) { u <- 0; for (j in 1:8) u <- u + A[i, j] * x[j]; g[i] <- u - b[i] }; g }; hA <- function(x) A;"
QA_P <- "def fA(x):\n    s = 0.0\n    for i in range(8):\n        for j in range(8):\n            s = s + x[i]*(A[i, j]*x[j])\n    t = 0.0\n    for i in range(8):\n        t = t + b[i]*x[i]\n    return 0.5*s - t\ndef gA(x):\n    g = np.zeros(8)\n    for i in range(8):\n        u = 0.0\n        for j in range(8):\n            u = u + A[i, j]*x[j]\n        g[i] = u - b[i]\n    return g\ndef hA(x):\n    return np.array(A, dtype=float)\n"
QA_J <- "function fA(x)\n    s = 0.0\n    for i in 1:8, j in 1:8\n        s = s + x[i]*(A[i, j]*x[j])\n    end\n    t = 0.0\n    for i in 1:8\n        t = t + b[i]*x[i]\n    end\n    0.5*s - t\nend\nfunction gA(x)\n    g = zeros(8)\n    for i in 1:8\n        u = 0.0\n        for j in 1:8\n            u = u + A[i, j]*x[j]\n        end\n        g[i] = u - b[i]\n    end\n    g\nend\nhA(x) = Matrix{Float64}(A)\n"
for (v in c("f", "g", "h")) {
  ar <- switch(v, f = "fA", g = "fA, gA", h = "fA, gA, hA")
  cs(paste0("q8_", v), paste0(QA_R, sprintf(NL, sprintf("nlminb(rep(0.1, 8), %s)", ar))),
     paste0(QA_P, sprintf("result = st.nlminb(np.full(8, 0.1), %s)", ar)),
     paste0(QA_J, sprintf("result = st.nlminb(fill(0.1, 8), %s)", ar)), inputs = list(A = Aq, b = bq), wrap = FALSE)
  cs(paste0("q8_b_", v), paste0(QA_R, sprintf(NL, sprintf("nlminb(rep(0.1, 8), %s, lower = c(-Inf, 0, 0, -1, -Inf, 0.2, -0.3, 0), upper = c(0.5, Inf, 0.4, 1, 0, 0.2, 0.3, Inf))", ar))),
     paste0(QA_P, sprintf("result = st.nlminb(np.full(8, 0.1), %s, lower=np.array([-math.inf, 0, 0, -1, -math.inf, 0.2, -0.3, 0]), upper=np.array([0.5, math.inf, 0.4, 1, 0, 0.2, 0.3, math.inf]))", ar)),
     paste0(QA_J, sprintf("result = st.nlminb(fill(0.1, 8), %s; lower = [-Inf, 0, 0, -1, -Inf, 0.2, -0.3, 0], upper = [0.5, Inf, 0.4, 1, 0, 0.2, 0.3, Inf])", ar)),
     inputs = list(A = Aq, b = bq), wrap = FALSE)
}
cs("q8_b_h_evalmax", paste0(QA_R, sprintf(NL, "nlminb(rep(0.1, 8), fA, gA, hA, lower = 0, upper = 0.5, scale = 1:8, control = list(eval.max = 4, scale.init = 0.5))")),
   paste0(QA_P, "result = st.nlminb(np.full(8, 0.1), fA, gA, hA, lower=0, upper=0.5, scale=np.arange(1, 9), control={'eval.max': 4, 'scale.init': 0.5})"),
   paste0(QA_J, "result = st.nlminb(fill(0.1, 8), fA, gA, hA; lower = 0, upper = 0.5, scale = 1:8, control = [\"eval.max\" => 4, \"scale.init\" => 0.5])"),
   inputs = list(A = Aq, b = bq), wrap = FALSE)
cs("q8_b_g_itermax", paste0(QA_R, sprintf(NL, "nlminb(rep(0.1, 8), fA, gA, lower = -0.2, upper = 0.3, control = list(iter.max = 3, trace = 1))")),
   paste0(QA_P, "result = st.nlminb(np.full(8, 0.1), fA, gA, lower=-0.2, upper=0.3, control={'iter.max': 3, 'trace': 1})"),
   paste0(QA_J, "result = st.nlminb(fill(0.1, 8), fA, gA; lower = -0.2, upper = 0.3, control = [\"iter.max\" => 3, \"trace\" => 1])"),
   inputs = list(A = Aq, b = bq), wrap = FALSE)

## ── GARCH-artige Likelihoods (wie rugarch über .nlminbsolver) ───────────
set.seed(42)
ng <- 600
zz <- rnorm(ng); hh <- numeric(ng); ee <- numeric(ng); hh[1] <- 1e-4
for (t in 1:ng) { if (t > 1) hh[t] <- 2e-6 + 0.08 * ee[t - 1]^2 + 0.9 * hh[t - 1]; ee[t] <- sqrt(hh[t]) * zz[t] }
rg <- 5e-4 + ee
set.seed(7)
rg2 <- rnorm(300) * 0.02 + c(rep(0, 200), rnorm(100) * 0.05)
rg3 <- rg[1:150] * 40

GL_R <- "gllh <- function(p, x, gjr = FALSE) { n <- length(x); e <- x - p[1]; s <- 0; for (t in 1:n) s <- s + e[t] * e[t]; h <- s / n; ll <- 0; for (t in 1:n) { if (t > 1) { a <- p[3]; if (gjr && e[t - 1] < 0) a <- a + p[5]; h <- p[2] + a * e[t - 1] * e[t - 1] + p[4] * h }; if (!is.finite(h) || h <= 0) return(1e10); ll <- ll + log(h) + e[t] * e[t] / h }; 0.5 * (n * log(2 * pi) + ll) };"
GL_P <- "def gllh(p, x, gjr=False):\n    p = [float(v) for v in p]; n = len(x); e = [float(v) - p[0] for v in x]\n    s = 0.0\n    for t in range(n):\n        s = s + e[t]*e[t]\n    h = s / n; ll = 0.0\n    for t in range(n):\n        if t > 0:\n            a = p[2]\n            if gjr and e[t - 1] < 0:\n                a = a + p[4]\n            h = p[1] + a*e[t - 1]*e[t - 1] + p[3]*h\n        if not math.isfinite(h) or h <= 0:\n            return 1e10\n        ll = ll + math.log(h) + e[t]*e[t]/h\n    return 0.5*(n*math.log(2*math.pi) + ll)\n"
GL_J <- "function gllh(p; x, gjr = false)\n    p = p isa SL.RVector ? Float64.(p.values) : Float64.(collect(p))\n    n = length(x); e = Float64[v - p[1] for v in x]\n    s = 0.0\n    for t in 1:n\n        s = s + e[t]*e[t]\n    end\n    h = s / n; ll = 0.0\n    for t in 1:n\n        if t > 1\n            a = p[3]\n            (gjr && e[t - 1] < 0) && (a = a + p[5])\n            h = p[2] + a*e[t - 1]*e[t - 1] + p[4]*h\n        end\n        (!isfinite(h) || h <= 0) && return 1e10\n        ll = ll + SL.RLibm.log(h) + e[t]*e[t]/h\n    end\n    0.5*(n*SL.RLibm.log(2*pi) + ll)\nend\n"
# Steuerwerte aus rugarch .nlminbctrl (bei solver.control = list())
RGC_R <- "list(eval.max = 2000, trace = 0, iter.max = 1500, abs.tol = 1e-20, rel.tol = 1e-10, x.tol = 1.5e-8, step.min = 2.2e-14)"
RGC_P <- "{'eval.max': 2000, 'trace': 0, 'iter.max': 1500, 'abs.tol': 1e-20, 'rel.tol': 1e-10, 'x.tol': 1.5e-8, 'step.min': 2.2e-14}"
RGC_J <- "[\"eval.max\" => 2000, \"trace\" => 0, \"iter.max\" => 1500, \"abs.tol\" => 1e-20, \"rel.tol\" => 1e-10, \"x.tol\" => 1.5e-8, \"step.min\" => 2.2e-14]"
garch_case <- function(id, x, gjr = FALSE, start = NULL, ctl = TRUE, scl = TRUE) {
  np <- if (gjr) 5 else 4
  nm <- c("mu", "omega", "alpha1", "beta1", if (gjr) "gamma1")
  st0 <- if (is.null(start)) c(mean(x), var(x) * 0.1, 0.05, 0.85, if (gjr) 0.05) else start
  ps <- c(abs(mean(x)), var(x), rep(1, np - 2))
  lb <- c(-100 * abs(mean(x)), var(x) / 1e5, rep(0, np - 2))
  ub <- c(100 * abs(mean(x)), var(x) * 1e5, 1, 1, if (gjr) 1)
  inp <- list(x = x, st0 = st0, ps = ps, lb = lb, ub = ub)
  cr <- if (ctl) RGC_R else "list()"; cp <- if (ctl) RGC_P else "{}"; cj <- if (ctl) RGC_J else "nothing"
  sr <- if (scl) "1/ps" else "1"; sp <- if (scl) "1/np.atleast_1d(ps)" else "1"; sj <- if (scl) "1 ./ ps" else "1"
  g <- if (gjr) "TRUE" else "FALSE"
  cs(id, paste0(GL_R, sprintf(NL, sprintf("nlminb(setNames(st0, c(%s)), gllh, x = x, gjr = %s, scale = %s, control = %s, lower = lb, upper = ub)",
                                         paste0("'", nm, "'", collapse = ", "), g, sr, cr))),
     paste0(GL_P, sprintf("result = st.nlminb(pd.Series(st0, index=[%s]), gllh, x=x, gjr=%s, scale=%s, control=%s, lower=lb, upper=ub)",
                          paste0("'", nm, "'", collapse = ", "), if (gjr) "True" else "False", sp, cp)),
     paste0(GL_J, sprintf("result = st.nlminb(SL.RVector(st0; names = [%s]), gllh; x = x, gjr = %s, scale = %s, control = %s, lower = lb, upper = ub)",
                          paste0("\"", nm, "\"", collapse = ", "), if (gjr) "true" else "false", sj, cj)),
     inputs = inp, wrap = FALSE)
}
garch_case("garch_s", rg)
garch_case("garch_gjr", rg, gjr = TRUE)
garch_case("garch_s_short", rg[1:120])
garch_case("garch_s_break", rg2)
garch_case("garch_gjr_break", rg2, gjr = TRUE)
garch_case("garch_s_bigvar", rg3)
garch_case("garch_s_nearint", rg, start = c(mean(rg), var(rg) * 0.01, 0.1, 0.89))
garch_case("garch_s_noctl", rg[1:300], ctl = FALSE, scl = FALSE)
garch_case("garch_gjr_noscale", rg[1:300], gjr = TRUE, scl = FALSE)
cs("garch_trace", paste0(GL_R, sprintf(NL, "nlminb(c(mean(x), var(x) * 0.1, 0.05, 0.85), gllh, x = x, scale = 1/c(abs(mean(x)), var(x), 1, 1), control = list(eval.max = 2000, trace = 1, iter.max = 1500, abs.tol = 1e-20, rel.tol = 1e-10, x.tol = 1.5e-8, step.min = 2.2e-14), lower = c(-1, 1e-12, 0, 0), upper = c(1, 1, 1, 1))")),
   paste0(GL_P, "m = rb.r_mean(x); vx = st.var(x)\nresult = st.nlminb(np.array([m, vx*0.1, 0.05, 0.85]), gllh, x=x, scale=1/np.array([abs(m), vx, 1, 1]), control={'eval.max': 2000, 'trace': 1, 'iter.max': 1500, 'abs.tol': 1e-20, 'rel.tol': 1e-10, 'x.tol': 1.5e-8, 'step.min': 2.2e-14}, lower=np.array([-1, 1e-12, 0, 0]), upper=np.array([1.0, 1, 1, 1]))"),
   paste0(GL_J, "m = SL.RBase.r_mean(x); vx = st.var(x)\nresult = st.nlminb([m, vx*0.1, 0.05, 0.85], gllh; x = x, scale = 1 ./ [abs(m), vx, 1, 1], control = [\"eval.max\" => 2000, \"trace\" => 1, \"iter.max\" => 1500, \"abs.tol\" => 1e-20, \"rel.tol\" => 1e-10, \"x.tol\" => 1.5e-8, \"step.min\" => 2.2e-14], lower = [-1, 1e-12, 0, 0], upper = [1.0, 1, 1, 1])"),
   inputs = list(x = rg[1:200]), wrap = FALSE)
# wie rugarch: Aufruf in try(), Fehler als Konvergenz 1
cs("garch_try_err", paste0(GL_R, "gbad <- function(p, x) if (p[3] > 0.06) stop('LLH nicht berechenbar') else gllh(p, x); r <- try(nlminb(c(mean(x), var(x) * 0.1, 0.05, 0.85), gbad, x = x, lower = c(-1, 1e-12, 0, 0), upper = c(1, 1, 1, 1)), silent = TRUE); inherits(r, 'try-error')"),
   paste0(GL_P, "def gbad(p, x):\n    if p[2] > 0.06:\n        raise ValueError('LLH nicht berechenbar')\n    return gllh(p, x)\nm = rb.r_mean(x); vx = st.var(x)\ntry:\n    st.nlminb(np.array([m, vx*0.1, 0.05, 0.85]), gbad, x=x, lower=np.array([-1, 1e-12, 0, 0]), upper=np.array([1.0, 1, 1, 1]))\n    result = False\nexcept ValueError:\n    result = True"),
   paste0(GL_J, "gbad(p; x) = p[3] > 0.06 ? error(\"LLH nicht berechenbar\") : gllh(p; x = x)\nm = SL.RBase.r_mean(x); vx = st.var(x)\nresult = try\n    st.nlminb([m, vx*0.1, 0.05, 0.85], gbad; x = x, lower = [-1, 1e-12, 0, 0], upper = [1.0, 1, 1, 1]); false\ncatch\n    true\nend"),
   inputs = list(x = rg[1:200]), wrap = FALSE)

ref_done()

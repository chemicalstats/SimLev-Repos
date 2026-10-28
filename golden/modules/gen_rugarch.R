# Referenzfälle für die aus rugarch 1.5-6 übernommene Fassung von ugarchspec/ugarchfit/coef
# (R: SimLev:::.rugarch_ugarchspec, .rugarch_ugarchfit, .rugarch_coef in r/R/vendor_rugarch.R,
# C-Filter in r/src/vendor_rugarch.c; Python: simlev/_r/rugarch.py, Julia: src/r/rugarch.jl),
# Rsolnp 1.16 solnp/gosolnp (SimLev:::.rsolnp_solnp, .rsolnp_gosolnp in r/R/vendor_rsolnp.R;
# simlev/_r/solnp.py, src/r/solnp.jl), truncnorm 1.0-9 rtruncnorm
# (SimLev:::.truncnorm_rtruncnorm, r/R/vendor_truncnorm.R, r/src/vendor_truncnorm.c;
# simlev/_r/truncnorm.py, src/r/truncnorm.jl) und den Weg über rugarch in .fit_garch11
# (bootstrap(…, "garch"/"gjr_garch"), dependence_dcc, dependence_analysis). Hesse-Matrix und Scores
# rechnet die eigenständige Richardson-Extrapolation (SimLev:::.sl_richardson_hessian,
# .sl_richardson_jacobian in r/R/richardson.R; Direktvergleich mit numDeriv als Orakel:
# golden/modules/check_richardson.R). rugarch, Rsolnp, numDeriv und truncnorm selbst werden
# nicht benötigt; die Fälle waren zuvor mit den echten Paketen erzeugt (rugarch 1.5-6,
# Rsolnp 1.16, numDeriv 2016.8-1.1, truncnorm 1.0-9) und sind mit der Übernahme bzw. der
# eigenen Richardson-Extrapolation bitgleich.
# Aufruf aus der Repo-Wurzel:
#   LC_ALL=C.UTF-8 R_LIBS=<R-Bibliothek mit SimLev> Rscript golden/modules/gen_rugarch.R
source("golden/modules/ref_tools.R"); ref_init("rugarch")

P <- paste0("import numpy as np\nimport pandas as pd\nfrom simlev._r import rugarch as RG\nfrom simlev._r import solnp as SN\n",
            "import simlev.bootstrap as B\nfrom simlev.bootstrap import *\nfrom simlev import dependence as D\n",
            "def UG(e, m='sGARCH'):\n    return RG.coef(RG.ugarchfit(e, model=m))\n",
            "def UGF(e, m='sGARCH'):\n    f = RG.ugarchfit(e, model=m, full=True)\n",
            "    return {'coef': f['coef'], 'LLH': f['LLH'], 'hessian': f['hessian'], 'cvar': f['cvar'], 'robust': f['robust_cvar'], 'scores': f['scores']}\n",
            "def S(a):\n    return {k: a[k] for k in ['pars', 'convergence', 'values', 'lagrange', 'hessian', 'ineqx0', 'nfuneval', 'outer.iter', 'vscale']}\n")
JP <- paste0("const RG = SL.RRugarch\nconst SN = SL.RSolnp\nconst B = SL.Bootstrap\nusing SimLev.Bootstrap\nconst D = SL.Dependence\n",
             "UG(e, m = \"sGARCH\") = RG.coef(RG.ugarchfit(e; model = m))\n",
             "function UGF(e, m = \"sGARCH\")\n    f = RG.ugarchfit(e; model = m, full = true)\n",
             "    SL.RList(\"coef\" => f[\"coef\"], \"LLH\" => f[\"LLH\"], \"hessian\" => f[\"hessian\"], \"cvar\" => f[\"cvar\"], \"robust\" => f[\"robust_cvar\"], \"scores\" => f[\"scores\"])\nend\n",
             "S(a) = SL.RList([k => a[k] for k in [\"pars\", \"convergence\", \"values\", \"lagrange\", \"hessian\", \"ineqx0\", \"nfuneval\", \"outer.iter\", \"vscale\"]]...)\n")
UG_R <- paste0("UG <- function(e, m = 'sGARCH', full = FALSE) {\n",
               "  spec <- SimLev:::.rugarch_ugarchspec(variance.model = list(model = m, garchOrder = c(1, 1)),\n",
               "    mean.model = list(armaOrder = c(0, 0), include.mean = TRUE), distribution.model = 'norm')\n",
               "  fit <- SimLev:::.rugarch_ugarchfit(spec = spec, data = e, solver = 'hybrid')\n",
               "  if (!full) return(SimLev:::.rugarch_coef(fit))\n",
               "  list(coef = SimLev:::.rugarch_coef(fit), LLH = fit$fit$LLH, hessian = fit$fit$hessian, cvar = fit$fit$cvar,\n",
               "       robust = fit$fit$robust.cvar, scores = unname(fit$fit$scores))\n}\n")
S_R <- paste0("S <- function(a) list(pars = a$pars, convergence = a$convergence, values = a$values, lagrange = as.numeric(a$lagrange),\n",
              "  hessian = a$hessian, ineqx0 = a$ineqx0, nfuneval = a$nfuneval, outer.iter = a$outer.iter, vscale = a$vscale)\n")
case <- function(id, r, py, inputs = list(), jl = NULL, ...)
  ref_case(id, r = r, py = paste0(P, py), inputs = inputs, jl = if (is.null(jl)) NULL else paste0(JP, jl), ...)

# ── Reihen ──────────────────────────────────────────────────────────────────
sim_garch <- function(n, om, al, be, ga = 0, s2 = om / (1 - al - be - ga / 2)) {
  x <- numeric(n)
  for (i in 1:n) { x[i] <- sqrt(s2) * rnorm(1); s2 <- om + (al + ga * (x[i] < 0)) * x[i]^2 + be * s2 }
  x
}
E <- list()
set.seed(1);  E$n500    <- rnorm(500, 3e-4, 0.01)
set.seed(2);  E$g1500   <- 2e-4 + sim_garch(1500, 2e-6, 0.08, 0.9)
set.seed(3);  E$n120    <- rnorm(120, 0, 0.005)
set.seed(4);  E$n40     <- rnorm(40, 1e-3, 0.012)                  # < 100 Beobachtungen: Warnung
set.seed(5);  E$n12     <- rnorm(12, 0, 0.01)
set.seed(6);  E$big     <- rnorm(300, 5, 30)                       # große Varianz
set.seed(7);  E$small   <- rnorm(400, 1e-5, 1e-4)                  # kleine Varianz
set.seed(8);  E$igarch  <- sim_garch(1000, 1e-7, 0.15, 0.85, s2 = 1e-4)   # nahe IGARCH
set.seed(9);  E$outl    <- { x <- rnorm(600, 0, 0.01); x[c(100, 300, 450)] <- c(0.3, -0.4, 0.25); x }
set.seed(10); E$t2      <- 0.01 * rt(800, 2)
set.seed(11); E$disc    <- round(rnorm(300, 0, 0.01), 3)
set.seed(12); E$lev     <- sim_garch(700, 1e-6, 0.02, 0.85, ga = 0.15)
set.seed(13); E$sym0    <- { x <- rnorm(200, 0, 0.01); c(x, -x)[sample(400)] }   # Mittelwert exakt 0
set.seed(14); E$regime  <- c(rnorm(250, 0, 0.005), rnorm(250, 0, 0.04))
set.seed(15); E$n2000   <- rnorm(2000, 2e-4, 0.011)
# solnp scheitert (Hesse-Matrix), nlminb konvergiert (mit R gesucht)
set.seed(1);  E$tiny30  <- rnorm(30, 1e-7, 1e-7)
set.seed(2);  E$tiny150 <- rnorm(150, 1e-7, 1e-7)
set.seed(3);  E$tiny400 <- rnorm(400, 1e-7, 1e-7)
set.seed(4);  E$tiny1k  <- rnorm(1000, 1e-7, 1e-7)
set.seed(4);  E$ig400   <- sim_garch(400, 1e-7, 0.15, 0.85, s2 = 1e-4)
set.seed(4);  E$ig1000  <- sim_garch(1000, 1e-7, 0.15, 0.85, s2 = 1e-4)
set.seed(5);  E$out400  <- { x <- rnorm(400, 0, 0.01); x[sample(400, 3)] <- c(0.3, -0.4, 0.25); x }
set.seed(4);  E$sym1000 <- { x <- rnorm(500, 0, 0.01); c(x, -x)[sample(1000)] }
set.seed(3);  E$ar30    <- as.numeric(arima.sim(list(ar = 0.9), 30) * 0.01)
set.seed(4);  E$ar150   <- as.numeric(arima.sim(list(ar = 0.9), 150) * 0.01)
# Hesse-Matrix nicht invertierbar ("failed to invert hessian")
set.seed(1);  E$huge    <- rnorm(200, 0, 1e6)
set.seed(5);  E$jump100 <- { x <- rep(0, 100); x[sample(100, 1)] <- 0.05; x }
set.seed(3);  E$short3  <- rnorm(3, 0, 0.01)
set.seed(4);  E$short6  <- rnorm(6, 0, 0.01)

# ── ugarchfit -> coef direkt ────────────────────────────────────────────────
# Reihen, bei denen R den Solver gosolnp erreicht, folgen am Ende mit fester Uhr (Abschnitt gosolnp)
uses_gosolnp <- function(e, m) {
  ns <- asNamespace("SimLev"); f0 <- get(".rugarch_gosolnpsolver", ns)
  unlockBinding(".rugarch_gosolnpsolver", ns); assign(".rugarch_gosolnpsolver", function(...) stop("<gosolnp>"), ns)
  on.exit({ assign(".rugarch_gosolnpsolver", f0, ns); lockBinding(".rugarch_gosolnpsolver", ns) })
  spec <- SimLev:::.rugarch_ugarchspec(variance.model = list(model = m, garchOrder = c(1, 1)),
    mean.model = list(armaOrder = c(0, 0), include.mean = TRUE), distribution.model = "norm")
  r <- tryCatch(suppressWarnings(SimLev:::.rugarch_ugarchfit(spec = spec, data = e, solver = "hybrid")), error = function(err) conditionMessage(err))
  identical(r, "<gosolnp>")
}
U <- function(id, v, m, full = FALSE) {
  if (uses_gosolnp(E[[v]], m)) { cat(sprintf("später mit fester Uhr (gosolnp): %s %s\n", v, m)); return(invisible()) }
  case(sprintf("ug_%s_%s%s", if (m == "sGARCH") "s" else "gjr", id, if (full) "_full" else ""),
       paste0(UG_R, sprintf("UG(e, '%s'%s)", m, if (full) ", full = TRUE" else "")),
       sprintf("result = %s(e, '%s')", if (full) "UGF" else "UG", m), list(e = E[[v]]),
       jl = sprintf("result = %s(e, \"%s\")", if (full) "UGF" else "UG", m))
}
for (v in names(E)) for (m in c("sGARCH", "gjrGARCH")) U(v, v, m)
for (v in c("n500", "n120", "n40", "tiny150", "ig400", "huge", "jump100", "lev")) for (m in c("sGARCH", "gjrGARCH")) U(v, v, m, full = TRUE)

# ── solnp direkt ────────────────────────────────────────────────────────────
SOLNP <- function(id, rdef, rcall, pdef, pcall, jdef, jcall, inputs = list())
  case(paste0("solnp_", id), paste0(S_R, rdef, rcall), paste0(pdef, pcall), inputs, jl = paste0(jdef, jcall))
POW_R <- "fn <- function(x) exp(x[1] * x[2] * x[3] * x[4] * x[5])\neq <- function(x) c(x[1]*x[1]+x[2]*x[2]+x[3]*x[3]+x[4]*x[4]+x[5]*x[5], x[2]*x[3]-5*x[4]*x[5], x[1]*x[1]*x[1]+x[2]*x[2]*x[2])\n"
POW_P <- "import math\nfn = lambda x: math.exp(x[0]*x[1]*x[2]*x[3]*x[4])\neq = lambda x: [x[0]*x[0]+x[1]*x[1]+x[2]*x[2]+x[3]*x[3]+x[4]*x[4], x[1]*x[2]-5*x[3]*x[4], x[0]*x[0]*x[0]+x[1]*x[1]*x[1]]\n"
POW_J <- "fn(x) = SL.RLibm.exp(x[1] * x[2] * x[3] * x[4] * x[5])\neq(x) = [x[1]*x[1]+x[2]*x[2]+x[3]*x[3]+x[4]*x[4]+x[5]*x[5], x[2]*x[3]-5*x[4]*x[5], x[1]*x[1]*x[1]+x[2]*x[2]*x[2]]\n"
SOLNP("powell", POW_R, "S(SimLev:::.rsolnp_solnp(c(-2, 2, 2, -1, -1), fun = fn, eqfun = eq, eqB = c(10, 0, -1), control = list(trace = 0)))",
      POW_P, "result = S(SN.solnp(np.array([-2., 2, 2, -1, -1]), fn, eqfun=eq, eqB=[10, 0, -1], control={'trace': 0}))",
      POW_J, "result = S(SN.solnp([-2.0, 2, 2, -1, -1], fn; eqfun = eq, eqB = [10, 0, -1], control = Dict(\"trace\" => 0)))")
RS_R <- "fn <- function(x) x[1]*x[1]+x[2]*x[2]+2*x[3]*x[3]+x[4]*x[4]-5*x[1]-5*x[2]-21*x[3]+7*x[4]\nineq <- function(x) c(8-x[1]*x[1]-x[2]*x[2]-x[3]*x[3]-x[4]*x[4]-x[1]+x[2]-x[3]+x[4], 10-x[1]*x[1]-2*x[2]*x[2]-x[3]*x[3]-2*x[4]*x[4]+x[1]+x[4], 5-2*x[1]*x[1]-x[2]*x[2]-x[3]*x[3]-2*x[1]+x[2]+x[4])\n"
RS_P <- "fn = lambda x: x[0]*x[0]+x[1]*x[1]+2*x[2]*x[2]+x[3]*x[3]-5*x[0]-5*x[1]-21*x[2]+7*x[3]\nineq = lambda x: [8-x[0]*x[0]-x[1]*x[1]-x[2]*x[2]-x[3]*x[3]-x[0]+x[1]-x[2]+x[3], 10-x[0]*x[0]-2*x[1]*x[1]-x[2]*x[2]-2*x[3]*x[3]+x[0]+x[3], 5-2*x[0]*x[0]-x[1]*x[1]-x[2]*x[2]-2*x[0]+x[1]+x[3]]\n"
RS_J <- "fn(x) = x[1]*x[1]+x[2]*x[2]+2*x[3]*x[3]+x[4]*x[4]-5*x[1]-5*x[2]-21*x[3]+7*x[4]\nineq(x) = [8-x[1]*x[1]-x[2]*x[2]-x[3]*x[3]-x[4]*x[4]-x[1]+x[2]-x[3]+x[4], 10-x[1]*x[1]-2*x[2]*x[2]-x[3]*x[3]-2*x[4]*x[4]+x[1]+x[4], 5-2*x[1]*x[1]-x[2]*x[2]-x[3]*x[3]-2*x[1]+x[2]+x[4]]\n"
SOLNP("rosensuzuki", RS_R, "S(SimLev:::.rsolnp_solnp(c(1, 1, 1, 1), fun = fn, ineqfun = ineq, ineqLB = rep(0, 3), ineqUB = rep(1000, 3), control = list(trace = 0)))",
      RS_P, "result = S(SN.solnp(np.array([1., 1, 1, 1]), fn, ineqfun=ineq, ineqLB=[0, 0, 0], ineqUB=[1000, 1000, 1000], control={'trace': 0}))",
      RS_J, "result = S(SN.solnp([1.0, 1, 1, 1], fn; ineqfun = ineq, ineqLB = zeros(3), ineqUB = fill(1000.0, 3), control = Dict(\"trace\" => 0)))")
SOLNP("rosensuzuki_trace", RS_R, "S(SimLev:::.rsolnp_solnp(c(1, 1, 1, 1), fun = fn, ineqfun = ineq, ineqLB = rep(0, 3), ineqUB = rep(1000, 3), control = list(outer.iter = 3)))",
      RS_P, "result = S(SN.solnp(np.array([1., 1, 1, 1]), fn, ineqfun=ineq, ineqLB=[0, 0, 0], ineqUB=[1000, 1000, 1000], control={'outer.iter': 3}))",
      RS_J, "result = S(SN.solnp([1.0, 1, 1, 1], fn; ineqfun = ineq, ineqLB = zeros(3), ineqUB = fill(1000.0, 3), control = Dict(\"outer.iter\" => 3)))")
ROS_R <- "fn <- function(x) 100 * (x[2] - x[1] * x[1])^2 + (1 - x[1])^2\n"
ROS_P <- "fn = lambda x: 100 * (x[1] - x[0] * x[0]) ** 2 + (1 - x[0]) ** 2\n"
ROS_J <- "fn(x) = 100 * ((x[2] - x[1] * x[1]) * (x[2] - x[1] * x[1])) + (1 - x[1]) * (1 - x[1])\n"
SOLNP("rosen_free", ROS_R, "S(SimLev:::.rsolnp_solnp(c(-1.2, 1), fun = fn, control = list(trace = 0)))",
      ROS_P, "result = S(SN.solnp(np.array([-1.2, 1]), fn, control={'trace': 0}))",
      ROS_J, "result = S(SN.solnp([-1.2, 1], fn; control = Dict(\"trace\" => 0)))")
SOLNP("rosen_box", ROS_R, "S(SimLev:::.rsolnp_solnp(c(a = -1.2, b = 1), fun = fn, LB = c(-2, -2), UB = c(2, 0.5)))",
      ROS_P, "result = S(SN.solnp(pd.Series([-1.2, 1], index=['a', 'b']), lambda x: fn(np.asarray(x)), LB=[-2, -2], UB=[2, 0.5]))",
      ROS_J, "result = S(SN.solnp(SL.RVector([-1.2, 1.0]; names = [\"a\", \"b\"]), fn; LB = [-2, -2], UB = [2, 0.5]))")
SOLNP("rosen_box2", ROS_R, "S(SimLev:::.rsolnp_solnp(c(0.5, 0.2), fun = fn, LB = c(-2, -1), UB = c(0.8, 3), control = list(trace = 0, tol = 1e-10, delta = 1e-6, rho = 2)))",
      ROS_P, "result = S(SN.solnp(np.array([0.5, 0.2]), fn, LB=[-2, -1], UB=[0.8, 3], control={'trace': 0, 'tol': 1e-10, 'delta': 1e-6, 'rho': 2}))",
      ROS_J, "result = S(SN.solnp([0.5, 0.2], fn; LB = [-2, -1], UB = [0.8, 3], control = Dict(\"trace\" => 0, \"tol\" => 1e-10, \"delta\" => 1e-6, \"rho\" => 2)))")
SOLNP("ineq_viol", ROS_R, "S(SimLev:::.rsolnp_solnp(c(1.5, 2), fun = fn, ineqfun = function(x) x[1] + x[2], ineqLB = 0, ineqUB = 1, LB = c(-3, -3), UB = c(3, 3), control = list(trace = 0)))",
      ROS_P, "result = S(SN.solnp(np.array([1.5, 2]), fn, ineqfun=lambda x: [x[0] + x[1]], ineqLB=[0], ineqUB=[1], LB=[-3, -3], UB=[3, 3], control={'trace': 0}))",
      ROS_J, "result = S(SN.solnp([1.5, 2], fn; ineqfun = x -> [x[1] + x[2]], ineqLB = [0], ineqUB = [1], LB = [-3, -3], UB = [3, 3], control = Dict(\"trace\" => 0)))")
SOLNP("eq_ineq_box", ROS_R, "S(SimLev:::.rsolnp_solnp(c(0.3, 0.4, 0.3), fun = function(x) (x[1] - 1)^2 + (x[2] - 2)^2 + x[3] * x[3], eqfun = function(x) x[1] + x[2] + x[3], eqB = 1, ineqfun = function(x) x[1] - x[2], ineqLB = -0.5, ineqUB = 0.5, LB = c(0, 0, 0), UB = c(1, 1, 1), control = list(trace = 0)))",
      "", "result = S(SN.solnp(np.array([0.3, 0.4, 0.3]), lambda x: (x[0] - 1) ** 2 + (x[1] - 2) ** 2 + x[2] * x[2], eqfun=lambda x: [x[0] + x[1] + x[2]], eqB=[1], ineqfun=lambda x: [x[0] - x[1]], ineqLB=[-0.5], ineqUB=[0.5], LB=[0, 0, 0], UB=[1, 1, 1], control={'trace': 0}))",
      "", "result = S(SN.solnp([0.3, 0.4, 0.3], x -> (x[1] - 1) * (x[1] - 1) + (x[2] - 2) * (x[2] - 2) + x[3] * x[3]; eqfun = x -> [x[1] + x[2] + x[3]], eqB = [1], ineqfun = x -> [x[1] - x[2]], ineqLB = [-0.5], ineqUB = [0.5], LB = [0, 0, 0], UB = [1, 1, 1], control = Dict(\"trace\" => 0)))")
SOLNP("nonfinite", "", "S(SimLev:::.rsolnp_solnp(c(1, 1), fun = function(x) if (x[1] > 1.0000001) NaN else (x[1] - 3)^2 + x[2]^2, control = list(trace = 0, outer.iter = 5)))",
      "", "import math\nresult = S(SN.solnp(np.array([1., 1]), lambda x: math.nan if x[0] > 1.0000001 else (x[0] - 3) ** 2 + x[1] ** 2, control={'trace': 0, 'outer.iter': 5}))",
      "", "result = S(SN.solnp([1.0, 1], x -> x[1] > 1.0000001 ? NaN : (x[1] - 3) * (x[1] - 3) + x[2] * x[2]; control = Dict(\"trace\" => 0, \"outer.iter\" => 5)))")
SOLNP("eqbounds", ROS_R, "S(SimLev:::.rsolnp_solnp(c(-1.2, 1), fun = fn, LB = c(-2, 1), UB = c(2, 1), control = list(trace = 0)))",
      ROS_P, "result = S(SN.solnp(np.array([-1.2, 1]), fn, LB=[-2, 1], UB=[2, 1], control={'trace': 0}))",
      ROS_J, "result = S(SN.solnp([-1.2, 1], fn; LB = [-2, 1], UB = [2, 1], control = Dict(\"trace\" => 0)))")
SOLNP("err_lb", ROS_R, "SimLev:::.rsolnp_solnp(c(-1.2, 1), fun = fn, LB = c(-2, -2, -2))",
      ROS_P, "result = SN.solnp(np.array([-1.2, 1]), fn, LB=[-2, -2, -2])",
      ROS_J, "result = SN.solnp([-1.2, 1], fn; LB = [-2, -2, -2])")
SOLNP("err_ublb", ROS_R, "SimLev:::.rsolnp_solnp(c(-1.2, 1), fun = fn, LB = c(-2, 2), UB = c(2, 1))",
      ROS_P, "result = SN.solnp(np.array([-1.2, 1]), fn, LB=[-2, 2], UB=[2, 1])",
      ROS_J, "result = SN.solnp([-1.2, 1], fn; LB = [-2, 2], UB = [2, 1])")
SOLNP("err_len", "", "SimLev:::.rsolnp_solnp(c(-1.2, 1), fun = function(x) x)",
      "", "result = SN.solnp(np.array([-1.2, 1]), lambda x: x)",
      "", "result = SN.solnp([-1.2, 1], x -> x)")
SOLNP("err_ineq", ROS_R, "SimLev:::.rsolnp_solnp(c(-1.2, 1), fun = fn, ineqfun = function(x) x[1], ineqLB = 0)",
      ROS_P, "result = SN.solnp(np.array([-1.2, 1]), fn, ineqfun=lambda x: [x[0]], ineqLB=[0])",
      ROS_J, "result = SN.solnp([-1.2, 1], fn; ineqfun = x -> [x[1]], ineqLB = [0])")

# ── .fit_garch11 mit rugarch ────────────────────────────────────────────────
set.seed(5); n <- 400
us <- 1 + rnorm(n, 3e-4, 0.011)
d <- data.frame(us = us, eu = us * (1 + rnorm(n, 0, 0.004)), rate = 2 + cumsum(rnorm(n, 0, 0.005)))
set.seed(3); dv <- data.frame(us = 1 + rnorm(200, 0, 0.3)); dv$us[dv$us <= 0.05] <- 0.05
set.seed(31); dg <- data.frame(us = 1 + 2e-4 + sim_garch(800, 2e-6, 0.1, 0.87), eu = 1 + 1e-4 + sim_garch(800, 1e-6, 0.05, 0.9, ga = 0.06))
set.seed(32); dt <- data.frame(us = 1 + rnorm(300, 1e-7, 1e-7), eu = 1 + rnorm(300, 0, 0.01))   # us: nlminb
I <- list(d = d, dv = dv, dg = dg, dt = dt, e = E$tiny150, e2 = E$jump100)
FG <- function(id, x, args = "", pargs = "", jargs = "")
  case(paste0("fit_", id), sprintf("SimLev:::.fit_garch11(%s%s)", x[1], args), sprintf("result = B._fit_garch11(%s%s)", x[2], pargs), I,
       jl = sprintf("result = B._fit_garch11(%s%s)", x[3], jargs))
X <- function(col, r = "") c(sprintf("d$%s%s - 1", col, r), sprintf("d['%s'].to_numpy()%s - 1", col, if (r == "") "" else r),
                            sprintf("d.%s%s .- 1", col, if (r == "") "" else r))
FG("garch", X("us"))
FG("gjr", X("eu"), ", gjr = TRUE", ", gjr=True", "; gjr = true")
FG("garch_short", c("d$us[1:30] - 1", "d['us'].to_numpy()[:30] - 1", "d.us[1:30] .- 1"))
FG("gjr_short", c("d$us[1:60] - 1", "d['us'].to_numpy()[:60] - 1", "d.us[1:60] .- 1"), ", gjr = TRUE, quiet = TRUE", ", gjr=True, quiet=True", "; gjr = true, quiet = true")
FG("garch_dg", c("dg$us - 1", "dg['us'].to_numpy() - 1", "dg.us .- 1"))
FG("gjr_dg", c("dg$eu - 1", "dg['eu'].to_numpy() - 1", "dg.eu .- 1"), ", gjr = TRUE", ", gjr=True", "; gjr = true")
FG("garch_nlminb", c("dt$us - 1", "dt['us'].to_numpy() - 1", "dt.us .- 1"))
FG("gjr_nlminb", c("dt$us - 1", "dt['us'].to_numpy() - 1", "dt.us .- 1"), ", gjr = TRUE", ", gjr=True", "; gjr = true")
FG("garch_hivol", c("dv$us - 1", "dv['us'].to_numpy() - 1", "dv.us .- 1"))
FG("garch_tiny_e", c("e", "e", "e"), "", "", "")
FG("garch_const", c("rep(0.001, 50)", "np.full(50, 0.001)", "fill(0.001, 50)"))
FG("garch_hess", c("e2", "e2", "e2"), ", gjr = TRUE", ", gjr=True", "; gjr = true")

# ── bootstrap mit garch / gjr_garch ─────────────────────────────────────────
CFG_R <- "cfg <- bootstrap_config(c(us = 'us', eu = 'eu'), regime_index = 'us', aux = c(rate = 'rate'),
  letfs = list(list(base = 'eu', leverage = 2, finance = 'rate', expense = 0.5), list(base = 'us', leverage = -1, finance = 'rate', expense = 0.6)))\n"
CFG_P <- "cfg = bootstrap_config({'us': 'us', 'eu': 'eu'}, regime_index='us', aux={'rate': 'rate'},
  letfs=[{'base': 'eu', 'leverage': 2, 'finance': 'rate', 'expense': 0.5}, {'base': 'us', 'leverage': -1, 'finance': 'rate', 'expense': 0.6}])\n"
CFG_J <- 'cfg = bootstrap_config((us = "us", eu = "eu"), regime_index = "us", aux = (rate = "rate",),
  letfs = [(base = "eu", leverage = 2, finance = "rate", expense = 0.5), (base = "us", leverage = -1, finance = "rate", expense = 0.6)])\n'
for (m in c("garch", "gjr_garch"))
  case(paste0("bs_", m), paste0(CFG_R, "b <- bootstrap(d, cfg, '", m, "', n = 2, seed = 1, progress = FALSE); b"),
       paste0(CFG_P, "result = bootstrap(d, cfg, method='", m, "', n=2, seed=1, progress=False)"), I,
       jl = paste0(CFG_J, "result = bootstrap(d, cfg, \"", m, "\"; n = 2, seed = 1, progress = false)"))
case("bs_garch_joint", "cfg <- bootstrap_config(c(us = 'us', eu = 'eu'), cross = 'joint'); bootstrap(d, cfg, 'gjr_garch', n = 2, seed = 4, progress = FALSE, path_length = 100)",
     "cfg = bootstrap_config({'us': 'us', 'eu': 'eu'}, cross='joint'); result = bootstrap(d, cfg, method='gjr_garch', n=2, seed=4, progress=False, path_length=100)", I,
     jl = 'cfg = bootstrap_config((us = "us", eu = "eu"), cross = "joint"); result = bootstrap(d, cfg, "gjr_garch"; n = 2, seed = 4, progress = false, path_length = 100)')
case("bs_garch_regime_eu", "cfg <- bootstrap_config(c(us = 'us', eu = 'eu'), regime_index = 'eu'); bootstrap(d, cfg, 'garch', n = 1, seed = 2, progress = FALSE, path_length = 80)",
     "cfg = bootstrap_config({'us': 'us', 'eu': 'eu'}, regime_index='eu'); result = bootstrap(d, cfg, method='garch', n=1, seed=2, progress=False, path_length=80)", I,
     jl = 'cfg = bootstrap_config((us = "us", eu = "eu"), regime_index = "eu"); result = bootstrap(d, cfg, "garch"; n = 1, seed = 2, progress = false, path_length = 80)')
case("bs_garch_single", "bootstrap(d, bootstrap_config(c(eu = 'eu')), 'garch', n = 2, seed = 3, progress = FALSE, path_length = 60)",
     "result = bootstrap(d, bootstrap_config({'eu': 'eu'}), method='garch', n=2, seed=3, progress=False, path_length=60)", I,
     jl = 'result = bootstrap(d, bootstrap_config((eu = "eu",)), "garch"; n = 2, seed = 3, progress = false, path_length = 60)')
case("bs_garch_hivol", "bootstrap(dv, bootstrap_config(c(us = 'us')), 'garch', n = 2, seed = 1, progress = FALSE)$stats",
     "result = bootstrap(dv, bootstrap_config({'us': 'us'}), method='garch', n=2, seed=1, progress=False)['stats']", I,
     jl = 'result = bootstrap(dv, bootstrap_config((us = "us",)), "garch"; n = 2, seed = 1, progress = false)["stats"]')
case("bs_garch_const", "bootstrap(data.frame(us = rep(1.0001, 50)), bootstrap_config(c(us = 'us')), 'garch', n = 1, seed = 1)",
     "result = bootstrap(pd.DataFrame({'us': np.full(50, 1.0001)}), bootstrap_config({'us': 'us'}), method='garch', n=1, seed=1)",
     jl = 'result = bootstrap(SL.RFrame("us" => fill(1.0001, 50)), bootstrap_config((us = "us",)), "garch"; n = 1, seed = 1)')
case("bs_cross_const", "dd <- d[1:120, 1:2]; dd$eu <- dd$us; bootstrap(dd, bootstrap_config(c(us = 'us', eu = 'eu')), 'garch', n = 1, seed = 1, progress = FALSE, path_length = 30)",
     "dd = d.iloc[:120, :2].copy(); dd['eu'] = dd['us']; result = bootstrap(dd, bootstrap_config({'us': 'us', 'eu': 'eu'}), method='garch', n=1, seed=1, progress=False, path_length=30)", I,
     jl = 'dd = SL.RFrame("us" => d.us[1:120], "eu" => d.us[1:120]); result = bootstrap(dd, bootstrap_config((us = "us", eu = "eu")), "garch"; n = 1, seed = 1, progress = false, path_length = 30)')
case("bs_garch_short", "bootstrap(d[1:70, ], bootstrap_config(c(us = 'us', eu = 'eu')), 'gjr_garch', n = 2, seed = 9, progress = FALSE, path_length = 40)",
     "result = bootstrap(d.iloc[:70], bootstrap_config({'us': 'us', 'eu': 'eu'}), method='gjr_garch', n=2, seed=9, progress=False, path_length=40)", I,
     jl = 'result = bootstrap(SL.RFrame("us" => d.us[1:70], "eu" => d.eu[1:70], "rate" => d.rate[1:70]), bootstrap_config((us = "us", eu = "eu")), "gjr_garch"; n = 2, seed = 9, progress = false, path_length = 40)')
case("bs_garch_dg", "bootstrap(dg, bootstrap_config(c(us = 'us', eu = 'eu'), cross = 'ratio'), 'gjr_garch', n = 3, seed = 5, progress = FALSE, path_length = 250)",
     "result = bootstrap(dg, bootstrap_config({'us': 'us', 'eu': 'eu'}, cross='ratio'), method='gjr_garch', n=3, seed=5, progress=False, path_length=250)", I,
     jl = 'result = bootstrap(dg, bootstrap_config((us = "us", eu = "eu"), cross = "ratio"), "gjr_garch"; n = 3, seed = 5, progress = false, path_length = 250)')
case("bs_garch_nlminb", "bootstrap(dt, bootstrap_config(c(us = 'us', eu = 'eu')), 'garch', n = 2, seed = 6, progress = FALSE, path_length = 50)",
     "result = bootstrap(dt, bootstrap_config({'us': 'us', 'eu': 'eu'}), method='garch', n=2, seed=6, progress=False, path_length=50)", I,
     jl = 'result = bootstrap(dt, bootstrap_config((us = "us", eu = "eu")), "garch"; n = 2, seed = 6, progress = false, path_length = 50)')
CF3_R <- "cfg3 <- bootstrap_config(c(us = 'us'), aux = c(cpi = 'cpi', zins = 'zins', infl = 'infl'), input = 'prices', aux_type = c(cpi = 'level', zins = 'rate'), letfs = list(list(base = 'us', leverage = 3, finance = 'zins', spread = 0.5)))\n"
CF3_J <- 'cfg3 = bootstrap_config((us = "us",), aux = (cpi = "cpi", zins = "zins", infl = "infl"), input = "prices", aux_type = (cpi = "level", zins = "rate"), letfs = [(base = "us", leverage = 3, finance = "zins", spread = 0.5)])\n'
CF3_P <- "cfg3 = bootstrap_config({'us': 'us'}, aux={'cpi': 'cpi', 'zins': 'zins', 'infl': 'infl'}, input='prices', aux_type={'cpi': 'level', 'zins': 'rate'}, letfs=[{'base': 'us', 'leverage': 3, 'finance': 'zins', 'spread': 0.5}])\n"
set.seed(21); n2 <- 300
dp <- data.frame(us = 100 * cumprod(c(1, 1 + rnorm(n2, 3e-4, 0.01))), cpi = 100 * 1.02^((0:n2) / 365),
                 infl = 2, zins = 2 + sin((0:n2) / 40))
case("aux_level_garch", paste0(CF3_R, "b <- suppressWarnings(bootstrap(dp, cfg3, 'garch', n = 2, seed = 2, progress = FALSE)); c(b$paths, lapply(b$paths, attr, 'aux_level'))"),
     paste0(CF3_P, "import warnings\nwith warnings.catch_warnings():\n    warnings.simplefilter('ignore')\n    b = bootstrap(dp, cfg3, method='garch', n=2, seed=2, progress=False)\nresult = b['paths'] + [p.attrs['aux_level'] for p in b['paths']]"), list(dp = dp),
     jl = paste0(CF3_J, "result = B._quiet(() -> (b = bootstrap(dp, cfg3, \"garch\"; n = 2, seed = 2, progress = false); vcat(b[\"paths\"], [p.attrs[\"aux_level\"] for p in b[\"paths\"]])))"))

# ── dependence_dcc / dependence_analysis ───────────────────────────────────────────
set.seed(1); n <- 300
RR <- cbind(a = rnorm(n, 0, 0.01), b = rnorm(n, 0, 0.01), c = rnorm(n, 0, 0.012))
RR[, "b"] <- 0.5 * RR[, "a"] + sqrt(0.75) * RR[, "b"]
RG2 <- unname(as.matrix(dg - 1))
JD <- "sub(m, r, c) = SL.NamedMat(m.data[r, c]; colnames = m.colnames[c])\n"
case("dcc_fit2", "dependence_dcc(RR[, 1:2])", "result = D.dependence_dcc(RR.iloc[:, :2])", list(RR = RR),
     jl = paste0(JD, "result = D.dependence_dcc(sub(RR, :, 1:2))"))
case("dcc_fit3", "dependence_dcc(unname(RR))", "result = D.dependence_dcc(RR.to_numpy())", list(RR = RR),
     jl = "result = D.dependence_dcc(RR.data)")
case("dcc_fit_dg", "dependence_dcc(RG2)", "result = D.dependence_dcc(RG2)", list(RG2 = RG2),
     jl = "result = D.dependence_dcc(RG2)")
RT <- cbind(x = (dt$us - 1)[1:150], y = (dt$eu - 1)[1:150])
case("dcc_fit_nlminb", "dependence_dcc(RT)", "result = D.dependence_dcc(RT)", list(RT = RT),
     jl = "result = D.dependence_dcc(RT)")
RC <- RR; RC[, "c"] <- 0.001
case("dcc_err_const", "dependence_dcc(RC)", "result = D.dependence_dcc(RC)", list(RC = RC), jl = "result = D.dependence_dcc(RC)")
RS <- cbind(RR, d = RR[, "a"] * 2)
case("dcc_err_sing", "dependence_dcc(RS)", "result = D.dependence_dcc(RS)", list(RS = RS), jl = "result = D.dependence_dcc(RS)")

mkdata <- function(seed, n = 1500) {
  set.seed(seed)
  date <- seq(as.Date("2015-01-01"), by = "day", length.out = n)
  z <- matrix(rnorm(n * 3), n) %*% chol(matrix(c(1, -0.3, 0.2, -0.3, 1, 0, 0.2, 0, 1), 3))
  data.frame(date = date, stocks = 100 * exp(cumsum(0.0003 + 0.01 * z[, 1])),
             bonds = 100 * exp(cumsum(0.0001 + 0.004 * z[, 2])), gold = 100 * exp(cumsum(0.008 * z[, 3])),
             inflation = 2 + cumsum(rnorm(n, 0, 0.05)), zins = 1 + cumsum(rnorm(n, 0, 0.02)),
             regime = sample(c("a", "b"), n, TRUE))
}
d1 <- mkdata(1)
case("da_basic", "dependence_analysis(d1, c('stocks', 'bonds'), copulas = FALSE)",
     "result = D.dependence_analysis(d1, ['stocks', 'bonds'], copulas=False)", list(d1 = d1),
     jl = 'result = D.dependence_analysis(d1, ["stocks", "bonds"]; copulas = false)')
d600 <- d1[1:600, ]
case("da_day3", "dependence_analysis(d600, c('stocks', 'bonds', 'gold'), frequency = 'day', copulas = FALSE, B = 0)",
     "result = D.dependence_analysis(d600, ['stocks', 'bonds', 'gold'], frequency='day', copulas=False, B=0)", list(d600 = d600),
     jl = 'result = D.dependence_analysis(d600, ["stocks", "bonds", "gold"]; frequency = "day", copulas = false, B = 0)')
case("da_dccfail", "x <- d1; x$b2 <- x$bonds; dependence_analysis(x, c('stocks', 'bonds', 'b2'), copulas = FALSE)",
     "x = d1.copy(); x['b2'] = x['bonds']; result = D.dependence_analysis(x, ['stocks', 'bonds', 'b2'], copulas=False)", list(d1 = d1),
     jl = 'x = copy(d1); x["b2"] = copy(x["bonds"]); result = D.dependence_analysis(x, ["stocks", "bonds", "b2"]; copulas = false)')
# ── gosolnp (Rsolnp 1.16) mit fester Uhr ────────────────────────────────────
# Rsolnp::gosolnp setzt bei rseed = NULL (so ruft rugarch es auf) den Startwert
# as.numeric(Sys.time()) und überschreibt mit set.seed den globalen Zufallszustand.
# Die Fälle legen die Uhr fest (ref_case(sys_time = …), Feld sys_time); die Ports
# lesen sie über SIMLEV_R_SYS_TIME. Alle Fälle hier stehen am Ende, damit die
# Zufallszustände der übrigen Fälle unverändert bleiben.
P2 <- paste0(P, "from simlev._r import rng as RNG\nfrom simlev._r import truncnorm as TN\n",
             "def GS(a):\n    return {'pars': np.asarray(a['pars'], dtype=float), 'convergence': a['convergence'], 'values': a['values'],\n",
             "            'start.pars': np.asarray(a['start.pars'], dtype=float), 'rseed': float(a['rseed']), 'u': RNG.runif(2)}\n",
             "def UGR(e, m='sGARCH'):\n    RNG.set_seed(1)\n    f = RG.ugarchfit(e, model=m)\n    return {'coef': f['coef'], 'u': RNG.runif(3)}\n")
JP2 <- paste0(JP, "const RNG = SL.RRng\nconst TN = SL.RTruncnorm\n",
              "GS(a) = SL.RList(\"pars\" => SN._asvec(a[\"pars\"]), \"convergence\" => a[\"convergence\"], \"values\" => a[\"values\"],\n",
              "    \"start.pars\" => SN._asvec(a[\"start.pars\"]), \"rseed\" => Float64(a[\"rseed\"]), \"u\" => RNG.runif(2))\n",
              "function UGR(e, m = \"sGARCH\")\n    RNG.set_seed(1)\n    f = RG.ugarchfit(e; model = m)\n    SL.RList(\"coef\" => f[\"coef\"], \"u\" => RNG.runif(3))\nend\n")
GS_R <- paste0("GS <- function(a) list(pars = as.numeric(a$pars), convergence = a$convergence, values = a$values,\n",
               "  start.pars = as.numeric(a$start.pars), rseed = as.numeric(a$rseed), u = runif(2))\n")
UGR_R <- "UGR <- function(e, m = 'sGARCH') { set.seed(1); cf <- UG(e, m); list(coef = cf, u = runif(3)) }\n"
CLK <- 1760870000.5
case2 <- function(id, r, py, inputs = list(), jl = NULL, sys_time = CLK, ...)
  ref_case(id, r = r, py = paste0(P2, py), inputs = inputs, jl = if (is.null(jl)) NULL else paste0(JP2, jl),
           sys_time = sys_time, ...)
# Anzahl der Aufrufe von .rugarch_gosolnpsolver beim Auswerten von `code` (zur Kontrolle im Protokoll)
gos_calls <- function(code, inputs = list(), clk = CLK) {
  ns <- asNamespace("SimLev"); f0 <- get(".rugarch_gosolnpsolver", ns); k <- 0L
  unlockBinding(".rugarch_gosolnpsolver", ns); assign(".rugarch_gosolnpsolver", function(...) { k <<- k + 1L; f0(...) }, ns)
  undo <- .ref_fix_time(clk); seed0 <- get0(".Random.seed", globalenv())
  on.exit({ assign(".rugarch_gosolnpsolver", f0, ns); lockBinding(".rugarch_gosolnpsolver", ns); undo()
            if (!is.null(seed0)) assign(".Random.seed", seed0, globalenv()) })
  env <- new.env(parent = globalenv()); for (nm in names(inputs)) assign(nm, inputs[[nm]], envir = env)
  try(suppressWarnings(eval(parse(text = code), envir = env)), silent = TRUE)
  k
}
chk <- function(id, n, code, inputs = list(), clk = CLK) {
  k <- gos_calls(code, inputs, clk)
  cat(sprintf("gosolnp %-28s %d Aufruf(e)%s\n", id, k, if (k != n) sprintf("  ERWARTET %d", n) else ""))
}

# Reihen, bei denen R gosolnp erreicht (mit R gesucht)
G <- list()
set.seed(6);  G$outl200 <- { x <- rnorm(200, 0, 0.01); x[sample(200, 3)] <- c(0.3, -0.4, 0.25); x }
set.seed(6);  G$outl600 <- { x <- rnorm(600, 0, 0.01); x[sample(600, 3)] <- c(0.3, -0.4, 0.25); x }
set.seed(4);  G$jump60  <- { x <- rnorm(60, 0, 1e-4); x[sample(60, 2)] <- c(0.05, -0.05); x }
set.seed(5);  G$tiny60  <- rnorm(60, 1e-7, 1e-7)
set.seed(10); G$tiny30  <- rnorm(30, 1e-7, 1e-7)
set.seed(3);  G$tin2_60 <- rnorm(60, 1e-6, 1e-8)
set.seed(9);  G$tin2_100 <- rnorm(100, 1e-6, 1e-8)
set.seed(11); G$tin2_300 <- rnorm(300, 1e-6, 1e-8)
spike <- function(n) { x <- rep(1e-5, n); x[sample(n, 1)] <- 0.1; x + rnorm(n, 0, 1e-9) }
set.seed(13); G$spk100  <- spike(100)
set.seed(7);  G$spk100b <- spike(100)
set.seed(9);  G$spk300  <- spike(300)
set.seed(14); G$spk300g <- spike(300)
set.seed(8);  G$spk100g <- spike(100)
GU <- function(id, v, m, n_gos, clk = CLK, full = FALSE, src = G) {
  code <- paste0(UG_R, sprintf("UG(e, '%s')", m))
  chk(id, n_gos, code, list(e = src[[v]]), clk)
  case2(id, paste0(UG_R, sprintf("UG(e, '%s'%s)", m, if (full) ", full = TRUE" else "")),
        sprintf("result = %s(e, '%s')", if (full) "UGF" else "UG", m), list(e = src[[v]]),
        jl = sprintf("result = %s(e, \"%s\")", if (full) "UGF" else "UG", m), sys_time = clk)
}
# die im Durchlauf oben übersprungenen Reihen (gosolnp)
GU("ug_s_outl", "outl", "sGARCH", 1, src = E)
GU("ug_gjr_tiny1k", "tiny1k", "gjrGARCH", 2, src = E)               # beide gosolnp-Läufe scheitern
# gosolnp konvergiert
GU("gos_s_outl200", "outl200", "sGARCH", 1)
GU("gos_s_outl200_full", "outl200", "sGARCH", 1, full = TRUE)
GU("gos_gjr_outl600", "outl600", "gjrGARCH", 1)
GU("gos_gjr_jump60", "jump60", "gjrGARCH", 1)
GU("gos_gjr_tiny60", "tiny60", "gjrGARCH", 1)
GU("gos_gjr_tiny30", "tiny30", "gjrGARCH", 1)
GU("gos_gjr_tin2_60", "tin2_60", "gjrGARCH", 1)
GU("gos_gjr_tin2_100", "tin2_100", "gjrGARCH", 1)
GU("gos_gjr_tin2_100_full", "tin2_100", "gjrGARCH", 1, full = TRUE)
GU("gos_gjr_tin2_300", "tin2_300", "gjrGARCH", 1)
GU("gos_s_spk100_c2", "spk100", "sGARCH", 1, clk = CLK + 37)        # andere Uhr: gosolnp konvergiert
GU("gos_gjr_spk300g_c2", "spk300g", "gjrGARCH", 1, clk = CLK + 37)
# erster gosolnp-Lauf scheitert (convergence 2), der zweite folgt (gleicher Startwert) und scheitert ebenso
GU("gos2_s_spk100", "spk100", "sGARCH", 2)
GU("gos2_s_spk100b", "spk100b", "sGARCH", 2)
GU("gos2_s_spk300", "spk300", "sGARCH", 2)
GU("gos2_gjr_spk300g", "spk300g", "gjrGARCH", 2)
GU("gos2_gjr_spk100g", "spk100g", "gjrGARCH", 2)
GU("gos2_gjr_jump60_c3", "jump60", "gjrGARCH", 2, clk = CLK + 259)

# globaler Zufallszustand nach dem Fit wie in R
GR <- function(id, v, m, n_gos, clk = CLK) {
  chk(id, n_gos, paste0(UG_R, UGR_R, sprintf("UGR(e, '%s')", m)), list(e = G[[v]]), clk)
  case2(id, paste0(UG_R, UGR_R, sprintf("UGR(e, '%s')", m)), sprintf("result = UGR(e, '%s')", m), list(e = G[[v]]),
        jl = sprintf("result = UGR(e, \"%s\")", m), sys_time = clk)
}
GR("rng_s_outl200", "outl200", "sGARCH", 1)
GR("rng_s_outl200_c4", "outl200", "sGARCH", 1, clk = 1760871234.999)   # Abschneiden auf ganze Sekunden
GR("rng_gjr_tin2_100", "tin2_100", "gjrGARCH", 1)
GR("rng_s_spk100", "spk100", "sGARCH", 2)
GR("rng_s_outl200_c5", "outl200", "sGARCH", 1, clk = 1e9 + 0.25)
LEC_R <- paste0(UG_R, "RNGkind(\"L'Ecuyer-CMRG\"); set.seed(3); cf <- UG(e, 'gjrGARCH'); out <- list(coef = cf, u = runif(3), seed = .Random.seed)\n",
                "RNGkind('Mersenne-Twister'); out")
chk("rng_lecuyer", 1, LEC_R, list(e = G$jump60))
case2("rng_lecuyer", LEC_R,
      "RNG.rng_kind(\"L'Ecuyer-CMRG\"); RNG.set_seed(3); cf = UG(e, 'gjrGARCH')\nresult = {'coef': cf, 'u': RNG.runif(3), 'seed': RNG.get_random_seed()}\nRNG.rng_kind('Mersenne-Twister')",
      list(e = G$jump60),
      jl = "RNG.rng_kind(\"L'Ecuyer-CMRG\"); RNG.set_seed(3); cf = UG(e, \"gjrGARCH\")\nresult = SL.RList(\"coef\" => cf, \"u\" => RNG.runif(3), \"seed\" => RNG.get_random_seed())\nRNG.rng_kind(\"Mersenne-Twister\")")
NOSEED_R <- paste0(UG_R, "if (exists('.Random.seed', globalenv())) rm('.Random.seed', envir = globalenv()); cf <- UG(e)\n",
                   "list(coef = cf, u = runif(2), seed = .Random.seed[1:4])")
chk("rng_noseed", 1, NOSEED_R, list(e = G$outl200))
case2("rng_noseed", NOSEED_R,
      "RNG.rm_random_seed(); cf = UG(e)\nresult = {'coef': cf, 'u': RNG.runif(2), 'seed': RNG.get_random_seed()[:4]}",
      list(e = G$outl200),
      jl = "RNG.rm_random_seed(); cf = UG(e)\nresult = SL.RList(\"coef\" => cf, \"u\" => RNG.runif(2), \"seed\" => RNG.get_random_seed()[1:4])")

# .fit_garch11, bootstrap und dependence_dcc über gosolnp
IG <- list(e1 = G$outl200, e2 = G$outl600, e3 = G$spk100, dgo = data.frame(us = 1 + G$outl200),
           dgo2 = data.frame(us = 1 + G$spk100g, eu = 1 + G$outl200[1:100]), RG3 = cbind(a = G$outl200, b = G$outl600[1:200]))
FG2 <- function(id, rx, px, jx, n_gos) {
  chk(id, n_gos, rx, IG)
  case2(id, rx, px, IG, jl = jx)
}
FG2("gos_fit_garch", "set.seed(2); list(fit = SimLev:::.fit_garch11(e1), u = runif(2))",
    "RNG.set_seed(2); result = {'fit': B._fit_garch11(e1), 'u': RNG.runif(2)}",
    "RNG.set_seed(2); result = SL.RList(\"fit\" => B._fit_garch11(e1), \"u\" => RNG.runif(2))", 1)
FG2("gos_fit_gjr", "SimLev:::.fit_garch11(e2, gjr = TRUE)", "result = B._fit_garch11(e2, gjr=True)",
    "result = B._fit_garch11(e2; gjr = true)", 1)
FG2("gos_fit_fail", "SimLev:::.fit_garch11(e3)", "result = B._fit_garch11(e3)", "result = B._fit_garch11(e3)", 2)
FG2("gos_bs_noseed", "set.seed(1); b <- bootstrap(dgo, bootstrap_config(c(us = 'us')), 'garch', n = 2, progress = FALSE, path_length = 40); list(seed = b$seed, paths = b$paths, u = runif(2))",
    "RNG.set_seed(1); b = bootstrap(dgo, bootstrap_config({'us': 'us'}), method='garch', n=2, progress=False, path_length=40)\nresult = {'seed': b['seed'], 'paths': b['paths'], 'u': RNG.runif(2)}",
    "RNG.set_seed(1); b = bootstrap(dgo, bootstrap_config((us = \"us\",)), \"garch\"; n = 2, progress = false, path_length = 40)\nresult = SL.RList(\"seed\" => b[\"seed\"], \"paths\" => b[\"paths\"], \"u\" => RNG.runif(2))", 1)
FG2("gos_bs_seed", "set.seed(1); b <- bootstrap(dgo2, bootstrap_config(c(us = 'us', eu = 'eu')), 'gjr_garch', n = 2, seed = 4, progress = FALSE, path_length = 40); list(b = b, u = runif(2))",
    "RNG.set_seed(1); b = bootstrap(dgo2, bootstrap_config({'us': 'us', 'eu': 'eu'}), method='gjr_garch', n=2, seed=4, progress=False, path_length=40)\nresult = {'b': b, 'u': RNG.runif(2)}",
    "RNG.set_seed(1); b = bootstrap(dgo2, bootstrap_config((us = \"us\", eu = \"eu\")), \"gjr_garch\"; n = 2, seed = 4, progress = false, path_length = 40)\nresult = SL.RList(\"b\" => b, \"u\" => RNG.runif(2))", 2)
FG2("gos_dcc", "set.seed(1); list(d = dependence_dcc(RG3), u = runif(2))", "RNG.set_seed(1); result = {'d': D.dependence_dcc(RG3), 'u': RNG.runif(2)}",
    "RNG.set_seed(1); result = SL.RList(\"d\" => D.dependence_dcc(RG3), \"u\" => RNG.runif(2))", 1)

# ── gosolnp direkt ──────────────────────────────────────────────────────────
FN_R <- "fn <- function(x) (x[1] - 1) * (x[1] - 1) + 10 * (x[2] - x[1] * x[1]) * (x[2] - x[1] * x[1])\n"
FN_P <- "def fn(x):\n    x = np.asarray(x, dtype=float)\n    return (x[0] - 1) * (x[0] - 1) + 10 * (x[1] - x[0] * x[0]) * (x[1] - x[0] * x[0])\n"
FN_J <- "fn(x) = (x[1] - 1) * (x[1] - 1) + 10 * (x[2] - x[1] * x[1]) * (x[2] - x[1] * x[1])\n"
GO <- function(id, rcall, pcall, jcall, sys_time = NULL, wrap = TRUE)
  case2(paste0("gosolnp_", id), paste0(GS_R, FN_R, if (wrap) sprintf("GS(%s)", rcall) else rcall),
        paste0(FN_P, if (wrap) sprintf("result = GS(%s)", pcall) else paste0("result = ", pcall)), list(),
        jl = paste0(FN_J, if (wrap) sprintf("result = GS(%s)", jcall) else paste0("result = ", jcall)), sys_time = sys_time)
GO("unif", "SimLev:::.rsolnp_gosolnp(fun = fn, LB = c(-3, -3), UB = c(3, 3), n.sim = 200, rseed = 7, control = list(trace = 0))",
   "SN.gosolnp(fun=fn, LB=[-3, -3], UB=[3, 3], n_sim=200, rseed=7, control={'trace': 0})",
   "SN.gosolnp(nothing, nothing, fn; LB = [-3, -3], UB = [3, 3], n_sim = 200, rseed = 7, control = Dict(\"trace\" => 0))")
GO("clock", "SimLev:::.rsolnp_gosolnp(fun = fn, LB = c(-3, -3), UB = c(3, 3), n.sim = 100, control = list(trace = 0))",
   "SN.gosolnp(fun=fn, LB=[-3, -3], UB=[3, 3], n_sim=100, control={'trace': 0})",
   "SN.gosolnp(nothing, nothing, fn; LB = [-3, -3], UB = [3, 3], n_sim = 100, control = Dict(\"trace\" => 0))", sys_time = 1760870123.75)
GO("clock2", "{ a <- SimLev:::.rsolnp_gosolnp(fun = fn, LB = c(-3, -3), UB = c(3, 3), n.sim = 30, control = list(trace = 0)); u <- runif(1); b <- SimLev:::.rsolnp_gosolnp(fun = fn, LB = c(-3, -3), UB = c(3, 3), n.sim = 30, control = list(trace = 0)); list(a = GS(a), b = GS(b), u = u) }",
   "None\na = SN.gosolnp(fun=fn, LB=[-3, -3], UB=[3, 3], n_sim=30, control={'trace': 0}); u = RNG.runif(1); b = SN.gosolnp(fun=fn, LB=[-3, -3], UB=[3, 3], n_sim=30, control={'trace': 0})\nresult = {'a': GS(a), 'b': GS(b), 'u': u}",
   "nothing\na = SN.gosolnp(nothing, nothing, fn; LB = [-3, -3], UB = [3, 3], n_sim = 30, control = Dict(\"trace\" => 0)); u = RNG.runif(1); b = SN.gosolnp(nothing, nothing, fn; LB = [-3, -3], UB = [3, 3], n_sim = 30, control = Dict(\"trace\" => 0))\nresult = SL.RList(\"a\" => GS(a), \"b\" => GS(b), \"u\" => u)",
   sys_time = 1760870555.5, wrap = FALSE)
GO("restarts", "SimLev:::.rsolnp_gosolnp(pars = c(a = 0.5, b = 0.5), fun = fn, LB = c(-3, -3), UB = c(3, 3), n.sim = 100, n.restarts = 3, rseed = 11.7, distr = c(2, 3), distr.opt = list(list(mean = 0.5, sd = 1), list(mean = 0, sd = 2)), ineqfun = function(x) x[1] + x[2], ineqLB = -1, ineqUB = 1, control = list(trace = 0))",
   "SN.gosolnp(pars=pd.Series([0.5, 0.5], index=['a', 'b']), fun=fn, LB=[-3, -3], UB=[3, 3], n_sim=100, n_restarts=3, rseed=11.7, distr=[2, 3], distr_opt=[{'mean': 0.5, 'sd': 1}, {'mean': 0, 'sd': 2}], ineqfun=lambda x: [x.iloc[0] + x.iloc[1]], ineqLB=[-1], ineqUB=[1], control={'trace': 0})",
   "SN.gosolnp(SL.RVector([0.5, 0.5]; names = [\"a\", \"b\"]), nothing, fn; LB = [-3, -3], UB = [3, 3], n_sim = 100, n_restarts = 3, rseed = 11.7, distr = [2, 3], distr_opt = [Dict(\"mean\" => 0.5, \"sd\" => 1), Dict(\"mean\" => 0, \"sd\" => 2)], ineqfun = x -> [x[1] + x[2]], ineqLB = [-1], ineqUB = [1], control = Dict(\"trace\" => 0))")
GO("ineq2", "SimLev:::.rsolnp_gosolnp(fun = fn, LB = c(-3, -3, -3), UB = c(3, 3, 3), n.sim = 50, rseed = 3, distr = c(2, 2, 2), distr.opt = list(list(mean = 0, sd = 1), list(mean = 1, sd = 0.1), list(mean = -2.9, sd = 0.05)), ineqfun = function(x) c(x[1] + x[2], x[3]), ineqLB = c(-1, -3), ineqUB = c(1, 0), control = list(trace = 0))",
   "SN.gosolnp(fun=fn, LB=[-3, -3, -3], UB=[3, 3, 3], n_sim=50, rseed=3, distr=[2, 2, 2], distr_opt=[{'mean': 0, 'sd': 1}, {'mean': 1, 'sd': 0.1}, {'mean': -2.9, 'sd': 0.05}], ineqfun=lambda x: [x[0] + x[1], x[2]], ineqLB=[-1, -3], ineqUB=[1, 0], control={'trace': 0})",
   "SN.gosolnp(nothing, nothing, fn; LB = fill(-3, 3), UB = fill(3, 3), n_sim = 50, rseed = 3, distr = [2, 2, 2], distr_opt = [Dict(\"mean\" => 0, \"sd\" => 1), Dict(\"mean\" => 1, \"sd\" => 0.1), Dict(\"mean\" => -2.9, \"sd\" => 0.05)], ineqfun = x -> [x[1] + x[2], x[3]], ineqLB = [-1, -3], ineqUB = [1, 0], control = Dict(\"trace\" => 0))")
GO("fixed_normal", "SimLev:::.rsolnp_gosolnp(pars = c(0.5, 1), fixed = 2, fun = fn, LB = c(-3, -3), UB = c(3, 3), n.sim = 60, rseed = 5, distr = c(3, 1), distr.opt = list(list(mean = 1, sd = 0.5), list()), control = list(trace = 0))",
   "SN.gosolnp(pars=np.array([0.5, 1]), fixed=2, fun=fn, LB=[-3, -3], UB=[3, 3], n_sim=60, rseed=5, distr=[3, 1], distr_opt=[{'mean': 1, 'sd': 0.5}, {}], control={'trace': 0})",
   "SN.gosolnp([0.5, 1.0], 2, fn; LB = [-3, -3], UB = [3, 3], n_sim = 60, rseed = 5, distr = [3, 1], distr_opt = [Dict(\"mean\" => 1, \"sd\" => 0.5), Dict()], control = Dict(\"trace\" => 0))")
GO("infeasible", "SimLev:::.rsolnp_gosolnp(fun = fn, LB = c(-3, -3), UB = c(3, 3), n.sim = 50, rseed = 1, ineqfun = function(x) x[1] + x[2], ineqLB = 10, ineqUB = 11, control = list(trace = 0))",
   "SN.gosolnp(fun=fn, LB=[-3, -3], UB=[3, 3], n_sim=50, rseed=1, ineqfun=lambda x: [x[0] + x[1]], ineqLB=[10], ineqUB=[11], control={'trace': 0})",
   "SN.gosolnp(nothing, nothing, fn; LB = [-3, -3], UB = [3, 3], n_sim = 50, rseed = 1, ineqfun = x -> [x[1] + x[2]], ineqLB = [10], ineqUB = [11], control = Dict(\"trace\" => 0))")
GO("nonfinite", "SimLev:::.rsolnp_gosolnp(fun = function(x) if (x[1] > 2) NaN else fn(x), LB = c(-3, -3), UB = c(3, 3), n.sim = 30, rseed = 2, control = list(trace = 0))",
   "SN.gosolnp(fun=lambda x: float('nan') if x[0] > 2 else fn(x), LB=[-3, -3], UB=[3, 3], n_sim=30, rseed=2, control={'trace': 0})",
   "SN.gosolnp(nothing, nothing, x -> x[1] > 2 ? NaN : fn(x); LB = [-3, -3], UB = [3, 3], n_sim = 30, rseed = 2, control = Dict(\"trace\" => 0))")
GO("err_nofeas", "SimLev:::.rsolnp_gosolnp(fun = fn, LB = c(-3, -3), UB = c(3, 3), n.sim = 50, n.restarts = 2, rseed = 1, control = list(trace = 0, outer.iter = 1))",
   "SN.gosolnp(fun=fn, LB=[-3, -3], UB=[3, 3], n_sim=50, n_restarts=2, rseed=1, control={'trace': 0, 'outer.iter': 1})",
   "SN.gosolnp(nothing, nothing, fn; LB = [-3, -3], UB = [3, 3], n_sim = 50, n_restarts = 2, rseed = 1, control = Dict(\"trace\" => 0, \"outer.iter\" => 1))")
GO("err_lb", "SimLev:::.rsolnp_gosolnp(fun = fn, UB = c(3, 3))", "SN.gosolnp(fun=fn, UB=[3, 3])", "SN.gosolnp(nothing, nothing, fn; UB = [3, 3])")
GO("err_ub", "SimLev:::.rsolnp_gosolnp(fun = fn, LB = c(3, 3))", "SN.gosolnp(fun=fn, LB=[3, 3])", "SN.gosolnp(nothing, nothing, fn; LB = [3, 3])")
GO("err_fixed", "SimLev:::.rsolnp_gosolnp(fixed = 1, fun = fn, LB = c(-3, -3), UB = c(3, 3))", "SN.gosolnp(fixed=1, fun=fn, LB=[-3, -3], UB=[3, 3])",
   "SN.gosolnp(nothing, 1, fn; LB = [-3, -3], UB = [3, 3])")
GO("err_fixed_oob", "SimLev:::.rsolnp_gosolnp(pars = c(1, 1), fixed = 3, fun = fn, LB = c(-3, -3), UB = c(3, 3))",
   "SN.gosolnp(pars=np.array([1., 1.]), fixed=3, fun=fn, LB=[-3, -3], UB=[3, 3])", "SN.gosolnp([1.0, 1.0], 3, fn; LB = [-3, -3], UB = [3, 3])")
GO("err_mean", "SimLev:::.rsolnp_gosolnp(fun = fn, LB = c(-3, -3), UB = c(3, 3), distr = c(1, 2), distr.opt = list(list(), list(sd = 1)))",
   "SN.gosolnp(fun=fn, LB=[-3, -3], UB=[3, 3], distr=[1, 2], distr_opt=[{}, {'sd': 1}])",
   "SN.gosolnp(nothing, nothing, fn; LB = [-3, -3], UB = [3, 3], distr = [1, 2], distr_opt = [Dict(), Dict(\"sd\" => 1)])")
GO("err_sd", "SimLev:::.rsolnp_gosolnp(fun = fn, LB = c(-3, -3), UB = c(3, 3), distr = c(3, 3), distr.opt = list(list(mean = 0, sd = 1), list(mean = 1)))",
   "SN.gosolnp(fun=fn, LB=[-3, -3], UB=[3, 3], distr=[3, 3], distr_opt=[{'mean': 0, 'sd': 1}, {'mean': 1}])",
   "SN.gosolnp(nothing, nothing, fn; LB = [-3, -3], UB = [3, 3], distr = [3, 3], distr_opt = [Dict(\"mean\" => 0, \"sd\" => 1), Dict(\"mean\" => 1)])")
GO("err_fun", "SimLev:::.rsolnp_gosolnp(fun = function(x) if (x[1] > 2.5) stop('boom') else fn(x), LB = c(-3, -3), UB = c(3, 3), n.sim = 40, rseed = 2)",
   "SN.gosolnp(fun=lambda x: (_ for _ in ()).throw(SN.RError('boom')) if x[0] > 2.5 else fn(x), LB=[-3, -3], UB=[3, 3], n_sim=40, rseed=2)",
   "SN.gosolnp(nothing, nothing, x -> x[1] > 2.5 ? error(\"boom\") : fn(x); LB = [-3, -3], UB = [3, 3], n_sim = 40, rseed = 2)")

# ── rtruncnorm (truncnorm 1.0-9) ────────────────────────────────────────────
TNC <- rbind(c(0, 1, 0, 1), c(-1, 1, 0, 1), c(-0.5, 0.5, 0, 1), c(-3, 3, 0, 1), c(0.5, 3, 0, 1), c(0.5, 1, 0, 1),
             c(1, 5, 0, 1), c(3, 10, 0, 1), c(0.3, 10, 0, 1), c(-3, -0.5, 0, 1), c(-1, -0.8, 0, 1), c(-10, -3, 0, 1),
             c(-10, -0.3, 0, 1), c(-Inf, 1, 0, 1), c(-Inf, -2, 0, 1), c(0.2, Inf, 0, 1), c(2, Inf, 0, 1), c(-Inf, Inf, 1, 2),
             c(1, 1, 0, 1), c(NaN, 1, 0, 1), c(2.220446049250313e-16, 1 - 1e-8, 0.05, 0.1), c(0, 1 - 1e-8, 0.9, 1.8),
             c(-0.03, 0.03, 3e-4, 6e-4), c(1, 2, 1.5, 0))
case2("tn_branches", "set.seed(42); c(unlist(lapply(seq_len(nrow(TNC)), function(i) SimLev:::.truncnorm_rtruncnorm(7, TNC[i, 1], TNC[i, 2], TNC[i, 3], TNC[i, 4]))), runif(2))",
      "RNG.set_seed(42); result = np.concatenate([TN.rtruncnorm(7, *TNC[i, :]) for i in range(TNC.shape[0])] + [RNG.runif(2)])",
      list(TNC = TNC), jl = "RNG.set_seed(42); result = vcat([TN.rtruncnorm(7, TNC[i, :]...) for i in 1:size(TNC, 1)]..., RNG.runif(2))", sys_time = NULL)
case2("tn_recycle", "set.seed(3); list(SimLev:::.truncnorm_rtruncnorm(5, c(0, 1), c(2, 3, 4), 0, c(1, 2)), SimLev:::.truncnorm_rtruncnorm(c(9, 9, 9), -1, 1), SimLev:::.truncnorm_rtruncnorm(2.9, 0, 1, c(0, 1, 2)))",
      "RNG.set_seed(3); result = [TN.rtruncnorm(5, [0, 1], [2, 3, 4], 0, [1, 2]), TN.rtruncnorm([9, 9, 9], -1, 1), TN.rtruncnorm(2.9, 0, 1, [0, 1, 2])]",
      jl = "RNG.set_seed(3); result = Any[TN.rtruncnorm(5, [0, 1], [2, 3, 4], 0, [1, 2]), TN.rtruncnorm([9, 9, 9], -1, 1), TN.rtruncnorm(2.9, 0, 1, [0, 1, 2])]", sys_time = NULL)
case2("tn_zero", "SimLev:::.truncnorm_rtruncnorm(0, 0, 1)", "result = TN.rtruncnorm(0, 0, 1)", jl = "result = TN.rtruncnorm(0, 0, 1)", sys_time = NULL)
case2("tn_err_len", "SimLev:::.truncnorm_rtruncnorm(3, numeric(0), 1)", "result = TN.rtruncnorm(3, [], 1)", jl = "result = TN.rtruncnorm(3, Float64[], 1)", sys_time = NULL)
case2("tn_err_n", "SimLev:::.truncnorm_rtruncnorm('a', 0, 1)", "result = TN.rtruncnorm('a', 0, 1)", jl = "result = TN.rtruncnorm(\"a\", 0, 1)", sys_time = NULL)
ref_done()

/*
 * vendor_rugarch.c  --  uebernommener C-Code des R-Pakets rugarch
 *
 * Paket:    rugarch 1.5-6 (CRAN, 2026-07-18), Dateien src/garchmodels.c
 *           (sgarchfilterC, gjrgarchfilterC), src/filters.c (sgarchfilter,
 *           gjrgarchfilter, arfimaxfilter) und src/distributions.c
 *           (garchdistribution, dnormstd)
 * Autoren:  Alexios Galanos [aut, cre, cph], Tobias Kley [ctb]
 * Lizenz:   GPL-3
 * Angepasst fuer SimLev (siehe inst/COPYRIGHTS):
 *   - Uebernommen ist nur, was die Likelihood von sGARCH und gjrGARCH mit
 *     Normalverteilung braucht (.rugarch_sgarchLLH, .rugarch_gjrgarchLLH in
 *     R/vendor_rugarch.R). Die Funktionen sind static und tragen den Praefix
 *     rugarch_; ihre Ruempfe sind unveraendert, ausser dass
 *     rugarch_garchdistribution nur den Zweig ndis == 1 (Normalverteilung)
 *     enthaelt (die anderen Verteilungen sind nicht uebernommen; R ruft sie
 *     nicht, ugarchspec laesst nur "norm" zu).
 *   - rugarch ruft sgarchfilterC und gjrgarchfilterC ueber .C auf. SimLev
 *     registriert in init.c nur .Call-Routinen (frueher erzeugte
 *     Rcpp::compileAttributes die Registrierung), deshalb rufen die
 *     R-Funktionen die Huellen C_rugarch_sgarchfilterC und
 *     C_rugarch_gjrgarchfilterC ueber .Call auf.
 *     Sie bilden .C(..., NAOK = FALSE) nach: Pruefung der Argumente (gleiche
 *     Meldungen und Argumentnummern), Kopie aller Argumente, Rueckgabe der
 *     Liste aller Argumente mit ihren Namen.
 */
#include <R.h>
#include <Rinternals.h>
#include <math.h>

/* ---- src/distributions.c ------------------------------------------------ */

static double rugarch_dnormstd(const double x)
{
  double pdf;
  pdf = exp ( -0.5 * x * x ) / sqrt ( 2.0 * M_PI );
  if(pdf == 0.0) pdf = 0.0 + 2.22507e-24;
  return pdf;
}

static double rugarch_garchdistribution(const double zz, const double hh, const double skew, const double shape, const double dlambda, const int ndis){
	/*ndist: 1- normal
			 (SimLev: die Verteilungen 2 bis 10 sind nicht uebernommen)
	*/
	double pdf=0;
	if(ndis==1)
	{
		pdf=rugarch_dnormstd(zz)/hh;
	}
	return pdf;
}

/* ---- src/filters.c ------------------------------------------------------ */

static void rugarch_sgarchfilter(int *model, double *pars, int *idx, double *vexdata, double *e, int T, int i, double *h)
{
	int j, ind;
	h[i] = h[i] + pars[idx[6]];
	if( model[14]>0 )
	{
		for( j=0; j<model[14]; j++ )
		{
			ind = i + ( T * j );
			h[i] = h[i] + pars[idx[14]+j]*vexdata[ind];
		}
	}
	for( j=0; j<model[7]; j++ )
	{
		h[i] = h[i] + pars[idx[7]+j]*e[i-(j+1)];
	}
	for( j=0; j<model[8]; j++ )
	{
		h[i] = h[i] + pars[idx[8]+j]*h[i-(j+1)];
	}
}

static void rugarch_gjrgarchfilter(int *model, double *pars, int *idx, double *vexdata, double *nres, double *e, int T, int i, double *h)
{
	int j, ind;
	h[i] = h[i] + pars[idx[6]];
	if( model[14]>0 )
	{
		for( j=0; j<model[14]; j++ )
		{
			ind = i + ( T * j );
			h[i] = h[i] + pars[idx[14]+j]*vexdata[ind];
		}
	}
	for( j=0; j<model[7]; j++ )
	{
		h[i] = h[i] + pars[idx[7]+j]*e[i-(j+1)]+pars[idx[9]+j]*nres[i-(j+1)];
	}
	for( j=0; j<model[8]; j++ )
	{
		h[i] = h[i] + pars[idx[8]+j]*h[i-(j+1)];
	}
}

static void rugarch_arfimaxfilter(int* model, double *pars, int *idx, double *x, double *res,
		double *mexdata, double *zrf, double *constm, double *condm, double h,
		int m, int i, int T)
{
/* --------------------------------------------------------------------------------
 * ARFIMA Process :
 * (1-L)^(-darfima).e[t] = phi(1-L)(y[t] - mu[t]) - psi(L).e[t]
 * where mu[t] includes constant, external and arch-in-mean
 * L is the lag operator
 * --------------------------------------------------------------------------------
 * */
	/*0 constm, 1 condm, 2 res*/
	int j, k, ind;
	constm[i] = pars[0];
	// GARCH-In-Mean Initialization (h is always the sigma, not sigma^2 so that h^model[4] is correct)
	if(model[4]>0)
	{
		constm[i]+=pars[idx[4]]*pow(h, model[4]);
	}
	// Exogenous Regressor Initialization
	if(model[5]>0)
	{
		if(model[19]==0){
			for(k=0;k<model[5];k++)
			{
				ind=i+(T*k);
				constm[i]+=pars[idx[5]+k]*mexdata[ind];
			}
		} else{
			if(model[19] == model[5]){
				for(k=0;k<model[5];k++)
				{
					ind=i+(T*k);
					constm[i]+=pars[idx[5]+k]*(mexdata[ind]*h);
				}
			} else{
				int tmpi = model[5]-model[19];
				for(k=0;k<tmpi;k++)
				{
					ind=i+(T*k);
					constm[i]+=pars[idx[5]+k]*mexdata[ind];
				}
				for(k=tmpi;k<model[5];k++)
				{
					ind=i+(T*k);
					constm[i]+=pars[idx[5]+k]*(mexdata[ind]*h);
				}
			}
		}
	}
	condm[i]+=constm[i];
	//ARMA initialization
	if(model[1]>0 || model[2]>0)
	{
		if(i>=model[1])
		{
			if(model[1]>0)
			{
				for(j=0; j<model[1];j++)
				{
					condm[i]+=pars[idx[1]+j]*(x[i-(j+1)]-constm[i-(j+1)]);
				}
			}
			if(model[2]>0)
			{
				for(j=0; j<model[2];j++)
				{
					if(i-j-1>=0)
					{
						condm[i]+=pars[idx[2]+j]*(x[i-(j+1)]-condm[i-(j+1)]);
					}
				}
			}
		}
	}
	res[i]=x[i]-condm[i];
	//arfima initialization
	if(model[3]>0)
	{
		if(i>0 && i<m)
		{
			double tmp=0;
			for(k=1;k<=i;k++)
			{
				tmp+=(zrf[i-k+1]*res[k-1]) ;
			}
			res[i]=-1.0 * tmp;
		}
		if(i>0 && i>=m)
		{
			double tmp=0;
			for(k=i;k>0;k--)
			{
				// quicker to count down
				tmp+=zrf[k]*(x[i-k] - condm[i-k]) ;
			}
			res[i]+= tmp;
		}
	}
}

/* ---- src/garchmodels.c -------------------------------------------------- */

static void rugarch_sgarchfilterC(int *model, double *pars, int *idx, double *hEst, double *x, double *res,
		double *e, double *mexdata, double *vexdata, double *zrf, double *constm, double *condm,
		int *m, int *T, double *h, double *z, double *llh, double *LHT)
{
	int i;
	double lk=0;
	double hm = 0;
	for(i=0; i<*m; i++)
	{
		h[i] = *hEst;
		rugarch_arfimaxfilter(model, pars, idx, x, res, mexdata, zrf, constm, condm, sqrt(fabs(*hEst)), *m, i, *T);
		e[i] = res[i] * res[i];
		z[i] = res[i]/sqrt(fabs(h[i]));
		LHT[i] = log(rugarch_garchdistribution(z[i], sqrt(fabs(h[i])), pars[idx[15]], pars[idx[16]], pars[idx[17]], model[20]));
		lk = lk - LHT[i];
	}
	for (i=*m; i<*T; i++)
	{
		rugarch_sgarchfilter(model, pars, idx, vexdata, e, *T, i, h);
		hm = sqrt(fabs(h[i]));
		rugarch_arfimaxfilter(model, pars, idx, x, res, mexdata, zrf, constm, condm, hm, *m, i, *T);
		e[i] = res[i] * res[i];
		z[i] = res[i]/sqrt(fabs(h[i]));
		LHT[i] = log(rugarch_garchdistribution(z[i], sqrt(fabs(h[i])), pars[idx[15]], pars[idx[16]], pars[idx[17]], model[20]));
		lk = lk - LHT[i];
	}
	*llh=lk;
}

static void rugarch_gjrgarchfilterC(int *model, double *pars, int *idx, double *hEst, double *x,
		double *res, double *nres, double *e, double *mexdata, double *vexdata, double *zrf,
		double *constm, double *condm, int *m, int *T, double *h, double *z, double *llh, double *LHT)
{
	int i;
	double lk=0;
	double hm=0;
	for( i=0; i<*m; i++ )
	{
		h[i] = *hEst;
		rugarch_arfimaxfilter(model, pars, idx, x, res, mexdata, zrf, constm, condm, sqrt(fabs(*hEst)), *m, i, *T);
		e[i] = res[i] * res[i];
		nres[i] = res[i] < 0.0 ? e[i] : 0.0;
		z[i] = res[i]/sqrt(fabs(h[i]));
		LHT[i] = log(rugarch_garchdistribution(z[i], sqrt(fabs(h[i])), pars[idx[15]], pars[idx[16]], pars[idx[17]], model[20]));
		lk = lk - LHT[i];
	}
	// Main Loop
	for ( i=*m; i<*T; i++ )
	{
		rugarch_gjrgarchfilter(model, pars, idx, vexdata, nres, e, *T, i, h);
		hm = sqrt(fabs(h[i]));
		rugarch_arfimaxfilter(model, pars, idx, x, res, mexdata, zrf, constm, condm, hm, *m, i, *T);
		e[i] = res[i] * res[i];
		nres[i] = (res[i] < 0.0) ? e[i] : 0.0;
		z[i] = res[i]/sqrt(fabs(h[i]));
		LHT[i] = log(rugarch_garchdistribution(z[i], sqrt(fabs(h[i])), pars[idx[15]], pars[idx[16]], pars[idx[17]], model[20]));
		lk = lk - LHT[i];
	}
	*llh = lk;
}

/* ---- .C-Nachbildung (SimLev) -------------------------------------------- */

/* Argument wie .C kopieren und wie .C mit NAOK = FALSE pruefen; die R-Seite
 * uebergibt wie in rugarch as.integer()/as.double() */
static SEXP rugarch_c_arg(SEXP x, int argno)
{
  R_xlen_t i, n;
  SEXP y;
  if(TYPEOF(x) == REALSXP) {
    n = XLENGTH(x);
    for(i = 0; i < n; i++)
      if(!R_FINITE(REAL(x)[i]))
        error("NA/NaN/Inf in foreign function call (arg %d)", argno);
  } else if(TYPEOF(x) == INTSXP) {
    n = XLENGTH(x);
    for(i = 0; i < n; i++)
      if(INTEGER(x)[i] == NA_INTEGER)
        error("NAs in foreign function call (arg %d)", argno);
  } else {
    error("invalid mode (%s) to pass to C or Fortran (arg %d)", type2char(TYPEOF(x)), argno);
  }
  y = duplicate(x);
  return y;
}

/* Liste der kopierten Argumente mit den Namen wie .C(...) */
static SEXP rugarch_c_call(SEXP args, int nargs)
{
  SEXP out, nms, onms;
  int k;
  if(TYPEOF(args) != VECSXP || LENGTH(args) != nargs)
    error("rugarch-Uebernahme: interne Argumentliste ungueltig");
  PROTECT(out = allocVector(VECSXP, nargs));
  for(k = 0; k < nargs; k++)
    SET_VECTOR_ELT(out, k, rugarch_c_arg(VECTOR_ELT(args, k), k + 1));
  nms = getAttrib(args, R_NamesSymbol);
  PROTECT(onms = duplicate(nms));
  setAttrib(out, R_NamesSymbol, onms);
  UNPROTECT(2);
  return out;
}

#define RG_I(k) INTEGER(VECTOR_ELT(out, k))
#define RG_D(k) REAL(VECTOR_ELT(out, k))

/* .C("sgarchfilterC", model, pars, idx, hEst, x, res, e, mexdata, vexdata,
 *    zrf, constm, condm, m, T, h, z, llh, LHT) */
SEXP C_rugarch_sgarchfilterC(SEXP args)
{
  SEXP out;
  PROTECT(out = rugarch_c_call(args, 18));
  if(TYPEOF(VECTOR_ELT(out, 0)) != INTSXP || TYPEOF(VECTOR_ELT(out, 2)) != INTSXP ||
     TYPEOF(VECTOR_ELT(out, 12)) != INTSXP || TYPEOF(VECTOR_ELT(out, 13)) != INTSXP)
    error("rugarch-Uebernahme: interne Argumenttypen ungueltig");
  rugarch_sgarchfilterC(RG_I(0), RG_D(1), RG_I(2), RG_D(3), RG_D(4), RG_D(5), RG_D(6), RG_D(7),
                        RG_D(8), RG_D(9), RG_D(10), RG_D(11), RG_I(12), RG_I(13), RG_D(14),
                        RG_D(15), RG_D(16), RG_D(17));
  UNPROTECT(1);
  return out;
}

/* .C("gjrgarchfilterC", model, pars, idx, hEst, x, res, nres, e, mexdata,
 *    vexdata, zrf, constm, condm, m, T, h, z, llh, LHT) */
SEXP C_rugarch_gjrgarchfilterC(SEXP args)
{
  SEXP out;
  PROTECT(out = rugarch_c_call(args, 19));
  if(TYPEOF(VECTOR_ELT(out, 0)) != INTSXP || TYPEOF(VECTOR_ELT(out, 2)) != INTSXP ||
     TYPEOF(VECTOR_ELT(out, 13)) != INTSXP || TYPEOF(VECTOR_ELT(out, 14)) != INTSXP)
    error("rugarch-Uebernahme: interne Argumenttypen ungueltig");
  rugarch_gjrgarchfilterC(RG_I(0), RG_D(1), RG_I(2), RG_D(3), RG_D(4), RG_D(5), RG_D(6), RG_D(7),
                          RG_D(8), RG_D(9), RG_D(10), RG_D(11), RG_D(12), RG_I(13), RG_I(14),
                          RG_D(15), RG_D(16), RG_D(17), RG_D(18));
  UNPROTECT(1);
  return out;
}

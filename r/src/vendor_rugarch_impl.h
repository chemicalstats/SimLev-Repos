/*
 * vendor_rugarch_impl.h  --  uebernommener C-Code des R-Pakets rugarch, reine Rechnung
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
 *   - GEMEINSAME QUELLE FUER R UND PYTHON (Etappe 7.3a): Diese Datei kennt kein R
 *     und kein Python (frueher Teil von src/vendor_rugarch.c, die jetzt nur die
 *     .Call-Huellen mit der .C-Nachbildung enthaelt und diese Datei einbindet,
 *     dadurch derselbe Maschinencode wie vor der Teilung). Python bindet sie in
 *     python/src/_ext_rugarch_c.c ein (Erweiterungsmodul simlev._ext) und baut aus
 *     einer Byte-fuer-Byte-Kopie in python/src/ (python/tests/test_shared_c.py);
 *     Aenderungen nur hier vornehmen und danach kopieren. Der reine Python-Port
 *     (simlev/_r/rugarch.py, _LLH._filter) bleibt der Rueckfall.
 *   - exp, log, pow und sqrt aus der libm des Systems, in R wie in Python.
 *     Keine Zufallszahlen.
 */
#ifndef SIMLEV_VENDOR_RUGARCH_IMPL_H
#define SIMLEV_VENDOR_RUGARCH_IMPL_H

// Gleitkomma wie im Pilot (simlev_core.h): Abbruch bei -ffast-math; kein
// Zusammenziehen von a * b + c zu fma. Das Pragma steht nur dort, wo der Compiler
// fma ueberhaupt erzeugen kann (__FP_FAST_FMA, etwa aarch64 oder -mfma): auf
// x86-64 ohne FMA ist -ffp-contract=off wirkungslos, das GCC-Pragma optimize
// veraendert dort aber die Codeerzeugung der ganzen Datei (geprueft), und R soll
// denselben Maschinencode wie vor der Teilung ausfuehren. Python baut immer mit
// -ffp-contract=off (setup.py) und setzt SIMLEV_FP_CONTRACT_BY_FLAG.
#if defined(__FAST_MATH__)
#error "Gemeinsame Kerne duerfen nicht mit -ffast-math uebersetzt werden (Bitgleichheit)."
#endif
#if defined(__clang__)
#pragma STDC FP_CONTRACT OFF
#elif defined(_MSC_VER)
#pragma fp_contract (off)
#elif defined(__GNUC__) && (defined(__FP_FAST_FMA) || defined(__FP_FAST_FMAF)) && !defined(SIMLEV_FP_CONTRACT_BY_FLAG)
#pragma GCC optimize ("fp-contract=off")
#endif

#include <math.h>

#ifndef M_PI
#define M_PI 3.141592653589793238462643383279502884197169399375
#endif

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

#endif

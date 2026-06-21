"""
This program replicates Hasbrouck (2009 JoF), using a Gibbs-sampling (MCMC) procedure 
to estimate the classic Roll (1984 JoF) market microstructure model, 
and infer the effective spread from the observed price series.

Based on adapted from Joel Hasbrouck (July, 2010)'s SAS codes, 
crspGibbsBuildv01.sas and RollGibbsLibrary02.sas

Optimizations & Architecture Notes:
  - Native CRSP V2 CIZ Architecture support (using volume fields for trade flags)
  - Full Numba @njit Acceleration for Bayesian Math kernels
  - High-accuracy numerical inverse error function for Numba compilation stability
  - Joblib Multi-Core Parallel Processing for Stock-Year Panel Data
 
Rong Wang (Updated June 2026)
"""

import os
import time
import argparse
import numpy as np
import math
import pandas as pd
from pathlib import Path
import gc
import wrds
from tqdm import tqdm
from joblib import Parallel, delayed, parallel_config
from numba import njit

# Global precision configurations
INFINITY = 1e30
EPS = 1e-30

# =============================================================================
# BAYESIAN ENGINE & FUNCTIONS
# =============================================================================

@njit
def local_erfinv(y):
    # High-accuracy numerical approximation for inverse error function to satisfy Numba compilation
    sign = 1.0
    if y < 0:
        sign = -1.0
        y = -y
    if y == 0:
        return 0.0
    
    a = 0.147
    log_term = np.log(1.0 - y**2)
    tmp1 = 2.0 / (np.pi * a) + log_term / 2.0
    tmp2 = log_term / a
    
    val = tmp1**2 - tmp2
    if val < 0: 
        val = 0.0
        
    inner = np.sqrt(val) - tmp1
    if inner < 0:
        inner = 0.0
        
    return sign * np.sqrt(inner)

@njit
def rand_std_norm_t(zlow, zhigh):
    if zlow == -INFINITY and zhigh == INFINITY: 
        return np.random.normal(0.0, 1.0)
        
    # Hard tail boundary logic using Robert (1995) exponential proposal
    if zlow > 5.0:
        alpha = (zlow + np.sqrt(zlow**2 + 4.0)) / 2.0
        while True:
            z = zlow - np.log(np.random.uniform(0.0, 1.0)) / alpha
            rho = np.exp(-0.5 * (z - alpha)**2)
            if np.random.uniform(0.0, 1.0) <= rho:
                return z
                
    if zhigh < -5.0:
        alpha = (-zhigh + np.sqrt(zhigh**2 + 4.0)) / 2.0
        while True:
            z = -zhigh - np.log(np.random.uniform(0.0, 1.0)) / alpha
            rho = np.exp(-0.5 * (z - alpha)**2)
            if np.random.uniform(0.0, 1.0) <= rho:
                return -z

    # Standard range inversion evaluation avoiding Scipy dependency inside Numba
    plow = 0.0 if zlow == -INFINITY else 0.5 * (1.0 + math.erf(zlow / np.sqrt(2.0)))
    phigh = 1.0 if zhigh == INFINITY else 0.5 * (1.0 + math.erf(zhigh / np.sqrt(2.0)))
    
    p = plow + np.random.uniform(0.0, 1.0) * (phigh - plow)
    if p >= 1.0: return zlow + 1e-10
    if p <= 0.0: return zhigh - 1e-10
    
    return np.sqrt(2.0) * local_erfinv(2.0 * p - 1.0)

@njit
def mvnrnd_t(mu, cov, v_lower, v_upper):
    f = np.linalg.cholesky(cov)
    n = len(mu)
    eta = np.zeros(n)
    low = (v_lower[0] - mu[0]) / f[0, 0]
    high = (v_upper[0] - mu[0]) / f[0, 0]
    eta[0] = rand_std_norm_t(low, high)
    for k in range(1, n):
        eta_sum = 0.0
        for j in range(k):
            eta_sum += f[k, j] * eta[j]
        low = (v_lower[k] - mu[k] - eta_sum) / f[k, k]
        high = (v_upper[k] - mu[k] - eta_sum) / f[k, k]
        eta[k] = rand_std_norm_t(low, high)
        
    out = np.zeros(n)
    for i in range(n):
        val = mu[i]
        for j in range(n):
            val += f[i, j] * eta[j]
        out[i] = val
    return out

@njit
def q_draw_fast(p, q, c, varu):
    n_obs = len(p)
    n_skip = 2
    ru = np.random.uniform(0.0, 1.0, size=n_obs)
    
    for i_start in range(n_skip):
        for i in range(1, n_obs):
            if (i % n_skip) == i_start and q[i] != 0.0:
                
                # Check outcome assuming q[i] = 1
                q_try_buy = 1.0
                u_buy = (p[i] - c * q_try_buy) - (p[i-1] - c * q[i-1])
                s_buy = (u_buy ** 2) / (2.0 * varu)
                
                # Check outcome assuming q[i] = -1
                q_try_sell = -1.0
                u_sell = (p[i] - c * q_try_sell) - (p[i-1] - c * q[i-1])
                s_sell = (u_sell ** 2) / (2.0 * varu)
                
                if i < n_obs - 1 and q[i+1] != 0.0:
                    u_f_buy = (p[i+1] - c * q[i+1]) - (p[i] - c * q_try_buy)
                    s_buy += (u_f_buy ** 2) / (2.0 * varu)
                    
                    u_f_sell = (p[i+1] - c * q[i+1]) - (p[i] - c * q_try_sell)
                    s_sell += (u_f_sell ** 2) / (2.0 * varu)
                
                log_odds = s_sell - s_buy
                if log_odds < 500.0:
                    odds = np.exp(log_odds)
                    p_buy = odds / (1.0 + odds)
                else:
                    p_buy = 1.0
                
                q[i] = 1.0 if ru[i] <= p_buy else -1.0
    return q

@njit
def roll_gibbs_core(p, pm, q, n_sweeps, reg_draw, varu_draw, q_draw_flag):
    n_obs = len(p)
    dp = np.zeros(n_obs - 1)
    for i in range(n_obs - 1):
        dp[i] = p[i+1] - p[i]
        
    if q_draw_flag:
        for i in range(1, n_obs):
            if q[i] != 0.0:
                diff = p[i] - p[i-1]
                q[i] = 1.0 if diff >= 0.0 else -1.0
        q[0] = 1.0

    varu = 0.001
    c = 0.01
    beta = 1.0
    parm_out = np.zeros((n_sweeps, 3))
    
    prior_mu = np.array([0.0, 1.0])
    covi = np.zeros((2, 2))
    covi[0, 0] = 1.0 / 1.0
    covi[1, 1] = 1.0 / 2.0
    
    coeff_lower = np.array([0.0, -INFINITY])
    coeff_upper = np.array([INFINITY, INFINITY])
    
    for sweep in range(n_sweeps):
        dq = np.zeros(n_obs - 1)
        dpm = np.zeros(n_obs - 1)
        for i in range(n_obs - 1):
            dq[i] = q[i+1] - q[i]
            dpm[i] = pm[i+1] - pm[i]
            
        if reg_draw:
            xx00 = 0.0; xx01 = 0.0; xx11 = 0.0
            xy0 = 0.0; xy1 = 0.0
            for i in range(n_obs - 1):
                xx00 += dq[i] * dq[i]
                xx01 += dq[i] * dpm[i]
                xx11 += dpm[i] * dpm[i]
                xy0  += dq[i] * dp[i]
                xy1  += dpm[i] * dp[i]
                
            inv_varu = 1.0 / varu
            di00 = inv_varu * xx00 + covi[0, 0] + 1e-9  
            di01 = inv_varu * xx01
            di11 = inv_varu * xx11 + covi[1, 1] + 1e-9
            
            det = di00 * di11 - di01 * di01
            D = np.zeros((2, 2))
            D[0, 0] = di11 / det
            D[0, 1] = -di01 / det
            D[1, 0] = -di01 / det
            D[1, 1] = di00 / det
            
            dd0 = inv_varu * xy0 + covi[0, 0] * prior_mu[0]
            dd1 = inv_varu * xy1 + covi[1, 1] * prior_mu[1]
            
            post_mu = np.zeros(2)
            post_mu[0] = D[0, 0] * dd0 + D[0, 1] * dd1
            post_mu[1] = D[1, 0] * dd0 + D[1, 1] * dd1
            
            coeff_draw = mvnrnd_t(post_mu, D, coeff_lower, coeff_upper)
            c = coeff_draw[0]
            beta = coeff_draw[1]
            
        if varu_draw:
            sum_u2 = 0.0
            for i in range(n_obs - 1):
                u_val = dp[i] - c * dq[i] - beta * dpm[i]
                sum_u2 += u_val * u_val
            post_alpha = 1e-12 + (n_obs - 1) / 2.0
            post_beta = 1e-12 + sum_u2 / 2.0
            # Complies with positional-only mapping for Numba random engines
            x_draw = np.random.gamma(post_alpha, 1.0 / post_beta)
            varu = 1.0 / x_draw
            
        if q_draw_flag:
            p2 = np.zeros(n_obs)
            for i in range(n_obs):
                p2[i] = p[i] - beta * pm[i]
            q = q_draw_fast(p2, q, c, varu)
            
        parm_out[sweep, 0] = c
        parm_out[sweep, 1] = beta
        parm_out[sweep, 2] = varu
        
    return parm_out

def estimate_single_segment(group_keys, sub_df):
    t_perm, t_yr, t_ks = group_keys
    p_v = sub_df['p'].to_numpy(dtype=np.float64)
    pm_v = sub_df['pm'].to_numpy(dtype=np.float64)
    q_v = sub_df['q'].to_numpy(dtype=np.float64)
    
    raw_draws = roll_gibbs_core(p_v, pm_v, q_v, n_sweeps=1000, reg_draw=1, varu_draw=1, q_draw_flag=1)
    post_burn = raw_draws[200:, :]
    
    return [
        t_perm, t_yr, t_ks,
        np.mean(post_burn[:, 0]), 
        np.mean(post_burn[:, 1]), 
        np.mean(post_burn[:, 2]), 
        np.mean(np.sqrt(post_burn[:, 2]))
    ]
    

# =============================================================================
# DATA PROCESSING PIPELINE
# =============================================================================

def run_crsp_gibbs_pipeline(datapath, conn=None, startyear=1960, endyear=2025):
    startdate = f"{startyear}-01-01"
    enddate   = f"{endyear}-12-31"

    # --- Step 1: Pull Names and Exchanges ---

    print("Loading CRSP stock names...")
    # names = conn.raw_sql(f"""
    #                    select permno, namedt, nameenddt, primaryexch
    #                    from crsp.stocknames_v2
    #                    where sharetype = 'NS'
    #                    and securitytype = 'EQTY'
    #                    and securitysubtype = 'COM'
    #                    and usincflg = 'Y'
    #                    and issuertype in ('ACOR','CORP')
    #                    """, date_cols=['namedt', 'nameendt'])
    # names.to_parquet(datapath / "crsp/crsp_names.parquet", engine="pyarrow")
    names = pd.read_parquet(datapath / 'crsp/crsp_names.parquet')

    # --- Step 2: Pull Daily Data ---

    print("Loading CRSP daily stock data...")
    # dfs = []
    # for start in tqdm(range(1960, 2026, 10)):
    #     end = min(start + 9, 2025)
    
    #     df = conn.raw_sql(f"""
    #         SELECT permno, dlycaldt, yyyymmdd, dlyret, dlyretx, dlyvol, shrout, dlyprc, dlycap,
    #                dlyask, dlybid, dlyopen, dlyclose, dlynumtrd, dlycumfacpr, dlycumfacshr
    #         FROM crsp.dsf_v2
    #         WHERE dlycaldt BETWEEN '{start}-01-01' AND '{end}-12-31'
    #           AND sharetype = 'NS'
    #           AND securitytype = 'EQTY'
    #           AND securitysubtype = 'COM'
    #           AND usincflg = 'Y'
    #           AND issuertype IN ('ACOR','CORP')
    #     """, date_cols=['dlycaldt'])
    
    #     dfs.append(df)
    #     df.to_parquet(datapath / f"crsp/crsp_dsf_{start}_{end}.parquet", engine="pyarrow")
    #
    # # Append to a single DataFrame
    # dsf = pd.concat(dfs, ignore_index=True)
    # dsf.to_parquet(datapath / "crsp/crsp_dsf.parquet", engine="pyarrow")    
    dsf = pd.read_parquet(datapath / 'crsp/dsf.parquet')
    dsf = dsf[dsf['date'] >= startdate].reset_index(drop=True)

    # --- Step 3: Pull Market Index Returns ---

    print("Loading CRSP market index data...")
    # dsi = conn.raw_sql(f"""
    #                    select dlycaldt, dlytotret
    #                    from crsp.inddlyseriesdata
    #                    where dlycaldt between '{startdate}' and '{enddate}'
    #                    and indno = 1000200
    #                    """, date_cols=['dlycaldt'])
    # dsi.to_parquet(datapath / "crsp/crsp_dsi.parquet", engine="pyarrow")
    dsi = pd.read_parquet(datapath / 'crsp/crsp_dsi.parquet')

    # Market index trajectories
    mindex = dsi.sort_values(by='dlycaldt').copy()
    mindex['year'] = pd.to_datetime(mindex['dlycaldt']).dt.year
    mindex['logret'] = np.log(1.0 + mindex['dlytotret'].fillna(0))
    mindex['pm'] = mindex['logret'].cumsum()
    mindex = mindex[mindex['dlytotret'].notna()][['year', 'dlycaldt', 'dlytotret', 'pm']].reset_index(drop=True)
    mindex = mindex.rename(columns={'dlycaldt': 'date', 'dlytotret': 'ret'})

    # --- Step 4: Process Listing Exchange Variations ---
    
    print("Tracking listing exchange changes...")
    exch = names.sort_values(by=['permno', 'namedt']).copy()
    exchange_map = {'N': 1, 'A': 2, 'Q': 3, 'R': 4}
    exch['exchcd'] = exch['primaryexch'].str.upper().map(exchange_map).fillna(9).astype(int)
    
    exch_mask = (exch['exchcd'] != exch.groupby('permno')['exchcd'].shift(1))
    exch_events = exch[exch_mask].copy()
    exch_events['startDate'] = exch_events['namedt']
    exch_events['endDate'] = exch_events['nameenddt']
    exch_events['year'] = pd.to_datetime(exch_events['startDate']).dt.year
    exch = exch_events[['permno', 'year', 'startDate', 'endDate', 'exchcd']].reset_index(drop=True)

    # --- Step 5: Identify Corporate Splits ---
    
    print("Tracking structural stock splits...")
    splits = dsf.sort_values(by=['permno', 'date']).copy()
    splits['year'] = pd.to_datetime(splits['date']).dt.year
    splits['cfacpr0'] = splits.groupby('permno')['cfacpr'].shift(1)
    splits.loc[splits['permno'] != splits['permno'].shift(1), 'cfacpr0'] = np.nan
    splits['r'] = np.where((splits['cfacpr0'] != 0) & (splits['cfacpr0'].notna()), splits['cfacpr'] / splits['cfacpr0'], np.nan)
    splits = splits[(splits['r'] > 1.20) | (splits['r'] < 0.8)]
    splits = splits[['permno', 'year', 'date', 'cfacpr']].reset_index(drop=True)    

    # --- Step 6: Optimized Sub-Windows Segmenting ---
    
    print("Segmenting sub-windows...")
    dsf_base = dsf.copy()
    dsf_base['year'] = pd.to_datetime(dsf_base['date']).dt.year
    
    merge_keys = ['permno', 'year', 'date']
    dsf_base = dsf_base.set_index(merge_keys)
    exch_indexed = exch.rename(columns={'startDate': 'date'}).set_index(merge_keys)[['exchcd']]
    splits_indexed = splits.set_index(merge_keys)
    
    dsf0 = dsf_base.merge(exch_indexed, left_index=True, right_index=True, how='left')
    dsf0['in2'] = dsf0['exchcd'].notna()
    dsf0['in3'] = dsf0.index.isin(splits_indexed.index)
    dsf0 = dsf0.reset_index()
    
    del dsf_base, exch_indexed, splits_indexed
    gc.collect()
    
    dsf0 = dsf0.sort_values(by=['permno', 'year', 'date']).reset_index(drop=True)
    dsf0['first_year_flag'] = (dsf0['year'] != dsf0['year'].shift(1)).fillna(True)
    dsf0['first_permno_flag'] = (dsf0['permno'] != dsf0['permno'].shift(1)).fillna(True)
    
    exch_filled = dsf0.groupby('permno')['exchcd'].ffill()
    dsf0['exchcd'] = exch_filled.where((~dsf0['first_permno_flag']), np.nan)
    
    dsf0['inc_k'] = (~dsf0['first_year_flag']) & (dsf0['in2'] | dsf0['in3'])
    dsf0['kSample'] = dsf0.groupby(['permno', 'year'])['inc_k'].cumsum() + 1
    
    # CRSP V2 Architecture Fix: Identify true trading days using positive volume constraints
    dsf0['TradeDay'] = (dsf0['vol'] > 0) & (dsf0['prc'] > 0)
    
    sample_group = dsf0.groupby(['permno', 'year', 'kSample'])['date']
    dsf0['firstDate'] = sample_group.transform('min')
    dsf0['lastDate'] = sample_group.transform('max')
    
    pm_lookup = mindex.set_index('date')['pm']
    dsf0['pm'] = dsf0['date'].map(pm_lookup)
    dsf1 = dsf0.dropna(subset=['pm']).sort_values(by=['permno', 'year', 'date']).reset_index(drop=True)
    
    del dsf0, sample_group
    gc.collect()

    # --- Step 7: Microstructure Sign Vectors (q) ---
    
    print("Compiling sign direction vectors (q)...")
    ret_raw = dsf1['ret'].to_numpy(dtype=float, na_value=0.0)
    prc_raw = dsf1['prc'].to_numpy(dtype=float, na_value=np.nan)
    vol_raw = dsf1['vol'].to_numpy(dtype=float, na_value=0.0)
    is_first_permno = dsf1['first_permno_flag'].to_numpy(dtype=bool, na_value=False)
    
    dsf1['prcLast'] = dsf1.groupby('permno')['prc'].shift(1)
    dsf1.loc[is_first_permno, 'prcLast'] = np.nan
    prc_last_raw = dsf1['prcLast'].to_numpy(dtype=float, na_value=np.nan)
    
    clean_ret = np.where(ret_raw <= -1.0, 0.0, ret_raw)
    dsf1['log_ret_clean'] = np.log(1.0 + clean_ret).astype(np.float32)
    dsf1['p'] = dsf1.groupby('permno')['log_ret_clean'].cumsum()
    
    # V2 Architecture: Direct price differences since prc fields are consistently positive 
    dsf1['dp'] = prc_raw - prc_last_raw
    dp_raw = dsf1['dp'].to_numpy(dtype=float, na_value=np.nan)
    
    # CRSP V2 Mapping: Direct quote-only protection via volume verification rules
    # If vol == 0, it's a quote-only day -> q = 0.0. Otherwise, use sign(dp)
    q_arr = np.zeros_like(prc_raw, dtype=np.float32)
    q_arr = np.where(vol_raw > 0.0, np.where(dp_raw < 0.0, -1.0, 1.0), 0.0)
    
    dsf1['q'] = q_arr
    dsf2 = dsf1.dropna(subset=['p', 'pm', 'q']).reset_index(drop=True)
               
    del dsf1, ret_raw, prc_raw, prc_last_raw, vol_raw, is_first_permno, clean_ret, dp_raw, q_arr
    gc.collect()

    # --- Step 8: Final Aggregation Map Block ---
    
    print("Assembling segment metadata tables...")
    pys = dsf2.groupby(['permno', 'year', 'kSample']).agg(
        nTradeDays=('TradeDay', 'sum'),
        nDays=('date', 'count')
    ).reset_index()
    
    eligible_samples = pys[pys['nTradeDays'] >= 60].copy()

    # --- Step 9: Gibbs Estimation ---
    
    print("Staging data groups for estimation...")
    dsf2_filtered = dsf2.merge(eligible_samples[['permno', 'year', 'kSample']], on=['permno', 'year', 'kSample'], how='inner')
    
    # 1. Cast the grouped panel directly to a list to lock down its length
    grouped_list = list(dsf2_filtered.groupby(['permno', 'year', 'kSample']))
    
    print(f"Beginning Parallel Gibbs loops for {len(grouped_list)} target samples...")
    num_cores = max(1, os.cpu_count() - 3)
    
    # 2. Use joblib native tracking with an explicit list
    with parallel_config(backend='loky', n_jobs=num_cores):
        gibbs_rows = Parallel(verbose=10)(
            delayed(estimate_single_segment)(name, group) 
            for name, group in grouped_list 
        )
    
    out_cols = ['permno', 'year', 'kSample', 'c', 'beta', 'varu', 'sdu']
    return pd.DataFrame(gibbs_rows, columns=out_cols)


# =============================================================================
# EXECUTION
# =============================================================================
if __name__ == "__main__":
    parser = argparse.ArgumentParser(description='Run Hasbrouck (2009) Gibbs Sampling (MCMC) Model Estimation.')
    parser.add_argument('--startyear', type=int, default=1960, help='Specify the sample start year (int).')
    parser.add_argument('--endyear', type=int, default=2025, help='Specify the sample end year (int).')
    args = parser.parse_args()

    total_start_time = time.time()
    datapath = Path('/work/rw196/data/')
    
    gibbs_out = run_crsp_gibbs_pipeline(
        datapath=datapath,
        conn=None, 
        startyear=args.startyear, 
        endyear=args.endyear
    )

    gibbs_out.to_parquet(datapath / "Hasbrouck_gibbs.parquet", engine="pyarrow")
    elapsed = time.time() - total_start_time
    print(f"\nTotal run time: {elapsed / 60:.2f} minutes.")

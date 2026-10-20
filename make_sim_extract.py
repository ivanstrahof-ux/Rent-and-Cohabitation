#!/usr/bin/env python3
"""
make_sim_extract.py

Writes sim_ipums_extract.dta, a simulated IPUMS USA ACS extract with known
metro rent sensitivities, for testing rent_gamma_instrument.do before running
it on the real extract. It also writes sim_truth.dta with the true gamma.

Layout (2012-2024, one file, Stata 118 format):
- 9 Census divisions, 2 states each, 12 metros per division.
- Each metro has two CPUMAs entirely inside it. Every 4th metro also has an
  "edge" CPUMA whose PUMAs are 70% in the metro and 30% outside (MET2013 = 0).
  Each division has one "split" CPUMA, 60% in one metro and 40% in the next,
  and two CPUMAs outside any metro.
- Real log rent of metro m in year t:
      a_m + gamma_m * R_r(t) + u_mt,   gamma_m ~ lognormal(0, 0.35)
  where R_r is a region-level rent cycle (4 Census regions).
- Household log rent = metro level + bedroom premium + noise (sd 0.30).
  Nominal rent = real x price level; CPI99 converts back to 1999 dollars.
- The 3-bedroom share of renters rises with the regional cycle, so a raw
  median would pick up composition shifts. The fixed-weight index should not.
- Also includes owners, renters paying no cash rent, group quarters records,
  studios and 4+ bedroom units, and non-householder person records, all of
  which the do-file must drop.

Expected output of rent_gamma_instrument.do with default settings (from a
Python replication of the same steps; Stata's weighted median can differ
slightly):
- 99 metros in the balanced panel. The 9 metros that lose 40% of a split
  CPUMA exceed the 15% mismatch cutoff; years 2012-2019 and 2021-2024.
- gamma_full correlates about 0.92 with gamma_target in sim_truth.dta
  (gamma_m / mean of gamma_j over the other metros in its region).
- First stages (coefficient, F): lnR on Z_lvl about 0.81 (F ~350);
  lnR on Z_lvl_full about 0.92 (F ~580); p on Z_chg about 0.54 (F ~60);
  p on Z_chg_full about 0.87 (F ~1,650). Coefficients below 1 for the
  leave-out versions reflect noise in gamma_lo; the much larger F for the
  full-sample versions reflects overfitting, not a better instrument.

Usage: python make_sim_extract.py [output_dir]
"""

from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
import pandas as pd

YEARS = np.arange(2012, 2025)
DIV_STATES = {1: (25, 9), 2: (36, 42), 3: (17, 39), 4: (27, 29), 5: (12, 37),
              6: (47, 1), 7: (48, 40), 8: (4, 8), 9: (6, 53)}
DIV_REGION = {1: 1, 2: 1, 3: 2, 4: 2, 5: 3, 6: 3, 7: 3, 8: 4, 9: 4}
BR_PREMIUM = {0: -0.20, 1: 0.0, 2: 0.25, 3: 0.45, 4: 0.60}
RENTERS_PER_CPUMA = 220


def simulate(seed: int = 7) -> tuple[pd.DataFrame, pd.DataFrame]:
    rng = np.random.default_rng(seed)
    T = len(YEARS)
    tt = np.arange(T)

    # Regional real rent cycles and the national price level
    R = {}
    for r in range(1, 5):
        phase = rng.uniform(0, 2 * np.pi)
        R[r] = 0.015 * tt + 0.12 * np.sin(2 * np.pi * tt / rng.uniform(7, 10) + phase)
    infl = np.full(T, 0.025)
    infl[YEARS == 2021] = 0.05
    infl[YEARS == 2022] = 0.07
    price = 1.36 * np.exp(np.cumsum(infl) - infl[0])   # 1999 = 1

    # Metros
    metros = []
    code = 10000
    for div, states in DIV_STATES.items():
        for k in range(12):
            metros.append({"metro": code, "division": div, "region": DIV_REGION[div],
                           "statefip": states[k % 2],
                           "gamma": float(np.exp(rng.normal(0, 0.35))),
                           "a": rng.normal(6.4, 0.25)})
            code += 10
    mdf = pd.DataFrame(metros)
    mlevel = {}
    for m in metros:
        u = np.zeros(T)
        for s in range(1, T):
            u[s] = 0.5 * u[s - 1] + rng.normal(0, 0.01)
        mlevel[m["metro"]] = m["a"] + m["gamma"] * R[m["region"]] + u

    # CPUMAs: list of (cpuma, statefip, [(met2013, share, level_series)], region)
    cpumas = []
    cid = 1
    for div, states in DIV_STATES.items():
        dm = mdf[mdf["division"] == div].reset_index(drop=True)
        nonmetro_level = 6.0 + 0.3 * R[DIV_REGION[div]]
        for i, m in dm.iterrows():
            for _ in range(2):
                cpumas.append((cid, m["statefip"], [(m["metro"], 1.0, mlevel[m["metro"]])], m["region"]))
                cid += 1
            if i % 4 == 0:   # edge CPUMA: 70% in metro, 30% outside
                cpumas.append((cid, m["statefip"], [(m["metro"], 0.7, mlevel[m["metro"]]),
                                                    (0, 0.3, nonmetro_level)], m["region"]))
                cid += 1
        a, b = dm.loc[2], dm.loc[3]   # split CPUMA: 60% metro a, 40% metro b
        cpumas.append((cid, a["statefip"], [(a["metro"], 0.6, mlevel[a["metro"]]),
                                            (b["metro"], 0.4, mlevel[b["metro"]])], a["region"]))
        cid += 1
        for j in range(2):            # outside any metro
            cpumas.append((cid, states[j], [(0, 1.0, nonmetro_level)], DIV_REGION[div]))
            cid += 1

    rows = []
    for yi, year in enumerate(YEARS):
        serial = 0
        cpi99 = 1.0 / price[yi]
        for cp, st, parts, region in cpumas:
            for met, share, level in parts:
                n_rent = int(round(RENTERS_PER_CPUMA * share))
                # bedroom mix shifts toward 3BR when the regional cycle is high
                tilt = float(np.clip(0.4 * (R[region][yi] - R[region].mean()), -0.08, 0.08))
                probs = np.array([0.08, 0.32 - tilt / 2, 0.35 - tilt / 2, 0.18 + tilt, 0.07])
                br = rng.choice(5, size=n_rent, p=probs / probs.sum())
                lnr = level[yi] + np.vectorize(BR_PREMIUM.get)(br) + rng.normal(0, 0.30, n_rent)
                rent_nom = np.maximum(np.round(np.exp(lnr) * price[yi]), 1).astype(int)
                for k in range(n_rent):
                    serial += 1
                    rows.append((year, serial, 1, rng.integers(40, 161), 1, st, met, cp, 1, 2,
                                 rent_nom[k], br[k] + 1,
                                 1 if rng.random() < 0.3 else rng.integers(2, 8), cpi99))
                    if rng.random() < 0.15:   # a second person in the household
                        rows.append((year, serial, 2, rows[-1][3], 1, st, met, cp, 2, 2,
                                     rent_nom[k], br[k] + 1, 0, cpi99))
                n_other = int(round(70 * share))
                for k in range(n_other):
                    serial += 1
                    kind = rng.random()
                    if kind < 0.85:     # owner
                        rows.append((year, serial, 1, rng.integers(40, 161), 1, st, met, cp, 1, 1,
                                     0, rng.integers(2, 6), rng.integers(1, 8), cpi99))
                    elif kind < 0.93:   # renter, no cash rent
                        rows.append((year, serial, 1, rng.integers(40, 161), 1, st, met, cp, 1, 2,
                                     0, rng.integers(2, 5), rng.integers(1, 8), cpi99))
                    else:               # group quarters person
                        rows.append((year, serial, 1, rng.integers(40, 161), 3, st, met, cp, 13, 0,
                                     0, 0, 0, cpi99))

    cols = ["year", "serial", "pernum", "hhwt", "gq", "statefip", "met2013", "cpuma1020",
            "relate", "ownershp", "rentgrs", "bedrooms", "movedin", "cpi99"]
    df = pd.DataFrame(rows, columns=cols)
    types = {"year": "int16", "serial": "int32", "pernum": "int16", "hhwt": "float64",
             "gq": "int8", "statefip": "int8", "met2013": "int32", "cpuma1020": "int16",
             "relate": "int8", "ownershp": "int8", "rentgrs": "int32", "bedrooms": "int8",
             "movedin": "int8", "cpi99": "float64"}
    df = df.astype(types)

    # Target: gamma relative to the leave-out mean of gamma in the region
    mdf["loo_mean"] = mdf.groupby("region")["gamma"].transform(
        lambda s: (s.sum() - s) / (len(s) - 1))
    mdf["gamma_target"] = mdf["gamma"] / mdf["loo_mean"]
    truth = mdf[["metro", "division", "region", "gamma", "gamma_target"]]
    return df, truth


if __name__ == "__main__":
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(".")
    out.mkdir(parents=True, exist_ok=True)
    df, truth = simulate()
    df.to_stata(out / "sim_ipums_extract.dta", write_index=False, version=118)
    truth.to_stata(out / "sim_truth.dta", write_index=False, version=118)
    print(f"Wrote {len(df):,} records to {out / 'sim_ipums_extract.dta'}")
    print(f"Wrote {len(truth)} metros to {out / 'sim_truth.dta'}")

# Railway environment variables — trading bots

Both bots read config from the process environment on Railway (and fall back to the
`.env` file locally). The full watchlists are **also baked into the bot code as
defaults**, so Railway will work even if you never set the env vars — but setting
them lets you change the watchlist without a redeploy.

The Railway CLI isn't installed on this machine, so set these via the Railway dashboard:
**Project → Service → Variables → New Variable**.

---

## Service 1 — ORB+VWAP bot (`orb_bot.pl`, paper account PA3HBWTHSTE1)

Dockerfile: `Dockerfile` • railway.json cron: `*/5 13-20 * * 1-5` (UTC → 9 AM–4 PM ET in EDT)

| Variable | Value |
|---|---|
| `ALPACA_API_KEY_2` | `PKF72FILYV3RDKV4PZYBZ35JAW` |
| `ALPACA_SECRET_KEY_2` | `FR88H4zEz7UcaafB4iwvb5GtwaDjXANnfMXg5TWVRGQT` |
| `ORB_WATCHLIST` | `AAPL,MSFT,GOOGL,META,AMZN,NVDA,TSLA,AVGO,ORCL,AMD,CRM,ADBE,QCOM,TXN,INTC,MU,AMAT,KLAC,LRCX,MRVL,NFLX,TMUS,UBER,SHOP,PYPL,PLTR,SNOW,CRWD,PANW,NOW,JPM,BAC,WFC,GS,MS,C,BLK,AXP,V,MA,SCHW,COF,USB,MET,PNC,XOM,CVX,COP,OXY,SLB,HAL,EOG,MPC,PSX,VLO,FCX,NEM,GOLD,X,CLF,NUE,ALB,CAT,DE,BA,GE,HON,LMT,RTX,UPS,WMT,COST,TGT,HD,LOW,NKE,SBUX,MCD,CMG,DIS,DAL,UAL,AAL,LUV,CCL,UNH,PFE,MRK,LLY,ABBV,BMY,JNJ,CVS,TMO,ISRG,COIN,HOOD,RBLX,SMCI,ANET` |
| `ORB_BUDGET_USD` | `50000` |
| `ORB_MAX_TRADE_USD` | `1000` |
| `ORB_MAX_POSITIONS` | `10` |
| `ORB_MINUTES` | `30` |
| `ORB_VOL_MULT` | `1.1` |
| `ORB_RR_RATIO` | `1.5` |
| `ORB_CUTOFF_HOUR` | `14` |
| `ORB_GAP_THRESH` | `0.75` |
| `MR_EXT_PCT` | `1.5` |
| `MR_VOL_DRY` | `0.70` |
| `MR_CUTOFF_HOUR` | `14` |

## Service 2 — Qullamaggie bot (`qullamaggie_bot.pl`, paper account 3)

Dockerfile: `Dockerfile.qull` • cron: add `35 13 * * 1-5` (UTC → 9:35 AM ET in EDT)
for the midmorning scan, or schedule locally via Claude Code.

| Variable | Value |
|---|---|
| `ALPACA_API_KEY_3` | `PKLC2ETO4FHVG7M2WM2Y23MOE2` |
| `ALPACA_SECRET_KEY_3` | `Gkp5sGUJtDDCx9rPus7gDYBKbTEWRA5p7cRdthCVY35y` |
| `QULL_WATCHLIST` | `NVDA,AMD,AVGO,MRVL,MU,AMAT,LRCX,KLAC,ASML,TSM,ARM,SMCI,DELL,ANET,CRDO,CRCL,ALMU,AAOI,FN,LITE,META,AAPL,MSFT,GOOGL,AMZN,NFLX,ORCL,CRM,ADBE,NOW,PLTR,SNOW,DDOG,NET,CRWD,ZS,PANW,FTNT,OKTA,MDB,HUBS,MNDY,WDAY,INTU,VEEV,SHOP,SQ,PYPL,COIN,HOOD,SOFI,AFRM,NU,SPGI,MSCI,UBER,DASH,ABNB,BKNG,EXPE,RBLX,DUOL,APP,TTD,RDDT,IONQ,RGTI,QBTS,BBAI,SOUN,AI,IREN,MARA,RIOT,TMDX,DXCM,ISRG,EXAS,NTRA,REGN,VRTX,BIIB,MRNA,AXSM,CELH,TSLA,RIVN,LCID,CVNA,GLXY,BIRD,HIMS,NBIS,AXTI,ASTS,RKLB,HROW,HPS,FORM,LWLG` |
| `QULL_BUDGET_USD` | `100000` |
| `QULL_MAX_POS_USD` | `10000` |
| `QULL_RISK_PCT` | `0.02` |

To revert the Qullamaggie bot to full-universe scanning, set `QULL_WATCHLIST=ALL`.

---

## Local runs

All of the above also live in `.env`. The bots prefer process env over `.env` file,
so Railway-injected values win over local defaults.

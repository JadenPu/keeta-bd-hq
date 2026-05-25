#!/bin/bash
# Keeta BD HQ — Daily Data Update Script
# Runs at 09:00 CST, pulls T-1 data and pushes to GitHub

set -e

export PATH="$HOME/bin:$PATH"
export PYTHONPATH="$HOME/.openclaw/skills/keeta-data-query-for-front-line/scripts:$HOME/.openclaw/skills/keeta-data-query-for-front-line/scripts/core:$HOME/.openclaw/skills/keeta-data-query-for-front-line/scripts/capability1_standard"

REPO="$HOME/.openclaw/workspace/keeta-bd-hq"
LOG="$REPO/update.log"
YESTERDAY=$(date -d "yesterday" +%Y%m%d)
TREND_START=$(date -d "7 days ago" +%Y%m%d)
MONTH_START="20260501"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] === Daily update starting ===" >> "$LOG"

# 1. Pull 7-day trend
TASK_ID=$(python3 -c "import uuid; print(uuid.uuid4())")
kdata --task-id "$TASK_ID" --task-name "trend" standard query \
  --dataset 60041382 \
  --measures open_shop_num txn_shop_num fin_ord_num discount_product_shop_ratio fulldiscount_open_shop_coverage \
  --date "${TREND_START}~${YESTERDAY}" \
  --region BR --biz-type 1148702721 \
  --filter org_4_mis_ids=4259_zhouhaibin_championzhang_pujunjie \
  --group-by dt --order-by dt=ASC --page-size 10 2>> "$LOG" > /tmp/keeta_trend.csv

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Trend pulled" >> "$LOG"

# 2. Pull MTD cumulative
TASK_ID2=$(python3 -c "import uuid; print(uuid.uuid4())")
kdata --task-id "$TASK_ID2" --task-name "mtd" standard query \
  --dataset 60041382 \
  --measures open_shop_num txn_shop_num fin_ord_num new_shop_num acc_new_shop_num discount_product_shop_ratio fulldiscount_open_shop_coverage \
  --date "${MONTH_START}~${YESTERDAY}" \
  --region BR --biz-type 1148702721 \
  --filter org_4_mis_ids=4259_zhouhaibin_championzhang_pujunjie \
  --page-size 1 2>> "$LOG" > /tmp/keeta_mtd.csv

echo "[$(date '+%Y-%m-%d %H:%M:%S')] MTD pulled" >> "$LOG"

# 3. Parse CSVs and update data.json
python3 - << 'PYEOF'
import json, csv, os, sys
from datetime import datetime, timedelta

yesterday = (datetime.now() - timedelta(days=1)).strftime('%Y-%m-%d')
repo = os.path.expanduser('~/.openclaw/workspace/keeta-bd-hq')

with open(f'{repo}/data.json') as f:
    data = json.load(f)

# --- Parse trend CSV ---
try:
    trend = []
    with open('/tmp/keeta_trend.csv') as f:
        content = f.read().strip()
    # Find header line (starts with 'dt')
    lines = [l for l in content.split('\n') if l.strip()]
    header_idx = next((i for i,l in enumerate(lines) if l.strip().startswith('dt')), None)
    if header_idx is not None:
        reader = csv.DictReader(lines[header_idx:], delimiter='\t' if '\t' in lines[header_idx] else ',')
        for row in reader:
            dt = str(row.get('dt','') or '').strip()
            if len(dt) == 8:
                disc = float(row.get('discount_product_shop_ratio','0') or 0)
                full = float(row.get('fulldiscount_open_shop_coverage','0') or 0)
                # API returns ratio (0-1) or percentage, detect
                if disc <= 1: disc = round(disc*100, 2)
                if full <= 1: full = round(full*100, 2)
                trend.append({
                    "date": f"{dt[4:6]}/{dt[6:8]}",
                    "openShops": int(float(row.get('open_shop_num',0) or 0)),
                    "txnShops": int(float(row.get('txn_shop_num',0) or 0)),
                    "orders": int(float(row.get('fin_ord_num',0) or 0)),
                    "discountCoverage": disc,
                    "fullDiscCoverage": full
                })
    if trend:
        data['trend'] = trend[-7:]
        print(f'[OK] Trend: {len(data["trend"])} days')
    else:
        print('[WARN] Trend: no rows parsed')
except Exception as e:
    print(f'[WARN] Trend parse error: {e}')

# --- Parse MTD CSV ---
try:
    with open('/tmp/keeta_mtd.csv') as f:
        content = f.read().strip()
    lines = [l for l in content.split('\n') if l.strip()]
    header_idx = next((i for i,l in enumerate(lines) if 'open_shop' in l or 'fin_ord' in l), None)
    if header_idx is not None:
        sep = '\t' if '\t' in lines[header_idx] else None
        rows = list(csv.DictReader(lines[header_idx:], delimiter=sep or ',') if sep else csv.DictReader(lines[header_idx:]))
        if rows:
            r = rows[-1]
            disc = float(r.get('discount_product_shop_ratio','0') or 0)
            full = float(r.get('fulldiscount_open_shop_coverage','0') or 0)
            if disc <= 1: disc = round(disc*100,2)
            if full <= 1: full = round(full*100,2)
            data['overview'].update({
                'date': yesterday,
                'openShops': int(float(r.get('open_shop_num',0) or 0)),
                'txnShops': int(float(r.get('txn_shop_num',0) or 0)),
                'orders': int(float(r.get('fin_ord_num',0) or 0)),
                'newSigns': int(float(r.get('new_shop_num',0) or 0)),
                'discountProductCoverage': f'{disc:.2f}%',
                'fullDiscountCoverage': f'{full:.2f}%'
            })
            data['hud'].update({
                'discountCoverage': f'{disc:.2f}%',
                'fullDiscountCoverage': f'{full:.2f}%',
                'accNewShops': int(float(r.get('acc_new_shop_num',0) or 0))
            })
            print(f'[OK] MTD overview updated for {yesterday}')
except Exception as e:
    print(f'[WARN] MTD parse error: {e}')

# --- Update timestamps & log ---
data['updated'] = datetime.now().strftime('%Y-%m-%dT%H:%M:%S+08:00')
data['dataDate'] = yesterday
data['log'].insert(0, {
    "time": datetime.now().strftime('%H:%M'),
    "agent": "System",
    "type": "ok",
    "msg": f"Auto-update completed — data as of {yesterday}"
})
data['log'] = data['log'][:5]

with open(f'{repo}/data.json', 'w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
print('[OK] data.json saved')
PYEOF

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Parsed and saved. Pushing to GitHub..." >> "$LOG"

# 4. Git push
cd "$REPO"
git add data.json
git diff --cached --quiet || git commit -m "auto: daily update $(date +%Y-%m-%d)"
git push origin main >> "$LOG" 2>&1

echo "[$(date '+%Y-%m-%d %H:%M:%S')] === Done ===" >> "$LOG"

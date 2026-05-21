#!/bin/bash
# Keeta BD HQ — Daily Merchant List Update
# Downloads Central Western - B Mid Zone - Merchant list from Dashboard 300004252
# Parses CSV and updates bds[] in data.json, then git pushes to GitHub

set -e

REPO="$HOME/.openclaw/workspace/keeta-bd-hq"
LOG="$REPO/update.log"
CSV_PATH="/tmp/merchant_list_$(date +%Y%m%d).csv"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] === Merchant list update starting ===" >> "$LOG"

# Step 1: Use Python to drive the browser JS API and download CSV
python3 - << 'PYEOF'
import subprocess, json, time, sys, os

def browser_eval(js):
    """Call OpenClaw browser evaluate via agent-browser CLI"""
    import shlex
    cmd = f'agent-browser eval {shlex.quote(js)}'
    result = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=60)
    return result.stdout.strip()

# Navigate to dashboard controller page
print("[INFO] Opening dashboard controller...", flush=True)
subprocess.run(
    'agent-browser open "https://bi.keetapp.com/v2/dashboard/dashboard-controller?dashboardId=300004252"',
    shell=True, check=True, timeout=30
)

# Wait for DashboardController
print("[INFO] Waiting for DashboardController...", flush=True)
for i in range(15):
    time.sleep(2)
    result = browser_eval("typeof window.DashboardController !== 'undefined' ? 'ready' : 'not_ready'")
    if 'ready' in result and 'not_ready' not in result:
        print("[OK] DashboardController ready", flush=True)
        break
    if i == 14:
        print("[ERROR] DashboardController not found after 30s", flush=True)
        sys.exit(1)

# Trigger query
COMPONENT_ID = "dashboard-chart-container-9vp4i-05019"
print(f"[INFO] Triggering query for {COMPONENT_ID}...", flush=True)
browser_eval(f"""
(function(){{
  window._queryDone = false;
  window.DashboardController.executeQueryAndGetCHNResult('{COMPONENT_ID}')
    .then(function(){{ window._queryDone = true; }})
    .catch(function(e){{ window._queryError = e.message; window._queryDone = true; }});
  return 'triggered';
}})()
""")

# Wait for query to finish
for i in range(30):
    time.sleep(2)
    result = browser_eval("JSON.stringify({done: window._queryDone, error: window._queryError})")
    try:
        state = json.loads(result)
        if state.get('done'):
            if state.get('error'):
                print(f"[ERROR] Query error: {state['error']}", flush=True)
                sys.exit(1)
            print("[OK] Query complete", flush=True)
            break
    except:
        pass
    if i == 29:
        print("[ERROR] Query timed out after 60s", flush=True)
        sys.exit(1)

# Get download link (with retry)
print("[INFO] Getting download link...", flush=True)
wait_intervals = [15, 30, 60, 120]
wenshu_url = None

for attempt in range(8):
    browser_eval(f"""
(function(){{
  window._downloadResult = null;
  window.DashboardController.executeDownload('{COMPONENT_ID}', {{fileType: 'CSV'}})
    .then(function(res){{ window._downloadResult = JSON.stringify(res); }})
    .catch(function(e){{ window._downloadResult = JSON.stringify({{error: e.message}}); }});
  return 'triggered';
}})()
""")
    wait = 20
    time.sleep(wait)
    result = browser_eval("window._downloadResult")
    if not result or result == 'null':
        wait_idx = min(attempt, len(wait_intervals)-1)
        print(f"[WAIT] Not ready, retrying in {wait_intervals[wait_idx]}s...", flush=True)
        time.sleep(wait_intervals[wait_idx])
        continue
    try:
        data = json.loads(result)
        if data.get('code') == 0 and data.get('data', {}).get('fileUrl'):
            wenshu_url = data['data']['fileUrl']
            print(f"[OK] Got wenshu URL", flush=True)
            break
        elif data.get('error'):
            print(f"[WARN] Download error: {data['error']}, retrying...", flush=True)
    except:
        pass
    wait_idx = min(attempt, len(wait_intervals)-1)
    time.sleep(wait_intervals[wait_idx])

if not wenshu_url:
    print("[ERROR] Failed to get download link after retries", flush=True)
    sys.exit(1)

# Download CSV
import urllib.request
csv_path = f"/tmp/merchant_list_{__import__('datetime').date.today().strftime('%Y%m%d')}.csv"
print(f"[INFO] Downloading CSV to {csv_path}...", flush=True)
urllib.request.urlretrieve(wenshu_url, csv_path)
print(f"[OK] CSV downloaded", flush=True)
PYEOF

echo "[$(date '+%Y-%m-%d %H:%M:%S')] CSV downloaded, parsing..." >> "$LOG"

# Step 2: Parse CSV and update data.json
python3 - << 'PYEOF'
import json, csv, os, sys
from datetime import datetime, timedelta

yesterday = (datetime.now() - timedelta(days=1)).strftime('%Y-%m-%d')
repo = os.path.expanduser('~/.openclaw/workspace/keeta-bd-hq')
csv_path = f"/tmp/merchant_list_{datetime.now().strftime('%Y%m%d')}.csv"

if not os.path.exists(csv_path):
    print(f"[ERROR] CSV not found: {csv_path}")
    sys.exit(1)

with open(f'{repo}/data.json') as f:
    data = json.load(f)

# Read CSV - detect separator
with open(csv_path, encoding='utf-8-sig') as f:
    sample = f.read(2048)

sep = '\t' if sample.count('\t') > sample.count(',') else ','

with open(csv_path, encoding='utf-8-sig') as f:
    lines = [l for l in f.read().strip().split('\n') if l.strip()]

# Find header row
header_idx = None
for i, line in enumerate(lines):
    low = line.lower()
    if any(k in low for k in ['bd_name', 'salesperson', 'open_shop', 'merchant', 'bd name', 'owner']):
        header_idx = i
        break

if header_idx is None:
    print(f"[WARN] Could not find header row. First 3 lines:")
    for l in lines[:3]: print(f"  {repr(l)}")
    # Print all headers for debugging
    print(f"[DEBUG] All columns in row 0: {lines[0]}")
    sys.exit(0)

reader = list(csv.DictReader(lines[header_idx:], delimiter=sep))
print(f"[OK] Parsed {len(reader)} rows. Columns: {list(reader[0].keys()) if reader else 'none'}")

# Map column names flexibly
def get_col(row, *candidates):
    for c in candidates:
        for k in row.keys():
            if c.lower() in k.lower():
                return row[k]
    return None

bds_updated = []
for row in reader:
    name = get_col(row, 'bd_name', 'salesperson', 'bd name', 'owner', 'name')
    if not name or not str(name).strip():
        continue
    name = str(name).strip()

    open_shops   = int(float(get_col(row, 'open_shop_num', 'open_shop', 'active_shop') or 0))
    txn_shops    = int(float(get_col(row, 'txn_shop_num', 'txn_shop', 'trading_shop') or 0))
    orders       = int(float(get_col(row, 'fin_ord_num', 'order_num', 'orders', 'fin_ord') or 0))
    new_signs    = int(float(get_col(row, 'new_shop_num', 'new_sign', 'new_merchant') or 0))

    # Try to match existing BD record by name (fuzzy)
    existing = next((b for b in data.get('bds', [])
                     if name.lower() in b['name'].lower() or b['name'].lower() in name.lower()), None)

    if existing:
        existing.update({
            'shops': open_shops,
            'txnShops': txn_shops,
            'orders': orders,
            'newSigns': new_signs,
        })
        bds_updated.append(name)
    else:
        print(f"[INFO] New BD not in existing list: {name} (shops={open_shops})")

print(f"[OK] Updated BDs: {bds_updated}")

# Update timestamps
data['updated'] = datetime.now().strftime('%Y-%m-%dT%H:%M:%S-03:00')
data['dataDate'] = yesterday
data['log'].insert(0, {
    "time": datetime.now().strftime('%H:%M'),
    "agent": "System",
    "type": "ok",
    "msg": f"Merchant list updated — B Mid Zone data as of {yesterday}"
})
data['log'] = data['log'][:5]

with open(f'{repo}/data.json', 'w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
print('[OK] data.json saved')
PYEOF

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Parsed. Pushing to GitHub..." >> "$LOG"

# Step 3: Git push
cd "$REPO"
git add data.json
git diff --cached --quiet || git commit -m "auto: merchant list update $(date +%Y-%m-%d)"
git push origin main >> "$LOG" 2>&1

echo "[$(date '+%Y-%m-%d %H:%M:%S')] === Merchant list update done ===" >> "$LOG"
echo "done"

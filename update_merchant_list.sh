#!/bin/bash
# Keeta BD HQ — Daily Merchant List Update
# Downloads Central Western - B Mid Zone - Merchant list from Dashboard 300004252
# Parses CSV and updates bds[] + scores in data.json, then git pushes to GitHub

set -e

REPO="$HOME/.openclaw/workspace/keeta-bd-hq"
LOG="$REPO/update.log"
WENSHU_SKILL="$HOME/.openclaw/skills/wenshu-tools"
CSV_PATH="/tmp/merchant_list_$(date +%Y%m%d).csv"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] === Merchant list update starting ===" >> "$LOG"

# Step 1: Drive browser JS API to get download link
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Getting download link from Dashboard..." >> "$LOG"

WENSHU_URL=$(python3 - << 'PYEOF'
import subprocess, json, time, sys, shlex

def browser_eval(js):
    cmd = f'agent-browser eval {shlex.quote(js)}'
    result = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=60)
    return result.stdout.strip()

# Navigate to dashboard controller page
subprocess.run(
    'agent-browser open "https://bi.keetapp.com/v2/dashboard/dashboard-controller?dashboardId=300004252"',
    shell=True, check=True, timeout=30
)

# Wait for DashboardController
for i in range(15):
    time.sleep(2)
    result = browser_eval("typeof window.DashboardController !== 'undefined' ? 'ready' : 'not_ready'")
    if 'ready' in result and 'not_ready' not in result:
        break
    if i == 14:
        print("ERROR: DashboardController not found", file=sys.stderr)
        sys.exit(1)

# Trigger query
COMPONENT_ID = "dashboard-chart-container-9vp4i-05019"
browser_eval(f"""
(function(){{
  window._queryDone = false;
  window.DashboardController.executeQueryAndGetCHNResult('{COMPONENT_ID}')
    .then(function(){{ window._queryDone = true; }})
    .catch(function(e){{ window._queryError = e.message; window._queryDone = true; }});
  return 'triggered';
}})()
""")

# Wait for query
for i in range(30):
    time.sleep(2)
    result = browser_eval("JSON.stringify({done: window._queryDone, error: window._queryError})")
    try:
        state = json.loads(result)
        if state.get('done'):
            if state.get('error'):
                print(f"ERROR: Query error: {state['error']}", file=sys.stderr)
                sys.exit(1)
            break
    except: pass
    if i == 29:
        print("ERROR: Query timed out", file=sys.stderr)
        sys.exit(1)

# Get download link with retry
wait_intervals = [15, 30, 60, 120]
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
    time.sleep(20)
    result = browser_eval("window._downloadResult")
    if not result or result == 'null':
        wi = min(attempt, len(wait_intervals)-1)
        time.sleep(wait_intervals[wi])
        continue
    try:
        data = json.loads(result)
        if data.get('code') == 0 and data.get('data', {}).get('fileUrl'):
            print(data['data']['fileUrl'])
            sys.exit(0)
    except: pass
    wi = min(attempt, len(wait_intervals)-1)
    time.sleep(wait_intervals[wi])

print("ERROR: Failed to get download link", file=sys.stderr)
sys.exit(1)
PYEOF
)

if [ -z "$WENSHU_URL" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: No download URL obtained" >> "$LOG"
    exit 1
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Got wenshu URL, downloading via wenshu-tools..." >> "$LOG"

# Step 2: Download via wenshu-tools
TASK_ID=$(node ${WENSHU_SKILL}/scripts/download.js --url "$WENSHU_URL" --timeout 30 2>>"$LOG" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('taskId',''))")

if [ -z "$TASK_ID" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Download task submission failed" >> "$LOG"
    exit 1
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Download task submitted: $TASK_ID, waiting..." >> "$LOG"

# Wait for download to complete
for i in $(seq 1 12); do
    sleep 5
    RESULT=$(node ${WENSHU_SKILL}/scripts/query_downloads.js --minutes 5 --json 2>/dev/null)
    DOWNLOADED=$(echo "$RESULT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for item in d.get('completed', []):
    if item.get('id') == '${TASK_ID}' or item.get('status') == 'completed':
        print(item.get('path', ''))
        break
" 2>/dev/null)
    if [ -n "$DOWNLOADED" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Downloaded to: $DOWNLOADED" >> "$LOG"
        cp "$DOWNLOADED" "$CSV_PATH"
        break
    fi
    if [ "$i" -eq 12 ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Download timed out after 60s" >> "$LOG"
        exit 1
    fi
done

echo "[$(date '+%Y-%m-%d %H:%M:%S')] CSV ready, parsing..." >> "$LOG"

# Step 3: Parse CSV and update data.json
python3 - << 'PYEOF'
import json, csv, os, sys
from datetime import datetime, timedelta
from collections import defaultdict

yesterday = (datetime.now() - timedelta(days=1)).strftime('%Y-%m-%d')
repo = os.path.expanduser('~/.openclaw/workspace/keeta-bd-hq')
csv_path = f"/tmp/merchant_list_{datetime.now().strftime('%Y%m%d')}.csv"

if not os.path.exists(csv_path):
    print(f"[ERROR] CSV not found: {csv_path}")
    sys.exit(1)

with open(csv_path, encoding='utf-8-sig') as f:
    content = f.read().strip()

lines = [l for l in content.split('\n') if l.strip()]
sep = '\t' if content.count('\t') > content.count(',') else ','
rows = list(csv.DictReader(lines, delimiter=sep))

if not rows:
    print("[ERROR] CSV is empty or could not be parsed")
    sys.exit(1)

print(f"[OK] Parsed {len(rows)} rows. Columns: {list(rows[0].keys())}")

# Aggregate by BD name
bd_data = defaultdict(lambda: {
    'shops': 0, 'txnShops': 0, 'orders': 0, 'newSigns': 0,
    'cooperating': 0, 'earned': 0, 'newsignPts': 0, 'recallPts': 0,
    'base_points': 0, 'list_total_score': 0,
    'open15h_count': 0, 'total_merchants': 0
})

for row in rows:
    bd = str(row.get('bd', '') or '').strip()
    if not bd:
        continue

    d = bd_data[bd]
    d['total_merchants'] += 1

    # Merchant status
    status = str(row.get('merchant_competition_status', '') or '').strip().lower()
    if row.get('is_cooperating_may', '0') in ('1', 'true', 'True', 'yes'):
        d['cooperating'] += 1
    if row.get('has_completed_order_may', '0') in ('1', 'true', 'True', 'yes'):
        d['txnShops'] += 1

    # Orders
    try:
        d['orders'] += int(float(row.get('total_completed_orders_may', 0) or 0))
    except: pass

    # 15h flag
    if row.get('open_15h_last7days_flag', '0') in ('1', 'true', 'True', 'yes'):
        d['open15h_count'] += 1

    # New sign: first_bind_contract_time present = new sign
    if str(row.get('first_bind_contract_time', '') or '').strip():
        d['newSigns'] += 1

    # Points (accumulate per merchant, sum to BD)
    try:
        d['earned'] += int(float(row.get('total_points_earned', 0) or 0))
    except: pass
    try:
        d['newsignPts'] += int(float(row.get('newsign_points_earned', 0) or 0))
    except: pass
    try:
        d['recallPts'] += int(float(row.get('recall_points_earned', 0) or 0))
    except: pass
    try:
        d['base_points'] += int(float(row.get('base_points', 0) or 0))
    except: pass
    try:
        d['list_total_score'] += int(float(row.get('list_total_score', 0) or 0))
    except: pass

    d['shops'] += 1  # each row = one merchant

print(f"[OK] Aggregated data for BDs: {list(bd_data.keys())}")

# Load data.json
with open(f'{repo}/data.json') as f:
    data = json.load(f)

# Update bds[]
bds_updated = []
for bd_name, bd_vals in bd_data.items():
    # Fuzzy match to existing BD record
    existing = next(
        (b for b in data.get('bds', [])
         if bd_name.lower() in b['name'].lower() or b['name'].lower() in bd_name.lower()),
        None
    )
    if existing:
        existing.update({
            'shops':       bd_vals['shops'],
            'txnShops':    bd_vals['txnShops'],
            'orders':      bd_vals['orders'],
            'newSigns':    bd_vals['newSigns'],
            'cooperating': bd_vals['cooperating'],
            'earned':      bd_vals['earned'],
            'newsignPts':  bd_vals['newsignPts'],
            'recallPts':   bd_vals['recallPts'],
        })
        # Status logic: earned >= 15 = on-track, >= 7 = at-risk, else critical
        pts = bd_vals['earned']
        existing['status'] = 'on-track' if pts >= 15 else ('at-risk' if pts >= 7 else 'critical')
        bds_updated.append(bd_name)
    else:
        print(f"[INFO] BD not matched in existing list: {bd_name}")

# Update HUD totals
total_pts = sum(b.get('earned', 0) for b in data.get('bds', []))
bd_count = len([b for b in data.get('bds', []) if b.get('earned', 0) > 0])
data['hud']['totalPointsEarned'] = total_pts
data['hud']['teamAvgPoints'] = round(total_pts / max(bd_count, 1), 1)

# Update timestamps
data['updated'] = datetime.now().strftime('%Y-%m-%dT%H:%M:%S-03:00')
data['dataDate'] = yesterday
data['log'].insert(0, {
    "time": datetime.now().strftime('%H:%M'),
    "agent": "System",
    "type": "ok",
    "msg": f"Merchant list + 积分 updated — B Mid Zone data as of {yesterday}"
})
data['log'] = data['log'][:5]

with open(f'{repo}/data.json', 'w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)

print(f'[OK] data.json saved. Updated BDs: {bds_updated}')
print(f'[OK] Total team points: {total_pts}, avg: {data["hud"]["teamAvgPoints"]}')
PYEOF

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Parsed. Pushing to GitHub..." >> "$LOG"

# Step 4: Git push
cd "$REPO"
git add data.json
git diff --cached --quiet || git commit -m "auto: merchant list + scores update $(date +%Y-%m-%d)"
git push origin main >> "$LOG" 2>&1

echo "[$(date '+%Y-%m-%d %H:%M:%S')] === Merchant list update done ===" >> "$LOG"
echo "done"

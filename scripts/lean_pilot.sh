#!/usr/bin/env bash
# QuantConnect LEAN CLI pilot.
#
# Goal: run ONE real local backtest with the LEAN CLI (pip package `lean`)
# and report the statistics EXACTLY as LEAN reports them — or report the
# exact blocker (command + error). Nothing is faked: if no statistics are
# produced, results/lean_result.md says so and this script exits non-zero.
#
# Verified locally (2026-11-10, lean 1.0.233) before this repo was built:
#   * `lean create-project` works with NO QuantConnect account.
#   * `lean init` does NOT: it prompts for a QuantConnect user id + API
#     token, validates them against the API and asks for an organization.
#     So this script replicates init's *file* scaffolding only, from the
#     same public source init itself downloads: the QuantConnect/Lean
#     GitHub repo master.zip (its Data/ sample data + Launcher/config.json
#     becomes lean.json with data-folder pointed at ./data).
#   * With lean.json + data/ + project in place, `lean backtest` passes
#     all config checks with no credentials and stops only at Docker —
#     which GitHub-hosted runners provide.
#   * The free sample SPY daily data in that repo covers
#     1998-01-02 .. 2021-03-31, so the pilot window is 2020-01-01 ->
#     2021-01-01. A 2023-2024 window would need a QuantConnect data
#     download, which requires an account.

set -u
cd "$(dirname "$0")/.."
ROOT="$PWD"
RESULTS="$ROOT/results"
WS="$ROOT/lean_workspace"
mkdir -p "$RESULTS" "$WS"
cd "$WS"

step() { echo; echo "=== $* ==="; }
BLOCKER_CMD=""
BLOCKER_LOG=""

write_blocker_result() {
  {
    echo "# LEAN pilot result"
    echo
    echo "**Backtest did NOT complete — no statistics were produced. Nothing below is estimated.**"
    echo
    echo "- Date (UTC): $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "- LEAN CLI: $(lean --version 2>/dev/null || echo 'unknown')"
    echo "- Failing command: \`$BLOCKER_CMD\`"
    echo
    echo "## Exact error output (tail)"
    echo
    echo '```'
    tail -n 60 "$BLOCKER_LOG" 2>/dev/null || echo "(no output captured)"
    echo '```'
    echo
    echo "Full pilot log: run.log in this artifact. Sample-data / login notes: see README.md."
  } > "$RESULTS/lean_result.md"
}

step "Environment"
python3 --version || true
docker --version || true
docker info --format 'Docker server: {{.ServerVersion}}' 2>&1 | head -2 || true
df -h . | tail -1 || true

step "Install LEAN CLI (pip install lean)"
pip install lean 2>&1 | tail -3
lean --version || { BLOCKER_CMD="pip install lean / lean --version"; BLOCKER_LOG="$RESULTS/run.log"; write_blocker_result; exit 1; }

step "Show that lean init requires QuantConnect credentials (bounded attempt)"
mkdir -p init_attempt && cd init_attempt
timeout 120 lean init --language python < /dev/null > "$RESULTS/lean_init_attempt.log" 2>&1
echo "lean init exit code: $? (expected non-zero: it prompts for a user id / API token)"
tail -5 "$RESULTS/lean_init_attempt.log" || true
cd "$WS"
rm -rf init_attempt

step "Replicate lean init file scaffolding from the public QuantConnect/Lean repo"
# This is exactly what `lean init` downloads (see lean/commands/init.py):
# https://github.com/QuantConnect/Lean/archive/master.zip -> Data/ + Launcher/config.json
if [ ! -f master.zip ]; then
  curl -sL -o master.zip https://github.com/QuantConnect/Lean/archive/master.zip || {
    BLOCKER_CMD="curl -sL -o master.zip https://github.com/QuantConnect/Lean/archive/master.zip"
    BLOCKER_LOG="$RESULTS/run.log"; write_blocker_result; exit 1; }
fi
ls -lh master.zip
python3 - <<'PYEOF'
import zipfile
z = zipfile.ZipFile("master.zip")
count = 0
for n in z.namelist():
    if n.startswith("Lean-master/Data/"):
        z.extract(n, ".")
        count += 1
cfg = z.read("Lean-master/Launcher/config.json").decode("utf-8")
cfg = cfg.replace('"data-folder": "../../../Data/"', '"data-folder": "data"')
open("lean.json", "w").write(cfg)
print(f"extracted {count} data files; lean.json written")
PYEOF
mv Lean-master/Data data && rmdir Lean-master
rm -f master.zip
du -sh data
grep -m1 '"data-folder"' lean.json

step "Scaffold the project with LEAN's own scaffolding"
lean project-create "BuyAndHold" --language python 2>&1 || lean create-project "BuyAndHold" --language python 2>&1 || {
  BLOCKER_CMD='lean project-create "BuyAndHold" --language python'
  BLOCKER_LOG="$RESULTS/run.log"; write_blocker_result; exit 1; }
ls -la BuyAndHold

step "Write the BuyAndHold algorithm (SPY daily, 2020-01-01 -> 2021-01-01)"
cat > BuyAndHold/main.py <<'PYEOF'
# region imports
from AlgorithmImports import *
# endregion

class BuyAndHold(QCAlgorithm):

    def initialize(self):
        # Window is inside the free sample-data range for SPY daily
        # (1998-01-02 .. 2021-03-31 in the QuantConnect/Lean repo Data/).
        self.set_start_date(2020, 1, 1)
        self.set_end_date(2021, 1, 1)
        self.set_cash(100000)
        self.add_equity("SPY", Resolution.DAILY)

    def on_data(self, data: Slice):
        if not self.portfolio.invested:
            self.set_holdings("SPY", 1)
            self.debug("Purchased Stock")
PYEOF
cat BuyAndHold/main.py

step "Run the backtest: lean backtest \"BuyAndHold\" (pulls the quantconnect/lean Docker image on first run)"
timeout 3000 lean backtest "BuyAndHold" < /dev/null > "$WS/backtest_output.log" 2>&1
BT_EXIT=$?
tail -40 "$WS/backtest_output.log"
cp "$WS/backtest_output.log" "$RESULTS/backtest_output.log"
if [ "$BT_EXIT" -ne 0 ]; then
  BLOCKER_CMD='lean backtest "BuyAndHold"'
  BLOCKER_LOG="$WS/backtest_output.log"
  write_blocker_result
  echo "Backtest failed with exit code $BT_EXIT — blocker written to results/lean_result.md"
  exit 1
fi

step "Collect result files and extract statistics exactly as reported"
find BuyAndHold/backtests -type f | sort || true
python3 - <<'PYEOF'
import json, shutil
from pathlib import Path

results = Path("..") / "results"
bt_root = Path("BuyAndHold/backtests")
jsons = sorted(bt_root.rglob("*.json")) if bt_root.exists() else []

def find_statistics(obj, depth=0):
    if depth > 6:
        return None
    if isinstance(obj, dict):
        for key, val in obj.items():
            if key.lower() == "statistics" and isinstance(val, dict) and val:
                return val
        for val in obj.values():
            found = find_statistics(val, depth + 1)
            if found is not None:
                return found
    elif isinstance(obj, list):
        for item in obj:
            found = find_statistics(item, depth + 1)
            if found is not None:
                return found
    return None

stats = None
stats_source = None
copied = []
for jf in jsons:
    # Copy summary-style files (and any small result json) into results/
    name = jf.name.lower()
    if "summary" in name or jf.stat().st_size < 25_000_000:
        dest = results / jf.name
        if not dest.exists():
            shutil.copyfile(jf, dest)
            copied.append(jf.name)
    if stats is None:
        try:
            data = json.loads(jf.read_text(encoding="utf-8", errors="replace"))
        except Exception:
            continue
        found = find_statistics(data)
        if found:
            stats, stats_source = found, jf.name

lines = []
lines.append("# LEAN pilot result")
lines.append("")
if stats:
    lines.append("**Backtest ran successfully** with the QuantConnect LEAN CLI (local Docker engine, free sample data).")
    lines.append("")
    lines.append(f"- Project: BuyAndHold (SPY, daily, buy & hold)")
    lines.append(f"- Window: 2020-01-01 to 2021-01-01 (inside the free sample-data range; see README)")
    lines.append(f"- Starting cash: 100000")
    lines.append(f"- Statistics source file: `{stats_source}` (copied into this artifact)")
    lines.append("")
    lines.append("## Headline statistics (verbatim from LEAN)")
    lines.append("")
    for wanted in ["Total Return", "Net Profit", "Sharpe Ratio", "Drawdown", "Total Fees"]:
        for key, val in stats.items():
            if key.strip().lower() == wanted.lower():
                lines.append(f"- {key}: {val}")
    lines.append("")
    lines.append("## Full statistics as reported")
    lines.append("")
    lines.append("| Statistic | Value |")
    lines.append("|---|---|")
    for key, val in stats.items():
        lines.append(f"| {key} | {val} |")
else:
    lines.append("**The backtest command exited 0 but NO statistics were found in any result JSON.**")
    lines.append("")
    lines.append(f"- JSON files found under BuyAndHold/backtests: {[str(j) for j in jsons]}")
    lines.append("- This is reported as-is; no numbers were invented. See backtest_output.log.")
lines.append("")
lines.append(f"Result files copied into this artifact: {copied}")
(results / "lean_result.md").write_text("\n".join(lines) + "\n")
print("\n".join(lines))
Path("..", "results", ".stats_found").write_text("yes" if stats else "no")
PYEOF

if [ "$(cat "$RESULTS/.stats_found" 2>/dev/null)" = "yes" ]; then
  rm -f "$RESULTS/.stats_found"
  echo "Pilot complete: statistics extracted."
  exit 0
else
  rm -f "$RESULTS/.stats_found"
  echo "Backtest exited 0 but no statistics were found — treating as a blocker (see lean_result.md)."
  exit 1
fi

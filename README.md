# lean-runner

Runs [QuantConnect LEAN](https://www.lean.io/) backtests (via the LEAN CLI,
pip package `lean`) on GitHub Actions, where the commands to execute live in
a repository **Actions variable** — not in code.

## The pattern (one repo per tool)

1. **Edit the commands**: repo *Settings → Secrets and variables → Actions →
   Variables* → set the `COMMANDS` variable to whatever shell commands this
   run should execute (multi-line works). The same can be done through the
   GitHub API (`PUT /repos/{owner}/{repo}/actions/variables/COMMANDS`).
2. **Trigger manually**: *Actions* tab → “Run analysis” → *Run workflow*
   (or `POST /repos/{owner}/{repo}/actions/workflows/run.yml/dispatches`).
   The workflow has **no other triggers** — it runs only when dispatched.
3. **Collect results**: the workflow uploads everything under `results/` as
   the `results` build artifact (`if: always()`, so partial results survive
   a failing step). Download it from the run page or via the API.

The workflow itself is generic: checkout → Python 3.11 →
`pip install -r requirements.txt` → run `${{ vars.COMMANDS }}` → upload
`results/`. To run a different analysis, change the variable — not the
workflow.

## Multi-market by design

Nothing in the workflow or the runner pattern is tied to one exchange.
Scripts take the **ticker symbol and analysis parameters as inputs**, so the
same repo can backtest a US stock today and another market tomorrow — only
the inputs (algorithm file / `COMMANDS` variable) change.

## Pilot: LEAN CLI — SPY BuyAndHold

Pilot `COMMANDS` value:

```sh
mkdir -p results
set -o pipefail; bash scripts/lean_pilot.sh 2>&1 | tee results/run.log
```

`scripts/lean_pilot.sh`:

1. `pip install lean`, prints the CLI version.
2. Attempts `lean init` (bounded, stdin closed) and saves the output to
   `results/lean_init_attempt.log` — see the login note below.
3. Replicates `lean init`'s *file* scaffolding from the same public source
   `lean init` itself downloads: the `QuantConnect/Lean` GitHub repo
   (`Data/` sample data + `Launcher/config.json` → `lean.json`).
4. Scaffolds the project with LEAN's own scaffolding
   (`lean project-create "BuyAndHold" --language python`), then writes a
   minimal BuyAndHold algorithm: SPY, daily resolution, buy once and hold,
   100,000 starting cash.
5. Runs `lean backtest "BuyAndHold"` — the CLI pulls the
   `quantconnect/lean` Docker image (large; first run takes a while) and
   runs the engine locally against the sample data.
6. Copies the backtest result JSON(s) into `results/` and writes
   `results/lean_result.md` with the headline statistics **exactly as
   LEAN reported them** (Total Return / Net Profit, Sharpe Ratio,
   Drawdown, Total Fees). If any step blocks the backtest, the result file
   records the exact failing command and error instead — no number is
   ever estimated or invented.

### Honest notes (verified locally with lean 1.0.233, 2026-11-10)

- **`lean init` has a login wall.** In lean 1.0.233 it prompts for a
  QuantConnect user id + API token, validates them against the
  QuantConnect API and asks you to select an organization — before it
  scaffolds anything. There is no anonymous `lean init`. The pilot
  therefore replicates only init's file downloads (public, open-source
  repo) and never touches any account.
- **`lean create-project` and local `lean backtest` need no account.**
  Verified locally: with `lean.json` + `data/` + a project in place,
  `lean backtest` passes every config check with no credentials and stops
  only at Docker availability — which GitHub-hosted runners provide.
  (Commands that *do* need an account: anything `lean cloud …` and
  `lean data download` from QuantConnect's Data Library.)
- **Free data range decides the window.** The sample SPY daily data in
  the `QuantConnect/Lean` repo covers **1998-01-02 → 2021-03-31**, so the
  pilot backtests **2020-01-01 → 2021-01-01**. A 2023–2024 window is not
  in the free sample data; it would require downloading data from
  QuantConnect, which requires an account (and possibly a paid dataset).
- **Docker is required** by the LEAN CLI; the engine runs inside the
  `quantconnect/lean` image. Pulling it is several GB and dominates the
  first run's time.

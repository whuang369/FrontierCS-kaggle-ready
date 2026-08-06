#!/usr/bin/env bash
# End-to-end check that a published revision of this dataset actually runs.
#
# It reproduces what a consumer does rather than what a developer does: export a
# clean tree from a git ref, install the adapter from that tree alone, generate a
# task with no host environment variables set, and grade the reference solution.
#
# Step 6 is the point of the suite. The failure this guards against is not a
# crash -- it is a task whose test data never arrives, which leaves the judge
# healthy and scores every submission 0. So the run is repeated with the test
# data removed: if that also produces a real score, step 5 proved nothing.
#
#   ./smoke_test.sh [git-ref] [problem-id] [workdir]
#
# Requires: docker, uv, and network access for the base images.
set -euo pipefail

REF=${1:-HEAD}
PID=${2:-0}
WORK=${3:-$(mktemp -d)}
REPO=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)

FAIL=0
step() { printf '\n=== %s ===\n' "$1"; }
ok()   { printf '  PASS  %s\n' "$1"; }
bad()  { printf '  FAIL  %s\n' "$1"; FAIL=1; }

rm -rf "$WORK"; mkdir -p "$WORK/tree"

step "1. export a clean tree from $REF"
git -C "$REPO" archive "$REF" | tar -x -C "$WORK/tree"
printf '  %s files\n' "$(find "$WORK/tree" -type f | wc -l | tr -d ' ')"
for p in .env algorithmic/solutions; do
  [ -e "$WORK/tree/$p" ] && bad "$p is published but should not be" || ok "$p absent"
done

step "2. install the adapter from that tree alone"
uv venv "$WORK/venv" -q
if VIRTUAL_ENV="$WORK/venv" uv pip install -q "$WORK/tree/adapters/frontier-cs-algorithm" 2>"$WORK/pip.err"; then
  ok "adapter installed"
else
  bad "adapter install failed"; sed 's/^/      /' "$WORK/pip.err" | head -5
fi
"$WORK/venv/bin/python" -c "import harbor" 2>/dev/null \
  && ok "harbor resolves" || bad "harbor does not resolve"

step "3. generate task for problem $PID with no host env vars"
if (cd "$WORK/tree" && env -u FRONTIER_CS_ALGORITHMIC_PATH \
      "$WORK/venv/bin/frontier-cs-algorithm" --source "$WORK/tree" \
      --output-dir "$WORK/tree/gen" --task-ids "$PID" >"$WORK/gen.log" 2>&1); then
  ok "task generated"
else
  bad "generation failed"; tail -5 "$WORK/gen.log" | sed 's/^/      /'
fi

TASK="$WORK/tree/gen/frontier-cs-algorithm-$PID"
step "4. bundle is self-contained"
grep -rq "FRONTIER_CS_ALGORITHMIC_PATH" "$TASK" 2>/dev/null \
  && bad "bundle references a host path" || ok "no host-path variable"
[ -d "$TASK/environment/problem/testdata" ] \
  && ok "test data present" || bad "test data missing"
[ -e "$TASK/environment/problem/examples" ] \
  && bad "examples/ (reference solutions) shipped in bundle" || ok "examples/ excluded"

step "5. grade the reference solution"
if (cd "$WORK/tree" && env -u FRONTIER_CS_ALGORITHMIC_PATH \
      "$WORK/venv/bin/harbor" trial start -p "$TASK" -a oracle \
      --trials-dir "$WORK/trials" >"$WORK/trial.log" 2>&1); then
  ok "trial completed"
else
  bad "trial failed"; tail -15 "$WORK/trial.log" | sed 's/^/      /'
fi
R=$(find "$WORK/trials" -name reward.txt -exec cat {} \; 2>/dev/null | head -1)
printf '  reward = %s\n' "${R:-none}"
# Problems are open-ended optimisation tasks, so the reference does not score
# 1.0 (problem 0 lands near 0.89). Only a non-zero score is meaningful here.
if [ -n "$R" ] && awk -v r="$R" 'BEGIN{exit !(r+0 > 0)}'; then
  ok "grader produced a non-zero score"
else
  bad "no usable score -- grader likely saw no test data"
fi

step "6. negative control: same task, test data removed"
NEG="$WORK/neg"; rm -rf "$NEG"; mkdir -p "$NEG"; cp -R "$TASK" "$NEG/task"
rm -f "$NEG"/task/environment/problem/testdata/*
(cd "$WORK/tree" && env -u FRONTIER_CS_ALGORITHMIC_PATH \
   "$WORK/venv/bin/harbor" trial start -p "$NEG/task" -a oracle \
   --trials-dir "$NEG/trials" >"$WORK/neg.log" 2>&1) || true
NR=$(find "$NEG/trials" -name reward.txt -exec cat {} \; 2>/dev/null | head -1)
printf '  reward without test data = %s\n' "${NR:-none}"
if [ -z "$NR" ] || awk -v r="$NR" 'BEGIN{exit !(r+0 == 0)}'; then
  ok "scores 0 without test data -- step 5 measured something real"
else
  bad "still scored $NR without test data -- the grader is not reading it"
fi

printf '\n%s\n' "-----------------------------------"
[ "$FAIL" -eq 0 ] && echo "SMOKE TEST PASSED" || echo "SMOKE TEST FAILED"
exit "$FAIL"

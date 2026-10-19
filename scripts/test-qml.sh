#!/usr/bin/env bash
# Every plugin's QML unit tests (default/omarchy/plugins/*/tests/tst_*.qml).
#
#   ./scripts/test-qml.sh
#
# They test the plugins' pure JavaScript -- the phone's call bookkeeping, the
# lock's decisions -- so they need qmltestrunner and QtTest, and no shell, no
# compositor and no phone. Qt 6's runner, by path: /usr/bin/qmltestrunner can
# be Qt 5's, which runs nothing and says nothing. QMLTESTRUNNER overrides it.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER=${QMLTESTRUNNER:-/usr/lib/qt6/bin/qmltestrunner}
[[ -x $RUNNER ]] || { echo "FAIL: no Qt 6 qmltestrunner at $RUNNER"; exit 1; }

export QT_QPA_PLATFORM=offscreen
# The tests that print times were written against UTC, like the screenshots.
export TZ=UTC
fail=0 files=0
for t in "$ROOT"/default/omarchy/plugins/*/tests/tst_*.qml; do
  files=$((files + 1))
  out=$("$RUNNER" -input "$t" 2>&1)
  rc=$?
  totals=$(grep -m1 '^Totals:' <<<"$out")
  if [[ $rc -eq 0 && -n $totals ]]; then
    printf '  PASS  %s: %s\n' "${t#"$ROOT"/default/omarchy/plugins/}" "${totals#Totals: }"
  else
    printf '  FAIL  %s (rc %s)\n' "${t#"$ROOT"/default/omarchy/plugins/}" "$rc"
    grep -E '^(FAIL|   Actual|   Expected|   Loc)' <<<"$out" | head -20
    fail=$((fail + 1))
  fi
done

[[ $files -gt 0 ]] || { echo "FAIL: no tests found"; exit 1; }
if [[ $fail -gt 0 ]]; then
  echo "$fail of $files failed"
  exit 1
fi
echo "all $files passed"

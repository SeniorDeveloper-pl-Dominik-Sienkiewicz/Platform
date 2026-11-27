#!/usr/bin/env bash
# ADR-0022: everything Platform prints, names or ships for a reader is English; Polish stays only in
# CLAUDE.md and in comments. The guard scans the scripts, workflows, convention plugins, Java libraries and
# starters for Polish letters outside comments, and in Python the strings that reach a reader (print, raise,
# sys.exit, write, argparse help), not comments or docstrings. A line that holds Polish letters as data (a detector
# pattern) ends with the comment `language-guard: allow`.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"

polish='ą|ć|ę|ł|ń|ó|ś|ź|ż|Ą|Ć|Ę|Ł|Ń|Ó|Ś|Ź|Ż'

scan() { # $1 = comment style (hash|slash), files on stdin
  local style=$1 file
  while IFS= read -r file; do
    LC_ALL=C awk -v style="$style" -v file="$file" -v polish="$polish" '
      /language-guard: allow[[:space:]]*$/ { next }
      {
        text = $0
        if (style == "hash") {
          if (text ~ /^[[:space:]]*(#|\/\/)/) next
          sub(/[[:space:]]#([[:space:]].*)?$/, "", text)
        } else {
          if (text ~ /^[[:space:]]*(\/\/|\*|\/\*)/) next
          sub(/[[:space:]]\/\/.*$/, "", text)
        }
        if (text ~ polish) printf "  %s:%d: %s\n", file, NR, $0
      }
    ' "$file"
  done
}

hash_files=$(git ls-files '*.sh' '.github/workflows/*.yml' 'templates/github/**.yml' \
  ':!:templates/tests/**' ':!:**/test/**' ':!:*.test.sh')
slash_files=$(git ls-files 'gradle/*/src/main/**.kt' 'gradle/*/src/main/**.kts' 'gradle/*/src/main/**.java' \
  'templates/jvm/**.java' 'templates/jvm/**.kts' 'frontend/packages/*/bin/*.mjs' \
  ':!:**/src/test/**' ':!:**/test/**')

# Python: drzewo składni zamiast wzorca linii, bo docstring i komentarz mogą zostać po polsku (ADR-0022).
scan_python() { # files as arguments
  [[ $# -gt 0 ]] || return 0
  python3 -I - "$@" <<'PY'
import ast
import re
import sys

POLISH = re.compile("[\u0105\u0107\u0119\u0142\u0144\u00f3\u015b\u017a\u017c\u0104\u0106\u0118\u0141\u0143\u00d3\u015a\u0179\u017b]")
OUTPUT = {"print", "exit", "write", "error", "warn", "warning", "fail", "add_argument", "ArgumentParser"}


def called(func):
    return func.id if isinstance(func, ast.Name) else func.attr if isinstance(func, ast.Attribute) else None


for path in sys.argv[1:]:
    with open(path, encoding="utf-8") as handle:
        source = handle.read()
    lines = source.splitlines()
    roots = [node for node in ast.walk(ast.parse(source, path))
             if isinstance(node, ast.Raise) or (isinstance(node, ast.Call) and called(node.func) in OUTPUT)]
    reported = {
        node.lineno
        for root in roots
        for node in ast.walk(root)
        if isinstance(node, ast.Constant) and isinstance(node.value, str) and POLISH.search(node.value)
        and not re.search(r"language-guard: allow\s*$", lines[node.lineno - 1])
    }
    for number in sorted(reported):
        print(f"  {path}:{number}: {lines[number - 1]}")
PY
}

python_files=$(git ls-files '*.py' ':!:templates/tests/**' ':!:**/test/**')
[[ -n "$python_files" ]] || { echo "the language guard found no Python files to scan" >&2; exit 1; }

count=$(printf '%s\n%s\n%s\n' "$hash_files" "$slash_files" "$python_files" | grep -c . || true)
[[ "$count" -gt 50 ]] || { echo "the language guard found only $count files to scan" >&2; exit 1; }

python_list=()
while IFS= read -r file; do python_list+=("$file"); done <<< "$python_files"
found=$( { scan hash <<< "$hash_files"; scan slash <<< "$slash_files"; scan_python "${python_list[@]}"; } )
if [[ -n "$found" ]]; then
  printf 'Polish outside comments (ADR-0022: output, names and descriptions are English):\n%s\n' "$found" >&2
  exit 1
fi
echo "OK: $count scripts, workflows and sources print, name and describe in English"

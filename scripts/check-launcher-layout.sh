#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

errors=0

fail() {
	echo "ERROR: $*"
	errors=1
}

require_dir() {
	[ -d "$1" ] || fail "missing directory: $1"
}

require_file() {
	[ -f "$1" ] || fail "missing file: $1"
}

for d in Apps/!Danby Apps/!Temple Apps/!Models Apps/!Lessons; do
	require_dir "$d"
	require_file "$d/!Boot"
done

while IFS= read -r f; do
	fail "empty !Run (bad script header risk): $f"
done < <(find Apps -name '!Run' -type f -size 0 | sort)

while IFS= read -r -d '' f; do
	first="$(sed -n '1p' "$f")"
	[ "$first" = "#!/dis/sh.dis" ] || fail "invalid !Run header: $f"
done < <(find Apps -name '!Run' -type f -print0)

check_wrapper_target() {
	local file="$1"
	local expected_ns="$2"
	local target
	target="$(awk 'NR>1 && $0 !~ /^[[:space:]]*#/ && $0 !~ /^[[:space:]]*$/ {print $1; exit}' "$file")"
	[ -n "$target" ] || { fail "no launch target in $file"; return; }
	case "$target" in
		"$expected_ns"/*) ;;
		*) fail "wrong namespace in $file -> $target (expected $expected_ns/*)" ;;
	esac
	local app="${target#*/}"
	[ -f "appl/$expected_ns/$app.dis" ] || fail "missing app binary source for $file -> appl/$expected_ns/$app.dis"
}

# Category folder !Run files (top-level !Boot+!Run for wm/dir) are exempt.
while IFS= read -r -d '' f; do
	[ "$f" = "Apps/!Danby/!Run" ] && continue
	check_wrapper_target "$f" "temple"
done < <(find Apps/!Danby -name '!Run' -type f -print0)

while IFS= read -r -d '' f; do
	[ "$f" = "Apps/!Temple/!Run" ] && continue
	check_wrapper_target "$f" "temple"
done < <(find Apps/!Temple -name '!Run' -type f -print0)

echo "Category counts:"
printf "  Danby  : %s\n" "$(find Apps/!Danby -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
printf "  Temple : %s\n" "$(find Apps/!Temple -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
printf "  Models : %s\n" "$(find Apps/!Models -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
printf "  Lessons: %s\n" "$(find Apps/!Lessons -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"

if [ "$errors" -ne 0 ]; then
	exit 1
fi

echo "Launcher layout checks passed."

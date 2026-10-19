#!/bin/sh

set -eu

if [ "$#" -lt 4 ]; then
	echo "Usage: $0 <label> <parser.awk> <namespace.h> <object>..." >&2
	exit 2
fi

label=$1
parser=$2
namespace=$3
shift 3

: "${NM:=nm}"
: "${AWK:=awk}"

if [ -n "${PRIVATE_NAMESPACE_AUDIT_DIR:-}" ]; then
	audit_dir=${PRIVATE_NAMESPACE_AUDIT_DIR}/${label}
	mkdir -p "${audit_dir}"
	remove_audit_dir=false
else
	audit_dir=${TMPDIR:-/tmp}/jemalloc-private-namespace-${label}-$$
	(umask 077 && mkdir "${audit_dir}")
	remove_audit_dir=true
fi

cleanup() {
	status=$?
	trap - EXIT HUP INT TERM
	if [ "${status}" -ne 0 ]; then
		echo "private namespace audit (${label}): files retained in ${audit_dir}" >&2
		remove_audit_dir=false
	fi
	if ${remove_audit_dir}; then
		rm -rf "${audit_dir}"
	fi
	exit "${status}"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

header_symbols=${audit_dir}/header.symbols
portable_raw=${audit_dir}/portable.raw
portable_symbols=${audit_dir}/portable.symbols
portable_a_raw=${audit_dir}/portable-a.raw
portable_a_symbols=${audit_dir}/portable-a.symbols
legacy_raw=${audit_dir}/legacy.raw
legacy_symbols=${audit_dir}/legacy.symbols

LC_ALL=C; export LC_ALL

"${AWK}" '$1 == "#define" {print $2}' "${namespace}" | sort -u > \
    "${header_symbols}"

: > "${portable_raw}"
for object do
	"${NM}" -P -t d "${object}" >> "${portable_raw}"
done
"${AWK}" -f "${parser}" "${portable_raw}" | sort -u > \
    "${portable_symbols}"

compare_symbols() {
	expected=$1
	actual=$2
	description=$3

	if ! cmp -s "${expected}" "${actual}"; then
		echo "private namespace audit (${label}): ${description}" >&2
		diff -u "${expected}" "${actual}" >&2 || true
		exit 1
	fi
}

compare_symbols "${header_symbols}" "${portable_symbols}" \
    "generated header differs from nm -P -t d"

first_object=$1
if "${NM}" -a -P -t d "${first_object}" >/dev/null 2>&1; then
	: > "${portable_a_raw}"
	: > "${legacy_raw}"
	for object do
		"${NM}" -a -P -t d "${object}" >> "${portable_a_raw}"
		"${NM}" -a "${object}" >> "${legacy_raw}"
	done
	"${AWK}" -f "${parser}" "${portable_a_raw}" | sort -u > \
    "${portable_a_symbols}"
	"${AWK}" -f "${parser}" "${legacy_raw}" | sort -u > \
    "${legacy_symbols}"

	compare_symbols "${portable_symbols}" "${portable_a_symbols}" \
    "-a changes the portable private-symbol set"
	compare_symbols "${portable_symbols}" "${legacy_symbols}" \
    "portable output differs from legacy nm -a output"
	a_status="supported; no selected-symbol difference"
else
	a_status="unsupported"
fi

symbol_count=$(wc -l < "${portable_symbols}" | tr -d ' ')
symbol_types=$("${AWK}" '(NF == 3 || NF == 4) &&
    $2 ~ /^[A-Za-z?]$/ && $3 ~ /^[0-9]+$/ {types[$2] = 1}
    END {for (type in types) print type}' "${portable_raw}" | sort | tr '\n' ' ')

echo "private namespace audit (${label}): ${symbol_count} symbols"
echo "private namespace audit (${label}): -a ${a_status}"
echo "private namespace audit (${label}): observed types: ${symbol_types}"

#!/bin/bash
set -eEuo pipefail

# Runs in CI.
# Test compilation with some flag combinations:
# - All version and debug names, extracted from the source code.
#   Guard against bit rot by ensuring things like debug code continue to compile.
# - Preview compiler features.
#   Detect problems early.

bad_flags=(
	# Built-in
	-version=AArch64
	-version=all
	-version=BigEndian
	-version=CRuntime_Bionic
	-version=CRuntime_DigitalMars
	-version=CRuntime_Microsoft
	-version=Darwin
	-version=DigitalMars
	-version=D_LP64
	-version=FreeBSD
	-version=GNU
	-version=iOS
	-version=LDC
	-version=linux
	-version=LittleEndian
	-version=NetBSD
	-version=none
	-version=OpenBSD
	-version=OSX
	-version=Posix
	-version=TVOS
	-version=unittest
	-version=WatchOS
	-version=Win64
	-version=Windows
	-version=X86
	-version=X86_64

	# Require special dependencies
	-version=LIBEV

	# "no longer has any effect"
	-preview=dip25
	# Currently very buggy, segfaults a lot
	-preview=dip1021
	# Seems unfinished, see https://forum.dlang.org/post/t05jts$2j48$1@digitalmars.com
	-preview=nosharedaccess
	# Too strict
	-preview=safer
	# Includes the above
	-preview=all
)

mapfile -t files < <(git ls-files)
mapfile -t all_flags < <(
	{
		printf -- '%s\n' '-debug'
		dmd -preview=h | awk '/^  (=[^ ]*) .*/ {print "-preview" $1}'
		cat "${files[@]}" |
			sed -n 's/.*\b\(debug\|version\) *( *\([^()~" ]*\) *).*/-\1=\2/p' |
			sort -u
	} | grep -vFf <(printf -- '%s\n' "${bad_flags[@]}")
)

find . -maxdepth 1 \( -name '*.ok' -o -name '*.out' \) -delete

# Runs `check` for each tested flag combination.
function check_all() {
	check 'no flags'

	for flag in "${all_flags[@]}" ; do
		check "$flag" "$flag"
	done

	check 'all flags' "${all_flags[@]}"
}

function check() {
	local name=$1
	local flags=("${@:2}")

	printf -- '%s > ./%q.out 2>&1 && touch ./%q.ok && echo "%s OK" >&2\n' \
		   "$(printf -- '%q ' \
				dmd -color=on -i -o- -I.. -de "${flags[@]}" all.d)" \
		   "$name" "$name" "$name"
}
nproc=$(nproc)
limit_ram=$(awk '/MemFree/ { printf "%d\n", $2/(2*1024*1024) }' /proc/meminfo)
if (( nproc > limit_ram )) ; then nproc=$limit_ram ; fi
if (( nproc < 1 )) ; then nproc=1 ; fi
check_all | ( xargs -n 1 -d '\n' -P "$nproc" sh -c || true )

function check() {
	local name=$1

	if [[ ! -f ./"$name".ok ]] ; then
		printf -- '%s failed! Output:\n' "$name"
		cat ./"$name".out
		exit 1
	fi
}
check_all

# Check unittest blocks
if git grep '^\s*unittest' ; then
	printf 'All unittest blocks must have a debug(ae_unittest) guard!\n' >&2
	exit 1
fi

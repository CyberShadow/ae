#!/bin/bash
set -eu

# Generate a JSON file usable with DAutoFix.
# Also create an all.d file, which can be used to run all unit tests.

IFS=$'\n'

packages=(
	# These don't have any special *compile-time* dependencies.
	# (We're not going to try to link the output.)
	ae
	ae:sqlite
)

rm -f files.txt
for package in "${packages[@]}"
do
	dub describe "$package" > describe.json
	jq -r --arg package "$package" '.packages[] | select(.name == $package) | .files[] | select(.role == "source") | .path' describe.json >> files.txt
done
mapfile -t files < files.txt
rm files.txt describe.json

dmd -o- -dw -Xfae.json "${files[@]}"

(
	echo "deprecated module ae.all;"
	printf '%s\n' "${files[@]}" | sed 's#^\(.*\)\.d$#import ae/\1;#g' | grep -v "package;" | sed s#/#.#g
) > all.d

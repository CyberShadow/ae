#!/bin/bash
set -eu

# Generate a JSON file usable with DAutoFix.
# Also create an all.d file, which can be used to run all unit tests.

IFS=$'\n'

files=$(git ls-files)

files=$(echo "$files" | grep '\.d$')

files=$(echo "$files" | grep -vxF 'utils/graphics/sdlimage.d') # Needs SDLv1
files=$(echo "$files" | grep -vxF 'utils/graphics/libpng.d') # Needs libpng
files=$(echo "$files" | grep -vxF 'ui/app/windows/main.d') # Windows-only
files=$(echo "$files" | grep -v  '^utils/serialization/') # Needs __traits(child)
files=$(echo "$files" | grep -vxF 'net/ssl/openssl.d') # Needs OpenSSL
files=$(echo "$files" | grep -vxF 'net/x11/package.d') # Needs X11
files=$(echo "$files" | grep -vxF 'sys/net/system.d') # Needs OpenSSL
files=$(echo "$files" | grep -v '^.*/sdl2') # Needs SDLv2
files=$(echo "$files" | grep -v '^sys/windows/pe/') # Needs win32

files=$(echo "$files" | grep -vxF 'utils/alloc.d') # Needs alias template parameter binding
files=$(echo "$files" | grep -vxF 'utils/container/list.d') # Needs ae.utils.alloc
files=$(echo "$files" | grep -vxF 'utils/container/package.d') # Needs ae.utils.container.list
files=$(echo "$files" | grep -vxF 'utils/container/hashtable.d') # Needs ae.utils.alloc
files=$(echo "$files" | grep -vxF 'utils/xmldom.d') # Needs ae.utils.alloc

files=$(echo "$files" | grep -vxF 'sys/vfs_curl.d') # Deprecated redirect
files=$(echo "$files" | grep -vxF 'utils/meta/misc.d') # Deprecated redirect

files=$(echo "$files" | grep -v  '^ui/app/main\.d$') # Has main()
files=$(echo "$files" | grep -v  '^ui/app/.*/main\.d$') # Has main()
files=$(echo "$files" | grep -v  '^demo/') # Most have main()

dmd -o- -dw -Xfae.json $files

# files=$(echo "$files" | grep -v \
#      -e sdl \
#      -e demo \
#      -e hls \
#      -e /app/main.d \
#      -e /app/.*/main.d \
#      -e signals\.d \
#      -e benchmark \
#      -e serialization \
#      -e vfs_curl \
#      -e openssl \
#      -e utils/meta/misc \
#      -e utils/graphics/image \
#      -e '!' \
# )

(
	echo "deprecated module ae.all;"
	echo "$files" | sed 's#^\(.*\)\.d$#import ae/\1;#g' | grep -v "package;" | sed s#/#.#g
) > all.d

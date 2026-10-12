#!/bin/sh
# name: Make a zip of these
# description: Puts what is selected into untitled.zip, beside it.
# apply-to: file, directory, link
# args: 1,
# call: $0 $@
# source: diptych
# version: 1
set -eu

# The folder the items are in, taken from the items themselves rather than
# from $DIPTYCH_ACTIVE: what was chosen is what matters, and a script is
# given its arguments before anything else can change.
folder=$(dirname "$1")
cd "$folder"

# untitled.zip, then "untitled 2.zip", as Diptych names a new folder.
target="untitled.zip"
number=2
while [ -e "$target" ]; do
    target="untitled $number.zip"
    number=$((number + 1))
done

# Plain names, so the archive holds "notes.txt" rather than the whole path
# from the root of the disk. Each argument is replaced by its own last
# component, one at a time, which needs no array and no word splitting.
count=$#
index=0
while [ "$index" -lt "$count" ]; do
    set -- "$@" "$(basename "$1")"
    shift
    index=$((index + 1))
done

/usr/bin/zip -r -q "$target" "$@"
echo "Created $target in $folder"
echo
/bin/ls -ld "$target"
echo
/usr/bin/unzip -l "$target"

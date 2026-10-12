#!/bin/sh
# name: Make this script editable
# description: Takes the read-only bit off, so it can be changed. It will not run again until it is read-only.
# only-in: ~/.diptych/scripts
# args: 1,
# call: $0 $@
# source: diptych
# version: 1
for f in "$@"; do chmod u+w "$f" && echo "editable: $f"; done

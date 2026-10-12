#!/bin/sh
# name: Make this script runnable again
# description: Puts the read-only bit back, which is what Diptych requires.
# only-in: ~/.diptych/scripts
# args: 1,
# call: $0 $@
# source: diptych
# version: 1
for f in "$@"; do chmod a-w "$f" && echo "read-only: $f"; done

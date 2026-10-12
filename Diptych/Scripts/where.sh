#!/bin/sh
# name: Where am I
# description: The two panes, as the scripts see them.
# args: 0
# call: $0
# source: diptych
# version: 1
echo "active: $DIPTYCH_ACTIVE"
echo "other:  $DIPTYCH_OTHER"
echo "left:   $DIPTYCH_LEFT"
echo "right:  $DIPTYCH_RIGHT"
echo "script: $DIPTYCH_SCRIPT"
echo "cwd:    $(pwd)"

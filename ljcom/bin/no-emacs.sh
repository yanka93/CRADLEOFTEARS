#!/bin/sh
#
# <LJDEP>
# prog: find, rm
# </LJDEP>

find . \( -name '.*~' -or -name '*~' -or -name '#*#' -or -name '.#*' \) -print -exec rm -f {} \;

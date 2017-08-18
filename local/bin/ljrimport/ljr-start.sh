#!/bin/bash

export LJHOME=/home/lj-admin/lj
IMPORT_NAME=ljr-import

ipid=`ps -e --format=pid,cmd | grep $IMPORT_NAME | grep -v grep | cut --bytes=1-5`

if [ ! "$ipid" == "" ]; then
  echo "LJR::Import found, PID: $ipid; shutdown with ljr-stop.sh first."
else
  if [ "$LJHOME" != "" ]; then
    cd $LJHOME/bin/ljrimport
    ./ljr-import.pl >> $LJHOME/logs/ljr-import.log 2>&1 &
  else
    echo \$LJHOME is not set.
  fi
fi

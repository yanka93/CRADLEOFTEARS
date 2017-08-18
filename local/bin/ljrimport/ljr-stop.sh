#!/bin/bash

IMPORT_NAME=ljr-import

ipid=`ps -e --format=pid,cmd | grep $IMPORT_NAME | grep -v grep | cut --bytes=1-5`

if [ ! "$ipid" == "" ]; then
  echo "LJR::Import found, PID: $ipid; sending shutdown signal."
  kill $ipid
else
  echo "LJR::Import is not running."
fi

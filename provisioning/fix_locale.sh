#!/bin/bash
if `sed -e 's/de_DE.UTF-8/en_US.UTF-8/g' -i /etc/sysconfig/i18n`
then
    echo "Success"
else
    echo "Failure"
fi

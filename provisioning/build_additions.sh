## Build guest additions for CentOS 6 vbox.

## Current running kernel on Fedora, CentOS 7/6 and Red Hat (RHEL) 7/6 ##
KERN_DIR=/usr/src/kernels/`uname -r`

## Current running kernel on CentOS 5 and Red Hat (RHEL) 5 ##
KERN_DIR=/usr/src/kernels/`uname -r`-`uname -m`

## Export KERN_DIR ##
export KERN_DIR

## BUILD VBOX GUEST ADDITIONS ##
cd /media/VirtualBoxGuestAdditions

./VBoxLinuxAdditions.run

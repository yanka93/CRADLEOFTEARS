#!/bin/bash
# Run this manually to update your Vagrant image.

echo "Updating kernel..."
sudo yum -y update kernel*

echo "Adding EPEL repos"
sudo rpm -Uvh https://dl.fedoraproject.org/pub/epel/epel-release-latest-6.noarch.rpm

echo "Installing python 2 for ansible"
sudo yum -y install python

echo "Installing build tools"
sudo yum -y install gcc kernel-devel kernel-headers dkms make bzip2 perl

## Current running kernel on Fedora, CentOS 7/6 and Red Hat (RHEL) 7/6 ##
KERN_DIR=/usr/src/kernels/`uname -r`

## Current running kernel on CentOS 5 and Red Hat (RHEL) 5 ##
KERN_DIR=/usr/src/kernels/`uname -r`-`uname -m`

## Export KERN_DIR ##
export KERN_DIR

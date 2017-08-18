#!/usr/bin/perl

use strict;
use DMap;
DMap::set_job_servers("localhost", "sammy", "kenny");

my @foo = dmap { "$_ = " . `hostname` } (1..10);

print "dmap says:\n @foo";





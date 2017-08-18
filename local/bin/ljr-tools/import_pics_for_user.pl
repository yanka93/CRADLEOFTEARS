#!/usr/bin/perl -w

use strict;
use Simple; # corrected LJ::Simple
use XML::Parser;

require "$ENV{'LJHOME'}/cgi-bin/ljlib.pl";
require "$ENV{'LJHOME'}/cgi-bin/talklib.pl";

require "ljr-defaults.pl";
require "ljr-links.pl";
require LJR::Distributed;
require "ipics.pl";

#require "ijournal.pl";
#require "icomments.pl";


my $e = import_pics(
  "http://www.livejournal.com",
  "sharlei",
  "",
  "imp_5204",
  "", 1);

print $e->{errtext} ."\n" if $e->{err};

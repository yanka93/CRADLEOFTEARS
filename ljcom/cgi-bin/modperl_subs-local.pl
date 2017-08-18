#!/usr/bin/perl
#

# site-local version of modperl_subs.pl

package LJ::ModPerl;

use strict;

# pull in a lot of useful stuff before we fork children

use lib "$ENV{'LJHOME'}/cgi-bin";
use XMLRPC::Lite; # for cmdbuf:pay_fb_xmlrpc hook

require "phonepost.pl";
require "paylib.pl";

$LJ::OPTMOD_CRACKLIB = eval "use Crypt::Cracklib qw(); 1;";
$Crypt::Cracklib::DICT = "$ENV{'LJHOME'}/cgi-bin/cracklib/dict";

$LJ::OPTMOD_GEOIP = eval "use Geo::IP::PurePerl (); 1;";

1;

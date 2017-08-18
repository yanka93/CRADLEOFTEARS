#!/usr/bin/perl
#

use strict;
use lib "$ENV{'BLOBHOME'}/lib";
use Apache;

Apache->httpd_conf(qq{
PerlInitHandler +Apache::Blob
});

# delete this file from %INC to ensure it's reloaded
# after restarts
delete $INC{"$ENV{'BLOBHOME'}/lib/modperl.pl"};

1;

#!/usr/bin/perl
#

use strict;
use lib "$ENV{'LJHOME'}/cgi-bin";
use Apache;
use Apache::LiveJournal;

Apache->httpd_conf("DocumentRoot $LJ::HOME/ssldocs");
Apache->httpd_conf("ServerAdmin $LJ::ADMIN_EMAIL")
    if $LJ::ADMIN_EMAIL;

Apache->httpd_conf(qq{

<IfModule mod_userdir.c>
  UserDir disabled
</IfModule>

PerlInitHandler +Apache::LiveJournal
PerlFixupHandler +Apache::CompressClientFixup
DirectoryIndex index.html index.bml
});

unless ($LJ::SERVER_TOTALLY_DOWN)
{
    Apache->httpd_conf(qq{
# BML support:
PerlModule Apache::BML
<Files ~ "\\.bml\$">
  SetHandler perl-script
  PerlHandler Apache::BML
</Files>

# User-friendly error messages
ErrorDocument 404 /404-error.html
ErrorDocument 500 /500-error.html

});
}

1;

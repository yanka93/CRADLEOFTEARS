To be used like:

RewriteEngine on
RewriteLock  /tmp/apache-rewrite.lock
RewriteLog   /var/log/apache/rewrite.log
RewriteLogLevel  0

RewriteMap    lb      prg:/home/lj/bin/rewrite-balance-intweb
RewriteRule   ^/(.*)$ http://${lb:$1}/$1           [NS,P,L]


Where rewrite-balance-intweb is like:

#!/usr/bin/perl

use FindBin qw($Bin);
exec("$Bin/rewrite-balancer", "-f", "$Bin/../cgi-bin/pool_int_web.txt");

And pool_int_web.txt is just one IP address per line.

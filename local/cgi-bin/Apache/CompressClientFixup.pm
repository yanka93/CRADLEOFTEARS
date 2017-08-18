# modified from: 
#    http://devl4.outlook.net/devdoc/Dynagzip/ContentCompressionClients.html

package Apache::CompressClientFixup;

use 5.004;
use strict;
use Apache::Constants qw(OK DECLINED);
use Apache::Log();
use Apache::URI();

use vars qw($VERSION);
$VERSION = "0.01";

sub handler {
    my $r = shift;
    return DECLINED unless $r->header_in('Accept-Encoding') =~ /gzip/io;

    my $no_gzip = sub { 
        $r->headers_in->unset('Accept-Encoding');
        return OK;
    };

    my $ua = $r->header_in('User-Agent');

    if ($r->protocol =~ /http\/1\.0/io) {
        # it is not supposed to be compressed:
        #  (but if request comes via mod_proxy, it'll be 1.1 regardless of what it actually was)
        return $no_gzip->();
    }
    if ($ua =~ /MSIE 4\./o) {
        return $no_gzip->() if 
            $r->method =~ /POST/io ||
            $r->header_in('Range') ||
            length($r->uri) > 245;
    }
    if ($ua =~ /MSIE 6\.0/o) {
        return $no_gzip->() if $r->parsed_uri->scheme =~ /https/io;
    }

    if ($r->header_in('Via') =~ /^1\.1\s/o ||  # MS Proxy 2.0
        $r->header_in('Via') =~ /^Squid\//o ||
        $ua =~ /Galeon\)/o ||
        $ua =~ /Mozilla\/4\.7[89]/o ||
        $ua =~ /Opera 3\.5/o ||
        $ua =~ /SkipStone\)/o) {
        return $no_gzip->();
    }

    if (($ua =~ /Mozilla\/4\.0/o) and (!($ua =~ /compatible/io))) {
        return $no_gzip->();
    }
}

1;

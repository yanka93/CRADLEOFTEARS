#!/usr/bin/perl -w
package try;
use strict;

BEGIN {
    use lib qw{lib};
    use MySQL::BinLog;
}

my %connect_params = (
    hostname        => 'whitaker.lj',
    database        => 'livejournal',
    user            => 'slave',
    password        => 'm&s',
    port            => 3337,
    debug           => 1,

    log_slave_id    => 512,
);

sub handler {
    my $ev = shift;
    print( ('-' x 70), "\n",
           ">>> QUERY: ", $ev->query_data, "\n",
           ('-' x 70), "\n" );
}

my $filename = shift @ARGV;

my $log = MySQL::BinLog->open( $filename );
#my $log = MySQL::BinLog->connect( %connect_params );

my @res = $log->handle_events( \&handler, MySQL::QUERY_EVENT );


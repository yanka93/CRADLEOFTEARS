#!/usr/bin/perl
use strict;
use Gearman::Util;
use IO::Socket::INET;
use Data::Dumper;
my $sock = IO::Socket::INET->new(PeerAddr => "localhost:7003")
    or die "no socket.";

my $send = sub {
    print $sock Gearman::Util::pack_req_command(@_);
};

my $err;
my $get = sub {
    return Gearman::Util::read_res_packet($sock, \$err);;
};

#$send->("submit_job_bg", join("\0", "add", "", "5,3"));
$send->("get_status", "FOO");
my $res = $get->() or die "no handle";
die "not a status_res packet" unless $res->{type} eq "status_res";

while (1) {
    $send->("submit_job", join("\0", "add", "-", "5,3"));
    $res = $get->() or die "no handle";
    print Dumper($res);
    die "not a job_created res" unless $res->{type} eq "job_created";

    while ($res = $get->()) {
        print "New packet: " . Dumper($res);
    }
    print "Error: $err\n";

    exit 0;

}





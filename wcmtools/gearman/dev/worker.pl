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
    my $res;
    while (1) {
        $res = Gearman::Util::read_res_packet($sock, \$err);
        return undef unless $res;
        return $res unless $res->{type} eq "noop";
    }
};

$send->("can_do", "frob");
$send->("cant_do", "frob");
$send->("can_do", "bar");
$send->("reset_abilities");

$send->("can_do", "add");

while (1) {
    $send->("grab_job");

    my $res = $get->();
    die "ERROR: $err\n" unless $res;
    print " res.type = $res->{type}\n";

    if ($res->{type} eq "error") {
        print "ERROR: " . Dumper($res);
        exit 0;
    }

    if ($res->{type} eq "no_job") {
        $send->("pre_sleep");

        print "Sleeping.\n";
        my $rin;
        vec($rin, fileno($sock), 1) = 1;
        my $nfound = select($rin, undef, undef, 2.0);
        print "  select returned = $nfound\n";
        next;
    }

    if ($res->{type} eq "job_assign") {
        my $ar = $res->{blobref};
        die "uh, bogus res" unless
            $$ar =~ s/^(.+)\0(.+)\0//;
        my ($handle, $func) = ($1, $2);

        print " GOT: handle=$handle, func=$func, args=($$ar)\n";
        if ($func eq "add") {
            for (1..10) {
                $send->("work_status", join("\0", $handle, $_, 10));
                select undef, undef, undef, 0.5;
            }
            my ($n1, $n2) = split(/,/, $$ar);
            $send->("work_complete", join("\0", $handle, $n1+$n2));
        }
        next;
    }

    print "RES: ", Dumper($res);

}




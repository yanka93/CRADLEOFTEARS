#!/usr/bin/perl
use strict;
use Gearman::Util;
use IO::Socket::INET;
my $sock = IO::Socket::INET->new(PeerAddr => "localhost:7003")
    or die "no socket.";

print $sock "gibberish_cmd\r\n";
my $res = <$sock>;
die "bogus response" unless $res =~ /^ERR unknown_command /;

my $cmd;

my $echo_val = "The time is " . time() . " \r\n and a null\0 is fun.";
print $sock Gearman::Util::pack_req_command("echo_req", $echo_val);

my $err;
my $res = Gearman::Util::read_res_packet($sock, \$err);
use Data::Dumper;
print "ERROR: $err\n";
print Dumper($res);



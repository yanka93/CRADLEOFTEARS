#!/usr/bin/perl

use strict;
use IO::Socket::INET;
use IO::Select;

my $port = 4446;
my $MAXLEN = 512;
my $BCAST_VER = 1;

eval { require "$ENV{'LJHOME'}/cgi-bin/ljlib.pl"; };

my $pool = shift @ARGV;
$pool ||= "int_web";

my $pool_file = "$ENV{'LJHOME'}/cgi-bin/pool_${pool}.txt";
die "Can't find pool file: $pool_file\n" unless -e $pool_file;
my @pool;
open (F, $pool_file) or die;
while (<F>) {
    chomp;
    push @pool, $_;
}
close F;

if ($LJ::FREECHILDREN_BCAST && 
    $LJ::FREECHILDREN_BCAST =~ /^(\S+):(\d+)$/) {
    $port = $2;
}

my $sock = IO::Socket::INET->new(Proto=>'udp',
                                 LocalPort=>$port)
    or die "couldn't create socket\n";
$sock->sockopt(SO_BROADCAST, 1);
$sock->blocking(0);
$|=1;

my $sel = IO::Select->new();
$sel->add($sock);

my $message;
my %servers;

sub dump_servers {
    my $now = time();
    print "----- Pool: $pool (\@$now) -----\n";
    foreach my $key (@pool) {
        my $s = $servers{$key};
        if ($s && $s->{_time} > $now - 10) {
            print "$key: free $s->{'free'}, active $s->{'active'}\n";
        } else {
            print "$key: ??\n";
        }
    }
}

sub parse_message {
    my ($sock, $message) = @_;
    my ($port, $ipaddr) = sockaddr_in($sock->peername);
    my $ip_text = inet_ntoa($ipaddr);
    delete $servers{$ip_text};

    my $host;
    foreach my $pair (split /\n/, $message) {
        $host->{$1} = $2 if $pair =~ /^(\S+)=(\S*)$/;
    }
    $host->{_time} = time();

    return unless $host->{bcast_ver} eq $BCAST_VER;
    $servers{$ip_text} = $host;
}

my $savedtime = 0;
while(1) {
    my $time = time();
    if ($time - $savedtime >=2) {
        dump_servers();
        $savedtime = $time;
    }
    my @ready = $sel->can_read(2);
    foreach my $fh (@ready) {
        if ($fh == $sock) {
            while($sock->recv($message, $MAXLEN)) {
                parse_message($sock, $message);
                last if time() - $savedtime >=2;
            }
        }
    }
}
            
        

#!/usr/bin/perl

# This tool is to be run from apache's mod_rewrite,
# not from command line.
# If there's an argument, it's taken to be a key
# in the $LJ::WEB_POOLS hash specifying the hosts which
# this balancer is to work with.

use strict;
use IO::Socket::INET;
use IO::Select;

my $port = 4446;
my $MAXLEN = 512;
my $BCAST_VER = 1;
my %allowed;   # ip_text -> 1  (if broadcasting server is in our watched pool)

eval { require "$ENV{'LJHOME'}/cgi-bin/ljlib.pl"; };

if ($LJ::FREECHILDREN_BCAST && 
    $LJ::FREECHILDREN_BCAST =~ /^(\S+):(\d+)$/) {
    $port = $2;
}

if ($ARGV[0] && $LJ::WEB_POOLS{$ARGV[0]}) {
    foreach (@{$LJ::WEB_POOLS{$ARGV[0]}}) {
        $allowed{$_} = 1;
    }
}

my $sock = IO::Socket::INET->new(Proto=>'udp',
                                 LocalPort=>$port)
    or die "couldn't create socket\n";
$sock->sockopt(SO_BROADCAST, 1);
$sock->blocking(0);
$|=1;

my $sel = IO::Select->new();
$sel->add(\*STDIN);
$sel->add($sock);

my %servers;  # ip_text -> { bcast_ver => 1 , free => \d+, active => \d+, _time => unix }
my %free;     # ip_text -> num_free
my $total_free = 0;

sub get_server {
    return "" unless $total_free;

    # delete servers that haven't reported back in a while
    my $now = time();
    my @del;
    while (my ($k, $v) = each %servers) {
        push @del, $k if $v->{_time} < $now - 20;
    }
    foreach (@del) { delete_server($_); }

    return "" unless $total_free;

    my $choice = rand($total_free);
    my $count = 0;
    while ($_ = each %free) {
        $count += $free{$_};
        if ($count >= $choice) { # can only happen if $free{$_}>0
            $total_free--;
            $free{$_}--;
            return $_;
        }
    }
    return "";
}

sub delete_server {
    my $key = shift;  # key = ip_text
    $total_free -= $free{$key} if $free{$key};
    delete $servers{$key};
    delete $free{$key};
}

sub parse_message {
    my ($sock, $message) = @_;
    my ($port, $ipaddr) = sockaddr_in($sock->peername);
    my $ip_text = inet_ntoa($ipaddr);
    return if %allowed and not $allowed{$ip_text};

    delete_server($ip_text);

    my $host;
    foreach my $pair (split /\n/, $message) {
        $host->{$1} = $2 if $pair =~ /^(\S+)=(\S*)$/;
    }
    $host->{_time} = time();
    
    return unless $host->{bcast_ver} eq $BCAST_VER;

    if ($host->{free}) {
        $servers{$ip_text} = $host;
        $free{$ip_text} = $host->{free};
        $total_free += $host->{free};
    }
    return;
}

my @backlog;  # unserviced uris, with trailing newlines

sub process_requests
{
    my $server;
    while (@backlog && ($server = get_server())) {
        my $uri = shift @backlog;
        print "http://$server/$uri";
    }
}

while(1) {
    my @ready = $sel->can_read();
    foreach my $fh (@ready) {
        if ($fh == $sock) {
            my $message;
            while($sock->recv($message, $MAXLEN)) {
                parse_message($sock, $message);
            }
            process_requests();
        }
        if ($fh == \*STDIN) {
            $_ = <STDIN>;
            push @backlog, $_;
            exit 1 if @backlog > 2000;  # something's horribly wrong
            process_requests();
        }
    }
}

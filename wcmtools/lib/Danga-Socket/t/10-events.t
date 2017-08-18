#!/usr/bin/perl -w

use strict;
use Test::More tests => 24;
use Danga::Socket;
use IO::Socket::INET;
use POSIX;

use vars qw($done);

Danga::Socket::init_poller();

SKIP: {
    my ($sysname, $nodename, $release, $version, $machine) = POSIX::uname();
    skip "not on linux 2.6", 1 if $^O ne "linux" || $version =~ /^2\.[01234]/;
    ok(Danga::Socket->HaveEpoll(), "using epoll");
}


for my $mode ("auto", "poll") {
    $done = 0;
    my $iters = 0;
    is(Danga::Socket->WatchedSockets, 0, "no watched sockets");
    Danga::Socket->SetLoopTimeout(150);
    Danga::Socket->SetPostLoopCallback(sub {
        return 0 if $done;
        $iters++;
        ok(Server->new, "created server") if $iters == 1;
        if ($iters == 3) {
            ok(ClientOut->new, "created client outgoing");
            is(Danga::Socket->WatchedSockets, 2, "two watched sockets");
        }
        return 1;
    });

    if ($mode eq "poll") {
        require IO::Poll;
        Danga::Socket->PollEventLoop;
    } else {
        Danga::Socket->EventLoop;
    }

    ok($done, "$mode mode is done");

    # check descriptor map status
    my $map = Danga::Socket->DescriptorMap;
    ok(ref $map eq "HASH", "map is hash");
    is(scalar keys %$map, 3, "watching 3 connections");
    Danga::Socket->Reset;
    is(scalar keys %$map, 0, "watching 0 connections");

}

ok(1, "finish");


package Server;
use base 'Danga::Socket';

sub new {
    my $class = shift;
    my $ssock = IO::Socket::INET->new(Listen    => 5,
                                      LocalAddr => 'localhost',
                                      LocalPort => 60000,
                                      Proto     => 'tcp',
                                      ReuseAddr => 1,
                                      Blocking => 0,
                                      );
    die "couldn't create socket" unless $ssock;
    IO::Handle::blocking($ssock, 0);
    my $self = $class->SUPER::new($ssock);
    $self->watch_read(1);
    return $self;
}

sub event_read {
    my $self = shift;
    while (my ($psock, $peeraddr) = $self->{sock}->accept) {
        IO::Handle::blocking($psock, 0);
        Test::More::ok($psock, "Server got incoming conn");
        ClientIn->new($psock);
    }
}

package ClientIn;
use base 'Danga::Socket';
use fields (
            'lines',  #[]
            );

sub new {
    my ($class, $sock) = @_;

    my $self = fields::new($class);
    $self->SUPER::new($sock);       # init base fields
    bless $self, ref $class || $class;
    $self->watch_read(1);
    $self->{lines} = [];
    return $self;
}

sub event_read {
    my $self = shift;
    my $bref = $self->read(5000);
    Test::More::ok($$bref eq "Hello!\n", "ClientIn got hello");
    $self->watch_read(0);
    $main::done = 1;
}


package ClientOut;
use base 'Danga::Socket';
use fields (
            'connected',  # 0 or 1
            );
use Socket qw(PF_INET IPPROTO_TCP SOCK_STREAM);

sub new {
    my $class = shift;

    my $sock;
    socket $sock, PF_INET, SOCK_STREAM, IPPROTO_TCP;

    die "can't create outgoing sock" unless $sock && defined fileno($sock);
    IO::Handle::blocking($sock, 0);
    connect $sock, Socket::sockaddr_in(60000, Socket::inet_aton('127.0.0.1'));

    my $self = fields::new($class);
    $self->SUPER::new($sock);
    bless $self, ref $class || $class;

    $self->{'connected'} = 0;

    $self->watch_write(1);
    return $self;
}

sub event_write {
    my $self = shift;
    if (! $self->{'connected'}) {
        Test::More::ok(1, "ClientOut connected");
        $self->{'connected'} = 1;
    }

    $self->write("Hello!\n");
    $self->watch_write(0);
}

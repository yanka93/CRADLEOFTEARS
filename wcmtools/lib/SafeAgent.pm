#!/usr/bin/perl
#
# SafeAgent: fetch HTTP resources with paranoia
#
# =head1 SYNOPSIS
#
#       my $sua = new SafeAgent;
#
#       $sua->fetch( $url, $max_amount[, $timeout[, $callback]])
#
#

package SafeAgent;
use strict;
use constant MB => 1024*1024;
use Socket;

use LWP::UserAgent;
use Carp qw{croak confess};
use URI ();

sub new {
    my $proto = shift or croak "Not a function";
    my $class = ref $proto || $proto;

    my $self = bless {
        realagent       => new LWP::UserAgent (),
        timeout         => 10,
        maxamount       => 1*MB,
        last_response   => undef,
        last_url        => undef,
    }, $class;

    return $self;
}

sub err {
    my $self = shift;
    $self->{lasterr} = shift if @_;
    return $self->{lasterr};
}

sub last_response {
    my $self = shift;
    return $self->{last_response};
}


sub last_url {
    my $self = shift;
    return $self->{last_url};
}


sub ret_err {
    my $self = shift;
    $self->{lasterr} = shift;
    return undef;
}


sub check_url {
    my $self = shift;
    my $url = shift;

    return $self->ret_err("BAD_SCHEME") unless $url =~ m!^https?://!;
    my $urio = URI->new($url);
    my $host = $urio->host;

    my $ip;
    if ($host =~ /^\d+\.\d+\.\d+\.\d+$/) {
        $ip = $host;
    } else {
        my ($name,$aliases,$addrtype,$length,@addrs) = gethostbyname($host);
        return $self->ret_err("BAD_HOSTNAME") unless @addrs;
        $ip = inet_ntoa($addrs[0]);
    }

    # don't connect to private or reserved addresses
    return $self->ret_err("BAD_IP") if
        ! $ip ||
        $ip =~ /^(?:10\.|127\.|192\.168\.)/ ||
        ($ip =~ /^172\.(\d+)/ && ($1 >= 16 && $1 <= 31)) ||
        ($ip =~ /^2(\d+)/ && ($1 >= 24 && $1 <= 54));

    return $urio;
}


sub fetch {
    my ($self, $url, $max_amount, $timeout, $callback) = @_;
    $timeout ||= $self->{timeout} || 10,
    $max_amount ||= $self->{maxamount} || 1*MB;

    my $urio = $self->check_url($url) or
        return undef;
    $self->{last_url} = $url;
    my $req = HTTP::Request->new('GET' => $url);

    my $hops = 0;
    my $ret;
    my $no_callback = ! $callback;
    $callback ||= sub {
        my($data, $response, $protocol) = @_;
        $ret .= $data;
    };

  HOP:
    while (1) {
        # print "Hop $hops.\n";
        $ret = "";

        my $size = 0;
        my $toobig = 0;
        my $ua = $self->{realagent};
        my $res;
        my $hard_timeout = 0;

      ALARM: eval {
            local $SIG{ALRM} = sub { $hard_timeout = 1; die "Hard timeout." };
            alarm( $self->{timeout} ) if $self->{timeout};
            $res = $ua->simple_request($req, sub {
                                           my($data, $response, $protocol) = @_;
                                           $size += length($data);
                                           $callback->($data, $response, $protocol);
                                           $toobig = 1 && die "TOOBIG" if $size > $max_amount;
                                       }, 10_000);
            alarm( 0 );
        };
        return $self->ret_err( "Hard timeout." ) if $hard_timeout;
        $self->{last_response} = $res;

        # If it's an error response, return failure unless it aborted due
        # to an overlarge document, in which case just return the chunk we
        # have so far. Also set the error value if it did overflow.
        if ( my $err = $res->headers->header('X-Died') ) {
            $self->err($err);
            return undef unless $err =~ m{TOOBIG};
            last HOP;
        } elsif ( $res->is_error ) {
            return $self->ret_err("HTTP_Error");
        } elsif ( $res->is_redirect ) {
            # follow redirect
            my $newurl = $res->headers->header('Location');
            return $self->ret_err("HOPCOUNT") if ++$hops > 1;
            # print "Redirect to '$newurl'\n";
            $urio = $self->check_url($newurl) or return undef;
            $self->{last_url} = $newurl;
            $req = HTTP::Request->new('GET' => $urio);
        } else {
            # print "Success.\n";
            $self->err( undef );
            last HOP;
        }
    } # end while

    return $no_callback ? $ret : 1;
}

sub agent {
    my $self = shift;
    my $old = $self->{realagent}->agent;
    if (@_) {
        my $agent = shift;
        $self->{realagent}->agent($agent);
    }
    return $old;
}

1;

#!/usr/bin/perl

package DMap;
use strict;
use Exporter;
use Storable;
use IO::Socket::INET;
use Gearman::Util;
use vars qw(@ISA @EXPORT);
@ISA = qw(Exporter);
@EXPORT = qw(dmap);

$Storable::Deparse = 1;
$Storable::Eval = 1;

our @js;

sub set_job_servers {
    @js = @_;
}

sub dmap (&@) {
    my $code = shift;
    my $fz = Storable::freeze($code);

    my $sock;
    foreach (@js) {
	$_ .= ":7003" unless /:/;
	$sock = IO::Socket::INET->new(PeerAddr => $js[0]);
	last if $sock;
    }
    die "No jobserver available" unless $sock;

    my $send = sub {
	print $sock Gearman::Util::pack_req_command(@_);
    };

    my $err;
    my $get = sub {
	return Gearman::Util::read_res_packet($sock, \$err);;
    };

    my $argc = scalar @_;
  ARG:
    foreach (@_) {
	$send->("submit_job", join("\0", "dmap", "", Storable::freeze([ $code, $_ ])));
    }

    my $waiting = $argc;
    my %handle;  # n -> handle
    my $hct = 0;
    my %partial_res;

    while ($waiting) {
	my $res = $get->()
	    or die "Failure: $err";

	if ($res->{type} eq "job_created") {
	    $handle{$hct} = ${$res->{blobref}};
	    $hct++;
	    next;
	}

	if ($res->{type} eq "work_complete") {
	    my $br = $res->{blobref};
	    $$br =~ s/^(.+?)\0//;
	    my $handle = $1;
	    $partial_res{$handle} = Storable::thaw($$br);
	    $waiting--;
	}
    }

    return map { @{ $partial_res{$handle{$_}} } } (0..$argc-1);
}


1;

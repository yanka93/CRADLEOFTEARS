#!/usr/bin/perl
#

use strict;
use lib "$ENV{'LJHOME'}/cgi-bin";
use Apache;
use Apache::FakeRequest ();
use Apache::BML;
use Benchmark;

my $benchmark = shift;  # times to run new code
my $bold = shift;       # times to run old code
$bold = $benchmark unless defined $bold;

my $r = Apache::FakeRequest->new(
                                 'filename' => "$ENV{LJHOME}/fake_root/bml-test.bml",
#                                 'filename' => "$ENV{LJHOME}/htdocs/foo.bml",
                                 'document_root' => "$ENV{LJHOME}/fake_root",
                                 'method' => "GET",
                                 'args' => "",
                                 'content' => "",
                                 'uri' => '/bml-test.bml',
#                                 'uri' => '/foo.bml',
                                 'header_only' => $benchmark ? 1 : 0,
                                 );

unless ($benchmark) {
#    *Apache::BML::bml_decode = \&Apache::BML::bml_decode_OLD;
#    *Apache::BML::load_elements = \&Apache::BML::load_elements_OLD;
    my $stat = Apache::BML::handler($r);
    die "bad init" unless $stat == 0;
    exit 0;
}

print "New code:\n";
timethis($benchmark, sub {
    my $stat = Apache::BML::handler($r);
});


if ($bold) {
    print "Old code:\n";
    *Apache::BML::bml_decode = \&Apache::BML::bml_decode_OLD;
    *Apache::BML::load_elements = \&Apache::BML::load_elements_OLD;
    timethis($bold, sub {
        my $stat = Apache::BML::handler($r);
    });
}





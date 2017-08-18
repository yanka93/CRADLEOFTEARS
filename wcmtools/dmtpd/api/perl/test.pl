#!/usr/bin/perl
#

use strict;
use MIME::Lite ();
use IO::File;
use IO::Socket::INET;

my $msg = new MIME::Lite ('From' => 'brad@danga.com (Brad Fitzpatrick)',
                          'To' => 'brad@danga.com (Fitz)',
                          'Cc' => 'brad@livejournal.com',
                          'Subject' => "Subjecto el Email testo",
                          'Data' => "word\n.\n\nthe end.\n");

my $as = $msg->as_string;
my $len = length($as);

my $sock = IO::Socket::INET->new(PeerAddr => 'localhost',
                                 PeerPort => '7005',
                                 Proto    => 'tcp');

my $message = "Content-Length: $len\r\nEnvelope-Sender: brad\@danga.com\r\n\r\n$as";

$sock->print("$message$message");

sleep 1;

$sock->print("Content-Len");
sleep 1;
$sock->print("gth: $len\r\nEnvelope-Sender: brad\@danga.com\r\n");
sleep 1;
$sock->print("\r\n${as}Content-Length: $len\r\nEnvelope-Sender: ");
sleep 1;
$sock->print("brad\@danga.com\r\n\r\n$as");

while ($_ = $sock->getline) {
    $_ =~ s/[\r\n]+$//;
    print "RES: $_\n";
}
$sock->close;



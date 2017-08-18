#!/usr/bin/perl
#

use strict;
use LWPx::ParanoidAgent;
use Time::HiRes qw(time);
use Test::More tests => 25;
use Net::DNS;
use IO::Socket::INET;

my ($t1, $td);
my $delta = sub { printf " %.03f secs\n", $td; };

my $ua = LWPx::ParanoidAgent->new;
ok((ref $ua) =~ /LWPx::ParanoidAgent/);

my ($HELPER_IP, $HELPER_PORT) = ("127.66.74.70", 9001);

my $child_pid = fork;
web_server_mode() if ! $child_pid;
select undef, undef, undef, 0.5;

my $HELPER_SERVER = "http://$HELPER_IP:$HELPER_PORT";


$ua->whitelisted_hosts(
                       $HELPER_IP,
                       );

$ua->blocked_hosts(
                   qr/\.lj$/,
                   "1.2.3.6",
                   );

my $res;

# hostnames pointing to internal IPs
$res = $ua->get("http://localhost-fortest.danga.com/");
ok(! $res->is_success && $res->status_line =~ /Suspicious DNS results/);

# random IP address forms
$res = $ua->get("http://0x7f.1/");
ok(! $res->is_success && $res->status_line =~ /blocked/);
$res = $ua->get("http://0x7f.0xffffff/");
ok(! $res->is_success && $res->status_line =~ /blocked/);
$res = $ua->get("http://037777777777/");
ok(! $res->is_success && $res->status_line =~ /blocked/);
$res = $ua->get("http://192.052000001/");
ok(! $res->is_success && $res->status_line =~ /blocked/);
$res = $ua->get("http://0x00.00/");
ok(! $res->is_success && $res->status_line =~ /blocked/);

# test the the blocked host above in decimal form is blocked by this non-decimal form:
$res = $ua->get("http://0x01.02.0x306/");
ok(! $res->is_success && $res->status_line =~ /blocked/);

# hostnames doing CNAMEs (this one resolves to "brad.lj", which is verboten)
my $old_resolver = $ua->resolver;
$ua->resolver(Net::DNS::Resolver->new(nameservers => [  qw(66.150.15.140) ] ));
$res = $ua->get("http://bradlj-fortest.danga.com/");
print $res->status_line, "\n";
ok(! $res->is_success);
$ua->resolver($old_resolver);

# black-listed via blocked_hosts
$res = $ua->get("http://brad.lj/");
print $res->status_line, "\n";
ok(! $res->is_success);

# can't do octal in IPs
$res = $ua->get("http://012.1.2.1/");
print $res->status_line, "\n";
ok(! $res->is_success);

# can't do decimal/octal IPs
$res = $ua->get("http://167838209/");
print $res->status_line, "\n";
ok(! $res->is_success);

# checking that port isn't affected
$res = $ua->get("http://brad.lj:80/");
print $res->status_line, "\n";
ok(! $res->is_success);

# this domain is okay.  bradfitz.com isn't blocked
$res = $ua->get("http://bradfitz.com/");
print $res->status_line, "\n";
ok(  $res->is_success);

# SSL should still work
$res = $ua->get("https://pause.perl.org/pause/query");
ok(  $res->is_success && $res->content =~ /Login|PAUSE|Edit/);

# internal. bad.  blocked by default by module.
$res = $ua->get("http://10.2.3.4/");
print $res->status_line, "\n";
ok(! $res->is_success);

# okay
$res = $ua->get("http://danga.com/temp/");
print $res->status_line, "\n";
ok(  $res->is_success);

# localhost is blocked, case insensitive
$res = $ua->get("http://LOCALhost/temp/");
print $res->status_line, "\n";
ok(! $res->is_success);

# redirecting to invalid host
$res = $ua->get("$HELPER_SERVER/redir/http://10.2.3.4/");
print $res->status_line, "\n";
ok(! $res->is_success);

# redirect with tarpitting
print "4 second redirect tarpit (tolerance 2)...\n";
$ua->timeout(2);
$res = $ua->get("$HELPER_SERVER/redir-4/http://www.danga.com/");
ok(! $res->is_success);

# lots of slow redirects adding up to a lot of time
print "Three 1-second redirect tarpits (tolerance 2)...\n";
$ua->timeout(2);
$t1 = time();
$res = $ua->get("$HELPER_SERVER/redir-1/$HELPER_SERVER/redir-1/$HELPER_SERVER/redir-1/http://www.danga.com/");
$td = time() - $t1;
$delta->();
ok($td < 2.5);
ok(! $res->is_success);

# redirecting a bunch and getting the final good host
$res = $ua->get("$HELPER_SERVER/redir/$HELPER_SERVER/redir/$HELPER_SERVER/redir/http://www.danga.com/");
ok( $res->is_success && $res->request->uri->host eq "www.danga.com");

# dying in a tarpit
print "5 second tarpit (tolerance 2)...\n";
$ua->timeout(2);
$res = $ua->get("$HELPER_SERVER/1.5");
ok(!  $res->is_success);

# making it out of a tarpit.
print "3 second tarpit (tolerance 4)...\n";
$ua->timeout(4);
$res = $ua->get("$HELPER_SERVER/1.3");
ok(  $res->is_success);

kill 9, $child_pid;


sub web_server_mode {
    my $ssock = IO::Socket::INET->new(Listen    => 5,
                                      LocalAddr => $HELPER_IP,
                                      LocalPort => $HELPER_PORT,
                                      ReuseAddr => 1,
                                      Proto     => 'tcp')
        or die "Couldn't start webserver.\n";

    while (my $csock = $ssock->accept) {
        exit 0 unless $csock;
        fork and next;

        my $eat = sub {
            while (<$csock>) {
                last if ! $_ || /^\r?\n/;
            }
        };

        my $req = <$csock>;
        print STDERR "    ####### GOT REQ:  $req" if $ENV{VERBOSE};

        if ($req =~ m!^GET /(\d+)\.(\d+) HTTP/1\.\d+\r?\n?$!) {
            my ($delay, $count) = ($1, $2);
            $eat->();
            print $csock
                "HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\n\r\n";
            for (1..$count) {
                print $csock "[$_/$count]\n";
                sleep $delay;
            }
            exit 0;
        }

        if ($req =~ m!^GET /redir/(\S+) HTTP/1\.\d+\r?\n?$!) {
            my $dest = $1;
            $eat->();
            print $csock
                "HTTP/1.0 302 Found\r\nLocation: $dest\r\nContent-Length: 0\r\n\r\n";
            exit 0;
        }

        if ($req =~ m!^GET /redir-(\d+)/(\S+) HTTP/1\.\d+\r?\n?$!) {
            my $sleep = $1;
            sleep $sleep;
            my $dest = $2;
            $eat->();
            print $csock
                "HTTP/1.0 302 Found\r\nLocation: $dest\r\nContent-Length: 0\r\n\r\n";
            exit 0;
        }

        print $csock
            "HTTP/1.0 500 Server Error\r\n" .
            "Content-Length: 10\r\n\r\n" .
            "bogus_req\n";
        exit 0;
    }
    exit 0;
}

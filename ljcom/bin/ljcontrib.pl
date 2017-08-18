#!/usr/bin/perl
# -*-perl-*-
# vim:ts=4:sw=4:et
#
# Tool to add/ack contributions on a livejournal server
#
# Gavin Mogan <halkeye@halkeye.net>
#
use strict;
use LWP::UserAgent;
use Digest::MD5 qw(md5_hex);
use Getopt::Long;
use URI::Escape;

my $CONFFILE = "$ENV{'HOME'}/.ljcontrib.conf";

my ($opt_help, $opt_type, $opt_zilla, $opt_url, $opt_ack );

exit 1 unless GetOptions('help' => \$opt_help,
                         'zilla|z=s' => \$opt_zilla,
                         'url|u=s' => \$opt_url,
                         'type|t=s' => \$opt_type,
                         'ack|a' => \$opt_ack,
                         );

if ($opt_help || (@ARGV == 0)) {
    print STDERR "Usage: ljcontrib.pl [opts] <user> <description>\n\n";
    print STDERR "Options:\n";
    print STDERR "    --ack                 Ack a contribution\n";
    print STDERR "    --zilla=<bug#>        [optional] What zilla bug is it for?\n";
    print STDERR "    --url=<url>           [optional] Supply a url for contribution\n";
    print STDERR "    --type=<type>         contrib type: code/doc/creative/biz/other\n";
    exit 1;
}

unless (-s $CONFFILE) {
    open (C, ">>$CONFFILE"); close C; chmod 0700, $CONFFILE;
    print "\nNo ~/.ljcontrib.conf config file found.\nFormat:\n\n";
    print "server: www.livejournal.com\n";
    print "username: test\n";
    print "password: test\n";
    exit 1;
}

my %conf;
open (C, $CONFFILE);
while (<C>) {
    next if /^\#/;
    next unless /\S/;
    chomp;
    next unless /^(\w+)\s*:\s*(.+)/;
    $conf{$1} = $2;
}
close C;
my $commands;

if ($opt_ack) {
    die "No ack #\n" unless @ARGV;
    my $ackno = $ARGV[0];  
    $commands = "command=" . uri_escape("contrib ack $ackno");
} else {
    die "URL and Zilla are mutually exclusive\n" if ($opt_url && $opt_zilla);
    
    if ($opt_type ne "code" && $opt_type ne "doc" && $opt_type ne "creative" &&
        $opt_type ne "biz"  && $opt_type ne "other")
    {
        $opt_type = "other"; # default to other
    }
           
    die "No user for ack\n" unless @ARGV;
    my $user = $ARGV[0];
    
    die "No description given\n" unless @ARGV == 2;
    my $desc = $ARGV[1];
    
    my $url = " ";
    
    $url .= $opt_url if ($opt_url);
    $url .= " http://zilla.livejournal.org/show_bug.cgi?id=$opt_zilla" if ($opt_zilla);

    $commands = "command=" . uri_escape("contrib add $user $opt_type \"$desc\"$url");
}


# Create a request
my $ua = LWP::UserAgent->new;
$ua->agent("Gavin_Contrib/0.1");
my $req = HTTP::Request->new('POST',"http://$conf{'server'}/interface/flat");
$req->content_type('application/x-www-form-urlencoded');
my $user = "user=" . uri_escape($conf{'username'});
my $pass = "hpassword=" . uri_escape(md5_hex($conf{'password'}));
my $mode = "mode=consolecommand";
my $clientversion = "clientversion=moocow/0.1";
my $data = join('&', $user,$pass,$mode,$commands, $clientversion);

$req->content($data);

my $res = $ua->request($req);

if ($res->is_error) { 
    die "Error posting to LJ server: " . $res->message . "\n";
}
my %ljres = split(/\n/, $res->content);

if ($ljres{'success'} ne "OK") {
    die "Error: " . $ljres{'errmsg'} . "\n";
}

if ($ljres{'cmd_line_1_type'} eq "error") {
    die "Error: " . $ljres{'cmd_line_1'} . "\n"; 
}

print "SUCCESS: contribution added.\n" unless ($opt_ack);
print "SUCCESS: contribution acked.\n" if ($opt_ack);

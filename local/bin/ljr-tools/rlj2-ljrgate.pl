#!/usr/bin/perl

use strict;
use XMLRPC::Lite;
use Digest::MD5 qw(md5_hex);
use DBI;
use Time::Local;
use lib "$ENV{'LJHOME'}/cgi-bin";

do $ENV{'LJHOME'} . "/cgi-bin/ljconfig.pl";
require "$ENV{'LJHOME'}/cgi-bin/ljlib.pl";
use LJR::Viewuserstandalone;
use LJR::Gate;
use LJR::Distributed;

#
#Настройки
#

#Свойства соединения с базой
my $qhost = $LJ::DBINFO{'master'}->{'host'};
my $quser = $LJ::DBINFO{'master'}->{'user'};
my $qpass = $LJ::DBINFO{'master'}->{'pass'};
my $qsock = $LJ::DBINFO{'master'}->{'sock'};
my $qport = $LJ::DBINFO{'master'}->{'port'};

my $dbh = DBI->connect(
  "DBI:mysql:mysql_socket=$qsock;hostname=$qhost;port=$qport;database=prod_ljgate",
  $quser, $qpass, ) || die  localtime(time) . ": Can't connect to database\n";

my $dbhljr = DBI->connect(
  "DBI:mysql:mysql_socket=$qsock;hostname=$qhost;port=$qport;database=prod_livejournal",
  $quser, $qpass, ) || die  localtime(time) . ": Can't connect to database\n";

my $get_our = sub {
  my ($userid) = @_;
  my $sqh = $dbh->prepare("SELECT * FROM our_user where userid=?");
  $sqh->execute($userid);
  my $res = $sqh->fetchrow_hashref;
  $sqh->finish;
  return $res;
};

my $get_alien = sub {
  my ($userid) = @_;
  my $sqh = $dbh->prepare("SELECT * FROM alien where alienid=?");
  $sqh->execute($userid);
  my $res = $sqh->fetchrow_hashref;
  $sqh->finish;
  return $res;
};

my $get_lj_user = sub {
  my ($user) = @_;
  $user =~ s/\-/\_/g;
  my $sqh = $dbhljr->prepare("SELECT * FROM user where user=?");
  $sqh->execute($user);
  my $res = $sqh->fetchrow_hashref;
  $sqh->finish;
  return $res;
};

my $count_gated_records = sub {
  my ($userid) = @_;
  my $sqh = $dbh->prepare("SELECT count(*) FROM rlj_lj_id where userid=?");
  $sqh->execute($userid);
  my ($res) = $sqh->fetchrow_array;
  $sqh->finish;
  return $res;
};

my $sqh = $dbh->prepare("SELECT userid,alienid FROM rlj2lj");
$sqh->execute;
my $result;
while ($result = $sqh->fetchrow_hashref) {
  my $our = $get_our->($result->{'userid'});
  my $alien = $get_alien->($result->{'alienid'});

  if ($our && $alien && $alien->{'alienpass'}) {
    my $ljuser = $get_lj_user->($our->{'our_user'});
    
    my $ru = LJR::Distributed::get_remote_server("www.livejournal.com");
    die $ru->{"errtext"} if $ru->{"err"};
    $ru->{'username'} = $alien->{'alien'};
    $ru = LJR::Distributed::get_cached_user($ru);
    die $ru->{"errtext"} if $ru->{"err"};

    print
      $our->{'our_user'} .
      " -> " .
      $alien->{'alien'} . " ($ru->{'ru_id'}) " . "pass: " . $alien->{'alienpass'} .
      "\n"
      ;
    
    my $r = LJR::Distributed::update_export_settings($our->{'our_user'}, $ru->{'ru_id'}, $alien->{'alienpass'});
    die $r->{'errtext'} if $r->{'err'};

    if ($ljuser) {
      print "ljr id: " . $ljuser->{'userid'};
    }
    else {
      print "ljr id: error";
    }
    print "; ";
    
    my $gated_records = $count_gated_records->($our->{'userid'});
    print $gated_records;
    
    print "\n";
#    my $xmlrpc = LJR::Gate::Authenticate ("www.livejournal.com",
#      $alien->{'alien'}, $alien->{'alienpass'});
#    if ($xmlrpc->{'err_text'}) {
#      print "err\n";
#    }
#    else {
#      print "ok\n";
#    }
  }
  else {
    print
      $result->{'userid'} . "($our->{'our_user'})" . " -> " .
      $result->{'alienid'} . "($alien->{'alien'})" . "\n"
      ;
  }
}
$sqh->finish;
$dbh->disconnect;
$dbhljr->disconnect;

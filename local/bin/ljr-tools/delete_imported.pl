#!/usr/bin/perl

use strict;

require "$ENV{'LJHOME'}/cgi-bin/ljlib.pl";
require "$ENV{'LJHOME'}/cgi-bin/talklib.pl";


# remote user id of user to clean
my $ru_id = 27850;

# database connection
my $queue_db = "livejournal";
my $queue_host = "localhost";
my $queue_login = "lj";
my $queue_pass = "lj-upyri";


use strict; # preventing my program from doing bad things
use DBI; # http://dbi.perl.org

$| = 1; # unbuffered (almost) output

my $dbh = DBI->connect(
  "DBI:mysql:$queue_db:$queue_host",
  $queue_login, $queue_pass,
  {RaiseError => 0, AutoCommit => 1}
  ) || die "Can't open database connection: $DBI::errstr";

my $sth = $dbh->prepare("select * from ljr_remote_users where ru_id = $ru_id");
$sth->execute;
while (my $row = $sth->fetchrow_hashref) {
  if (! $row->{ru_id}) {
    die "User not found.\n";
  }

  my $sth1 = $dbh->prepare("select * from ljr_cached_users where ru_id = $ru_id");
  $sth1->execute();
  my $row1 = $sth1->fetchrow_hashref;

  print
    "You're about to delete user [" .
    $row1->{remote_username} . "].\n" .
    "Please confirm by typing their username: "
    ;
  while (<>) {
    my $iu = $_;
    if ($iu =~ /\s*(.*)\s*/) { $iu = $1; }
    if ($iu ne $row1->{remote_username}) {
      die "You have to learn to type letters to use this tool.\n";
    }
    last;
  }
  $sth1->finish;

  print "deleting cached comprops and remote comments...\n";
  $sth1 = $dbh->prepare("select * from ljr_cached_comments where ru_id = $ru_id");
  $sth1->execute();
  while ($row1 = $sth1->fetchrow_hashref) {
    my $sth2 = $dbh->prepare("delete from ljr_cached_comprops where cc_id = " . $row1->{cc_id});
    $sth2->execute();
    $sth2->finish;
    
    $sth2 = $dbh->prepare("delete from ljr_remote_comments where cc_id = " . $row1->{cc_id});
    $sth2->execute();
    $sth2->finish;
    
    print ".";
  }
  $sth1->finish;

  print "deleting cached comments...\n";
  $sth1 = $dbh->prepare("delete from ljr_cached_comments where ru_id = $ru_id");
  $sth1->execute();
  $sth1->finish;
  
  print "deleting ljr_cached_userpics...\n";
  $sth1 = $dbh->prepare("delete from ljr_cached_userpics where ru_id = $ru_id");
  $sth1->execute();
  $sth1->finish;
  
  print "deleting ljr_cached_users...\n";
  $sth1 = $dbh->prepare("delete from ljr_cached_users where ru_id = $ru_id");
  $sth1->execute();
  $sth1->finish;
  
  print "deleting local entries...\n";
  my $lu;
  $sth1 = $dbh->prepare("select * from ljr_remote_entries where ru_id = $ru_id");
  $sth1->execute();
  while ($row1 = $sth1->fetchrow_hashref) {
    $lu = LJ::load_userid($row1->{"local_journalid"}) unless $lu;
    LJ::delete_entry($lu, $row1->{"local_jitemid"});
  }
  $sth1->finish;

  print "deleting ljr_remote_entries...\n";
  $sth1 = $dbh->prepare("delete from ljr_remote_entries where ru_id = $ru_id");
  $sth1->execute();
  $sth1->finish;

  print "deleting ljr_remote_userpics...\n";
  $sth1 = $dbh->prepare("delete from ljr_remote_userpics where ru_id = $ru_id");
  $sth1->execute();
  $sth1->finish;
}
$sth->finish;

$sth = $dbh->prepare("delete from ljr_remote_users where ru_id = $ru_id");
$sth->execute;
$sth->finish;

$dbh->disconnect;

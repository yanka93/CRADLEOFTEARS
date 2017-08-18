#!/usr/bin/perl

# remote user id of user to clean
my $ru_id = 491;

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
  if ($row->{created_comments_maxid} > 0) {
    die "User has created comments. Cannot clean cached comments (IMPLEMENT THIS!)\n";
  }

  my $sth1 = $dbh->prepare("select * from ljr_cached_users where ru_id = $ru_id");
  $sth1->execute();
  my $row1 = $sth1->fetchrow_hashref;

  print
    "You're about to delete cached comments for user [" .
    $row1->{remote_username} . "].\n" .
    "Please confirm by typing their username: "
    ;
  while (<>) {
    my $iu = $_;
    
    if ($iu =~ /\s*(.*)\s*/) {
      $iu = $1;
    }

    if ($iu ne $row1->{remote_username}) {
      die "You have to learn to type letters to use this tool.\n";
    }
    last;
  }
  $sth1->finish;

  print "deleting cached comprops...\n";
  $sth1 = $dbh->prepare("select * from ljr_cached_comments where ru_id = $ru_id");
  $sth1->execute();
  while ($row1 = $sth1->fetchrow_hashref) {
    my $sth2 = $dbh->prepare(
      "delete from ljr_cached_comprops where cc_id = " . $row1->{cc_id}
      );
    $sth2->execute();
    $sth2->finish;
    print ".";
  }
  $sth1->finish;

  print "deleting cached comments...\n";
  $sth1 = $dbh->prepare(
    "delete from ljr_cached_comments where ru_id = " . $ru_id
      );
  $sth1->execute();
  $sth1->finish;

  print "resetting cached counters...\n";
  $sth1 = $dbh->prepare(
    "update ljr_cached_users
     set remote_meta_maxid = 0, cached_comments_maxid = 0
     where ru_id = " . $ru_id);
  $sth1->execute();
  $sth1->finish;
}
$sth->finish;

$dbh->disconnect;

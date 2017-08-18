#!/usr/bin/perl

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


my $username;
my $new_identity;

my $sth = $dbh->prepare(
  "select * from identitymap where idtype='O' and identity like 'http://www.livejournal.com/%'");
$sth->execute;
while (my $row = $sth->fetchrow_hashref) {
  $username = "";

  if ($row->{"identity"} =~ /\/users\/(.+[^\/])\/??/ || $row->{"identity"} =~ /\/\~(.+[^\/])\/??/) {
    my $new_id;
    my $old_email;
    my $new_email;
    my $sth2;

    $username = $1;
    $new_identity = "";

    if ($username =~ /^_/ || $username =~ /_$/) {
      $new_identity = "http://users.livejournal.com/" . $username . "/";
    }
    else {
      $new_identity = "http://" . $username . ".livejournal.com/";
    }

    $sth2 = $dbh->prepare("select email from user where userid = " . $row->{"userid"});
    $sth2->execute;
    if (my $row1 = $sth2->fetchrow_hashref) {
      $old_email = $row1->{"email"};
    }
    $sth2->finish;

    $sth2 = $dbh->prepare(
      "select * from identitymap where idtype='O' and identity ='" . $new_identity . "'");
    $sth2->execute();
    if (my $row1 = $sth2->fetchrow_hashref) {
      $new_id = $row1->{"userid"};

      my $sth3 = $dbh->prepare("select email from user where userid = " . $new_id);
      $sth3->execute;
      if (my $row2 = $sth3->fetchrow_hashref) {
        $new_email = $row2->{"email"};
      }
      $sth3->finish;

      print
        $username . "(" .
        $row->{"userid"} . ", " . $old_email . "):(" .
        $new_id . "," . $new_email . ")\n";
    }
    $sth2->finish;

    if (!$new_id) {
      $sth2 = $dbh->prepare(
        "update identitymap set identity = '" . $new_identity . "' " .
        "where idtype='O' and userid = " . $row->{"userid"}
        );
      $sth2->execute();
      $sth2->finish;
    }
    else {
      if (!$new_email) {
        $sth2 = $dbh->prepare("update user set email = '" . $old_email . "' " .
          "where userid = " . $new_id);
        $sth2->execute();
        $sth2->finish;
      }
    }
  }
}
$sth->finish;

$dbh->disconnect;

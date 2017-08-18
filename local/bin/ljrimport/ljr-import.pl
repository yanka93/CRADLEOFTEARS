#!/usr/bin/perl -w

package LJR::Import;

use strict; # preventing my program from doing bad things
use DBI; # http://dbi.perl.org
use POSIX ();

do $ENV{'LJHOME'} . "/cgi-bin/ljconfig.pl";

my $qhost = $LJ::DBINFO{'master'}->{'host'};
my $quser = $LJ::DBINFO{'master'}->{'user'};
my $qpass = $LJ::DBINFO{'master'}->{'pass'};
my $qdb = $LJ::DBINFO{'master'}->{'dbname'};
my $qsock = $LJ::DBINFO{'master'}->{'sock'};
my $qport = $LJ::DBINFO{'master'}->{'port'};

$| = 1; # unbuffered (almost) output

# global database handle
$LJR::Import::global_dbh = 0;
# global shutdown request received flag
$LJR::Import::cool_stop = 0;

my $history_id;

# POSIX unmasks the sigprocmask properly
my $sigset = POSIX::SigSet->new();
my $action = POSIX::SigAction->new(
  'LJR::Import::sigTERM_handler', $sigset, &POSIX::SA_NODEFER);

POSIX::sigaction(&POSIX::SIGTERM, $action);

sub log_print {
  my $msg = shift;
  my $t = `date +"%D %T"`;
  print substr($t, 0, length($t) - 1) . " $msg\n";
}

sub sigTERM_handler {
  my $t = `date +"%D %T"`;
  print substr($t, 0, length($t) - 1) . " ljr-import.pl: received shutdown request\n";
  $LJR::Import::cool_stop = 1;
}

# configuration
my $speed_throttle = 10; # seconds

print "\n";

LJR::Import::log_print("started");

# main loop, throttled
while (!process_exit()) {
  process_queue(); # process new requests for import if any
  sleep ($speed_throttle); # sleep for a while
}

LJR::Import::log_print("ljr-import.pl: shutting down due to safe shutdown request");

sub import_log {
  my ($istatus) = @_;

  my $sth2 = $LJR::Import::global_dbh->prepare (
    "update ljr_ihistory set
      istatus = ?,
      idate = now()
      where importid = ?");
  $sth2->execute($istatus, $history_id);
  $sth2->finish;
}

sub process_exit {
  return ($LJR::Import::cool_stop);
}

sub process_queue {
  my $row;
  my $row1;
  my $sth2;
  my $e;
  
  $LJR::Import::global_dbh = DBI->connect(
     "DBI:mysql:mysql_socket=$qsock;hostname=$qhost;port=$qport;database=$qdb",
      $quser, $qpass,
      {RaiseError => 0, AutoCommit => 1}
    ) || die "Can't open database connection: $DBI::errstr";

  my $sth = $LJR::Import::global_dbh->prepare("SELECT * from ljr_iqueue order by priority, importid");
  $sth->execute;

  while (($row = $sth->fetchrow_hashref) && !process_exit()) {
    my $r = system ("nice -n 19 ./ljr-importdo.pl");
    if ($r != 0) {
      $sth->finish;
      $LJR::Import::global_dbh->disconnect;
      return;
    }

    sleep($speed_throttle); # do not hurry
    $sth->execute; # refresh the query
  }
  $sth->finish;

  $LJR::Import::global_dbh->disconnect;
}

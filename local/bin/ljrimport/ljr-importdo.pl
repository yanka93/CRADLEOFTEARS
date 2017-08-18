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


require "ijournal.pl";
require "icomments.pl";

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
  print substr($t, 0, length($t) - 1) . " ljr-import-do.pl: received shutdown request\n";
  $LJR::Import::cool_stop = 1;
}

# configuration
my $speed_throttle = 10; # seconds


process_queue_alone(); # there must be something there!
if (process_exit()) {
  exit 1;
}
else {
  exit 0;
}

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

sub process_queue_alone {
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
    my $sth1 = $LJR::Import::global_dbh->prepare (
      "SELECT * from ljr_iqueue where
         local_user = '" . $row->{'local_user'} . "'
         order by local_user desc, importid desc limit 1");
    $sth1->execute; # find last user request for import
    $row = $sth1->fetchrow_hashref;

    # create history record
    $sth2 = $LJR::Import::global_dbh->prepare (
      "insert into ljr_ihistory values ('',?,?,'',?,?,?,?,now(),'STARTED',now())");
    $sth2->execute (
      $row->{'remote_site'}, $row->{'remote_user'}, $row->{'remote_protocol'},
      $row->{'local_user'}, $row->{'opt_overwrite'}, $row->{'opt_comments'}
      ); # save import history (parameters, time when started)
    
    $history_id = $LJR::Import::global_dbh->selectrow_array("SELECT LAST_INSERT_ID()");
    $sth2->finish;

    LJR::Import::log_print(
      $row->{'local_user'} . " <- " .
      $row->{'remote_site'} . "::" . $row->{'remote_user'} .
      " (entries)"
      );

    $e = "";
    $e = import_journal(
      0,                        # throttle_speed (seconds)
      $row->{'remote_site'},    # remote_site
      $row->{'remote_protocol'},# remote_protocol
      $row->{'remote_user'},    # remote_user
      $row->{'remote_pass'},    # remote_pass
      "",                       # remote shared journal (if any)
      $row->{'local_user'},     # local_user
      "",                       # local shared journal (if any)
      $row->{'opt_overwrite'}   # overwrite entries
      );

    if ($row->{'opt_comments'} && (!$e || !$e->{'err'})) {
      LJR::Import::log_print(
        $row->{'local_user'} . " <- " .
        $row->{'remote_site'} . "::" . $row->{'remote_user'} .
        " (caching comments)"
        );

      $e = get_comments(
        $row->{'remote_site'},
        $row->{'remote_user'},
        $row->{'remote_pass'},
        1);

      if (!$e || !$e->{'err'}) {
        LJR::Import::log_print(
          $row->{'local_user'} . " <- " .
          $row->{'remote_site'} . "::" . $row->{'remote_user'} .
          " (creating comments)");

        $e = create_imported_comments (
          $row->{'remote_site'},
          $row->{'remote_user'},
          $row->{'local_user'});
      }
    }

    if ($e->{'err'}) {
      $sth2 = $LJR::Import::global_dbh->prepare (
        "update ljr_ihistory " .
	"set remote_pass = '" . $row->{'remote_pass'} . "' " .
        "where importid = " . $history_id . " ;"
        );
      $sth2->execute; # save remote pass for debugging purposes
      $sth2->finish;

      my $boo = $e->{errtext};
      $boo =~ s/\n//;

      LJR::Import::log_print(
        $row->{'local_user'} . " <- " .
        $row->{'remote_site'} . "::" . $row->{'remote_user'} . " " . $boo
        );

      import_log($e->{errtext});
    }
    else {
      $sth2 = $LJR::Import::global_dbh->prepare (
        "update ljr_ihistory " .
	"set remote_pass = '' " .
        "where remote_site = '" . $row->{'remote_site'} . "' and " .
	"remote_user = '" . $row->{'remote_user'} . "' ;"
        );
      $sth2->execute; # remove remote pass since the journal was imported successfully
      $sth2->finish;

      LJR::Import::log_print(
        $row->{'local_user'} . " <- " .
        $row->{'remote_site'} . "::" . $row->{'remote_user'} .
        ": successful"
        );

      if ($e->{'warns'}) {
        import_log("SUCCESSFUL, but " . $e->{'warns'});
      }
      else {
        import_log("SUCCESSFUL");
      }
    }
        
    $sth1 = $LJR::Import::global_dbh->prepare (
      "delete from ljr_iqueue " .
      "where local_user = '" . $row->{'local_user'} . "'"
      ); # empty all the user's request after processing last one
    $sth1->execute;
    $sth1->finish;

    $sth->finish;

# we're quitting!
#    if (process_exit()) {
      $LJR::Import::global_dbh->disconnect;
      return;
#    }
  }
  $sth->finish;

  $LJR::Import::global_dbh->disconnect;
}

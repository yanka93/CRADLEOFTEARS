#!/usr/bin/perl -w

package Golem;

use strict;

require "$ENV{'LJHOME'}/cgi-bin/Golem/dblib.pl";
require "$ENV{'LJHOME'}/cgi-bin/Golem/loglib.pl";
require "$ENV{'LJHOME'}/cgi-bin/Golem/netlib.pl";
require "$ENV{'LJHOME'}/cgi-bin/Golem/proplib.pl";
require "$ENV{'LJHOME'}/cgi-bin/Golem/textlib.pl";

# *** LJR apis conversion layer
#
# check out

our $on = 1;
our $counter_prefix = "golem_";

sub get_db {
  return LJ::get_db_writer();
}

# Golem tags are not ported to LJR
sub unset_row_tag {
	return 1;
}
# *** LJR apis conversion layer

sub get_callstack {
  my $cstack;
  my $i = 0;
  while ( 1 ) {
    my $tfunc = (caller($i))[3];
    if ($tfunc && $tfunc ne "") {
      if ($tfunc !~ /\_\_ANON\_\_/ &&
        $tfunc !~ /.*::get_callstack/) {
        $cstack .= "\t" . $tfunc . "\n";
      }
      $i = $i + 1;
    }
    else {
      last;
    }
  }
  return "\nCallstack:\n" . $cstack . "\n";
}

sub err {
  if (ref($_[0])) {
    my $dbh = shift;
    $dbh->rollback;
  }

  my $errstr = shift || "";
  my $previous_object;

  if (ref($_[0]) eq 'HASH') {
    $previous_object = shift;
  }

  if ($previous_object) {
    $previous_object->{'err'} = 1;
    $previous_object->{'errstr'} = $errstr . Golem::get_callstack();

    return $previous_object;
  }
  else {
    my %res = (
      "err" => 1,
      "errstr" => $errstr . Golem::get_callstack(),
      );
  
    return \%res;
  }
}

sub die {
  my ($message, $suppress_callstack) = @_;

  print STDERR "$message";

  unless ($suppress_callstack) {
    print STDERR Golem::get_callstack();
  }
  else {
    print "\n";
  }

  exit 1;
}


1;

#!/usr/bin/perl -w
#
# converts s1usercache and s1stylecache blob fields
# which store Storable::freeze data from ::freeze to ::nfreeze
#
# 14oct07 petya@nigilist.ru
# initial revision
#

sub convert {
  my ($dbh, $table, $unique, $field) = @_;
  
  print "convert $table.$field ($unique)\n";

  my $sql = "select * from $table;";

  my $sth = $dbh->prepare($sql) or die "preparing: ", $dbh->errstr;
  $sth->execute or die "executing: ", $dbh->errstr;

  while (my $row = $sth->fetchrow_hashref) {
    if ($row->{"$field"}) {
      my $obj = Storable::thaw($row->{"$field"});
      if ($obj) {
        print $row->{"$unique"} . "\n";
        $dbh->do("UPDATE $table SET $field=? WHERE $unique=?", undef,
          Storable::nfreeze($obj), $row->{"$unique"}) ||
	  die "Error updating $table. Unique id: " . $row->{"$unique"} . "\n";
      }
    }
  }
  print "\n";
}

use strict;
use DBI;
use Storable;

$ENV{'LJHOME'} = "/home/lj-admin";
do $ENV{'LJHOME'} . "/lj/cgi-bin/ljconfig.pl";
my $host = $LJ::DBINFO{'master'}->{'host'};
my $user = $LJ::DBINFO{'master'}->{'user'};
my $pwd = $LJ::DBINFO{'master'}->{'pass'};
my $db = "prod_livejournal";

$| = 1; # turn off buffered output

# connect to the database.
my $dbh = DBI->connect( "DBI:mysql:mysql_socket=/tmp/mysql.sock;hostname=$host;port=3306;database=$db", $user, $pwd)
  or die "Connecting : $DBI::errstr\n ";

#convert ($dbh, "s1stylecache", "styleid", "vars_stor");
#convert ($dbh, "s1usercache", "userid", "color_stor");
#convert ($dbh, "s1usercache", "userid", "override_stor");

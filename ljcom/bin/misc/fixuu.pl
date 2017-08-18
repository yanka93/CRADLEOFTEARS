#!/usr/bin/perl
#

require "$ENV{'LJHOME'}/cgi-bin/ljlib.pl";

my $dbh = LJ::get_db_writer();
my $dbslo = LJ::get_dbh("slow");
die "no slow" unless $dbslo;

my $sth = $dbslo->prepare("select u.userid from user u left join userusage uu on u.userid=uu.userid where uu.userid is null");
$sth->execute;
while (my $userid = $sth->fetchrow_array)
{
    print "$userid...\n";
    my $u = LJ::load_userid($userid);
    die unless $u;

    print "Find timeupdate...\n";
    my $timeupdate;
    my $dbcr = LJ::get_cluster_reader($u);
    $timeupdate = $dbcr->selectrow_array("SELECT logtime FROM log2 WHERE journalid=$u->{'userid'} AND rlogtime>0 ORDER BY journalid, rlogtime");
    die $dbcr->errstr if $dbcr->err;
    $timeupdate = $dbh->quote($timeupdate);

    print "BS a time create...\n";
    my $timecreate;
    my $puserid = $u->{'userid'};
    while (not defined $timecreate) {
	$puserid--;
	print "  trying $puserid\n";
	$timecreate = $dbslo->selectrow_array("SELECT DATE_ADD(timecreate, INTERVAL 10 MINUTE) FROM userusage WHERE userid=$puserid");
    }
    $timecreate = $dbh->quote($timecreate);

    my $sql = "INSERT INTO userusage VALUES ($u->{'userid'}, $timecreate, $timeupdate, NULL, 0)";
    print "$sql\n";
    $dbh->do($sql);
}

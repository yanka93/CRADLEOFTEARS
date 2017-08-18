#!/usr/bin/perl
#

$maint{'stats_makemarkers'} = sub 
{
    my $dbr = LJ::get_db_reader();

    my ($sth);
    
    open (MARK, ">${STATSDIR}/markers.txt");

    # FIXME: this is broken.  zip is a userprop now.
    $sth = $dbr->prepare("CREATE TEMPORARY TABLE tmpmarkzip SELECT DISTINCT zip FROM user WHERE country='US' and zip<>''");
    $sth->execute;
    $sth = $dbr->prepare("SELECT z.lon, z.lat FROM zips z, tmpmarkzip t WHERE t.zip=z.zip");
    $sth->execute;
    while (my ($lon, $lat) = $sth->fetchrow_array) {
        print MARK "$lat -$lon \"\" color=white # \n";
    }
    $sth->finish;
    close (MARK);
};

1;

#!/usr/bin/perl
#

$maint{'clean_intdups'} = sub 
{
    my $dbh = LJ::get_dbh("master");
    my ($sth);
    my @dups;

    print "-I- Cleaning duplicates.\n";
    foreach my $let ('a'..'z', '0'..'9')
    {
        print "-I- Letter $let\n";
        $sth = $dbh->prepare("SELECT interest, COUNT(*) AS 'count' FROM interests WHERE interest LIKE '$let%' GROUP BY 1 HAVING count > 1");
        $sth->execute;
        while (($interest, $count) = $sth->fetchrow_array)
        {
            print "    $interest has $count\n";
            push @dups, $interest;
        }
    }
    
    foreach my $dup (@dups) {
        print "Fixing: $dup\n";
        my $min = 0;
        my @fix = ();
        my $qdup = $dbh->quote($dup);
        $sth = $dbh->prepare("SELECT intid FROM interests WHERE interest=$qdup ORDER BY intid");
        $sth->execute;
        while (my ($id) = $sth->fetchrow_array) {
            if ($min) { push @fix, $id; }
            else { $min = $id; }
        }
        if (@fix) {
            my $in = join(",", @fix);

            # change duplicate interests to the minimum, ignoring duplicates.
            $sth = $dbh->prepare("UPDATE IGNORE userinterest SET intid=$min WHERE intid IN ($in)");
            $sth->execute;

            # delete ones that had duplicate key conflicts and didn't change
            $sth = $dbh->prepare("DELETE FROM userinterest WHERE intid IN ($in)");
            $sth->execute;
            
            # update the intcount column
            $sth = $dbh->prepare("REPLACE INTO interests (intid, interest, intcount) SELECT intid, $qdup, COUNT(*) FROM userinterests WHERE intid=$min GROUP BY 1, 2");
            $sth->execute;

            # delete from interests table
            $sth = $dbh->prepare("DELETE FROM interests WHERE intid IN ($in)");
            $sth->execute;
        }
        print "  @fix --> $min\n";

    }
    
};

$maint{'clean_intcounts'} = sub 
{
    my $dbh = LJ::get_dbh("master");
    my ($sth);
    
    $sth = $dbh->prepare("SELECT MAX(intid) FROM userinterests");
    $sth->execute;
    my ($max) = $sth->fetchrow_array;

    print "Fixing intcounts, up to intid=$max\n";
    for (my $i=1; $i < $max; $i += 5000)
    {
        my $low = $i;
        my $high = $i+4999;
        print "$low..$high:\n";
        $sth = $dbh->prepare("SELECT ui.intid, i.intcount, COUNT(*) AS 'count' FROM userinterests ui, interests i WHERE i.intid=ui.intid AND ui.intid BETWEEN $low AND $high GROUP BY 1, 2 HAVING i.intcount<>COUNT(*)");
        $sth->execute;
        while (my ($intid, $wrong, $count) = $sth->fetchrow_array) {
            print "  $intid: $count, not $wrong\n";
            $dbh->do("UPDATE interests SET intcount=$count WHERE intid=$intid");
        }
    }

};

1;

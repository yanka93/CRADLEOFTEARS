#!/usr/bin/perl
#

$maint{'clean_caches'} = sub 
{
    my $dbh = LJ::get_db_writer();
    my $sth;

    my $verbose = $LJ::LJMAINT_VERBOSE;

    print "-I- Cleaning authactions.\n";
    $dbh->do("DELETE FROM authactions WHERE datecreate < DATE_SUB(NOW(), INTERVAL 30 DAY)");

    print "-I- Cleaning faquses.\n";
    $dbh->do("DELETE FROM faquses WHERE dateview < DATE_SUB(NOW(), INTERVAL 7 DAY)");

    print "-I- Cleaning duplock.\n";
    $dbh->do("DELETE FROM duplock WHERE instime < DATE_SUB(NOW(), INTERVAL 1 HOUR)");

    print "-I- Cleaning commenturl.\n";
    $dbh->do("DELETE FROM commenturls WHERE timecreate < UNIX_TIMESTAMP() - 86400*30 LIMIT 50000");

    print "-I- Cleaning captcha sessions.\n";
    foreach my $c (@LJ::CLUSTERS) {
        my $dbcm = LJ::get_cluster_master($c);
        next unless $dbcm;
        $dbcm->do("DELETE FROM captcha_session WHERE sesstime < UNIX_TIMESTAMP()-86400");
    }

    print "-I- Cleaning old anonymous comment IP logs.\n";
    my $count;
    foreach my $c (@LJ::CLUSTERS) {
        my $dbcm = LJ::get_cluster_master($c);
        next unless $dbcm;
        # 432,000 seconds is 5 days
        $count += $dbcm->do('DELETE FROM tempanonips WHERE reporttime < (UNIX_TIMESTAMP() - 432000)');
    }
    print "    deleted $count\n";

    print "-I- Cleaning diresearchres.\n";
    # need insert before delete so master logs delete and slaves actually do it
    $dbh->do("INSERT INTO dirsearchres2 VALUES (MD5(NOW()), DATE_SUB(NOW(), INTERVAL 31 MINUTE), '')");
    $dbh->do("DELETE FROM dirsearchres2 WHERE dateins < DATE_SUB(NOW(), INTERVAL 30 MINUTE)");

    print "-I- Cleaning meme.\n";
    do {
        $sth = $dbh->prepare("DELETE FROM meme WHERE ts < DATE_SUB(NOW(), INTERVAL 7 DAY) LIMIT 250");
        $sth->execute;
        if ($dbh->err) { print $dbh->errstr; }
        print "    deleted ", $sth->rows, "\n";
    } while ($sth->rows && ! $sth->err);

    print "-I- Cleaning old pending comments.\n";
    $count = 0;
    foreach my $c (@LJ::CLUSTERS) {
        my $dbcm = LJ::get_cluster_master($c);
        next unless $dbcm;
        # 3600 seconds is one hour
        my $time = time() - 3600;
        $count += $dbcm->do('DELETE FROM pendcomments WHERE datesubmit < ? LIMIT 2000', undef, $time);
    }
    print "    deleted $count\n";

    # move rows from talkleft_xfp to talkleft
    print "-I- Moving talkleft_xfp.\n";

    my $xfp_count = $dbh->selectrow_array("SELECT COUNT(*) FROM talkleft_xfp");
    print "    rows found: $xfp_count\n";

    if ($xfp_count) {

        my @xfp_cols = qw(userid posttime journalid nodetype nodeid jtalkid publicitem);
        my $xfp_cols = join(",", @xfp_cols);
        my $xfp_cols_join = join(",", map { "t.$_" } @xfp_cols);

        my %insert_vals;
        my %delete_vals;
        
        # select out 1000 rows from random clusters
        $sth = $dbh->prepare("SELECT u.clusterid,u.user,$xfp_cols_join " .
                             "FROM talkleft_xfp t, user u " .
                             "WHERE t.userid=u.userid LIMIT 1000");
        $sth->execute();
        my $row_ct = 0;
        while (my $row = $sth->fetchrow_hashref) {

            my %qrow = map { $_, $dbh->quote($row->{$_}) } @xfp_cols;

            push @{$insert_vals{$row->{'clusterid'}}},
                   ("(" . join(",", map { $qrow{$_} } @xfp_cols) . ")");
            push @{$delete_vals{$row->{'clusterid'}}},
                   ("(userid=$qrow{'userid'} AND " .
                    "journalid=$qrow{'journalid'} AND " .
                    "nodetype=$qrow{'nodetype'} AND " .
                    "nodeid=$qrow{'nodeid'} AND " .
                    "posttime=$qrow{'posttime'} AND " .
                    "jtalkid=$qrow{'jtalkid'})");

            $row_ct++;
        }

        foreach my $clusterid (sort keys %insert_vals) {
            my $dbcm = LJ::get_cluster_master($clusterid);
            unless ($dbcm) {
                print "    cluster down: $clusterid\n";
                next;
            }

            print "    cluster $clusterid: " . scalar(@{$insert_vals{$clusterid}}) .
                  " rows\n" if $verbose;
            $dbcm->do("INSERT INTO talkleft ($xfp_cols) VALUES " .
                      join(",", @{$insert_vals{$clusterid}})) . "\n";
            if ($dbcm->err) {
                print "    db error (insert): " . $dbcm->errstr . "\n";
                next;
            }

            # no error, delete from _xfp
            $dbh->do("DELETE FROM talkleft_xfp WHERE " .
                     join(" OR ", @{$delete_vals{$clusterid}})) . "\n";
            if ($dbh->err) {
                print "    db error (delete): " . $dbh->errstr . "\n";
                next;
            }
        }

        print "    rows remaining: " . ($xfp_count - $row_ct) . "\n";
    }

    # move clustered recentaction summaries from their respective clusters
    # to the global actionhistory table
    print "-I- Migrating recentactions.\n";

    foreach my $cid (@LJ::CLUSTERS) {
        next unless $cid;

        my $dbcm = LJ::get_cluster_master($cid);
        unless ($dbcm) {
            print "    cluster down: $clusterid\n";
            next;
        }

        unless ($dbcm->do("LOCK TABLES recentactions WRITE")) {
            print "    db error (lock): " . $dbcm->errstr . "\n";
            next;
        }

        my $sth = $dbcm->prepare
            ("SELECT what, COUNT(*) FROM recentactions GROUP BY 1");
        $sth->execute;
        if ($dbcm->err) {
            print "    db error (select): " . $dbcm->errstr . "\n";
            next;
        }

        my %counts = ();
        my $total_ct = 0;
        while (my ($what, $ct) = $sth->fetchrow_array) {
            $counts{$what} += $ct;
            $total_ct += $ct;
        }
        
        print "    cluster $cid: $total_ct rows\n" if $verbose;

        # Note: We can experience failures on both sides of this 
        #       transaction.  Either our delete can succeed then
        #       insert fail or vice versa.  Luckily this data is
        #       for statistical purposes so we can just live with
        #       the possibility of a small skew.

        unless ($dbcm->do("DELETE FROM recentactions")) {
            print "    db error (delete): " . $dbcm->errstr . "\n";
            next;
        }

        # at this point if there is an error we will ignore it and try
        # to insert the count data above anyway
        $dbcm->do("UNLOCK TABLES")
            or print "    db error (unlock): " . $dbcm->errstr . "\n";

        # nothing to insert, why bother?
        next unless %counts;

        # insert summary into global actionhistory table
        my @bind = ();
        my @vals = ();
        while (my ($what, $ct) = each %counts) {
            push @bind, "(UNIX_TIMESTAMP(),?,?,?)";
            push @vals, $cid, $what, $ct;
        }
        my $bind = join(",", @bind);

        $dbh->do("INSERT INTO actionhistory (time, clusterid, what, count) " .
                 "VALUES $bind", undef, @vals);
        if ($dbh->err) {
            print "    db error (insert): " . $dbh->errstr . "\n";

            # something's badly b0rked, don't try any other clusters for now
            last;
        }

        # next cluster
    }

};

1;

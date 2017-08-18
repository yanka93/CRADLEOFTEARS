#!/usr/bin/perl
#

use strict;
use vars qw(%maint);

$maint{'genstatslocal'} = sub
{
    my @which = @_;

    unless (@which) { @which = qw(singles); }
    my %do = map { $_, 1, } @which;
    
    my %to_pop;

    LJ::load_props("user");

    if ($do{'singles'}) {
        my $dbr = LJ::get_db_reader();
        my $propid = $dbr->selectrow_array("SELECT upropid FROM userproplist WHERE name='single_status'");
        my $ct = $dbr->selectrow_array("SELECT COUNT(*) FROM userprop WHERE upropid=$propid");
        $to_pop{'singles'}->{'total'} = $ct;
    }

    # copied from stats.pl:
    my $dbh = LJ::get_db_writer();
    foreach my $cat (keys %to_pop)
    {
        print "  dumping $cat stats\n";
        my $qcat = $dbh->quote($cat);
        $dbh->do("DELETE FROM stats WHERE statcat=$qcat");
        if ($dbh->err) { die $dbh->errstr; }
        foreach (sort keys %{$to_pop{$cat}}) {
            my $qkey = $dbh->quote($_);
            my $qval = $to_pop{$cat}->{$_}+0;
            $dbh->do("REPLACE INTO stats (statcat, statkey, statval) VALUES ($qcat, $qkey, $qval)");
            if ($dbh->err) { die $dbh->errstr; }
        }
    }

    print "-I- Done.\n";

};

1;

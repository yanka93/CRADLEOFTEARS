#!/usr/bin/perl
#

$maint{'clean_caches_local'} = sub 
{
    my $dbh = LJ::get_db_writer();

    my $verbose = $LJ::LJMAINT_VERBOSE;

    print "-I- Cleaning authactions.\n";
    $dbh->do("DELETE FROM authactions WHERE datecreate < DATE_SUB(NOW(), INTERVAL 30 DAY)");
};

1;

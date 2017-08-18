#!/usr/bin/perl
#

$maint{'clean_challenges'} = sub 
{
    my $dbh = LJ::get_db_writer();
    my $sth;

    my $ctime = time();
    my $deltime = $ctime - 60*60*24*14; # two weeks

    print "current time: $ctime\n";
    print "deleting challenges older than: $deltime\n";
    $sth = $dbh->prepare("delete from challenges where challenge < 'c0:$deltime'");
    $sth->execute();
    if ($dbh->err) { die $dbh->errstr; }

    print "done.\n";
};

1;

#!/usr/bin/perl
#

use Net::FTP;

# FIXME: low priority. bitrot. never made public.

$maint{'xfers_do'} = sub
{
    
    my $dbh = LJ::get_db_writer();

    print "-I- Loading users that need transfers...\n";
    $sth = $dbh->prepare("SELECT t.*, u.user, u.lastn_style FROM transferinfo t, user u WHERE t.userid=u.userid AND t.lastxfer < u.timeupdate AND t.state='on'");
    $sth->execute;
    if ($dbh->err) { die $dbh->errstr; }
    while ($ti = $sth->fetchrow_hashref)
    {
        print "  ==> $ti->{'user'} ($ti->{'userid'})\n";
        my $styleid = $ti->{'styleid'} || $ti->{'lastn_style'};

        my $localfile = "$LJ::TEMP/$ti->{'userid'}.xfer";
        open (TEMP, ">$localfile") or die ($!);
        my $data = &make_journal_by_style($ti->{'user'}, $styleid, "", "");
        $data ||= "<B>[LiveJournal: Bad username, styleid, or style definition]</B>";
        print TEMP $data;
        close TEMP;	

        if ($ti->{'method'} eq "ftp") {
            my $ftp = Net::FTP->new($ti->{'host'});
            $ftp->login($username, $ti->{'password'});
            $ftp->cwd($ti->{'directory'});
            $ftp->put($localfile, ($ti->{'filename'} || "livejournal.html"));
            $ftp->quit;
        }
        elsif ($ti->{'method'} eq "scp") 
        {
            my $username = $ti->{'username'};
            $username =~ s/[^a-zA-Z0-9\-\_]//g;
            my $host = $ti->{'host'};
            $host =~ s/[^a-zA-Z0-9\-\.]//g;
            my $directory = $ti->{'directory'};
            $directory =~ s/[^a-zA-Z0-9\_\-\. \/]//g;
            my $filename = $ti->{'filename'};
            $filename =~ s/[^a-zA-Z0-9\_\-\. ]//g;
            my $rc = system("scp $localfile \"$username\@$host:$directory/$filename\"");
            print "Return: $rc\n";
        }

    }

};

1;

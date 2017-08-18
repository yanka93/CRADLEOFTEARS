#!/usr/bin/perl
#

$maint{'dirsync'} = sub
{
    use File::Copy;

    my $FROMBASE = "/home/devftp";
    my $TOBASE = "/home/lj/htdocs";
    my $REWRITE_PERIOD = 3600*2;    # for 2 hours, ftp area files can overwrite masters
    my $VERBOSE = 0;

    print "-I- Connecting to db.\n" if ($VERBOSE);

    my $dbr = LJ::get_db_reader();

    print "-I- Fetching users with devftp privs.\n" if ($VERBOSE);
    my $sth = $dbr->prepare("SELECT u.user, u.userid, pm.arg FROM priv_map pm, priv_list pl, user u WHERE pl.prlid=pm.prlid AND pl.privcode='dirsync' AND pm.userid=u.userid ORDER BY u.user");
    $sth->execute;
    while (my ($user, $userid, $arg) = $sth->fetchrow_array)
    {
        print "-I- $user: $arg\n" if ($VERBOSE);
        if ($arg =~ /\.\./) { print "-E- ($user) arg contains '..', skipping!\n"; next; }
        if ($arg =~ /~/) { print "-E- ($user) arg contains '~', skipping!\n"; next; }
        my $opts;
        if ($arg =~ s/\s*\[(.+)?\]\s*$//) {
            $opts = $1;
        }
        unless ($arg =~ /^(\S+)=(\S+)$/) { print "-E- arg doesn't match \S+=\S+, skipping!\n"; next; }
        my ($from, $to) = ($1, $2);

        $to =~ s/\0//;  # fuck perl, seriously.  why's a NULL in this string?
        if ($from =~ /\0/) { die "from has null (0)!\n"; }
        if ($to =~ /\0/) { die "to has null (0)!\n"; }

        $from = "$FROMBASE/$user/$from";
        $to = "$TOBASE/$to";
        unless (-d $from) { print "-E- ($user) From directory doesn't exist: $from, skipping!\n"; next; }
        unless (-d $to) { print "-E- ($user) To directory doesn't exist: $to, skipping!\n"; next; }

        opendir (DIR, $from);
        while (my $file = readdir DIR) 
        {
            if ($file eq "." || $file eq ".." || $file =~ /~/ || length($file) > 40) { next; }

            my $tofile = "$to/$file";
            if ($tofile =~ /\0/) { die "tofile has null (1)!\n"; }

            my $fromfile = "$from/$file";
            if (-d $fromfile) { next; }
            unless (-f $fromfile) { next; }
            
            my $fromtime = (stat($fromfile))[9];
            my $totime = (-e $tofile) ? (stat($tofile))[9] : 0;
            my $existtime = $totime - $fromtime;

            my $allow = 0;
            if ($totime == 0) { $allow = 1; }
            elsif ($fromtime > $totime) {
                if ($existtime < $REWRITE_PERIOD) { $allow = 1; }
                elsif ($file =~ /^changelog(\.txt)?$/i ||
                       $file =~ /^readme(\.txt)?$/i) { $allow = 1; }
                elsif ($opts =~ /u/) { $allow = 1; }
            }

            if ($allow) {
                if ($fromfile =~ /\0/) { die "from has null!\n"; }
                if ($tofile =~ /\0/) { die "to has null!\n"; }
                print "-I- ($user) Copying $file ($fromfile to $tofile)\n";
                unless (copy($fromfile, $tofile)) {
                    print "-E- ($user) Didn't copy! error: $!\n";
                }
            } 
        }
        
    }

};

1;

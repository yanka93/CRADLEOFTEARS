#!/usr/bin/perl
#

use Sys::Hostname;
use Digest::MD5;
use File::Copy;

$maint{'syncsoon'} = sub
{
    if ($> == 0) {
        print "Don't run this as root.\n";
        return 0;
    }
    open (F, ">/home/lj/var/do-syncweb");
    print F "this file flags to syncweb to sync later.\n";
    close F;

    print "Flag set.\n";
    return 1;    
};

$maint{'syncweb'} = sub
{
    my $arg = shift;

    # update inc files on disk if necessary
    if ($LJ::FILEEDIT_VIA_DB) {
        my $syncfile = "$LJ::HOME/temp/last-fileedit-sync";
        open (F, $syncfile);
        my $lasttime = <F>;
        close F;
        $lasttime += 0;
        my $dbh = LJ::get_dbh("master");
        my $sth = $dbh->prepare("SELECT incname, inctext, updatetime FROM includetext ".
                                "WHERE updatetime > $lasttime");
        $sth->execute;

        my $newmax = 0;
        while (my ($name, $text, $time) = $sth->fetchrow_array) {
            if (open (F, ">$LJ::HOME/htdocs/inc/$name")) {
                print F $text;
                close F;
                $newmax = $time if ($time > $newmax);
            }
        }
        
        if ($newmax) {
            open (F, ">$syncfile");
            print F $newmax;
            close F;
        }
    }

    return 1 if ($arg eq "norsync");

    unless ($arg eq "now" || -e "/home/lj/var/do-syncweb") {
        return 1;
    }

    my $host = hostname();

    if ($> == 0) {
        print "Don't run this as root.\n";
        return 0;
    }
    if (`grep '/home nfs' /proc/mounts`) {
        print "Don't run this on an NFS client.\n";
        return 0;
    }
    unless (chdir("/home/lj"))
    {
        print "Could not chdir to /home/lj\n";
        return 0;
    }
    
    my @exclude = qw(/logs/
                     /mail/
                     /var/
                     /backup/
                     /cvs/
                     /temp/
                     /.ssh/
                     /.ssh2/
                     /.procmailrc
                     /htdocs/userpics
                     );
    my $excludes = join(" ", map { "--exclude='$_'"} @exclude);

    print "Syncing...\n";
    print `/usr/bin/rsync -avz --delete $excludes masterweb::ljhome/ .`;

    unlink "/home/lj/var/do-syncweb";
    print "Done.\n";
    return 1;
};

$maint{'syncmodules'} = sub
{
    my $host = hostname();

    unless ($> == 0 || $< == 0) {
        print "Must run this as root.\n";
        return 0;
    }

    my %state;
    my $STATE_FILE = "/home/lj/var/modstate.dat";
    my $LINK_DIR = "/home/lj/modules";
    my $BUILD_DIR = "/usr/build";
    my $changed = 0;  # did state change?

    unless (-d $BUILD_DIR) {
        print "Build directory ($BUILD_DIR) doesn't exist!\n";
        return 0;
    }
    
    ###
    ## load everything about what we did last
    #
    open (ST, $STATE_FILE);
    while (<ST>) {
        chomp;
        my ($file, $target, $status, $digest) = split(/\t/, $_);
        $state{$file} = {'target' => $target,
                         'status' => $status,
                         'digest' => $digest, };
    }
    close ST;

    ## look for all symlinks in the link dir.  for each
    ## try to install it if, 1) it points to someplace
    ## that it didn't before, or 2) it failed before and
    ## the md5 sum changed from last time.

    unless (chdir ($LINK_DIR)) {
        print "Can't chdir to link directory: $LINK_DIR\n";
        return 0;
    }
    
    unless (opendir (DIR, $LINK_DIR)) {
        print "Can't open link directory: $LINK_DIR\n";
        return 0;
    }
    
  LINKWHILE:
    while (my $file = readdir(DIR)) 
    {
        chdir $LINK_DIR;
        next if (-d $file);
        next unless (-l $file);
        my $target = readlink($file);
        
        # FIXME: and check for weird characters?  
        # could be a problem if user lj is hacked, could be used to get
        # root, if symlink goes somewhere odd.
        next unless (-f $file);  

        my $install = 0;
        my $digest = "";

        if ($target ne $state{$file}->{'target'}) {
            $install = 1;
        } elsif ($state{$file}->{'status'} eq "FAIL") {
            $digest = Digest::MD5::md5_hex($target);
            if ($digest ne $state{$file}->{'digest'}) {
                $install = 1;
            }
        }
        next unless ($install);

        #
        # install it!
        #

        print "Installing $file ($target)...\n";
        $digest ||= Digest::MD5::md5_hex($target);
        $state{$file}->{'digest'} = $digest;
        $state{$file}->{'target'} = $target;
        $changed = 1;

        my $subdir;
        open (CON, "tar ztf $target |");
        while (<CON>) {
            chomp;
            unless (/^(\S+?)\//) {
                warn "Target has no subdirectories it extracts from?\n";                
                $state{$file}->{'status'} = "FAIL";
                next LINKWHILE;
            }
            my $dir = $1;
            $subdir ||= $dir;
            if ($subdir ne $dir) {
                warn "Target has multiple sub-directories.\n";
                $state{$file}->{'status'} = "FAIL";
                next LINKWHILE;
            }
        }
        close CON;
        
        print "Sub-directory = $subdir\n";

        if (system("tar zxvf $target -C $BUILD_DIR")) {
            warn "Extraction failed.\n";
            $state{$file}->{'status'} = "FAIL";
            next LINKWHILE;
        }
        chdir "$BUILD_DIR/$subdir";
        if (system("perl Makefile.PL")) {
            warn "makefile creation failed.\n";
            $state{$file}->{'status'} = "FAIL";
            next LINKWHILE;
        }
        if (system("make")) {
            warn "make failed.\n";
            $state{$file}->{'status'} = "FAIL";
            next LINKWHILE;
        }
        if (system("make test")) {
            warn "make test failed.\n";
            $state{$file}->{'status'} = "FAIL";
            next LINKWHILE;
        }
        if (system("make install")) {
            warn "make install failed.\n";
            $state{$file}->{'status'} = "FAIL";
            next LINKWHILE;
        }

        $state{$file}->{'status'} = "OK";
        
    }
    closedir (DIR);

    if ($changed) {
        print "Writing state.\n";
        open (ST, ">$STATE_FILE");
        foreach (sort keys %state) {
            print ST join("\t", 
                          $_, 
                          $state{$_}->{'target'},
                          $state{$_}->{'status'},
                          $state{$_}->{'digest'}), "\n";
        }
        close ST;
    }
    
};

#!/usr/bin/perl
#

use strict;
use Getopt::Long;

$| = 1;

my $help = 0;
my $sync = 0;
my $diff = 0;
my $cvsonly = 0;
my $liveonly = 0;
my $init = 0;
my $conf;
my $opt_update;
my $opt_justfiles;
my $opt_ignore_space;
my $these_flag;

exit 1 unless GetOptions('conf=s' => \$conf,
                         'help' => \$help,
                         'sync' => \$sync,
                         'diff' => \$diff,
                         'cvsonly|c' => \$cvsonly,
                         'liveonly' => \$liveonly,
                         'init' => \$init,
                         'update' => \$opt_update,
                         'justfiles|1' => \$opt_justfiles,
                         'no-space-changes|b|w' => \$opt_ignore_space,
                         'these|t' => \$these_flag,
                         );

if ($help or not defined $conf) {
    die "Usage: multicvs.pl --conf=/path/to/multicvs.conf [opts] [files]\n" .
        "    --help          Get this help\n" .
        "    --sync          Put files where they need to go.\n" .
        "                    All files, unless you specify which ones.\n".
        "    --diff          Show diffs of changed files.\n".
        "    --cvsonly       Don't consider files changed in live dirs.\n".
        "    --liveonly      Don't consider files changed in the CVS dirs.\n".
        "    --init          Copy all files from cvs to main, unconditionally.\n" .
        "    --update        Updates files in the CVS dirs from the cvs repositories.\n".
        "    --justfiles -1  Only output files, not the old -> new arrow. (good for xargs)\n".
        "    --no-space-changes -b    Do not display whitespace differences.\n".
        "    --these -t      Refuse to --sync if no files are specified.\n";
}

if ($init) {
    $sync = 1;
    die "Can't set --liveonly or --cvsonly with --init\n"
        if $cvsonly or $liveonly;
    $diff = 0;
}

unless (-e $conf) {
    die "Specified conf file doesn't exist: $conf\n";
}

my ($DIR_LIVE, $DIR_CVS);
my @paths;

my $read_conf = sub
{
    my $file = shift;
    my $main = shift;

    open (C, $file) or die "Error opening conf file.\n";
    while (<C>)
    {
        s/\#.*//;
        next unless /\S/;
        s/^\s+//;
        s/\s+$//;
        s/\$(\w+)/$ENV{$1} or die "Environment variable \$$1 not set.\n"/ge;

        if (/(\w+)\s*=\s*(.+)/) {
            my ($k, $v) = ($1, $2);
            unless ($main) {
                die "Included config files can't set variables such as $k.\n";
            }
            if ($k eq "LIVEDIR") { $DIR_LIVE = $v; }
            elsif ($k eq "CVSDIR") { $DIR_CVS = $v; }
            else { die "Unknown option $k = $v\n"; }
            next;
        }

        if (/(\S+)\s+(.+)/) {
            my ($from, $to) = ($1, $2);
            my $maybe = 0;
            if ($from =~ s/\?$//) { $maybe = 1; }
            push @paths, {
                'from' => $from,
                'to' => $to,
                'maybe' => $maybe,
            };
        } else {
            die "Bogus line: $_\n";
        }
    }
    close C;
};
$read_conf->($conf, 1);

if ($conf =~ /^(.+)(multicvs\.conf)$/) {
    my $localconf = "$1multicvs-local.conf";
    $read_conf->($localconf) if -e $localconf;
}

my %cvspath;  # live path -> cvs path
my %have_updated;;

foreach my $p (@paths)
{
    unless (-e "$DIR_CVS/$p->{'from'}") {
        warn "WARNING: $p->{'from'} doesn't exist under $DIR_CVS\n"
            unless $p->{'maybe'};
        next;
    }

    if ($opt_update) {
        my $root = $p->{'from'};
        $root =~ s!/.*!!;
        my $dir = "$DIR_CVS/$root";
        if (-d $dir && ! $have_updated{$dir}) {
            chdir $dir or die "Can't cd to $dir\n";
            print "Updating CVS dir '$root' ...\n";
            system("cvs", "update", "-dP");
            $have_updated{$dir} = 1;
        }
    }

    if (-f "$DIR_CVS/$p->{'from'}") {
        $cvspath{$p->{'to'}} = $p->{'from'};
        next;
    }

    $p->{'to'} =~ s!/$!!;
    my $to_prefix = "$p->{'to'}/";
    $to_prefix =~ s!^\./!!;

    my @dirs = ($p->{'from'});
    while (@dirs)
    {
        my $dir = shift @dirs;
        my $fulldir = "$DIR_CVS/$dir";

        opendir (MD, $fulldir) or die "Can't open $fulldir.";
        while (my $file = readdir(MD)) {
            next if ($file =~ /~$/);     # ignore emacs files
            next if ($file =~ /^\.\#/);  # ignore CVS archived versions
            next if ($file =~ /\bCVS\b/);
            next if $file eq "." or $file eq "..";
            if (-d "$fulldir/$file") {
                unshift @dirs, "$dir/$file";
            } elsif (-f "$fulldir/$file") {
                my $to = "$dir/$file";
                $to =~ s!^$p->{'from'}/!!;
                $cvspath{"$to_prefix$to"} = "$dir/$file";
            }
        }
        close MD;
    }
}

# If the user has specified that there must be arguments, require @ARGV to
# contain soemthing.
die "These what?\n\nWith --these specified, you must provide at least one file to sync.\n"
    if $these_flag && $sync && !@ARGV;

my @files = scalar(@ARGV) ? @ARGV : sort keys %cvspath;
foreach my $relfile (@files)
{
    my $status;
    next unless exists $cvspath{$relfile};
    my $root = $cvspath{$relfile};
    $root =~ s!/.*!!;

    my ($from, $to);  # if set, do action (diff and/or sync)

    my $lfile = "$DIR_LIVE/$relfile";
    my $cfile = "$DIR_CVS/$cvspath{$relfile}";

    if ($init) {
        $status = "main <- $root";
        ($from, $to) = ($cfile, $lfile);
    } else {
        my $ltime = mtime($lfile);
        my $ctime = mtime($cfile);
        next if $ltime == $ctime;
        if ($ltime > $ctime && ! $cvsonly) {
            $status = "main -> $root";
            ($from, $to) = ($lfile, $cfile);
        }
        if ($ctime > $ltime && ! $liveonly) {
            $status = "main <- $root";
            ($from, $to) = ($cfile, $lfile);
        }
    }

    next unless $status;

    my $the_diff;
    if ($diff && -e $from && -e $to) {
        my $opt;
        $opt = '-b' if $opt_ignore_space;
        $the_diff = `diff -u $opt $to $from`; # getting from destination to source
        if ($the_diff) {
            # fix the -p level to be -p0
            my $slashes = ($DIR_LIVE =~ tr!/!/!);
            $the_diff =~ s/((^|\n)[\-\+]{3,3} )\/([^\/]+?\/){$slashes,$slashes}/$1/g;
        } else {
            # don't touch the files that don't have a diff if we're ignoring spaces
            # as there might really be one and we just don't see it
            next if $opt_ignore_space;

            # no real change (just touched/copied?), so copy
            # cvs one on top to fix times up.
            copy($from, $to);
            next;
        }
    }
    if ($sync) {
        make_dirs($relfile);
        copy($from, $to);
    }

    if ($opt_justfiles) {
        print "$relfile\n";
    } else {
        printf "%-25s %s\n", $status, $relfile;
        print $the_diff;
    }
}

sub mtime
{
    my $file = shift;
    return (stat($file))[9];
}

my %MADE_DIR;
sub make_dirs
{
    my $file = shift;
    return 1 unless $file =~ s!/[^/]*$!!;
    return 1 if $MADE_DIR{$file};
    my @dirs = split(m!/!, $file);
    for (my $i=0; $i<scalar(@dirs); $i++) {
        my $sd = join("/", @dirs[0..$i]);
        my $makedir = "$DIR_LIVE/$sd";
        unless (-d $makedir) {
            mkdir $makedir, 0755
                or die "Couldn't make directory $makedir\n";
        }
    }
    $MADE_DIR{$file} = 1;
}

# was using perl's File::Copy, but I want to preserve the file time.
sub copy
{
    my ($src, $dest) = @_;
    my $ret = system("cp", "-p", $src, $dest);
    return ($ret == 0);
}

__END__

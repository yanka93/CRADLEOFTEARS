#!/usr/bin/perl
#

my $mode = shift @ARGV;

if ($< == 0 || $> ==0) { die "Don't run as root.\n"; }
chdir("/home/lj") || die "Can't cd to /home/lj";

chdir("/home/ljcode") || die "Can't cd to /home/ljcode";
unless (-d "LiveJournal") {
    die "directory 'LiveJournal' doesn't exist.\n";
}

print "Dumping SQL...\n";
system("dumpsql.pl init > LiveJournal/livejournal.sql");
system("dumpsql.pl data > LiveJournal/livejournal-data.sql");
system("dumpsql.pl datareplace > LiveJournal/livejournal-datareplace.sql");

mkdir "LiveJournal/bin/", 0755;
mkdir "LiveJournal/cgi-bin/", 0755;
mkdir "LiveJournal/htdocs/", 0755;
foreach my $dir (qw(htdocs/files htdocs/temp htdocs/misc htdocs/img 
                    htdocs/stats htdocs/download htdocs/clients
                    logs var))
{
    mkdir "LiveJournal/htdocs/$dir", 0755;
    open (T, ">LiveJournal/htdocs/$dir/.touch");
    print T "placeholder\n";
    close T;
}

print "Syncing cgi-bin...\n";
system("rsync -rl --delete --exclude='archive' --exclude='clients' --exclude='ljconfig.pl' /home/lj/cgi-bin/ LiveJournal/cgi-bin/");

print "Syncing htdocs...\n";
system("rsync -rl --delete --exclude='htdocs/dev/' --exclude='img' --exclude='files' --exclude='download' --exclude='temp' --exclude='misc' --exclude='stats' /home/lj/htdocs/ LiveJournal/htdocs/");

print "Syncing bin...\n";
system("rsync -rl --delete --exclude='old' /home/lj/bin/ LiveJournal/bin/");

my @now = localtime();
my $date = sprintf("%04d%02d%02d", $now[5]+1900, $now[4]+1, $now[3]);
my $append = $date;
print "Date is: $date\n";
my $count = 1;
while (-e "LiveJournal-$append" || -e "LiveJournal-$append.tar.gz") {
    $count++;
    $append = "$date-$count";
}

chdir("LiveJournal");

print "Cleaning emacs files.\n";
system("no-emacs.sh");
print "Cleaning other files.\n";
system("rm cgi-bin/pod2html-* cgi-bin/perl.core");

chdir("..");

unless ($mode eq "lite")
{
    print "Renaming to LiveJournal-$append...\n";
    rename "LiveJournal", "LiveJournal-$append";
    
    print "Tarring...\n";
    system("tar -zcvf LiveJournal-$append.tar.gz LiveJournal-$append");
    
    print "Renaming back...\n";
    rename "LiveJournal-$append", "LiveJournal";
}
else
{
    print "Skipping tarball.\n";
}
print "Done\n";


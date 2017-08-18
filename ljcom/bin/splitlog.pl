#!/usr/bin/perl
#

my $file = shift @ARGV;
my $newfile = shift @ARGV;

my $locfile = "$file.loc";
my $loc = 0;
my $lines = 0;

my %monthtonum = qw(Jan 01 Feb 02 Mar 03 Apr 04 May 05 Jun 06
                    Jul 07 Aug 08 Sep 09 Oct 10 Nov 10 Dec 12);

$SIG{'INT'} = \&write_loc;

sub write_loc {
    close OUT;
    print "Writing location $loc\n";
    open (LOC, ">$locfile") || die "Can't write location file!\n";
    print LOC "$loc\n$lines\n";
    close LOC;
    print "Ending.";
    exit;
};

unless ($file && $newfile) {
    die "Usage:\n $0 <logfile> <basename>\n";
}
unless (-r $file) {
    die "File \"$file\" does not exist.\n";
}

unless (-d "split") {
    die "No split directory underneith the current directory.\n";
}

if (-e $locfile) {
    open (LOC, $locfile) || die "Can't read location file!\n";;
    chomp ($loc = <LOC>);
    $loc += 0;
    chomp ($lines = <LOC>);
    $lines += 0;
    close LOC;
    print "Location: $loc (did $lines lines)\n";
}

open (LOG, $file) || die "Can't read log file\n";;
seek(LOG, $loc, 0);

#my $line = <LOG>;
#$line = <LOG>;
#print $line;
#exit;

my $count = 0;
my $lastdate = "";
while (my $line = <LOG>) {
    $loc += length($line);
    $lines++;

    if ($line =~ /\[(\d\d)\/(...)\/(\d\d\d\d)/) {
        my ($year, $month, $day) = ($3, $monthtonum{$2}, $1);
        
        my $date = "$year-$month-$day";

        if ($date ne $lastdate) {
#	    if ($year==2001 && $month==3 && $day > 2) {
                close OUT;
                open (OUT, ">>split/$date-$newfile.log") || die "Can't open file we're supposed to append to.\n";
#	    }
            $lastdate = $date;
        }

#	if ($year==2001 && $month==3 && $day > 2) {
            print OUT $line;
#	}
    }

    if ($lines % 10000 == 0) { print "line: $lines ($lastdate).\n"; }
}

close LOG;
close OUT;

print "End of file!\n";
unlink $locfile, $file;



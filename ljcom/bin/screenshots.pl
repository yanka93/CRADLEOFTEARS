#!/usr/bin/perl
#

use Image::Size;

my $dir = shift @ARGV;
unless ($dir) {
    die "Usage:\n  $0 <directory>\n";
}
unless (-d $dir) {
    die "$dir isn't a directory!\n";
}

unless (open (PICS, "pics.dat")) {
    die "No pics.dat found in that directory, or unreadable.\n";
}

print "<?page\ntitle=>Screenshots\nbody<=\n";

while ($line = <PICS>) {
    chomp $line;
    my ($file, $des) = split(/\t/, $line);
    if (-e $file) {
        my ($w, $h) = imgsize($file);

        print "<p>$des<p><CENTER><IMG SRC=\"$file\" WIDTH=$w HEIGHT=$h></CENTER>\n";

    } else {
        print STDERR "$file not found!\n";
    }
       
}

print "<=body\npage?>\n";

#!/usr/bin/perl
#

opendir (DIR, ".");
@files = readdir DIR;

open (HTML, ">index.html");
print HTML "<HTML><BODY BGCOLOR=#C0C0C0>\n";
print HTML "<TABLE CELLPADDING=2>\n";

foreach my $file (sort @files)
{
    next unless ($file =~ /\.gif$/);
    my $newfile = $file;
    $newfile =~ s/\s\(\d\)//g;
    if ($file ne $newfile) {
	rename $file, $newfile;
	$file = $newfile;
    }
    print HTML "<TR VALIGN=MIDDLE><TD>$file</TD>";
    foreach $col ("#FFFFFF", "#000000", "#C0C0C0", "#FFFF00", "#FF0000") {
	print HTML "<TD BGCOLOR=$col><IMG SRC=\"$file\"></TD>";
    }
    print HTML "</TR>\n";
}

print HTML "</TABLE></BODY></HTML>\n";

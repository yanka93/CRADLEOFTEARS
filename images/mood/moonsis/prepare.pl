#!/usr/bin/perl
#

use Image::Size;

require '/home/lj/cgi-bin/ljlib.pl';
&connect_db();

my $num = shift @ARGV;
if ($num) {
    my $sth = $dbh->prepare("SELECT mood, moodid FROM moods");
    $sth->execute;
    $moodid{$_->{'mood'}} = $_->{'moodid'} while ($_ = $sth->fetchrow_hashref);

    $dir = shift @ARGV;
    unless ($dir) { die "No directory prefix given!\n"; }
    unless ($dir =~ /\/$/) { $dir .= "/"; }
}


opendir (DIR, ".");
@files = readdir DIR;

open (HTML, ">index.html");
print HTML "<HTML><BODY BGCOLOR=#C0C0C0>\n";
print HTML "<TABLE CELLPADDING=2>\n";

foreach my $file (sort @files)
{
    next unless ($file =~ /\.gif$/);
    my $newfile = $file;
    $newfile =~ s/_bobl1//g;
    if ($file ne $newfile) {
	rename $file, $newfile;
	$file = $newfile;
    }
    ($w, $h) = imgsize($file);
    my $noext = $file;
    $noext =~ s/\..+?$//;
    my $moodid;

    $uri = $dir . $file;
    my $quri = $dbh->quote($uri);

    print HTML "<TR VALIGN=MIDDLE><TD>$file";
    if ($moodid = $moodid{$noext}) {
	print HTML " ($moodid)";
	if ($num) {
	    $dbh->do("REPLACE INTO moodthemedata (moodthemeid, moodid, picurl, width, height) VALUES ($num, $moodid, $quri, $w, $h)");
	}
    } else {
	if ($num) {
	    print "REPLACE INTO moodthemedata (moodthemeid, moodid, picurl, width, height) VALUES ($num, , $quri, $w, $h);\n";
	}
    }
    print HTML "</TD>";
    foreach $col ("#FFFFFF", "#000000", "#C0C0C0", "#FFFF00", "#FF0000") {
	print HTML "<TD BGCOLOR=$col><IMG SRC=\"$file\" WIDTH=$w HEIGHT=$h></TD>";
    }
    print HTML "</TR>\n";
}

print HTML "</TABLE></BODY></HTML>\n";

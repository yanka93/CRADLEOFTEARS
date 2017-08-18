#!/usr/bin/perl
#

my $dir = shift @ARGV;
unless ($dir || -d $dir) {
    die "Usage:\n  makemoodindex.pl <dir>\n";
}

print "Making mood index for $dir\n";

@colors = qw(ffffff 333333 663300 ff9900 ffff33 00ff00 006600 009999 0066cc 9900cc ff3399 ff0000
             cccccc 000000 cccc99 ffcc99 ffffcc ccffcc 339933 99ffff 99ccff cc99ff ff99cc ffcccc);

opendir (DIR, $dir);
@files = readdir DIR;
closedir DIR;

if (-e "$dir/index.html") {
    open (HTML, "$dir/index.html");
    my $line = <HTML>;
    chomp $line;
    unless ($line eq "<!--MOODINDEX-->") { die "Won't overwrite index.html in this directory!\n"; }
}

open (HTML, ">$dir/index.html");
print HTML "<!--MOODINDEX-->\n";
print HTML "<HTML><BODY BGCOLOR=#ffffff>\n";

print HTML <<"CHOOSER_HEADER";
<CENTER>
<FONT FACE="verdana,arial,helvetica" SIZE=1 color=#999999>
&#149;&#149; click for background color &#149;&#149;
</FONT>
<TABLE border=1 bordercolor=#999999 cellpadding=0 cellspacing=0><tr><td valign=center align=center bgcolor=#eaeaea>
<FORM>
<TABLE border=0 bordercolor=#999999 cellpadding=0 cellspacing=0>
<TR valign=middle align=center bgcolor=#eaeaea>
CHOOSER_HEADER

    my $count = 0;
    foreach my $col (@colors) {
        if (++$count == 13) { print HTML "\n</tr><tr>\n"; }
        print HTML "<td><input type=button value=\"   \" onclick=\"document.bgColor='$col'\" style=\"background-color: #$col\"></td>\n";

    }
print HTML "</tr></table></td></tr></table></font></center>\n\n";

foreach my $file (sort @files)
{
    next unless (-d "$dir/$file" && $file ne ".");
    print HTML "<B><A HREF=\"$file/\">$file/</A></B><BR>\n";
}

print HTML "<TABLE CELLPADDING=2>\n";
foreach my $file (sort @files)
{
    next unless ($file =~ /\.gif$/);

    print HTML "<TR VALIGN=MIDDLE><TD>$file</TD>";
    print HTML "<TD><IMG SRC=\"$file\"></TD>";
    print HTML "</TR>\n";
}

print HTML "</TABLE></BODY></HTML>\n";

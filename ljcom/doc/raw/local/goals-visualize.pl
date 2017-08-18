#!/usr/bin/perl
#

use strict;
use Getopt::Long;

my $dir = "$ENV{'LJHOME'}/doc/raw/local/";
my $outdir = "$ENV{'LJHOME'}/htdocs/misc/goals";

my $opt_rand = 0;
exit 1 unless 
    GetOptions('random' => \$opt_rand);

my @ltime = localtime();
my $basefile = sprintf("goals-%04d%02d%02d", $ltime[5]+1900, $ltime[4]+1, $ltime[3]);

print "basefile: $basefile\n";

exit 1 
    unless ($opt_rand || 
            (stat("$dir/goals.dat"))[9] > (stat("$outdir/$basefile.html"))[9]);

open (I, "$dir/goals.dat");

open (O, ">$dir/goals.dot");
print O "digraph goals {\n";
print O "bgcolor=\"white\";\n";
print O "size=\"20,15\";\n";
print O "node [fontsize=17,fontname=\"Verdana\"]\n";
my %notes;
my %nodeid;
my $num = 0;
my @lines = <I>;
close I;

my @no_notes;
foreach (@lines) 
{
    chomp;
    s/\#.+//;
    
    if (/:/) {
        my ($k, $n) = split(/\s*:\s*/);
        $notes{$k} = $n;
        next;
    }
    push @no_notes, $_;
}
@lines = @no_notes;

if ($opt_rand) {
    srand;
    for (my $i=0; $i<@lines; $i++) {
        unshift @lines, splice(@lines, $i + int(rand(@lines-$i)), 1);
    }
}

foreach (@lines)
{
    my ($a, $b) = split(/\s*\-\>\s*/);
    next unless $a and $b;
    foreach my $t ($a, $b) {
        next if $nodeid{$t};
        my $id = "n" . (++$num);
        $nodeid{$t} = $id;
        my $label = "$t";
        my $color = "lightgray";
        if ($notes{$t} =~ s/\(X\)//) {
            $color = "green";
        } elsif ($notes{$t} =~ s/\(\+\)//) {
            $color = "yellow";
        } elsif ($notes{$t} =~ s/\(\-\)//) {
            $color = "white";
        }

        if ($notes{$t}) {
            $label .= "\\n($notes{$t})";
        }

        $color = $color ? ", color=\"black\", style=\"filled\", fillcolor=\"$color\"" : "";
        print O "$id [label=\"$label\" $color]\n";
    }
    print O "$nodeid{$a} -> $nodeid{$b}\n";
}

print O "}\n";
close O;

$ENV{'DOTFONTPATH'} = "/usr/share/fonts/truetype";
system("dot", "-Tgif", "-o", "$outdir/$basefile.gif", "$dir/goals.dot");
open (O, ">$outdir/$basefile.html");
printf O "<a href=\"/misc/goals.html\">Goals</a> as of: <i>%04d-%02d-%02d</i><p><img src='$basefile.gif'>",
    $ltime[5]+1900, $ltime[4]+1, $ltime[3];
close O;

print "Rebuilt.\n";

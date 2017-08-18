#!/usr/bin/perl
#

use strict;
use File::Find ();
use Getopt::Long;
die "\$LJHOME not set or invalid\n" unless -d $ENV{'LJHOME'};

my $opt_check = 0;
exit 1 unless GetOptions('check' => \$opt_check);

File::Find::find({
    wanted => \&wanted,
    no_chdir => 1,
}, map { "$ENV{'LJHOME'}/$_"} qw(bin cgi-bin htdocs));

sub wanted {
    return 0 unless m/\.(pl|bml|html)$/;

    open (F, $_);
    my $lnum = 0;
    my $contents;
    my $dirty = 0;
    while (my $line = <F>) {
        $lnum++;
        if ($line =~ s/\t/        /g) {
            print "$_:$lnum: tab\n";
            $dirty = 1;
        }
        if ($line =~ s/\s+\n$/\n/) {
            print "$_:$lnum: trailing space\n";
            $dirty = 1;
        }
        $contents .= $line;
    }
    close F;
}

#!/usr/bin/perl
#

use File::Copy;

unless (-e "/etc/my.cnf") {
    symlink "/etc/mysql/my.cnf", "/etc/my.cnf";
}

my %dfile;
foreach my $p (qw(mysql-common mysql-client mysql-server))
{
    foreach my $f (`dpkg -L $p`) {
	chomp $f;
	next unless -f $f;
	die "Dup: $f\n" if defined $dfile{$f};
	$dfile{$f} = $p;
    }
}
die "No mysql-server package installed?\n" unless %dfile;

my $mdir = readlink '/usr/src/mysql';
die "Symlink /usr/src/mysql does not point to binary mysql untar dir.\n" unless $mdir;
chdir $mdir or die;

my @mfiles;
my %cp;
foreach (`find . -type f`) {
    chomp;
    s!^\./!!;
    next if /^(mysql-test|sql-bench|support-files|tests|include|man)\//;
    next if m!^bin/safe_mysqld!;

    my $d = "/usr/$_";
    if ($_ eq "bin/mysqld") { $d = "/usr/sbin/mysqld"; }

    if ($dfile{$d}) {
	$cp{$_} = $d;
	print "  MATCH: $_ -> $cp{$_}\n";
	copy ($_, $d) or die "error copying file $_";
	next;
    }
    push @mfiles, $_;
}
foreach (@mfiles) {
    print "not copied: $_\n";
}


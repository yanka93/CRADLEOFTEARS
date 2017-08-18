#!/usr/bin/perl
#

my @errors;
my $err = sub {
    return unless @_;
    print STDERR "Problem:\n" . join('', map { "  * $_\n" } @_) . "\n";
    exit 1;
};

############################################################################
print "[Checking site-local config....]\n";
############################################################################

my %modules = (
               "Crypt::Cracklib" => { 'deb' => 'libcrypt-cracklib-perl',  
                                      'opt' => 'Provides checking of strong password.' },
               "GnuPG::Interface" => { 'deb' => 'libgnupg-interface-perl',  
                                      'opt' => 'Crypto and signed message authentication.' },
               "Inline" => { 'deb' => 'libinline-perl', },
               "Crypt::SSLeay" => {'deb' => "libcrypt-ssleay-perl", },
               "Geo::IP::PurePerl" => { 'opt' => "Provides IP to country mapping for stopping some CC fraud.", },
               );

my @debs;

foreach my $mod (sort keys %modules) {
    my $rv = eval "use $mod;";
    if ($@) {
        my $dt = $modules{$mod};
        if ($dt->{'opt'}) {
            print STDERR "Missing optional module $mod: $dt->{'opt'}\n";
        } else {
            push @errors, "Missing perl module: $mod";
        }
        push @debs, $dt->{'deb'} if $dt->{'deb'};
        next;
    }
    my $ver_want = $modules{$mod}{ver};
    my $ver_got = $mod->VERSION;
    if ($ver_want && $ver_got && $ver_got < $ver_want) {
        push @errors, "Out of date module: $mod (need $ver_want, $ver_got installed)";
    }
}

unless (-e "/usr/share/doc/aspell-en" || -e "/usr/local/share/aspell") {
    push @errors, "Spell check dictionary not installed?";
    push @debs, "aspell-en";
}

unless (-d "$ENV{'LJHOME'}/temp") {
    push @errors, "\$LJHOME/temp dir doesn't exist";
}
unless (-d "$ENV{'LJHOME'}/var") {
    push @errors, "\$LJHOME/var dir doesn't exist";
}

if (@debs && -e '/etc/debian_version') {
    print STDERR "\n# apt-get install ", join(' ', @debs), "\n\n";
}

$err->(@errors);

1;

#!/usr/bin/perl
#

package MultiCVS;
use strict;

BEGIN {
    use Carp            qw{confess croak};
    use IO::File        qw{};
    use File::Find      qw{find};
    use Fcntl           qw{O_RDONLY};

    use constant TRUE   => 1;
    use constant FALSE  => ();
}


### (CONSTRUCTOR) METHOD: new( $mainconfig )
### Create a new MultiCVS object.
sub new {
    my $proto = shift;
    my $class = ref $proto || $proto;
    my $mainconfig = shift;

    my $self = bless {
        dir_live        => '',
        dir_cvs         => '',

        directories     => undef,
        filemap         => undef,

        _debug          => undef,
    }, $class;

    # Read the first argument as the main config file, and try to find and read
    # any local variant after that.
    if ( $mainconfig ) {
        $self->read_config( $mainconfig, 1 );

        if ( $mainconfig =~ m{^(.+)multicvs.conf$} ) {
            my $localconf = "$1multicvs-local.conf";
            $self->read_config( $localconf );
        }
    }

    return $self;
}


sub debugmsg {
    my $self = shift or confess "Cannot be used as a function";
    return unless $self->{_debug};
    my ( $fmt, @args ) = @_;

    printf STDERR $fmt, @args;
}


### METHOD: read_config( $file[, $ismain] )
### Read the object's configuration from the given I<file>.
sub read_config {
    my ( $self, $file, $ismain ) = @_;

    my (
        $ifh,
        $line,
       );

    open $ifh, "<$file" or die "open: $file: $!";

    while ( <$ifh> ) {
        $line = $_;
        chomp $line;

        # Strip leading, trailing space and comments
        $line =~ s{(^\s+|#.*|\s+$)}{}g;
        next unless $line =~ /\S/;

        # Expand environment variables
        $line =~ s/\$(\w+)/$ENV{$1} or die "Environment variable \$$1 not set.\n"/ge;

        # Set key/value pair variables if this is the main config
        if ( $line =~ /(\w+)\s*=\s*(.+)/ ) {
            my ($k, $v) = ($1, $2);
            die "Included config files can't set variables such as $k.\n" unless $ismain;

            if ( $k eq "LIVEDIR" ) { $self->{dir_live} = $v }
            elsif ( $k eq "CVSDIR" ) { $self->{dir_cvs} = $v }
            else { die "Unknown option $k = $v\n"; }
        }

        # Set name<space>value pairs
        elsif (/(\S+)\s+(.+)/) {
            my ($from, $to) = ($1, $2);
            my $optional = 0;

            if ($from =~ s/\?$//) { $optional = 1; }

            push @{$self->{paths}}, {
                'from'     => $from,
                'to'       => $to,
                'optional' => $optional,
            };
        } else {
            die "Bogus config line in '$file': $line\n";
        }
    }
    close $ifh;

    # Clear any old entries
    $self->{directories} = $self->{files} = undef;

    return TRUE;
}


### METHOD: cvs_update( [$quiet] )
### Update the modules under multicvs's control, optionally with the quiet flag
### turned on.
sub cvs_update {
    my $self = shift or confess "can't be called as a function";
    my $quiet = shift || 0;

    my (
        $dir,
        $count,
       );

    $count = 0;

    # Do a 'cvs update' in directories that haven't been updated yet.
    foreach my $dir ( $self->directories ) {
        chdir $dir or die "chdir: $dir: $!\n";
        $self->debugmsg( "Updating CVS dir '$dir' ...\n" );
        system( "cvs", "update", "-dP" );

        $count++;
    }

    return $count;
}



### METHOD: directories()
### Returns a list of the top-level directories which should be checked for
### updates.
sub directories {
    my $self = shift or confess "cannot be used as a function";

    my (
        $root,
        $dir,
       );

    unless ( $self->{directories} ) {
        my %map = ();

        foreach my $path ( @{$self->{paths}} ) {

            # Get the root module which contains the file, fully-qualify it,
            # then add it to the map
            ( $root = $path->{from} ) =~ s!/.*!!;
            $dir = "$self->{dir_cvs}/$root";
            $map{ $dir } = 1 if -d $dir;
        }

        $self->{directories} = [ keys %map ];
    }

    return wantarray ? @{$self->{directories}} : $self->{directories};
}


### METHOD: filemap()
### Make a map of file paths to equivalent cvs path out of the multicvs
### configuration. Returns either a hash in list context or a hashref in scalar
### context.
sub filemap {
    my $self = shift or confess "can't be used as a function";

    unless ( $self->{filemap} ) {
        my (
            $from,
            $to,
            $cvsfile,
            $livefile,
            $selector,
            %files,
           );

        # Process each path from the config
        foreach my $path ( @{$self->{paths}} ) {

            $self->debugmsg( ">>> Mapping files under $path->{from}...\n" );

            # Calculate the fully-qualified source and destination paths
            $from = "$self->{dir_cvs}/$path->{from}";
            $to = "$self->{dir_live}/$path->{to}";

            # Trim leading dot from destination
            $to =~ s{/\.?/?$}{};
            $from =~ s{/\.?/?$}{};

            # Search the current directories for files.
            if ( -d $from ) {
                $self->debugmsg( "Adding files to the map from directory ${from} under ${to}\n" );

                # Selector proc -- discards backups, saves good files.
                $selector = sub {
                    my $name = $_;
                    $self->debugmsg( "  Examining '$name' in '${File::Find::dir}'...\n" );

                    # Skip all but the first dot-dir
                    if ( $name ne '.' || $File::Find::dir ne $from ) {

                        # Prune garbage
                        if ( $name eq '..'|| $name =~ m{^\.\#|\bCVS\b|~$} ) {
                            $File::Find::prune = 1;
                        }

                        # Add the file to the map after fully-qualifying the
                        # paths.
                        else {
                            $cvsfile = "${File::Find::dir}/${name}";
                            ( $livefile = $cvsfile ) =~ s{^$from}{$to}e;
                            $self->debugmsg( "  Adding file from %s to map as %s\n",
                                             $cvsfile, $livefile );

                            $files{ $livefile } = $cvsfile if -f $cvsfile;
                        }
                    }
                };

                # Now actually do the find
                File::Find::find( {wanted => $selector, follow => 1}, $from );
            }

            # Plain file -- just look to see if it exists in the cvs dir, adding
            # it if so, warning about it if not
            else {
                if ( -e $from ) {
                    $self->debugmsg( "Adding file ${from} to map as ${to}\n" );
                    $files{ $to } = $from;
                } else {
                    warn "WARNING: $from doesn't exist under $self->{dir_cvs}\n"
                        unless $path->{optional};
                }
            }
        }

        # Cache the results
        $self->{filemap} = \%files;
    }

    return wantarray ? %{$self->{filemap}} : $self->{filemap};
}



### METHOD: find_changed_files( [@files] )
### Returns a hash (or hashref in scalar context) of tuples describing changes
### which must be made to bring the cvs and live dirs into sync for the given
### I<files>, or for all files if no I<files> are given. Each entry in the hash
### is keyed by relative filename, and each value is a tuple (an arrayref) of
### the following form:
###
###  { from => $from_path, type => $direction, to => $to_path }
###
### where I<from_path> is the path to the newer file, I<direction> is either
### C<c> for a file which is newer in CVS or C<l> for a file which is newer in
### the live tree, and I<to_path> is the path to the older file that should be
### replaced.
sub find_changed_files {
    my $self = shift or confess "Cannot be called as a function";

    my $filemap = $self->filemap;
    my %tuples = ();

    my (
        $module,
        $relfile,
        $lfile,
        $cfile,
        $live_time,
        $cvs_time,
       );

    # Iterate over the list of relative files, fully-qualifying them and then
    # checking for up-to-dateness.
    while ( ($lfile, $cfile) = each %$filemap  ) {

        # Get the name of the cvs module for this entry, as well as the relative
        # path in the live site.
        ( $module = $cfile ) =~ s{(^$self->{dir_cvs}/|/.*)}{}g;
        ( $relfile = $lfile ) =~ s{^$self->{dir_live}/}{};

        # Fetch timestamps
        $live_time = -e $lfile ? (stat _)[9] : 0;
        $cvs_time  = -e $cfile ? (stat _)[9] : 0;

        $self->debugmsg( "Comparing: %s -> %s (%s): %d -> %d\n",
                         $lfile, $cfile, $relfile, $live_time, $cvs_time );

        # If either of them is newer, add an entry for it
        if ( $live_time > $cvs_time ) {
            $self->debugmsg( "  Live was newer: adding " );
            $tuples{ $relfile } = {
                from      => $lfile,
                type      => 'l',
                module    => $module,
                to        => $cfile,
                live_time => $live_time,
                cvs_time  => $cvs_time,
                diff      => undef,
               };
        } elsif ( $cvs_time > $live_time ) {
            $tuples{ $relfile } =  {
                from      => $cfile,
                type      => 'c',
                module    => $module,
                to        => $lfile,
                live_time => $live_time,
                cvs_time  => $cvs_time,
                diff      => undef,
               };
        }
    }

    return wantarray ? %tuples : \%tuples;
}


### METHOD: find_init_files( [@files] )
### Like find_changed_files(), but assumes that none of the given I<files> are
### extant on the live side (for --init).
sub find_init_files {
    my $self = shift or confess "Cannot be called as a function";

    my $filemap = $self->filemap;
    my %tuples = ();

    my (
        $module,
        $relfile,
        $lfile,
        $cfile,
        $cvs_time,
       );

    while ( ($lfile, $cfile) = each %$filemap  ) {
        ( $relfile = $cfile ) =~ s{^$self->{dir_cvs}/}{};
        ( $module = $relfile ) =~ s{/.*}{};

        # Fetch the mtime of the cvs file
        $cvs_time  = -e $cfile ? (stat _)[9] : 0;

        # Add an entry for every file
        $tuples{ $lfile } = {
            from      => $cfile,
            type      => 'c',
            module    => $module,
            to        => $lfile,
            live_time => 0,
            cvs_time  => $cvs_time,
        };
    }

    return wantarray ? %tuples : \%tuples;
}


# :TODO: This should really use Text::Diff or something instead of doing a bunch
# of forked reads...

### METHOD: get_diffs( \@options, @files )
### Given one or more tuples like those returned from find_changed_files(),
### return a list of diffs the diffs for each one.
sub get_diffs {
    my $self = shift or confess "Cannot be called as a function";
    my $options = ref $_[0] eq 'ARRAY' ? shift : [];

    my @files = @_;
    my @diffs = ();
    my $diff = undef;

    $self->debugmsg( "In get_diffs" );

    foreach my $tuple ( @files ) {

        # Reuse cached diffs
        if ( $tuple->{diff} ) {
            push @diffs, $tuple->{diff};
        }

        # Regular diff
        elsif ( -e $tuple->{from} && -e $tuple->{to} ) {
            $self->debugmsg( "Forking for real diff on $tuple->{from} -> $tuple->{to}" );
            $diff = $self->forkread( 'diff', @$options,
                                     $tuple->{to}, $tuple->{from} );
            $self->debugmsg( "Read diff: '", $diff, "'" );
            $tuple->{diff} = $diff;
            push @diffs, $diff;
        }

        # Simulate a diff for a new file
        else {
            $self->debugmsg( "Diff for new file $tuple->{from}" );
            $diff = sprintf " >>> New File <<<\n%s\n\n", $self->readfile( $tuple->{from} );
            $self->debugmsg( "Read diff: '", $diff, "'" );
            $tuple->{diff} = $diff;
            push @diffs, $diff;
        }
    }

    return @diffs;
}


### METHOD: readfile( $file )
### Return the specified file in and return it as a scalar.
sub readfile {
    my $self = shift or confess "cannot be used as a function";
    my $filename = shift;

    local $/ = undef;
    open( my $ifh, $filename, O_RDONLY ) or
        croak "open: $filename: $!";
    my $content = <$ifh>;

    return $content;
}


### METHOD: forkread( $cmd, @args )
### Fork and exec the specified I<cmd>, giving it the specified I<args>, and
### return the output of the command as a list of lines.
sub forkread {
    my $self = shift or confess "Cannot be used as a function";
    my ( $cmd, @args ) = @_;

    my (
        $fh,
        @lines,
        $pid,
       );

    # Fork-open and read the child's output as the parent
    if (( $pid = open($fh, "-|") )) {
        @lines = <$fh>;
        $fh->close;
    }

    # Child - capture output for diagnostics and progress display stuff.
    else {
        die "Couldn't fork: $!" unless defined $pid;

        open STDERR, ">&STDOUT" or die "Can't dup stdout: $!";
        { exec $cmd, @args };

        # Only reached if the exec() fails.
        close STDERR;
        close STDOUT;
        exit 1;
    }

    return wantarray ? @lines : join( '', @lines );
}



1;

__END__

# Local Variables:
# mode: perl
# c-basic-indent: 4
# indent-tabs-mode: nil
# End:

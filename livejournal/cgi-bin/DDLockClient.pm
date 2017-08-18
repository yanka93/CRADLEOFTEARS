#!/usr/bin/perl
###########################################################################

=head1 NAME

DDLockClient - Client library for distributed lock daemon

=head1 SYNOPSIS

  use DDLockClient ();

  my $cl = new DDLockClient (
	servers => ['locks.localnet:7004', 'locks2.localnet:7002', 'localhost']
  );

  # Do something that requires locking
  if ( my $lock = $cl->trylock("foo") ) {
    ...do some 'foo'-synchronized stuff...
  } else {
    die "Failed to lock 'foo': $!";
  }

  # You can either just let $lock go out of scope or explicitly release it:
  $lock->release;

=head1 DESCRIPTION

This is a client library for ddlockd, a distributed lock daemon not entirely
unlike a very simplified version of the CPAN module IPC::Locker.

=head1 REQUIRES

L<Socket>

=head1 EXPORTS

Nothing.

=head1 AUTHOR

Brad Fitzpatrick <brad@danga.com>

Copyright (c) 2004 Danga Interactive, Inc.

=cut

###########################################################################

#####################################################################
###	D D L O C K   C L A S S
#####################################################################
package DDLock;

BEGIN {
    use Socket qw{:DEFAULT :crlf};
    use IO::Socket::INET ();

    use constant DEFAULT_PORT => 7002;

    use fields qw( name sockets pid );
}



### (CONSTRUCTOR) METHOD: new( $name, @sockets )
### Create a new lock object that corresponds to the specified I<name> and is
### held by the given I<sockets>.
sub new {
    my DDLock $self = shift;
    $self = fields::new( $self ) unless ref $self;

    $self->{pid} = $$;
    $self->{name} = shift;
    $self->{sockets} = $self->getlocks( $self->{name}, @_ );

    return $self;
}


### (PROTECTED) METHOD: getlocks( $lockname, @servers )
### Try to obtain locks with the specified I<lockname> from one or more of the
### given I<servers>.
sub getlocks {
    my DDLock $self = shift;
    my $lockname = shift;
    my @servers = @_;

    my (
        @sockets,
        $sock,
        $res,
       );

    # First create connected sockets to all the lock hosts
    @sockets = ();
  SERVER: foreach my $server ( @servers ) {
        my ( $host, $port ) = split /:/, $server;
        $port ||= DEFAULT_PORT;

        my $sock = new IO::Socket::INET (
            PeerAddr    => $host,
            PeerPort    => $port,
            Proto       => "tcp",
            Type        => SOCK_STREAM,
            ReuseAddr   => 1,
            Blocking    => 1,
           ) or next SERVER;

        $sock->printf( "trylock lock=%s%s", eurl($lockname), CRLF );
        chomp( $res = <$sock> );
        die "$server: '$lockname' $res\n" unless $res =~ m{^ok\b}i;

        push @sockets, $sock;
    }

    die "No available lock hosts" unless @sockets;
    return \@sockets;
}


### METHOD: release()
### Release the lock held by the lock object. Returns the number of sockets that
### were released on success, and dies with an error on failure.
sub release {
    my DDLock $self = shift;

    my (
        $count,
        $res,
        $sock,
       );

    # lock server might have gone away, but we don't really care.
    local $SIG{'PIPE'} = "IGNORE";

    $count = 0;
    while (( $sock = shift @{$self->{sockets}} )) {
        $sock->printf( "releaselock lock=%s%s", eurl($self->{name}), CRLF );
        chomp( $res = <$sock> );

        if ( $res && $res !~ m{^ok\b}i ) {
            my $port = $sock->peerport;
            my $addr = $sock->peerhost;
            die "releaselock ($addr): $res\n";
        }

        $count++;
    }

    return $count;
}


### FUNCTION: eurl( $arg )
### URL-encode the given I<arg> and return it.
sub eurl
{
    my $a = $_[0];
    $a =~ s/([^a-zA-Z0-9_,.\\: -])/uc sprintf("%%%02x",ord($1))/eg;
    $a =~ tr/ /+/;
    return $a;
}



#####################################################################
###	D D F I L E L O C K   C L A S S
#####################################################################
package DDFileLock;

BEGIN {
    use Fcntl qw{:DEFAULT :flock};
    use File::Spec qw{};
    use File::Path qw{mkpath};
    use IO::File qw{};

    use fields qw{name path tmpfile pid};
}


our $TmpDir = File::Spec->tmpdir;

### (CONSTRUCTOR) METHOD: new( $lockname )
### Createa a new file-based lock with the specified I<lockname>.
sub new {
    my DDFileLock $self = shift;
    $self = fields::new( $self ) unless ref $self;
    my ( $name, $lockdir ) = @_;

    $self->{pid} = $$;

    $lockdir ||= $TmpDir;
    if ( ! -d $lockdir ) {
        # Croaks if it fails, so no need for error-checking
        mkpath $lockdir;
    }

    my $lockfile = File::Spec->catfile( $lockdir, eurl($name) );

    # First open a temp file
    my $tmpfile = "$lockfile.$$.tmp";
    if ( -e $tmpfile ) {
        unlink $tmpfile or die "unlink: $tmpfile: $!";
    }

    my $fh = new IO::File $tmpfile, O_WRONLY|O_CREAT|O_EXCL
        or die "open: $tmpfile: $!";
    $fh->close;
    undef $fh;

    # Now try to make a hard link to it
    link( $tmpfile, $lockfile )
        or die "link: $tmpfile -> $lockfile: $!";
    unlink $tmpfile or die "unlink: $tempfile: $!";

    $self->{path} = $lockfile;
    $self->{tmpfile} = $tmpfile;

    return $self;
}


### METHOD: release()
### Release the lock held by the object.
sub release {
    my DDFileLock $self = shift;
    return unless $self->{path};
    unlink $self->{path} or die "unlink: $self->{path}: $!";
    unlink $self->{tmpfile};
}


### FUNCTION: eurl( $arg )
### URL-encode the given I<arg> and return it.
sub eurl
{
    my $a = $_[0];
    $a =~ s/([^a-zA-Z0-9_,.\\: -])/sprintf("%%%02X",ord($1))/eg;
    $a =~ tr/ /+/;
    return $a;
}


DESTROY {
    my $self = shift;
    $self->release if $$ == $self->{pid};
}


#####################################################################
###	D D L O C K C L I E N T   C L A S S
#####################################################################
package DDLockClient;
use strict;

BEGIN {
    use fields qw( servers lockdir );
    use vars qw{$Error};
}

$Error = undef;

our $Debug = 0;


### (CLASS) METHOD: DebugLevel( $level )
sub DebugLevel {
    my $class = shift;

    if ( @_ ) {
        $Debug = shift;
        if ( $Debug ) {
            *DebugMsg = *RealDebugMsg;
        } else {
            *DebugMsg = sub {};
        }
    }

    return $Debug;
}


sub DebugMsg {}


### (CLASS) METHOD: DebugMsg( $level, $format, @args )
### Output a debugging messages formed sprintf-style with I<format> and I<args>
### if I<level> is greater than or equal to the current debugging level.
sub RealDebugMsg {
    my ( $class, $level, $fmt, @args ) = @_;
    return unless $Debug >= $level;

    chomp $fmt;
    printf STDERR ">>> $fmt\n", @args;
}


### (CONSTRUCTOR) METHOD: new( %args )
### Create a new DDLockClient 
sub new {
    my DDLockClient $self = shift;
    my %args = @_;

    $self = fields::new( $self ) unless ref $self;
    die "Servers argument must be an arrayref if specified"
        unless !exists $args{servers} || ref $args{servers} eq 'ARRAY';
    $self->{servers} = $args{servers} || [];
    $self->{lockdir} = $args{lockdir} || '';

    return $self;
}


### METHOD: trylock( $name )
### Try to get a lock from the lock daemons with the specified I<name>. Returns
### a DDLock object on success, and undef on failure.
sub trylock {
    my DDLockClient $self = shift;
    my $lockname = shift;

    my $lock;

    # If there are servers to connect to, use a network lock
    if ( @{$self->{servers}} ) {
        $self->DebugMsg( 2, "Creating a new DDLock object." );
        $lock = eval { DDLock->new($lockname, @{$self->{servers}}) };
    }

    # Otherwise use a file lock
    else {
        $self->DebugMsg( 2, "No servers configured: Creating a new DDFileLock object." );
        $lock = eval { DDFileLock->new($lockname, $self->{lockdir}) };
    }

    # If no lock was acquired, fail and put the reason in $Error.
    unless ( $lock ) {
        return $self->lock_fail( $@ ) if $@;
        return $self->lock_fail( "Unknown failure." );
    }

    return $lock;
}


### (PROTECTED) METHOD: lock_fail( $msg )
### Set C<$!> to the specified message and return undef.
sub lock_fail {
    my DDLockClient $self = shift;
    my $msg = shift;

    $Error = $msg;
    return undef;
}


1;


# Local Variables:
# mode: perl
# c-basic-indent: 4
# indent-tabs-mode: nil
# End:

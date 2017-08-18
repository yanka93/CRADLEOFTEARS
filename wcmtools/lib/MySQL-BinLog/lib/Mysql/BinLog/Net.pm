#!/usr/bin/perl
##############################################################################

=head1 NAME

MySQL::BinLog::Net - Read binlog events from a master server over the network.

=head1 SYNOPSIS

  use MySQL::BinLog     qw{};

  my %connect_params = (
      hostname    => 'db.example.com',
      database    => 'sales',
      user        => 'salesapp',
      password    => 'bloo$shewz',
      port        => 3306,
  );
  my $log = MySQL::BinLog->connect( %connect_params )
    or die "Couldn't connect.";


=head1 REQUIRES

I<Net::MySQL>, I<Carp>

=head1 DESCRIPTION

None yet.

=head1 AUTHOR

Michael Granger <ged@Danga.com>

Copyright (c) 2004 Danga Interactive. All rights reserved.

This module is free software. You may use, modify, and/or redistribute this
software under the terms of the Perl Artistic License. (See
http://language.perl.com/misc/Artistic.html)

THIS SOFTWARE IS PROVIDED "AS IS" AND WITHOUT ANY EXPRESS OR IMPLIED WARRANTIES,
INCLUDING, WITHOUT LIMITATION, THE IMPLIED WARRANTIES OF MERCHANTIBILITY AND
FITNESS FOR A PARTICULAR PURPOSE.

=cut

##############################################################################
package MySQL::BinLog::Net;
use strict;
use warnings qw{all};


###############################################################################
###  I N I T I A L I Z A T I O N
###############################################################################
BEGIN {
	# Versioning stuff
	use vars qw{$VERSION $RCSID};
	$VERSION	= do { my @r = (q$Revision: 1.2 $ =~ /\d+/g); sprintf "%d."."%02d" x $#r, @r };
	$RCSID	= q$Id: Net.pm,v 1.2 2004/11/17 21:58:40 marksmith Exp $;

    use Net::MySQL  qw{};
    use Carp        qw{carp croak confess};
    use base        qw{Net::MySQL};

    use constant    CHUNKSIZE   => 16;
    use constant    PKTHEADER_LEN => (3 + 1 + 1);
}


### METHOD: start_binlog( $slave_id[, $logname, $position, $flags] )
### Contact the remote server and send the command to start reading binlog
### events from the given I<logname>, I<position>, I<slave_id>, and optional
### I<flags>.
sub start_binlog {
    my $self = shift;
    my ( $slave_server_id, $logname, $pos, $flags ) = @_;

    # New log: no logname and position = 4
    $logname ||= '';
    $pos = 4 unless defined $pos && $pos > 4;

    my (
        $len,
        $cmd,
        $packet,
        $mysql,
       );

    # Build the BINLOG_DUMP packet
    $cmd = Net::MySQL::COMMAND_BINLOG_DUMP;
    $flags ||= 0;
    $len = 1 + 4 + 2 + 4 + length( $logname );
    $packet = pack( 'VaVvVa*', $len, $cmd, $pos, $flags, $slave_server_id, $logname );
    $mysql = $self->{socket};

    # Send it
    $mysql->send( $packet, 0 );
    $self->_dump_packet( $packet ) if $self->debug;

    # Receive the response
    my $result = $self->read_packet;

    # FIXME I broke error checking by switching to read_packet instead of using
    # recv... but recv reads a full buffer's worth, which just gets tossed and
    # causes subsequent read_packe calls to start at arbitrary positions and fail.
    # real solution is to make read_packet set error flags and then have callers
    # check them.  eventually.  oh, FYI, you have to reconstitute the packet before
    # passing it on to _is_error and _set_error_by_packet, as those are in Net::MySQL
    # and expect the whole packet, not just the payload that read_packet returns.
    #return $self->_set_error_by_packet( $result ) if $self->_is_error( $result );

    return 1;
}


### METHOD: read_packet( )
### Read a single packet from the connection and return its payload as a scalar.
sub read_packet {
    my $self = shift;

    my $pkt_header = $self->readbytes( PKTHEADER_LEN );
    my $length = unpack( 'V', substr($pkt_header, 0, 3, '') . "\0" ) - 1;
    my ( $pktno, $cmd ) = unpack( 'CC', $pkt_header );

    my $pkt = $self->readbytes( $length );
    $self->_dump_packet( $pkt ) if $self->debug;

    return $pkt;
}


### FUNCTION: readbytes( $len )
### Read and return I<len> bytes from the connection.
sub readbytes {
    my ( $self, $len ) = @_;
    my ( $buf, $rval, $bytes ) = ('', '', 0);

    my $sock = $self->{socket};

    until ( length $rval == $len ) {
        $bytes = $sock->read( $buf, $len - length $rval );
        if ( !defined $bytes ) {
            if ( $!{EAGAIN} ) { next }
            die "Read error: $!";
        } elsif ( !$bytes && $sock->eof ) {
            die "EOF before reading $len bytes.\n";
        }
        $rval .= $buf;
    }

    return $rval;
}



### Utility/debugging methods (overridden).

sub hexdump { join ' ', map {sprintf "%02x", ord $_} grep {defined} @_ }
sub ascdump { join '', map {m/[\d \w\._]/ ? $_ : '.'} grep {defined} @_ }

sub _dump_packet {
	my $self = shift;
	my $packet = shift;

    my (
        $method_name,
        @bytes,
        @chunk,
        $half,
        $width,
        $count,
       );

    $method_name = (caller(1))[3];
    print "$method_name:\n";

    @bytes = split //, $packet;
    $count = 0;
    while ( @bytes ) {
        @chunk = grep { defined } splice( @bytes, 0, CHUNKSIZE );
        $half = CHUNKSIZE / 2;
        $width = $half * 3;

        printf( "  0x%04x: %-${width}s  %-${width}s |%-${half}s %-${half}s|\n",
                $count,
                hexdump( @chunk[0..($half-1)] ),
                hexdump( @chunk[$half..$#chunk] ),
                ascdump( @chunk[0..($half-1)] ),
                ascdump( @chunk[$half..$#chunk] ) );

        $count += CHUNKSIZE;
    }

	print "--\n";
}



### Destructors
DESTROY {}
END {}


1;



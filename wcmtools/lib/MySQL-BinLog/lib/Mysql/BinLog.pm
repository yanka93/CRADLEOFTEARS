#!/usr/bin/perl
##############################################################################

=head1 NAME

MySQL::BinLog - Binary log parser classes

=head1 SYNOPSIS

  use MySQL::BinLog ();

  my $log = MySQL::BinLog->open( "Foo-relay.bin.001" );

  # -or-

  die unless $MySQL::BinLog::HaveNet;
  my $log = MySQL::BinLog->connect(
      hostname      => 'db.example.com',
      database      => 'sales',
      user          => 'salesapp',
      password      => '',
      port          => 3337,

      log_name      => '',
      log_pos       => 4,
      log_slave_id  => 10,
  );

  $log->handle_events( \&print_queries, MySQL::BinLog::QUERY_EVENT );

  sub print_queries {
    my $ev = shift;
    print "Query: ", $ev->query_data, "\n";
  }


=head1 REQUIRES

I<Token requires line>

=head1 DESCRIPTION

This is a collection of Perl classes for parsing a MySQL binlog.

=head1 AUTHOR

Michael Granger <ged@FaerieMUD.org>

Copyright (c) 2004 Danga Interactive. All rights reserved.

This module is free software. You may use, modify, and/or redistribute this
software under the terms of the Perl Artistic License. (See
http://language.perl.com/misc/Artistic.html)

THIS SOFTWARE IS PROVIDED "AS IS" AND WITHOUT ANY EXPRESS OR IMPLIED WARRANTIES,
INCLUDING, WITHOUT LIMITATION, THE IMPLIED WARRANTIES OF MERCHANTIBILITY AND
FITNESS FOR A PARTICULAR PURPOSE.

=cut

##############################################################################
package MySQL::BinLog;
use strict;
use warnings qw{all};

BEGIN {
	# Versioning stuff
	use vars qw{$VERSION $RCSID};
	$VERSION	= do { my @r = (q$Revision: 1.2 $ =~ /\d+/g); sprintf "%d."."%02d" x $#r, @r };
	$RCSID	= q$Id: BinLog.pm,v 1.2 2004/11/17 21:58:39 marksmith Exp $;

    use constant TRUE => 1;
    use constant FALSE => 0;

    # Subordinate classes
    use MySQL::BinLog::Constants    qw{};
    use MySQL::BinLog::Events       qw{};
    use MySQL::BinLog::Header       qw{};

    # Try to load Net::MySQL, but no worries if we can't until they try to use
    # ->connect.
    use vars qw{$HaveNet $NetError};
    $HaveNet = eval { require MySQL::BinLog::Net; 1 };
    $NetError = $@;

    use Carp qw{croak confess carp};
    use IO::File qw{};
    use Fcntl qw{O_RDONLY};
}


### (CONSTRUCTOR) METHOD: new
### Return a new generic MySQL::BinLog object.
sub new {
    my $class = shift or confess "Cannot be used as a function";
    return bless {
        fh => undef,
        type => undef,
    }, $class;
}


### (CONSTRUCTOR) METHOD: open( $filename )
### Return a MySQL::BinLog object that will read events from the file specified
### by I<filename>.
sub open {
    my $class = shift or confess "Cannot be used as a function";
    my $filename = shift or croak "Missing argument: filename";

    my $ifh = new IO::File $filename, O_RDONLY
        or croak "open: $filename: $!";
    $ifh->seek( 4, 0 );

    my $self = $class->new;
    $self->{fh} = $ifh;

    return $self;
}


### (CONSTRUCTOR) METHOD: connect( %connect_params )
### Open a connection to a MySQL server over the network and read events from
### it. The connection parameters are the same as those passed to Net::MySQL. If
### Net::MySQL is not installed, this method will raise an exception.
sub connect {
    my $class = shift or confess "Cannot be used as a function";
    my %connect_params = @_;

    croak "Net::MySQL not available: $NetError" unless $HaveNet;
    my $self = $class->new;

    my (
        $logname,
        $pos,
        $slave_id,
       );

    $logname  = delete $connect_params{log_name} || '';
    $pos      = delete $connect_params{log_pos} || 0;
    $slave_id = delete $connect_params{log_slave_id} || 128;

    $self->{net} = new MySQL::BinLog::Net ( %connect_params );
    $self->{net}->start_binlog( $slave_id, $logname, $pos );

    return $self;
}


#####################################################################
###	I N S T A N C E   M E T H O D S
#####################################################################


### METHOD: read_next_event()
### Read the next event from the registered source and return it.
sub read_next_event {
    my $self = shift;

    # :FIXME: This is some ugly inexcusably ugly shit, but I'm hacking all the
    # IO into here to get something working, but it really should be made
    # cleaner by separating out the socket IO routine into the ::Net class and
    # the file IO into a new File class that reads from a file in an optimized
    # fashion.

    my $event_data;

    # Reading from a file -- have to read the header, figure out the length of
    # the rest of the event data, then read the rest.
    if ( $self->{fh} ) {
        $event_data = $self->readbytes( $self->{fh}, MySQL::LOG_EVENT_HEADER_LEN );
        my $len = unpack( 'V', substr($event_data, 9, 4) );
        $event_data .= $self->readbytes( $self->{fh},
                                         $len - MySQL::LOG_EVENT_HEADER_LEN );
    }

    # Reading from a real master
    elsif ( $self->{net} ) {
        $event_data = $self->{net}->read_packet;
    }

    # An object without a reader
    else {
        croak "Cannot read without an event source.";
    }

    # Let the event class parse the event
    return MySQL::BinLog::Event->read_event( $event_data );
}




### METHOD: handle_events( \&handler[, @types] )
### Start reading events from whatever source is registered, handling those of
### the types specified in I<types> with the given I<handler>. If no I<types>
### are given, all events will be sent to the I<handler>. Events are sent as
### instances of the MySQL::BinLog::Event classes.
sub handle_events {
    my $self = shift or croak "Cannot be used as a function.";
    my ( $handler, @types ) = @_;

    my @rv = ();

    while (( my $event = $self->read_next_event )) {
        my $etype = $event->header->event_type;
        next if @types && !grep { $etype == $_ } @types;

        push @rv, $handler->( $event );
    }

    return @rv;
}


### FUNCTION: readbytes( $fh, $len )
### Read and return I<len> bytes from the specified I<fh>.
sub readbytes {
    my ( $self, $fh, $len ) = @_;
    my ( $buf, $rval, $bytes ) = ('', '', 0);

    until ( length $rval == $len ) {
        $bytes = $fh->read( $buf, $len - length $rval );
        if ( !defined $bytes ) {
            if ( $!{EAGAIN} ) { next }
            die "Read error: $!";
        } elsif ( !$bytes && $fh->eof ) {
            die "EOF before reading $len bytes.\n";
        }
        $rval .= $buf;
    }

    return $rval;
}



### Destructors
DESTROY {}
END {}


1;



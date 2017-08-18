#!/usr/bin/perl
##############################################################################

=head1 NAME

MySQL::BinLog::Header - Per-event MySQL binlog header class

=head1 SYNOPSIS

  use MySQL::BinLog::Header qw();
  use MySQL::Constants qw(LOG_EVENT_HEADER_LEN);

  my $hdata = substr( $data, 0, LOG_EVENT_HEADER_LEN );
  my $header = new MySQL::BinLog::Header $hdata;

  $header->event_type;
  $header->server_id;
  $header->event_len;
  $header->log_pos;
  $header->flags;

=head1 REQUIRES

I<Token requires line>

=head1 DESCRIPTION

None yet.

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
package MySQL::BinLog::Header;
use strict;
use warnings qw{all};


###############################################################################
###  I N I T I A L I Z A T I O N
###############################################################################
BEGIN {
	# Versioning stuff and custom includes
	use vars qw{$VERSION $RCSID};
	$VERSION	= do { my @r = (q$Revision: 1.2 $ =~ /\d+/g); sprintf "%d."."%02d" x $#r, @r };
	$RCSID	= q$Id: Header.pm,v 1.2 2004/11/17 21:58:40 marksmith Exp $;

    # Data format template and fields definition
    use constant PACK_TEMPLATE => 'VcVVVv';
    use fields qw{timestamp event_type server_id event_len log_pos flags};
    use base qw{fields};

    # MySQL modules
    use MySQL::BinLog::Constants qw{:all};

    # Other modules
    use Data::Dumper;
    use Scalar::Util qw{blessed};
}


our $AUTOLOAD;


### (CONSTRUCTOR) new( $data )
### Construct a new MySQL::BinLog::::Header object from the given header data.
sub new {
    my MySQL::BinLog::Header $self = shift;
    my $data = shift || '';

    debugMsg( "Creating a new ", __PACKAGE__, " object for header: ",
              hexdump($data), ".\n" );
    die "Invalid header" unless length $data == MySQL::LOG_EVENT_HEADER_LEN;
    $self = fields::new( $self ) unless ref $self;

    # Extract the fields or provide defaults
    my @fields = ();
    if ( $data ) {
        @fields = unpack PACK_TEMPLATE, $data;
        debugMsg( "Unpacked fields are: ", Data::Dumper->Dumpxs([\@fields], [qw{fields}]), "\n" );
    } else {
        @fields = ( time, MySQL::UNKNOWN_EVENT, 0, 0, 0, 0 );
    }

    @{$self}{qw{timestamp event_type server_id event_len log_pos flags}} = @fields;

    debugMsg( "Returning header: ", Data::Dumper->Dumpxs([$self]), ".\n" );
    return $self;
}


# Accessor-generator

### (PROXY) METHOD: AUTOLOAD( @args )
### Proxy method to build (non-translucent) object accessors.
sub AUTOLOAD {
	my MySQL::BinLog::Header $self = shift;
	( my $name = $AUTOLOAD ) =~ s{.*::}{};

	### Build an accessor for extant attributes
	if ( blessed $self && exists $self->{$name} ) {

		### Define an accessor for this attribute
		my $method = sub {
			my MySQL::BinLog::Header $closureSelf = shift;

			$closureSelf->{$name} = shift if @_;
			return $closureSelf->{$name};
		};

		### Install the new method in the symbol table
	  NO_STRICT_REFS: {
			no strict 'refs';
			*{$AUTOLOAD} = $method;
		}

		### Now jump to the new method after sticking the self-ref back onto the
		### stack
		unshift @_, $self;
		goto &$AUTOLOAD;
	}

	### Try to delegate to our parent's version of the method
	my $parentMethod = "SUPER::$name";
	return $self->$parentMethod( @_ );
}



### Utility functions

#sub debugMsg { print STDERR @_ }
sub debugMsg {}
sub hexdump { return join( ' ', map {sprintf '%02x', ord($_)} split('', $_[0])) }



### Destructors
DESTROY {}
END {}


1;



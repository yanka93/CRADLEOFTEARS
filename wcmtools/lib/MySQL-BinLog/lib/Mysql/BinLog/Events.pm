#!/usr/bin/perl
##############################################################################

=head1 NAME

MySQL::BinLog::Event - Event class for MySQL binlog parsing

=head1 SYNOPSIS

  use MySQL::BinLog::Event qw();

  my $event = MySQL::BinLog::Event->read_event( $header, $data );

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
package MySQL::BinLog::Event;
use strict;
use warnings qw{all};


###############################################################################
###  I N I T I A L I Z A T I O N
###############################################################################
BEGIN {
	### Versioning stuff and custom includes
	use vars qw{$VERSION $RCSID};
	$VERSION	= do { my @r = (q$Revision: 1.2 $ =~ /\d+/g); sprintf "%d."."%02d" x $#r, @r };
	$RCSID	= q$Id: Events.pm,v 1.2 2004/11/17 21:58:40 marksmith Exp $;

    # MySQL classes
    use MySQL::BinLog::Header qw{};
    use Carp qw{croak confess carp};
    use Scalar::Util qw{blessed};

    use fields qw{header rawdata};
    use base qw{fields};
}

our $AUTOLOAD;

# Maps an event type to a subclass
our @ClassMap = qw(
    UnknownEvent
    StartEvent
    QueryEvent
    StopEvent
    RotateEvent
    IntvarEvent
    LoadEvent
    SlaveEvent
    CreateFileEvent
    AppendBlockEvent
    ExecLoadEvent
    DeleteFileEvent
    NewLoadEvent
    RandEvent
    UserVarEvent
);


### (FACTORY) METHOD: read_event( $fh )
### Read the next event from the given string I<str> and return it as a
### C<MySQL::BinLog::Event> object.
sub read_event {
    my $class = shift;
    my $rawdata = shift;
    my @desired_types = @_;

    my (
        $hdata,
        $header,
        $datalen,
        $event_data,
        $reallen,
        $event_class,
       );

    debugMsg( "Reading event from ", length $rawdata, " byes of raw data.\n" );

    # Read the header data and create the header object
    # :TODO: only handles "new" headers; old headers are shorter. Need to
    # document which version this changed and mention this in the docs.
    $hdata = substr( $rawdata, 0, MySQL::LOG_EVENT_HEADER_LEN, '' );
    $header = new MySQL::BinLog::Header $hdata;

    # Read the event data
    $datalen = $header->{event_len} - MySQL::LOG_EVENT_HEADER_LEN;
    debugMsg( "Event data is $header->{event_len} bytes long.\n" );
    $event_data = substr( $rawdata, 0, $datalen, '' );
    debugMsg( "Read ", length $event_data, " bytes of event data.\n" );

    $reallen = length $event_data;
    croak "Short read for event data ($reallen of $datalen bytes)"
        unless $reallen == $datalen;

    # Figure out which class implements the event type and create one with the
    # header and data
    $event_class = sprintf "MySQL::BinLog::%s", $ClassMap[ $header->{event_type} ];
    return $event_class->new( $header, $event_data );
}



### (CONSTRUCTOR) METHOD: new( $header, $raw_data )
### Construct a new Event with the specified I<header> and I<raw_data>. This is
### only meant to the called from a subclass.
sub new {
    my MySQL::BinLog::Event $self = shift;
    my ( $header, $data ) = @_;

    die "Instantiation of abstract class" unless ref $self;

    $self->{header}     = $header;
    $self->{rawdata}    = $data;

    return $self;
}


# Accessor-generator

### (PROXY) METHOD: AUTOLOAD( @args )
### Proxy method to build (non-translucent) object accessors.
sub AUTOLOAD {
	my MySQL::BinLog::Event $self = shift;
	( my $name = $AUTOLOAD ) =~ s{.*::}{};

	### Build an accessor for extant attributes
	if ( blessed $self && exists $self->{$name} ) {

		### Define an accessor for this attribute
		my $method = sub {
			my MySQL::BinLog::Event $closureSelf = shift;

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





### Destructors
DESTROY {}
END {}


### Utility functions

### Debugging function -- switch the commented one for debugging or no.
sub debugMsg {}
#sub debugMsg { print STDERR @_ }



#####################################################################
###	S T A R T E V E N T   C L A S S
#####################################################################
package MySQL::BinLog::StartEvent;
use strict;

BEGIN {
    use base 'MySQL::BinLog::Event';
    use fields qw{binlog_ver server_ver created};

    use constant PACK_TEMPLATE => 'va8a*';
}


### (CONSTRUCTOR) METHOD: new( $header_obj, $raw_data )
### Create a new StartEvent object from the given I<raw_data> and I<header_obj>
### (a MySQL::BinLog::Header object).
sub new {
    my MySQL::BinLog::StartEvent $self = shift;

    $self = fields::new( $self );
    $self->SUPER::new( @_ );

    if ( $self->{rawdata} ) {
        my @fields = unpack PACK_TEMPLATE, $self->{rawdata};
        @{$self}{qw{binlog_ver server_ver created}} = @fields;
    }

    return $self;
}


### METHOD: stringify()
### Return a representation of the event as a human-readable string.
sub stringify {
    my MySQL::BinLog::StartEvent $self = shift;
    return join( ':', @{$self}{qw{binlog_ver server_ver created}} );
}



#####################################################################
###	Q U E R Y E V E N T   C L A S S
#####################################################################
package MySQL::BinLog::QueryEvent;
use strict;

BEGIN {
    use base 'MySQL::BinLog::Event';
    use fields qw{thread_id exec_time db_len err_code dbname query_data};

    # 4 + 4 + 1 + 2 + variable length data field.
    use constant PACK_TEMPLATE => 'VVCva*';
}


### (CONSTRUCTOR) METHOD: new( $header_obj, $raw_data )
### Create a new QueryEvent object from the given I<raw_data> and I<header_obj>
### (a MySQL::BinLog::Header object).
sub new {
    my MySQL::BinLog::QueryEvent $self = shift;

    $self = fields::new( $self );
    $self->SUPER::new( @_ );

    if ( $self->{rawdata} ) {
        my @fields = unpack PACK_TEMPLATE, $self->{rawdata};

        # The last bit needs further unpacking with a length that is in the data
        # extracted via the first template. If db_len immediately preceded the
        # query data it could all be done in one unpack with 'c/a' or something,
        # but alas...
        my $template = sprintf( 'a%da*', $fields[2] ); # $fields[2] = length of dbname
        push @fields, unpack( $template, pop @fields );

        @{$self}{qw{thread_id exec_time db_len err_code dbname query_data}} = @fields;
    }

    return $self;
}


### METHOD: stringify()
### Return a representation of the event as a human-readable string.
sub stringify {
    my MySQL::BinLog::QueryEvent $self = shift;
    return join( ':', @{$self}{qw{thread_id exec_time db_len err_code dbname query_data}} );
}


#####################################################################
###	S T O P E V E N T   C L A S S
#####################################################################
package MySQL::BinLog::StopEvent;
use strict;

BEGIN {
    use base 'MySQL::BinLog::Event';
    use fields qw{}; # Stop event has no fields
}


### (CONSTRUCTOR) METHOD: new( $header_obj, $raw_data )
### Create a new StopEvent object from the given I<raw_data> and I<header_obj>
### (a MySQL::BinLog::Header object).
sub new {
    my MySQL::BinLog::StopEvent $self = shift;

    $self = fields::new( $self );
    $self->SUPER::new( @_ );

    return $self;
}


### METHOD: stringify()
### Return a representation of the event as a human-readable string.
sub stringify {
    my MySQL::BinLog::StopEvent $self = shift;
    return join( ':', @{$self}{qw{}} );
}


#####################################################################
###	R O T A T E E V E N T   C L A S S
#####################################################################
package MySQL::BinLog::RotateEvent;
use strict;

BEGIN {
    use base 'MySQL::BinLog::Event';
    use fields qw{pos ident};

    use constant PACK_TEMPLATE => 'a8';
}


### (CONSTRUCTOR) METHOD: new( $header_obj, $raw_data )
### Create a new RotateEvent object from the given I<raw_data> and I<header_obj>
### (a MySQL::BinLog::Header object).
sub new {
    my MySQL::BinLog::RotateEvent $self = shift;

    $self = fields::new( $self );
    $self->SUPER::new( @_ );

    if ( $self->{rawdata} ) {
        my @fields = unpack PACK_TEMPLATE, $self->{rawdata};
        @{$self}{qw{pos ident}} = @fields;
    }

    return $self;
}


### METHOD: stringify()
### Return a representation of the event as a human-readable string.
sub stringify {
    my MySQL::BinLog::RotateEvent $self = shift;
    return join( ':', @{$self}{qw{pos ident}} );
}


#####################################################################
###	I N T V A R E V E N T   C L A S S
#####################################################################
package MySQL::BinLog::IntvarEvent;
use strict;

BEGIN {
    use base 'MySQL::BinLog::Event';
    use fields qw{type val};

    use constant PACK_TEMPLATE => 'Ca8';
}


### (CONSTRUCTOR) METHOD: new( $header_obj, $raw_data )
### Create a new IntvarEvent object from the given I<raw_data> and I<header_obj>
### (a MySQL::BinLog::Header object).
sub new {
    my MySQL::BinLog::IntvarEvent $self = shift;

    $self = fields::new( $self );
    $self->SUPER::new( @_ );

    if ( $self->{rawdata} ) {
        my @fields = unpack PACK_TEMPLATE, $self->{rawdata};
        @{$self}{qw{type val}} = @fields;
    }

    return $self;
}


### METHOD: stringify()
### Return a representation of the event as a human-readable string.
sub stringify {
    my MySQL::BinLog::IntvarEvent $self = shift;
    return join( ':', @{$self}{qw{type val}} );
}


#####################################################################
###	L O A D E V E N T   C L A S S
#####################################################################
package MySQL::BinLog::LoadEvent;
use strict;

BEGIN {
    use base 'MySQL::BinLog::Event';
    use fields qw{thread_id exec_time skip_lines tbl_len db_len num_fields sql_ex ldata};

    use constant PACK_TEMPLATE => 'VVVCCVa*';
}


### (CONSTRUCTOR) METHOD: new( $header_obj, $raw_data )
### Create a new LoadEvent object from the given I<raw_data> and I<header_obj>
### (a MySQL::BinLog::Header object).
sub new {
    my MySQL::BinLog::LoadEvent $self = shift;

    $self = fields::new( $self );
    $self->SUPER::new( @_ );

    if ( $self->{rawdata} ) {
        my @fields = unpack PACK_TEMPLATE, $self->{rawdata};
        @{$self}{qw{thread_id exec_time skip_lines tbl_len db_len num_fields sql_ex ldata}} = @fields;
    }

    return $self;
}


### METHOD: stringify()
### Return a representation of the event as a human-readable string.
sub stringify {
    my MySQL::BinLog::LoadEvent $self = shift;
    return join( ':', @{$self}{qw{thread_id exec_time skip_lines tbl_len db_len num_fields sql_ex ldata}} );
}



#####################################################################
###	S L A V E E V E N T   C L A S S
#####################################################################
package MySQL::BinLog::SlaveEvent;
use strict;

BEGIN {
    use base 'MySQL::BinLog::Event';
    use fields qw{master_pos master_port master_host};

    use constant PACK_TEMPLATE => 'a8va*';
}


### (CONSTRUCTOR) METHOD: new( $header_obj, $raw_data )
### Create a new SlaveEvent object from the given I<raw_data> and I<header_obj>
### (a MySQL::BinLog::Header object).
sub new {
    my MySQL::BinLog::SlaveEvent $self = shift;

    $self = fields::new( $self );
    $self->SUPER::new( @_ );

    if ( $self->{rawdata} ) {
        my @fields = unpack PACK_TEMPLATE, $self->{rawdata};
        @{$self}{qw{master_pos master_port master_host}} = @fields;
    }

    return $self;
}


### METHOD: stringify()
### Return a representation of the event as a human-readable string.
sub stringify {
    my MySQL::BinLog::SlaveEvent $self = shift;
    return join( ':', @{$self}{qw{master_pos master_port master_host}} );
}



#####################################################################
###	C R E A T E F I L E E V E N T   C L A S S
#####################################################################
package MySQL::BinLog::CreateFileEvent;
use strict;

BEGIN {
    use base 'MySQL::BinLog::Event';
    use fields qw{thread_id exec_time skip_lines tbl_len db_len num_fields sql_ex ldata};

    use constant PACK_TEMPLATE => 'VVVCCVa*';
}


### (CONSTRUCTOR) METHOD: new( $header_obj, $raw_data )
### Create a new CreateFileEvent object from the given I<raw_data> and I<header_obj>
### (a MySQL::BinLog::Header object).
sub new {
    my MySQL::BinLog::CreateFileEvent $self = shift;

    $self = fields::new( $self );
    $self->SUPER::new( @_ );

    if ( $self->{rawdata} ) {
        my @fields = unpack PACK_TEMPLATE, $self->{rawdata};
        @{$self}{qw{thread_id exec_time skip_lines tbl_len db_len num_fields sql_ex ldata}} = @fields;
    }

    return $self;
}


### METHOD: stringify()
### Return a representation of the event as a human-readable string.
sub stringify {
    my MySQL::BinLog::CreateFileEvent $self = shift;
    return join( ':', @{$self}{qw{thread_id exec_time skip_lines tbl_len db_len num_fields sql_ex ldata}} );
}


#####################################################################
###	A P P E N D B L O C K E V E N T   C L A S S
#####################################################################
package MySQL::BinLog::AppendBlockEvent;
use strict;

BEGIN {
    use base 'MySQL::BinLog::Event';
    use fields qw{file_id data};

    use constant PACK_TEMPLATE => 'Va*';
}


### (CONSTRUCTOR) METHOD: new( $header_obj, $raw_data )
### Create a new AppendBlockEvent object from the given I<raw_data> and I<header_obj>
### (a MySQL::BinLog::Header object).
sub new {
    my MySQL::BinLog::AppendBlockEvent $self = shift;

    $self = fields::new( $self );
    $self->SUPER::new( @_ );

    if ( $self->{rawdata} ) {
        my @fields = unpack PACK_TEMPLATE, $self->{rawdata};
        @{$self}{qw{file_id data}} = @fields;
    }

    return $self;
}


### METHOD: stringify()
### Return a representation of the event as a human-readable string.
sub stringify {
    my MySQL::BinLog::AppendBlockEvent $self = shift;
    return join( ':', @{$self}{qw{file_id data}} );
}


#####################################################################
###	E X E C L O A D E V E N T   C L A S S
#####################################################################
package MySQL::BinLog::ExecLoadEvent;
use strict;

BEGIN {
    use base 'MySQL::BinLog::Event';
    use fields qw{file_id};

    use constant PACK_TEMPLATE => 'V';
}


### (CONSTRUCTOR) METHOD: new( $header_obj, $raw_data )
### Create a new ExecLoadEvent object from the given I<raw_data> and I<header_obj>
### (a MySQL::BinLog::Header object).
sub new {
    my MySQL::BinLog::ExecLoadEvent $self = shift;

    $self = fields::new( $self );
    $self->SUPER::new( @_ );

    if ( $self->{rawdata} ) {
        my @fields = unpack PACK_TEMPLATE, $self->{rawdata};
        @{$self}{qw{file_id}} = @fields;
    }

    return $self;
}


### METHOD: stringify()
### Return a representation of the event as a human-readable string.
sub stringify {
    my MySQL::BinLog::ExecLoadEvent $self = shift;
    return join( ':', @{$self}{qw{file_id}} );
}


#####################################################################
###	D E L E T E F I L E E V E N T   C L A S S
#####################################################################
package MySQL::BinLog::DeleteFileEvent;
use strict;

BEGIN {
    use base 'MySQL::BinLog::Event';
    use fields qw{file_id};

    use constant PACK_TEMPLATE => 'V';
}


### (CONSTRUCTOR) METHOD: new( $header_obj, $raw_data )
### Create a new DeleteFileEvent object from the given I<raw_data> and I<header_obj>
### (a MySQL::BinLog::Header object).
sub new {
    my MySQL::BinLog::DeleteFileEvent $self = shift;

    $self = fields::new( $self );
    $self->SUPER::new( @_ );

    if ( $self->{rawdata} ) {
        my @fields = unpack PACK_TEMPLATE, $self->{rawdata};
        @{$self}{qw{file_id}} = @fields;
    }

    return $self;
}


### METHOD: stringify()
### Return a representation of the event as a human-readable string.
sub stringify {
    my MySQL::BinLog::DeleteFileEvent $self = shift;
    return join( ':', @{$self}{qw{file_id}} );
}


#####################################################################
###	N E W L O A D E V E N T   C L A S S
#####################################################################
package MySQL::BinLog::NewLoadEvent;
use strict;

BEGIN {
    use base 'MySQL::BinLog::Event';
}


### (CONSTRUCTOR) METHOD: new( $header_obj, $raw_data )
### Create a new NewLoadEvent object from the given I<raw_data> and I<header_obj>
### (a MySQL::BinLog::Header object).
sub new {
    my MySQL::BinLog::NewLoadEvent $self = shift;

    $self = fields::new( $self );
    $self->SUPER::new( @_ );

    # I don't think these have any data (?) -MG

    return $self;
}


### METHOD: stringify()
### Return a representation of the event as a human-readable string.
sub stringify {
    my MySQL::BinLog::NewLoadEvent $self = shift;
    return '(New_load)';
}



#####################################################################
###	R A N D E V E N T   C L A S S
#####################################################################
package MySQL::BinLog::RandEvent;
use strict;

BEGIN {
    use base 'MySQL::BinLog::Event';
    use fields qw{seed1 seed2};

    use constant PACK_TEMPLATE => 'a8a8';
}


### (CONSTRUCTOR) METHOD: new( $header_obj, $raw_data )
### Create a new RandEvent object from the given I<raw_data> and I<header_obj>
### (a MySQL::BinLog::Header object).
sub new {
    my MySQL::BinLog::RandEvent $self = shift;

    $self = fields::new( $self );
    $self->SUPER::new( @_ );

    if ( $self->{rawdata} ) {
        my @fields = unpack PACK_TEMPLATE, $self->{rawdata};
        @{$self}{qw{seed1 seed2}} = @fields;
    }

    return $self;
}


### METHOD: stringify()
### Return a representation of the event as a human-readable string.
sub stringify {
    my MySQL::BinLog::RandEvent $self = shift;
    return join( ':', @{$self}{qw{seed1 seed2}} );
}




#####################################################################
###	U S E R V A R E V E N T   C L A S S
#####################################################################

#   USER_VAR_EVENT
# 	o 	4 bytes:  the size of the name of the user variable.
# 	o 	 variable-sized part:  A concatenation. First is the name of the
# user variable. Second is one byte, non-zero if the content of the
# variable is the SQL value NULL, ASCII 0 otherwise. If this bytes was
# ASCII 0, then the following parts exist in the event. Third is one
# byte, the type of the user variable, which corresponds to elements of
# enum Item_result defined in `include/mysql_com.h'. Fourth is 4 bytes,
# the number of the character set of the user variable (needed for a
# string variable). Fifth is 4 bytes, the size of the user variable's
# value (corresponds to member val_len of class Item_string). Sixth is
# variable-sized: for a string variable it is the string, for a float or
# integer variable it is its value in 8 bytes.

package MySQL::BinLog::UserVarEvent;
use strict;

BEGIN {
    use base 'MySQL::BinLog::Event';
    use fields qw{varname value};

    use constant PACK_TEMPLATE => 'V/aca*';
}


### (CONSTRUCTOR) METHOD: new( $header_obj, $raw_data )
### Create a new UserVarEvent object from the given I<raw_data> and I<header_obj>
### (a MySQL::BinLog::Header object).
sub new {
    my MySQL::BinLog::UserVarEvent $self = shift;

    $self = fields::new( $self );
    $self->SUPER::new( @_ );

    if ( $self->{rawdata} ) {
        my @fields = unpack PACK_TEMPLATE, $self->{rawdata};

        # If the the second field is null, the value is undef. Otherwise,
        # unpack the value
        if ( $fields[1] eq "\0" ) {
            $fields[2] = undef;
        } else {
            my ( $type, $charset, $len, $data ) = unpack 'cVVa*', $fields[2];
            $fields[2] = {
                type    => $type,
                charset => $charset,
                len     => $len,
                data    => $data,
            };
        }

        @{$self}{qw{varname value}} = @fields[0, 2];
    }

    return $self;
}


### METHOD: stringify()
### Return a representation of the event as a human-readable string.
sub stringify {
    my MySQL::BinLog::UserVarEvent $self = shift;
    # :FIXME: This will obviously have to take into account the fact that the
    # value field is a complex datatype or undef.
    return join( ':', @{$self}{qw{varname value}} );
}



1;



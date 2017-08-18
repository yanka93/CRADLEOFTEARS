#!/usr/bin/perl
################################################################################

=head1 NAME

Danga::Exceptions - runtime exception classes for Danga systems

=head1 SYNOPSIS

  use Danga::Exceptions qw{:syntax};

  my $result = try {
    do_some_stuff();
  } catch Danga::Exception with {
    my $e = shift;
    print STDERR "Failed to do_some_stuff: $e";
  };

=head1 EXPORTS

Nothing by default.

If used with the :syntax tag, the functions C<try()>, C<with()>, C<finally()>,
C<except()>, and C<otherwise()> will be imported into your package. See
B<PROCEDURAL INTERFACE> for more about what they do and how to use them.

=head1 REQUIRES

C<Carp>, C<Perl 5.006>, C<Scalar::Util>, C<overload>

=head1 DESCRIPTION

This module provides runtime exception classes for Danga, and methods and
syntax for handling them which can be imported.

This code is mostly a hacked-up version of Text::Templar::Exceptions, which is
mostly a hacked-up version of the Error.pm module by Graham Barr
E<lt>gbarr@ti.comE<gt>. Sections which have been copied from or are modified
versions of synonymous sections of that module are annotated accordingly.

=head2 Procedural Interface

C<Danga::Exceptions> can export subroutines to use for exception
handling. The following functions can be imported into your package with the
C<:syntax> tag.

=over 3

=item C<try I<BLOCK> I<CLAUSES>>

C<try> is the main subroutine called by the user. All other subroutines exported
are clauses to the C<try> subroutine.

The I<BLOCK> will be evaluated and if no error is thrown, it will return the result
of the block.

I<CLAUSES> are the subroutines below, which describe what to do in the event of
an error being thrown within I<BLOCK>.

C<Try> works a bit like C<eval E<lt>BLOCKE<gt>> in regards to return value -- it
evaluates to the value of the last statement executed by any of its clauses
(including C<catch>, C<otherwise>, or C<finally> clauses), or may be influenced
by a return within any clause. This allows statements like the following:

  # Try to get the result of executing the code, ignoring any errors that
  # happen within.
  my $result = try { <unsafe code> };

or

  # Get the result of the unsafe code if it executed successfully, or 0 if it
  # errors for any reason.
  my $result = try { <unsafe code> } catch Exception with { return 0 };


=item C<catch I<CLASS> with I<BLOCK>>

This clause will cause all errors that satisfy C<$err-E<gt>isa(I<CLASS>)> to be
caught and handled by evaluating I<BLOCK>.

I<BLOCK> will be passed two arguments. The first will be the exception object
being thrown, and the second is a reference to a scalar variable. If this
variable is set by the C<catch> block, then on return from the C<catch> block,
C<try> will continue processing as if the C<catch> block was never found. This
can be used to propagate an exception to a later C<catch>, for example.

Another way of propagating the error is to call C<$err-E<gt>throw> from within
the C<catch> block.

If the scalar referenced by the second argument is not set, and the error is not
re-thrown, then the current C<try> block will return with the result from the C<catch>
block.

=item C<except I<BLOCK>>

When C<try> is looking for a handler, if an C<except> clause is found, C<BLOCK> is
evaluated. The return value from this block should be a C<HASH> reference or a list of
key-value pairs, where the keys are class names and the values are C<CODE>
references for the handler of errors of that type.

This is useful for defining handlers on the fly.

For example:

  try {
	somethingDangerous();
  }
  
  # Handle IO errors
  catch Exception::IOError with {
	<do something>
  }
  
  # Build a handler for other errors
  except {
	my $handler = sub { print STDERR shift()->message };
    
	return {
		Exception::Custom1	=> $handler,
		Exception::Custom2	=> $handler,
	};
  };

=item C<otherwise I<BLOCK>>

Catch any error by executing the code in I<BLOCK>

When evaluated, I<BLOCK> will be passed one argument, which will be the error
being processed.

Only one C<otherwise> block may be specified per C<try> block. Additional C<otherwise>
blocks will be ignored.

=item C<finally I<BLOCK>>

The code in I<BLOCK> will be executed after all other clauses have executed. If
the C<try> block throws an exception then C<BLOCK> will be executed after any
handlers have been executed. If a handler throws an exception, then the exception will
be caught, the C<finally> block will be executed and the exception will be re-thrown.

Only one C<finally> block may be specified per C<try> block. Additional ones will
result in a syntax error.

=back

=head2 The Base Exception Class

The following methods are methods on the base exception class, from which all
exceptions classes defined herein inherit.

=head3 Constructor Methods

=over 4

=item I<new( [@errorMessage] )>

Returns a new Danga::Exception object with the error message
specified, or 'Unspecified error' if none is specified.

=back

=head3 Methods

=over 4

=item I<as_string( undef )>

A wrapper for stringify()

=item I<catch( $packageName, \&handlerCode[, \%clauses] )>

Adds a catch clause with the specified handler code for the specified
package onto the array of 'catch' clauses in the clauses given. If the
clauses hashref is omitted, one is created. Returns the new or given clauses
hashref with the new catch clause added.

=item I<stackframe( $frameNumber )>

Returns the stack frame from frameNumber levels deep in the call stack. The
frame is a hash (or hashref if called in scalar context) of the form:

  {
    'package'       => The caller's package
    'filename'      => The filename of the code being executed
    'line'          => The line number being executed
    'subroutine'    => The name of the function or method being executed
    'hasargs'       => True if the sub was passed arguments from its caller
    'wantarray'     => True if the sub was called in a list context
    'evaltext'      => If 'subroutine' is '(eval)', this is the EXPR of the eval block
    'is_require'    => True if the frame was created from a 'require' or 'use'
  }

=item I<stacktrace()>

Returns an array of stack frames of the format returned by C<stackframe()> that
describe the stack trace at the moment the exception was thrown.

=item I<stringify()>

Returns the stacktrace and error message of the exception as a human-readable
string.

=item I<throw( $errmsg )>

Create a new C<Exception> object with I<errmsg> and C<die> with it. This will be
caught by any enclosing C<try()> blocks. If not enclosed by aC<try()>, calling
this method will cause a fatal exception.  This method is a modified version of
the synonymous one in Error.pm.

=back

=head1 RCSID

$Id: Exceptions.pm,v 1.3 2004/10/30 00:57:57 deveiant Exp $

=head1 AUTHOR

Michael Granger E<lt>ged@FaerieMUD.orgE<gt>

Large portions of this code were copied from the Text::Templar module's
exceptions module, which is licensed under Perl's Artistic License, and is
licensed under the following terms:

  Copyright (c) 1999-2004 The FaerieMUD Consortium. All rights reserved.

  This module is free software. You may use, modify, and/or
  redistribute this software under the terms of the Perl Artistic
  License. (See http://language.perl.com/misc/Artistic.html)

  THIS SOFTWARE IS PROVIDED "AS IS" AND WITHOUT ANY EXPRESS OR IMPLIED
  WARRANTIES, INCLUDING, WITHOUT LIMITATION, THE IMPLIED WARRANTIES OF
  MERCHANTIBILITY AND FITNESS FOR A PARTICULAR PURPOSE.

Portions of this file are also borrowed from Error.pm, which has the following
licensing information:

  Copyright (c) 1997-8 Graham Barr <gbarr@ti.com>. All rights reserved.  This
  program is free software; you can redistribute it and/or modify it under the
  same terms as Perl itself.

All remaining changes and additional code fall under the following strictures:

Copyright (c) 2004 Danga Interactive. All rights reserved.

=head1 SEE ALSO

Error.pm by Graham Barr

=cut

################################################################################
package Danga::Exceptions;
use strict;

BEGIN {
	require 5.006;
	use vars		qw{$VERSION $RCSID};
	$VERSION = do { my @r = (q$Revision: 1.3 $ =~ /\d+/g); sprintf "%d."."%02d" x $#r, @r };
	$RCSID			= q$Id: Exceptions.pm,v 1.3 2004/10/30 00:57:57 deveiant Exp $;

	use base qw{Exporter};
}

### Delegate all exported stuff to the real base exception class
sub import {
	my @args = @_;
	return Danga::Exception->export_to_level( 1, @args );
}


###############################################################################
###	B A S E   E X C E P T I O N   C L A S S
###############################################################################
package Danga::Exception;
use strict;

BEGIN {
	require 5.006;

	# Package constants
	use vars		qw{$VERSION $RCSID @ISA @EXPORT @EXPORT_OK %EXPORT_TAGS $AUTOLOAD};
	$VERSION = do { my @r = (q$Revision: 1.3 $ =~ /\d+/g); sprintf "%d."."%02d" x $#r, @r };
	$RCSID			= q$Id: Exceptions.pm,v 1.3 2004/10/30 00:57:57 deveiant Exp $;

	# Superclass
	use base		qw{Exporter};

	# Exporter stuff
	@EXPORT			= qw{};
	@EXPORT_OK		= qw{try with finally except otherwise};
	%EXPORT_TAGS	= ( 'syntax'	=> \@EXPORT_OK );

	# Required modules
	use Carp			qw{carp croak confess};
	use Scalar::Util	qw{blessed};

	#	Overload some operations
	use overload (
		'""'		=> 'stringify',
		'@{}'		=> sub { return shift()->{stacktrace} },
		'fallback'	=> 1,
	);

}

###############################################################################
###	C L A S S   V A R I A B L E S
###############################################################################
our ( $Depth, $ErrorType, $Debug );

$ErrorType	= "System";
$Depth		= 1;
$Debug		= 0;


###############################################################################
###	P U B L I C   M E T H O D S
###############################################################################

### (CONSTRUCTOR) METHOD: new( [@errorMessage] )
### Returns a new Danga::Exception object with the error message
### specified, or 'Unspecified error' if none is specified.
sub new {
	my $proto = shift;
	my $class = ref $proto || $proto;
	my $message = ( @_ ? join('', @_) : "Unspecified error" );

	my (
		@stacktrace,
		@calleritems,
		$frame,
		$package,
		$filename,
		$line,
		$context,
		$errtype,
	   );

	print STDERR "Creating an exception of type '$class' with message '$message'.\n" if $Debug;

	# Get the name of the error being thrown from the calling class
  NO_STRICT_REFS: {
		no strict 'refs';
		$errtype = ${"${class}::ErrorType"} || $ErrorType;
	}

	# Build a stacktrace back to the first driver call for this error
	$frame = $Depth;
  FRAME: while ( @calleritems = caller($frame++) ) {

		# Define the exception's variables if the sub is our constructor or
		#		one of the syntax methods
		if ( not defined $package ) {
			( $package, $filename, $line, undef, undef, $context ) = @calleritems;
			next FRAME;
		}

		# :FIXME: Should we trim frames off the stacktrace if they are frames
		# inside the Exception class or one of its children?
		#last FRAME if $calleritems[3] =~ m{^Danga::Exception::};

		push @stacktrace, {
			'package'		=> $calleritems[0],
			'filename'		=> $calleritems[1],
			'line'			=> $calleritems[2],
			'subroutine'	=> $calleritems[3],
			'hasargs'		=> $calleritems[4],
			'wantarray'		=> $calleritems[5],
			'evaltext'		=> $calleritems[6],
			'is_require'	=> $calleritems[7],
		};
	}

	return bless {
	  	'message'			=> $message,
	  	'type'				=> $errtype,
	  	'stacktrace'		=> \@stacktrace,
	  	'timestamp'			=> time(),
		'package'			=> $package,
		'filename'			=> $filename,
		'line'				=> $line,
		'context'			=> $context,
	}, $class;
}


### METHOD: throw( $errmsg )
### Create a new C<Exception> object with I<errmsg> and C<die> with it. This
### will be caught by any enclosing C<try()> blocks. If not enclosed by a
### C<try()>, calling this method will cause a fatal exception.
###   This method is a modified version of the synonymous one in Error.pm.
sub throw {
	my $self = shift;

	print STDERR "Throwing a '", ref $self || $self, "' thingie.\n" if $Debug;

	# if we are not rethrow-ing then create the object to throw
	#local $Depth = $Depth + 1;
	$self = $self->new(@_) unless ref $self;

	# Throw ourself as the exception
	print STDERR "Dying with exception '$self'.\n" if $Debug;
	CORE::die $self;
}


### (AUTOLOADED) METHOD: message()
### Get/set the error message.

### (AUTOLOADED) METHOD: type()
### Get/set the error type.
sub AUTOLOAD {
	my $self = shift;
	my $type = ref( $self ) || croak "AUTOLOAD: Cannot call proxy method in non-object '$self'.";

	( my $name = $AUTOLOAD ) =~ s{^.*::}{};

	# If we have an attribute with the same name as the method called, act as
	# an accessor
	if ( exists $self->{$name} ) {
		$self->{ $name } = shift if @_;
		return $self->{ $name };
	}

	# If there's not like-named attribute, try to call the method in our
	# superclass
	else {
		my $method = "SUPER::${name}";
		return $self->$method( @_ );
	}
}


### METHOD: stackframe( $frameNumber )
### Returns the stack frame from frameNumber levels deep in the call stack. The
### frame is a hash (or hashref if called in scalar context) of the form:
###
###	    'package'       => The caller's package
###	    'filename'      => The filename of the code being executed
###	    'line'          => The line number being executed
###	    'subroutine'    => The name of the function or method being executed
###	    'hasargs'       => True if the sub was passed arguments from its caller
###	    'wantarray'     => True if the sub was called in a list context
###	    'evaltext'      => If 'subroutine' is '(eval)', this is the EXPR
###	                        of the eval block
###	    'is_require'    => True if the frame was created from a 'require' or 'use'
sub stackframe {
	my $self = shift;
	my $frame = shift || 0;

	return undef unless $#{$self->{'stacktrace'}} >= $frame;
	return wantarray
		? %{ $self->{'stacktrace'}[$frame] }
		: $self->{'stacktrace'}[$frame];
}


### METHOD: stacktrace()
### Returns an array of stack frames of the format returned by C<stackframe()>
### that describe the stack trace at the moment the exception was thrown.
sub stacktrace {
	my $self = shift;
	return @{$self->{'stacktrace'}};
}


### METHOD: as_string( undef )
### A wrapper for stringify()
sub as_string { stringify(@_) }


### METHOD: error()
### Generate an error message out of the exception's attributes and return it.
sub error {
    my $self = shift;

    return sprintf( "A %s error '%s' occurred\n\tin %s (%s) line %d\n\t(%s).\n",
                    $self->type,
                    $self->message,
                    $self->package,
                    $self->filename,
                    $self->line,
                    scalar localtime($self->timestamp) );
}


### METHOD: stringify()
### Returns the stacktrace and error message or the exception as a human-readable string.
sub stringify {
	my $self = shift;
	my $rval;

	$rval = $self->error . "-" x 80 . "\n";

	for my $traceref ( @{$self->{'stacktrace'}} ) {
		$rval .= sprintf( "%s (%s)\n\tline %s called %s.\n",
						  $$traceref{'package'},
						  $$traceref{'filename'},
						  $$traceref{'line'},
						  $$traceref{'subroutine'} );
	}

	return $rval;
}


###############################################################################
###	S Y N T A X   F U N C T I O N S
###############################################################################

### Note: Most of this code is from Error.pm by Graham Barr <gbarr@ti.com>, with
### a few aesthetic and functional modifications by Michael Granger
### <ged@FaerieMUD.org>. All comments are also mine, so blame me for any
### mistakes =:)

### FUNCTION: try( \&codeblock, \%handlerClauses )
### The I<codeblock> will be evaluated and if no error condition arises, this
### function returns the result. I<handlerClauses> is a hash of code
### references that describe what actions to take if a error occurs. It is
### typically built by appending one or more C<catch>, C<otherwise>, or
### C<finally> clauses.
sub try (&;$) {
	my $try			= shift;				# The try block as a CODE ref
	my $clauses		= @_ ? shift : {};		# The handler clauses

	my (
		$ok,
		$error,
		@results,
		$wantarray,
		$handlerCode,
	   );

	$wantarray = wantarray;

	#	Execute the try block
	do {
		no warnings;

		# Localize the depth counter and temporarily unset the die handler
		local $Depth = 1;
		local $SIG{__DIE__} = undef;

		#	Wrap a call to the try block in an eval
		$ok = eval {
			if ( $wantarray ) {
				@results = $try->();
			} else {
				$results[0] = $try->();
			}
			1;	# Indicate success
		};

		# Set the error message and set ok to false if there's an eval error
		$error = $@, $ok = undef if $@;
	};

	# If the try block didn't return an ok status, handle the error
	if ( $error ) {

		#	If the error was just a $@, wrap it in a Exception
		$error = __PACKAGE__->new( "Untrapped exception in try block: $error" ) unless ref $error;

		CATCH: {
			my (
				$catchClauses,			# Catch clauses (coderefs)
				$owise,			# Otherwise clause (coderef)
				$i,				# Iterator
				$pkg,			# The package to match for catch clauses
				$keepTrying,	# The 'keep trying' flag passed (by reference) to each catch block
				$ok,			# Eval result
			);

			# Do the catch clauses (if any are defined)
			if (defined( $catchClauses = $clauses->{'catch'} )) {

				# Iterate over each catch clause package + coderef
				CATCHLOOP: for( $i = 0; $i < @$catchClauses; $i += 2) {

					#	Get the name of the package we're looking for
					$pkg = $catchClauses->[$i];

					#	If there wasn't a package name, then it must be an except block,
					#	 so splice the hash returned by it into the catch handlers and
					#	 decrement the counter to point to the first new handler
					unless (defined $pkg) {

						splice( @$catchClauses, $i, 2, $catchClauses->[$i+1]->() );
						$i -= 2;
						redo CATCH;
					}

					#	Otherwise, check to see if the error's one of the ones we should catch
					elsif ( $error->isa($pkg) ) {

						#	Get the coderef to the handler
						$handlerCode = $catchClauses->[$i+1];
						$keepTrying = 0;

						#	Wrap the catch handler in an eval
						$ok = eval {
							if ( $wantarray ) {
								@results = $handlerCode->( $error, \$keepTrying );
							} elsif ( defined($wantarray) ) {
								$results[0] = $handlerCode->( $error, \$keepTrying );
							} else {
								$handlerCode->( $error, \$keepTrying );
							}
							1;	# Indicate success
						};

						# If the handler executed successfully, either keep
						#	 trying (if the handler said to do so), or consider
						#	 it handled and quit doing catches
						if ( $ok ) {
							next CATCHLOOP if $keepTrying;
							undef $error;
						} elsif ( $@ ) {
							$error = $@;
							$error = __PACKAGE__->new( "Exception in catch block: $error" ) unless ref $error;
						} else {
							$error = __PACKAGE__->new( "Mysterious error in catch block." );
						}
						last CATCH;
					}
				}
			}

			# Otherwise clause
			if (defined( $owise = $clauses->{'otherwise'} )) {

				#	Wrap the otherwise handler in an eval
				my $ok = eval {
					if ( $wantarray ) {
						@results = $owise->( $error );
					} elsif (defined( $wantarray )) {
						$results[0] = $owise->( $error );
					} else {
						$owise->( $error );
					}
					1;	# Indicate success
				};

				if ( $ok ) {
					undef $error;
				} elsif ( $@ ) {
					$error = $@;
					$error = __PACKAGE__->new( "Exception in otherwise block: $error" ) unless ref $error;
				} else {
					$error = __PACKAGE__->new( "Mysterious error in otherwise block." );
				}
			}
		}
	}

	#	Finally clause
	$clauses->{finally}->() if exists $clauses->{finally} && defined $clauses->{finally};

	#	Propagate the error if it's still defined
	$error->throw if defined $error;

	#	Return the results
	return $wantarray ? @results : $results[0];
}


### METHOD: catch( $packageName, \&handlerCode[, \%clauses] )
### Adds a catch clause with the specified handler code for the specified
### package onto the array of 'catch' clauses in the clauses given. If the
### clauses hashref is omitted, one is created. Returns the new or given clauses
### hashref with the new catch clause added.
sub catch {
	my $pkg		= shift;
	my $code	= shift;
	my $clauses	= shift || {};

	$clauses->{catch} ||= [];

	unshift @{$clauses->{catch}}, $pkg, $code;
	return $clauses;
}


sub with (&;$) {
	return @_;		# Does nothing except pass the clauses hash on
}

sub finally (&) {
	my $code = shift;
	my $clauses = { 'finally' => $code };
	return $clauses;
}

###	The except clause is a block which returns a hashref or a list of
###		key-value pairs, where the keys are the classes and the values are subs.
sub except (&;$) {
	my $code	= shift;
	my $clauses	= shift || {};

	$clauses->{catch} ||= [];

	#	Build the coderef that'll return the hash of handlers
	my $handler = sub {
		my $arg = shift;

		my $handlers;
		my ( @array ) = $code->( $arg );

		if ( @array == 1 && ref $array[0] ) {
			$handlers = $array[0];
			$handlers = [ %$handlers ] if ref $handlers eq 'HASH';
		} else {
			$handlers = \@array;
		}

		return @$handlers;
	};

	#	Stick the handler onto the front of the listref with an undef as the package
	#		to alert the try function that this is an except block
	unshift @{$clauses->{catch}}, undef, $code;

	#	Pass the clauses on
	return $clauses;
}

sub otherwise (&;$) {
	my $code = shift;
	my $clauses = shift || {};

	croak "Multiple otherwise clauses" if exists $clauses->{'otherwise'};
	$clauses->{otherwise} = $code;

	return $clauses;
}

END			{}
DESTROY		{}


###############################################################################
###	D E R I V E D   E X C E P T I O N   C L A S S E S
###############################################################################

###
###	General exceptions
###

### (EXCEPTION) CLASS: Danga::MethodError
### Method invocation error
package Danga::MethodError;
use strict;
use base 'Danga::Exception';
our $ErrorType = 'method invocation';

### (EXCEPTION) CLASS: Danga::FileIOError
### File I/O error
package Danga::FileIOError;
use strict;
use base 'Danga::Exception';
our $ErrorType = 'file I/O';

### (EXCEPTION) CLASS: Danga::EvalError
### Evaluation error
package Danga::EvalError;
use strict;
use base 'Danga::Exception';
our $ErrorType = 'evaluation';

### (EXCEPTION) CLASS: Danga::RecursionError
### Too deep recursion error
package Danga::RecursionError;
use strict;
use base 'Danga::Exception';
our $ErrorType = 'recursion';

### (EXCEPTION) CLASS: Danga::ConfigError
### Configuration file format/value error
package Danga::ConfigError;
use strict;
use base 'Danga::Exception';
our $ErrorType = 'configuration';

### (EXCEPTION) CLASS: Danga::ParseError
### Configuration/component parse error
package Danga::ParseError;
use strict;
use base 'Danga::Exception';
our $ErrorType = 'parse';

### (EXCEPTION) CLASS: Danga::UnimplementedMethodError
### Exception thrown when a virtual method is used.
package Danga::UnimplementedMethodError;
use strict;
use base 'Danga::Exception';
our $ErrorType = 'unimplemented method';

### (EXCEPTION) CLASS: Danga::UnimplementedMethodError
### Exception thrown when instantiation is attempted of an abstract class.
package Danga::InstantiationError;
use strict;
use base 'Danga::Exception';
our $ErrorType = 'instantiation';

sub new {
	my $proto = shift;
	my $errmsg = @_ ? join '', @_ : "Instantiation attempted of abstract class.";
	local $Danga::Exception::Depth = $Danga::Exception::Depth + 1;
	return $proto->SUPER::new( $errmsg );
}

### (EXCEPTION) CLASS: Danga::CommandError
### Exception thrown when a command run in the shell fails.
package Danga::CommandError;
use strict;
use base 'Danga::Exception';
our $ErrorType = 'command';


### (EXCEPTION) CLASS: Danga::IncompleteObjectError
### Exception thrown when an operation is attempted on an object which does not
### have all the requisite information set.
package Danga::IncompleteObjectError;
use strict;
use base 'Danga::Exception';
our $ErrorType = 'incomplete object';

sub new {
	my $proto = shift;
	local $Danga::Exception::Depth = $Danga::Exception::Depth + 1;

	my $errmsg;
	if ( @_ == 2 ) { $errmsg = sprintf("Cannot %s: Missing '%s'", @_) }
	else { $errmsg = join('', @_) }

	return $proto->SUPER::new( $errmsg );
}

### (EXCEPTION) CLASS: Danga::ParamError
### Parameter missing or invalid error. This exception type accepts arguments in
### three different patterns which form three kinds of error message:
###
### =over 4
###
### =item C<throw Danga::ParamError 1, "name">
###
### Forms an error message like:
###
###   Missing or undefined argument B<1>: B<name>.
###
### =item C<throw Danga::ParamError "actions", ['IO::Handle', 'IO::File'], "string"
###
### Forms an error message like:
###
###   Illegal 'B<actions>' parameter: Expected one of B<IO::Handle>, B<IO::File>, got a simple scalar
###
### =back
package Danga::ParamError;
use strict;
use base 'Danga::Exception';
our $ErrorType = 'parameter';

sub new {
	my $proto = shift;

	my $errmsg;

	# Two-arg syntax when the first arg's a number indicates a missing or
	# undefined parameter.
	if ( @_ == 2 && $_[0] =~ m{^[0-9]+$} ) {
		my ( $position, $paramName ) = @_;

		$errmsg = sprintf( 'Missing or undefined argument %s: %s',
						   $position,
						   ucfirst $paramName );
	}

	# Three-arg syntax indicates an illegal param
	elsif ( @_ == 3 && ref $_[1] eq 'ARRAY' ) {
		my ( $paramName, $legalValues, $actualValue ) = @_;

		if ( @$legalValues > 1 ) {
			$errmsg = sprintf( q{Illegal '%s' parameter: Expected one of %s, got a %s},
							   $paramName,
							   join(', ', @$legalValues),
							   (ref $actualValue ? ref $actualValue : "simple scalar") );
		} else {
			$errmsg = sprintf( q{Illegal '%s' parameter: Expected a %s, got a %s},
							   $paramName,
							   $legalValues->[0],
							   (ref $actualValue ? ref $actualValue : "simple scalar") );
		}
	}

	else {
		$errmsg = @_ ? join( '', @_ ) : 'Illegal parameter';
		$errmsg = ucfirst $errmsg;
	}

	local $Danga::Exception::Depth = $Danga::Exception::Depth + 1;
	return $proto->SUPER::new( $errmsg );
}


### Event errors

### (EXCEPTION) CLASS: Danga::UnhandledEventError
### Exception thrown when an unhandled event is received by a job.
package Danga::UnhandledEventError;
use strict;
use base 'Danga::Exception';
our $ErrorType = 'unhandled event';

sub new {
	my $proto = shift;
	my $event = shift or return $proto->SUPER::new( "Unhandled event: Unknown event" );

	return $proto->SUPER::new( sprintf "Unhandled %s event", ref $event );
}


### Database errors

### (EXCEPTION) CLASS: Danga::DatabaseError
### Exception thrown when a database error occurs. If no argument is given, the
### default is built out of the current value of $DBI::errstr.
package Danga::DatabaseError;
use strict;
use base 'Danga::Exception';
our $ErrorType = 'database';

sub new {
	my $proto = shift;
	my $errmsg = @_ ? join( '', @_ ) : $DBI::errstr;

	return $proto->SUPER::new( $errmsg );
}

### (EXCEPTION) CLASS: Danga::SqlError
### Exception thrown when a database error occurs while preparing or executing a
### database operation. A DBI::Dbh or DBI::Sth object may be passed as the
### argument, in which case the result of calling C<errstr> on the object will
### be used to build an error message.
package Danga::SqlError;
use strict;
use Scalar::Util qw{blessed};
use base 'Danga::DatabaseError';
our $ErrorType = 'SQL';

sub new {
	my $proto = shift;
	my @args = @_;

	if ( blessed $args[0] && ($args[0]->isa('DBI::db') || $args[0]->isa('DBI::st')) ) {
		my $h = shift @args;
		my $errmsg = sprintf( 'While %s (%s): %s',
							  $h->isa('DBI::db') ? 'preparing' : 'executing',
							  $h->{Statement},
							  $h->errstr,
							 );
		unshift @args, $errmsg;
	}

	return $proto->SUPER::new( join('', @args) );
}


### (EXCEPTION) CLASS: Danga::ValidationError
### Exception thrown (or more likely, simply returned) when a parameter given to
### a CGI fails to untaint+validate.
package Danga::ValidationError;
use strict;
use base 'Danga::Exception';
our $ErrorType = 'validation';



### Module require return value
1;




###	AUTOGENERATED DOCUMENTATION FOLLOWS

=head1 CLASSES

=head2 Exception Classes

=over 4

=item I<Danga::CommandError>

Exception thrown when a command run in the shell fails.

=item I<Danga::ConfigError>

Configuration file format/value error

=item I<Danga::DatabaseError>

Exception thrown when a database error occurs. If no argument is given, the
default is built out of the current value of $DBI::errstr.

=item I<Danga::EvalError>

Evaluation error

=item I<Danga::FileIOError>

File I/O error

=item I<Danga::IncompleteObjectError>

Exception thrown when an operation is attempted on an object which does not
have all the requisite information set.

=item I<Danga::MethodError>

Method invocation error

=item I<Danga::ParamError>

Parameter missing or invalid error. This exception type accepts arguments in
three different patterns which form three kinds of error message:

=item I<Danga::ParseError>

Configuration/component parse error

=item I<Danga::RecursionError>

Too deep recursion error

=item I<Danga::SqlError>

Exception thrown when a database error occurs while preparing or executing a
database operation. A DBI::Dbh or DBI::Sth object may be passed as the
argument, in which case the result of calling C<errstr> on the object will
be used to build an error message.

=item I<Danga::UnhandledEventError>

Exception thrown when an unhandled event is received by a job.

=item I<Danga::UnimplementedMethodError>

Exception thrown when instantiation is attempted of an abstract class.

=back

=head1 FUNCTIONS

=over 4

=item I<try( \&codeblock, \%handlerClauses )>

The I<codeblock> will be evaluated and if no error condition arises, this
function returns the result. I<handlerClauses> is a hash of code
references that describe what actions to take if a error occurs. It is
typically built by appending one or more C<catch>, C<otherwise>, or
C<finally> clauses.

=back

=head1 METHODS

=over 4

=item I<as_string( undef )>

A wrapper for stringify()

=item I<catch( $packageName, \&handlerCode[, \%clauses] )>

Adds a catch clause with the specified handler code for the specified
package onto the array of 'catch' clauses in the clauses given. If the
clauses hashref is omitted, one is created. Returns the new or given clauses
hashref with the new catch clause added.

=item I<stackframe( $frameNumber )>

Returns the stack frame from frameNumber levels deep in the call stack. The
frame is a hash (or hashref if called in scalar context) of the form:

=item I<stacktrace()>

Returns an array of stack frames of the format returned by C<stackframe()>
that describe the stack trace at the moment the exception was thrown.

=item I<stringify()>

Returns the stacktrace and error message or the exception as a human-readable string.

=item I<throw( $errmsg )>

Create a new C<Exception> object with I<errmsg> and C<die> with it. This
will be caught by any enclosing C<try()> blocks. If not enclosed by a
C<try()>, calling this method will cause a fatal exception.

This method is a modified version of the synonymous one in Error.pm.

=back

=head2 Autoloaded Methods

=over 4

=item I<message()>

Get/set the error message.

=item I<type()>

Get/set the error type.

=back

=head2 Constructor Methods

=over 4

=item I<new( [@errorMessage] )>

Returns a new Danga::Exception object with the error message
specified, or 'Unspecified error' if none is specified.

=back

=cut


#!/usr/bin/perl -w
#
#		Test script for Danga::Exceptions
#		$Id: basic.t,v 1.1 2004/06/04 22:06:28 deveiant Exp $
#
#		Before `make install' is performed this script should be runnable with
#		`make test'. After `make install' it should work as `perl 02_exceptions.t'
#
#		Please do not commit any changes you make to the module without a
#		successful 'make test'!
#
package main;
use strict;

BEGIN	{ $| = 1; }

### Load up the test framework
use Test::SimpleUnit qw{:functions};
Test::SimpleUnit::AutoskipFailedSetup( 1 );

use Danga::Exceptions qw{:syntax};

### Imported-symbol test-generation function
sub genTest {
	my $functionName = shift;
	return {
		name => "Import $functionName",
		test => sub {
			no strict 'refs';
			assertDefined *{"main::${functionName}"}{CODE},
				"$functionName() was not imported";
		},
	};
}

### Test functions for throwing
sub simple_throw {
	throw Danga::Exception "Simple throw exception.";
}
sub methoderror_throw {
	throw Danga::MethodError "Method error.";
}

### Build tests for imported syntax functions
my @synFuncTests = map { s{^&}{}; genTest $_ } @{$Danga::Exception::EXPORT_TAGS{syntax}};


### Main test suite (in the order they're run)
my @testSuite = (

	# Test for imported symbols first
	@synFuncTests,

	# try + throw + catch
	{
		name => 'Simple throw',
		test => sub {
			try {
				simple_throw();
			} catch Danga::Exception with {
				my $except = shift;
				assertInstanceOf 'Danga::Exception', $except;
			};
		},
	},

	# try + throw subclass + catch general class
	{
		name => 'Subclass throw - general handler',
		test => sub {
			try {
				methoderror_throw();
			} catch Danga::Exception with {
				my $except = shift;
				assertInstanceOf 'Danga::MethodError', $except;
			};
		},
	},

	# try + throw subclass + catch subclass + catch general class(skipped)
	{
		name => 'Subclass throw - specific and general handlers',
		test => sub {
			my ( $sawSpecificHandler, $sawGeneralHandler );

			try {
				methoderror_throw();
			} catch Danga::MethodError with {
				$sawSpecificHandler = 1;
			} catch Danga::Exception with {
				$sawGeneralHandler = 1;
			};

			assertNot $sawGeneralHandler, "Saw general handler with preceeding specific handler";
			assert $sawSpecificHandler, "Didn't see specific handler";
		},
	},

	# try + throw subclass + catch subclass + rethrow + catch general class
	{
		name => 'Subclass throw - specific handler with keeptrying',
		test => sub {
			my ( $sawSpecificHandler, $sawGeneralHandler );

			try {
				methoderror_throw();
			} catch Danga::MethodError with {
				my ( $e, $keepTrying ) = @_;
				assertRef 'SCALAR', $keepTrying;
				$sawSpecificHandler = 1;
				$$keepTrying = 1;
			} catch Danga::Exception with {
				$sawGeneralHandler = 1;
			};

			assert $sawGeneralHandler,
				"Didn't see general handler after setting \$keeptrying from ".
				"preceeding specific handler";
			assert $sawSpecificHandler,
				"Didn't see specific handler";
		},
	},

	# try + catch + with + otherwise
	{
		name => "Throw with otherwise",
		test => sub {
			my ( $seenCatch, $seenOtherwise );
			try {
				simple_throw();
			} catch Danga::MethodError with {
				$seenCatch = 1;
			} otherwise {
				$seenOtherwise = 1;
			};

			assert $seenOtherwise;
			assertNot $seenCatch;
		},
	},


	### finally
	{
		name => "Throw with finally",
		test => sub {
			my ( $sawHandler, $sawFinally );

			try {
				simple_throw();
			} catch Danga::Exception with {
				$sawHandler = 1;
			} finally {
				$sawFinally = 1;
			};

			assert $sawHandler, "Didn't see handler";
			assert $sawFinally, "Didn't see finally clause.";
		},
	},


);

runTests( @testSuite );


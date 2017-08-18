#!/usr/bin/perl
#
#		Test script for Apache::BML -- Simple functions
#		$Id: 10_simple.t,v 1.1 2004/05/26 17:33:51 deveiant Exp $
#
#		Before `make install' is performed this script should be runnable with
#		`make test'. After `make install' it should work as `perl 00_require.t'
#
#		Please do not commit any changes you make to the module without a
#		successful 'make test'!
#
package main;
use strict;

BEGIN	{ $| = 1; }

### Load up the test framework
use Test::SimpleUnit	qw{:functions};
use Apache::BML			qw{};
use Apache::FakeRequest	qw{};
use Fcntl				qw{O_CREAT O_TRUNC O_EXCL O_WRONLY};
use File::Spec			qw{};

my (
   @testSuite,
   $Output,
   $Errout,
   $Pnotes,
   $Request,
   $DataPath,
   $NonExistantFile,
   $ForbiddenFile,
   $ForbiddenConfigFile,
   $EmptyFile,
  );

$Pnotes = {};
$Output = '';
$Errout = '';

$DataPath = File::Spec->rel2abs( "test" );
$NonExistantFile = "$DataPath/nonexistant.bml";
$ForbiddenFile = "$DataPath/forbidden.bml";
$ForbiddenConfigFile = "$DataPath/_config.bml";
$EmptyFile = "$DataPath/empty.bml";


# Overload Apache::FakeRequest's print to append output to a variable.
{
	no warnings 'redefine';
	*Apache::FakeRequest::print = sub {
		my $r = shift;
		$Output .= join('', @_)
	};
	*Apache::FakeRequest::log_error = sub {
		my $r - shift;
		print STDERR @_, "\n"; $Errout .= join('', @_)
	};
	*Apache::FakeRequest::pnotes = sub {
		my ( $r, $key ) = @_;
		return $Pnotes if !$key;
		$Pnotes->{ $key } = shift if @_;
		$Pnotes->{ $key };
	};
}


# Define tests
@testSuite = (

	{
		name	=> 'setup',
		func	=> sub {
			$Output = '';
			$Errout = '';
			$Pnotes = {};
		},
	},

	# Calling handler() with no args should error
	{
		name => 'No Args',
		test => sub {
			assertException {
				Apache::BML::handler();
			};
		},
	},


	# Calling with a non-existant file should 404
	{
		name => "Non-existant file",
		test => sub {
			my $request = new Apache::FakeRequest (
				filename => $NonExistantFile,
			   );
			my $res;

			assertNoException {
				$res = Apache::BML::handler( $request );
			};

			assertEquals( 404, $res );
			assertMatches( /does not exist/, $Errout );
		},
	},

	{
		name	=> 'teardown',
		func	=> sub {
			if ( -e $ForbiddenFile ) {
				unlink $ForbiddenFile or die "unlink: $ForbiddenFile: $!";
			}
		},
	},

	# Calling with a file for which we have no permissions should 403
	{
		name => "Non-readable file",
		test => sub {
			# Create an unreadable file
			my $fh = new IO::File $ForbiddenFile, O_CREAT|O_WRONLY
				or die "open: $ForbiddenFile: $!";
			close $fh;
			chmod 0220, $ForbiddenFile
				or die "chmod: $ForbiddenFile: $!";

			my $request = new Apache::FakeRequest (
				filename => $ForbiddenFile,
			   );
			my $res;

			assertNoException {
				$res = Apache::BML::handler( $request );
			};

			assertEquals( 403, $res );
			assertMatches( /File permissions deny access/, $Errout );
		},
	},

	{
		name	=> 'teardown',
		func	=> sub {
			if ( -e $ForbiddenConfigFile ) {
				unlink $ForbiddenConfigFile or die "unlink: $ForbiddenConfigFile: $!";
			}
		},
	},

	# _config files are forbidden
	{
		name => "Forbidden _config file",
		test => sub {
			# Create a readable _config file
			my $fh = new IO::File $ForbiddenConfigFile, O_CREAT|O_WRONLY
				or die "open: $ForbiddenConfigFile: $!";
			$fh->print("");
			close $fh;

			my $request = new Apache::FakeRequest (
				filename => $ForbiddenConfigFile,
			   );
			my $res;

			assertNoException {
				$res = Apache::BML::handler( $request );
			};

			assertEquals( 403, $res );
		},
	},


	{
		name	=> 'teardown',
		func	=> sub {
			if ( -e $EmptyFile ) {
				unlink $EmptyFile or die "unlink: $EmptyFile: $!";
			}
		},
	},


	# Loading an empty file should be okay
	{
		name => "Empty file",
		test => sub {
			# Create an unreadable file
			my $fh = new IO::File $EmptyFile, O_CREAT|O_WRONLY
				or die "open: $EmptyFile: $!";
			$fh->print("");
			close $fh;

			my $request = new Apache::FakeRequest (
				filename => $EmptyFile,
			   );
			my $res;

			assertNoException { $res = Apache::BML::handler($request) };
			assertEquals 0, $res;
			assertEquals '', $Output;
		},
	}


);

runTests( @testSuite );

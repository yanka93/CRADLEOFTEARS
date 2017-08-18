#!/usr/bin/perl
#
#		Test script for Apache::BML -- Simple functions
#		$Id: 20_render.t,v 1.3 2004/07/03 00:13:26 deveiant Exp $
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

use lib "lib";

### Load up the test framework
use Test::SimpleUnit	qw{:functions};
use Apache::BML			qw{};
use Apache::FakeRequest	qw{};
use Fcntl				qw{O_CREAT O_TRUNC O_EXCL O_RDONLY O_WRONLY};
use File::Spec			qw{};
use File::Basename		qw{dirname basename};
use Text::Diff			qw{diff};


#####################################################################
###	G L O B A L   V A R I A B L E S
#####################################################################
my (
   @testSuite,
   $Request,
   $TestDir,
   @TestSubdirs,
  );

$TestDir = File::Spec->rel2abs( "test" );

# The list of directories to search for .bml files. This is hard-coded instead
# of automatic so other tests can use the test/ directory for their data, too.
@TestSubdirs = qw[ tutorial1 tutorial2 brads recursion syntax-errors 
				   codeblocks fake_root comments info escape include
				   tutorial-example*
				 ];


#####################################################################
###	C U S T O M   A S S E R T I O N   F U N C T I O N S
#####################################################################

### FUNCTION: readFile( $file )
### Read the specified I<file> and return its contents as a single scalar.
sub readFile {
	my ( $file ) = @_;

	my $fh = new IO::File $file, O_RDONLY
		or die "open: $file: $!";
	return join '', $fh->getlines;
}


### FUNCTION: assertCorrect( $directory, $name, $output )
### Load the "I<name>.correct" file from the specified testing I<directory> and
### check that it is the same as the specified I<output> after stripping off
### trailing whitespace from both.
sub assertCorrect {
	my ( $dir, $name, $output ) = @_;

	my $path = File::Spec->catfile( $dir, "$name.correct" );
	if ( ! -e $path ) {
		print "\n>>> WARNING: No .correct file for '$name': Creating one with \n",
			">>> the test output. You should verify the correctness of \n",
			">>> '$path' before trusting this test.\n\n";
		IO::File->new($path, O_WRONLY|O_CREAT)->print( $output );
	}

	my $correct = readFile( $path );

	# Trim trailing whitespace off of both expected and correct
	$correct =~ s{\s+$}{}; $correct .= "\n";
	$output =~ s{\s+$}{}; $output .= "\n";

	my $diff = diff( \$correct, \$output );
	assert( $diff eq '', "Expected output from $name.correct, got:\n$diff" );
}


#####################################################################
###	A P A C H E : : F A K E R E Q U E S T   M U N G I N G
#####################################################################

# Overload Apache::FakeRequest's print to append output to a variable.
{
	package Apache::FakeRequest;
	use vars qw{%Pnotes $Output $Errout};
	no warnings 'redefine';

	%Pnotes = ();
	$Output = $Errout = '';

	sub Reset {
		%Pnotes = ();
		$Output = $Errout = '';
	}

	sub print {
		my $r = shift;
		$Output .= join('', @_)
	}
	sub log_error {
		my $r - shift;
		print STDERR @_, "\n"; $Errout .= join('', @_)
	}
	sub pnotes {
		my ( $r, $key ) = @_;
		$Pnotes{ $key } = shift if @_;
		return $Pnotes{ $key };
	}

}



#####################################################################
###	T E S T S
#####################################################################

# Define tests
@testSuite = (

	{
		name	=> 'setup',
		func	=> sub {
			Apache::FakeRequest->Reset;
		},
	},

);

# Auto-generate tests for each test subdir
foreach my $subdir ( @TestSubdirs ) {
	my $testpat = File::Spec->catdir( $TestDir, $subdir );

	# Find all the .bml files, skipping those which start with underscores.
	foreach my $bmlfile ( glob "$testpat/*.bml" ) {
		next if $bmlfile =~ m{/_};
		( my $name = $bmlfile ) =~ s{.*/(.*)\.bml$}{$1};
		my $testdir = dirname( $bmlfile );
		my $testname = basename( $testdir );

		# Add a test to the suite for the .bml file
		push @testSuite,
		{
			name => "$testname $name",
			test => sub {

				#print "Testing dir: $testdir\n";
				my $request = new Apache::FakeRequest (
					document_root => $TestDir,
					uri => "/$name.bml",
					filename => "$bmlfile",
				   );
				my $res;

				$ENV{testlookroot} = $testdir;

				assertNoException {
					local $SIG{ALRM} = sub { die "Timeout" };
					alarm 10;
					$res = Apache::BML::handler($request)
				};
				alarm 0;
				assertEquals 0, $res;
				assertCorrect( $testdir, $name, $Apache::FakeRequest::Output );

				print STDERR $Apache::Request::Errout, "\n";
			},
		};
	}
}


runTests( @testSuite );

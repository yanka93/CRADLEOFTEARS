#!/usr/bin/perl -w
package newtest;
use strict;
use warnings qw{all};

BEGIN {
	use Term::Prompter	qw{};
	use FindBin			qw{$Bin};
	use Cwd				qw{getcwd};
	use IO::File		qw{};
	use Fcntl			qw{O_WRONLY O_CREAT O_EXCL};
}

my (
	$prompter,
	$olddir,
	$testname,
	$firstfile,
	$ofh,
   );

$olddir = getcwd();
chdir $Bin;

$prompter = new Term::Prompter;
$prompter->promptColor( 'cyan' );

# Prompt for the information about this test
$prompter->message( "This will create a new test subdirectory and create the \n",
					"necessary files and links.\n" );
$testname = $prompter->prompt( "Name of the test subdirectory:" )
	or exit 1;
$firstfile = $prompter->promptWithDefault( 'index.bml', "Name of the first BML test file" );
$firstfile .= ".bml" unless $firstfile =~ m{\.bml$};

# Make the test directory, symlink the config, and add the new files to it
$prompter->message( "Creating '$testname' directory..." );
mkdir $testname or die "mkdir: $testname: $!";
symlink "../_config.bml", "$testname/_config.bml"
	or die "symlink: _config.bml -> $testname/_config.bml: $!";

$prompter->message( "Creating BML file '$testname/$firstfile'..." );
$ofh = new IO::File "$testname/$firstfile", O_WRONLY|O_CREAT|O_EXCL
	or die "open: $testname/$firstfile: $!";
$ofh->print( <<"EOF" );

<!-- You should, of course, replace this with your own stuff... -->
<?example This is an example call to a block. example?>


EOF
$ofh->close;

$prompter->message( "Creating lookfile '$testname/scheme.look'..." );
$ofh = new IO::File "$testname/scheme.look", O_WRONLY|O_CREAT|O_EXCL
	or die "open: $testname/scheme.look: $!";
$ofh->print( <<"EOF" );

example=>{D}<example>%%DATA%%</example>

EOF
$ofh->close;

chdir( $olddir );

# Give instructions to the user
( my $correct = $firstfile ) =~ s{\.bml$}{.correct};
$prompter->message( <<"EOF" );

Now you need to do three things to finish setting up the test:

1. Edit $testname/scheme.look and add the blocks you're testing.
2. Edit $testname/$firstfile and add your test content.
3. When you're done, add '$testname' to the list of tests to run in the
   \@TestSubdirs var in t/20_render.t.

Then when you run the new test for the first time, it'll generate a comparison
test output file in $testname/$correct which you should verify for
correctness.

EOF


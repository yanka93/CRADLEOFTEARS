#!/usr/bin/perl
#
#		Test script for Apache::BML
#		$Id: 00_require.t,v 1.1 2004/05/26 17:33:51 deveiant Exp $
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
use Test::SimpleUnit qw{:functions};

my (
   $manifest,
   @modules,
   @testSuite,
  );

# Read the manifest and grok the list of modules out of it
$manifest = IO::File->new( "MANIFEST", "r" )
   or die "open: MANIFEST: $!";
@modules = map { s{lib/(.+)\.pm$}{$1}; s{/}{::}g; $_ } grep { m{\.pm$} } $manifest->getlines;
chomp @modules;

### Test suite (in the order they're run)
@testSuite = map {
	{
		name => "require ${_}",
		test => eval qq{sub { assertNoException {require $_}; }},
	}
} @modules;

runTests( @testSuite );

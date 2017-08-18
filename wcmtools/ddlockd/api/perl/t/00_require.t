#!/usr/bin/perl -w

use strict;
use Test;

BEGIN { plan tests => 3 }

ok( eval { require DDLockClient; 1 } );
ok( exists $::{"DDLockClient::"} );
ok( exists $::{"DDLock::"} );



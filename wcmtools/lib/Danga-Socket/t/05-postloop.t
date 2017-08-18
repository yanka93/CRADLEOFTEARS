#!/usr/bin/perl -w

use strict;
use Test::More 'no_plan';
use Danga::Socket;

my ($t1, $t2, $iters);

$t1 = time();
$iters = 0;

Danga::Socket->SetLoopTimeout(250);
Danga::Socket->SetPostLoopCallback(sub {
    $iters++;
    return $iters < 4 ? 1 : 0;
});

Danga::Socket->EventLoop;

$t2 = time();

ok($iters == 4,    "four iters");
ok($t2 == $t1 + 1, "took a second");


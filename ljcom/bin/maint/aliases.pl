#!/usr/bin/perl
#

$maint{'makealiases'} = sub
{
    my $dbh = LJ::get_dbh("master");
    foreach (keys %LJ::FIXED_ALIAS) {
        $dbh->do("REPLACE INTO email_aliases (alias, rcpt) VALUES (?,?)",
                 undef, "$_\@$LJ::USER_DOMAIN", $LJ::FIXED_ALIAS{$_});
    }
};

1;

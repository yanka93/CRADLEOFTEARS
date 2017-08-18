package LJ::Poll;

use strict;

sub replace_polls_with_links {
  my ($event) = @_;

  my $dbr = LJ::get_db_reader();

  while ($$event =~ /<lj-poll-(\d+)>/g) {
      my $pollid = $1;
      my $name = $dbr->selectrow_array("SELECT name FROM poll WHERE pollid=?",
                                       undef, $pollid);

      if ($name) {
          LJ::Poll::clean_poll(\$name);
      } else {
          $name = "#$pollid";
      }

      $$event =~ s!<lj-poll-$pollid>!<div><a href="$LJ::SITEROOT/poll/?id=$pollid">View Poll: $name</a></div>!g;
  }
}

return 1;

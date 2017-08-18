#!/usr/bin/perl

use strict;

package LJ::ParseFeed;

use XML::RSS;
use XML::Parser;


# parse_feed parses an RSS/Atom feed 
# arguments: content and, optionally, type, specifying "atom" or
# "rss". If type isn't supplied, the function will try to guess it
# based on contents.
# It returns $feed, which is a hash
# with the following keys:
#  type - 'atom' or 'rss'
#  version - version of the feed in its standard
#  link - URL of the feed
#  title - title of the feed
#  description - description of the feed
#  # TODO: more kinds of info?
#
#  items - arrayref of item hashes, in the same order they were in the feed
#    each item contains:
#    link - URL of the item
#    id - unique identifier (optional)
#    text - text of the item
#    subject - subject
#    time - in format 'yyyy-mm-dd hh:mm' (optional)
# the second argument returned is $error, which, if defined, is a human-readable
# error string. the third argument is arrayref of items, same as 
# $feed->{'items'}.

sub parse_feed
{
    my ($content, $type) = @_;
    my ($feed, $items, $error);
    my $parser;

    # is it RSS or Atom?
    # Atom feeds are rare for now, so prefer to err in favor of RSS
    # simple heuristic: Atom feeds will have '<feed' somewhere at the beginning
    # TODO: maybe store the feed's type on creation in a userprop and not guess here
    
    my $cut = substr($content, 0, 255);
    if ($type eq 'atom' || $cut =~ m!\<feed!) {
        # try treating it as an atom feed
        $parser = new XML::Parser(Style=>'Stream', Pkg=>'LJ::ParseFeed::Atom');
        return ("", "failed to create XML parser") unless $parser;
        eval {
            $parser->parse($content);
        };
        if ($@) {
            $error = "XML parser error: $@";
        } else {
            ($feed, $items, $error) = LJ::ParseFeed::Atom::results();
        };
    
        if ($feed || $type eq 'atom') {
            # there was a top-level <feed> there, or we're forced to treat
            # as an Atom feed, so even if $error is set,
            # don't try RSS
            $feed->{'type'} = 'atom';
            return ($feed, $error, $items);
        }
    }

    # try parsing it as RSS
    $parser = new XML::RSS;
    return ("", "failed to create RSS parser") unless $parser;
    eval {
        $parser->parse($content);
    };
    if ($@) {
        $error = "RSS parser error: $@";
        return ("", $error);
    }

    $feed = {};
    $feed->{'type'} = 'rss';
    $feed->{'version'} = $parser->{'version'};

    foreach (qw (link title description)) {
        $feed->{$_} = $parser->{'channel'}->{$_}
            if $parser->{'channel'}->{$_};
    }
    
    $feed->{'items'} = [];

    foreach(@{$parser->{'items'}}) {
        my $item = {};
        $item->{'subject'} = $_->{'title'};
        $item->{'text'} = $_->{'description'};
        $item->{'link'} = $_->{'link'} if $_->{'link'};
        $item->{'id'} = $_->{'guid'} if $_->{'guid'};

        my $nsdc = 'http://purl.org/dc/elements/1.1/';
        my $nsenc = 'http://purl.org/rss/1.0/modules/content/';
        if ($_->{$nsenc} && ref($_->{$nsenc}) eq "HASH") {
            # prefer content:encoded if present
            $item->{'text'} = $_->{$nsenc}->{'encoded'}
                if defined $_->{$nsenc}->{'encoded'};
        }

        if ($_->{'pubDate'}) {
            my $time = time822_to_time($_->{'pubDate'});
            $item->{'time'} = $time if $time;
        }
        if ($_->{$nsdc} && ref($_->{$nsdc}) eq "HASH") {
            if ($_->{$nsdc}->{date}) {
                my $time = w3cdtf_to_time($_->{$nsdc}->{date});
                $item->{'time'} = $time if $time;
            }
        }
        push @{$feed->{'items'}}, $item;
    }

    return ($feed, undef, $feed->{'items'});
}

# convert rfc822-time in RSS's <pubDate> to our time
# see http://www.faqs.org/rfcs/rfc822.html
# RFC822 specifies 2 digits for year, and RSS2.0 refers to RFC822,
# but real RSS2.0 feeds apparently use 4 digits. 
sub time822_to_time {
    my $t822 = shift;
    # remove day name if present
    $t822 =~ s/^\s*\w+\s*,//;
    # remove whitespace
    $t822 =~ s/^\s*//;
    # break it up
    if ($t822 =~ m!(\d?\d)\s+(\w+)\s+(\d\d\d\d)\s+(\d?\d):(\d\d)!) {
        my ($day, $mon, $year, $hour, $min) = ($1,$2,$3,$4,$5);
        $day = "0" . $day if length($day) == 1;
        $hour = "0" . $hour if length($hour) == 1;
        $mon = {'Jan'=>'01', 'Feb'=>'02', 'Mar'=>'03', 'Apr'=>'04',
                'May'=>'05', 'Jun'=>'06', 'Jul'=>'07', 'Aug'=>'08',
                'Sep'=>'09', 'Oct'=>'10', 'Nov'=>'11', 'Dec'=>'12'}->{$mon};
        return undef unless $mon;
        return "$year-$mon-$day $hour:$min";
    } else {
        return undef;
    }
}

# convert W3C-DTF to our internal format
# see http://www.w3.org/TR/NOTE-datetime
# Based very loosely on code from DateTime::Format::W3CDTF,
# which isn't stable yet so we can't use it directly.
sub w3cdtf_to_time {
    my $tw3 = shift;

    # TODO: Should somehow return the timezone offset
    #   so that it can stored... but we don't do timezones
    #   yet anyway. For now, just strip the timezone
    #   portion if it is present, along with the decimal
    #   fractions of a second.
    
    $tw3 =~ s/(?:\.\d+)?(?:[+-]\d{1,2}:\d{1,2}|Z)$//;
    $tw3 =~ s/^\s*//; $tw3 =~ s/\s*$//; # Eat any superflous whitespace

    # We can only use complete times, so anything which
    # doesn't feature the time part is considered invalid.
    
    # This is working around clients that don't implement W3C-DTF
    # correctly, and only send single digit values in the dates.
    # 2004-4-8T16:9:4Z vs 2004-04-08T16:09:44Z
    # If it's more messed up than that, reject it outright.
    $tw3 =~ /^(\d{4})-(\d{1,2})-(\d{1,2})T(\d{1,2}):(\d{1,2})(?::(\d{1,2}))?$/
        or return undef;

    my %pd; # parsed date
    $pd{Y} = $1; $pd{M} = $2; $pd{D} = $3;
    $pd{h} = $4; $pd{m} = $5; $pd{s} = $6;

    # force double digits
    foreach (qw/ M D h m s /) {
        next unless defined $pd{$_};
        $pd{$_} = sprintf "%02d", $pd{$_};
    }

    return $pd{s} ? "$pd{Y}-$pd{M}-$pd{D} $pd{h}:$pd{m}:$pd{s}" :
                    "$pd{Y}-$pd{M}-$pd{D} $pd{h}:$pd{m}";
}

package LJ::ParseFeed::Atom;

our ($feed, $item, $data);
our ($ddepth, $dholder); # for accumulating;
our @items;
our $error;

sub err {
    $error = shift unless $error;
}

sub results {
    return ($feed, \@items, $error);
}

# $name under which we'll store accumulated data may be different
# from $tag which causes us to store it
# $name may be a scalarref pointing to where we should store
# swallowing is achieved by calling startaccum('');

sub startaccum {
    my $name = shift;

    return err("Tag found under neither <feed> nor <entry>")
        unless $feed || $item;
    $data = ""; # defining $data triggers accumulation
    $ddepth = 1;

    $dholder = undef 
        unless $name;
    # if $name is a scalarref, it's actually our $dholder
    if (ref($name) eq 'SCALAR') {
        $dholder = $name;
    } else {
        $dholder = ($item ? \$item->{$name} : \$feed->{$name})
            if $name;
    }
    return;
}

sub swallow {
    return startaccum('');
}

sub StartDocument {
    ($feed, $item, $data) = (undef, undef, undef);
    @items = ();
    undef $error;
}

sub StartTag {
    # $_ carries the unparsed tag
    my ($p, $tag) = @_;
    my $holder;

    # do nothing if there has been an error
    return if $error;

    # are we just accumulating data?
    if (defined $data) {
        $data .= $_;
        $ddepth++;
        return;
    }

    # where we'll usually store info
    $holder = $item ? $item : $feed;

    TAGS: {
        if ($tag eq 'feed') {
            return err("Nested <feed> tags") 
                if $feed;
            $feed = {};
            $feed->{'standard'} = 'atom';
            $feed->{'version'} = $_{'version'};
            return err("No version specified in <feed>")
                unless $feed->{'version'};
            return err("Incompatible version specified in <feed>")
                unless $feed->{'version'} eq '0.3';
            last TAGS;
        }
        if ($tag eq 'entry') {
            return err("Nested <entry> tags") 
                if $item;
            $item = {};
            last TAGS;
        }
        
        # at this point, we must have a top-level <feed> or <entry>
        # to write into
        return err("Tag found under neither <feed> nor <entry>")
            unless $holder;

        if ($tag eq 'link') {
            # ignore links with rel= anything but alternate
            unless ($_{'rel'} eq 'alternate') {
                swallow();
                last TAGS;
            }
            $holder->{'link'} = $_{'href'};
            return err("No href attribute in <link>")
                unless $holder->{'link'};
            last TAGS;
        }

        if ($tag eq 'content') {
            return err("<content> outside <entry>")
                unless $item;
            # if type is multipart/alternative, we continue recursing
            # otherwise we accumulate
            my $type = $_{'type'} || "text/plain";
            unless ($type eq "multipart/alternative") {
                push @{$item->{'contents'}}, [$type, ""];
                startaccum(\$item->{'contents'}->[-1]->[1]);
                last TAGS;
            }
            # it's multipart/alternative, so recurse, but don't swallow
            last TAGS;
        }

        # store tags which should require no further
        # processing as they are, and others under _atom_*, to be processed
        # in EndTag under </entry>
        if ($tag eq 'title') {
            if ($item) { # entry's subject
                startaccum("subject");
            } else { # feed's title
                startaccum($tag);
            }
            last TAGS;
        }
        if ($tag eq 'id') {
            unless ($item) {
                swallow(); # we don't need feed-level <id>
            } else {
                startaccum($tag);
            }
            last TAGS;
        }

        if ($tag eq 'tagline' && !$item) { # feed's tagline, our "description"
            startaccum("description");
            last TAGS;
        }

        # accumulate and store
        startaccum("_atom_" . $tag);
        last TAGS;
    }
            
    return;
}

sub EndTag {
    # $_ carries the unparsed tag
    my ($p, $tag) = @_;

    # do nothing if there has been an error
    return if $error;

    # are we accumulating data?
    if (defined $data) {
        $ddepth--;
        if ($ddepth == 0) { # stop accumulating
            $$dholder = $data
                if $dholder;
            undef $data;
            return;
        }
        $data .= $_;
        return;
    }

    TAGS: {
        if ($tag eq 'entry') {
            # finalize item...
            # generate suitable text from $item->{'contents'}            
            my $content;
            $item->{'contents'} ||= [];
            unless (scalar(@{$item->{'contents'}}) >= 1) {
                # this item had no <content>
                # maybe it has <summary>? if so, use <summary>
                # TODO: type= or encoding issues here? perhaps unite
                # handling of <summary> with that of <content>?
                if ($item->{'_atom_summary'}) {
                    $item->{'text'} = $item->{'_atom_summary'};
                    delete $item->{'contents'};
                } else {
                    # nothing to display, so ignore this entry
                    undef $item;
                    last TAGS;
                }
            }

            unless ($item->{'text'}) { # unless we already have text
                if (scalar(@{$item->{'contents'}}) == 1) {
                    # only one <content> section
                    $content = $item->{'contents'}->[0]; 
                } else {
                    # several <content> section, must choose the best one
                    foreach (@{$item->{'contents'}}) {
                        if ($_->[0] eq "application/xhtml+xml") { # best match
                            $content = $_;
                            last; # don't bother to look at others
                        }
                        if ($_->[0] =~ m!html!) { # some kind of html/xhtml/html+xml, etc.
                            # choose this unless we've already chosen some html
                            $content = $_
                                unless $content->[0] =~ m!html!;
                            next;
                        }
                        if ($_->[0] eq "text/plain") {
                            # choose this unless we have some html already
                            $content = $_
                                unless $content->[0] =~ m!html!;
                            next;
                        }
                    }
                    # if we didn't choose anything, pick the first one
                    $content =  $item->{'contents'}->[0]
                        unless $content;
                }

                # we ignore the 'mode' attribute of <content>. If it's "xml", we've
                # stringified it by accumulation; if it's "escaped", our parser
                # unescaped it
                # TODO: handle mode=base64?

                $item->{'text'} = $content->[1];
                delete $item->{'contents'};
            }

            # generate time
            my $w3time = $item->{'_atom_modified'} || $item->{'_atom_created'};
            my $time;
            if ($w3time) {
                # see http://www.w3.org/TR/NOTE-datetime for format
                # we insist on having granularity up to a minute,
                # and ignore finer data as well as the timezone, for now
                if ($w3time =~ m!^(\d\d\d\d)-(\d\d)-(\d\d)T(\d\d):(\d\d)!) {
                    $time = "$1-$2-$3 $4:$5";
                }
            }
            if ($time) {
                $item->{'time'} = $time;
            }
            
            # get rid of all other tags we don't need anymore
            foreach (keys  %$item) {
                delete $item->{$_} if substr($_, 0, 6) eq '_atom_';
            }
            
            push @items, $item;
            undef $item;
            last TAGS;
        }
        if ($tag eq 'feed') {
            # finalize feed
            # get rid of all other tags we don't need anymore
            foreach (keys  %$feed) {
                delete $feed->{$_} if substr($_, 0, 6) eq '_atom_';
            }
            
            # link the feed with its itms
            $feed->{'items'} = \@items 
                if $feed;
            last TAGS;
        }
    }
    return;
}

sub Text {
    my $p = shift;

    # do nothing if there has been an error
    return if $error;

    $data .= $_ if defined $data;
}

sub PI {
    # ignore processing instructions
    return;
}

sub EndDocument {
    # if we parsed a feed, link items to it
    $feed->{'items'} = \@items 
        if $feed;
    return;
}


1;

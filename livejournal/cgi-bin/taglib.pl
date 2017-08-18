#!/usr/bin/perl

package LJ::Tags;

use strict;

# <LJFUNC>
# name: LJ::Tags::get_usertagsmulti
# class: tags
# des: Gets a bunch of tags for the specified list of users.
# args: uobj*
# des-uobj: One or more user ids or objects to load the tags for.
# returns: Hashref; { userid => *tagref*, userid => *tagref*, ... } where *tagref* is the
#          return value of LJ::Tags::get_usertags -- undef on failure
# </LJFUNC>
sub get_usertagsmulti {
    return {} if $LJ::DISABLED{tags};

    # get input users
    my @uobjs = grep { defined } map { LJ::want_user($_) } @_;
    return {} unless @uobjs;

    # now setup variables we'll need
    my @memkeys;  # memcache keys to fetch
    my @resjids;  # final list of journal ids
    my $res = {}; # { jid => { tagid => {}, ... }, ... }; results return hashref
    my %jid2cid;  # ( jid => cid ); cross reference journals to clusters
    my %need;     # ( cid => { jid => 1 } ); what we still need

    # prepopulate our structures
    foreach my $u (@uobjs) {
        $jid2cid{$u->{userid}} = $u->{clusterid};
        $need{$u->{clusterid}}->{$u->{userid}} = 1;
        push @memkeys, [ $u->{userid}, "tags:$u->{userid}" ];
    }

    # gather data from memcache if available
    my $memc = LJ::MemCache::get_multi(@memkeys) || {};
    foreach my $key (keys %$memc) {
        if ($key =~ /^tags:(\d+)$/) {
            my $jid = $1;
            my $cid = $jid2cid{$jid};

            # set this up in our return hash
            $res->{$jid} = $memc->{$key};

            # no longer need this user
            delete $need{$cid}->{$jid};

            # delete cluster if no more users
            delete $need{$cid}
                unless %{$need{$cid}};
        }
    }

    # now, what we need per cluster...
    foreach my $cid (keys %need) {
        # get db for this cluster
        my $dbcr = LJ::get_cluster_def_reader($cid)
            or next;

        # useful sql
        my $in = join(',', map { $_ + 0 } keys %{$need{$cid}});

        # get the tags from the database
        my $tagrows = $dbcr->selectall_arrayref(qq{
                SELECT journalid, kwid, parentkwid, display
                FROM usertags
                WHERE journalid IN ($in)
            });
        next if $dbcr->err || ! $tagrows;

        # break down into data structures
        my %tags; # ( jid => ( id => display ) )
        $tags{$_->[0]}->{$_->[1]} = $_->[3]
            foreach @$tagrows;

        # if they have no tags...
        next unless %tags;

        # create SQL for finding the proper ids... (userid = ? AND kwid IN (...)) OR (userid = ? ...) ...
        my @stmts;
        foreach my $uid (keys %tags) {
            push @stmts, "(userid = " . ($uid+0) . " AND kwid IN (" .
                         join(',', map { $_+0 } keys %{$tags{$uid}}) .
                         "))";
        }
        my $where = join(' OR ', @stmts);
            
        # get the keyword ids they have used as tags
        my $rows = $dbcr->selectall_arrayref("SELECT userid, kwid, keyword FROM userkeywords WHERE $where");
        next if $dbcr->err || ! $rows;

        # now turn this into a tentative results hash: { userid => { tagid => { name => tagname, ... }, ... } }
        foreach my $row (@$rows) {
            $res->{$row->[0]}->{$row->[1]} =
                {
                    name => $row->[2],
                    security => {
                        public => 0,
                        groups => {},
                        private => 0,
                        friends => 0
                    },
                    uses => 0,
                    display => $tags{$row->[0]}->{$row->[1]},
                };
        }
        @resjids = keys %$res;

        # get security counts
        my $ids = join(',', map { $_+0 } @resjids);

        # populate security counts
        my $counts = $dbcr->selectall_arrayref("SELECT journalid, kwid, security, entryct FROM logkwsum WHERE journalid IN ($ids)");
        next if $dbcr->err || ! $counts;

        # setup some helper values
        my $public_mask = 1 << 31;
        my $friends_mask = 1 << 0;

        # melt this information down into the hashref
        foreach my $row (@$counts) {
            my ($jid, $kwid, $sec, $ct) = @$row;

            # make sure this journal and keyword are present in the results already
            # so we don't auto-vivify something with security that has no keyword with it
            next unless $res->{$jid} && $res->{$jid}->{$kwid};

            # add these to the total uses
            $res->{$jid}->{$kwid}->{uses} += $ct;

            if ($sec & $public_mask) {
                $res->{$jid}->{$kwid}->{security}->{public} += $ct;
                $res->{$jid}->{$kwid}->{security_level} = 'public';
            } elsif ($sec & $friends_mask) {
                $res->{$jid}->{$kwid}->{security}->{friends} += $ct;
                $res->{$jid}->{$kwid}->{security_level} = 'friends'
                    unless $res->{$jid}->{$kwid}->{security_level} eq 'public';
            } elsif ($sec) {
                # if $sec is true (>0), and not friends/public, then it's a group.  but it's
                # still in the form of a number, and we want to know which group it is.  so
                # we must convert the mask back to a bit number with LJ::bit_breakdown.  but
                # we will only ever have one mask, so we just accept that.
                my $grpid = (LJ::bit_breakdown($sec))[0] + 0;
                $res->{$jid}->{$kwid}->{security}->{groups}->{$grpid} += $ct;
                $res->{$jid}->{$kwid}->{security_level} ||= 'group';
            } else {
                # $sec must be 0
                $res->{$jid}->{$kwid}->{security}->{private} += $ct;
            }
        }

        # default securities to private and store to memcache
        foreach my $jid (@resjids) {
            $res->{$jid}->{$_}->{security_level} ||= 'private'
                foreach keys %{$res->{$jid}};

            LJ::MemCache::add([ $jid, "tags:$jid" ], $res->{$jid});
        }
    }

    return $res;
}

# <LJFUNC>
# name: LJ::Tags::get_usertags
# class: tags
# des: Returns the tags that a user has defined for their account.
# args: uobj, opts?
# des-uobj: User object to get tags for.
# des-opts: Optional hashref; key can be 'remote' to filter tags to only ones that remote can see
# returns: Hashref; key being tag id, value being a large hashref (FIXME: document)
# </LJFUNC>
sub get_usertags {
    return {} if $LJ::DISABLED{tags};

    my $u = LJ::want_user(shift)
        or return undef;
    my $opts = shift() || {};

    # get tags for this user
    my $tags = LJ::Tags::get_usertagsmulti($u);
    return undef unless $tags;

    # get the tags for this user
    my $res = $tags->{$u->{userid}} || {};
    return {} unless %$res;

    # now if they provided a remote, remove the ones they don't want to see; note that
    # remote may be undef so we have to check exists
    if (exists $opts->{remote}) {
        # never going to cull anything if it's you, so return it
        return $res if LJ::u_equals($u, $opts->{remote});

        # setup helper variables from u to remote
        my ($is_friend, $grpmask) = (0, 0);
        if ($opts->{remote}) {
            $is_friend = LJ::is_friend($u, $opts->{remote});
            $grpmask = LJ::get_groupmask($u, $opts->{remote});
        }

        # figure out what we need to purge
        my @purge;
TAG:    foreach my $tagid (keys %$res) {
            my $sec = $res->{$tagid}->{security_level};
            next TAG if $sec eq 'public';
            next TAG if $is_friend && $sec eq 'friends';
            if ($grpmask && $sec eq 'group') {
                foreach my $grpid (%{$res->{$tagid}->{security}->{groups}}) {
                    next TAG if $grpmask & (1 << $grpid);
                }
            }
            push @purge, $tagid;
        }
        delete $res->{$_} foreach @purge;
    }

    return $res;
}

# <LJFUNC>
# name: LJ::Tags::get_entry_tags
# class: tags
# des: Gets tags that have been used on an entry
# args: uuserid, jitemid
# des-uuserid: User id or object of account with entry
# des-jitemid: Journal itemid of entry; may also be arrayref of jitemids in journal.
# returns: Hashref; { jitemid => { tagid => tagname, tagid => tagname, ... }, ... }
# </LJFUNC>
sub get_logtags {
    return {} if $LJ::DISABLED{tags};

    my $u = LJ::want_user(shift);
    return undef unless $u;

    # handle magic jitemid parameter
    my $jitemid = shift;
    unless (ref $jitemid eq 'ARRAY') {
        $jitemid = [ $jitemid+0 ];
        return undef unless $jitemid->[0];
    }
    return undef unless @$jitemid;

    # transform to a call to get_logtagsmulti
    my $ret = LJ::Tags::get_logtagsmulti({ $u->{clusterid} => [ map { [ $u->{userid}, $_ ] } @$jitemid ] });
    return undef unless $ret && ref $ret eq 'HASH';

    # now construct result hashref
    return { map { $_ => $ret->{"$u->{userid} $_"} } @$jitemid };
}

# <LJFUNC>
# name: LJ::Tags::get_logtagsmulti
# class: tags
# des: Load tags on a given set of entries
# args: idsbyc
# des-idsbyc: { clusterid => [ [ jid, jitemid ], [ jid, jitemid ], ... ] }
# returns: hashref with "jid jitemid" keys, value of each being a hashref of
#          { tagid => tagname, ... }
# </LJFUNC>
sub get_logtagsmulti {
    return {} if $LJ::DISABLED{tags};

    # get parameter (only one!)
    my $idsbycluster = shift;
    return undef unless $idsbycluster && ref $idsbycluster eq 'HASH';

    # the mass of variables to make this mess work!
    my @jids;     # journalids we've seen
    my @memkeys;  # memcache keys to load
    my %ret;      # ( jid => { jitemid => [ tagid, tagid, ... ], ... } ); storage for data pre-final conversion
    my %set;      # ( jid => ( jitemid => [ tagid, tagid, ... ] ) ); for setting in memcache
    my $res = {}; # { "jid jitemid" => { tagid => kw, tagid => kw, ... } }; final results hashref for return
    my %need;     # ( cid => { jid => { jitemid => 1, jitemid => 1 } } ); what still needs loading
    my %jid2cid;  # ( jid => cid ); map of journal id to clusterid

    # construct memcache keys for loading below
    foreach my $cid (keys %$idsbycluster) {
        foreach my $row (@{$idsbycluster->{$cid} || []}) {
            $need{$cid}->{$row->[0]}->{$row->[1]} = 1;
            $jid2cid{$row->[0]} = $cid;
            push @memkeys, [ $row->[0], "logtag:$row->[0]:$row->[1]" ];
        }
    }

    # now hit up memcache to try to find what we can
    my $memc = LJ::MemCache::get_multi(@memkeys) || {};
    foreach my $key (keys %$memc) {
        if ($key =~ /^logtag:(\d+):(\d+)$/) {
            my ($jid, $jitemid) = ($1, $2);
            my $cid = $jid2cid{$jid};

            # save memcache output hashref to out %ret var
            $ret{$jid}->{$jitemid} = $memc->{$key};

            # no longer need this jid->jitemid combo
            delete $need{$cid}->{$jid}->{$jitemid};

            # no longer need this user if no more jitemids for them
            delete $need{$cid}->{$jid}
                unless %{$need{$cid}->{$jid}};

            # delete cluster from need if no more users on it
            delete $need{$cid}
                unless %{$need{$cid}};
        }
    }

    # iterate over clusters and construct SQL to get the data...
    foreach my $cid (keys %need) {
        my $dbcm = LJ::get_cluster_master($cid)
            or return undef;

        # list of (jid, jitemid) pairs that we get from %need
        my @bind;
        foreach my $jid (keys %{$need{$cid} || {}}) {
            push @bind, ($jid, $_)
                foreach keys %{$need{$cid}->{$jid} || {}};
        }

        # @bind is always even (from above), so the count of query elements we need is the
        # number of items in @bind, divided by 2
        my $sql = join(' OR ', map { "(journalid = ? AND jitemid = ?)" } 1..(scalar(@bind)/2));

        # prepare the query to run
        my $sth = $dbcm->prepare("SELECT journalid, jitemid, kwid FROM logtags WHERE ($sql)");
        return undef if $dbcm->err || ! $sth;

        # execute, fail on error
        $sth->execute(@bind);
        return undef if $sth->err;

        # get data into %set so we add it to memcache later
        while (my ($jid, $jitemid, $kwid) = $sth->fetchrow_array) {
            push @{$set{$jid}->{$jitemid} ||= []}, $kwid;
        }
    }

    # now add the things to memcache that we loaded from the clusters and also
    # transport them into the $ret hashref or returning to the user
    foreach my $jid (keys %set) {
        foreach my $jitemid (keys %{$set{$jid}}) {
            LJ::MemCache::add([ $jid, "logtag:$jid:$jitemid" ], $set{$jid}->{$jitemid});
            $ret{$jid}->{$jitemid} = $set{$jid}->{$jitemid};
        }
    }

    # quickly load all tags for the users we've found
    @jids = keys %ret;
    my $utags = LJ::Tags::get_usertagsmulti(@jids);
    return undef unless $utags;

    # last step: convert keywordids to keywords
    foreach my $jid (@jids) {
        my $tags = $utags->{$jid};
        next unless $tags;

        # transpose data from %ret into $res hashref which has (kwid => keyword) pairs
        foreach my $jitemid (keys %{$ret{$jid}}) {
            $res->{"$jid $jitemid"}->{$_} = $tags->{$_}->{name}
                foreach @{$ret{$jid}->{$jitemid} || []};
        }
    }

    # finally return the result hashref
    return $res;
}

# <LJFUNC>
# name: LJ::Tags::can_add_tags
# class: tags
# des: Determines if one account is allowed to add tags to another's post
# args: u, remote
# des-u: User id or object of account tags are being added to
# des-remote: User id or object of account performing the action
# returns: 1 if allowed, 0 if not, undef on error
# </LJFUNC>
sub can_add_tags {
    return undef if $LJ::DISABLED{tags};

    my $u = LJ::want_user(shift);
    my $remote = LJ::want_user(shift);
    return undef unless $u && $remote;
    return undef unless $remote->{journaltype} eq 'P';
    return undef if LJ::is_banned($remote, $u);

    # get permission hashref and check it; note that we fall back to the control
    # permission, which will allow people to add even if they can't add by default
    my $perms = LJ::Tags::get_permission_levels($u);
    return LJ::Tags::_remote_satisfies_permission($u, $remote, $perms->{add}) ||
           LJ::Tags::_remote_satisfies_permission($u, $remote, $perms->{control});
}

# <LJFUNC>
# name: LJ::Tags::can_control_tags
# class: tags
# des: Determines if one account is allowed to control (add, edit, delete) the tags of another
# args: u, remote
# des-u: User id or object of account tags are being edited on
# des-remote: User id or object of account performing the action
# returns: 1 if allowed, 0 if not, undef on error
# </LJFUNC>
sub can_control_tags {
    return undef if $LJ::DISABLED{tags};

    my $u = LJ::want_user(shift);
    my $remote = LJ::want_user(shift);
    return undef unless $u && $remote;
    return undef unless $remote->{journaltype} eq 'P';
    return undef if LJ::is_banned($remote, $u);

    # get permission hashref and check it
    my $perms = LJ::Tags::get_permission_levels($u);
    return LJ::Tags::_remote_satisfies_permission($u, $remote, $perms->{control});
}

# helper sub internal used by can_*_tags functions
sub _remote_satisfies_permission {
    my ($u, $remote, $perm) = @_;
    return undef unless $u && $remote && $perm;

    # permission checks
    if ($perm eq 'public') {
        return 1;
    } elsif ($perm eq 'none') {
        return 0;
    } elsif ($perm eq 'friends') {
        return LJ::is_friend($u, $remote);
    } elsif ($perm eq 'private') {
        return LJ::can_manage($remote, $u);
    } elsif ($perm =~ /^group:(\d+)$/) {
        my $grpid = $1+0;
        return undef unless $grpid >= 1 && $grpid <= 30;

        my $mask = LJ::get_groupmask($u, $remote);
        return ($mask & (1 << $grpid)) ? 1 : 0;
    } else {
        # else, problem!
        return undef;
    }
}

# <LJFUNC>
# name: LJ::Tags::get_permission_levels
# class: tags
# des: Gets the permission levels on an account
# args: uobj
# des-uobj: User id or object of account to get permissions for
# returns: Hashref; keys one of 'add', 'control'; values being 'private' (only the account
#          in question), 'friends' (all friends), 'public' (everybody), 'group:N' (one
#          friend group with given id), or 'none' (nobody can)
# </LJFUNC>
sub get_permission_levels {
    return { add => 'none', control => 'none' }
        if $LJ::DISABLED{tags};

    my $u = LJ::want_user(shift);
    return undef unless $u;

    # get the prop
    LJ::load_user_props($u, 'opt_tagpermissions');

    # return defaults for accounts
    unless ($u->{opt_tagpermissions}) {
        if ($u->{journaltype} eq 'C') {
            # communities are members (friends) add, private (maintainers) control
            return { add => 'friends', control => 'private' };
        } elsif ($u->{journaltype} eq 'P') {
            # people let friends add, self control
            return { add => 'private', control => 'private' };
        } else {
            # other account types can't add tags
            return { add => 'none', control => 'none' };
        }
    }

    # now split and return
    my ($add, $control) = split(/\s*,\s*/, $u->{opt_tagpermissions});
    return { add => $add, control => $control };
}

# <LJFUNC>
# name: LJ::Tags::is_valid_tagstring
# class: tags
# des: Determines if a string contains a valid list of tags.
# args: tagstring, listref?
# des-tagstring: Opaque tag string provided by the user.
# des-listref: If specified, return valid list of canonical tags in arrayref here.
# returns: 1 if list is valid, 0 if not.
# </LJFUNC>
sub is_valid_tagstring {
    my ($tagstring, $listref) = @_;
    return 0 unless $tagstring;
    $listref ||= [];

    # setup helper subs
    my $valid_tag = sub {
        my $tag = shift;
        return 0 if $tag =~ /^_/;               # reserved for future use (starting with underscore)
        return 0 if $tag =~ /[\<\>\r\n\t]/;     # no HTML, newlines, tabs, etc
        return 0 unless $tag =~ /^(?:.+\s?)+$/; # one or more "words"
        return 1;
    };
    my $canonical_tag = sub {
        my $tag = shift;
        $tag = LJ::trim($tag);
        $tag =~ s/\s+/ /g; # condense multiple spaces to a single space
        $tag = LJ::text_trim($tag, LJ::BMAX_KEYWORD, LJ::CMAX_KEYWORD);
        $tag = lc $tag
            if $tag !~ /[\x7f-\xff]/;
        return $tag;
    };

    # now iterate
    my @list = grep { length $_ }            # only keep things that are something
               map { LJ::trim($_) }          # remove leading/trailing spaces
               split(/\s*,\s*/, $tagstring); # split on comma with optional spaces
    return 0 unless @list;

    # now validate each one as we go
    foreach my $tag (@list) {
        # canonicalize and determine validity
        $tag = $canonical_tag->($tag);
        return 0 unless $valid_tag->($tag);

        # now push on our list
        push @$listref, $tag;
    }

    # well, it must have been okay if we got here
    return 1;
}

# <LJFUNC>
# name: LJ::Tags::get_security_breakdown
# class: tags
# des: Returns a list of security levels that apply to the given security information.
# args: security, allowmask
# des-security: 'private', 'public', or 'usemask'
# des-allowmask: a bitmask in standard allowmask form
# returns: List of broken down security levels to use for logkwsum table.
# </LJFUNC>
sub get_security_breakdown {
    my ($sec, $mask) = @_;

    my @out;

    if ($sec eq 'private') {
        @out = (0);
    } elsif ($sec eq 'public') {
        @out = (1 << 31);
    } else {
        # have to get each group bit into a mask
        foreach my $bit (0..30) { # include 0 for friends only
            if ($mask & (1 << $bit)) {
                push @out, (1 << $bit);
            }
        }
    }

    return @out;
}

# <LJFUNC>
# name: LJ::Tags::update_logtags
# class: tags
# des: Updates the tags on an entry.  Tags not in the list you provide are deleted.
# args: uobj, jitemid, uobj, tags,
# des-uobj: User id or object of account with entry
# des-jitemid: Journal itemid of entry to tag
# des-opts: Hashref; keys being the action and values of the key being an arrayref of
#           tags to involve in the action.  Possible actions are 'add', 'set', and
#           'delete'.  With those, the value is a hashref of the tags (textual tags)
#           to add, set, or delete.  Other actions are 'add_ids', 'set_ids', and
#           'delete_ids'.  The value arrayref should then contain the tag ids to
#           act with.  Can also specify 'add_string', 'set_string', or 'delete_string'
#           as a comma separated list of user-supplied tags which are then canonicalized
#           and used.  'remote' is the remote user taking the actions (required).
# returns: 1 on success, undef on error
# </LJFUNC>
sub update_logtags {
    return undef if $LJ::DISABLED{tags};

    my $u = LJ::want_user(shift);
    my $jitemid = shift() + 0;
    return undef unless $u && $jitemid;
    return undef unless $u->writer;

    # ensure we have an options hashref
    my $opts = shift;
    return undef unless $opts && ref $opts eq 'HASH';

    # perform set logic?
    my $do_set = exists $opts->{set} || exists $opts->{set_ids} || exists $opts->{set_string};

    # now get extra options
    my $remote = LJ::want_user(delete $opts->{remote});
    return undef unless $remote || $opts->{force};

    # get access levels
    my $can_control = LJ::Tags::can_control_tags($u, $remote);
    my $can_add = $can_control || LJ::Tags::can_add_tags($u, $remote);
    return undef unless $can_add || $opts->{force};

    # load the user's tags
    my $utags = LJ::Tags::get_usertags($u);
    return undef unless $utags;

    # take arrayrefs of tag strings and stringify them for validation
    foreach my $verb (qw(add set delete)) {
        # if given tags, combine into a string
        if ($opts->{$verb}) {
            $opts->{"${verb}_string"} = join(',', @{$opts->{$verb}});
            $opts->{$verb} = [];
        }

        # now validate the string, if we have one
        if ($opts->{"${verb}_string"}) {
            $opts->{$verb} = [];
            return undef
                unless LJ::Tags::is_valid_tagstring($opts->{"${verb}_string"}, $opts->{$verb});
        }

        # and turn everything into ids
        $opts->{"${verb}_ids"} ||= [];
        foreach my $kw (@{$opts->{$verb} || []}) {
            my $kwid = LJ::get_keyword_id($u, $kw, $can_control);
            if ($can_control) {
                # error if we failed to create
                return undef unless $kwid;
            } else {
                # if we're not creating, who cares, just skip; also skip if the keyword
                # is not really a tag (don't promote it)
                next unless $kwid && $utags->{$kwid};
            }

            # create it if necessary
            LJ::Tags::create_usertag($u, $kw, { display => 1 })
                unless $utags->{$kwid};

            push @{$opts->{"${verb}_ids"}}, $kwid;
        }
    }

    # setup %add/%delete hashes, for easier duplicate removal
    my %add = ( map { $_ => 1 } @{$opts->{add_ids} || []} );
    my %delete = ( map { $_ => 1 } @{$opts->{delete_ids} || []} );

    # used to keep counts in sync
    my $tags = LJ::Tags::get_logtags($u, $jitemid);
    return undef unless $tags;

    # now get tags for this entry; which there might be none, so make it a hashref
    $tags = $tags->{$jitemid} || {};

    # set is broken down into add/delete as necessary
    if ($do_set || ($opts->{set_ids} && @{$opts->{set_ids}})) {
        # mark everything to delete, we'll fix it shortly
        $delete{$_} = 1 foreach keys %{$tags};

        # and now go through the set we want, things that are in the delete
        # pile are just nudge so we don't touch them, and everything else we
        # throw in the add pile
        foreach my $id (@{$opts->{set_ids}}) {
            $add{$id} = 1
                unless delete $delete{$id};
        }
    }


    # now don't readd things we already have
    delete $add{$_} foreach keys %{$tags};

    # but delete nothing if we're not a controller
    %delete = () unless $can_control || $opts->{force};

    # bail out if nothing needs to be done
    return 1 unless %add || %delete;

    # %add and %delete are accurate, but we need to track necessary
    # security updates; this is a hash of keyword ids and a modification
    # value (a delta; +/-N) to be applied to that row later
    my %security;

    # get the security of this post for use in %security; do this now so
    # we don't interrupt the transaction below
    my $l2row = LJ::get_log2_row($u, $jitemid);
    return undef unless $l2row;

    # calculate security masks
    my @sec = LJ::Tags::get_security_breakdown($l2row->{security}, $l2row->{allowmask});

    # setup a rollback bail path so that we can undo everything we've done
    # if anything fails in the middle; and if the rollback fails, scream loudly
    # and burst into flames!
    my $rollback = sub {
        die $u->errstr unless $u->rollback;
        return undef;
    };

    # start the big transaction, for great justice!
    $u->begin_work;

    # process additions first
    my @bind;
    foreach my $kwid (keys %add) {
        $security{$kwid}++;
        push @bind, $u->{userid}, $jitemid, $kwid;
    }

    # now add all to both tables; only do 100 rows (300 bind vars) at a time
    while (my @list = splice(@bind, 0, 300)) {
        my $sql = join(',', map { "(?,?,?)" } 1..(scalar(@list)/3));

        $u->do("REPLACE INTO logtags (journalid, jitemid, kwid) VALUES $sql", undef, @list);
        return $rollback->() if $u->err;

        $u->do("REPLACE INTO logtagsrecent (journalid, jitemid, kwid) VALUES $sql", undef, @list);
        return $rollback->() if $u->err;
    }

    # now process deletions
    @bind = ();
    foreach my $kwid (keys %delete) {
        $security{$kwid}--;
        push @bind, $kwid;
    }

    # now run the SQL
    while (my @list = splice(@bind, 0, 100)) {
        my $sql = join(',', map { $_ + 0 } @list);

        $u->do("DELETE FROM logtags WHERE journalid = ? AND jitemid = ? AND kwid IN ($sql)",
               undef, $u->{userid}, $jitemid);
        return $rollback->() if $u->err;

        $u->do("DELETE FROM logtagsrecent WHERE journalid = ? AND kwid IN ($sql) AND jitemid = ?",
               undef, $u->{userid}, $jitemid);
        return $rollback->() if $u->err;
    }

    # now handle lazy cleaning of this table for these tag ids; note that the
    # %security hash contains all of the keywords we've operated on in total
    my @kwids = keys %security;
    my $sql = join(',', map { $_ + 0 } @kwids);
    my $sth = $u->prepare("SELECT kwid, COUNT(*) FROM logtagsrecent WHERE journalid = ? AND kwid IN ($sql) GROUP BY 1");
    return $rollback->() if $u->err || ! $sth;
    $sth->execute($u->{userid});
    return $rollback->() if $sth->err;

    # now iterate over counts and find ones that are too high
    my %delrecent; # kwid => [ jitemid, jitemid, ... ]
    while (my ($kwid, $ct) = $sth->fetchrow_array) {
        next unless $ct > 120;

        # get the times of the entries, the user time (lastn view uses user time), sort it, and then
        # we can chop off jitemids that fall below the threshold -- but only in this keyword and only clean
        # up some number at a time (25 at most, starting at our threshold)
        my $sth2 = $u->prepare(qq{
                SELECT t.jitemid
                FROM logtagsrecent t, log2 l
                WHERE t.journalid = l.journalid
                  AND t.jitemid = l.jitemid
                  AND t.journalid = ?
                  AND t.kwid = ?
                ORDER BY l.eventtime DESC
                LIMIT 100,25
            });
        return $rollback->() if $u->err || ! $sth2;
        $sth2->execute($u->{userid}, $kwid);
        return $rollback->() if $sth2->err;

        # push these onto the hash for deleting below
        while (my $jit = $sth2->fetchrow_array) {
            push @{$delrecent{$kwid} ||= []}, $jit;
        }
    }

    # now delete any recents we need to into this format:
    #    (kwid = 3 AND jitemid IN (2, 3, 4)) OR (kwid = ...) OR ...
    # but only if we have some to delete
    if (%delrecent) {
        my $del = join(' OR ', map {
                                    "(kwid = " . ($_+0) . " AND jitemid IN (" . join(',', map { $_+0 } @{$delrecent{$_}}) . "))"
                               } keys %delrecent);
        $u->do("DELETE FROM logtagsrecent WHERE journalid = ? AND ($del)", undef, $u->{userid});
        return $rollback->() if $u->err;
    }

    # now we must get the current security values in order to come up with a proper update; note that
    # we select for update, which locks it so we have a consistent view of the rows
    $sth = $u->prepare("SELECT kwid, security, entryct FROM logkwsum WHERE journalid = ? AND kwid IN ($sql) FOR UPDATE");
    return $rollback->() if $u->err || ! $sth;
    $sth->execute($u->{userid});
    return $rollback->() if $sth->err;

    # now iterate and get the security counts
    my %counts;
    while (my ($kwid, $sec, $ct) = $sth->fetchrow_array) {
        $counts{$kwid}->{$sec} = $ct;
    }

    # now we want to update them, and delete any at 0
    my (@replace, @delete);
    foreach my $kwid (@kwids) {
        foreach my $sec (@sec) {
            if (exists $counts{$kwid} && exists $counts{$kwid}->{$sec}) {
                # an old one exists
                my $new = $counts{$kwid}->{$sec} + $security{$kwid};
                if ($new > 0) {
                    # update it
                    push @replace, [ $kwid, $sec, $new ];
                } else {
                    # delete this one
                    push @delete, [ $kwid, $sec ];
                }
            } else {
                # add a new one
                push @replace, [ $kwid, $sec, $security{$kwid} ];
            }
        }
    }

    # handle deletes in one move; well, 100 at a time
    while (my @list = splice(@delete, 0, 100)) {
        my $sql = join(' OR ', map { "(kwid = ? AND security = ?)" } 1..scalar(@list));
        $u->do("DELETE FROM logkwsum WHERE journalid = ? AND ($sql)",
               undef, $u->{userid}, map { @$_ } @list);
        return $rollback->() if $u->err;
    }

    # handle replaces and inserts
    while (my @list = splice(@replace, 0, 100)) {
        my $sql = join(',', map { "(?,?,?,?)" } 1..scalar(@list));
        $u->do("REPLACE INTO logkwsum (journalid, kwid, security, entryct) VALUES $sql",
               undef, map { $u->{userid}, @$_ } @list);
        return $rollback->() if $u->err;
    }

    # commit everything and smack caches and we're done!
    die $u->errstr unless $u->commit;
    LJ::Tags::reset_cache($u);
    LJ::Tags::reset_cache($u => $jitemid);
    return 1;

}

# <LJFUNC>
# name: LJ::Tags::delete_logtags
# class: tags
# des: Deletes all tags on an entry.
# args: uobj, jitemid
# des-uobj: User id or object of account with entry
# des-jitemid: Journal itemid of entry to delete tags from
# returns: undef on error; 1 on success
# </LJFUNC>
sub delete_logtags {
    return undef if $LJ::DISABLED{tags};

    my $u = LJ::want_user(shift);
    my $jitemid = shift() + 0;
    return undef unless $u && $jitemid;

    # maybe this is ghetto, but it does all of the logic we would otherwise
    # have to duplicate here, so no sense in doing that.
    return LJ::Tags::update_logtags($u, $jitemid, { set_string => "", force => 1, });
}

# <LJFUNC>
# name: LJ::Tags::reset_cache
# class: tags
# des: Clears out all cached information for a user's tags.
# args: uobj, jitemid?
# des-uobj: User id or object of account to clear cache for
# des-jitemid: Either a single jitemid or an arrayref of jitemids to clear for the user.  If
#              not present, the user's tags cache is cleared.  If present, the cache for those
#              entries only are cleared.
# returns: undef on error; 1 on success
# </LJFUNC>
sub reset_cache {
    return undef if $LJ::DISABLED{tags};

    while (my ($u, $jitemid) = splice(@_, 0, 2)) {
        next unless
            $u = LJ::want_user($u);

        # standard user tags cleanup
        unless ($jitemid) {
            LJ::MemCache::delete([ $u->{userid}, "tags:$u->{userid}" ]);
        }

        # now, cleanup entries if necessary
        if ($jitemid) {
            $jitemid = [ $jitemid ]
                unless ref $jitemid eq 'ARRAY';
            LJ::MemCache::delete([ $u->{userid}, "logtag:$u->{userid}:$_" ])
                foreach @$jitemid;
        }
    }
    return 1;
}

# <LJFUNC>
# name: LJ::Tags::create_usertag
# class: tags
# des: Creates tags for a user, returning the keyword ids allocated.
# args: uobj, kw, opts?
# des-uobj: User object to create tag on.
# des-kw: Tag string (comma separated list of tags) to create.
# des-opts: Optional; hashref, possible keys being 'display' and value being whether or
#           not this tag should be a display tag and 'parenttagid' being the tagid of a
#           parent tag for heirarchy.
# returns: undef on error, else a hashref of { keyword => tagid } for each keyword defined
# </LJFUNC>
sub create_usertag {
    return undef if $LJ::DISABLED{tags};

    my $u = LJ::want_user(shift);
    my $kw = shift;
    my $opts = shift || {};
    return undef unless $u && $kw;

    my $tags = [];
    my $isvalid = LJ::Tags::is_valid_tagstring($kw, $tags);
    return undef unless $isvalid;

    my $display = $opts->{display} ? 1 : 0;
    my $parentkwid = $opts->{parenttagid} ? ($opts->{parenttagid}+0) : undef;

    my %res;
    foreach my $tag (@$tags) {
        my $kwid = LJ::get_keyword_id($u, $tag);
        return undef unless $kwid;

        $res{$tag} = $kwid;
    }

    my $ct = scalar keys %res;
    my $bind = join(',', map { "(?,?,?,?)" } 1..$ct);
    $u->do("INSERT IGNORE INTO usertags (journalid, kwid, parentkwid, display) VALUES $bind",
           undef, map { $u->{userid}, $_, $parentkwid, $display } values %res);
    return undef if $u->err;

    LJ::Tags::reset_cache($u);
    return \%res;
}

# <LJFUNC>
# name: LJ::Tags::validate_tag
# class: tags
# des: Check the validity of a single tag.
# args: tag
# des-tag: The tag to check.
# returns: If valid, the canonicalized tag, else, undef.
# </LJFUNC>
sub validate_tag {
    my $tag = shift;
    return undef unless $tag;

    my $list = [];
    return undef unless
        LJ::Tags::is_valid_tagstring($tag, $list);
    return undef if scalar(@$list) > 1;

    return $list->[0];
}

# <LJFUNC>
# name: LJ::Tags::delete_usertag
# class: tags
# des: Deletes a tag for a user, and all mappings.
# args: uobj, type, tag
# des-uobj: User object to delete tag on.
# des-type: Either 'id' or 'name', indicating the type of the third parameter.
# des-tag: If type is 'id', this is the tag id (kwid).  If type is 'name', this is the name of the
#          tag that we want to delete from the user.
# returns: undef on error, 1 for success, 0 for tag not found
# </LJFUNC>
sub delete_usertag {
    return undef if $LJ::DISABLED{tags};

    my $u = LJ::want_user(shift);
    return undef unless $u;

    my ($type, $val) = @_;

    my $kwid;
    if ($type eq 'name') {
        my $tag = LJ::Tags::validate_tag($val);
        return undef unless $tag;

        $kwid = LJ::get_keyword_id($u, $tag, 0);
    } elsif ($type eq 'id') {
        $kwid = $val + 0;
    }
    return undef unless $kwid;

    # escape sub
    my $rollback = sub {
        die $u->errstr unless $u->rollback;
        return undef;
    };

    # start the big transaction
    $u->begin_work;

    # get items this keyword is on
    my $sth = $u->prepare('SELECT jitemid FROM logtags WHERE journalid = ? AND kwid = ? FOR UPDATE');
    return $rollback->() if $u->err || ! $sth;

    # now get the items
    $sth->execute($u->{userid}, $kwid);
    return $rollback->() if $sth->err;

    # now get list of jitemids for later cache clearing
    my @jitemids;
    push @jitemids, $_
        while $_ = $sth->fetchrow_array;

    # delete this tag's information from the relevant tables
    foreach my $table (qw(usertags logtags logtagsrecent logkwsum)) {
        # no error checking, we're just deleting data that's already semi-unlinked due
        # to us already updating the userprop above
        $u->do("DELETE FROM $table WHERE journalid = ? AND kwid = ?",
               undef, $u->{userid}, $kwid);
    }

    # all done with our updates
    die $u->errstr unless $u->commit;

    # reset caches, have to do both of these, one for the usertags one for logtags
    LJ::Tags::reset_cache($u);
    LJ::Tags::reset_cache($u => \@jitemids);
    return 1;
}

# <LJFUNC>
# name: LJ::Tags::rename_usertag
# class: tags
# des: Deletes a tag for a user, and all mappings.
# args: uobj, type, tag, newname
# des-uobj: User object to delete tag on.
# des-type: Either 'id' or 'name', indicating the type of the third parameter.
# des-tag: If type is 'id', this is the tag id (kwid).  If type is 'name', this is the name of the
#          tag that we want to rename for the user.
# des-newname: The new name of this tag.
# returns: undef on error, 1 for success, 0 for tag not found
# </LJFUNC>
sub rename_usertag {
    return undef if $LJ::DISABLED{tags};

    # FIXME/TODO: make this function do merging?

    my $u = LJ::want_user(shift);
    return undef unless $u;

    my ($type, $val, $newname) = @_;
    return undef unless $type && $val && $newname;

    # validate new tag
    $newname = LJ::Tags::validate_tag($newname);
    return undef unless $newname;

    # get a list of keyword ids to operate on
    my $kwid;
    if ($type eq 'name') {
        $val = LJ::Tags::validate_tag($val);
        return undef unless $val;

        $kwid = LJ::get_keyword_id($u, $val, 0);
    } elsif ($type eq 'id') {
        $kwid = $val + 0;
    }
    return undef unless $kwid;

    # see if this is already a keyword
    my $newkwid = LJ::get_keyword_id($u, $newname);
    return undef unless $newkwid;

    # see if the tag we're renaming TO already exists as a keyword,
    # if so, don't allow the rename because we don't do merging (yet)
    my $tags = LJ::Tags::get_usertags($u);
    return undef if $tags->{$newkwid};

    # escape sub
    my $rollback = sub {
        die $u->errstr unless $u->rollback;
        return undef;
    };

    # start the big transaction
    $u->begin_work;

    # get items this keyword is on
    my $sth = $u->prepare('SELECT jitemid FROM logtags WHERE journalid = ? AND kwid = ? FOR UPDATE');
    return $rollback->() if $u->err || ! $sth;

    # now get the items
    $sth->execute($u->{userid}, $kwid);
    return $rollback->() if $sth->err;

    # now get list of jitemids for later cache clearing
    my @jitemids;
    push @jitemids, $_
        while $_ = $sth->fetchrow_array;

    # do database update to migrate from old to new
    foreach my $table (qw(usertags logtags logtagsrecent logkwsum)) {
        $u->do("UPDATE $table SET kwid = ? WHERE journalid = ? AND kwid = ?",
               undef, $newkwid, $u->{userid}, $kwid);
        return $rollback->() if $u->err;
    }

    # all done with our updates
    die $u->errstr unless $u->commit;

    # reset caches, have to do both of these, one for the usertags one for logtags
    LJ::Tags::reset_cache($u);
    LJ::Tags::reset_cache($u => \@jitemids);
    return 1;
}

# <LJFUNC>
# name: LJ::Tags::set_usertag_display
# class: tags
# des: Set the display bool for a tag.
# args: uobj, vartype, var, val
# des-uobj: User id or object of account to edit tag on
# des-vartype: Either 'id' or 'name'; indicating what the next parameter is
# des-var: If vartype is 'id', this is the tag (keyword) id; else, it's the tag/keyword itself
# des-val: 1/0; whether to turn the display flag on or off
# returns: 1 on success, undef on error
# </LJFUNC>
sub set_usertag_display {
    return undef if $LJ::DISABLED{tags};

    my $u = LJ::want_user(shift);
    my ($type, $var, $val) = @_;
    return undef unless $u;

    my $kwid;
    if ($type eq 'id') {
        $kwid = $var + 0;
    } elsif ($type eq 'name') {
        $var = LJ::Tags::validate_tag($var);
        return undef unless $var;

        # do not auto-vivify but get the keyword id
        $kwid = LJ::get_keyword_id($u, $var, 0);
    }
    return undef unless $kwid;

    $u->do("UPDATE usertags SET display = ? WHERE journalid = ? AND kwid = ?",
           undef, $val ? 1 : 0, $u->{userid}, $kwid);
    return undef if $u->err;

    return 1;
}

# <LJFUNC>
# name: LJ::Tags::deleted_friend_group
# class: tags
# des: Called internally when a friends group is deleted.
# args: uobj, bit
# des-uobj: User id or object of account deleting the group.
# des-bit: The id (1..30) of the friends group being deleted.
# returns: 1 of success undef on failure.
# </LJFUNC>
sub deleted_friend_group {
    my $u = LJ::want_user(shift);
    my $bit = shift() + 0;
    return undef unless $u && $bit >= 1 && $bit <= 30;

    # delete from logkwsum and then nuke the user's tags
    $u->do("DELETE FROM logkwsum WHERE journalid = ? AND security = ?",
           undef, $u->{userid}, 1 << $bit);
    return undef if $u->err;

    # that was simple
    LJ::Tags::reset_cache($u);
    return 1;
}

1;

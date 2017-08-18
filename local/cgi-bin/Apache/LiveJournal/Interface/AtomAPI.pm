# AtomAPI support for LJ

package Apache::LiveJournal::Interface::AtomAPI;

use strict;
use Apache::Constants qw(:common);
use Digest::SHA1;
use MIME::Base64;
use lib "$ENV{'LJHOME'}/cgi-bin";
require 'parsefeed.pl';
require 'fbupload.pl';

BEGIN {
    $LJ::OPTMOD_XMLATOM = eval q{
        use XML::Atom::Feed;
        use XML::Atom::Entry;
        use XML::Atom::Link;
        XML::Atom->VERSION < 0.09 ? 0 : 1;
    };
};

# check allowed Atom upload filetypes
sub check_mime
{
    my $mime = shift;
    return unless $mime;

    # TODO: add audio/etc support
    my %allowed_mime = (
        image => qr{^image\/(?:gif|jpe?g|png|tiff?)$}i,
        #audio => qr{^(?:application|audio)\/(?:(?:x-)?ogg|wav)$}i
    );

    foreach (keys %allowed_mime) {
        return $_ if $mime =~ $allowed_mime{$_}
    }
    return;
}

sub respond {
    my ($r, $status, $body, $type) = @_;

    my %msgs = (
        200 => 'OK',
        201 => 'Created',

        400 => 'Bad Request',
        401 => 'Authentication Failed',
        403 => 'Forbidden',
        404 => 'Not Found',
        500 => 'Server Error',
    ),

    my %mime = (
        html => 'text/html',
        atom => 'application/x.atom+xml',
        xml  => "text/xml; charset='utf-8'",
    );

    # if the passed in body was a reference, send it
    # without any modification.  otherwise, send some
    # prettier html to the client.
    my $out;
    if (ref $body) {
        $out = $$body;
    } else {
        $out = <<HTML;
<html><head><title>$status $msgs{$status}</title></head><body>
<h1>$msgs{$status}</h1><hr /><p>$body</p>
</body></html>
HTML
    }

    $type = $mime{$type} || 'text/html';
    $r->status_line("$status $msgs{$status}");
    $r->content_type($type);
    $r->send_http_header();
    $r->print($out);
    return OK;
};

sub handle_upload
{
    my ($r, $remote, $u, $opts, $entry) = @_;

    # entry could already be populated from a standalone
    # service.post posting.
    my $standalone = $entry ? 1 : 0;
    unless ($entry) {
        my $buff;
        $r->read($buff, $r->header_in("Content-length"));

        eval { $entry = XML::Atom::Entry->new( \$buff ); };
        return respond($r, 400, "Could not parse the entry due to invalid markup.<br /><pre>$@</pre>")
            if $@;
    }

    my $mime = $entry->content()->type();
    my $mime_area = check_mime( $mime );
    return respond($r, 400, "Unsupported MIME type: $mime") unless $mime_area;

    if ($mime_area eq 'image') {

        return respond($r, 400, "Unable to upload media. Your account doesn't have the required access.")
            unless LJ::get_cap($u, 'fb_can_upload') && $LJ::FB_SITEROOT;

        my $err;
        LJ::load_user_props(
            $u,
            qw/ emailpost_gallery emailpost_imgsecurity /
        );

        my $summary = LJ::trim( $entry->summary() );

        my $fb = LJ::FBUpload::do_upload(
            $u, \$err,
            {
                path    => $entry->title(),
                rawdata => \$entry->content()->body(),
                imgsec  => $u->{emailpost_imgsecurity},
                caption => $summary,
                galname => $u->{emailpost_gallery} || 'AtomUpload',
            }
        );

        return respond($r, 500, "There was an error uploading the media: $err")
            if $err || ! $fb;

        if (ref $fb && $fb->{Error}->{code}) {
            my $errstr = $fb->{Error}->{content};
            return respond($r, 500, "There was an error uploading the media: $errstr");
        }

        my $atom_reply = XML::Atom::Entry->new();
        $atom_reply->title( $fb->{Title} );

        if ($standalone) {
            $atom_reply->summary('Media post');
            my $id = "atom:$u->{user}:$fb->{PicID}";
            $fb->{Summary} = $summary;
            LJ::MemCache::set( $id, $fb, 1800 );
            $atom_reply->id( "urn:fb:$LJ::FB_DOMAIN:$id" );
        }

        my $link = XML::Atom::Link->new();
        $link->type('text/html');
        $link->rel('alternate');
        $link->href( $fb->{URL} );
        $atom_reply->add_link($link);

        $r->header_out("Location", $fb->{URL});
        return respond($r, 201, \$atom_reply->as_xml(), 'atom');
    }
}

sub handle_post {
    my ($r, $remote, $u, $opts) = @_;
    my ($buff, $entry);

    # read the content
    $r->read($buff, $r->header_in("Content-length"));

    # try parsing it
    eval { $entry = XML::Atom::Entry->new( \$buff ); };
    return respond($r, 400, "Could not parse the entry due to invalid markup.<br /><pre>$@</pre>")
        if $@;

    # on post, the entry must NOT include an id
    return respond($r, 400, "Must not include an <b>&lt;id&gt;</b> field in a new entry.")
        if $entry->id();

    # detect 'standalone' media posts
    return handle_upload( @_, $entry )
        if $entry->get("http://sixapart.com/atom/typepad#", 'standalone');

    # remove the SvUTF8 flag. See same code in synsuck.pl for
    # an explanation
    $entry->title(   pack( 'C*', unpack( 'C*', $entry->title() ) ) );
    $entry->link(    pack( 'C*', unpack( 'C*', $entry->link() ) ) );
    $entry->content( pack( 'C*', unpack( 'C*', $entry->content()->body() ) ) );

    # Retrieve fotobilder media links from clients that embed via
    # standalone tags or service.upload transfers.  Add to post entry
    # body.
    my $body  = $entry->content()->body();
    my @links = $entry->link();
    my (@images, $link_count);
    foreach my $link (@links) {
        # $link is now a valid XML::Atom::Link object
        my $rel  = $link->get('rel');
        my $type = $link->get('type');
        my $id   = $link->get('href');

        next unless $rel eq 'related' && check_mime($type) && $id;
        $id =~ s/^urn:fb:$LJ::FB_DOMAIN://;
        my $fb = LJ::MemCache::get( $id );
        next unless $fb;

        push @images, {
            url     => $fb->{URL},
            width   => $fb->{Width},
            height  => $fb->{Height},
            caption => $fb->{Summary},
            title   => $fb->{Title}
        };
    }

    $body .= LJ::FBUpload::make_html( $u, \@images );

    # build a post event request.
    my $req = {
        'usejournal'  => ( $remote->{'userid'} != $u->{'userid'} ) ? $u->{'user'} : undef,
        'ver'         => 1,
        'username'    => $u->{'user'},
        'lineendings' => 'unix',
        'subject'     => $entry->title(),
        'event'       => $body,
        'props'       => {},
        'security'    => 'public',
        'tz'          => 'guess',
    };

    my $err;
    my $res = LJ::Protocol::do_request("postevent", 
                                       $req, \$err, { 'noauth' => 1 });

    if ($err) {
        my $errstr = LJ::Protocol::error_message($err);
        return respond($r, 500, "Unable to post new entry. Protocol error: <b>$errstr</b>.");
    }

    my $atom_reply = XML::Atom::Entry->new();
    $atom_reply->title( $entry->title() );
    $atom_reply->summary( substr( $entry->content->body(), 0, 100 ) );

    my $link;
    my $edit_url = "$LJ::SITEROOT/interface/atom/edit/$res->{'itemid'}";

    $link = XML::Atom::Link->new();
    $link->type('application/x.atom+xml');
    $link->rel('service.edit');
    $link->href( $edit_url );
    $link->title( $entry->title() );
    $atom_reply->add_link($link);

    $link = XML::Atom::Link->new();
    $link->type('text/html');
    $link->rel('alternate');
    $link->href( $res->{url} );
    $link->title( $entry->title() );
    $atom_reply->add_link($link);

    $r->header_out("Location", $edit_url);
    return respond($r, 201, \$atom_reply->as_xml(), 'atom');
}

sub handle_edit {
    my ($r, $remote, $u, $opts) = @_;

    my $method = $opts->{'method'};

    # first, try to load the item and fail if it's not there
    my $jitemid = $opts->{'param'};
    my $req = {
        'usejournal' => ($remote->{'userid'} != $u->{'userid'}) ?
            $u->{'user'} : undef,
         'ver' => 1,
         'username' => $u->{'user'},
         'selecttype' => 'one',
         'itemid' => $jitemid,
    };

    my $err;
    my $olditem = LJ::Protocol::do_request("getevents", 
                                           $req, \$err, { 'noauth' => 1 });
    
    if ($err) {
        my $errstr = LJ::Protocol::error_message($err);
        return respond($r, 404, "Unable to retrieve the item requested for editing. Protocol error: <b>$errstr</b>.");
    }
    $olditem = $olditem->{'events'}->[0];

    if ($method eq "GET") {
        # return an AtomEntry for this item
        # use the interface between make_feed and create_view_atom in
        # ljfeed.pl

        # get the log2 row (need logtime for createtime)
        my $row = LJ::get_log2_row($u, $jitemid) ||
            return respond($r, 404, "Could not load the original entry.");

        # we need to put into $item: itemid, ditemid, subject, event, 
        # createtime, eventtime, modtime
        
        my $ctime = LJ::mysqldate_to_time($row->{'logtime'}, 1);

        my $item = {
            'itemid'     => $olditem->{'itemid'},
            'ditemid'    => $olditem->{'itemid'}*256 + $olditem->{'anum'},
            'eventtime'  => LJ::alldatepart_s2($row->{'eventtime'}),
            'createtime' => $ctime,
            'modtime'    => $olditem->{'props'}->{'revtime'} || $ctime,
            'subject'    => $olditem->{'subject'},
            'event'      => $olditem->{'event'},
        };

        my $ret = LJ::Feed::create_view_atom(
            { 'u' => $u },
            $u,
            {
                'saycharset' => "utf-8",
                'noheader'   => 1,
                'apilinks'   => 1,
            },
            [$item]
        );

        return respond($r, 200, \$ret, 'xml');
    }

    if ($method eq "PUT") {
        # read the content
        my $buff;
        $r->read($buff, $r->header_in("Content-length"));

        # try parsing it
        my $entry;
        eval { $entry = XML::Atom::Entry->new( \$buff ); };
        return respond($r, 400, "Could not parse the entry due to invalid markup.<br /><pre>$@</pre>")
            if $@;

        # remove the SvUTF8 flag. See same code in synsuck.pl for
        # an explanation
        $entry->title(   pack( 'C*', unpack( 'C*', $entry->title() ) ) );
        $entry->link(    pack( 'C*', unpack( 'C*', $entry->link() ) ) );
        $entry->content( pack( 'C*', unpack( 'C*', $entry->content()->body() ) ) );

        # the AtomEntry must include <id> which must match the one we sent
        # on GET
        unless ($entry->id() =~ m#atom1:$u->{'user'}:(\d+)$# &&
                $1 == $olditem->{'itemid'}*256 + $olditem->{'anum'}) {
            return respond($r, 400, "Incorrect <b>&lt;id&gt;</b> field in this request.");
        }

        # build an edit event request. Preserve fields that aren't being
        # changed by this item (perhaps the AtomEntry isn't carrying the
        # complete information).
        
        $req = {
            'usejournal'  => ( $remote->{'userid'} != $u->{'userid'} ) ? $u->{'user'} : undef,
            'ver'         => 1,
            'username'    => $u->{'user'},
            'itemid'      => $jitemid,
            'lineendings' => 'unix',
            'subject'     => $entry->title() || $olditem->{'subject'},
            'event'       => $entry->content()->body() || $olditem->{'event'},
            'props'       => $olditem->{'props'},
            'security'    => $olditem->{'security'},
            'allowmask'   => $olditem->{'allowmask'},
        };

        $err = undef;
        my $res = LJ::Protocol::do_request("editevent", 
                                           $req, \$err, { 'noauth' => 1 });
    
        if ($err) {
            my $errstr = LJ::Protocol::error_message($err);
            return respond($r, 500, "Unable to update entry. Protocol error: <b>$errstr</b>.");
        }

        return respond($r, 200, "The entry was successfully updated.");
    }

    if ($method eq "DELETE") {
        
        # build an edit event request to delete the entry.
        
        $req = {
            'usejournal' => ($remote->{'userid'} != $u->{'userid'}) ?
                $u->{'user'}:undef,
            'ver' => 1,
            'username' => $u->{'user'},
            'itemid' => $jitemid,
            'lineendings' => 'unix',
            'event' => '',
        };

        $err = undef;
        my $res = LJ::Protocol::do_request("editevent", 
                                           $req, \$err, { 'noauth' => 1 });
    
        if ($err) {
            my $errstr = LJ::Protocol::error_message($err);
            return respond($r, 500, "Unable to delete entry. Protocol error: <b>$errstr</b>.");
        }

        return respond($r, 200, "Entry successfully deleted.");
    }
    
}

# fetch lj tags, display as categories
sub handle_categories
{
    my ($r, $remote, $u, $opts) = @_;
    my $ret = '<?xml version="1.0"?>';
    $ret .= '<categories xmlns="http://sixapart.com/atom/category#">';

    my $tags = LJ::Tags::get_usertags($u, { remote => $remote }) || {};
    foreach (sort { $a->{name} cmp $b->{name} } values %$tags) {
        $ret .= "<subject xmlns=\"http://purl.org/dc/elements/1.1/\">$_->{name}</subject>";
    }
    $ret .= '</categories>';

    return respond($r, 200, \$ret, 'xml');
}

sub handle_feed {
    my ($r, $remote, $u, $opts) = @_;

    # simulate a call to the S1 data view creator, with appropriate
    # options
    
    my %op = ('pathextra' => "/atom",
              'saycharset'=> "utf-8",
              'apilinks'  => 1,
              );
    my $ret = LJ::Feed::make_feed($r, $u, $remote, \%op);

    unless (defined $ret) {
        if ($op{'redir'}) {
            # this happens if the account was renamed or a syn account.
            # the redir URL is wrong because ljfeed.pl is too 
            # dataview-specific. Since this is an admin interface, we can
            # just fail.
            return respond ($r, 404, "The account <b>$u->{'user'} </b> is of a wrong type and does not allow AtomAPI administration.");
        }
        if ($op{'handler_return'}) {
            # this could be a conditional GET shortcut, honor it
            $r->status($op{'handler_return'});
            return OK;
        }
        # should never get here
        return respond ($r, 404, "Unknown error.");
    }

    # everything's fine, return the XML body with the correct content type
    return respond($r, 200, \$ret, 'xml');

}

# this routine accepts the apache request handle, performs
# authentication, calls the appropriate method handler, and
# prints the response.
sub handle {
    my $r = shift;

    return respond($r, 404, "This server does not support the Atom API.")
        unless $LJ::OPTMOD_XMLATOM;

    # break the uri down: /interface/atom/<verb>[/<number>]
    my ( $action, $param, $oldparam ) = ( $1, $2, $3 )
      if $r->uri =~ m#^/interface/atom(?:api)?/?(\w+)?(?:/(\w+))?(?:/(\d+))?$#;

    my $valid_actions = qr{feed|edit|post|upload|categories};

    # old uri was was: /interface/atomapi/<username>/<verb>[/<number>]
    # support both by shifting params around if we see something extra.
    if ($action !~ /$valid_actions/ && $r->uri =~ /atomapi/ ) {
        $action = $param;
        $param  = $oldparam;
    }

    # let's authenticate.
    # 
    # if wsse information is supplied, use it. 
    # if not, fall back to digest.
    my $wsse = $r->header_in('X-WSSE');
    my $nonce_dup;
    my $u = $wsse ? auth_wsse($wsse, \$nonce_dup) : LJ::auth_digest($r);
    return respond( $r, 401, "Authentication failed for this AtomAPI request.")
        unless $u;

    return respond( $r, 401, "Authentication failed for this AtomAPI request.")
        if $nonce_dup && $action && $action ne 'post';

    # service autodiscovery
    # TODO: Add communities?
    my $method = $r->method;
    if ( $method eq 'GET' && ! $action ) {
        LJ::load_user_props( $u, 'journaltitle' );
        my $title = $u->{journaltitle} || 'Untitled Journal';
        my $feed = XML::Atom::Feed->new();
        foreach (qw/ post feed upload categories /) {
            my $link = XML::Atom::Link->new();
            $link->title($title);
            $link->type('application/x.atom+xml');
            $link->rel("service.$_");
            $link->href("$LJ::SITEROOT/interface/atom/$_");
            $feed->add_link($link);
        }
        my $link = XML::Atom::Link->new();
        $link->title($title);
        $link->type('text/html');
        $link->rel('alternate');
        $link->href( LJ::journal_base($u) );
        $feed->add_link($link);

        return respond($r, 200, \$feed->as_xml(), 'atom');
    }

    $action =~ /$valid_actions/
      or return respond($r, 400, "Unknown URI scheme: /interface/atom/<b>$action</b>");

    unless (($action eq 'feed' and $method eq 'GET')  or
            ($action eq 'categories' and $method eq 'GET') or
            ($action eq 'post' and $method eq 'POST') or
            ($action eq 'upload' and $method eq 'POST') or
            ($action eq 'edit' and 
             {'GET'=>1,'PUT'=>1,'DELETE'=>1}->{$method})) {
        return respond($r, 400, "URI scheme /interface/atom/<b>$action</b> is incompatible with request method <b>$method</b>.");
    }

    if (($action ne 'edit' && $param) or
        ($action eq 'edit' && $param !~ m#^\d+$#)) {
        return respond($r, 400, "Either the URI lacks a required parameter, or its format is improper.");
    }

    # we've authenticated successfully and remote is set. But can remote
    # manage the requested account?
    my $remote = LJ::get_remote();
    unless (LJ::can_manage($remote, $u)) {
        return respond($r, 403, "User <b>$remote->{'user'}</b> has no administrative access to account <b>$u->{user}</b>.");
    }

    # handle the requested action
    my $opts = {
        'action' => $action,
        'method' => $method,
        'param'  => $param
    };

    {
        'feed'       => \&handle_feed,
        'post'       => \&handle_post,
        'edit'       => \&handle_edit,
        'upload'     => \&handle_upload,
        'categories' => \&handle_categories,
    }->{$action}->( $r, $remote, $u, $opts );

    return OK;
}

# Authenticate via the WSSE header.
# Returns valid $u on success, undef on failure.
sub auth_wsse
{
    my ($wsse, $nonce_dup) = @_;
    $wsse =~ s/UsernameToken // or return undef;

    # parse credentials into a hash.
    my %creds;
    foreach (split /, /, $wsse) {
        my ($k, $v) = split '=', $_, 2;
        $v =~ s/^['"]//;
        $v =~ s/['"]$//;
        $v =~ s/=$// if $k =~ /passworddigest/i; # strip base64 newline char
        $creds{ lc($k) } = $v;
    }

    # invalid create time?  invalid wsse.
    my $ctime = LJ::ParseFeed::w3cdtf_to_time( $creds{created} ) or return undef;

    # prevent replay attacks.
    $ctime = LJ::mysqldate_to_time( $ctime, 'gmt' );
    return undef if abs(time() - $ctime) > 42300;

    my $u = LJ::load_user( LJ::canonical_username( $creds{'username'} ) )
        or return undef;

    if (@LJ::MEMCACHE_SERVERS && ref $nonce_dup) {
        $$nonce_dup = 1
          unless LJ::MemCache::add( "wsse_auth:$creds{username}:$creds{nonce}", 1, 180 )
    }

    # validate hash
    my $hash =
      Digest::SHA1::sha1_base64(
        $creds{nonce} . $creds{created} . $u->{password} );

    # Nokia's WSSE implementation is incorrect as of 1.5, and they
    # base64 encode their nonce *value*.  If the initial comparison
    # fails, we need to try this as well before saying it's invalid.
    if ($hash ne $creds{passworddigest}) {

        $hash =
          Digest::SHA1::sha1_base64(
                MIME::Base64::decode_base64( $creds{nonce} ) .
                $creds{created} .
                $u->{password} );

        return undef if $hash ne $creds{passworddigest};
    }
    
    # If we're here, we're valid.
    LJ::set_remote($u);
    return $u;
}

1;

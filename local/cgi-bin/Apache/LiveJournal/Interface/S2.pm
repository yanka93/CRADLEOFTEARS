#!/usr/bin/perl
#

package Apache::LiveJournal::Interface::S2;

use strict;
use MIME::Base64 ();
use Apache::Constants;

sub handler {
    my $r = shift;

    my $meth = $r->method();
    my %GET = $r->args();
    my $uri = $r->uri();
    my $id;
    if ($uri =~ m!^/interface/s2/(\d+)$!) {
        $id = $1 + 0;
    } else {
        return NOT_FOUND;
    }

    my $lay = LJ::S2::load_layer($id);
    return error($r, 404, 'Layer not found', "There is no layer with id $id at this site")
        unless $lay;

    LJ::auth_digest($r);
    my $u = LJ::get_remote();
    unless ($u) {
        # Tell the client how it can authenticate
        # use digest authorization.
        
        $r->send_http_header("text/plain; charset=utf-8");
        $r->print("Unauthorized\nYou must send your $LJ::SITENAME username and password or a valid session cookie\n");

        return OK;
    }

    my $dbr = LJ::get_db_reader();

    my $lu = LJ::load_userid($lay->{'userid'});

    return error($r, 500, "Error", "Unable to find layer owner.")
        unless $lu;

    if ($meth eq 'GET') {

        return error($r, 403, "Forbidden", "You are not authorized to retrieve this layer")
            unless $lu->{'user'} eq 'system' || LJ::can_manage($u, $lu);

        my $layerinfo = {};
        LJ::S2::load_layer_info($layerinfo, [ $id ]);
        my $srcview = exists $layerinfo->{$id}->{'source_viewable'} ?
            $layerinfo->{$id}->{'source_viewable'} : 1;

        # Disallow retrieval of protected system layers
        return error($r, 403, "Forbidden", "The requested layer is restricted")
            if $lu->{'user'} eq 'system' && ! $srcview;

        my $s2code = $dbr->selectrow_array("SELECT s2code FROM s2source WHERE s2lid=?", undef, $id);

        $r->send_http_header("application/x-danga-s2-layer");
        $r->print($s2code);

    }
    elsif ($meth eq 'PUT') {

        return error($r, 403, "Forbidden", "You are not authorized to edit this layer")
            unless LJ::can_manage($u, $lu);

        return error($r, 403, "Forbidden", "Your account type is not allowed to edit layers")
            unless LJ::get_cap($u, "s2styles");

        # Read in the entity body to get the source
        my $len = $r->header_in("Content-length")+0;

        return error($r, 400, "Bad Request", "Supply S2 layer code in the request entity body and set Content-length")
            unless $len;

        return error($r, 415, "Bad Media Type", "Request body must be of type application/x-danga-s2-layer")
            unless lc($r->header_in("Content-type")) eq 'application/x-danga-s2-layer';

        my $s2code;
        $r->read($s2code, $len);

        my $error = "";
        LJ::S2::layer_compile($lay, \$error, { 's2ref' => \$s2code });

        if ($error) {
            error($r, 500, "Layer Compile Error", "An error was encountered while compiling the layer.");

            ## Strip any absolute paths
            $error =~ s/LJ::.+//s;
            $error =~ s!, .+?(src/s2|cgi-bin)/!, !g;

            print $error;
            return OK;
        }
        else {
            $r->status_line("201 Compiled and Saved");
            $r->header_out("Location" => "$LJ::SITEROOT/interface/s2/$id");
            $r->send_http_header("text/plain; charset=utf-8");
            $r->print("Compiled and Saved\nThe layer was uploaded successfully.\n");
        }
    }
    else {
        #  Return 'method not allowed' so that we can add methods in future
        # and clients will get a sensible error from old servers.
        return error($r, 405, 'Method Not Allowed', 'Only GET and PUT are supported for this resource');
    }
}

sub error {
    my ($r, $code, $string, $long) = @_;

    $r->status_line("$code $string");
    $r->send_http_header("text/plain; charset=utf-8");
    $r->print("$string\n$long\n");

    # Tell Apache OK so it won't try to handle the error
    return OK;
}

1;

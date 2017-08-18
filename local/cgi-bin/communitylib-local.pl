# <LJFUNC>
# name: LJ::comm_member_request
# des: Registers an authaction to add a user to a
#      community and sends an approval email
#
#   taken from lilib.pl, version 1.681:
#     http://cvs.livejournal.org/browse.cgi/livejournal/cgi-bin/ljlib.pl?rev=1.681&content-type=text/x-cvsweb-markup
#
# returns: Hashref; output of LJ::register_authaction()
#          includes datecreate of old row if no new row was created
# args: comm, u, attr?
# des-comm: Community user object
# des-u: User object to add to community
# des-attr: array of attributes new user will have
# </LJFUNC>
sub comm_member_request {
    my ($comm, $u, $attr) = @_;
    return undef unless ref $comm && ref $u;

    my $arg = join("&", "targetid=$u->{'userid'}", map { "$_=1" } sort @$attr);

    my $dbh = LJ::get_db_writer();

    # check for duplicates within the same hour (to prevent spamming)
    my $oldaa = $dbh->selectrow_hashref("SELECT aaid, authcode, datecreate FROM authactions " .
                                        "WHERE userid=? AND arg1=? " .
                                        "AND action='comm_invite' AND used='N' " .
                                        "AND NOW() < datecreate + INTERVAL 1 HOUR " .
                                        "ORDER BY 1 DESC LIMIT 1",
                                        undef, $comm->{'userid'}, $arg);
    return $oldaa if $oldaa;

    # insert authactions row
    my $aa = LJ::register_authaction($comm->{'userid'}, 'comm_invite', $arg);
    return undef unless $aa;

    # if there are older duplicates, invalidate any existing unused authactions of this type
    $dbh->do("UPDATE authactions SET used='Y' WHERE userid=? AND aaid<>? AND arg1=? " .
             "AND action='comm_invite' AND used='N'",
             undef, $comm->{'userid'}, $aa->{'aaid'}, $arg);

    # email recipient user for confirmation
    $attr ||= [];
    my %attr_map = ('member'     => "участник",
                    'admin'      => "смотритель",
                    'post'       => "может писать",
                    'moderate'   => "модератор",
                    'preapprove' => "немодерируемое",
                    );

    my $cuser = $comm->{'user'};
    my $body = "Уважаемый $u->{'user'},\n\n";
    $body .= "смотритель сообщества $cuser ($LJ::SITEROOT/community/$cuser/)\n" .
        "приглашает вас стать членом сообщества со следующими привилегиями:\n".
        join(", ", map { $attr_map{$_} } @$attr) . ".\n\n" .
        "Если вы не хотите участвовать в $cuser, то просто проигнорируйте это письмо.\n" .
        "Однако, если вы хотите присоединиться к сообществу, то, пожалуйста,\n" .
        "перейдите по ссылке (ниже в письме), чтобы подтвердить свое согласие.\n\n" .
        "     $LJ::SITEROOT/approve/$aa->{'aaid'}.$aa->{'authcode'}\n\n" .
        "\nКоманда $LJ::SITENAME\n";

    LJ::send_mail({
        'to' => $u->{'email'},
        'from' => $LJ::COMMUNITY_EMAIL,
        'fromname' => $LJ::SITENAME,
        'charset' => 'koi8-r',
        'subject' => "Членство в сообществе: $cuser",
        'body' => $body
        });

    return $aa;
}


1;

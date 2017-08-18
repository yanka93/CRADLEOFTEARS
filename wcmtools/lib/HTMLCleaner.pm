#!/usr/bin/perl
#

package HTMLCleaner;

use strict;
use base 'HTML::Parser';

sub new {
    my ($class, %opts) = @_;
    
    my $p = new HTML::Parser('api_version' => 3);
    $p->handler('start' =>  \&start, 'self, tagname, attr, attrseq, text' );
    $p->handler('end' =>  \&end, 'self, tagname' );
    $p->handler('text' =>  \&text, 'self, text' );
    $p->handler('declaration' =>  \&decl, 'self, tokens' );

    $p->{'output'} = $opts{'output'} || sub {};
    bless $p, $class;
}

my %bad_attr = (map { $_ => 1 } 
                qw(onabort onactivate onafterprint onafterupdate
                   onbeforeactivate onbeforecopy onbeforecut
                   onbeforedeactivate onbeforeeditfocus
                   onbeforepaste onbeforeprint onbeforeunload
                   onbeforeupdate onblur onbounce oncellchange
                   onchange onclick oncontextmenu oncontrolselect
                   oncopy oncut ondataavailable ondatasetchanged
                   ondatasetcomplete ondblclick ondeactivate
                   ondrag ondragend ondragenter ondragleave
                   ondragover ondragstart ondrop onerror
                   onerrorupdate onfilterchange onfinish onfocus
                   onfocusin onfocusout onhelp onkeydown
                   onkeypress onkeyup onlayoutcomplete onload
                   onlosecapture onmousedown onmouseenter
                   onmouseleave onmousemove onmouseout
                   onmouseover onmouseup onmousewheel onmove
                   onmoveend onmovestart onpaste onpropertychange
                   onreadystatechange onreset onresize
                   onresizeend onresizestart onrowenter onrowexit
                   onrowsdelete onrowsinserted onscroll onselect
                   onselectionchange onselectstart onstart onstop
                   onsubmit onunload datasrc datafld));

my %eat_tag = (map { $_ => 1 } 
               qw(script iframe object applet embed));

my @eating;  # push tagname whenever we start eating a tag

sub start {
    my ($self, $tagname, $attr, $seq, $text) = @_;
    my $slashclose = 0;  # xml-style
    if ($tagname =~ s!/(.*)!!) {
        if (length($1)) { push @eating, "$tagname/$1"; } # basically halt parsing 
        else { $slashclose = 1; }
    }
    push @eating, $tagname if
        $eat_tag{$tagname};
    return if @eating;
    my $ret = "<$tagname";
    foreach (@$seq) {
        if ($_ eq "/") { $slashclose = 1; next; }
        next if $bad_attr{lc($_)};
        next if /(?:^=)|[\x0b\x0d]/;

        # IE is brain-dead and lets javascript:, vbscript:, and about: have spaces mixed in 
        if ($attr->{$_} =~ /((?:(?:v\s*b)|(?:j\s*a\s*v\s*a))\s*s\s*c\s*r\s*i\s*p\s*t|
                             a\s*b\s*o\s*u\s*t)\s*:/ix) {
            delete $attr->{$_};
        }
        $ret .= " $_=\"" . ehtml($attr->{$_}) . "\"";
    }
    $ret .= " /" if $slashclose;
    $ret .= ">";
    $self->{'output'}->($ret);
}

sub end {
    my ($self, $tagname) = @_;
    if (@eating) {
        pop @eating if $eating[-1] eq $tagname;
        return;
    }
    $self->{'output'}->("</$tagname>");
}

sub text {
    my ($self, $text) = @_;
    return if @eating;
    # the parser gives us back text whenever it's confused
    # on really broken input.  sadly, IE parses really broken
    # input, so let's escape anything going out this way.
    $self->{'output'}->(eangles($text));
}

sub decl {
    my ($self, $tokens) = @_;
    $self->{'output'}->("<!" . join(" ", map { eangles($_) } @$tokens) . ">");
}

sub eangles {
    my $a = shift;
    $a =~ s/</&lt;/g;
    $a =~ s/>/&gt;/g;
    return $a;
}

sub ehtml {
    my $a = shift;
    $a =~ s/\&/&amp;/g;
    $a =~ s/\"/&quot;/g;
    $a =~ s/\'/&\#39;/g;
    $a =~ s/</&lt;/g;
    $a =~ s/>/&gt;/g;
    return $a;
}

1;

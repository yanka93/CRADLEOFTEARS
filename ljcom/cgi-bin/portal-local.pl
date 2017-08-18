#!/usr/bin/perl
#

use strict;

package LJ::Portal;
use vars qw(%box);

$box{'newtolj'} =
{
    'name' => '<?_ml portal.newtolj.name _ml?>',
    'small' => 1,
    'large' => 0,
    'handler' => sub {
        my ($remote, $opts, $box) = @_;
        my $b = $opts->{'body'};

        box_start($b, $box, { 'title' => "About $LJ::SITENAME",
                              'align' => "left",
                              'url' => '/site/about.bml', });

        $$b .= "New to $LJ::SITENAME?";
        my @links = ("What is $LJ::SITENAME?", "/site/about.bml",
                     "Create an account!", "/create.bml");
        while (@links) {
            my $link = shift @links;
            my $url = shift @links;
            $$b .= "<li><a href=\"$url\"><b>$link</b></a>\n";
        }

        box_end($b, $box);
        $$b .= "</form>\n";
    },
};

############################################################################

$box{'goat'} =
{
    'name' => '<?_ml portal.goat.name _ml?>',
    'small' => 1,
    'large' => 0,
    'opts' => [ { 'key' => 'misbehaved',
                  'name' => '<?_ml portal.misbehaved.name _ml?>',
                  'des' => '<?_ml portal.misbehaved.des _ml?>',
                  'type' => 'check',
                  'value' => 1,
                  'default' => 0, },
                { 'key' => 'goattext',
                  'name' => '<?_ml portal.goattext.name _ml?>',
                  'des' => '<?_ml portal.goattext.des _ml?>',
                  'type' => 'text',
                  'default' => "Baaaaah",
                  'size' => 40,
                  'maxlength' => 40, },
                ],
    'handler' => sub {
        my ($remote, $opts, $box) = @_;
        my $b = $opts->{'body'};
        my $bo = $opts->{'bodyopts'};
        my $h = $opts->{'head'};
        my $pic;

        if ($opts->{'form'}->{'frank'} eq "urinate" || $box->{'args'}->{'misbehaved'}) {
            $pic = "pee";
        } else {
            $pic = "hover";
        }

        box_start($b, $box, { 'title' => "Frank",
                              'align' => "center",
                              'url' => "/site/goat.bml", });

        my $imgname = "frankani" . $box->{'uniq'};
        my $goattext = $box->{'args'}->{'goattext'} || "Baaaah";

        $$b .= <<"GOAT_STUFF";
<a onmouseout="MM_swapImgRestore()" onmouseover="MM_swapImage('$imgname','','$LJ::IMGPREFIX/goat-$pic.gif',1)" href="/site/goat.bml"><img name="$imgname" src="$LJ::IMGPREFIX/goat-normal.gif" width='110' height='101' hspace='2' vspace='2' border='0' alt="Frank, the LiveJournal mascot goat."></a><br />
<b><i>"$goattext"</i> says Frank.
GOAT_STUFF
    
    box_end($b, $box);

        $opts->{'onload'}->{"MM_preloadImages('$LJ::IMGPREFIX/goat-$pic.gif');"} = 1;

        unless ($opts->{'did'}->{'image_javascript'}) 
        {
            $opts->{'did'}->{'image_javascript'} = 1;

        $$h .= <<'JAVASCRIPT';
<script language="JavaScript">
<!--
function MM_swapImgRestore() { //v3.0
  var i,x,a=document.MM_sr; for(i=0;a&&i<a.length&&(x=a[i])&&x.oSrc;i++) x.src=x.oSrc;
}

function MM_preloadImages() { //v3.0
  var d=document; if(d.images){ if(!d.MM_p) d.MM_p=new Array();
    var i,j=d.MM_p.length,a=MM_preloadImages.arguments; for(i=0; i<a.length; i++)
    if (a[i].indexOf("#")!=0){ d.MM_p[j]=new Image; d.MM_p[j++].src=a[i];}}
}

function MM_findObj(n, d) { //v3.0
  var p,i,x;  if(!d) d=document; if((p=n.indexOf("?"))>0&&parent.frames.length) {
    d=parent.frames[n.substring(p+1)].document; n=n.substring(0,p);}
  if(!(x=d[n])&&d.all) x=d.all[n]; for (i=0;!x&&i<d.forms.length;i++) x=d.forms[i][n];
  for(i=0;!x&&d.layers&&i<d.layers.length;i++) x=MM_findObj(n,d.layers[i].document); return x;
}

function MM_swapImage() { //v3.0
  var i,j=0,x,a=MM_swapImage.arguments; document.MM_sr=new Array; for(i=0;i<(a.length-2);i+=3)
   if ((x=MM_findObj(a[i]))!=null){document.MM_sr[j++]=x; if(!x.oSrc) x.oSrc=x.src; x.src=a[i+2];}
}
//-->
</script>
JAVASCRIPT

        }  # end unless


    },  # end handler
    
};

############################################################################

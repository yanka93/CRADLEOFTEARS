use strict;
use GD::Simple;

package LJR::GD;

sub generate_number {
  my ($num, $fontname, $fontcolor, $stuff) = @_;
  
  $num =~ s/^(\ +)//g;
  $num =~ s/(\ +)$//g;
  
  my $font;
  if ($fontname eq "gdTinyFont") {
    $font = GD::Font->Tiny();
  }
  elsif ($fontname eq "gdSmallFont") {
    $font = GD::Font->Small();
  }
  elsif ($fontname eq "gdLargeFont") {
    $font = GD::Font->Large();
  }
  elsif ($fontname eq "gdMediumBoldFont") {
    $font = GD::Font->MediumBold();
  }
  elsif ($fontname eq "gdGiantFont") {
    $font = GD::Font->Giant();
  }
  else {
    $font = GD::Font->Small();
  }

  my $cell_width = $font->width;
  my $cell_height = $font->height;
  my $cols = length($stuff) > length($num) ? length($stuff) : length($num);
  my $width = int($cols * $cell_width + $cell_width / 3);
  my $height = $cell_height + 1;
  my $img = GD::Simple->new($width,$height);
  $img->font($font);
  $img->moveTo(1,$font->height + 1);
  $img->transparent("white");
  $img->bgcolor("white");
  $img->fgcolor($fontcolor);
  
  my $str = (length($num) < length($stuff) ?
    substr($stuff, 0, length($stuff) - length($num)) :
    "") . $num;
  $img->string($str);
  return $img;
}

return 1;

package Plugins::CastNowPlaying::CD;

# Audio CD playback (AudioCD plugin, audiocd://<disc id>/<track> urls): data for the CD-player
# style screen. No LMS dependencies (tested in tests/).

use strict;
use warnings;

# parse_url($url) -> ($discid, $track) or ()
sub parse_url {
	my $url = shift // '';
	return $url =~ m{^audiocd://([^/]+)/0*([1-9]\d{0,2})\z} ? ($1, $2 + 0) : ();
}

# info($url, $audiocd_status) -> { track, tracks => [ { n, length } ] } or undef when it is not a CD.
# $audiocd_status (result of "audiocd status") may be undef or about another disc: then no track list.
sub info {
	my ($url, $st) = @_;
	my ($discid, $n) = parse_url($url);
	return undef unless $n;
	my @tracks;
	if (ref $st eq 'HASH' && ($st->{discid} // '') eq $discid && ref $st->{metadata} eq 'HASH') {
		my $list = $st->{metadata}{tracks};
		@tracks = map { { n => $_->{n} + 0, length => int($_->{length} || 0) } }
			grep { ref $_ eq 'HASH' && ($_->{n} // '') =~ /^\d+\z/ } @{ ref $list eq 'ARRAY' ? $list : [] };
	}
	return { track => $n, tracks => \@tracks };
}

1;

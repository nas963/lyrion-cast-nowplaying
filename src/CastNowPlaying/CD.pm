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

# wave($audiocd_wave_result) -> [ rms 0..1000, ... ] (talasni oblik pesme) ili undef dok ga nema
sub wave {
	my $r = shift;
	return undef unless ref $r eq 'HASH' && ref $r->{rms} eq 'ARRAY' && @{ $r->{rms} } && @{ $r->{rms} } <= 2000;
	return [ map { my $v = int($_ // 0); $v < 0 ? 0 : $v > 1000 ? 1000 : $v } @{ $r->{rms} } ];
}

# dr($rezultat waveform get) -> "DR12" (dinamicki opseg pesme, Waveform 0.6+) ili undef
sub dr {
	my $r = shift;
	return undef unless ref $r eq 'HASH' && defined $r->{dr} && $r->{dr} =~ /\A\d+(?:\.\d+)?\z/ && $r->{dr} < 100;
	return 'DR' . int($r->{dr} + 0.5);
}

1;

#!/usr/bin/perl
use strict;
use warnings;
use Test::More;

use Plugins::CastNowPlaying::CD;

my $id = 'Y5YcSD94m8NHH5Zrj6gYEHIq5k8-';
my $u = "audiocd://$id/2";
is_deeply([ Plugins::CastNowPlaying::CD::parse_url($u) ], [ $id, 2 ], 'disc id and track');
for my $bad (undef, '', 'file:///a.flac', 'audiocd://x', 'audiocd://x/0', 'audiocd://x/y', 'qobuz://1.flac') {
	is(scalar(() = Plugins::CastNowPlaying::CD::parse_url($bad)), 0, 'not a CD: ' . ($bad // 'undef'));
	is(scalar(Plugins::CastNowPlaying::CD::info($bad, {})), undef, 'no info');
}

my $st = { discid => $id, metadata => { tracks => [ { n => 1, length => 456, title => 'x' }, { n => '2', length => '394.4' }, { n => undef } ] } };
is_deeply(Plugins::CastNowPlaying::CD::info($u, $st), { track => 2, tracks => [ { n => 1, length => 456 }, { n => 2, length => 394 } ] }, 'track list');
is_deeply(Plugins::CastNowPlaying::CD::info($u, { %$st, discid => 'other' }), { track => 2, tracks => [] }, 'another disc in the drive');
is_deeply(Plugins::CastNowPlaying::CD::info($u, undef), { track => 2, tracks => [] }, 'no AudioCD status');
is_deeply(Plugins::CastNowPlaying::CD::info($u, { %$st, metadata => undef }), { track => 2, tracks => [] }, 'no metadata yet');

done_testing;

#!/usr/bin/perl
# Device::_on_status decisions (launch / screen busy / yield), with LMS modules stubbed out.
use strict;
use warnings;
use Test::More;

BEGIN {
	package main;
	no strict 'refs';
	*{'main::INFOLOG'} = sub () { 0 } unless defined &main::INFOLOG;
	for my $m (qw(Slim::Networking::Select Slim::Utils::Log Slim::Utils::Timers)) {
		(my $f = "$m.pm") =~ s{::}{/}g;
		$INC{$f} = __FILE__;
		*{"${m}::import"} = sub {};
	}
	*{'Plugins::CastNowPlaying::Device::logger'} = sub { bless {}, 'StubLog' };
	*{'StubLog::is_info'} = sub { 0 };
	*{'StubLog::info'} = *{'StubLog::warn'} = sub {};
}

use Plugins::CastNowPlaying::Device;

my @sent;
{
	no warnings 'redefine';
	*Plugins::CastNowPlaying::Device::_send = sub { my ($self, $dst, $ns, $p) = @_; push @sent, $p->{type} };
	*Plugins::CastNowPlaying::Device::_send_np = sub { push @sent, 'NP' };
}

sub dev { my $d = Plugins::CastNowPlaying::Device->new(id => 'x', name => 'Box'); $d->{want} = 1; @sent = (); $d }
sub st { my ($apps, %o) = @_; { isActiveInput => JSON::PP::true(), isStandBy => JSON::PP::false(), applications => $apps, %o } }
my $vlc  = { appId => 'AndroidNativeApp', displayName => 'VLC', isIdleScreen => JSON::PP::false() };
my $cast = { appId => 'CC1AD845', displayName => 'Default Media Receiver', isIdleScreen => JSON::PP::false() };
my $idle = { appId => 'E8C28D3C', displayName => 'Backdrop', isIdleScreen => JSON::PP::true() };
my $ours = { appId => 'E49BABAD', sessionId => 's1', transportId => 't1' };

my $d = dev();
$d->_on_status(st([$vlc]));
is_deeply(\@sent, ['LAUNCH'], 'native app with a media session (VLC in the background) does not block');
is($d->status, 'launching', 'status launching');

$d = dev();
$d->_on_status(st([$idle]));
is_deeply(\@sent, ['LAUNCH'], 'idle screen does not block');

$d = dev();
$d->_on_status(st([$cast]));
is_deeply(\@sent, [], 'someone casting to the TV: not taken');
like($d->status, qr/screen busy: Default Media Receiver/, 'status names the Cast app');
ok($d->{yielded}, 'yields until playback restarts');

$d = dev();
$d->_on_status(st([$ours, $vlc]));
is_deeply(\@sent, ['CONNECT', 'NP'], 'our receiver running next to a native app: connect and send');
is($d->status, 'showing', 'showing');

# our receiver closed while wanted (user opened something on the TV): no immediate relaunch
@sent = ();
$d->_on_status(st([$vlc]));
is_deeply(\@sent, [], 'closed by the user: not launched again at once');
ok($d->{yielded}, 'yielded until playback restarts');
$d->release;
$d->_on_status(st([$vlc]));
is_deeply(\@sent, ['LAUNCH'], 'after release (playback restarted) it launches again');

# TV went to standby: receiver gone, but the screen comes back when the TV returns
$d = dev();
$d->_on_status(st([$ours]));
@sent = ();
$d->_on_status(st([], isStandBy => JSON::PP::true()));
is($d->status, 'standby', 'standby');
ok(!$d->{yielded}, 'standby does not count as closed by the user');
$d->_on_status(st([]));
is_deeply(\@sent, ['LAUNCH'], 'TV back on: launched again');

$d = dev();
$d->_on_status(st([], isActiveInput => JSON::PP::false()));
is_deeply(\@sent, [], 'TV on another input: not switched');
is($d->status, 'other input', 'status other input');

done_testing;

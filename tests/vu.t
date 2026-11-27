#!/usr/bin/perl
# VU metar na TV-u: podesavanja iz plugina VUMeter, spisak lokalnih plejera, format nivoa, slanje ekranu.
use strict;
use warnings;
use Test::More;

my (@http, $http_ok);
BEGIN {
	package main;
	no strict 'refs';
	*{'main::INFOLOG'} = sub () { 0 } unless defined &main::INFOLOG;
	for my $m (qw(Slim::Networking::Select Slim::Networking::SimpleAsyncHTTP Slim::Utils::Log Slim::Utils::Timers)) {
		(my $f = "$m.pm") =~ s{::}{/}g;
		$INC{$f} = __FILE__;
		*{"${m}::import"} = sub {};
	}
	*{'Plugins::CastNowPlaying::VU::logger'} = *{'Plugins::CastNowPlaying::Device::logger'} = sub { bless {}, 'StubLog' };
	*{'StubLog::is_info'} = sub { 0 };
	*{'StubLog::info'} = *{'StubLog::warn'} = sub {};
	# SimpleAsyncHTTP: zahtev se pamti, odgovor je ono sto test postavi u $http_ok
	*{'Slim::Networking::SimpleAsyncHTTP::new'} = sub { my ($c, $ok, $err) = @_; bless { ok => $ok, err => $err }, $c };
	*{'Slim::Networking::SimpleAsyncHTTP::get'} = sub {
		my ($s, $url) = @_;
		push @http, $url;
		defined $http_ok ? $s->{ok}->(bless { c => $http_ok }, 'StubRes') : $s->{err}->($s, 'down');
	};
	*{'StubRes::content'} = sub { $_[0]{c} };
	*{'Slim::Utils::Timers::setTimer'} = sub {};
	*{'Slim::Utils::Timers::killTimers'} = sub {};
}

use Plugins::CastNowPlaying::Device;
use Plugins::CastNowPlaying::VU;

# bez plugina VUMeter nema VU-a
is(Plugins::CastNowPlaying::VU::config(), undef, 'bez plugina VUMeter: iskljuceno');
is(Plugins::CastNowPlaying::VU::info('aa:bb'), undef, 'bez plugina VUMeter: nema info');
is(scalar @http, 0, 'bez plugina VUMeter: servis se ne pita');

my $cfg = { tv => 'needles', ref => -14, tvDelay => 0, port => 9095 };
{ no strict 'refs'; *{'Plugins::VUMeter::Plugin::config'} = sub { $cfg }; }

$http_ok = '[{"id":"02:7D:F7:86:EE:BB","running":true}]';
# (stub odgovara odmah, pa je spisak tu vec posle prvog poziva)
is_deeply(Plugins::CastNowPlaying::VU::info('02:7d:f7:86:ee:bb'), { style => 'needles', ref => -14, delay => 0 }, 'lokalni plejer: info za receiver');
$cfg->{ref} = 'auto';
is(Plugins::CastNowPlaying::VU::info('02:7d:f7:86:ee:bb')->{ref}, 'auto', 'referentni nivo auto ide receiver-u kao tekst');
$cfg->{ref} = -14;
like($http[0], qr{^http://127\.0\.0\.1:9095/players$}, 'spisak plejera od servisa');
is(Plugins::CastNowPlaying::VU::info('aa:aa:aa:aa:aa:aa'), undef, 'plejer koji servis ne vidi: nema VU-a');
$cfg->{tv} = 'off';
is(Plugins::CastNowPlaying::VU::info('02:7d:f7:86:ee:bb'), undef, 'VU za TV iskljucen');
$cfg->{tv} = 'bars';

is_deeply(Plugins::CastNowPlaying::VU::_frame({ p => [0.5, 0.25], r => [0.1234, 0.0006], on => 1 }), [500, 250, 123, 1], 'frame -> hiljaditi delovi');
is_deeply(Plugins::CastNowPlaying::VU::_frame({ p => [0.5, 0.5], r => [0.1, 0.1], on => 0 }), [0, 0, 0, 0], 'plejer ne svira: nule');

# slanje: samo ekranu koji prikazuje plejer, i ne kad se slanje zaglavilo
my @sent;
{
	no warnings 'redefine';
	*Plugins::CastNowPlaying::Device::_send = sub { my ($self, $dst, $ns, $p) = @_; push @sent, [$dst, $p->{type}] };
}
my $d = Plugins::CastNowPlaying::Device->new(id => 'x', name => 'Box');
$d->send_vu({ type => 'vu', f => [] });
is(scalar @sent, 0, 'ekran nije povezan: nista');
@$d{qw(state transport status)} = ('up', 't1', 'showing');
$d->send_vu({ type => 'vu', f => [] });
is_deeply(\@sent, [['t1', 'vu']], 'povezan ekran dobija nivoe');
$d->{wbuf} = 'x' x 40000;
$d->send_vu({ type => 'vu', f => [] });
is(scalar @sent, 1, 'zaglavljeno slanje: nivoi se preskacu');
$d->{wbuf} = '';

# petlja: zahtev za nove nivoe salje ih ekranu
@http = ();
$http_ok = '{"seq":42,"fps":30,"frames":[{"p":[0.5,0.5],"r":[0.2,0.2],"on":1}]}';
my $client = bless { id => '02:7d:f7:86:ee:bb' }, 'StubClient';
{ no strict 'refs'; *{'StubClient::id'} = sub { $_[0]{id} }; }
@sent = ();
Plugins::CastNowPlaying::VU::start($client, sub { ($d) });
like($http[0], qr{/levels\?player=02:7d:f7:86:ee:bb&since=0$}, 'zahtev za nivoe');
is_deeply(\@sent, [['t1', 'vu']], 'nivoi poslati ekranu');
Plugins::CastNowPlaying::VU::stop($client);

done_testing;

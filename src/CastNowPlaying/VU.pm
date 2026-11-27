package Plugins::CastNowPlaying::VU;

# VU metar na TV-u (plugin VUMeter, lyrion-vumeter). Nivoe daje servis vumeterd na ovom serveru, samo za
# plejere koji tu rade (squeezelite sa -v). Dok plejer svira i ekran ga prikazuje, plugin svakih POLL s
# uzima nove nivoe (GET /levels?player=..&since=..) i salje ih receiver-u kao poruku { type: 'vu', f: [...] }.
# Receiver ih crta istim kodom kao Material (receiver/vu-draw.js). Izgled (kazaljke/trake), referentni
# nivo i kasnjenje bira korisnik u podesavanjima plugina VUMeter (tv, ref, tvDelay).
#
# TV ne moze sam da se poveze sa servisom: receiver je https stranica, a servis je http u lokalnoj mrezi.

use strict;
use warnings;
use utf8;

use JSON::PP ();
use Time::HiRes ();

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Log;
use Slim::Utils::Timers;

use constant POLL          => 0.1;   # s izmedju dva zahteva
use constant PLAYERS_EVERY => 30;    # s, osvezavanje spiska plejera koje servis vidi
use constant BACKOFF       => 30;    # s posle greske

my $log = logger('plugin.castnowplaying');
my $JSON = JSON::PP->new;

my %LOCAL;          # mac (malim slovima) => 1: servis vidi plejer
my $LOCAL_AT = 0;
my $LOCAL_BUSY = 0;
my %RUN;            # mac => { since, busy, devices => sub, down_until }

# config() -> podesavanja plugina VUMeter ako je VU za TV ukljucen, inace undef
sub config {
	return undef unless Plugins::VUMeter::Plugin->can('config');
	my $c = eval { Plugins::VUMeter::Plugin::config() } or return undef;
	return ($c->{tv} // 'off') eq 'off' ? undef : $c;
}

# info($mac) -> { style, ref, delay } za poruku receiver-u, ili undef (plejer nije lokalni, VU iskljucen)
sub info {
	my ($mac) = @_;
	my $c = config() or return undef;
	_refresh_players($c) if time - $LOCAL_AT > PLAYERS_EVERY;
	return undef unless $LOCAL{ lc($mac // '') };
	return { style => $c->{tv}, ref => $c->{ref} eq 'auto' ? 'auto' : $c->{ref} + 0, delay => $c->{tvDelay} + 0 };
}

sub _refresh_players {
	my ($c) = @_;
	return if $LOCAL_BUSY;
	$LOCAL_BUSY = 1;
	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $list = eval { $JSON->decode($_[0]->content) };
			%LOCAL = ref $list eq 'ARRAY' ? map { lc($_->{id} // '') => 1 } @$list : ();
			$LOCAL_AT = time;
			$LOCAL_BUSY = 0;
		},
		sub {
			%LOCAL = ();
			$LOCAL_AT = time;
			$LOCAL_BUSY = 0;
		},
		{ timeout => 3 },
	)->get("http://127.0.0.1:$c->{port}/players");
}

# start($client, $devices): $devices->() vraca ekrane koji prate plejer; nivoi idu onima koji ga prikazuju
sub start {
	my ($client, $devices) = @_;
	my $mac = $client->id;
	my $r = $RUN{$mac} ||= { since => 0, mac => $mac };
	$r->{devices} = $devices;
	$r->{client} = $client;
	return if $r->{busy} || $r->{timer};
	_poll($mac);
}

sub stop {
	my ($client) = @_;
	my $r = delete $RUN{ $client->id } or return;
	Slim::Utils::Timers::killTimers($r, \&_tick);
}

sub _tick {
	my ($r) = @_;
	$r->{timer} = 0;
	_poll($r->{mac}) if ($RUN{ $r->{mac} } // 0) == $r;
}

# sledeci zahtev; $r koji je u medjuvremenu zaustavljen (stop, novi start) se ne nastavlja
sub _schedule {
	my ($r, $delay) = @_;
	return unless ($RUN{ $r->{mac} } // 0) == $r;
	$r->{timer} = 1;
	Slim::Utils::Timers::setTimer($r, Time::HiRes::time() + $delay, \&_tick);
}

sub _poll {
	my ($mac) = @_;
	my $r = $RUN{$mac} or return;
	my $c = config();
	my @devs = grep { $_->status eq 'showing' } $r->{devices}->();
	if (!$c || !@devs) {
		delete $RUN{$mac};
		return;
	}
	if (($r->{down_until} // 0) > time) {
		_schedule($r, 1);
		return;
	}
	$r->{busy} = 1;
	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $res = shift;
			$r->{busy} = 0;
			my $d = eval { $JSON->decode($res->content) } || {};
			my @f = ref $d->{frames} eq 'ARRAY' ? @{ $d->{frames} } : ();
			$r->{since} = $d->{seq} if defined $d->{seq};
			if (@f) {
				my $msg = { type => 'vu', fps => ($d->{fps} // 30) + 0, f => [ map { _frame($_) } @f ] };
				$_->send_vu($msg) for grep { $_->status eq 'showing' } $r->{devices}->();
			}
			_schedule($r, POLL);
		},
		sub {
			$r->{busy} = 0;
			$r->{down_until} = time + BACKOFF;
			main::INFOLOG && $log->is_info && $log->info("VU servis ne odgovara: $_[1]");
			_schedule($r, 1);
		},
		{ timeout => 2 },
	)->get("http://127.0.0.1:$c->{port}/levels?player=$mac&since=" . ($r->{since} // 0));
}

# frame servisa -> [peakL, peakR, rmsL, rmsR] u hiljaditim delovima pune skale (0 kad plejer ne svira)
sub _frame {
	my ($f) = @_;
	return [ 0, 0, 0, 0 ] unless $f->{on};
	return [ map { int(($_ // 0) * 1000 + 0.5) } @{ $f->{p} || [] }[0, 1], @{ $f->{r} || [] }[0, 1] ];
}

1;

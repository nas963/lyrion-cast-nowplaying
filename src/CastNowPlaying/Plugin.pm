package Plugins::CastNowPlaying::Plugin;

# Shows the now-playing screen of an LMS player on Cast screens (Chromecast, Google TV, Android TV
# boxes, TVs with Cast built in). Cast protocol and mDNS are pure Perl on the LMS event loop, so the
# plugin runs on any LMS platform without helper programs.
#
# prefs plugin.castnowplaying:
#   devices     { castId => { enabled => 0|1, player => 'mac', name => 'friendly name' } }
#   idleMinutes  close the receiver after the player has been paused/stopped this long (0 = never)

use strict;
use warnings;
use utf8;
use base qw(Slim::Plugin::Base);

use JSON::PP ();
use Time::HiRes ();

use Slim::Control::Request;
use Slim::Player::Client;
use Slim::Utils::Log;
use Slim::Utils::Network;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;

use Plugins::CastNowPlaying::Device;
use Plugins::CastNowPlaying::Discovery;
use Plugins::CastNowPlaying::MDNS;

use constant RESYNC_EVERY => 20;     # s, re-send position while playing (corrects drift)
use constant DEBOUNCE     => 0.3;    # s

my $log = Slim::Utils::Log->addLogCategory({
	category     => 'plugin.castnowplaying',
	defaultLevel => 'WARN',
	description  => 'PLUGIN_CASTNOWPLAYING',
});

my $prefs = preferences('plugin.castnowplaying');

my %DEV;        # castId => Device (enabled devices only)
my %IDLE_AT;    # player mac => time when it stopped playing

sub initPlugin {
	my $class = shift;
	$class->SUPER::initPlugin(@_);

	$prefs->init({ devices => {}, idleMinutes => 10 });

	if (main::WEBUI) {
		require Plugins::CastNowPlaying::Settings;
		Plugins::CastNowPlaying::Settings->new;
	}

	Plugins::CastNowPlaying::Discovery->start(\&_seen);
	reconfigure();

	Slim::Control::Request::subscribe(\&_onEvent,
		[[ 'playlist', 'play', 'pause', 'stop', 'mode', 'time', 'power', 'client' ]]);

	# castnowplaying toggle: turns the Cast screens that follow this player on or off
	Slim::Control::Request::addDispatch([ 'castnowplaying', 'toggle' ], [ 1, 0, 0, \&_cliToggle ]);
}

# Material Skin (if installed) gets a "Cast screen" item in the player menu
my $MATERIAL_ACTION;

sub postinitPlugin {
	return unless Slim::Utils::PluginManager->isEnabled('Plugins::MaterialSkin::Plugin');
	my $register = Plugins::MaterialSkin::Plugin->can('registerCustomAction') or return;
	$MATERIAL_ACTION = {
		title   => Slim::Utils::Strings::string('PLUGIN_CASTNOWPLAYING_TOGGLE'),
		icon    => 'cast',
		players => [],
		script  => 'lmsCommand("$ID",["castnowplaying","toggle"]).then(({data})=>{'
		         . 'if(data&&data.result&&data.result.message){bus.$emit("showMessage",data.result.message);}})',
	};
	_material_players();
	eval { $register->('players', $MATERIAL_ACTION); 1 } or $log->warn("Material menu: $@");
}

# the menu item is shown only for players that some Cast screen follows (in place, Material keeps the ref)
sub _material_players {
	return unless $MATERIAL_ACTION;
	my $conf = $prefs->get('devices') || {};
	my %p = map { $_->{player} => 1 } grep { $_->{player} } values %$conf;
	@{ $MATERIAL_ACTION->{players} } = sort keys %p;
}

sub _cliToggle {
	my $request = shift;
	my $client = $request->client;
	if (!$client) { $request->setStatusBadDispatch; return; }
	my ($on, @names) = toggle($client->id);
	my $msg = !@names ? Slim::Utils::Strings::string('PLUGIN_CASTNOWPLAYING_TOGGLE_NONE')
		: Slim::Utils::Strings::string($on ? 'PLUGIN_CASTNOWPLAYING_TOGGLE_ON' : 'PLUGIN_CASTNOWPLAYING_TOGGLE_OFF') . ': ' . join(', ', @names);
	$request->addResult('on', $on ? 1 : 0);
	$request->addResult('message', $msg);
	$request->setStatusDone;
}

# all screens following $mac go on if none of them is on, otherwise all go off; returns (on, names)
sub toggle {
	my $mac = shift;
	my $conf = $prefs->get('devices') || {};
	my @ids = sort grep { ($conf->{$_}{player} // '') eq $mac } keys %$conf;
	return (0) unless @ids;
	my $on = !grep { $conf->{$_}{enabled} } @ids;
	my %new = map { $_ => { %{ $conf->{$_} } } } keys %$conf;    # copy, so the pref really changes
	$new{$_}{enabled} = $on ? 1 : 0 for @ids;
	$prefs->set('devices', \%new);
	reconfigure();
	return ($on, map { $new{$_}{name} // $_ } @ids);
}

sub shutdownPlugin {
	Slim::Control::Request::unsubscribe(\&_onEvent);
	Plugins::CastNowPlaying::Discovery->stop;
	$_->shutdown for values %DEV;
	%DEV = ();
}

sub getDisplayName { 'PLUGIN_CASTNOWPLAYING' }

# ---------------------------------------------------------------- devices

# (re)build Device objects from prefs; called at start and after settings are saved
sub reconfigure {
	my $conf = $prefs->get('devices') || {};
	for my $id (keys %DEV) {
		next if $conf->{$id} && $conf->{$id}{enabled} && $conf->{$id}{player};
		$DEV{$id}->hide;
		$DEV{$id}->shutdown;
		delete $DEV{$id};
	}
	for my $id (keys %$conf) {
		my $c = $conf->{$id};
		next unless $c->{enabled} && $c->{player};
		$DEV{$id} ||= Plugins::CastNowPlaying::Device->new(id => $id, name => $c->{name});
		if (my $d = Plugins::CastNowPlaying::Discovery->device($id)) {
			$DEV{$id}->set_address($d->{ip}, $d->{port}, $d->{name});
		}
	}
	Plugins::CastNowPlaying::Discovery->refresh;
	_material_players();
	_update($_) for grep { defined } map { Slim::Player::Client::getClient($_) } _followed_players();
}

sub _followed_players {
	my $conf = $prefs->get('devices') || {};
	my %p = map { $conf->{$_}{player} => 1 } grep { $DEV{$_} } keys %$conf;
	return keys %p;
}

sub _devices_for {
	my $mac = shift;
	my $conf = $prefs->get('devices') || {};
	return map { $DEV{$_} } grep { $DEV{$_} && ($conf->{$_}{player} // '') eq $mac } keys %$conf;
}

# mDNS saw a device
sub _seen {
	my ($d, $changed) = @_;
	my $dev = $DEV{ $d->{id} } or return;
	$dev->set_address($d->{ip}, $d->{port}, $d->{name});
	# a TV that just woke up: push the current state so it can launch
	if (my $c = $changed && Slim::Player::Client::getClient(($prefs->get('devices')->{ $d->{id} } || {})->{player} // '')) {
		_update($c);
	}
}

# for the settings page: everything we know about, display devices first
sub known_devices {
	my $conf = $prefs->get('devices') || {};
	my %all;
	for my $d (Plugins::CastNowPlaying::Discovery->devices) {
		$all{ $d->{id} } = { %$d, display => Plugins::CastNowPlaying::MDNS::has_display($d->{ca}), online => 1 };
	}
	for my $id (keys %$conf) {
		$all{$id} ||= { id => $id, name => $conf->{$id}{name} // $id, model => '', display => 1, online => 0 };
	}
	for my $d (values %all) {
		my $c = $conf->{ $d->{id} } || {};    # no autovivification: $conf is the live pref
		$d->{enabled} = $c->{enabled} ? 1 : 0;
		$d->{player} = $c->{player} // '';
		$d->{status} = $DEV{ $d->{id} } ? $DEV{ $d->{id} }->status : '';
	}
	return [ sort { $b->{display} <=> $a->{display} || lc $a->{name} cmp lc $b->{name} } values %all ];
}

# ---------------------------------------------------------------- player events

sub _onEvent {
	my $request = shift;
	my $client = $request->client or return;
	my $mac = $client->id;
	return unless _devices_for($mac);
	Slim::Utils::Timers::killTimers($client, \&_update);
	Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + DEBOUNCE, \&_update);
}

sub _update {
	my $client = shift;
	Slim::Utils::Timers::killTimers($client, \&_update);
	Slim::Utils::Timers::killTimers($client, \&_resync);
	my @devs = _devices_for($client->id) or return;

	my ($msg, $mode) = now_playing($client);
	my $power = $client->power;
	my $mac = $client->id;

	if (!$power || $mode eq 'stop') {
		# stopped: playback restarting later may take the screen again
		$_->release for @devs;
	}
	if (!$power) {
		$_->hide for @devs;
		delete $IDLE_AT{$mac};
		return;
	}

	if ($mode eq 'play') {
		delete $IDLE_AT{$mac};
		$_->show($msg) for @devs;
		Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + RESYNC_EVERY, \&_resync);
		return;
	}

	# paused or stopped: keep the screen while within idleMinutes, then close it
	my $idle = $prefs->get('idleMinutes') // 10;
	$IDLE_AT{$mac} //= time;
	if ($idle > 0 && time - $IDLE_AT{$mac} >= $idle * 60) {
		$_->hide for @devs;
		return;
	}
	# only refresh screens that are already up; a paused player does not launch the receiver
	for my $d (@devs) { $d->show($msg) if $d->status eq 'showing' }
	if ($idle > 0) {
		Slim::Utils::Timers::setTimer($client, $IDLE_AT{$mac} + $idle * 60 + 1, \&_update);
	}
}

sub _resync { _update(shift) }

# ---------------------------------------------------------------- now-playing message

sub now_playing {
	my $client = shift;
	my $req = Slim::Control::Request::executeRequest($client, [ 'status', '-', 1, 'tags:alcdytrITKoN' ]);
	my $r = $req ? $req->getResults : {};
	my $t = ($r->{playlist_loop} || [])->[0] || {};
	my $base = Slim::Utils::Network::serverURL();

	my @fmt;
	push @fmt, $t->{bitrate} if $t->{bitrate};
	push @fmt, "$t->{samplesize}bit" if $t->{samplesize};
	push @fmt, sprintf('%gkHz', $t->{samplerate} / 1000) if $t->{samplerate};
	push @fmt, $t->{type} if $t->{type};
	my $info = join(', ', @fmt);
	if ($r->{playlist_tracks} && $r->{playlist_tracks} > 1) {
		$info .= ($info ? " \x{2022} " : '') . sprintf('%d of %d', ($r->{playlist_cur_index} // 0) + 1, $r->{playlist_tracks});
	}

	my $cover;
	if (my $a = $t->{artwork_url}) {
		$cover = $a =~ m{^https?://}i ? $a : $base . ($a =~ m{^/} ? '' : '/') . $a;
	}
	elsif (defined $t->{coverid} && $t->{coverid} ne '') {
		$cover = "$base/music/$t->{coverid}/cover_1280x1280.jpg";
	}
	else {
		$cover = "$base/music/current/cover_1280x1280.jpg?player=" . $client->id . '&t=' . int(time);
	}

	my $mode = $r->{mode} // 'stop';
	my $msg = {
		type     => (!$t->{title} && $mode eq 'stop') ? 'idle' : 'track',
		title    => $t->{title} // '',
		artist   => $t->{artist} // '',
		album    => $t->{album} // $t->{remote_title} // '',
		year     => $t->{year} || undef,
		trackNum => $t->{tracknum} || undef,
		info     => $info,
		cover    => $cover,
		duration => ($r->{duration} // 0) + 0,
		elapsed  => ($r->{time} // 0) + 0,
		playing  => $mode eq 'play' ? JSON::PP::true() : JSON::PP::false(),
	};
	return ($msg, $mode);
}

1;

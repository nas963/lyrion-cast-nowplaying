package Plugins::CastNowPlaying::Settings;

# Settings page: one row per Cast device (display devices first): show on/off + which player it follows.

use strict;
use warnings;
use utf8;
use base qw(Slim::Web::Settings);

use Slim::Player::Client;
use Slim::Utils::Prefs;
use Slim::Utils::Strings;

my $prefs = preferences('plugin.castnowplaying');

sub name { return Slim::Web::HTTP::CSRF->protectName('PLUGIN_CASTNOWPLAYING') }

sub page { return Slim::Web::HTTP::CSRF->protectURI('plugins/CastNowPlaying/settings/basic.html') }

sub prefs { return ($prefs, 'idleMinutes') }

sub handler {
	my ($class, $client, $params, @rest) = @_;

	if ($params->{saveSettings}) {
		my $conf = { %{ $prefs->get('devices') || {} } };
		for my $i (0 .. 199) {
			my $id = $params->{"dev_id_$i"};
			last unless defined $id;
			next unless $id =~ /^[\w.:-]{1,64}\z/;
			my $player = $params->{"dev_player_$i"} // '';
			$player = '' unless $player =~ /^[0-9a-f:.-]{1,40}\z/i;
			my $enabled = $params->{"dev_enabled_$i"} ? 1 : 0;
			if (!$enabled && !$player) { delete $conf->{$id}; next }
			$conf->{$id} = { enabled => $enabled, player => $player, name => $params->{"dev_name_$i"} // $id };
		}
		$prefs->set('devices', $conf);
		my $idle = $params->{pref_idleMinutes} // '';
		$params->{pref_idleMinutes} = 10 unless $idle =~ /^\d{1,4}\z/;
		Plugins::CastNowPlaying::Plugin::reconfigure();
	}

	$params->{castDevices} = Plugins::CastNowPlaying::Plugin::known_devices();
	$params->{castPlayers} = [
		sort { lc $a->{name} cmp lc $b->{name} }
		map { { id => $_->id, name => $_->name } } Slim::Player::Client::clients()
	];

	return $class->SUPER::handler($client, $params, @rest);
}

1;

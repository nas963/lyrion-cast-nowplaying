package Plugins::CastNowPlaying::Discovery;

# Finds Cast devices on the LAN with mDNS, on the LMS event loop.
# Listens on 5353 (shared with other responders) and joins the group, because Android TV
# devices answer by multicast only; falls back to an ephemeral port (unicast answers) if 5353
# cannot be bound.

use strict;
use warnings;

use IO::Socket::INET;
use Socket qw(inet_aton inet_ntoa sockaddr_in INADDR_ANY);
use Time::HiRes ();

use Slim::Networking::Select;
use Slim::Utils::Log;
use Slim::Utils::Timers;

use Plugins::CastNowPlaying::MDNS;

use constant QUERY_EVERY => 60;    # s

my $log = logger('plugin.castnowplaying');

my ($sock, $onSeen);
my %devices;    # id => { id name model ca ip port seen }

sub start {
	my ($class, $cb) = @_;
	$onSeen = $cb;
	return if $sock;

	$sock = IO::Socket::INET->new(Proto => 'udp', LocalPort => 5353, ReuseAddr => 1, ReusePort => 1, Blocking => 0)
		|| IO::Socket::INET->new(Proto => 'udp', LocalPort => 5353, ReuseAddr => 1, Blocking => 0)
		|| IO::Socket::INET->new(Proto => 'udp', LocalPort => 0, Blocking => 0);
	if (!$sock) {
		$log->error("mDNS socket failed: $!");
		return;
	}
	if ($sock->sockport == 5353) {
		my $ok = eval {
			setsockopt($sock, Socket::IPPROTO_IP(), Socket::IP_ADD_MEMBERSHIP(),
				Socket::pack_ip_mreq(inet_aton('224.0.0.251'), INADDR_ANY));
		};
		$log->warn("mDNS multicast join failed: " . ($@ || $!)) unless $ok;
	}
	main::INFOLOG && $log->is_info && $log->info('mDNS discovery on port ' . $sock->sockport);

	Slim::Networking::Select::addRead($sock, \&_read);
	# a few quick queries at start (UDP may drop), then once a minute
	Slim::Utils::Timers::setTimer($class, Time::HiRes::time() + $_, \&_query) for 1, 4, 10;
	_schedule($class);
}

sub stop {
	my $class = shift;
	Slim::Utils::Timers::killTimers($class, \&_query);
	Slim::Utils::Timers::killTimers($class, \&_periodic);
	if ($sock) {
		Slim::Networking::Select::removeRead($sock);
		close $sock;
		undef $sock;
	}
}

sub devices { return values %devices }

sub device { return $devices{ $_[1] } }

sub refresh { _query(__PACKAGE__) }

sub _schedule {
	my $class = shift;
	Slim::Utils::Timers::setTimer($class, Time::HiRes::time() + QUERY_EVERY, \&_periodic);
}

sub _periodic {
	my $class = shift;
	_query($class);
	_schedule($class);
}

sub _query {
	return unless $sock;
	my $dest = sockaddr_in(5353, inet_aton('224.0.0.251'));
	send($sock, Plugins::CastNowPlaying::MDNS::query_packet(), 0, $dest)
		or main::DEBUGLOG && $log->is_debug && $log->debug("mDNS send: $!");
}

sub _read {
	for (1 .. 50) {
		my $from = recv($sock, my $buf, 9000, 0);
		last unless defined $from && length $buf;
		my $ip = eval { inet_ntoa((sockaddr_in($from))[1]) } // '';
		for my $d (Plugins::CastNowPlaying::MDNS::parse($buf, $ip)) {
			my $old = $devices{ $d->{id} };
			my $changed = !$old || $old->{ip} ne $d->{ip} || $old->{port} != $d->{port};
			$d->{seen} = time;
			$devices{ $d->{id} } = $d;
			main::INFOLOG && $changed && $log->is_info && $log->info("Cast device: $d->{name} ($d->{model}) at $d->{ip}:$d->{port}");
			$onSeen->($d, $changed) if $onSeen;
		}
	}
}


1;

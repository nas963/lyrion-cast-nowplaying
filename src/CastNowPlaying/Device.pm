package Plugins::CastNowPlaying::Device;

# One Cast screen: TLS connection on the LMS event loop, receiver app lifecycle, now-playing messages.
#
# The controller only sets what it wants:
#   show($msg)  - our receiver should be on screen with this now-playing state
#   hide()      - close our receiver (if it is ours that is running)
# The device does the rest: connects, launches when the screen is free, follows the app being
# closed or replaced, reconnects when the TV comes back.
#
# Politeness rule: if another app (Netflix, live TV, CastBridge audio...) is on the screen, we do not
# take it over. We wait until the controller calls release() (playback stopped), then try again.

use strict;
use warnings;

use IO::Socket::INET;
use IO::Socket::SSL;
use JSON::PP ();
use Socket ();
use Time::HiRes ();

use Slim::Networking::Select;
use Slim::Utils::Log;
use Slim::Utils::Timers;

use Plugins::CastNowPlaying::Proto;

use constant APP_ID       => 'E49BABAD';
use constant SENDER       => 'sender-lms-np';
use constant CONNECT_WAIT => 6;      # s, TCP + TLS
use constant PING_EVERY   => 5;      # s
use constant DEAD_AFTER   => 20;     # s without any data
use constant RETRY_MIN    => 5;      # s
use constant RETRY_MAX    => 60;     # s

my $log = logger('plugin.castnowplaying');
my $JSON = JSON::PP->new->canonical;

sub new {
	my ($class, %a) = @_;
	my $self = bless {
		id => $a{id}, name => $a{name} // $a{id}, ip => $a{ip}, port => $a{port} || 8009,
		state => 'off',        # off | connecting | tls | up
		want => 0,             # 1 = should be showing
		msg => undef,          # last now-playing message
		transport => undef,    # transportId of our running receiver
		session => undef,
		yielded => 0,          # another app owns the screen; wait for release()
		launching => 0,
		retry => RETRY_MIN,
		rbuf => '', wbuf => '',
		req => 1,
		status => 'idle',
	}, $class;
	return $self;
}

sub id     { $_[0]{id} }
sub name   { $_[0]{name} }
sub status { $_[0]{status} }

sub set_address {
	my ($self, $ip, $port, $name) = @_;
	$self->{name} = $name if defined $name;
	return unless $ip;
	my $moved = !$self->{ip} || $self->{ip} ne $ip || $self->{port} != ($port || 8009);
	$self->{ip} = $ip;
	$self->{port} = $port || 8009;
	if ($moved && $self->{state} ne 'off') {
		$self->_close('address changed');
	}
	# device (re)appeared: try now instead of waiting for the backoff
	if ($self->{want} && $self->{state} eq 'off') {
		$self->{retry} = RETRY_MIN;
		Slim::Utils::Timers::killTimers($self, \&_retry);
		$self->_connect;
	}
}

sub show {
	my ($self, $msg) = @_;
	$self->{msg} = $msg;
	$self->{want} = 1;
	if ($self->{state} eq 'off') { $self->_connect; return }
	return unless $self->{state} eq 'up';
	if ($self->{transport}) { $self->_send_np }
	elsif (!$self->{launching} && !$self->{yielded}) { $self->_get_status }
}

sub hide {
	my ($self) = @_;
	$self->{want} = 0;
	if ($self->{state} eq 'up' && $self->{session}) {
		$self->_send('receiver-0', Plugins::CastNowPlaying::Proto::NS_RECEIVER, { type => 'STOP', sessionId => $self->{session} });
	}
	# give the STOP a moment to go out, then drop the connection
	Slim::Utils::Timers::killTimers($self, \&_idle_close);
	Slim::Utils::Timers::setTimer($self, Time::HiRes::time() + 3, \&_idle_close);
}

# playback stopped: next time we are asked to show, we may launch even if we yielded before
sub release { $_[0]{yielded} = 0 }

sub shutdown {
	my $self = shift;
	$self->{want} = 0;
	Slim::Utils::Timers::killTimers($self, $_) for \&_retry, \&_idle_close, \&_ping, \&_connect_timeout;
	$self->_close('shutdown');
}

# ---------------------------------------------------------------- connection

sub _connect {
	my $self = shift;
	return unless $self->{ip} && $self->{state} eq 'off';
	Slim::Utils::Timers::killTimers($self, \&_idle_close);
	my $sock = IO::Socket::INET->new(PeerAddr => $self->{ip}, PeerPort => $self->{port}, Proto => 'tcp', Blocking => 0);
	if (!$sock) {
		$self->_failed("socket: $!");
		return;
	}
	$self->{sock} = $sock;
	$self->{state} = 'connecting';
	$self->{status} = 'connecting';
	Slim::Utils::Timers::setTimer($self, Time::HiRes::time() + CONNECT_WAIT, \&_connect_timeout);
	Slim::Networking::Select::addWrite($sock, sub { $self->_tcp_ready });
}

sub _connect_timeout { $_[0]->_failed('connect timeout') }

sub _tcp_ready {
	my $self = shift;
	my $sock = $self->{sock} or return;
	Slim::Networking::Select::removeWrite($sock);
	my $err = getsockopt($sock, Socket::SOL_SOCKET(), Socket::SO_ERROR());
	$err = $err ? unpack('i', $err) : 0;
	if ($err || !$sock->connected) {
		local $! = $err;
		$self->_failed("connect: $!");
		return;
	}
	if (!IO::Socket::SSL->start_SSL($sock, SSL_startHandshake => 0, SSL_verify_mode => SSL_VERIFY_NONE)) {
		$self->_failed("TLS: $SSL_ERROR");
		return;
	}
	$self->{state} = 'tls';
	$self->_handshake;
}

sub _handshake {
	my $self = shift;
	my $sock = $self->{sock} or return;
	Slim::Networking::Select::removeRead($sock);
	Slim::Networking::Select::removeWrite($sock);
	if ($sock->connect_SSL) {
		$self->_up;
		return;
	}
	if ($SSL_ERROR == SSL_WANT_READ) {
		Slim::Networking::Select::addRead($sock, sub { $self->_handshake });
	}
	elsif ($SSL_ERROR == SSL_WANT_WRITE) {
		Slim::Networking::Select::addWrite($sock, sub { $self->_handshake });
	}
	else {
		$self->_failed("TLS handshake: $SSL_ERROR");
	}
}

sub _up {
	my $self = shift;
	Slim::Utils::Timers::killTimers($self, \&_connect_timeout);
	$self->{state} = 'up';
	$self->{status} = 'connected';
	$self->{retry} = RETRY_MIN;
	$self->{rbuf} = $self->{wbuf} = '';
	$self->{last_rx} = time;
	main::INFOLOG && $log->is_info && $log->info("$self->{name}: connected");
	Slim::Networking::Select::addRead($self->{sock}, sub { $self->_read });
	$self->_send('receiver-0', Plugins::CastNowPlaying::Proto::NS_CONN, { type => 'CONNECT' });
	$self->_get_status;
	Slim::Utils::Timers::setTimer($self, Time::HiRes::time() + PING_EVERY, \&_ping);
}

sub _failed {
	my ($self, $why) = @_;
	main::INFOLOG && $log->is_info && $log->info("$self->{name} ($self->{ip}): $why");
	$self->_close($why);
}

sub _close {
	my ($self, $why) = @_;
	Slim::Utils::Timers::killTimers($self, $_) for \&_connect_timeout, \&_ping;
	if (my $sock = delete $self->{sock}) {
		Slim::Networking::Select::removeRead($sock);
		Slim::Networking::Select::removeWrite($sock);
		eval { $sock->close(SSL_no_shutdown => 1) } if ref $sock eq 'IO::Socket::SSL';
		eval { close $sock };
	}
	$self->{state} = 'off';
	$self->{transport} = $self->{session} = undef;
	$self->{launching} = 0;
	$self->{status} = $self->{want} ? 'unreachable' : 'idle';
	if ($self->{want} && $why ne 'shutdown') {
		Slim::Utils::Timers::killTimers($self, \&_retry);
		Slim::Utils::Timers::setTimer($self, Time::HiRes::time() + $self->{retry}, \&_retry);
		$self->{retry} = $self->{retry} * 2 > RETRY_MAX ? RETRY_MAX : $self->{retry} * 2;
	}
}

sub _retry {
	my $self = shift;
	$self->_connect if $self->{want} && $self->{state} eq 'off';
}

sub _idle_close {
	my $self = shift;
	$self->_close('idle') if !$self->{want} && $self->{state} ne 'off';
}

sub _ping {
	my $self = shift;
	return unless $self->{state} eq 'up';
	if (time - $self->{last_rx} > DEAD_AFTER) {
		$self->_failed('no heartbeat');
		return;
	}
	$self->_send('receiver-0', Plugins::CastNowPlaying::Proto::NS_HB, { type => 'PING' });
	Slim::Utils::Timers::setTimer($self, Time::HiRes::time() + PING_EVERY, \&_ping);
}

# ---------------------------------------------------------------- I/O

sub _send {
	my ($self, $dst, $ns, $obj) = @_;
	return unless $self->{state} eq 'up';
	$obj->{requestId} //= $self->{req}++
		unless $ns eq Plugins::CastNowPlaying::Proto::NS_CONN || $ns eq Plugins::CastNowPlaying::Proto::NS_HB;
	$self->{wbuf} .= Plugins::CastNowPlaying::Proto::encode(SENDER, $dst, $ns, $JSON->encode($obj));
	$self->_flush;
}

sub _flush {
	my $self = shift;
	my $sock = $self->{sock} or return;
	while (length $self->{wbuf}) {
		my $n = syswrite($sock, $self->{wbuf}, 16384);
		if (defined $n && $n > 0) {
			substr($self->{wbuf}, 0, $n) = '';
			next;
		}
		if ($SSL_ERROR == SSL_WANT_WRITE || $SSL_ERROR == SSL_WANT_READ || $!{EAGAIN}) {
			Slim::Networking::Select::addWrite($sock, sub {
				Slim::Networking::Select::removeWrite($sock);
				$self->_flush;
			});
			return;
		}
		$self->_failed('write error');
		return;
	}
}

sub _read {
	my $self = shift;
	my $sock = $self->{sock} or return;
	while (1) {
		my $n = sysread($sock, my $chunk, 65536);
		if (defined $n && $n > 0) {
			$self->{rbuf} .= $chunk;
			next if $sock->pending;
			last;
		}
		if (defined $n && $n == 0) { $self->_failed('closed by device'); return }
		last if $SSL_ERROR == SSL_WANT_READ || $SSL_ERROR == SSL_WANT_WRITE || $!{EAGAIN};
		$self->_failed("read error: $!");
		return;
	}
	$self->{last_rx} = time;
	my @msgs = eval { Plugins::CastNowPlaying::Proto::take_messages(\$self->{rbuf}) };
	if ($@) { $self->_failed("protocol: $@"); return }
	for my $m (@msgs) {
		my $d = eval { JSON::PP->new->utf8->decode($m->{data}) } || {};
		$self->_on_message($m, $d);
		return unless $self->{sock};
	}
}

# ---------------------------------------------------------------- receiver logic

sub _get_status {
	my $self = shift;
	$self->_send('receiver-0', Plugins::CastNowPlaying::Proto::NS_RECEIVER, { type => 'GET_STATUS' });
}

sub _on_message {
	my ($self, $m, $d) = @_;
	my $type = $d->{type} // '';

	if ($m->{ns} eq Plugins::CastNowPlaying::Proto::NS_HB) {
		$self->_send($m->{src}, Plugins::CastNowPlaying::Proto::NS_HB, { type => 'PONG' }) if $type eq 'PING';
		return;
	}
	if ($m->{ns} eq Plugins::CastNowPlaying::Proto::NS_CONN && $type eq 'CLOSE') {
		if ($m->{src} eq 'receiver-0') { $self->_failed('device closed connection'); return }
		if ($self->{transport} && $m->{src} eq $self->{transport}) { $self->{transport} = undef }
		return;
	}
	return unless $m->{ns} eq Plugins::CastNowPlaying::Proto::NS_RECEIVER;

	if ($type eq 'RECEIVER_STATUS') {
		$self->_on_status($d->{status} || {});
	}
	elsif ($type eq 'LAUNCH_ERROR') {
		$self->{launching} = 0;
		$self->{yielded} = 1;    # do not hammer the device; try again after playback restarts
		$self->{status} = 'launch failed: ' . ($d->{reason} // '?');
		$log->warn("$self->{name}: launch failed ($d->{reason})");
	}
}

sub _on_status {
	my ($self, $st) = @_;
	my @apps = @{ $st->{applications} || [] };
	my ($ours) = grep { ($_->{appId} // '') eq APP_ID } @apps;
	# Android TV lists the native app that holds a media session as "AndroidNativeApp", even when it
	# runs in the background (e.g. VLC paused days ago while the cable TV app is on screen): that does
	# not mean the screen is taken. Only another Cast app (someone casting to the TV) does.
	my @others = grep { my $id = $_->{appId} // ''; $id ne APP_ID && $id ne 'AndroidNativeApp' && !$_->{isIdleScreen} } @apps;

	if ($ours) {
		$self->{launching} = 0;
		$self->{session} = $ours->{sessionId};
		if (($self->{transport} // '') ne $ours->{transportId}) {
			$self->{transport} = $ours->{transportId};
			$self->_send($self->{transport}, Plugins::CastNowPlaying::Proto::NS_CONN, { type => 'CONNECT' });
			main::INFOLOG && $log->is_info && $log->info("$self->{name}: receiver running");
		}
		$self->{status} = 'showing';
		if ($self->{want}) { $self->_send_np }
		else {
			$self->_send('receiver-0', Plugins::CastNowPlaying::Proto::NS_RECEIVER, { type => 'STOP', sessionId => $self->{session} });
		}
		return;
	}

	# our receiver is not running
	if ($self->{transport}) {
		main::INFOLOG && $log->is_info && $log->info("$self->{name}: receiver closed" . (@others ? " by $others[0]{displayName}" : ''));
		$self->{transport} = $self->{session} = undef;
		# closed while we wanted it shown (another app, or the user opened something on the TV):
		# do not take the screen back until playback is started again. A TV that went to standby
		# or another input gets the screen back when it returns (handled below).
		my $away = $st->{isStandBy} || (defined $st->{isActiveInput} && !$st->{isActiveInput});
		$self->{yielded} = 1 if @others || ($self->{want} && !$away);
	}
	if (@others) {
		$self->{status} = 'screen busy: ' . ($others[0]{displayName} // $others[0]{appId});
		$self->{yielded} = 1 if $self->{want};
		return;
	}
	# never wake the TV or switch its input: wait until the user turns to this device
	if ($st->{isStandBy} || (defined $st->{isActiveInput} && !$st->{isActiveInput})) {
		$self->{status} = $st->{isStandBy} ? 'standby' : 'other input';
		return;
	}
	$self->{status} = 'connected';
	if ($self->{want} && !$self->{yielded} && !$self->{launching}) {
		$self->{launching} = 1;
		$self->{status} = 'launching';
		main::INFOLOG && $log->is_info && $log->info("$self->{name}: launching receiver");
		$self->_send('receiver-0', Plugins::CastNowPlaying::Proto::NS_RECEIVER, { type => 'LAUNCH', appId => APP_ID });
	}
}

sub _send_np {
	my $self = shift;
	return unless $self->{transport} && $self->{msg};
	$self->_send($self->{transport}, Plugins::CastNowPlaying::Proto::NS_NP, { %{ $self->{msg} } });
}

1;

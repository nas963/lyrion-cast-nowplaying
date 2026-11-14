#!/usr/bin/perl
# perl -Isrc/.. tests/proto.t  (run from repo root: perl -I. tests/proto.t with src linked as Plugins)
use strict;
use warnings;
use Test::More;
use FindBin;


use Plugins::CastNowPlaying::Proto;
use Plugins::CastNowPlaying::MDNS;

# --- framing round trip, two frames + a partial one in the buffer
my $f1 = Plugins::CastNowPlaying::Proto::encode('sender-0', 'receiver-0', Plugins::CastNowPlaying::Proto::NS_CONN, '{"type":"CONNECT"}');
my $f2 = Plugins::CastNowPlaying::Proto::encode('a', 'b', 'urn:x', "{\"t\":\"\x{2022} \x{0161}\"}");
my $buf = $f1 . $f2 . substr($f1, 0, 7);
my @m = Plugins::CastNowPlaying::Proto::take_messages(\$buf);
is(scalar @m, 2, 'two complete frames');
is($m[0]{src}, 'sender-0', 'source');
is($m[0]{dst}, 'receiver-0', 'destination');
is($m[0]{ns}, Plugins::CastNowPlaying::Proto::NS_CONN, 'namespace');
is($m[0]{data}, '{"type":"CONNECT"}', 'payload');
my $p = $m[1]{data};
utf8::decode($p);
is($p, "{\"t\":\"\x{2022} \x{0161}\"}", 'utf8 payload');
is(length $buf, 7, 'partial frame stays in buffer');

# --- long payload (multi-byte varint length)
my $long = 'x' x 70000;
my $b2 = Plugins::CastNowPlaying::Proto::encode('s', 'd', 'n', $long);
my ($lm) = Plugins::CastNowPlaying::Proto::take_messages(\$b2);
is(length $lm->{data}, 70000, 'long payload');

# --- mDNS: query and a synthetic response
my $q = Plugins::CastNowPlaying::MDNS::query_packet();
like($q, qr/_googlecast\x04_tcp\x05local\x00/, 'query has service name');

sub lbl { join('', map { chr(length $_) . $_ } split /\./, shift) . "\0" }
my $inst = 'Yettel-abc._googlecast._tcp.local';
my $host = 'abc.local';
my $txt = join '', map { chr(length $_) . $_ } 'id=abc123', 'fn=Yettel TV Box', 'md=MediaBox', 'ca=266757';
my $srv = pack('nnn', 0, 0, 8009) . lbl($host);
my $pkt = pack('n6', 0, 0x8400, 0, 1, 0, 3)
	. lbl('_googlecast._tcp.local') . pack('nnNn', 12, 1, 120, length lbl($inst)) . lbl($inst)
	. lbl($inst) . pack('nnNn', 16, 0x8001, 120, length $txt) . $txt
	. lbl($inst) . pack('nnNn', 33, 0x8001, 120, length $srv) . $srv
	. lbl($host) . pack('nnNn', 1, 0x8001, 120, 4) . pack('C4', 192, 168, 1, 103);
my @d = Plugins::CastNowPlaying::MDNS::parse($pkt, '10.0.0.1');
is(scalar @d, 1, 'one device');
is($d[0]{id}, 'abc123', 'id');
is($d[0]{name}, 'Yettel TV Box', 'friendly name');
is($d[0]{ip}, '192.168.1.103', 'ip from A record');
is($d[0]{port}, 8009, 'port from SRV');
ok(Plugins::CastNowPlaying::MDNS::has_display($d[0]{ca}), 'box has a screen');
ok(!Plugins::CastNowPlaying::MDNS::has_display(199172), 'Chromecast Audio has no screen');
is(scalar Plugins::CastNowPlaying::MDNS::parse('garbage', '1.2.3.4'), 0, 'garbage ignored');

done_testing;

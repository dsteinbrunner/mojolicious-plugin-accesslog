#!/usr/bin/env perl

use Mojo::Base -strict;

# Disable IPv6 and libev
BEGIN {
    $ENV{MOJO_NO_IPV6} = 1;
    $ENV{MOJO_REACTOR} = 'Mojo::Reactor::Poll';
}

use Test::More;

use Mojo::Util qw(b64_encode);
use Mojolicious::Lite;
use Test::Mojo;

# Logger
my $log = '';
open my $fh, '>>:scalar', \$log or die;

# redirect all logging to $log
app->log->handle($fh);

# disable log output written with Mojo::Log methods
app->log->unsubscribe('message');

plugin 'AccessLog', format => 'combinedio';

my $shortpoll_nolength;
get '/dynamic' => sub {
    my $c = shift;

    $c->on(finish => sub { $shortpoll_nolength = 'finished!' });
    $c->res->code(200);
    $c->res->headers->content_type('text/plain');

    $c->write_chunk('He' => sub {
        my $c = shift;

        $c->write_chunk('ll' => sub {
            my $c = shift;

            $c->finish('o!');
        });
    });
};

any '/:any' => sub {
    my $c = shift;

    $c->res->headers->content_type('text/plain');
    $c->render(text => 'done')
};

my $t = Test::Mojo->new;

sub req_ok {
    my ($method, $url, $code, $opts) = @_;
    my $m = $t->can($method . '_ok')
        or return fail "Cannot $method $url";
    my $user = '-';
    my $query = '';
    my $pos;

    $opts = {} unless ref $opts eq 'HASH';

    if (index($url, '@') > -1) {
        ($user, $url) = split '@', $url, 2;
        $opts->{Authorization} = 'Basic ' . b64_encode($user . ':pass', '');
        $user =~ s/([^[:print:]]|\s)/'\x' . unpack('H*', $1)/eg;
    }
    elsif ($ENV{REMOTE_USER}) {
        $user = $ENV{REMOTE_USER};
        $user =~ s/([^[:print:]]|\s)/'\x' . unpack('H*', $1)/eg;
    }

    # issue request
    my $bcr = my $bcw = 0;
    my $start = $t->ua->on(start => sub {
        my ($ua, $tx) = @_;
        $tx->on(connection => sub {
            my ($tx, $connection) = @_;
            my $stream = Mojo::IOLoop->stream($connection);
            my $read   = $stream->on(read => sub {
                $bcw += length $_[1];
            });
            my $write = $stream->on(write => sub {
                $bcr += length $_[1];
            });
            $tx->on(finish => sub {
                $stream->unsubscribe(read  => $read);
                $stream->unsubscribe(write => $write);
            });
        });
    });

    my $res = $m->($t, $url . $query, $opts)
        ->status_is($code)
        ->tx->res;
    $t->ua->unsubscribe(start => $start);

    my $x = sprintf qq'^%s - %s %s "%s %s HTTP/1.1" %d %s "%s" "%s" %s %d\$',
        '127\.0\.0\.1',
        quotemeta($user),
        '\[\d{1,2}/\w{3}/\d{4}:\d{2}:\d{2}:\d{2} [\+\-]\d{4}\]',
        uc($method),
        quotemeta($url),
        $code,
        $opts->{nolength} ? '-' :'\d+',
        $opts->{Referer} ? quotemeta($opts->{Referer}) : '-',
        quotemeta('Mojolicious (Perl)'),
        $bcr,
        $bcw;

    # check last log line
    my ($l) = (split $/, $log)[-1];
    like $l, qr{$x}, $l;
}

req_ok(get => '/' => 404, {Referer => 'http://www.example.com/'});
req_ok(post => '/a_letter' => 200, {Referer => '/'});
req_ok(put => '/option' => 200);
{
    local $ENV{REMOTE_USER} = 'good boy';
    req_ok(get => "3v!l b0y\ntoy\@/more?foo=bar&foo=baz" => 200);
    req_ok(get => "/more?foo=bar&foo=baz" => 200);
}
req_ok(delete => '/fb_account' => 200, {Referer => '/are_you_sure?'});
req_ok(get => '/dynamic' => 200, {nolength => 1});

done_testing;

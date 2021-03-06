package FusionInventory::Agent::HTTP::Server;

use strict;
use warnings;

use English qw(-no_match_vars);
use File::Basename;
use HTTP::Daemon;
use IO::Handle;
use Net::IP;
use Text::Template;
use File::Glob;
use URI;

use FusionInventory::Agent::Logger;
use FusionInventory::Agent::Tools::Network;

my $log_prefix = "[http server] ";

sub new {
    my ($class, %params) = @_;

    my $self = {
        logger    => $params{logger} ||
                     FusionInventory::Agent::Logger->new(),
        agent     => $params{agent},
        htmldir   => $params{htmldir},
        ip        => $params{ip},
        port      => $params{port} || 62354,
    };
    bless $self, $class;

    # compute addresses allowed for push requests
    foreach my $target ($self->{agent}->getTargets()) {
        next unless $target->isa('FusionInventory::Agent::Target::Server');
        my $url  = $target->getUrl();
        my $host = URI->new($url)->host();
        my @addresses = compile($host, $self->{logger});
        $self->{trust}->{$url} = \@addresses;
    }
    if ($params{trust}) {
        foreach my $string (@{$params{trust}}) {
            my @addresses = compile($string);
            $self->{trust}->{$string} = \@addresses if @addresses;
        }
    }

    return $self;
}

sub _handle {
    my ($self, $client, $request, $clientIp) = @_;

    my $logger = $self->{logger};

    if (!$request) {
        $client->close();
        return;
    }

    my $path = $request->uri()->path();
    $logger->debug($log_prefix . "request $path from client $clientIp");

    # non-GET requests
    my $method = $request->method();
    if ($method ne 'GET') {
        $logger->debug($log_prefix . "error, invalid request type: $method");
        $client->send_error(400);
        $client->close;
        undef($client);
        return;
    }

    # GET requests
    SWITCH: {
        # root request
        if ($path eq '/') {
            $self->_handle_root($client, $request, $clientIp);
            last SWITCH;
        }

        # deploy request
        if ($path =~ m{^/deploy/getFile/./../([\w\d/-]+)$}) {
            $self->_handle_deploy($client, $request, $clientIp, $1);
            last SWITCH;
        }

        # now request
        if ($path =~ m{^/now(?:/(\S*))?$}) {
            $self->_handle_now($client, $request, $clientIp, $1);
            last SWITCH;
        }

        # status request
        if ($path eq '/status') {
            $self->_handle_status($client, $request, $clientIp);
            last SWITCH;
        }

        # static content request
        if ($path =~ m{^/(logo.png|site.css|favicon.ico)$}) {
            my $file = $1;
            $client->send_file_response("$self->{htmldir}/$file");
            last SWITCH;
        }

        $logger->debug("error, unknown path: $path");
        $client->send_error(400);
    }

    $client->close();
}

sub _handle_root {
    my ($self, $client, $request, $clientIp) = @_;

    my $logger = $self->{logger};

    my $template = Text::Template->new(
        TYPE => 'FILE', SOURCE => "$self->{htmldir}/index.tpl"
    );
    if (!$template) {
        $logger->error($log_prefix . "Template access failed: $Text::Template::ERROR");
        ;

        my $response = HTTP::Response->new(
            500,
            'KO',
            HTTP::Headers->new('Content-Type' => 'text/html'),
            "No template"
        );

        $client->send_response($response);
        return;
    }

    my @server_targets =
        map { { name => $_->getUrl(), date => $_->getFormatedNextRunDate() } }
        grep { $_->isa('FusionInventory::Agent::Target::Server') }
        $self->{agent}->getTargets();

    my @local_targets =
        map { { name => $_->getPath(), date => $_->getFormatedNextRunDate() } }
        grep { $_->isa('FusionInventory::Agent::Target::Local') }
        $self->{agent}->getTargets();

    my $hash = {
        version        => $FusionInventory::Agent::VERSION,
        trust          => $self->_isTrusted($clientIp),
        status         => $self->{agent}->getStatus(),
        server_targets => \@server_targets,
        local_targets  => \@local_targets
    };

    my $response = HTTP::Response->new(
        200,
        'OK',
        HTTP::Headers->new('Content-Type' => 'text/html'),
        $template->fill_in(HASH => $hash)
    );

    $client->send_response($response);
}

sub _handle_deploy {
    my ($self, $client, $request, $clientIp, $sha512) = @_;

    my $logger = $self->{logger};

    return unless $sha512 =~ /^(.)(.)(.{6})/;
    my $subFilePath = $1.'/'.$2.'/'.$3;

    Digest::SHA->require();

    my $path;
    LOOP: foreach my $target ($self->{agent}->getTargets()) {
        foreach (File::Glob::glob($target->{storage}->getDirectory() . "/deploy/fileparts/shared/*")) {
            next unless -f $_.'/'.$subFilePath;

            my $sha = Digest::SHA->new('512');
            $sha->addfile($_.'/'.$subFilePath, 'b');
            next unless $sha->hexdigest eq $sha512;

            $path = $_.'/'.$subFilePath;
            last LOOP;
        }
    }
    if ($path) {
        $logger->debug($log_prefix . "file $sha512 found");
        $client->send_file_response($path);
        $logger->debug($log_prefix . "file $path sent");
    } else {
        $client->send_error(404);
    }
}

sub _handle_now {
    my ($self, $client, $request, $clientIp) = @_;

    my $logger = $self->{logger};

    my ($code, $message, $trace);

    BLOCK: {
        foreach my $target ($self->{agent}->getTargets()) {
            next unless $target->isa('FusionInventory::Agent::Target::Server');
            my $url       = $target->getUrl();
            my $addresses = $self->{trust}->{$url};
            next unless isPartOf($clientIp, $addresses, $logger);
            $target->setNextRunDate(1);
            $code    = 200;
            $message = "OK";
            $trace   = "rescheduling next contact for target $url right now";
            last BLOCK;
        }

        if ($self->_isTrusted($clientIp)) {
            foreach my $target ($self->{agent}->getTargets()) {
                $target->setNextRunDate(1);
            }
            $code    = 200;
            $message = "OK";
            $trace   = "rescheduling next contact for all targets right now";
            last BLOCK;
        }

        $code    = 403;
        $message = "Access denied";
        $trace   = "invalid request (untrusted address)";
    }

    my $template = Text::Template->new(
        TYPE => 'FILE', SOURCE => "$self->{htmldir}/now.tpl"
    );

    my $hash = {
        message => $message
    };

    my $response = HTTP::Response->new(
        $code,
        'OK',
        HTTP::Headers->new('Content-Type' => 'text/html'),
        $template->fill_in(HASH => $hash)
    );

    $client->send_response($response);
    $logger->debug($log_prefix . $trace);
}

sub _handle_status {
    my ($self, $client, $request, $clientIp) = @_;

    my $status = $self->{agent}->getStatus();
    my $response = HTTP::Response->new(
        200,
        'OK',
        HTTP::Headers->new('Content-Type' => 'text/plain'),
       "status: ".$status
    );
    $client->send_response($response);
}

sub _isTrusted {
    my ($self, $address) = @_;

    foreach my $trusted_addresses (values %{$self->{trust}}) {
        return 1
            if isPartOf(
                $address,
                $trusted_addresses,
                $self->{logger}
            );
    }

    return 0;
}

sub init {
    my ($self) = @_;

    my $logger = $self->{logger};

    $self->{listener} = HTTP::Daemon->new(
        LocalAddr => $self->{ip},
        LocalPort => $self->{port},
        Reuse     => 1,
        Timeout   => 5
    );

    if (!$self->{listener}) {
        $logger->error($log_prefix . "failed to start the HTTPD service");
        return;
    }

    my $url = $self->{ip} ?
        "http://$self->{ip}:$self->{port}" :
        "http://localhost:$self->{port}" ;

    $logger->info($log_prefix . "HTTPD service started at $url");
}

sub handleRequests {
    my ($self) = @_;

    return unless $self->{listener}; # init() call failed

    my ($client, $socket) = $self->{listener}->accept();
    return unless $socket;

    my (undef, $iaddr) = sockaddr_in($socket);
    my $clientIp = inet_ntoa($iaddr);
    my $request = $client->get_request();
    $self->_handle($client, $request, $clientIp);
}

1;
__END__

=head1 NAME

FusionInventory::Agent::HTTP:Server - An embedded HTTP server

=head1 DESCRIPTION

This is the server used by the agent to listen on the network for messages sent
by OCS or GLPI servers.

It is an HTTP server listening on port 62354 (by default). The following
requests are accepted:

=over

=item /status

=item /deploy

=item /now

=back

Authentication is based on connection source address: trusted requests are
accepted, other are rejected.

=head1 CLASS METHODS

=head2 new(%params)

The constructor. The following parameters are allowed, as keys of the %params
hash:

=over

=item I<logger>

the logger object to use

=item I<htmldir>

the directory where HTML templates and static files are stored

=item I<ip>

the network address to listen to (default: all)

=item I<port>

the network port to listen to

=item I<trust>

an IP address or an IP address range from which to trust incoming requests
(default: none)

=back

=head1 INSTANCE METHODS

=head2 $server->init()

Start the server internal listener.

=head2 $server->handleRequests()

Check if there any incoming request, and honours it if needed.

#   Copyright (C) 2012 Erland Isaksson (erland@isaksson.info)
#   All rights reserved.
package Plugins::IckStreamPlugin::Server;

use strict;
use warnings;

use Tie::Cache::LRU;
use File::Spec::Functions;
use JSON::XS::VersionOneAndTwo;

use Slim::Utils::Log;
use Slim::Utils::Prefs;

my $log = logger('plugin.ickstream');
my $prefs  = preferences('plugin.ickstream');
my $sprefs = preferences('server');

my $server;

sub start {
	my ($class, $plugin) = @_;

	my $serverPath = Plugins::IckStreamPlugin::Plugin->jars(qr/^ickHttpServiceWrapper/);

	if ($serverPath) {

		$log->debug("server binary: $serverPath");

	} else {

		$log->error("can't find server binary");
		return;
	}

	my $serverLog = catdir(Slim::Utils::OSDetect::dirsFor('log'), 'ickstream.log');

	my @opts = (
		"-Dcom.ickstream.common.ickservice.daemon=true",
		"-Dcom.ickstream.common.ickservice.stdout=$serverLog",
		"-Dcom.ickstream.common.ickservice.stderr=$serverLog",
	);
	if($log->is_debug) {
		push @opts,"-Dcom.ickstream.common.ickservice.debug=true";
	}

	my $endpoint;
	if ($sprefs->get('authorize')) {
		$endpoint = "http://".$sprefs->get('username').":".sprefs->get('password')."\@localhost:".$sprefs->{'httpport'}."/plugins/IckStreamPlugin/jsonrpc";
	}else {
		$endpoint = "http://localhost:".$sprefs->get('httpport')."/plugins/IckStreamPlugin/jsonrpc";
	}

	my $serverName = $sprefs->get('libraryname');
	if(!defined($serverName) || $serverName eq '') {
		$serverName = Slim::Utils::Network::hostName();
	}
	my $serverUUID = uc($sprefs->get('server_uuid'));
	
	# use server to search for java and convert to short path if windows
	my $javaPath = Slim::Utils::Misc::findbin("java");
	$javaPath = Slim::Utils::OSDetect::getOS->decodeExternalHelperPath($javaPath);

	# fallback to Proc::Background finding java
	$javaPath ||= "java";

	my @cmd = ($javaPath, @opts, "-jar", "$serverPath", $serverUUID, $serverName, $endpoint);

	$log->info("Starting server");

	$log->debug("cmdline: ", join(' ', @cmd));

	$server = Proc::Background->new({'die_upon_destroy' => 1}, @cmd);

	if (!$class->running) {
		$log->error("Unable to launch server");
	}
}

sub stop {
	my $class = shift;

	if ($class->running) {
		$log->info("stopping server");
		$server->die;
	}
}

sub running {
	return $server && $server->alive;
}

1;

# Copyright (c) 2013, ickStream GmbH
# All rights reserved.
# 
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#     * Redistributions of source code must retain the above copyright
#       notice, this list of conditions and the following disclaimer.
#     * Redistributions in binary form must reproduce the above copyright
#       notice, this list of conditions and the following disclaimer in the
#       documentation and/or other materials provided with the distribution.
#     * Neither the name of ickStream nor the
#       names of its contributors may be used to endorse or promote products
#       derived from this software without specific prior written permission.
# 
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
# WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL LOGITECH, INC BE LIABLE FOR ANY
# DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
# (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
# LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
# ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
# SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

package Plugins::IckStreamPlugin::Server;

use strict;
use warnings;

use Tie::Cache::LRU;
use File::Spec::Functions;
use JSON::XS::VersionOneAndTwo;
use UUID::Tiny;

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
	my $serverUUID = $prefs->get('uuid');
	if(!defined($serverUUID)) {
		$serverUUID = uc(UUID::Tiny::create_UUID_as_string( UUID::Tiny::UUID_V4() ));
		$prefs->set('uuid',$serverUUID);
	}
	
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

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

package Plugins::IckStreamPlugin::ContentAccessServer;

use strict;
use warnings;

use Tie::Cache::LRU;
use File::Spec::Functions;
use JSON::XS::VersionOneAndTwo;
use UUID::Tiny;
use MIME::Base64;

use Slim::Utils::Log;
use Slim::Utils::Prefs;

my $log = Slim::Utils::Log->addLogCategory({
	'category'     => 'plugin.ickstream.content',
	'defaultLevel' => 'WARN',
	'description'  => 'PLUGIN_ICKSTREAM_CONTENT_LOG',
});
my $prefs  = preferences('plugin.ickstream');
my $sprefs = preferences('server');

my $server;
my $serverChecker = undef;
my $PLUGIN;

my $binaries;

sub binaries {
	my ($class, $re) = @_;

	$binaries || do {

		my $basedir = $class->_pluginDataFor('basedir');
		my @dirs = ($basedir);
		
		for my $dir (@dirs) {
			for my $file (Slim::Utils::Misc::readDirectory($dir,qr/ickHttpWrapperDaemon-/)) {
				my $path = catdir($dir, $file);{
					if (-f $path && -r $path) {
						$binaries->{ $file } = $path;
					}
				}
			}
		}
	};

	for my $key (keys %$binaries) {
	use Slim::Utils::Misc;
		if ($key =~ $re) {
			return ($key, $binaries->{$key});
		}
	}
	return (undef,undef);
}

sub start {
	my ($class, $plugin) = @_;
	$PLUGIN = $plugin;
	my $archname = $Config::Config{'archname'};
	my $myarchname = $Config::Config{'myarchname'};
	my $lddlflags = $Config::Config{'lddlflags'};
    my $daemon = qr/^ickHttpWrapperDaemon$/;
    if ($archname =~ /x86_64/) {
        $daemon = qr/^ickHttpWrapperDaemon\-x86_64$/;
    }elsif ($archname =~ /darwin/) {
        $daemon = qr/^ickHttpWrapperDaemon\-x86_64$/;
    }elsif ($archname =~  /arm\-linux\-gnueabihf\-/) {
        $daemon = qr/^ickHttpWrapperDaemon\-arm\-linux\-gnueabihf$/;
    }elsif ($archname =~  /arm\-linux\-gnueabi\-/ || $myarchname =~  /armv5tel/) {
        $daemon = qr/^ickHttpWrapperDaemon\-arm\-linux\-gnueabi$/;
    }elsif ($archname =~  /arm\-linux\-/) {
        if ($lddlflags =~  /\-mfloat-abi=hard/) {
            $daemon = qr/^ickHttpWrapperDaemon\-arm\-linux\-gnueabihf$/;
        }else {
            $daemon = qr/^ickHttpWrapperDaemon\-arm\-linux\-gnueabi$/;
        }
    }elsif (Slim::Utils::OSDetect::isLinux()) {
    	if ($lddlflags =~ /arm\-/ && ($lddlflags =~ /\-linux\-gnueabihf/ || ($lddlflags =~ /\-linux\-gnueabi/ && $lddlflags =~ /\-mfloat-abi=hard/))) {
            $daemon = qr/^ickHttpWrapperDaemon\-arm\-linux\-gnueabihf$/;
    	}elsif($lddlflags =~ /arm\-/ && $lddlflags =~  /\-linux\-gnueabi/) {
            $daemon = qr/^ickHttpWrapperDaemon\-arm\-linux\-gnueabi$/;
    	}elsif($archname =~  /armle\-linux/) {
            $daemon = qr/^ickHttpWrapperDaemon\-arm\-linux\-gnueabi$/;
    	}else {
	        $daemon = qr/^ickHttpWrapperDaemon\-x86$/;
    	}
    }else {
        $daemon = qr/^ickHttpWrapperDaemon\-x86$/;
    }

	my $serverPath = binaries($plugin, $daemon);

	if ($serverPath) {

		$log->debug("daemon binary: $serverPath");

	} else {

		$log->error("can't find daemon binary: $daemon");
		return;
	}

	my $serverLog = catdir(Slim::Utils::OSDetect::dirsFor('log'), 'ickstream.log');
	if(!$log->is_debug()) {
	    $serverLog = catdir("/dev/null");
	}
	$log->debug("Logging daemon output to: $serverLog");

	my $endpoint = "http://localhost:".$sprefs->get('httpport')."/plugins/IckStreamPlugin/ContentAccessService/jsonrpc";
	$log->debug("Using LMS at: $endpoint");

	my $authorization = undef;
	if ($sprefs->get('authorize')) {
		$log->debug("Calculating authorization token");
		$authorization = MIME::Base64::encode($sprefs->get('username').":".$sprefs->get('password'),'');
		$log->debug("Calculated authorization token");
	}

	my $serverName = $sprefs->get('libraryname');
	if(!defined($serverName) || $serverName eq '') {
		$serverName = Slim::Utils::Network::hostName();
	}
	$log->debug("With name: $serverName");

	my $serverUUID = $prefs->get('uuid');
	if(!defined($serverUUID)) {
		$log->debug("No ickStream id created, creating a new one...");
		$serverUUID = uc(UUID::Tiny::create_UUID_as_string( UUID::Tiny::UUID_V4() ));
		$prefs->set('uuid',$serverUUID);
	}
	$log->debug("Using ickStream identity: $serverUUID");

    my $serverIP = Slim::Utils::IPDetect::IP();
    if(!$serverIP) {
        $log->error("Can't detect IP address");
        return;
    }
	$log->debug("Local IP-address: $serverIP");

	my @cmd = ($serverPath, $serverIP, $serverUUID, $serverName, $endpoint, $serverLog);
	$log->info("Starting server");

	$log->debug("cmdline: ", join(' ', @cmd));

	if(defined($authorization)) {
		$log->debug("Adding authorization token");
		push @cmd,$authorization;
	}

	if(defined($serverChecker)) {
		Slim::Utils::Timers::killSpecific($serverChecker);
		$serverChecker = undef;
	}
	$server = Proc::Background->new({'die_upon_destroy' => 1}, @cmd);

	if (!$class->running) {
		$log->error("Unable to launch server");
	}else {
		$log->info("Successfully launched server");
		$serverChecker = Slim::Utils::Timers::setTimer($class, Time::HiRes::time()+15,\&checkAlive);
	}
}

sub checkAlive {
	my $class = shift;
	if($server && !$server->alive) {
		$log->warn("ickHttpWrapperDaemon daemon has died, restarting...");
		$class->start($PLUGIN);
	}
	$serverChecker = Slim::Utils::Timers::setTimer($class, Time::HiRes::time()+15, \&checkAlive);
}

sub stop {
	my $class = shift;

	if ($class->running) {
		if(defined($serverChecker)) {
			Slim::Utils::Timers::killSpecific($serverChecker);
			$serverChecker = undef;
		}
		$log->info("stopping server");
		$server->die;
	}
}

sub running {
	return $server && $server->alive;
}

1;

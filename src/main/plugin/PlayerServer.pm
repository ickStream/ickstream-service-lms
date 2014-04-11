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

package Plugins::IckStreamPlugin::PlayerServer;

use strict;
use warnings;

use Tie::Cache::LRU;
use File::Spec::Functions;
use JSON::XS::VersionOneAndTwo;
use UUID::Tiny;
use MIME::Base64;

use Slim::Utils::Log;
use Slim::Utils::Prefs;

use Plugins::IckStreamPlugin::PlayerManager;

my $log = logger('plugin.ickstream');
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
			for my $file (Slim::Utils::Misc::readDirectory($dir,qr/ickHttpSqueezeboxPlayerDaemon-/)) {
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
    my $daemon = qr/^ickHttpSqueezeboxPlayerDaemon$/;
    if ($Config::Config{'archname'} =~ /x86_64/) {
        $daemon = qr/^ickHttpSqueezeboxPlayerDaemon\-x86_64$/;
    }elsif ($Config::Config{'archname'} =~ /darwin/) {
        $daemon = qr/^ickHttpSqueezeboxPlayerDaemon\-x86_64$/;
    }elsif ($Config::Config{'archname'} =~  /arm\-linux\-gnueabihf\-/) {
        $daemon = qr/^ickHttpSqueezeboxPlayerDaemon\-arm\-linux\-gnueabihf$/;
    }elsif ($Config::Config{'archname'} =~  /arm\-linux\-gnueabi\-/ || $Config::Config{'myarchname'} =~  /armv5tel/) {
        $daemon = qr/^ickHttpSqueezeboxPlayerDaemon\-arm\-linux\-gnueabi$/;
    }elsif ($Config::Config{'archname'} =~  /arm\-linux\-/) {
        if ($Config::Config{'lddlflags'} =~  /\-mfloat-abi=hard/) {
            $daemon = qr/^ickHttpSqueezeboxPlayerDaemon\-arm\-linux\-gnueabihf$/;
        }else {
            $daemon = qr/^ickHttpSqueezeboxPlayerDaemon\-arm\-linux\-gnueabi$/;
        }
    }else {
        $daemon = qr/^ickHttpSqueezeboxPlayerDaemon\-x86$/;
    }

	my $serverPath = binaries($plugin, $daemon);

	if ($serverPath) {

		$log->debug("daemon binary: $serverPath");

	} else {

		$log->error("can't find daemon binary: $daemon");
		return;
	}

	my $serverLog = catdir(Slim::Utils::OSDetect::dirsFor('log'), 'ickstreamplayer.log');
	if(!$log->is_debug()) {
	    $serverLog = catdir("/dev/null");
	}
	$log->debug("Logging daemon output to: $serverLog");

	my $endpoint = "http://localhost:".$sprefs->get('httpport')."/plugins/IckStreamPlugin/PlayerService/jsonrpc";
	$log->debug("Using LMS at: $endpoint");

	my $authorization = undef;
	if ($sprefs->get('authorize')) {
		$log->debug("Calculating authorization token");
		$authorization = MIME::Base64::encode($sprefs->get('username').":".$sprefs->get('password'),'');
		$log->debug("Calculated authorization token");
	}

    my $serverIP = Slim::Utils::IPDetect::IP();
    if(!$serverIP) {
        $log->error("Can't detect IP address");
        return;
    }
	$log->debug("Local IP-address: $serverIP");
	my $daemonPort = $prefs->get('daemonPort');
	if(!$daemonPort) {
		$daemonPort = $sprefs->get('httpport')+6;
		$prefs->set('daemonPort',$daemonPort);
	}
	
	$log->debug("Using port $daemonPort for background daemon");

	my @cmd = ($serverPath, $serverIP, $daemonPort, $endpoint, "/plugins/IckStreamPlugin/discovery", $serverLog);
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
		Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + 3, \&Plugins::IckStreamPlugin::PlayerManager::start,$plugin);
	}
}

sub checkAlive {
	my $class = shift;
	if($server && !$server->alive) {
		$log->warn("ickHttpSqueezeboxPlayerDaemon daemon has died, restarting...");
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

# Copyright (c) 2014, ickStream GmbH
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

package Plugins::IckStreamPlugin::PlayerServiceCLI;

use strict;
use warnings;

use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Prefs;
use JSON::XS::VersionOneAndTwo;
use Data::Dumper;
use Storable qw(dclone);
use Plugins::IckStreamPlugin::Configuration;
use Plugins::IckStreamPlugin::PlayerService;

use Plugins::IckStreamPlugin::ItemCache;
use Plugins::IckStreamPlugin::PlaybackQueueManager;

my $log = Slim::Utils::Log->addLogCategory({
	'category'     => 'plugin.ickstream.player',
	'defaultLevel' => 'WARN',
	'description'  => 'PLUGIN_ICKSTREAM_PLAYER_LOG',
});
my $prefs = preferences('plugin.ickstream');
my $serverPrefs = preferences('server');

my $inProcessOfChangingPlaylist = {};
my $currentPlaylistWindowOffset = {};
my $nextTrackInstance = 1;

sub init {
	Slim::Control::Request::addDispatch(['ickstream','player','getPlayerConfiguration'], [1, 1, 0, \&getPlayerConfiguration]);
	Slim::Control::Request::addDispatch(['ickstream','player','setPlayerConfiguration'], [1, 0, 1, \&setPlayerConfiguration]);
}

sub setPlayerConfiguration {
		my $request = shift;
		my $client = $request->client();

		if(!defined $client) {
                $log->warn("Client required\n");
                $request->setStatusNeedsClient();
                return;
        }

		my $context = {
			'procedure' => {
				'params' => {}
			}
		};
		if(defined($request->getParam('playerName'))) {
			$context->{'procedure'}->{'params'}->{'playerName'} = $request->getParam('playerName');
		}
		if(defined($request->getParam('deviceRegistrationToken'))) {
			$context->{'procedure'}->{'params'}->{'deviceRegistrationToken'} = $request->getParam('deviceRegistrationToken');
		}
		if(defined($request->getParam('cloudCoreUrl'))) {
			$context->{'procedure'}->{'params'}->{'cloudCoreUrl'} = $request->getParam('cloudCoreUrl');
		}
		Plugins::IckStreamPlugin::PlayerService::setPlayerConfiguration($context, $client, sub {
			my $result = shift;
			foreach my $param (keys %$result) {
				$request->addResult($param, $result->{$param});
			}
			$request->setStatusDone();
		});
}

sub getPlayerConfiguration {
		my $request = shift;
		my $client = $request->client();

		if(!defined $client) {
                $log->warn("Client required\n");
                $request->setStatusNeedsClient();
                return;
        }

		my $context = {
			'procedure' => {
				'params' => {}
			}
		};
		Plugins::IckStreamPlugin::PlayerService::getPlayerConfiguration($context, $client, sub {
			my $result = shift;
			foreach my $param (keys %$result) {
				$request->addResult($param, $result->{$param});
			}
			$request->setStatusDone();
		});
}

1;

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

package Plugins::IckStreamPlugin::PlayerManager;

use strict;
use warnings;

use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Prefs;
use JSON::XS::VersionOneAndTwo;

my $log = logger('plugin.ickstream');
my $prefs = preferences('plugin.ickstream');
my $serverPrefs = preferences('server');

my $initializedPlayers = {};
my $initializedPlayerDaemon = undef;

sub start {
	$initializedPlayerDaemon = 1;
	$initializedPlayers = {};
	my @players = Slim::Player::Client::clients();
	foreach my $player (@players) {
		Plugins::IckStreamPlugin::PlayerManager::initializePlayer($player);
	}
}

sub playerChange {
        # These are the two passed parameters
        my $request=shift;
        my $player = $request->client();

		if(!$initializedPlayerDaemon) {
			return;
		}
		if(defined($player) && $request->isCommand([['client'],['new']]) || $request->isCommand([['client'],['reconnect']])) {
			$log->info("New or reconnected player: ".$player->name());
			initializePlayer($player);
		}elsif(defined($player) && $request->isCommand([['client'],['disconnect']])) {
			$log->info("Disconnected player: ".$player->name());
			uninitializePlayer($player);
		}
}

sub isPlayerInitialized {
	my $player = shift;
	
	return defined($initializedPlayers->{$player->id});
}

sub initializePlayer {
	my $player = shift;
	
	if(defined($player) && ($prefs->get('squeezePlayPlayersEnabled') || ($player->modelName() ne 'Squeezebox Touch' && $player->modelName() ne 'Squeezebox Radio'))) {
		if ( !defined($initializedPlayers->{$player->id}) ) {

			$log->debug("Initializing player: ".$player->name());
			my $params = { timeout => 35 };
			my $uuid = undef;
			my $playerConfiguration = $prefs->get('player_'.$player->id()) || {};
			if(defined($playerConfiguration->{'id'})) {
				$uuid = $playerConfiguration->{'id'};
			}else {
				$uuid = uc(UUID::Tiny::create_UUID_as_string( UUID::Tiny::UUID_V4() ));
			}
			$log->warn("Initializing ".$player->name()." (".$uuid.")");
			my $players = $prefs->get('players') || {};
			$players->{$uuid} = $player->id();
			$prefs->set('players',$players);
			$playerConfiguration->{'id'} = $uuid;
			$prefs->set('player_'.$player->id(), $playerConfiguration);
			if(!main::ISWINDOWS) {
			    my $serverIP = Slim::Utils::IPDetect::IP();
				Slim::Networking::SimpleAsyncHTTP->new(
					sub {
						$initializedPlayers->{$player->id()} = 1;
						$log->info("Successfully initialized ".$player->name());
						updateAddressOrRegisterPlayer($player);
					},
					sub {
						$initializedPlayers->{$player->id()} = undef;
						$log->warn("Error when initializing ".$player->name());
					},
					$params
				)->post("http://".$serverIP.":".$prefs->get('daemonPort')."/start",'Content-Type' => 'plain/text','Authorization'=>$uuid,$player->name());
			}else {
				updateAddressOrRegisterPlayer($player);
			}

		}
	}
}

sub uninitializePlayer {
	my $player = shift;
	
	if(defined($initializedPlayers->{$player->id})) {
		my $params = { timeout => 35 };
	    my $serverIP = Slim::Utils::IPDetect::IP();
	    my $playerConfiguration = $prefs->get('player_'.$player->id()) || {};
	    my $uuid = $playerConfiguration->{'id'};
		if(!main::ISWINDOWS) {
			Slim::Networking::SimpleAsyncHTTP->new(
				sub {
					$initializedPlayers->{$player->id()} = undef;
					$log->info("Successfully removed ".$player->name());
				},
				sub {
					my $http = shift;
					$initializedPlayers->{$player->id()} = undef;
					use Data::Dumper;
					$log->warn("Error when removing ".$player->name()." ".Dumper($http));
				},
				$params
			)->post("http://".$serverIP.":".$prefs->get('daemonPort')."/stop",'Content-Type' => 'plain/text','Authorization'=>$uuid,$player->name());
		}
	}
}

sub updateAddressOrRegisterPlayer {
	my $player = shift;
	
	my $playerConfiguration = $prefs->get('player_'.$player->id) || {};

	my $cloudCoreUrl = undef;
	if(defined($playerConfiguration->{'cloudCoreUrl'})) {
		$cloudCoreUrl = $playerConfiguration->{'cloudCoreUrl'};
	}else {
		$cloudCoreUrl = 'https://api.ickstream.com/ickstream-cloud-core/jsonrpc';
	}
	
	if(!defined($playerConfiguration->{'accessToken'})) {
		registerPlayer($cloudCoreUrl, $player);
	}else {
		if(!main::ISWINDOWS && !isPlayerInitialized($player)) {
			initializePlayer($player);
			return;
		}
		my $uuid = $playerConfiguration->{'uuid'};
		my $serverIP = Slim::Utils::IPDetect::IP();
		$log->debug("Trying to set player address in cloud to verify if its access token works");
		Slim::Networking::SimpleAsyncHTTP->new(
			sub {
				# Do nothing, player already registered
				$log->debug("Player ".$player->name()." is already registered, successfully updated address in cloud");
				Plugins::IckStreamPlugin::PlayerService::sendPlayerStatusChangedNotification($player);
			},
			sub {
				$log->warn("Failed to update address in cloud, player needs to be re-registered");
				registerPlayer($cloudCoreUrl, $player);
			},
			undef
			)->post($cloudCoreUrl,'Content-Type' => 'application/json','Authorization'=>'Bearer '.$playerConfiguration->{'accessToken'},to_json({
				'jsonrpc' => '2.0',
				'id' => 1,
				'method' => 'setDeviceAddress',
				'params' => {
					'deviceId' => $uuid,
					'address' => $serverIP
				}
			}));
	}
}

sub registerPlayer {
	my $cloudCoreUrl = shift;
	my $player = shift;
	
	my $controllerAccessToken = $prefs->get('accessToken');
	if(!defined($controllerAccessToken)) {
		$log->warn("Player(".$player->name().") must be manually registered since user is not logged in to ickStream Music Platform");
		return;
	}

	my $playerConfiguration = $prefs->get('player_'.$player->id) || {};
	my $uuid = undef;
	if(defined($playerConfiguration->{'id'})) {
		$uuid = $playerConfiguration->{'id'};
	}else {
		$uuid = uc(UUID::Tiny::create_UUID_as_string( UUID::Tiny::UUID_V4() ));
		$playerConfiguration->{'id'} = $uuid;
		$prefs->set('player_'.$player->id,$playerConfiguration);
	}

	$log->debug("Requesting device registration token");
	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $http = shift;
			my $jsonResponse = from_json($http->content);
			if(defined($jsonResponse->{'result'})) {
				$log->debug("Successfully got device registration token, now registering device: ".$player->name());
				Plugins::IckStreamPlugin::PlayerService::registerPlayer($player,$jsonResponse->{'result'});
			}
		},
		sub {
			$log->warn("Failed to create device registration token");
		},
		undef
		)->post($cloudCoreUrl,'Content-Type' => 'application/json','Authorization'=>'Bearer '.$controllerAccessToken,to_json({
			'jsonrpc' => '2.0',
			'id' => 1,
			'method' => 'createDeviceRegistrationToken',
			'params' => {
				'id' => $uuid,
				'name' => $player->name(),
				'applicationId' => 'C5589EF9-9C28-4556-942A-765E698215F1'
			}
		}));
}

1;
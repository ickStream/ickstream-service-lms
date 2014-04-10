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

package Plugins::IckStreamPlugin::PlayerService;

use strict;
use warnings;

use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Prefs;
use JSON::XS::VersionOneAndTwo;
use Data::Dumper;
use Storable qw(dclone);

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

# this array provides a function for each supported JSON method
my %methods = (
		'getProtocolVersions'	=> \&getProtocolVersions,
		'setPlayerConfiguration'	=> \&setPlayerConfiguration,
		'getPlayerConfiguration'	=> \&getPlayerConfiguration,
		'getPlayerStatus'	=> \&getPlayerStatus,
		'play'	=> \&play,
		'getSeekPosition'	=> \&getSeekPosition,
		'setSeekPosition'	=> \&setSeekPosition,
		'getTrack'	=> \&getTrack,
		'setTrack'	=> \&setTrack,
		'setTrackMetadata'	=> \&setTrackMetadata,
		'getVolume'	=> \&getVolume,
		'setVolume'	=> \&setVolume,
		'setPlaybackQueueMode'	=> \&setPlaybackQueueMode,
		'setDynamicPlaybackQueueParameters'	=> \&setDynamicPlaybackQueueParameters,
		'getPlaybackQueue'	=> \&getPlaybackQueue,
		'setPlaylistName'	=> \&setPlaylistName,
		'addTracks'	=> \&addTracks,
		'removeTracks'	=> \&removeTracks,
		'moveTracks'	=> \&moveTracks,
		'setTracks'	=> \&setTracks,
		'shuffleTracks'	=> \&shuffleTracks
);

sub getProtocolVersions {
        my $context = shift;
        my $client = shift;
        my $responseCallback = shift;
        
        if ( $log->is_debug ) {
                $log->debug( $client->name() .": ". "getProtocolVersions()" );
        }
        my $result = {
                'minVersion' => '1.0',
                'maxVersion' => '1.0'
        };
        # the request was successful and is not async, send results back to caller!
        &{$responseCallback}($result);
}

sub setPlayerConfiguration {
        my $context = shift;
        my $client = shift;
        my $responseCallback = shift;

	    # get the JSON-RPC params
	    my $reqParams = $context->{'procedure'}->{'params'};
        if ( $log->is_debug ) {
                $log->debug( $client->name() .": ". "setPlayerConfiguration(" . Data::Dump::dump($reqParams) . ")" );
        }
        my $sendNotification = 0;
        my $playerConfiguration = $prefs->get('player_'.$client->id) || {};
        if(defined($reqParams->{'cloudCoreUrl'}) && ((!defined($playerConfiguration->{'cloudCoreUrl'}) && $reqParams->{'cloudCoreUrl'} ne 'https://api.ickstream.com/ickstream-cloud-core/jsonrpc') || $reqParams->{'cloudCoreUrl'} ne $playerConfiguration->{'cloudCoreUrl'})) {
        	$playerConfiguration->{'cloudCoreUrl'} = $reqParams->{'cloudCoreUrl'};
        	$playerConfiguration->{'accessToken'} = undef;
        	$prefs->set('player_'.$client->id,$playerConfiguration);
        	# TODO: Add some error handling for invalid urls
        }
        if(defined($reqParams->{'deviceRegistrationToken'}) && $reqParams->{'deviceRegistrationToken'} ne '') {
        	registerPlayer($client,$reqParams->{'deviceRegistrationToken'});
        }elsif(defined($reqParams->{'deviceRegistrationToken'})) {
        	$playerConfiguration->{'accessToken'} = undef;
        	$prefs->set('player_'.$client->id,$playerConfiguration);
        	$sendNotification = 1;
        }elsif(defined($reqParams->{'accessToken'}) && $reqParams->{'accessToken'} ne '') {
        	$playerConfiguration->{'accessToken'} = $reqParams->{'accessToken'};
        	$prefs->set('player_'.$client->id,$playerConfiguration);
        	
        	my $cloudCoreUrl = $playerConfiguration->{'cloudCoreUrl'} || 'https://api.ickstream.com/ickstream-cloud-core/jsonrpc';
			Slim::Networking::SimpleAsyncHTTP->new(
				sub {
					my $http = shift;
					$log->info("Successfully updated IP-address in cloud");
				},
				sub {
					$log->info("Failed to update IP-address in cloud");
					$playerConfiguration = $prefs->get('player_'.$client->id) || {};
					$playerConfiguration->{'accessToken'} = undef;
					$prefs->set('player_'.$client->id,$playerConfiguration);
					sendPlayerStatusChangedNotification($client);
				},
				undef
			)->post($cloudCoreUrl,'Content-Type' => 'application/json','Authorization'=>'Bearer '.$playerConfiguration->{'accessToken'},to_json({
				'jsonrpc' => '2.0',
				'id' => 1,
				'method' => 'setDeviceAddress',
				'params' => {
					'deviceId' => $playerConfiguration->{'id'},
					'address' =>  Slim::Utils::IPDetect::IP()
				}
			}));
        	$sendNotification = 1;
        }elsif(defined($reqParams->{'accessToken'})) {
        	$playerConfiguration->{'accessToken'} = undef;
        	$prefs->set('player_'.$client->id,$playerConfiguration);
        	$sendNotification = 1;
        }
        
        if(defined($reqParams->{'playerName'}) && $reqParams->{'playerName'} ne '') {
        	$client->name($reqParams->{'playerName'});
        }
        
        getPlayerConfiguration($context,$client,$responseCallback);	
        if($sendNotification) {
	        sendPlayerStatusChangedNotification($client);
        }
}

sub registerPlayer {
	my $client = shift;
	my $deviceRegistrationToken = shift;
	
    my $playerConfiguration = $prefs->get('player_'.$client->id) || {};
	$playerConfiguration->{'accessToken'} = undef;
	$prefs->set('player_'.$client->id,$playerConfiguration);
	
	my $uuid = $client->uuid;
	if(!defined($uuid)) {
		$uuid = 'Squeezebox_'.$client->macaddress;
	}
	
	my $cloudCoreUrl = $playerConfiguration->{'cloudCoreUrl'} || 'https://api.ickstream.com/ickstream-cloud-core/jsonrpc';
	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $http = shift;
			my $jsonResponse = from_json($http->content);
			if($jsonResponse->{'result'} && $jsonResponse->{'result'}->{'accessToken'}) {
				$log->info("Succeessfully registered player in cloud");
				$playerConfiguration = $prefs->get('player_'.$client->id) || {};
				$playerConfiguration->{'accessToken'} = $jsonResponse->{'result'}->{'accessToken'};
				$prefs->set('player_'.$client->id,$playerConfiguration);
			}else {
				$log->info("Failed to register player in cloud");
			}
			sendPlayerStatusChangedNotification($client);
		},
		sub {
			$log->info("Failed to register player in cloud");
			sendPlayerStatusChangedNotification($client);
		},
		undef
	)->post($cloudCoreUrl,'Content-Type' => 'application/json','Authorization'=>'Bearer '.$deviceRegistrationToken,to_json({
		'jsonrpc' => '2.0',
		'id' => 1,
		'method' => 'addDevice',
		'params' => {
			'applicationId' => 'C5589EF9-9C28-4556-942A-765E698215F1',
			'hardwareId' => $uuid,
			'address' =>  Slim::Utils::IPDetect::IP()
		}
	}));
}
sub getPlayerConfiguration {
        my $context = shift;
        my $client = shift;
        my $responseCallback = shift;

        if ( $log->is_debug ) {
                $log->debug( $client->name() .": ". "getPlayerConfiguration()" );
        }
		my $playerConfiguration = $prefs->get('player_'.$client->id) || {};
        my $cloudCoreUrl = $playerConfiguration->{'cloudCoreUrl'} || 'https://api.ickstream.com/ickstream-cloud-core/jsonrpc';
        my $result = {
        	'cloudCoreUrl' => $cloudCoreUrl,
        	'playerName' => $client->name(),
        	'playerModel' => 'Legacy Squeezebox',
        	'hardwareId' => $client->macaddress()
        };
        # the request was successful and is not async, send results back to caller!
        &{$responseCallback}($result);
}

sub getPlayerStatus {
        my $context = shift;
        my $client = shift;
        my $responseCallback = shift;

        if ( $log->is_debug ) {
                $log->debug( $client->name() .": ". "getPlayerStatus()" );
        }
        my $result = {
        };
		my $playerConfiguration = $prefs->get('player_'.$client->id) || {};
		if(defined($playerConfiguration->{'accessToken'})) {
			$result->{'cloudCoreStatus'} = 'REGISTERED';
		}else {
			$result->{'cloudCoreStatus'} = 'UNREGISTERED';
		}
		
		my $playerStatus = $prefs->get('playerstatus_'.$client->id) || getDefaultPlayerStatus();
		if(defined($playerStatus->{'playbackQueuePos'})) {
	       	my $playbackQueue = Plugins::IckStreamPlugin::PlaybackQueueManager::getPlaybackQueue($client);
	       	
	       	if(scalar(@{$playbackQueue})>$playerStatus->{'playbackQueuePos'}) {
				$result->{'playbackQueuePos'} = $playerStatus->{'playbackQueuePos'};
				$result->{'track'} = @{$playbackQueue}[$playerStatus->{'playbackQueuePos'}];
				$result->{'seekPos'} = Slim::Player::Source::songTime($client);
	       	}
		}
		$result->{'playbackQueueMode'} = $playerStatus->{'playbackQueueMode'};

        my $vol = abs($serverPrefs->client($client)->get('volume'));
        my $volume = ($vol - $client->minVolume())/($client->maxVolume()-$client->minVolume());
        my $mute = bless(do{\(my $o = 0)}, "JSON::XS::Boolean");
        if($serverPrefs->client($client)->get('mute')) {
        	$mute = bless(do{\(my $o = 1)}, "JSON::XS::Boolean");
        }
        $result->{'volumeLevel'} = $volume;
        $result->{'muted'} = $mute;
        my $timestamp = int(Time::HiRes::time() * 1000);
        $result->{'lastChanged'} = 0+$timestamp;

		my $playMode = Slim::Player::Source::playmode($client);
        my $playing = bless(do{\(my $o = 0)}, "JSON::XS::Boolean");
		if($playMode eq 'play') {
	        $playing = bless(do{\(my $o = 1)}, "JSON::XS::Boolean");
		}
		$result->{'playing'} = $playing;
		
        # the request was successful and is not async, send results back to caller!
        &{$responseCallback}($result);
}

sub play {
        my $context = shift;
        my $client = shift;
        my $responseCallback = shift;

	    # get the JSON-RPC params
	    my $reqParams = $context->{'procedure'}->{'params'};
        if ( $log->is_debug ) {
                $log->debug( $client->name() .": ". "play(" . Data::Dump::dump($reqParams) . ")" );
        }
        my $playMode = Slim::Player::Source::playmode($client);
        
        my $notification = 1;
        if($reqParams->{'playing'} eq 'true' || $reqParams->{'playing'} eq '1') {
			my $playerStatus = $prefs->get('playerstatus_'.$client->id) || getDefaultPlayerStatus();
        	$notification = refreshCurrentPlaylist($client, $playerStatus->{'playbackQueuePos'});

        }elsif($reqParams->{'playing'} eq 'false' || $reqParams->{'playing'} eq '0') {
        	my $request = Slim::Control::Request::executeRequest($client,['pause','1']);
        	$request->source('PLUGIN_ICKSTREAM');
        }
        $playMode = Slim::Player::Source::playmode($client);
        my $playing = bless(do{\(my $o = 0)}, "JSON::XS::Boolean");
        if($playMode eq 'play') {
        	$playing = bless(do{\(my $o = 1)}, "JSON::XS::Boolean");
        }
        if($notification) {
	        sendPlayerStatusChangedNotification($client);
        }
        my $result = {
        	'playing' => $playing
        };
        # the request was successful and is not async, send results back to caller!
        &{$responseCallback}($result);
}

sub refreshCurrentPlaylist {
	my $client = shift;
	my $wantedPlaybackQueuePos = shift;
	
	my $notification = 1;
	my $playerStatus = $prefs->get('playerstatus_'.$client->id) || getDefaultPlayerStatus();
	my $playbackQueue = Plugins::IckStreamPlugin::PlaybackQueueManager::getPlaybackQueue($client);
   	my $playbackQueuePos = $wantedPlaybackQueuePos || $playerStatus->{'playbackQueuePos'} || 0;
   	
   	if($playbackQueuePos<scalar(@{$playbackQueue})) {
		my $songIndex = Slim::Player::Source::playingSongIndex($client);

		my $actualTrack = undef;
		if(!defined($wantedPlaybackQueuePos) && defined($currentPlaylistWindowOffset->{$client->id}) && scalar(@{$playbackQueue})>$currentPlaylistWindowOffset->{$client->id}+$songIndex) {
			$actualTrack = @{$playbackQueue}[$currentPlaylistWindowOffset->{$client->id}+$songIndex];
		}
		$log->debug(Dumper($actualTrack));
		
		my $song = Slim::Player::Playlist::song($client);
		$log->debug('ickStream Playlist:  ickstream://'.$actualTrack->{'id'}) if(defined($actualTrack));
		$log->debug('Squeezebox Playlist: '.$song->url) if(defined($song));
		
		
		if(!defined($song) || !defined($actualTrack) || $song->url ne 'ickstream://'.$actualTrack->{'id'}) {
			$log->debug("Current song doesn't match current playlist, replacing current playlist");
			my $request = Slim::Control::Request::executeRequest($client,['playlist','clear']);
        	$request->source('PLUGIN_ICKSTREAM');
			my $track = undef;
			my $songIndex = 0;
			if($playbackQueuePos>0) {
				$track = @{$playbackQueue}[$playbackQueuePos-1];
				$log->debug("Inserting ".$track->{'id'}."(".$track->{'text'}.") "." before current position");
				$request = Slim::Control::Request::executeRequest($client,['playlist','add','ickstream://'.$track->{'id'}]);
	        	$request->source('PLUGIN_ICKSTREAM');
				$songIndex = 1;
				$currentPlaylistWindowOffset->{$client->id} = $playbackQueuePos - 1;
			}else {
				$currentPlaylistWindowOffset->{$client->id} = $playbackQueuePos;
			}
			for(my $i=0;$i<10;$i++) {
				if(scalar(@{$playbackQueue})>($playbackQueuePos+$i)) {
					$track = @{$playbackQueue}[$playbackQueuePos+$i];
					
					$log->debug("Adding ".$track->{'id'}."(".$track->{'text'}.") "." to playlist");
					$request = Slim::Control::Request::executeRequest($client,['playlist','add','ickstream://'.$track->{'id'}]);
		        	$request->source('PLUGIN_ICKSTREAM');
				}
			}
			$request = Slim::Control::Request::executeRequest($client,['playlist','index',$songIndex]);
        	$request->source('PLUGIN_ICKSTREAM');
			if($wantedPlaybackQueuePos) {
				$request = Slim::Control::Request::executeRequest($client,['play']);
	        	$request->source('PLUGIN_ICKSTREAM');
			}
			
		}else {
			my $playerStatus = $prefs->get('playerstatus_'.$client->id) || getDefaultPlayerStatus();
			$playbackQueuePos = $currentPlaylistWindowOffset->{$client->id} + $songIndex;
			$playerStatus->{'playbackQueuePos'} = $playbackQueuePos;
			$prefs->set('playerstatus_'.$client->id,$playerStatus);
			$log->debug("Current song matches current playlist, adding and removing tracks outside window");
			if($songIndex > 1) {
				for(my $i=0;$i<($songIndex-1);$i++) {
					$log->debug("Deleting song before current position");
					my $request = Slim::Control::Request::executeRequest($client,['playlist','delete',0]);
		        	$request->source('PLUGIN_ICKSTREAM');
				}
				$songIndex = 1;
				my $previousSong = Slim::Player::Playlist::song($client,0);
				if($playbackQueuePos>0) {
					my $previousTrack = @{$playbackQueue}[$playbackQueuePos-1];
					if(!defined($previousSong) || $previousSong->url ne 'ickstream://'.$previousTrack->{'id'}) {
						$log->debug("Deleting song before current position");
						my $request = Slim::Control::Request::executeRequest($client,['playlist','delete',0]);
			        	$request->source('PLUGIN_ICKSTREAM');
						$log->debug("Inserting ".$previousTrack->{'id'}."(".$previousTrack->{'text'}.") "." before current position");
						$request = Slim::Control::Request::executeRequest($client,['playlist','insert','ickstream://'.$previousTrack->{'id'}]);
			        	$request->source('PLUGIN_ICKSTREAM');
						$request = Slim::Control::Request::executeRequest($client,['playlist','move', 1, 0]);
			        	$request->source('PLUGIN_ICKSTREAM');
					}
				}else {
					$log->debug("Deleting song before current position");
					my $request = Slim::Control::Request::executeRequest($client,['playlist','delete',0]);
		        	$request->source('PLUGIN_ICKSTREAM');
					$songIndex = 0;
				}
					
			}elsif($songIndex == 0 && $playbackQueuePos>0) {
				my $track = @{$playbackQueue}[$playbackQueuePos-1];
				
				$log->debug("Inserting ".$track->{'id'}."(".$track->{'text'}.") "." before current position");
				my $request = Slim::Control::Request::executeRequest($client,['playlist','insert','ickstream://'.$track->{'id'}]);
	        	$request->source('PLUGIN_ICKSTREAM');
				$request = Slim::Control::Request::executeRequest($client,['playlist','move', 1, 0]);
	        	$request->source('PLUGIN_ICKSTREAM');
				$songIndex = 1;
			}elsif($songIndex == 1 && $playbackQueuePos>0) {
				my $previousSong = Slim::Player::Playlist::song($client,0);
				my $previousTrack = @{$playbackQueue}[$playbackQueuePos-1];
				if(!defined($previousSong) || $previousSong->url ne 'ickstream://'.$previousTrack->{'id'}) {
					$log->debug("Deleting song before current position");
					my $request = Slim::Control::Request::executeRequest($client,['playlist','delete',0]);
		        	$request->source('PLUGIN_ICKSTREAM');
					$log->debug("Inserting ".$previousTrack->{'id'}."(".$previousTrack->{'text'}.") "." before current position");
					$request = Slim::Control::Request::executeRequest($client,['playlist','insert','ickstream://'.$previousTrack->{'id'}]);
		        	$request->source('PLUGIN_ICKSTREAM');
					$request = Slim::Control::Request::executeRequest($client,['playlist','move', 1, 0]);
		        	$request->source('PLUGIN_ICKSTREAM');
				}
			}
				
			$currentPlaylistWindowOffset->{$client->id} = $playbackQueuePos - $songIndex;
			for(my $i=1;$i<10;$i++) {
				if(scalar(@{$playbackQueue})>($playbackQueuePos+$i)) {
					my $track = @{$playbackQueue}[$playbackQueuePos+$i];
					my $song = undef;
					do {
						$song = Slim::Player::Playlist::song($client, $songIndex+$i);
						if(defined($song) && ($song->url ne 'ickstream://'.$track->{'id'})) {
							$log->debug("Deleting song after current position: ".$song->url());
							my $request = Slim::Control::Request::executeRequest($client,['playlist','delete',$songIndex+$i]);
				        	$request->source('PLUGIN_ICKSTREAM');
						}
					} while (defined($song) && ($song->url ne 'ickstream://'.$track->{'id'}));
					if(!defined($song)) {
						$log->debug("Adding ".$track->{'id'}."(".$track->{'text'}.") "." to playlist");
						my $request = Slim::Control::Request::executeRequest($client,['playlist','add','ickstream://'.$track->{'id'}]);
			        	$request->source('PLUGIN_ICKSTREAM');
					}
				}
			}
			$song = Slim::Player::Playlist::song($client, $songIndex+10);
			while(defined($song)) {
				$log->debug("Deleting song after current position: ".$song->url());
				my $request = Slim::Control::Request::executeRequest($client,['playlist','delete',$songIndex+10]);
	        	$request->source('PLUGIN_ICKSTREAM');
			}
			if($wantedPlaybackQueuePos) {
				my $request = Slim::Control::Request::executeRequest($client,['play']);
	        	$request->source('PLUGIN_ICKSTREAM');
			}
		}
   	}
   	return $notification;
}		   	


sub getSeekPosition {
        my $context = shift;
        my $client = shift;
        my $responseCallback = shift;

        if ( $log->is_debug ) {
                $log->debug( $client->name() .": ". "getSeekPosition()" );
        }
        my $result = {
        };
        # the request was successful and is not async, send results back to caller!
        &{$responseCallback}($result);
}

sub setSeekPosition {
        my $context = shift;
        my $client = shift;
        my $responseCallback = shift;

	    # get the JSON-RPC params
	    my $reqParams = $context->{'procedure'}->{'params'};
        if ( $log->is_debug ) {
                $log->debug( $client->name() .": ". "setSeekPosition(" . Data::Dump::dump($reqParams) . ")" );
        }
        my $result = {
        };
        # the request was successful and is not async, send results back to caller!
        &{$responseCallback}($result);
}

sub getTrack {
        my $context = shift;
        my $client = shift;
        my $responseCallback = shift;

	    # get the JSON-RPC params
	    my $reqParams = $context->{'procedure'}->{'params'};
        if ( $log->is_debug ) {
                $log->debug( $client->name() .": ". "getTrack(" . Data::Dump::dump($reqParams) . ")" );
        }
        my $playerStatus = $prefs->get('playerstatus_'.$client->id) || getDefaultPlayerStatus();

       	my $playbackQueue = Plugins::IckStreamPlugin::PlaybackQueueManager::getPlaybackQueue($client);
       	my @emptyPlaybackQueue = ();
       	$playbackQueue = \@emptyPlaybackQueue if(!defined($playbackQueue));

        my $result = {
        };
		if(defined($playerStatus->{'playlistId'})) {
			$result->{'playlistId'} = $playerStatus->{'playlistId'}
		}
		if(defined($playerStatus->{'playlistName'})) {
			$result->{'playlistName'} = $playerStatus->{'playlistName'}
		}
		if(defined($reqParams->{'playbackQueuePos'}) && $reqParams->{'playbackQueuePos'}<scalar(@{$playbackQueue})) {
			$result->{'playbackQueuePos'} = $reqParams->{'playbackQueuePos'};
			$result->{'track'} = @{$playbackQueue}[$reqParams->{'playbackQueuePos'}];
		}elsif(!defined($reqParams->{'playbackQueuePos'}) && defined($playerStatus->{'playbackQueuePos'})) {
			$result->{'playbackQueuePos'} = $playerStatus->{'playbackQueuePos'};
			$result->{'track'} = @{$playbackQueue}[$playerStatus->{'playbackQueuePos'}];
		}
        # the request was successful and is not async, send results back to caller!
        &{$responseCallback}($result);
}

sub setTrack {
        my $context = shift;
        my $client = shift;
        my $responseCallback = shift;

	    # get the JSON-RPC params
	    my $reqParams = $context->{'procedure'}->{'params'};
        if ( $log->is_debug ) {
                $log->debug( $client->name() .": ". "setTrack(" . Data::Dump::dump($reqParams) . ")" );
        }
        
        my $playerStatus = $prefs->get('playerstatus_'.$client->id) || getDefaultPlayerStatus();
       	my $playbackQueue = Plugins::IckStreamPlugin::PlaybackQueueManager::getPlaybackQueue($client);
       	my @emptyPlaybackQueue = ();
       	$playbackQueue = \@emptyPlaybackQueue if(!defined($playbackQueue));

        if(defined($reqParams->{'playbackQueuePos'}) && $reqParams->{'playbackQueuePos'} < scalar(@{$playbackQueue})) {
        	$playerStatus->{'playbackQueuePos'} = $reqParams->{'playbackQueuePos'};
        	$playerStatus->{'seekPos'} = 0;
        	$prefs->set('playerstatus_'.$client->id,$playerStatus);
        	# TODO: if playing
        	my $notification = refreshCurrentPlaylist($client, $playerStatus->{'playbackQueuePos'});
        	if($notification) {
	        	sendPlayerStatusChangedNotification($client);
        	}
        }else {
        	# TODO: return error
        }
        
        my $result = {
        	'playbackQueuePos' => $playerStatus->{'playbackQueuePos'}
        };
        # the request was successful and is not async, send results back to caller!
        &{$responseCallback}($result);
}

sub setTrackMetadata {
        my $context = shift;
        my $client = shift;
        my $responseCallback = shift;

	    # get the JSON-RPC params
	    my $reqParams = $context->{'procedure'}->{'params'};
        if ( $log->is_debug ) {
                $log->debug( $client->name() .": ". "setTrackMetadata(" . Data::Dump::dump($reqParams) . ")" );
        }
        my $result = {
        };
        # the request was successful and is not async, send results back to caller!
        &{$responseCallback}($result);
}

sub getVolume {
        my $context = shift;
        my $client = shift;
        my $responseCallback = shift;

        if ( $log->is_debug ) {
                $log->debug( $client->name() .": ". "getVolume()" );
        }
        my $vol = abs($serverPrefs->client($client)->get('volume'));
        my $volume = ($vol - $client->minVolume())/($client->maxVolume()-$client->minVolume());
        my $mute = bless(do{\(my $o = 0)}, "JSON::XS::Boolean");
        if($serverPrefs->client($client)->get('mute')) {
        	$mute = bless(do{\(my $o = 1)}, "JSON::XS::Boolean");
        }
        my $result = {
        	'volumeLevel' => $volume,
        	'muted' => $mute
        };
        
        # the request was successful and is not async, send results back to caller!
        &{$responseCallback}($result);
}

sub setVolume {
        my $context = shift;
        my $client = shift;
        my $responseCallback = shift;

	    # get the JSON-RPC params
	    my $reqParams = $context->{'procedure'}->{'params'};
        if ( $log->is_debug ) {
                $log->debug( $client->name() .": ". "setVolume(" . Data::Dump::dump($reqParams) . ")" );
        }
        if(defined($reqParams->{'volumeLevel'})) {
       		my $volume = $reqParams->{'volumeLevel'};
        	if($serverPrefs->client($client)->get('mute')) {
        		$serverPrefs->client($client)->set('volume',-($volume*($client->maxVolume()-$client->minVolume())+$client->minVolume()));
        	}else {
        		my $request = Slim::Control::Request::executeRequest($client,['mixer','volume',($volume*($client->maxVolume()-$client->minVolume())+$client->minVolume())]);
	        	$request->source('PLUGIN_ICKSTREAM');
        	}
        }elsif(defined($reqParams->{'relativeVolumeLevel'})) {
       		my $relativeVolume = $reqParams->{'relativeVolumeLevel'};
        	if($serverPrefs->client($client)->get('mute')) {
        		$serverPrefs->client($client)->set('volume',$serverPrefs->client($client)->get('volume')-($relativeVolume*($client->maxVolume()-$client->minVolume())));
        	}else {
        		my $request = Slim::Control::Request::executeRequest($client,['mixer','volume',($serverPrefs->client($client)->get('volume')+($relativeVolume*($client->maxVolume()-$client->minVolume())))]);
	        	$request->source('PLUGIN_ICKSTREAM');
        	}
        }
        if(defined($reqParams->{'muted'}) && ($reqParams->{'muted'} eq 'true' || $reqParams->{'muted'} eq '1') && !$serverPrefs->client($client)->get('mute')) {
        	$log->debug("Muting ".$client->name());
        	my $request = Slim::Control::Request::executeRequest($client,['mixer','muting','1']);
        	$request->source('PLUGIN_ICKSTREAM');
        }elsif(defined($reqParams->{'muted'}) && ($reqParams->{'muted'} eq 'false' || $reqParams->{'muted'} eq '0') && $serverPrefs->client($client)->get('mute')) {
        	$log->debug("Unmuting ".$client->name());
        	my $request = Slim::Control::Request::executeRequest($client,['mixer','muting','0']);
        	$request->source('PLUGIN_ICKSTREAM');
        }
        sendPlayerStatusChangedNotification($client);
        my $vol = abs($serverPrefs->client($client)->get('volume'));
        my $volume = ($vol - $client->minVolume())/($client->maxVolume()-$client->minVolume());
        my $mute = bless(do{\(my $o = 0)}, "JSON::XS::Boolean");
        if($serverPrefs->client($client)->get('mute')) {
        	$mute = bless(do{\(my $o = 1)}, "JSON::XS::Boolean");
        }
        my $result = {
        	'volumeLevel' => $volume,
        	'muted' => $mute
        };
        # the request was successful and is not async, send results back to caller!
        &{$responseCallback}($result);
}

sub setPlaybackQueueMode {
        my $context = shift;
        my $client = shift;
        my $responseCallback = shift;

	    # get the JSON-RPC params
	    my $reqParams = $context->{'procedure'}->{'params'};
        if ( $log->is_debug ) {
                $log->debug( $client->name() .": ". "setPlaybackQueueMode(" . Data::Dump::dump($reqParams) . ")" );
        }
        my $playerStatus = $prefs->get('playerstatus_'.$client->id) || getDefaultPlayerStatus();
        my $shuffle = 0;
        my $sendPlaybackQueueChanged = 0;
        if(($playerStatus->{'playbackQueueMode'} eq 'QUEUE_SHUFFLE' || $playerStatus->{'playbackQueueMode'} eq 'QUEUE_REPEAT_SHUFFLE') &&
        	!($reqParams->{'playbackQueueMode'} eq 'QUEUE_SHUFFLE' || $reqParams->{'playbackQueueMode'} eq 'QUEUE_REPEAT_SHUFFLE')) {
        		
        	$log->debug("Restoring playlist to original order");

        	my $playbackQueue = Plugins::IckStreamPlugin::PlaybackQueueManager::getPlaybackQueue($client);
        	my @emptyPlaybackQueue = ();
        	$playbackQueue = \@emptyPlaybackQueue if(!defined($playbackQueue));

        	my $currentPos = $playerStatus->{'playbackQueuePos'};
        	my $currentTrack = undef;
        	if(defined($currentPos)) {
        		$currentTrack = @{$playbackQueue}[$currentPos];
        	}

        	my $originalPlaybackQueue = Plugins::IckStreamPlugin::PlaybackQueueManager::getOriginalPlaybackQueue($client);
        	
        	$playbackQueue = \@emptyPlaybackQueue;
        	push @{$playbackQueue},@{$originalPlaybackQueue};
        	Plugins::IckStreamPlugin::PlaybackQueueManager::setPlaybackQueue($client, $playbackQueue);
        	
        	if(defined($currentTrack)) {
        		my $i = 0;
        		for my $item (@{$playbackQueue}) {
        			if($currentTrack->{'instanceId'} == $item->{'instanceId'}) {
        				last;
        			}
        			$i++;
        		}
        		$playerStatus->{'playbackQueuePos'} = $i;
        	}
        	$sendPlaybackQueueChanged = 1;
        }elsif(($reqParams->{'playbackQueueMode'} eq 'QUEUE_SHUFFLE' && $playerStatus->{'playbackQueueMode'} ne 'QUEUE_REPEAT_SHUFFLE') ||
        	($reqParams->{'playbackQueueMode'} eq 'QUEUE_REPEAT_SHUFFLE' && $playerStatus->{'playbackQueueMode'} ne 'QUEUE_SHUFFLE')) {
        		
        	$shuffle = 1;
        }
        $playerStatus->{'playbackQueueMode'} = $reqParams->{'playbackQueueMode'};
        $prefs->set('playerstatus_'.$client->id,$playerStatus);
        if($shuffle) {
        	$log->debug("Shuffling playlist");
	       	my $playbackQueue = Plugins::IckStreamPlugin::PlaybackQueueManager::getPlaybackQueue($client);
        	my @emptyPlaybackQueue = ();
        	$playbackQueue = \@emptyPlaybackQueue if(!defined($playbackQueue));
        	
        	my $currentItem = undef;
        	if(defined($playerStatus->{'playbackQueuePos'}) && $playerStatus->{'playbackQueuePos'}<scalar(@{$playbackQueue})) {
        		$currentItem = splice @{$playbackQueue},$playerStatus->{'playbackQueuePos'},1;
        	}
        	
        	fisher_yates_shuffle($playbackQueue);
        	
        	if(defined($currentItem)) {
        		splice @{$playbackQueue},0,0,$currentItem;
	        	$playerStatus->{'playbackQueuePos'} = 0;
	        	$prefs->set('playerstatus_'.$client->id,$playerStatus);
        	}
        	Plugins::IckStreamPlugin::PlaybackQueueManager::setPlaybackQueue($client, $playbackQueue);
        	
			sendPlaybackQueueChangedNotification($client);
			if(defined($currentItem)) {
				sendPlayerStatusChangedNotification($client);
			}
        }else {
        	if($sendPlaybackQueueChanged) {
        		sendPlaybackQueueChangedNotification($client);
        	}
        	sendPlayerStatusChangedNotification($client);
        }
        	
        my $result = {
        	'playbackQueueMode' => $playerStatus->{'playbackQueueMode'}
        };
        # the request was successful and is not async, send results back to caller!
        &{$responseCallback}($result);
}

sub fisher_yates_shuffle {
    my $myarray = shift;  
    my $i = @$myarray;
    if(scalar(@$myarray)>1) {
            while (--$i) {
                my $j = int rand ($i+1);
                @$myarray[$i,$j] = @$myarray[$j,$i];
            }
    }
}

sub setDynamicPlaybackQueueParameters {
        my $context = shift;
        my $client = shift;
        my $responseCallback = shift;

	    # get the JSON-RPC params
	    my $reqParams = $context->{'procedure'}->{'params'};
        if ( $log->is_debug ) {
                $log->debug( $client->name() .": ". "setDynamicPlaybackQueueParameters(" . Data::Dump::dump($reqParams) . ")" );
        }
        my $result = {
        };
        # the request was successful and is not async, send results back to caller!
        &{$responseCallback}($result);
}

sub getPlaybackQueue {
        my $context = shift;
        my $client = shift;
        my $responseCallback = shift;

	    # get the JSON-RPC params
	    my $reqParams = $context->{'procedure'}->{'params'};
        if ( $log->is_debug ) {
                $log->debug( $client->name() .": ". "getPlaybackQueue(" . Data::Dump::dump($reqParams) . ")" );
        }
        my $result = {
        };
		my $playerStatus = $prefs->get('playerstatus_'.$client->id);
		if(defined($playerStatus->{'playlistId'})) {
			$result->{'playlistId'} = $playerStatus->{'playlistId'}
		}
		if(defined($playerStatus->{'playlistName'})) {
			$result->{'playlistName'} = $playerStatus->{'playlistName'}
		}
		
		if(defined($reqParams->{'order'})) {
			$result->{'order'} = $reqParams->{'order'};
		}else {
			$result->{'order'} = 'CURRENT';
		}
		my $items = undef;
		if($result->{'order'} eq 'ORIGINAL') {
			$items = Plugins::IckStreamPlugin::PlaybackQueueManager::getOriginalPlaybackQueue($client);
		}else {
			$items = Plugins::IckStreamPlugin::PlaybackQueueManager::getPlaybackQueue($client);
		}
		
		my $offset = $reqParams->{'offset'} || 0;
		my $count = $reqParams->{'count'} || scalar(@{$items});
		$result->{'offset'} = $offset;
		$result->{'countAll'} = scalar(@{$items});
		
		if($offset < scalar(@{$items})) {
			if(($offset + $count) > scalar(@{$items})) {
				my @array = ();
				if($offset < scalar(@{$items})) {
					@array = @{$items}[$offset..(scalar(@{$items})-1)];
				}
				$result->{'items'} = \@array;
			}else {
				my @array = ();
				if($offset < ($offset+$count)) {
					@array = @{$items}[$offset..($offset+$count-1)];
				}
				$result->{'items'} = \@array;
			}
		}else {
			my @array = ();
			if($offset < scalar(@{$items})) {
				@array = @{$items}[$offset..(scalar(@{$items})-1)];
			}
			$result->{'items'} = \@array;
		}
		$result->{'count'} = scalar(@{$result->{'items'}});
		if(Plugins::IckStreamPlugin::PlaybackQueueManager::getLastChanged($client)) {
			$result->{'lastChanged'} = Plugins::IckStreamPlugin::PlaybackQueueManager::getLastChanged($client);
		}
        
        # the request was successful and is not async, send results back to caller!
        &{$responseCallback}($result);
}

sub setPlaylistName {
        my $context = shift;
        my $client = shift;
        my $responseCallback = shift;

	    # get the JSON-RPC params
	    my $reqParams = $context->{'procedure'}->{'params'};
        if ( $log->is_debug ) {
                $log->debug( $client->name() .": ". "setPlaylistName(" . Data::Dump::dump($reqParams) . ")" );
        }
        my $playerStatus = $prefs->get('playerstatus_'.$client->id) || getDefaultPlayerStatus();
        $playerStatus->{'playlistId'} = $reqParams->{'playlistId'};
        $playerStatus->{'playlistName'} = $reqParams->{'playlistName'};
        $prefs->set('playerstatus_'.$client->id,$playerStatus);
        
        my $playbackQueue = Plugins::IckStreamPlugin::PlaybackQueueManager::getPlaybackQueue($client);
       	my @emptyPlaybackQueue = ();
       	$playbackQueue = \@emptyPlaybackQueue if(!defined($playbackQueue));
        
        my $result = {
        	'countAll' => scalar(@{$playbackQueue})
        };
        if(defined($reqParams->{'playlistId'})) {
        	$result->{'playlistId'} = $reqParams->{'playlistId'};
        }
        if(defined($reqParams->{'playlistName'})) {
        	$result->{'playlistName'} = $reqParams->{'playlistName'};
        }
        # the request was successful and is not async, send results back to caller!
        &{$responseCallback}($result);
}

sub addTracks {
        my $context = shift;
        my $client = shift;
        my $responseCallback = shift;

	    # get the JSON-RPC params
	    my $reqParams = $context->{'procedure'}->{'params'};
        if ( $log->is_debug ) {
                $log->debug( $client->name() .": ". "addTracks(" . Data::Dump::dump($reqParams) . ")" );
        }
        my $playerStatus = $prefs->get('playerstatus_'.$client->id) || getDefaultPlayerStatus();
        my $items = $reqParams->{'items'};
        for my $item (@{$items}) {
        	my $instanceId = $nextTrackInstance;
        	$item->{'instanceId'} = $instanceId;
        	$nextTrackInstance++;
        	Plugins::IckStreamPlugin::ItemCache::setItemInCache($item->{'id'},$item);
        }

        if(defined($reqParams->{'playbackQueuePos'})) {
       		$log->debug("Inserting tracks at position: ".$reqParams->{'playbackQueuePos'});
        	# Insert tracks in middle
        	my $playbackQueue = Plugins::IckStreamPlugin::PlaybackQueueManager::getPlaybackQueue($client);
        	splice @{$playbackQueue},$reqParams->{'playbackQueuePos'},0,@{$items};
       		Plugins::IckStreamPlugin::PlaybackQueueManager::setPlaybackQueue($client, $playbackQueue);
       		
        	my $originalPlaybackQueue = Plugins::IckStreamPlugin::PlaybackQueueManager::getOriginalPlaybackQueue($client);
        	splice @{$originalPlaybackQueue},$reqParams->{'playbackQueuePos'},0,@{$items};
       		Plugins::IckStreamPlugin::PlaybackQueueManager::setOriginalPlaybackQueue($client, $originalPlaybackQueue);
        	
        	if(defined($playerStatus->{'playbackQueuePos'}) && $playerStatus->{'playbackQueuePos'}>=$reqParams->{'playbackQueuePos'}) {
        		$playerStatus->{'playbackQueuePos'} += scale(@{$reqParams->{'items'}});
        	}
        }else {
        	if($playerStatus->{'playbackQueueMode'} eq 'QUEUE_SHUFFLE' || $playerStatus->{'playbackQueueMode'} eq 'QUEUE_REPEAT_SHUFFLE') {
        		$log->debug("Adding tracks at random position");
        		# Add tracks at random position after currently playing track
        		my $currentPlaybackQueuePos = 0;
        		if(defined($playerStatus->{'playbackQueuePos'})) {
        			$currentPlaybackQueuePos = $playerStatus->{'playbackQueuePos'};
        		}
        		my $playbackQueue = Plugins::IckStreamPlugin::PlaybackQueueManager::getPlaybackQueue($client);
        		my $rangeLength = scalar(@{$playbackQueue}) - $currentPlaybackQueuePos - 1;
        		if($rangeLength > 0) {
        			my $randomPosition = $currentPlaybackQueuePos + int(rand($rangeLength)) + 1;
        			if($randomPosition < (scalar(@{$playbackQueue}) - 1)) {
        				splice @{$playbackQueue},$randomPosition,0,@{$items};
        			}else {
        				push @{$playbackQueue},@{$reqParams->{'items'}};
        			}
        		}else {
        			push @{$playbackQueue},@{$reqParams->{'items'}};
        		}
        		Plugins::IckStreamPlugin::PlaybackQueueManager::setPlaybackQueue($client, $playbackQueue);
        		my $originalPlaybackQueue = Plugins::IckStreamPlugin::PlaybackQueueManager::getOriginalPlaybackQueue($client);
        		push @{$originalPlaybackQueue},@{$items};
        		Plugins::IckStreamPlugin::PlaybackQueueManager::setOriginalPlaybackQueue($client, $originalPlaybackQueue);
        	}else {
        		$log->debug("Adding tracks to the end");
        		my $playbackQueue = Plugins::IckStreamPlugin::PlaybackQueueManager::getPlaybackQueue($client);
        		push @{$playbackQueue},@{$items};
        		Plugins::IckStreamPlugin::PlaybackQueueManager::setPlaybackQueue($client, $playbackQueue);
        		
        		my $originalPlaybackQueue = Plugins::IckStreamPlugin::PlaybackQueueManager::getOriginalPlaybackQueue($client);
        		push @{$originalPlaybackQueue},@{$items};
        		Plugins::IckStreamPlugin::PlaybackQueueManager::setOriginalPlaybackQueue($client, $originalPlaybackQueue);
        	}
        }
        if(!defined($playerStatus->{'playbackQueuePos'})) {
        	$playerStatus->{'playbackQueuePos'} = 0;
        }
        $prefs->set('playerstatus_'.$client->id,$playerStatus);
		refreshCurrentPlaylist($client);
        sendPlaybackQueueChangedNotification($client);
        
        my $result = {
        	'result' => 'true',
        	'playbackQueuePos' => $playerStatus->{'playbackQueuePos'}
        };
        # the request was successful and is not async, send results back to caller!
        &{$responseCallback}($result);
}

sub removeTracks {
        my $context = shift;
        my $client = shift;
        my $responseCallback = shift;

	    # get the JSON-RPC params
	    my $reqParams = $context->{'procedure'}->{'params'};
        if ( $log->is_debug ) {
                $log->debug( $client->name() .": ". "removeTracks(" . Data::Dump::dump($reqParams) . ")" );
        }
        my $playerStatus = $prefs->get('playerstatus_'.$client->id) || getDefaultPlayerStatus();
        
       	my $playbackQueue = Plugins::IckStreamPlugin::PlaybackQueueManager::getPlaybackQueue($client);

       	my $originalPlaybackQueue = Plugins::IckStreamPlugin::PlaybackQueueManager::getOriginalPlaybackQueue($client);

        my @emptyModifiedPlaybackQueue = ();
        my $modifiedPlaybackQueue = \@emptyModifiedPlaybackQueue;
        if(scalar(@{$playbackQueue})>0) {
	        push @{$modifiedPlaybackQueue},@{$playbackQueue};
        }        
        my $modifiedPlaybackQueuePos = $playerStatus->{'playbackQueuePos'};
        my $affectsPlayback = 0;
        for my $itemReference (@{$reqParams->{'items'}}) {
        	if(defined($itemReference->{'playbackQueuePos'})) {
        		my $item = @{$playbackQueue}[$itemReference->{'playbackQueuePos'}];
        		if($item->{'id'} eq $itemReference->{'id'}) {
        			if($itemReference->{'playbackQueuePos'} < $playerStatus->{'playbackQueuePos'}) {
        				$modifiedPlaybackQueuePos--;
        			}elsif($itemReference->{'playbackQueuePos'} == $playerStatus->{'playbackQueuePos'}) {
        				$affectsPlayback = 1;
        			}
        			my $removedItem = splice @{$modifiedPlaybackQueue},$itemReference->{'playbackQueuePos'},1;
        			@{$originalPlaybackQueue} = grep { $_->{'instanceId'} ne $removedItem->{'instanceId'}} @{$originalPlaybackQueue};
        		}else {
        			# TODO: Handle error non matching playbackQueuePos and id
        		}
        	}else {
        		my @itemsToDelete = ();
        		my $i = 0;
        		for my $item (@{$modifiedPlaybackQueue}) {
        			if($item->{'id'} eq $itemReference->{'id'}) {
        				if($i<$modifiedPlaybackQueuePos) {
        					$modifiedPlaybackQueuePos--;
        				}elsif($i==$modifiedPlaybackQueuePos) {
        					$affectsPlayback = 1;
        				}
        				push @itemsToDelete,$i;
        			}
        			$i++;
        		}
        		my $deleteOffset = 0;
        		for my $i (@itemsToDelete) {
        			my $removedItem = splice @{$modifiedPlaybackQueue},($i-$deleteOffset),1;
        			$deleteOffset++;
        			@{$originalPlaybackQueue} = grep { $_->{'instanceId'} ne $removedItem->{'instanceId'}} @{$originalPlaybackQueue};
        		}
        	}
        }
        $playbackQueue = $modifiedPlaybackQueue;
        Plugins::IckStreamPlugin::PlaybackQueueManager::setPlaybackQueue($client, $playbackQueue);
        Plugins::IckStreamPlugin::PlaybackQueueManager::setOriginalPlaybackQueue($client, $originalPlaybackQueue);

        if($modifiedPlaybackQueuePos >= scalar(@{$modifiedPlaybackQueue})) {
        	if($modifiedPlaybackQueuePos>0) {
        		$modifiedPlaybackQueuePos--;
        	}
        }
        refreshCurrentPlaylist($client);
        if($playerStatus->{'playbackQueuePos'} != $modifiedPlaybackQueuePos) {
        	$playerStatus->{'playbackQueuePos'} = $modifiedPlaybackQueuePos;
        	# TODO: If not playing
        	$prefs->set('playerstatus_'.$client->id,$playerStatus);
        	sendPlayerStatusChangedNotification($client);
        }
        
        # TODO: if playing
        if(0 && $affectsPlayback) {
        	if(scalar(@{$modifiedPlaybackQueue})>0) {
        		# TODO: Play
        	}else {
        		$playerStatus->{'playbackQueuePos'} = undef;
        		$playerStatus->{'seekPos'} = undef;
        		$prefs->set('playerstatus_'.$client->id,$playerStatus);
        		# TODO: Pause
        	}
        }
        
        sendPlaybackQueueChangedNotification($client);

        my $result = {
        	'result' => 'true'
        };
        if(defined($playerStatus->{'playbackQueuePos'})) {
        	$result->{'playbackQueuePos'} = $playerStatus->{'playbackQueuePos'};
        }
        
        # the request was successful and is not async, send results back to caller!
        &{$responseCallback}($result);
}

sub moveTracks {
        my $context = shift;
        my $client = shift;
        my $responseCallback = shift;

	    # get the JSON-RPC params
	    my $reqParams = $context->{'procedure'}->{'params'};
        if ( $log->is_debug ) {
                $log->debug( $client->name() .": ". "moveTracks(" . Data::Dump::dump($reqParams) . ")" );
        }
        
        my $playerStatus = $prefs->get('playerstatus_'.$client->id) || getDefaultPlayerStatus();
        my $modifiedPlaybackQueuePos = $playerStatus->{'playbackQueuePos'};

       	my $playbackQueue = Plugins::IckStreamPlugin::PlaybackQueueManager::getPlaybackQueue($client);

       	my $originalPlaybackQueue = Plugins::IckStreamPlugin::PlaybackQueueManager::getOriginalPlaybackQueue($client);
       	my @emptyOriginalPlaybackQueue = ();
       	$originalPlaybackQueue = \@emptyOriginalPlaybackQueue if(!defined($originalPlaybackQueue));

        my @emptyModifiedPlaybackQueue = ();
        my $modifiedPlaybackQueue = \@emptyModifiedPlaybackQueue;
        if(scalar(@{$playbackQueue})>0) {
	        push @{$modifiedPlaybackQueue},@{$playbackQueue};
        }        

		my $items = $reqParams->{'items'};
		
		my $wantedPlaybackQueuePos = scalar(@{$playbackQueue});
		if(defined($reqParams->{'playbackQueuePos'})) {
			$wantedPlaybackQueuePos = $reqParams->{'playbackQueuePos'};
		}
		
		for my $itemReference (@{$items}) {
			if(!defined($itemReference->{'playbackQueuePos'})) {
				# TODO: return error
			}
			if(!defined($itemReference->{'id'})) {
				# TODO: return error
			}
			
			# Move that doesn't affect playback queue position
			if(($wantedPlaybackQueuePos <= $modifiedPlaybackQueuePos && $itemReference->{'playbackQueuePos'} < $modifiedPlaybackQueuePos) ||
				$wantedPlaybackQueuePos > $modifiedPlaybackQueuePos && $itemReference->{'playbackQueuePos'} > $modifiedPlaybackQueuePos) {
					
				my $item = splice @{$modifiedPlaybackQueue},$itemReference->{'playbackQueuePos'},1;
				if($item->{'id'} ne $itemReference->{'id'}) {
					# TODO: return error
				}
				
				my $offset = 0;
				if($wantedPlaybackQueuePos >= $itemReference->{'playbackQueuePos'}) {
					$offset = -1;
				}
				if(($wantedPlaybackQueuePos + $offset) < scalar(@{$modifiedPlaybackQueue})) {
					splice @{$modifiedPlaybackQueue},$wantedPlaybackQueuePos+$offset,0,$item;
				}else {
					push @{$modifiedPlaybackQueue},$item;
				}
				if($wantedPlaybackQueuePos < $itemReference->{'playbackQueuePos'}) {
					$wantedPlaybackQueuePos++;
				}
				
			# Move that increase playback queue position
			}elsif($wantedPlaybackQueuePos <= $modifiedPlaybackQueuePos && $itemReference->{'playbackQueuePos'} > $modifiedPlaybackQueuePos) {
				my $item = splice @{$modifiedPlaybackQueue},$itemReference->{'playbackQueuePos'},1;
				if($item->{'id'} ne $itemReference->{'id'}) {
					# TODO: return error
				}
				push @{$modifiedPlaybackQueue},$item;
				$modifiedPlaybackQueuePos++;
				$wantedPlaybackQueuePos++;
			
			# Move that decrease playback queue position
			}elsif($wantedPlaybackQueuePos > $modifiedPlaybackQueuePos && $itemReference->{'playbackQueuePos'} < $modifiedPlaybackQueuePos) {
				my $item = splice @{$modifiedPlaybackQueue},$itemReference->{'playbackQueuePos'},1;
				if($item->{'id'} ne $itemReference->{'id'}) {
					# TODO: return error
				}
				my $offset = 0;
				if($wantedPlaybackQueuePos >= $itemReference->{'playbackQueuePos'}) {
					$offset = -1;
				}
				if(($wantedPlaybackQueuePos + $offset) < scalar(@{$modifiedPlaybackQueue})) {
					@{$modifiedPlaybackQueue} = splice @{$modifiedPlaybackQueue},$wantedPlaybackQueuePos+$offset,0,$item;
				}else {
					push @{$modifiedPlaybackQueue},$item;
				}
				$modifiedPlaybackQueuePos--;
				
			# Move of currently playing track
			}elsif($itemReference->{'playbackQueuePos'} == $modifiedPlaybackQueuePos) {
				my $item = splice @{$modifiedPlaybackQueue},$itemReference->{'playbackQueuePos'},1;
				if($item->{'id'} ne $itemReference->{'id'}) {
					# TODO: return error
				}
				
				if($wantedPlaybackQueuePos < (scalar(@{$modifiedPlaybackQueue})+1)) {
					if($wantedPlaybackQueuePos > $itemReference->{'playbackQueuePos'}) {
						splice @{$modifiedPlaybackQueue},$wantedPlaybackQueuePos - 1,0,$item;
						$modifiedPlaybackQueuePos = $wantedPlaybackQueuePos - 1;
					} else {
						splice @{$modifiedPlaybackQueue},$wantedPlaybackQueuePos,0,$item;
						$modifiedPlaybackQueuePos = $wantedPlaybackQueuePos;
					}
				}else {
					push @{$modifiedPlaybackQueue},$item;
					$modifiedPlaybackQueuePos = $wantedPlaybackQueuePos - 1;
				}
				if($wantedPlaybackQueuePos < $itemReference->{'playbackQueuePos'}) {
					$wantedPlaybackQueuePos++;
				}
			}
		
		}
		
		if($playerStatus->{'playbackQueueMode'} ne 'QUEUE_SHUFFLE' || $playerStatus->{'playbackQueueMode'} ne 'QUEUE_REPEAT_SHUFFLE') {
			my @empty = ();
			$originalPlaybackQueue = \@empty;
			push @{$originalPlaybackQueue},@{$modifiedPlaybackQueue};
			Plugins::IckStreamPlugin::PlaybackQueueManager::setOriginalPlaybackQueue($client, $originalPlaybackQueue);
		}
		my @empty = ();
		$playbackQueue = \@empty;
		push @{$playbackQueue},@{$modifiedPlaybackQueue};
		Plugins::IckStreamPlugin::PlaybackQueueManager::setPlaybackQueue($client, $playbackQueue);
		
		my $sendPlayerStatusChanged = 0;
		if($playerStatus->{'playbackQueuePos'} != $modifiedPlaybackQueuePos) {
			$playerStatus->{'playbackQueuePos'} = $modifiedPlaybackQueuePos;
			$prefs->set('playerstatus_'.$client->id,$playerStatus);
			$sendPlayerStatusChanged = 1;
		}
		refreshCurrentPlaylist($client);

		sendPlaybackQueueChangedNotification($client);
		if($sendPlayerStatusChanged) {
			sendPlayerStatusChangedNotification($client);
		}
		
        my $result = {
        	'result' => 'true',
        	'playbackQueuePos' => $modifiedPlaybackQueuePos
        };
        # the request was successful and is not async, send results back to caller!
        &{$responseCallback}($result);
}

sub setTracks {
        my $context = shift;
        my $client = shift;
        my $responseCallback = shift;

	    # get the JSON-RPC params
	    my $reqParams = $context->{'procedure'}->{'params'};
        if ( $log->is_debug ) {
                $log->debug( $client->name() .": ". "setTracks(" . Data::Dump::dump($reqParams) . ")" );
        }
        my $playerStatus = $prefs->get('playerstatus_'.$client->id) || getDefaultPlayerStatus();
        $playerStatus->{'playlistId'} = $reqParams->{'playlistId'};
        $playerStatus->{'playlistName'} = $reqParams->{'playlistName'};
        my $items = $reqParams->{'items'};
        for my $item (@{$items}) {
        	my $instanceId = $nextTrackInstance;
        	$item->{'instanceId'} = $instanceId;
        	$nextTrackInstance++;
        	Plugins::IckStreamPlugin::ItemCache::setItemInCache($item->{'id'},$item);
        }
        my @empty = ();
        $items = \@empty if(!defined($items));
        my @emptyPlaybackQueue = ();
        my $playbackQueue = \@emptyPlaybackQueue;
        if(scalar(@{$items})>0) {
	        push @{$playbackQueue},@{$items};
        }
        Plugins::IckStreamPlugin::PlaybackQueueManager::setPlaybackQueue($client, $playbackQueue);

        my @emptyOriginalPlaybackQueue = ();
        my $originalPlaybackQueue = \@emptyOriginalPlaybackQueue;
        if(scalar(@{$items})>0) {
	        push @{$originalPlaybackQueue},@{$items};
        }
        Plugins::IckStreamPlugin::PlaybackQueueManager::setOriginalPlaybackQueue($client, $originalPlaybackQueue);
        
        my $playbackQueuePos = 0;
        if(defined($reqParams->{'playbackQueuePos'})) {
        	$playbackQueuePos = $reqParams->{'playbackQueuePos'};
        }
        
        my $sendPlayerStatusChanged = 0;
        if(scalar(@{$playbackQueue})>0) {
        	if(defined($reqParams->{'playbackQueuePos'}) && $reqParams->{'playbackQueuePos'}<scalar(@{$playbackQueue})) {
        		$playerStatus->{'seekPos'} = 0;
        		$playerStatus->{'playbackQueuePos'} = $reqParams->{'playbackQueuePos'};
        		# TODO: Play if playing
        		# TODO: Send playerStatusChanged if not playing
        		$sendPlayerStatusChanged = 1;
        	}
        	# TODO: Set track
        }else {
        	$playerStatus->{'seekPos'} = undef;
        	$playerStatus->{'playbackQueuePos'} = undef;
        	# TODO: Pause playback if playing
       		$sendPlayerStatusChanged = 1;
        }
        $prefs->set('playerstatus_'.$client->id,$playerStatus);
        
        if($sendPlayerStatusChanged) {
        	sendPlayerStatusChangedNotification($client);
        }
        sendPlaybackQueueChangedNotification($client);
        my $result = {
        	'result' => 'true',
        };
        if(defined($playerStatus->{'playbackQueuePos'})) {
        	$result->{'playbackQueuePos'} = $playerStatus->{'playbackQueuePos'};
        }
        # the request was successful and is not async, send results back to caller!
        &{$responseCallback}($result);
}

sub shuffleTracks {
        my $context = shift;
        my $client = shift;
        my $responseCallback = shift;

        if ( $log->is_debug ) {
                $log->debug( $client->name() .": ". "shuffleTracks()" );
        }
        
        my $playerStatus = $prefs->get('playerstatus_'.$client->id) || getDefaultPlayerStatus();
        
       	my $playbackQueue = Plugins::IckStreamPlugin::PlaybackQueueManager::getPlaybackQueue($client);
       	
       	if(scalar(@{$playbackQueue})>0) {
	       	my $currentItem = undef;
	       	if(defined($playerStatus->{'playbackQueuePos'}) && $playerStatus->{'playbackQueuePos'}<scalar(@{$playbackQueue})) {
	       		$currentItem = splice @{$playbackQueue},$playerStatus->{'playbackQueuePos'},1;
	       	}
	       	
	       	fisher_yates_shuffle($playbackQueue);
	       	
	       	if(defined($currentItem)) {
	       		splice @{$playbackQueue},0,0,$currentItem;
	       	}
	       	Plugins::IckStreamPlugin::PlaybackQueueManager::setPlaybackQueue($client, $playbackQueue);
	       	
        	$playerStatus->{'playbackQueuePos'} = 0;
        	$prefs->set('playerstatus_'.$client->id,$playerStatus);
	       	
	       	if($playerStatus->{'playbackQueueMode'} ne 'QUEUE_SHUFFLE' && $playerStatus->{'playbackQueueMode'} ne 'QUEUE_REPEAT_SHUFFLE') {
			       	my @emptyOriginalPlaybackQueue = ();
			       	my $originalPlaybackQueue = \@emptyOriginalPlaybackQueue;
			       	push @{$originalPlaybackQueue},@{$playbackQueue};
			       	Plugins::IckStreamPlugin::PlaybackQueueManager::setOriginalPlaybackQueue($client, $originalPlaybackQueue);
	       	}

			sendPlaybackQueueChangedNotification($client);
			sendPlayerStatusChangedNotification($client);
       	}

        my $result = {
        	'result' => 'true',
        };
        if(defined($playerStatus->{'playbackQueuePos'})) {
        	$result->{'playbackQueuePos'} = $playerStatus->{'playbackQueuePos'};
        }
        
        # the request was successful and is not async, send results back to caller!
        &{$responseCallback}($result);
}

sub sendPlaybackQueueChangedNotification {
	my $client = shift;
	
	my $playerConfiguration = $prefs->get('player_'.$client->id) || {};
	my $playerStatus = $prefs->get('playerstatus_'.$client->id);
	my $notification = {
		'jsonrpc' => '2.0',
		'method' => 'playbackQueueChanged',
		'params' => {}
	};
	if(defined($playerStatus->{'playlistId'})) {
		$notification->{'params'}->{'playlistId'} = $playerStatus->{'playlistId'}
	}
	if(defined($playerStatus->{'playlistName'})) {
		$notification->{'params'}->{'playlistName'} = $playerStatus->{'playlistName'}
	}
	my $playbackQueue = Plugins::IckStreamPlugin::PlaybackQueueManager::getPlaybackQueue($client);
	$notification->{'params'}->{'countAll'} = scalar(@{$playbackQueue});
	
	if(Plugins::IckStreamPlugin::PlaybackQueueManager::getLastChanged($client)) {
		$notification->{'lastChanged'} = Plugins::IckStreamPlugin::PlaybackQueueManager::getLastChanged($client);
	}
	
    if($log->is_debug) { my $val = dclone($notification);$log->debug("notification: ".Data::Dump::dump($val)); }

    my $serverIP = Slim::Utils::IPDetect::IP();
	my $params = { timeout => 35 };
	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			$log->warn("Successfully sent playbackQueueChanged");
		},
		sub {
			$log->warn("Error when sending playbackQueueChanged");
		},
		$params
	)->post("http://".$serverIP.":".$prefs->get('daemonPort')."/sendMessage",'Content-Type' => 'application/json','Authorization'=>$playerConfiguration->{'id'},to_json($notification));
}

sub sendPlayerStatusChangedNotification {
	my $client = shift;
	
	my $notification = {
		'jsonrpc' => '2.0',
		'method' => 'playerStatusChanged',
		'params' => {}
	};
	
	
	my $playerConfiguration = $prefs->get('player_'.$client->id) || {};
	if(defined($playerConfiguration->{'accessToken'})) {
		$notification->{'params'}->{'cloudCoreStatus'} = 'REGISTERED';
	}else {
		$notification->{'params'}->{'cloudCoreStatus'} = 'UNREGISTERED';
	}
	
	my $playerStatus = $prefs->get('playerstatus_'.$client->id);
	if(defined($playerStatus->{'playbackQueuePos'})) {
       	my $playbackQueue = Plugins::IckStreamPlugin::PlaybackQueueManager::getPlaybackQueue($client);
       	
		$notification->{'params'}->{'playbackQueuePos'} = $playerStatus->{'playbackQueuePos'};
		$notification->{'params'}->{'track'} = @{$playbackQueue}[$playerStatus->{'playbackQueuePos'}];
	}
	$notification->{'params'}->{'playbackQueueMode'} = $playerStatus->{'playbackQueueMode'};

    my $vol = abs($serverPrefs->client($client)->get('volume'));
    my $volume = ($vol - $client->minVolume())/($client->maxVolume()-$client->minVolume());
    my $mute = bless(do{\(my $o = 0)}, "JSON::XS::Boolean");
    if($serverPrefs->client($client)->get('mute')) {
    	$mute = bless(do{\(my $o = 1)}, "JSON::XS::Boolean");
    }
    $notification->{'params'}->{'volumeLevel'} = $volume;
    $notification->{'params'}->{'muted'} = $mute;
    my $timestamp = int(Time::HiRes::time() * 1000);
    $notification->{'params'}->{'lastChanged'} = 0+$timestamp;

	my $playMode = Slim::Player::Source::playmode($client);
	my $playing = bless(do{\(my $o = 0)}, "JSON::XS::Boolean");
	if($playMode eq 'play') {
	       $playing = bless(do{\(my $o = 1)}, "JSON::XS::Boolean");
	}
	$notification->{'params'}->{'playing'} = $playing;

    if($log->is_debug) { my $val = dclone($notification);$log->debug("notification: ".Data::Dump::dump($val)); }

    my $serverIP = Slim::Utils::IPDetect::IP();
	my $params = { timeout => 35 };
	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			$log->warn("Successfully sent playerStatusChanged");
		},
		sub {
			$log->warn("Error when sending playerStatusChanged");
		},
		$params
	)->post("http://".$serverIP.":".$prefs->get('daemonPort')."/sendMessage",'Content-Type' => 'application/json','Authorization'=>$playerConfiguration->{'id'},to_json($notification));
}

sub getDefaultPlayerStatus() {
	return {
		'playbackQueueMode' => 'QUEUE'
		
	};
}

sub moveToNextTrack {
	my $player = shift;
	if(!$inProcessOfChangingPlaylist->{$player->id}) {
		my $playerStatus = $prefs->get('playerstatus_'.$player->id) || getDefaultPlayerStatus();
		if(defined($playerStatus->{'playbackQueuePos'})) {
	       	my $playbackQueue = Plugins::IckStreamPlugin::PlaybackQueueManager::getPlaybackQueue($player);
	       	
			my $playbackQueuePos = $playerStatus->{'playbackQueuePos'};
			my $playing = 0;
			if(scalar(@{$playbackQueue})>($playbackQueuePos + 1)) {
				$playerStatus->{'playbackQueuePos'} += 1;
				$playing = 1;
			}else {
				if($playerStatus->{'playbackQueueMode'} eq 'QUEUE_REPEAT_SHUFFLE') {
		        	fisher_yates_shuffle($playbackQueue);
		        	Plugins::IckStreamPlugin::PlaybackQueueManager::setPlaybackQueue($player, $playbackQueue);

		        	$playerStatus->{'playbackQueuePos'} = 0;
		        	sendPlaybackQueueChangedNotification($player);
		        	$playing = 1;
				}elsif($playerStatus->{'playbackQueueMode'} eq 'QUEUE_REPEAT') {
		        	$playerStatus->{'playbackQueuePos'} = 0;
		        	$playing = 1;
				}
			}
        	$prefs->set('playerstatus_'.$player->id,$playerStatus);
        	if($playing) {
				my $notification = refreshCurrentPlaylist($player);
				if($notification) {
			        sendPlayerStatusChangedNotification($player);
				}
        	}else {
		        sendPlayerStatusChangedNotification($player);
        	}
		}
	}else {
		$inProcessOfChangingPlaylist->{$player->id} = 0;
	}
}

sub handleJSONRPC {
	my ($httpClient, $httpResponse) = @_;

        # make sure we're connected
        if (!$httpClient->connected()) {
                $log->warn("Aborting, client not connected: $httpClient");
                return;
        }

        # cancel any previous subscription on this connection
        # we must have a context defined and a subscription defined
        if (defined(Plugins::IckStreamPlugin::JsonHandler::getContext($httpClient)) && 
                Slim::Control::Request::unregisterAutoExecute($httpClient)) {
        
                # we want to send a last chunk to close the connection as per HTTP...
                # a subscription is essentially a never ending response: we're receiving here
                # a new request (aka pipelining) so we want to be nice and close the previous response
                
                # we cannot have a subscription if this is not a long lasting, keep-open, chunked connection.
                
                Slim::Web::HTTP::addHTTPLastChunk($httpClient, 0);
        }

        # get the request data (POST for JSON 2.0)
        my $input = $httpResponse->request()->content();

        if (!$input) {

                # No data
                # JSON 2.0 => close connection
                $log->warn("No POST data found => closing connection");

                Slim::Web::HTTP::closeHTTPSocket($httpClient);
                return;
        }

        $log->is_info && $log->info("POST data: [$input]");

        # create a hash to store our context
        my $context = {};
        $context->{'httpClient'} = $httpClient;
        $context->{'httpResponse'} = $httpResponse;
        my $uri = $httpResponse->request()->uri();
        my $query = $uri->query();

		my $httpParams = {};
		foreach my $param (split /\&/, $query) {

			if ($param =~ /([^=]+)=(.*)/) {
				my $name  = Slim::Utils::Misc::unescape($1, 1);
				my $value = Slim::Utils::Misc::unescape($2, 1);
				$httpParams->{$name} = $value;
			}
		}
		$log->is_info && $log->info( "Device information: " . Data::Dump::dump($httpParams) );
  
		my $procedure = undef;
		eval {
	        # Parse the input
	        # Convert JSON to Perl
	        # FIXME: JSON 2.0 accepts multiple requests ? How do we parse that efficiently?
	        $procedure = from_json($input);
		};
        if ($@) {
				Plugins::IckStreamPlugin::JsonHandler::generateJSONResponse($context, undef, {
					'code' => -32700,
					'message' => 'Invalid JSON'
				});
				return;
        }

        # Validate the procedure
        # We must get a JSON object, i.e. a hash
        if (ref($procedure) ne 'HASH') {
                
                $log->warn("Cannot parse POST data into Perl hash => closing connection");
                
                Slim::Web::HTTP::closeHTTPSocket($httpClient);
                return;
        }
        
        if ( main::DEBUGLOG && $log->is_debug ) {
                $log->debug( "JSON parsed procedure: " . Data::Dump::dump($procedure) );
        }

        $context->{'procedure'} = $procedure;
		
		# ignore notifications (which don't have an id)
		if (!defined($procedure->{'id'})) {
				$log->debug("Ignoring notification: ".Data::Dump::dump($procedure));
                Slim::Web::HTTP::closeHTTPSocket($httpClient);
                return;
		}

		# ignore errors, just log them
		if (defined($procedure->{'error'})) {
				$log->warn("JSON error on id=".$procedure->{'id'}.": ".$procedure->{'error'}->{'code'}.":".$procedure->{'error'}->{'code'}.(defined($procedure->{'error'}->{'data'})?"(".$procedure->{'error'}->{'data'}.")":""));
                Slim::Web::HTTP::closeHTTPSocket($httpClient);
                return;
		}

        # we must have a method
        my $method = $procedure->{'method'};

        if (!$method) {
				if(defined($procedure->{'result'})) {
					if(!Plugins::IckStreamPlugin::LocalServiceManager::responseCallback($procedure)) {
						Plugins::IckStreamPlugin::ProtocolHandler::responseCallback($procedure);
					}
	                Slim::Web::HTTP::closeHTTPSocket($httpClient);
					return;
				}
				Plugins::IckStreamPlugin::JsonHandler::generateJSONResponse($context, undef, {
					'code' => -32601,
					'message' => 'Method not found',
					'data' => $method
				});
				return;
        }

        # figure out the method wanted
        my $funcPtr = $methods{$method};
        
        if (!$funcPtr) {

				Plugins::IckStreamPlugin::JsonHandler::generateJSONResponse($context, undef, {
					'code' => -32601,
					'message' => 'Method not found',
					'data' => $method
				});
				return;
                
        } elsif (ref($funcPtr) ne 'CODE') {
                # return internal server error
                $log->error("Procedure $method refers to non CODE ??? => closing connection");
                
                Slim::Web::HTTP::closeHTTPSocket($httpClient);
                return;
        }
        

        # parse the parameters
        my $params = $procedure->{'params'};

        if (defined($params) && ref($params) ne 'HASH') {
                
                # error, params is an array or an object
                $log->warn("Procedure $method has params not HASH => closing connection");
                Slim::Web::HTTP::closeHTTPSocket($httpClient);
                return;
        }        

        # Detect the language the client wants content returned in
        if ( my $lang = $httpResponse->request->header('Accept-Language') ) {
                my @parts = split(/[,-]/, $lang);
                $context->{lang} = uc $parts[0] if $parts[0];
        }

        if ( my $ua = ( $httpResponse->request->header('X-User-Agent') || $httpResponse->request->header('User-Agent') ) ) {
                $context->{ua} = $ua;
        }

        # Check our operational mode using our X-Jive header
        # We must be delaing with a 1.1 client because X-Jive uses chunked transfers
        # We must not be closing the connection
        if (defined(my $xjive = $httpResponse->request()->header('X-Jive')) &&
                $httpClient->proto_ge('1.1') &&
                $httpResponse->header('Connection') !~ /close/i) {
        
                main::INFOLOG && $log->info("Operating in x-jive mode for procedure $method and client $httpClient");
                $context->{'x-jive'} = 1;
                $httpResponse->header('X-Jive' => 'Jive')
        }
                
        # remember we need to send headers. We'll reset this once sent.
        $context->{'sendheaders'} = 1;
        
        # store our context. It'll get erased by the callback in HTTP.pm through handleClose
        Plugins::IckStreamPlugin::JsonHandler::setContext($httpClient, $context);

		# Get player for uuid
		my $players = $prefs->get('players');
		my $player = undef;
		if(defined($httpParams->{'toDeviceId'}) && $players->{$httpParams->{'toDeviceId'}}) {
			$player = Slim::Player::Client::getClient($players->{$httpParams->{'toDeviceId'}});
		}
		
        # jump to the code handling desired method. It is responsible to send a suitable output
        eval { &{$funcPtr}($context,$player, sub {
        	my $result = shift;
        	Plugins::IckStreamPlugin::JsonHandler::requestWrite($result,$context->{'httpClient'}, $context);
        }); };

        if ($@) {
                my $funcName = Slim::Utils::PerlRunTime::realNameForCodeRef($funcPtr);
                $log->error("While trying to run function coderef [$funcName]: [$@]");
                main::DEBUGLOG && $log->error( "JSON parsed procedure: " . Data::Dump::dump($procedure) );

				Plugins::IckStreamPlugin::JsonHandler::generateJSONResponse($context, undef, {
					'code' => -32001,
					'message' => 'Error when executing $funcName',
					'data' => $@
				});
				return;
        }
}

1;

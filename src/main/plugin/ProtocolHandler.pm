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

# Handler for ickstream:// URLs
package Plugins::IckStreamPlugin::ProtocolHandler;

use strict;
use base qw(Slim::Player::Protocols::HTTP);
use Scalar::Util qw(blessed);

use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Prefs;
use JSON::XS::VersionOneAndTwo;
use Data::Dumper;
use Plugins::IckStreamPlugin::ItemCache;
use Plugins::IckStreamPlugin::Plugin;
use Plugins::IckStreamPlugin::CloudServiceManager;


my $log = Slim::Utils::Log->addLogCategory({
	'category'     => 'plugin.ickstream.protocol',
	'defaultLevel' => 'WARN',
	'description'  => 'PLUGIN_ICKSTREAM_PROTOCOL_LOG',
});
my $prefs = preferences('plugin.ickstream');

my $localServiceItemRequestIds = {};
my $localServiceItemStreamingRefRequestIds = {};

sub new {
	my $class  = shift;
	my $args   = shift;
	main::DEBUGLOG && $log->debug("new(".$class.",".$args.")");

	my $client    = $args->{client};
	my $song      = $args->{song};
	my $streamUrl = $song->streamUrl() || return;
        
	main::DEBUGLOG && $log->is_debug && $log->debug( 'Streaming ickStream track: ' . $streamUrl );

	my $sock = $class->SUPER::new( {
		url     => $streamUrl,
		song    => $song,
		client  => $client,
	} ) || return;
        
	${*$sock}{contentType} = 'audio/mpeg';

	return $sock;
}

sub isRemote { 1 }

# Avoid scanning
sub scanUrl {
	my ( $class, $url, $args ) = @_;
	main::DEBUGLOG && $log->debug("scanUrl(".$class.",".$url.",".$args.")");
        
	$args->{cb}->( $args->{song}->currentTrack() );
}

# Source for AudioScrobbler
sub audioScrobblerSource {
	my ( $class, $client, $url ) = @_;
	main::DEBUGLOG && $log->debug("audioScrobblerSource(".$class.",".$client.",".$url.")");

	# P = Chosen by the user
	return 'P';
}

# Don't allow looping
sub shouldLoop { 0 }

# Check if player is allowed to skip
sub canSkip { 1 }

sub handleDirectError {
	my ( $class, $client, $url, $response, $status_line ) = @_;
	main::DEBUGLOG && $log->debug("handleDirectError(".$class.",".$client.",".$url.")");
        
	main::DEBUGLOG && $log->debug("Direct stream failed: [$response] $status_line\n");
        
	$client->controller()->playerStreamingFailed($client, 'PLUGIN_ICKSTREAM_PROTOCOL_HANDLER_DIRECT_STREAM_FAILED');
}

sub _handleClientError {
	my ( $error, $params ) = @_;
        
	my $song = $params->{song};
        
	return if $song->pluginData('abandonSong');
        
	# Tell other clients to give up
	$song->pluginData( abandonSong => 1 );
        
	$params->{errorCb}->($error);
}

sub getNextTrack {
	my ( $class, $song, $successCb, $errorCb ) = @_;
	main::DEBUGLOG && $log->debug("getNextTrack(".$class.",".$song->track()->url.")");
        
	my $url = $song->track()->url;
        
	$song->pluginData( abandonSong   => 0 );
	
	my $params = {
		song      => $song,
		url       => $url,
		successCb => $successCb,
		errorCb   => $errorCb,
	};
        
	_getTrack($params);
}

sub _getTrack {
	my $params = shift;
        
	my $song   = $params->{song};
	my $client = $song->master();

	# Get track URL for the next track
	my ($trackId,$serviceId) = _getStreamParams( $params->{url} );
	
	my $error;
	if($song->pluginData('abandonSong')) {
		$log->warn('Ignoring track, as it is known to be invalid: ' . $trackId);
		_gotTrackError($error || 'Invalid track ID', $params);
		return;
	}
	
	my $meta = Plugins::IckStreamPlugin::ItemCache::getItemFromCache( $trackId );
	my $playerConfiguration = $prefs->get('player_'.$client->id()) || {};
	if($serviceId =~ /[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/) {
		if(!$meta) {
			$log->info("Getting metadata for ".$trackId." for ".$client->name());
			
		    my $serverIP = Slim::Utils::IPDetect::IP();
			my $httpParams = { timeout => 35 };
			my $requestId = Plugins::IckStreamPlugin::Plugin::getNextRequestId();
			$localServiceItemRequestIds->{$requestId} = $params;
			
			Slim::Networking::SimpleAsyncHTTP->new(
				sub {
					$log->warn("Successfully sent getItem request");
				},
				sub {
					$log->warn("Error when sending getItem request");
				},
				$httpParams
			)->post("http://".$serverIP.":".$prefs->get('daemonPort')."/sendMessage/".$serviceId."/2",'Content-Type' => 'application/json','Authorization'=>$playerConfiguration->{'id'},to_json({
				'jsonrpc' => '2.0',
				'id' => $requestId,
				'method' => 'getItem',
				'params' => {
					'contextId' => 'allMusic',
					'itemId' => $trackId
				}
			}));

		}elsif(!defined($meta->{'url'})) {
			$params->{'meta'} = $meta;
			my $requestId = Plugins::IckStreamPlugin::Plugin::getNextRequestId();
			$localServiceItemStreamingRefRequestIds->{$requestId} = $params;
			
		    my $serverIP = Slim::Utils::IPDetect::IP();
			my $httpParams = { timeout => 35 };
			Slim::Networking::SimpleAsyncHTTP->new(
				sub {
					$log->warn("Successfully sent getItemStreamingRef request");
				},
				sub {
					$log->warn("Error when sending getItemStreamingRef request");
				},
				$httpParams
			)->post("http://".$serverIP.":".$prefs->get('daemonPort')."/sendMessage/".$serviceId."/2",'Content-Type' => 'application/json','Authorization'=>$playerConfiguration->{'id'},to_json({
				'jsonrpc' => '2.0',
				'id' => $requestId,
				'method' => 'getItemStreamingRef',
				'params' => {
					'contextId' => 'allMusic',
					'itemId' => $trackId
				}
			}));
		}else {
			_gotTrack( undef, undef, $meta, $params );
		}
	}else {
		my $httpParams = { timeout => 35 };
		my $uuid = $playerConfiguration->{'id'};
		my $serverIP = Slim::Utils::IPDetect::IP();
		if(!$meta) {
			Plugins::IckStreamPlugin::CloudServiceManager::getService($client, $serviceId,
				sub {
					my $serviceUrl = Plugins::IckStreamPlugin::CloudServiceManager::getServiceUrl($client, $serviceId);
					$log->info("Getting metadata for ".$trackId." for ".$client->name());
					
					Slim::Networking::SimpleAsyncHTTP->new(
						sub {
							my $http = shift;
							my $jsonResponse = from_json($http->content);
							main::DEBUGLOG && $log->debug(Dumper($http->content));
							if($jsonResponse && $jsonResponse->{'result'}) {
								$log->info("Successfully retrieved metadata for ".$client->name());
								my $info = $jsonResponse->{'result'};
								if(defined($info->{'streamingRefs'}) && $info->{'streamingRefs'}->[0]->{'url'}) {
									_gotTrack( $info, $info->{'streamingRefs'}->[0], undef, $params );
								}else {
									$log->info("Getting stream for ".$trackId." for ".$client->name());
									Slim::Networking::SimpleAsyncHTTP->new(
										sub {
											my $http = shift;
											my $jsonResponse = from_json($http->content);
											main::DEBUGLOG && $log->debug(Dumper($http->content));
											if($jsonResponse && $jsonResponse->{'result'}) {
												$log->info("Successfully retrieved stream ".$trackId." for ".$client->name());
												_gotTrack( $info, $jsonResponse->{'result'}, undef, $params );
											}else {
												$log->warn("Failed to retrieve stream for ".$client->name().": ".Dumper($jsonResponse));
												_gotTrackError("getTrack failed in getItemStreamingRef: ".$trackId, $params);
											}
										},
										sub {
											my $http = shift;
											my $error = shift;
											$log->warn("Failed to retrieve stream ".$trackId." for ".$client->name().": ".$error);
											_gotTrackError("getTrack failed in getItem: ".$trackId, $params);
										},
										undef
									)->post($serviceUrl,'Content-Type' => 'application/json','Authorization'=>'Bearer '.$playerConfiguration->{'accessToken'},to_json({
										'jsonrpc' => '2.0',
										'id' => 1,
										'method' => 'getItemStreamingRef',
										'params' => {
											'contextId' => 'allMusic',
											'itemId' => $trackId
										}
									}));
								}
							}else {
								main::DEBUGLOG && $log->debug(Dumper($http->content));
								$log->warn("Failed to retrieve metadata for ".$client->name().": ".Dumper($jsonResponse));
								_gotTrackError("getTrack failed in getItem: ".$trackId, $params);
							}
						},
						sub {
							my $http = shift;
							my $error = shift;
							$log->warn("Failed to retrieve metadata for ".$client->name().": ".$error);
							_gotTrackError("getTrack failed in getItem: ".$trackId, $params);
						},
						undef
					)->post($serviceUrl,'Content-Type' => 'application/json','Authorization'=>'Bearer '.$playerConfiguration->{'accessToken'},to_json({
						'jsonrpc' => '2.0',
						'id' => 1,
						'method' => 'getItem',
						'params' => {
							'contextId' => 'allMusic',
							'itemId' => $trackId
						}
					}));
				});
		}elsif(!defined($meta->{'url'})) {
			Plugins::IckStreamPlugin::CloudServiceManager::getService($client, $serviceId,
				sub {
					my $serviceUrl = Plugins::IckStreamPlugin::CloudServiceManager::getServiceUrl($client, $serviceId);
					$log->info("Getting stream for ".$trackId." for ".$client->name());
					Slim::Networking::SimpleAsyncHTTP->new(
						sub {
							my $http = shift;
							my $jsonResponse = from_json($http->content);
							main::DEBUGLOG && $log->debug(Dumper($http->content));
							if($jsonResponse && $jsonResponse->{'result'}) {
								$log->info("Successfully retrieved stream ".$trackId." for ".$client->name());
								_gotTrack( undef, $jsonResponse->{'result'}, $meta, $params );
							}else {
								$log->warn("Failed to retrieve stream ".$trackId." for ".$client->name().": ".Dumper($jsonResponse));
								_gotTrackError("getTrack failed in getItemStreamingRef: ".$trackId, $params);
							}
						},
						sub {
							my $http = shift;
							my $error = shift;
							$log->warn("Failed to retrieve stream ".$trackId." for ".$client->name().": ".$error);
							_gotTrackError("getTrack failed in getItemStreamingRef: ".$trackId, $params);
						},
						undef
					)->post($serviceUrl,'Content-Type' => 'application/json','Authorization'=>'Bearer '.$playerConfiguration->{'accessToken'},to_json({
						'jsonrpc' => '2.0',
						'id' => 1,
						'method' => 'getItemStreamingRef',
						'params' => {
							'contextId' => 'allMusic',
							'itemId' => $trackId
						}
					}));
				});
		}else {
			_gotTrack(undef,undef,$meta,$params);
		}
	}
}

sub responseCallback {
	my $jsonResponse = shift;
	if(defined($localServiceItemRequestIds->{$jsonResponse->{'id'}})) {
		my $params = $localServiceItemRequestIds->{$jsonResponse->{'id'}}; 
		$localServiceItemRequestIds->{$jsonResponse->{'id'}} = undef;
		
		my $song   = $params->{song};
		my $client = $song->master();
		
		my $playerConfiguration = $prefs->get('player_'.$client->id) || {};
		my ($trackId,$serviceId) = _getStreamParams( $params->{url} );
		if($jsonResponse && $jsonResponse->{'result'}) {
			$log->info("Successfully retrieved metadata for ".$trackId);
			my $info = $jsonResponse->{'result'};
			if(defined($info->{'streamingRefs'}) && $info->{'streamingRefs'}->[0]->{'url'}) {
				_gotTrack( $info, $info->{'streamingRefs'}->[0], undef, $params );
			}else {
				$params->{'item'} = $info;
				my $requestId = Plugins::IckStreamPlugin::Plugin::getNextRequestId();
				$localServiceItemStreamingRefRequestIds->{$requestId} = $params;
				
			    my $serverIP = Slim::Utils::IPDetect::IP();
				my $httpParams = { timeout => 35 };
				Slim::Networking::SimpleAsyncHTTP->new(
					sub {
						$log->warn("Successfully sent getItemStreamingRef request");
					},
					sub {
						my $http = shift;
						my $error = shift;
						$log->warn("Error when sending getItemStreamingRef request: ".$error);
					},
					$httpParams
				)->post("http://".$serverIP.":".$prefs->get('daemonPort')."/sendMessage/".$serviceId."/2",'Content-Type' => 'application/json','Authorization'=>$playerConfiguration->{'id'},to_json({
					'jsonrpc' => '2.0',
					'id' => $requestId,
					'method' => 'getItemStreamingRef',
					'params' => {
						'contextId' => 'allMusic',
						'itemId' => $trackId
					}
				}));
			}
		}else {
			$log->warn("Failed to metadata stream for ".$trackId.": ".Dumper($jsonResponse));
			_gotTrackError("getTrack failed in getItem: ".$trackId, $params);
		}
		return 1;
	}elsif(defined($localServiceItemStreamingRefRequestIds->{$jsonResponse->{'id'}})) {
		my $params = $localServiceItemStreamingRefRequestIds->{$jsonResponse->{'id'}}; 
		$localServiceItemStreamingRefRequestIds->{$jsonResponse->{'id'}} = undef;
	
		my ($trackId,$serviceId) = _getStreamParams( $params->{url} );
		
		main::DEBUGLOG && $log->debug(Dumper($jsonResponse));
		if($jsonResponse && $jsonResponse->{'result'}) {
			if(defined($params->{'item'})) {
				$log->info("Successfully retrieved stream ".$params->{'item'}->{'id'});
				_gotTrack( $params->{'item'}, $jsonResponse->{'result'}, undef, $params );
			}else {
				$log->info("Successfully retrieved stream ".$trackId);
				_gotTrack( undef, $jsonResponse->{'result'}, $params->{'meta'}, $params );
			}
		}else {
			$log->warn("Failed to retrieve stream for ".$trackId.": ".Dumper($jsonResponse));
			_gotTrackError("getTrack failed in getItemStreamingRef: ".$params->{'item'}->{'id'}, $params);
		}
		return 1;

	}
	return undef;
}

sub _gotTrack {
	my ($item, $streamingRef, $meta, $params ) = @_;
        
	my $song = $params->{song};
	my ($trackId,$serviceId) = _getStreamParams( $params->{url} );
    
    return if $song->pluginData('abandonSong');
    
    main::DEBUGLOG && $log->debug("Got item: ".Dumper($item)) if(defined($item));
    main::DEBUGLOG && $log->debug("Got meta: ".Dumper($meta)) if(defined($meta));
    main::DEBUGLOG && defined($streamingRef) && $log->debug("Got streamingRef: ".Dumper($streamingRef));

    if($streamingRef) {
    	my $url = $streamingRef->{'url'};
		if($url =~ /^service:\/\//) {
	    	main::DEBUGLOG && $log->debug("Resolving streaming url: ".$url);
			$url = Plugins::IckStreamPlugin::LocalServiceManager::resolveServiceUrl($serviceId,$url);
		}
    	main::DEBUGLOG && $log->debug("Got streaming url: ".$url);
		# Save the media URL for use in strm
		$song->streamUrl($url);
    }elsif(defined($meta) && defined($meta->{'url'})) {
    	my $url = $meta->{'url'};
		if($url =~ /^service:\/\//) {
	    	main::DEBUGLOG && $log->debug("Resolving streaming url: ".$url);
			$url = Plugins::IckStreamPlugin::LocalServiceManager::resolveServiceUrl($serviceId,$url);
		}
    	main::DEBUGLOG && $log->debug("Reusing streaming url: ".$url);
		# Save the media URL for use in strm
    	$song->streamUrl($url);
    }

	if(defined($item)) {
	    $meta = Plugins::IckStreamPlugin::ItemCache::setItemInCache($item->{id},$item, $streamingRef);
	}elsif(defined($streamingRef)) {
		$meta = Plugins::IckStreamPlugin::ItemCache::setItemStreamingRefInCache($trackId, $meta, $streamingRef);
	}

	if(defined($meta->{'cover'}) && $meta->{'cover'} =~ /^service:\/\//) {
		$meta->{'cover'} = Plugins::IckStreamPlugin::LocalServiceManager::resolveServiceUrl($serviceId,$meta->{'cover'});	
	}

	$song->duration( $meta->{duration} );
	# Save all the info
	$song->pluginData( info => $meta );
        

	if($params) {
		$params->{successCb}->();
	}
}

sub formatOverride {
	my $self = shift;
	my $song = shift;
	
	my $track = $song->currentTrack();
	my ($trackId,$serviceId) = _getStreamParams( $track->url );

	my $meta = Plugins::IckStreamPlugin::ItemCache::getItemFromCache($trackId);
	$log->debug("Cached meta for ".$trackId.": ".Dumper($meta));
	if($meta && $meta->{'format'}) {
		my $format = Slim::Music::Info::mimeToType($meta->{'format'});
		$log->debug("formatOverride = $format");
		return $format;
	}else {
		$log->debug("formatOverride = mp3 (default)");
		return 'mp3';
	}	
}

sub _gotTrackError {
	my ( $error, $params ) = @_;
        
	main::DEBUGLOG && $log->debug("Error during getTrackInfo: $error");

	return if $params->{song}->pluginData('abandonSong');

	_handleClientError( $error, $params );
}

sub canDirectStreamSong {
	my ( $class, $client, $song ) = @_;
	main::DEBUGLOG && $log->debug("canDirectStreamSong(".$class.",".$client.",".$song->track->url().",".$song->streamUrl().")");
	# We need to check with the base class (HTTP) to see if we
	# are synced or if the user has set mp3StreamingMethod
	my $url = $class->SUPER::canDirectStream( $client, $song->streamUrl(), $class->getFormatForURL($song->track->url()) );
	$log->debug("canDirectStreamSong: ".$url);
	return $url;
}

sub getFormatForURL {
	my ( $self, $url) = @_;
	main::DEBUGLOG && $log->debug("getFormatForURL(".$self.",".$url.")");
	
	my ($trackId,$serviceId) = _getStreamParams($url);

	my $meta = Plugins::IckStreamPlugin::ItemCache::getItemFromCache($trackId);
	if($meta && $meta->{'format'}) {
		my $format = Slim::Music::Info::mimeToType($meta->{'format'});
		$log->debug("getFormatForURL = ".$format);
		return $format;
	}else {
		$log->debug("getFormatForURL = mp3 (default)");
		return 'mp3';
	}
}



# Metadata for a URL, used by CLI/JSON clients
sub getMetadataFor {
	my ( $class, $client, $url ) = @_;
	#main::DEBUGLOG && $log->debug("getMetadataFor(".$class.",".$client.",".$url.")");
        
	my $icon = $class->getIcon();
        
	return {} unless $url;
         
	# If metadata is not here, fetch it so the next poll will include the data
	my ($trackId,$serviceId) = _getStreamParams( $url );
	my $meta = Plugins::IckStreamPlugin::ItemCache::getItemFromCache($trackId);

	if ( !$meta && !$client->master->pluginData('ickStreamFetchingMeta-'.$trackId)) {
		$client->master->pluginData('ickStreamFetchingMeta-'.$trackId => 1);
		my $httpParams = { timeout => 35 };
		my $playerConfiguration = $prefs->get('player_'.$client->id()) || {};
		my $uuid = $playerConfiguration->{'id'};
		Plugins::IckStreamPlugin::CloudServiceManager::getService($client,$serviceId,
			sub {
				my $serviceUrl = Plugins::IckStreamPlugin::CloudServiceManager::getServiceUrl($client, $serviceId);
				my $serverIP = Slim::Utils::IPDetect::IP();
			
				$log->info("Getting metadata for ".$trackId." for ".$client->name());
				Slim::Networking::SimpleAsyncHTTP->new(
					sub {
						my $http = shift;
						$client->master->pluginData('ickStreamFetchingMeta-'.$trackId => 0);
						main::DEBUGLOG && $log->debug(Dumper($http->content));
						my $jsonResponse = from_json($http->content);
						if($jsonResponse && $jsonResponse->{'result'}) {
							$log->info("Successfully retrieved metadata for ".$trackId." on ".$client->name());
							my $info = $jsonResponse->{'result'};
							my $icon = Plugins::IckStreamPlugin::Plugin->_pluginDataFor('icon');
		
							Plugins::IckStreamPlugin::ItemCache::setItemInCache($info->{id},$info);					        
						}else {
							$log->warn("Failed to retrieve metadata for ".$trackId." on ".$client->name().": ".Dumper($jsonResponse));
						}
					},
					sub {
						my $http = shift;
						my $error = shift;
						$client->master->pluginData('ickStreamFetchingMeta-'.$trackId => 0);
						$log->warn("Failed to retrieve metadata for ".$trackId." on ".$client->name().": ".$error);
					},
					undef
				)->post($serviceUrl,'Content-Type' => 'application/json','Authorization'=>'Bearer '.$playerConfiguration->{'accessToken'},to_json({
					'jsonrpc' => '2.0',
					'id' => 1,
					'method' => 'getItem',
					'params' => {
						'contextId' => 'allMusic',
						'itemId' => $trackId
					}
				}));
			});

	}elsif(!$meta) {
		#$log->debug("Already fetching metadata for ".$trackId);
	}else {
		if(defined($meta->{'cover'}) && $meta->{'cover'} =~ /^service:\/\//) {
			$meta->{'cover'} = Plugins::IckStreamPlugin::LocalServiceManager::resolveServiceUrl($serviceId,$meta->{'cover'});	
		}
		#$log->debug("Using cached metadata for ".$trackId);
	}
	
	#main::DEBUGLOG && $log->debug("returning ".Dumper($meta));
	
	return $meta || {
		icon      => $icon,
		cover     => $icon,
	};
}

sub getIcon {
	my ( $class, $url ) = @_;
	#main::DEBUGLOG && $log->debug("getIcon(".$class.",".$url.")");

	return Plugins::IckStreamPlugin::Plugin->_pluginDataFor('icon');
}

sub _getStreamParams {
        $_[0] =~ m{ickstream://(.+)}i;
        my $trackId = $1;
        $trackId =~ m{(.+?):.+}i;
        return ($trackId,$1);
}

1;

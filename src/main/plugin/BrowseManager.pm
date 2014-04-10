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

package Plugins::IckStreamPlugin::BrowseManager;

use strict;
use Scalar::Util qw(blessed);
use Plugins::IckStreamPlugin::Plugin;
use Plugins::IckStreamPlugin::ItemCache;
use Slim::Utils::Prefs;
use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Strings qw(string cstring);
use JSON::XS::VersionOneAndTwo;
use Data::Dumper;
use Tie::Cache::LRU;

my $log = Slim::Utils::Log->addLogCategory({
	'category'     => 'plugin.ickstream.browse',
	'defaultLevel' => 'WARN',
	'description'  => 'PLUGIN_ICKSTREAM_BROWSE_LOG',
});
my $prefs = preferences('plugin.ickstream');

my $cloudServiceEntries = {};
my $cloudServiceProtocolEntries = {};

tie my %cache, 'Tie::Cache::LRU', 10;
use constant CACHE_TIME => 300;

sub getAccessToken {
	my $player = shift;
	
	if(defined($player)) {
		my $playerConfiguration = $prefs->get('player_'.$player->id) || {};
		if(defined($playerConfiguration->{'accessToken'})) {
			return $playerConfiguration->{'accessToken'};
		}
	}
	my $accessToken = $prefs->get('accessToken');
	return $accessToken;
}

sub topLevel {
        my ($client, $cb, $args) = @_;
        
        my $params = $args->{params};
        
		my $accessToken = getAccessToken($client);
		
		if(!defined($accessToken)) {
			$cb->({items => [{
                        name => cstring($client, 'PLUGIN_ICKSTREAM_BROWSE_REQUIRES_CREDENTIALS'),
                        type => 'textarea',
                }]});
		}else {
				my $cloudCoreUrl = 'http://api.ickstream.com/ickstream-cloud-core/jsonrpc';
				my $requestParams = to_json({
							'jsonrpc' => '2.0',
							'id' => 1,
							'method' => 'findServices',
							'params' => {
								'type' => 'content'
							}
						});
				my $cacheKey = "$accessToken.$requestParams";
				if((time() - $cache{$cacheKey}->{'time'}) < CACHE_TIME) {
					$log->debug("Using cached content services from cloud");
					$cb->({items => $cache{$cacheKey}->{'data'}});
					return;
				}
				$log->info("Retrieve content services from cloud");
				Slim::Networking::SimpleAsyncHTTP->new(
							sub {
								my $http = shift;
								my $jsonResponse = from_json($http->content);
								$cloudServiceEntries = {};
								my @services = ();
								if($jsonResponse->{'result'} && $jsonResponse->{'result'}->{'items'}) {
									foreach my $service (@{$jsonResponse->{'result'}->{'items'}}) {
										$log->debug("Found ".$service->{'name'});
										$cloudServiceEntries->{$service->{'id'}} = $service;
										my $serviceEntry = {
											name => $service->{'name'},
											url => \&serviceContextMenu,
											passthrough => [$service->{'id'}]
										};
										push @services,$serviceEntry;
									}
									$log->debug("Got ".scalar(@services)." items");
								}else {
									$log->warn("Error: ".Dumper($jsonResponse));
								}
								if(scalar(@services)>0) {
									$cache{$cacheKey} = { 'data' => \@services, 'time' => time()};
									$cb->({items => \@services});
								}else {
									$cb->({items => [{
										name => cstring($client, 'PLUGIN_ICKSTREAM_BROWSE_ADD_SERVICES'),
										type => 'textarea',
					                }]});
								}
							},
							sub {
								$log->info("Failed to retrieve content services from cloud");
								$cb->(items => [{
									name => cstring($client, 'PLUGIN_ICKSTREAM_BROWSE_REQUIRES_CREDENTIALS'),
									type => 'textarea',
				                }]);
							},
							undef
						)->post($cloudCoreUrl,'Content-Type' => 'application/json','Authorization'=>'Bearer '.$accessToken,$requestParams);

		}
}

sub getProtocolDescription {
	my $client = shift;
	my $serviceId = shift;
	my $successCb = shift;
	my $errorCb = shift;
	
	my $accessToken = getAccessToken($client);
	if(!defined($accessToken)) {
		&{$errorCb}($serviceId);
	}

	if(defined($cloudServiceProtocolEntries->{$serviceId})) {
		&{$successCb}($serviceId,$cloudServiceProtocolEntries->{$serviceId});
	}else {
		$log->info("Retrieve protocol description for ".$serviceId);
		my $serviceUrl = $cloudServiceEntries->{$serviceId}->{'url'};
		$log->info("Retriving data from: $serviceUrl");
		Slim::Networking::SimpleAsyncHTTP->new(
					sub {
						my $http = shift;
						my $jsonResponse = from_json($http->content);
						my @menus = ();
						if($jsonResponse->{'result'}) {
							$cloudServiceProtocolEntries->{$serviceId} = $jsonResponse->{'result'};
							&{$successCb}($serviceId,$cloudServiceProtocolEntries->{$serviceId});
						}else {
							$log->info("Failed to retrieve protocol description for ".$serviceId.": ".Dumper($jsonResponse));
							&{$errorCb}($serviceId);
						}
					},
					sub {
						$log->info("Failed to retrieve protocol description for ".$serviceId);
						&{$errorCb}($serviceId);
					},
					undef
				)->post($serviceUrl,'Content-Type' => 'application/json','Authorization'=>'Bearer '.$accessToken,to_json({
					'jsonrpc' => '2.0',
					'id' => 1,
					'method' => 'getProtocolDescription',
					'params' => {
					}
				}));
		
	}
}
sub serviceContextMenu {
	my ($client, $cb, $args, $serviceId) = @_;
	
	my $accessToken = getAccessToken($client);
	if(!defined($accessToken)) {
		$cb->({items => [{
                       name => cstring($client, 'PLUGIN_ICKSTREAM_BROWSE_REQUIRES_CREDENTIALS'),
                       type => 'textarea',
               }]});
	}else {
		getProtocolDescription($client, $serviceId,
			sub {
				my $serviceId = shift;
				my $protocolDescription = shift;
				my @menus = ();
				if($protocolDescription->{'items'}) {
					foreach my $context (@{$protocolDescription->{'items'}}) {
						my $supported = undef;
						foreach my $request (@{$context->{'supportedRequests'}}) {
							foreach my $parameters (@{$request->{'parameters'}}) {
								my $unsupported = undef;
								foreach my $parameter (@{$parameters}) {
									if($parameter ne 'contextId' && $parameter ne 'type') {
										$unsupported = 1;
										last;
									}
								}
								if(!$unsupported) {
									$supported = 1;
									last;
								}
							}
							if($supported) {
								last;
							}
						}
						if($supported) {
							my $menu = {
								'name' => $context->{'name'},
								'url' => \&serviceTypeMenu,
								'passthrough' => [
									$serviceId,
									$context->{'contextId'}
								]
							};
							push @menus,$menu;
						}
					}
				}
				if(scalar(@menus)>0) {
					$cb->({items => \@menus});
				}else {
					$cb->({items => [{
						name => cstring($client, 'PLUGIN_ICKSTREAM_BROWSE_NO_ITEMS'),
						type => 'textarea',
	                }]});
				}
			},
			sub {
				$log->info("Failed to retrieve content services from cloud");
				$cb->(items => [{
					name => cstring($client, 'PLUGIN_ICKSTREAM_BROWSE_REQUIRES_CREDENTIALS'),
					type => 'textarea',
                }]);
			});
	}
	        
}

sub getNameForType {
	my $context = shift;
	my $type = shift;
	
	if($type eq 'artist') {
		return 'Artists';
	}elsif($type eq 'album') {
		return 'Albums';
	}elsif($type eq 'track') {
		return 'Songs';
	}elsif($type eq 'stream') {
		return 'Stations';
	}elsif($type eq 'category') {
		return 'Genres';
	}elsif($type eq 'playlist') {
		return 'Playlists';
	}else {
		return $type.'s';
	}
}

sub serviceTypeMenu {
	my ($client, $cb, $args, $serviceId, $contextId) = @_;

	my $accessToken = getAccessToken($client);
	if(!defined($accessToken)) {
		$cb->({items => [{
                       name => cstring($client, 'PLUGIN_ICKSTREAM_BROWSE_REQUIRES_CREDENTIALS'),
                       type => 'textarea',
               }]});
	}else {
		getProtocolDescription($client, $serviceId,
			sub {
				my $serviceId = shift;
				my $protocolDescription = shift;
				my @menus = ();
				if($protocolDescription->{'items'}) {
					foreach my $context (@{$protocolDescription->{'items'}}) {
						if($context->{'contextId'} eq $contextId) {
							my $supported = undef;
							foreach my $request (@{$context->{'supportedRequests'}}) {
								foreach my $parameters (@{$request->{'parameters'}}) {
									my $unsupported = undef;
									foreach my $parameter (@{$parameters}) {
										if($parameter ne 'contextId' && $parameter ne 'type') {
											$unsupported = 1;
											last;
										}
									}
									if(!$unsupported) {
										$supported = 1;
										last;
									}
								}
								if($supported) {
									my $menu = {
										'name' => getNameForType($context->{'contextId'}, $request->{'type'}),
										'url' => \&serviceItemMenu,
										'passthrough' => [
											$serviceId,
											$context->{'contextId'},
											{
												'type' => $request->{'type'}
											}
										]
									};
									push @menus,$menu;
								}
							}
						}
					}
				}
				if(scalar(@menus)>0) {
					$cb->({items => \@menus});
				}else {
					$cb->({items => [{
						name => cstring($client, 'PLUGIN_ICKSTREAM_BROWSE_NO_ITEMS'),
						type => 'textarea',
	                }]});
				}
			},
			sub {
				$log->info("Failed to retrieve content services from cloud");
				$cb->(items => [{
					name => cstring($client, 'PLUGIN_ICKSTREAM_BROWSE_REQUIRES_CREDENTIALS'),
					type => 'textarea',
                }]);
			});
	}
}

sub serviceItemMenu {
	my ($client, $cb, $args, $serviceId, $contextId, $parent) = @_;
	
	my $accessToken = getAccessToken($client);
	if(!defined($accessToken)) {
		$cb->({items => [{
                       name => cstring($client, 'PLUGIN_ICKSTREAM_BROWSE_REQUIRES_CREDENTIALS'),
                       type => 'textarea',
               }]});
	}else {
		getProtocolDescription($client, $serviceId,
			sub {
				my $serviceId = shift;
				my $protocolDescription = shift;
				
				my $contextRequests = undef;
				my $allMusicRequests = undef;
				
				if($protocolDescription->{'items'}) {
					foreach my $context (@{$protocolDescription->{'items'}}) {
						if($context->{'contextId'} eq $contextId) {
							$contextRequests = $context->{'supportedRequests'};
						}elsif($context->{'contextId'} eq 'allMusic') {
							$allMusicRequests = $context->{'supportedRequests'};
						}
					}
				}


				my $serviceUrl = $cloudServiceEntries->{$serviceId}->{'url'};
				my $params = {};
				if(!defined($parent->{'id'}) && defined($parent->{'type'})) {
					$params = createChildRequestParametersFromContext($contextRequests, $contextId,$parent->{'type'},$parent);
				}else {
					$params = createChildRequestParametersFromContext($contextRequests, $contextId,undef,$parent);
					if(!defined($params) && $contextId ne 'allMusic') {
						$params = createChildRequestParametersFromContext($allMusicRequests, 'allMusic',undef,$parent);
					}
				}
				if(defined($args->{'quantity'})) {
					#$params->{'count'} = int($args->{'quantity'});
				}
				if(defined($args->{'index'})) {
					$params->{'offset'} = $args->{'index'};
				}else {
					$params->{'offset'} = 0;
				}
				my $requestParams = to_json({
							'jsonrpc' => '2.0',
							'id' => 1,
							'method' => 'findItems',
							'params' => $params
						});
				$log->debug("Using: ".Dumper($requestParams));
				my $cacheKey = "$accessToken.$requestParams";
				if((time() - $cache{$cacheKey}->{'time'}) < CACHE_TIME) {
					$log->debug("Using cached items from: $serviceUrl");
					$cb->({items => $cache{$cacheKey}->{'data'}});
					return;
				}
				$log->info("Retriving items from: $serviceUrl");
				Slim::Networking::SimpleAsyncHTTP->new(
							sub {
								my $http = shift;
								my $jsonResponse = from_json($http->content);
								my @menus = ();
								if($jsonResponse->{'result'}) {
									foreach my $item (@{$jsonResponse->{'result'}->{'items'}}) {
										my $menu = {
											'name' => $item->{'text'},
											'passthrough' => [
												$serviceId,
												$contextId,
												{
													'type' => $item->{'type'},
													'id' => $item->{'id'},
													'parent' => $parent
												}
											]
										};
										if(defined($item->{'image'})) {
											$menu->{'image'} = $item->{'image'};
										}
										if($item->{'type'} ne 'track' && $item->{'type'} ne 'stream') {
											$menu->{'url'} = \&serviceItemMenu;
											if($item->{'type'} eq 'album') {
												$menu->{'type'} = 'playlist';
												if(defined($item->{'itemAttributes'}->{'mainArtists'}) && defined($item->{'itemAttributes'}->{'mainArtists'}[0]) && ($parent->{'type'} ne 'artist' || !defined($parent->{'id'}))) {
													$menu->{'line1'} = $item->{'text'};
													$menu->{'line2'} = $item->{'itemAttributes'}->{'mainArtists'}[0]->{'name'};						
												}elsif(defined($item->{'itemAttributes'}->{'year'})) {
													$menu->{'line1'} = $item->{'text'};
													$menu->{'line2'} = $item->{'itemAttributes'}->{'year'};						
												}
											}
										}else {
								        	Plugins::IckStreamPlugin::ItemCache::setItemInCache($item->{'id'},$item);
											$menu->{'play'} = 'ickstream://'.$item->{'id'};
											$menu->{'on_select'} => 'play';
											$menu->{'playall'} => 1;
											if(defined($item->{'itemAttributes'}->{'album'}) && defined($item->{'itemAttributes'}->{'mainArtists'}) && defined($item->{'itemAttributes'}->{'mainArtists'}[0]) && ($parent->{'type'} ne 'album' || !defined($parent->{'id'}))) {
												$menu->{'line1'} = $item->{'text'};
												$menu->{'line2'} = $item->{'itemAttributes'}->{'mainArtists'}[0]->{'name'}." - ".$item->{'itemAttributes'}->{'album'}->{'name'};
											}elsif(defined($item->{'itemAttributes'}->{'mainArtists'}) && defined($item->{'itemAttributes'}->{'mainArtists'}[0])) {
												$menu->{'line1'} = $item->{'text'};
												$menu->{'line2'} = $item->{'itemAttributes'}->{'mainArtists'}[0]->{'name'};
											}elsif(defined($item->{'itemAttributes'}->{'album'})) {
												$menu->{'line1'} = $item->{'text'};
												$menu->{'line2'} = $item->{'itemAttributes'}->{'album'}->{'name'};
											}
												
										}
										push @menus,$menu;
									}
									$log->debug("Got ".scalar(@menus)." items");
								}else {
									$log->warn("Error: ".Dumper($jsonResponse));
								}
								if(scalar(@menus)>0) {
									$cache{$cacheKey} = { 'data' => \@menus, 'time' => time()};
									$cb->({items => \@menus});
								}else {
									$cb->({items => [{
										name => cstring($client, 'PLUGIN_ICKSTREAM_BROWSE_NO_ITEMS'),
										type => 'textarea',
					                }]});
								}
							},
							sub {
								$log->info("Failed to retrieve content service items from cloud");
								$cb->(items => [{
									name => cstring($client, 'PLUGIN_ICKSTREAM_BROWSE_REQUIRES_CREDENTIALS'),
									type => 'textarea',
				                }]);
							},
							undef
						)->post($serviceUrl,'Content-Type' => 'application/json','Authorization'=>'Bearer '.$accessToken,$requestParams);					
		},
		sub {
			$log->info("Failed to retrieve content services from cloud");
			$cb->(items => [{
				name => cstring($client, 'PLUGIN_ICKSTREAM_BROWSE__REQUIRES_CREDENTIALS'),
				type => 'textarea',
               }]);
		});
	}
}

my $typePriorities = {
	'menu' => 1,
	'category' => 2,
	'artist' => 3,
	'album' => 4,
	'track' => 5,
};

sub compareTypes {
	my $type1 = shift;
	my $type2 = shift;
	
	return $typePriorities->{$type1} - $typePriorities->{$type2};
}

sub createChildRequestParametersFromContext {
	my $supportedRequests = shift;
	my $contextId = shift;
	my $type = shift;
	my $parent = shift;
	
	my $possibleRequests = findPossibleRequests($supportedRequests,$contextId,$type,$parent);
	my $supported = undef;
	my $supportedParameters = {};
	
	foreach my $possibleRequest (@{$possibleRequests}) {
		if(scalar(keys %$supportedParameters) == (scalar(keys %$possibleRequest) + 1) &&
			defined($supportedParameters->{'type'}) &&
			!defined($possibleRequest->{'type'})) {
				
			# If we can request without type we should do that
			$supportedParameters = $possibleRequest;
		}elsif((scalar(keys %$supportedParameters) + 1) == scalar(keys %$possibleRequest) &&
			!defined($supportedParameters->{'type'}) &&
			defined($possibleRequest->{'type'})) {
				
			# Keep the old one, if we can request without type we should do that
		}elsif(scalar(keys %$supportedParameters) < scalar(keys %$possibleRequest)) {
			
			# We should always prefer choices with more criterias
			$supportedParameters = $possibleRequest;
		}elsif(scalar(keys %$supportedParameters) == scalar(keys %$possibleRequest) &&
			compareTypes($supportedParameters,$possibleRequest) < 0) {
				
			# With equal preiority we should prefer items which show more items
			$supportedParameters = $possibleRequest;
		}elsif(scalar(keys %$supportedParameters) == scalar(keys %$possibleRequest) &&
			defined($parent) &&
			!defined($supportedParameters->{$parent->{'type'}.'Id'}) &&
			defined($possibleRequest->{$parent->{'type'}.'Id'})) {
				
			# With equal number of priority we should prefer items which filter by nearest parent
			$supportedParameters = $possibleRequest;
		}

	}
	
	if(scalar(keys %$supportedParameters)>0) {
		foreach my $supportedParameter (keys %$supportedParameters) {
			if(($supportedParameter ne 'contextId' && $supportedParameter ne 'type') || !defined($parent->{'id'})) {
				$supported = 1;
			}
		}
	}
	
	if($supported) {
		return $supportedParameters;
	}else {
		return undef;
	}
}

sub findPossibleRequests {
	my $supportedRequests = shift;
	my $contextId = shift;
	my $type = shift;
	my $parent = shift;
	
	my @possibleRequests = ();
	foreach my $request (@{$supportedRequests}) {
		if(!defined($type) || (defined($request->{'type'}) && $request->{'type'} eq $type)) {
			foreach my $parameters (@{$request->{'parameters'}}) {
				my $unsupported = undef;
				my $typeExists = undef;
				foreach my $parameter (@{$parameters}) {
					if($parameter ne 'contextId' && $parameter ne 'type' && (!defined($parent) || (defined($parent->{'id'}) && !getParameterFromParent($parameter,$parent)))) {
						$unsupported = 1;
					}
					if($parameter eq 'type') {
						$typeExists = 1;
					}
				}
				if(defined($type) && !$typeExists) {
					$unsupported = 1;
				}
				if(!$unsupported) {
					my $possibleParameters = {};
					foreach my $parameter (@{$parameters}) {
						if($parameter eq 'type') {
							$possibleParameters->{'type'} = (defined($type)?$type:$request->{'type'});
						}elsif($parameter eq 'contextId') {
							$possibleParameters->{'contextId'} = $contextId;
						}else {
							my $value = getParameterFromParent($parameter,$parent);
							if(defined($value)) {
								$possibleParameters->{$parameter} = $value;
							}else {
								$unsupported = 1;
							}
						}
					}
					if(!$unsupported) {
						push @possibleRequests,$possibleParameters;
					}
				}
					
			}
		}
	}
	return \@possibleRequests;
}

sub getParameterFromParent {
	my $parameter = shift;
	my $parent = shift;
	
	if(defined($parent->{'id'})) {
		if($parameter eq $parent->{'type'}.'Id') {
			return $parent->{'id'};
		}elsif(defined($parent->{'parent'})) {
			return getParameterFromParent($parameter,$parent->{'parent'});
		}
	}elsif(defined($parent->{'parent'})) {
		return getParameterFromParent($parameter,$parent->{'parent'});
	}
	return undef;
}

1;

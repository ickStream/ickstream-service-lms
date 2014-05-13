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

sub sliceResult {
	my $result = shift;
	my $args = shift;
	my $forcedOffset = shift;
	
	my $index = $forcedOffset;
	if(!defined($index)) {
		$index = getOffset($args);
	}
	my @resultItems = ();
	if(defined($args->{'quantity'}) && $args->{'quantity'} ne "") {
		$log->debug("Getting items $index..".$args->{'quantity'});
		@resultItems = @$result;
		@resultItems = splice @resultItems,$index,$args->{'quantity'};
	}else {
		$log->debug("Getting items $index..");
		@resultItems = @$result;
		@resultItems = splice @resultItems,$index;
	}
	return \@resultItems;
}

sub getOffset {
	my $args = shift;

	my $index = 0;
	if(defined($args->{'index'})) {
		$index = int($args->{'index'});
	}
	return $index;
}

sub init {
	my $accessToken = $prefs->get('accessToken');
	if(defined($accessToken)) {
		my $cloudCoreUrl = $prefs->get('cloudCoreUrl') || 'https://api.ickstream.com/ickstream-cloud-core/jsonrpc';
		my $requestParams = to_json({
					'jsonrpc' => '2.0',
					'id' => 1,
					'method' => 'findServices',
					'params' => {
						'type' => 'content'
					}
				});
		$log->info("Retrieve content services from cloud");
		Slim::Networking::SimpleAsyncHTTP->new(
			sub {
				my $http = shift;
				my $jsonResponse = from_json($http->content);
				$cloudServiceEntries = {};
				my @services = ();
				if($jsonResponse->{'result'} && $jsonResponse->{'result'}->{'items'}) {
					foreach my $service (@{$jsonResponse->{'result'}->{'items'}}) {
						if($jsonResponse->{'result'} && $jsonResponse->{'result'}->{'items'}) {
							foreach my $service (@{$jsonResponse->{'result'}->{'items'}}) {
								$cloudServiceEntries->{$service->{'id'}} = $service;
							}
						}
						getProtocolDescription(undef, $service->{'id'},
							sub {
								my $serviceId = shift;
								my $protocolDescription = shift;

								foreach my $context (@{$protocolDescription->{'items'}}) {
									my @searchTypes = ();
									foreach my $request (@{$context->{'supportedRequests'}}) {
										my $supported = undef;
										foreach my $parameters (@{$request->{'parameters'}}) {
											my $unsupported = undef;
											foreach my $parameter (@{$parameters}) {
												if($parameter ne 'contextId' && $parameter ne 'type' && $parameter ne 'search') {
													$unsupported = 1;
													last;
												}
											}
											if(!$unsupported && scalar(@{$parameters})==3) {
												$supported = 1;
												last;
											}
										}
										if($supported) {
											push @searchTypes, $request->{'type'};
										}
									}
									if(scalar(@searchTypes)>0) {
										$log->debug("Added search provider for: ".$service->{'name'}. " in ".$context->{'name'});
										Slim::Menu::GlobalSearch->registerInfoProvider( 'ickstream_'.$service->{'id'}."_".$context->{'contextId'} => (
								                func => sub {
								                	my ( $client, $tags ) = @_;
								                	return searchMenu($client,$tags,$service, $context->{'contextId'},\@searchTypes);
								                }
										) );
									}
								}
							},
							sub {
								$log->warn("Failed to retrieve content services from cloud");
							});
					}
				}else {
					$log->warn("Error: ".Dumper($jsonResponse));
				}
			},
			sub {
				my $http = shift;
				my $error = shift;
				$log->warn("Failed to retrieve content services from cloud: ".$error);
			},
			undef
		)->post($cloudCoreUrl,'Content-Type' => 'application/json','Authorization'=>'Bearer '.$accessToken,$requestParams);

	}
}

sub searchMenu {
	my $client = shift;
	my $tags = shift;
	my $service = shift;
	my $contextId = shift;
	my $searchTypes = shift;
	
	my @result = ();
	foreach my $type (@$searchTypes) {
		my $menu = {
			name => getNameForType(undef,$type),
			url => \&searchItemMenu,
			passthrough => [$service->{'id'},$contextId, $type,$tags->{search}]
		};
		push @result,$menu;
	}
	return {
		name => $service->{'name'}." via ickStream",
		items => \@result
	};
	
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
				my $playerConfiguration = $prefs->get('player_'.$client->id) || {};
				my $cloudCoreUrl = $playerConfiguration->{'cloudCoreUrl'} || 'http://api.ickstream.com/ickstream-cloud-core/jsonrpc';
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
					$log->debug("Using cached content services from cloud for: ".Dumper($args));
					my $items = $cache{$cacheKey}->{'data'};
					my $resultItems = sliceResult($items,$args);
					$log->debug("Returning: ".scalar(@$resultItems). " items");
					$cb->({items => $resultItems, offset => getOffset($args)});
					return;
				}
				$log->info("Retrieve content services from cloud using ".$cloudCoreUrl);
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
									#$cache{$cacheKey} = { 'data' => \@services, 'time' => time()};
									my $resultItems = sliceResult(\@services,$args);
									$log->debug("Returning: ".scalar(@$resultItems). " items");
									$cb->({items => $resultItems, offset => getOffset($args)});
								}else {
									$cb->({items => [{
										name => cstring($client, 'PLUGIN_ICKSTREAM_BROWSE_ADD_SERVICES'),
										type => 'textarea',
					                }]});
								}
							},
							sub {
								my $http = shift;
								my $error = shift;
								$log->warn("Failed to retrieve content services from cloud: ".$error);
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
		if(defined($client)) {
			$log->warn("Player ".$client->name()." isn't registered");
		}else {
			$log->warn("This LMS isn't registered");
		}
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
							$log->warn("Failed to retrieve protocol description for ".$serviceId.": ".Dumper($jsonResponse));
							&{$errorCb}($serviceId);
						}
					},
					sub {
						my $http = shift;
						my $error = shift;
						$log->warn("Failed to retrieve protocol description for ".$serviceId.": ".$error);
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
				my $searchItem = 0;
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
					
					foreach my $context (@{$protocolDescription->{'items'}}) {
						my @searchTypes = ();
						foreach my $request (@{$context->{'supportedRequests'}}) {
							foreach my $parameters (@{$request->{'parameters'}}) {
								my $unsupported = undef;
								foreach my $parameter (@{$parameters}) {
									if($parameter ne 'contextId' && $parameter ne 'type' && $parameter ne 'search') {
										$unsupported = 1;
										last;
									}
								}
								if(!$unsupported && scalar(@{$parameters})==3) {
									push @searchTypes, $request->{'type'};
									last;
								}
							}
						}
						if(scalar(@searchTypes)>0) {
							my $service = $cloudServiceEntries->{$serviceId};
							$log->debug("Creating search menu for: ".$service->{'name'});
							my $menu = {
								'name' => cstring($client, 'SEARCH'),
								'type' => 'search',
								'url' => sub {
									my ($client, $cb, $params) = @_;
									
									my $searchMenu = searchMenu($client, {
											search => lc($params->{search})
										},
										$cloudServiceEntries->{$serviceId},
										$context->{'contextId'},
										\@searchTypes);
									
									$cb->({
										items => $searchMenu->{items}
									});
								}
							};
							push @menus,$menu;
							$searchItem = 1;
						}
					}
				}
				if(scalar(@menus)>0) {
					if(scalar(@menus)==1 && !$searchItem) {
						serviceTypeMenu($client, $cb, $args, $serviceId, @menus[0]->{'passthrough'}[1]);
					}else {
						my $resultItems = sliceResult(\@menus,$args);
						$log->debug("Returning: ".scalar(@$resultItems). " items");
						$cb->({items => $resultItems, offset => getOffset($args)});
					}
				}else {
					$cb->({items => [{
						name => cstring($client, 'PLUGIN_ICKSTREAM_BROWSE_NO_ITEMS'),
						type => 'textarea',
	                }]});
				}
			},
			sub {
				$log->warn("Failed to retrieve content services from cloud");
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
	}elsif($type eq 'friend') {
		return 'Friends';
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
							foreach my $request (@{$context->{'supportedRequests'}}) {
								my $supported = undef;
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
					if(scalar(@menus)==1) {
						serviceItemMenu($client, $cb, $args, $serviceId, @menus[0]->{'passthrough'}[1], @menus[0]->{'passthrough'}[2]);
					}else {
						my $resultItems = sliceResult(\@menus,$args);
						$log->debug("Returning: ".scalar(@$resultItems). " items");
						$cb->({items => $resultItems, offset => getOffset($args)});
					}
				}else {
					$cb->({items => [{
						name => cstring($client, 'PLUGIN_ICKSTREAM_BROWSE_NO_ITEMS'),
						type => 'textarea',
	                }]});
				}
			},
			sub {
				$log->warn("Failed to retrieve content services from cloud");
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
								
				my $tmpParent = $parent;
				my @usedTypes = ();
				while(defined($tmpParent)) {
					if(defined($tmpParent->{'id'}) && defined($tmpParent->{'type'}) && $tmpParent->{'type'} ne 'menu' && $tmpParent->{'type'} ne 'category') {
						push @usedTypes, $tmpParent->{'type'};
					}
					if(defined($tmpParent->{'parent'})) {
						$tmpParent = $tmpParent->{'parent'};
					}else {
						$tmpParent = undef;
					}
				}


				my $serviceUrl = $cloudServiceEntries->{$serviceId}->{'url'};
				my $params = createChildRequestParameters($protocolDescription, $contextId,$parent->{'type'},$parent,\@usedTypes);
				if(defined($args->{'quantity'}) && $args->{'quantity'} ne "") {
					$params->{'count'} = int($args->{'quantity'});
				}
				if(defined($args->{'index'}) && $args->{'index'} ne "") {
					$params->{'offset'} = int($args->{'index'});
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
				my $cacheKey = "$accessToken.$serviceId.$requestParams";
				$log->debug("Check cache with key: ".$cacheKey);
				if((time() - $cache{$cacheKey}->{'time'}) < CACHE_TIME) {
					$log->debug("Using cached items from: $serviceUrl for: ".Dumper($args));
					my $resultItems = sliceResult($cache{$cacheKey}->{'data'},$args,0);
					if(defined($cache{$cacheKey}->{'total'})) {
						$log->debug("Returning: ".scalar(@$resultItems). " items of ".$cache{$cacheKey}->{'total'});
						$cb->({items => $resultItems, total => $cache{$cacheKey}->{'total'}, offset => getOffset($args)});
					}else {
						$log->debug("Returning: ".scalar(@$resultItems). " items");
						$cb->({items => $resultItems, offset => getOffset($args)});
					}
					return;
				}
				$log->info("Retriving items from: $serviceUrl");
				Slim::Networking::SimpleAsyncHTTP->new(
							sub {
								my $http = shift;
								my $jsonResponse = from_json($http->content);
								my @menus = ();
								my $totalItems = undef;
								if($jsonResponse->{'result'}) {
									if(defined($jsonResponse->{'result'}->{'countAll'})) {
										$totalItems =$jsonResponse->{'result'}->{'countAll'};
									}
									foreach my $item (@{$jsonResponse->{'result'}->{'items'}}) {
										my $menu = {
											'name' => $item->{'text'},
											'passthrough' => [
												$serviceId,
												$contextId,
												{
													'type' => $item->{'type'},
													'id' => $item->{'id'},
													'preferredChildItems' => $item->{'preferredChildItems'},
													'parent' => $parent
												}
											]
										};
										if(defined($item->{'image'})) {
											$menu->{'image'} = $item->{'image'};
										}
										if($item->{'type'} ne 'track' && $item->{'type'} ne 'stream') {
											$menu->{'url'} = \&serviceItemMenu;
											if($item->{'type'} eq 'album' || $item->{'type'} eq 'playlist') {
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
											$menu->{'type'} = 'audio';
											$menu->{'on_select'} = 'play';
											$menu->{'playall'} = 1;
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
									$log->debug("Store in cache with key: ".$cacheKey);
									if(defined($totalItems)) {
										$cache{$cacheKey} = { 'data' =>\@menus, 'total' => $totalItems, 'time' => time()};
									}else {
										$cache{$cacheKey} = { 'data' =>\@menus, 'time' => time()};
									}
									my $resultItems = sliceResult(\@menus,$args,0);
									if(defined($totalItems)) {
										$log->debug("Returning: ".scalar(@$resultItems). " items of ".$totalItems);
										$cb->({items => $resultItems, total => $totalItems, offset => getOffset($args)});
									}else {
										$log->debug("Returning: ".scalar(@$resultItems). " items");
										$cb->({items => $resultItems, offset => getOffset($args)});
									}
								}else {
									$cb->({items => [{
										name => cstring($client, 'PLUGIN_ICKSTREAM_BROWSE_NO_ITEMS'),
										type => 'textarea',
					                }]});
								}
							},
							sub {
								my $http = shift;
								my $error = shift;
								$log->warn("Failed to retrieve content service items from cloud: ".$error);
								$cb->(items => [{
									name => cstring($client, 'PLUGIN_ICKSTREAM_BROWSE_REQUIRES_CREDENTIALS'),
									type => 'textarea',
				                }]);
							},
							undef
						)->post($serviceUrl,'Content-Type' => 'application/json','Authorization'=>'Bearer '.$accessToken,$requestParams);					
		},
		sub {
			$log->warn("Failed to retrieve content services from cloud");
			$cb->(items => [{
				name => cstring($client, 'PLUGIN_ICKSTREAM_BROWSE__REQUIRES_CREDENTIALS'),
				type => 'textarea',
               }]);
		});
	}
}

sub searchItemMenu {
	my ($client, $cb, $args, $serviceId, $contextId, $type, $search) = @_;
	
	my $accessToken = getAccessToken($client);
	if(!defined($accessToken)) {
		$cb->({items => [{
                       name => cstring($client, 'PLUGIN_ICKSTREAM_BROWSE_REQUIRES_CREDENTIALS'),
                       type => 'textarea',
               }]});
	}else {
			my $serviceUrl = $cloudServiceEntries->{$serviceId}->{'url'};
			my $params = {
				'contextId' => $contextId,
				'type' => $type,
				'search' => $search
			};
			if(defined($args->{'quantity'}) && $args->{'quantity'} ne "") {
				$params->{'count'} = int($args->{'quantity'});
			}
			if(defined($args->{'index'}) && $args->{'index'} ne "") {
				$params->{'offset'} = int($args->{'index'});
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
			my $cacheKey = "$accessToken.$serviceId.$requestParams";
			$log->debug("Check cache with key: ".$cacheKey);
			if((time() - $cache{$cacheKey}->{'time'}) < CACHE_TIME) {
				$log->debug("Using cached items from: $serviceUrl for: ".Dumper($args));
				my $resultItems = sliceResult($cache{$cacheKey}->{'data'},$args,0);
				if(defined($cache{$cacheKey}->{'total'})) {
					$log->debug("Returning: ".scalar(@$resultItems). " items of ".$cache{$cacheKey}->{'total'});
					$cb->({items => $resultItems, total => $cache{$cacheKey}->{'total'}, offset => getOffset($args)});
				}else {
					$log->debug("Returning: ".scalar(@$resultItems). " items");
					$cb->({items => $resultItems, offset => getOffset($args)});
				}
				return;
			}
			$log->info("Search $type from: $serviceUrl");
			Slim::Networking::SimpleAsyncHTTP->new(
				sub {
					my $http = shift;
					my $jsonResponse = from_json($http->content);
					my @menus = ();
					my $totalItems = undef;
					if($jsonResponse->{'result'}) {
						if(defined($jsonResponse->{'result'}->{'countAll'})) {
							$totalItems =$jsonResponse->{'result'}->{'countAll'};
						}
						foreach my $item (@{$jsonResponse->{'result'}->{'items'}}) {
							my $menu = {
								'name' => $item->{'text'},
								'passthrough' => [
									$serviceId,
									$contextId,
									{
										'type' => $item->{'type'},
										'id' => $item->{'id'},
										'preferredChildItems' => $item->{'preferredChildItems'},
										'parent' => undef
									}
								]
							};
							if(defined($item->{'image'})) {
								$menu->{'image'} = $item->{'image'};
							}
							if($item->{'type'} ne 'track' && $item->{'type'} ne 'stream') {
								$menu->{'url'} = \&serviceItemMenu;
								if($item->{'type'} eq 'album' || $item->{'type'} eq 'playlist') {
									$menu->{'type'} = 'playlist';
									if(defined($item->{'itemAttributes'}->{'mainArtists'}) && defined($item->{'itemAttributes'}->{'mainArtists'}[0])) {
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
								$menu->{'type'} = 'audio';
								$menu->{'on_select'} => 'play';
								$menu->{'playall'} => 1;
								if(defined($item->{'itemAttributes'}->{'album'}) && defined($item->{'itemAttributes'}->{'mainArtists'}) && defined($item->{'itemAttributes'}->{'mainArtists'}[0])) {
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
						$log->debug("Store in cache with key: ".$cacheKey);
						if(defined($totalItems)) {
							$cache{$cacheKey} = { 'data' =>\@menus, 'total' => $totalItems, 'time' => time()};
						}else {
							$cache{$cacheKey} = { 'data' =>\@menus, 'time' => time()};
						}
						my $resultItems = sliceResult(\@menus,$args,0);
						if(defined($totalItems)) {
							$log->debug("Returning: ".scalar(@$resultItems). " items of ".$totalItems);
							$cb->({items => $resultItems, total => $totalItems, offset => getOffset($args)});
						}else {
							$log->debug("Returning: ".scalar(@$resultItems). " items");
							$cb->({items => $resultItems, offset => getOffset($args)});
						}
					}else {
						$cb->({items => [{
							name => cstring($client, 'PLUGIN_ICKSTREAM_BROWSE_NO_ITEMS'),
							type => 'textarea',
		                }]});
					}
				},
				sub {
					my $http = shift;
					my $error = shift;
					$log->warn("Failed to retrieve content service items from cloud: ".$error);
					$cb->(items => [{
						name => cstring($client, 'PLUGIN_ICKSTREAM_BROWSE_REQUIRES_CREDENTIALS'),
						type => 'textarea',
	                }]);
				},
				undef
			)->post($serviceUrl,'Content-Type' => 'application/json','Authorization'=>'Bearer '.$accessToken,$requestParams);					
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

sub createChildRequestParameters {
	my $protocolDescription = shift;
	my $contextId = shift;
	my $type = shift;
	my $parent = shift;
	my $excludedTypes = shift;
	
	
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

	my $params = undef;
	if(!defined($parent->{'id'}) && defined($parent->{'type'})) {
		$params = createChildRequestParametersFromContext($contextRequests, $contextId,$parent->{'type'},$parent,$excludedTypes);
		if(!defined($params) && $contextId ne 'allMusic') {
			$params = createChildRequestParametersFromContext($allMusicRequests, 'allMusic',$parent->{'type'},$parent,$excludedTypes);
		}
	}else {
		$params = createChildRequestParametersFromContext($contextRequests, $contextId,undef,$parent,$excludedTypes);
		if(!defined($params) && $contextId ne 'allMusic') {
			$params = createChildRequestParametersFromContext($allMusicRequests, 'allMusic',undef,$parent,$excludedTypes);
		}
	}
	return $params;

}

sub createChildRequestParametersFromContext {
	my $supportedRequests = shift;
	my $contextId = shift;
	my $type = shift;
	my $parent = shift;
	my $excludedTypes = shift;
	
	my $possibleRequests = findPossibleRequests($supportedRequests,$contextId,$type,$parent);
	my $supported = undef;
	my $supportedParameters = {};
	my $preferredSupportedParameters = {};
	foreach my $possibleRequest (@{$possibleRequests}) {
		if(defined($possibleRequest->{'type'}) && defined($excludedTypes) && grep(/^{$possibleRequest->{'type'}}$/,@$excludedTypes)) {
			# We aren't interested in excluded types
		}elsif(defined($parent) && defined($parent->{'id'}) && defined($parent->{'type'}) && (!defined($possibleRequest->{$parent->{'type'}.'Id'}) || $possibleRequest->{$parent->{'type'}.'Id'} ne $parent->{'id'})) {
			# We aren't interested in requests unless they filter by parent item
		}elsif(defined($parent) && !defined($parent->{'id'}) && (!defined($possibleRequest->{'type'}) || $possibleRequest->{'type'} ne $parent->{'type'})) {
			# We aren't interested in requests if parent item is filtered by type and the request type is different
		}elsif(scalar(keys %$supportedParameters) == (scalar(keys %$possibleRequest) + 1) &&
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
			if(defined($parent) && defined($parent->{'preferredChildItems'}) && scalar(@{$parent->{'preferredChildItems'}})>0 && $supportedParameters->{'type'} eq @{$parent->{'preferredChildItems'}}[0]) {
				$preferredSupportedParameters = $supportedParameters;
			}
		}elsif(scalar(keys %$supportedParameters) == scalar(keys %$possibleRequest) &&
			compareTypes($supportedParameters,$possibleRequest) < 0) {
				
			# With equal preiority we should prefer items which show more items
			$supportedParameters = $possibleRequest;
			if(defined($parent) && defined($parent->{'preferredChildItems'}) && scalar(@{$parent->{'preferredChildItems'}})>0 && $supportedParameters->{'type'} eq @{$parent->{'preferredChildItems'}}[0]) {
				$preferredSupportedParameters = $supportedParameters;
			}
		}elsif(scalar(keys %$supportedParameters) == scalar(keys %$possibleRequest) &&
			defined($parent) &&
			!defined($supportedParameters->{$parent->{'type'}.'Id'}) &&
			defined($possibleRequest->{$parent->{'type'}.'Id'})) {
				
			# With equal number of priority we should prefer items which filter by nearest parent
			$supportedParameters = $possibleRequest;
			if(defined($parent->{'preferredChildItems'}) && scalar(@{$parent->{'preferredChildItems'}})>0 && $supportedParameters->{'type'} eq @{$parent->{'preferredChildItems'}}[0]) {
				$preferredSupportedParameters = $supportedParameters;
			}
		}elsif(scalar(keys %$supportedParameters) == scalar(keys %$possibleRequest) &&
			defined($parent) &&
			defined($parent->{'preferredChildItems'}) &&
			scalar(@{$parent->{'preferredChildItems'}})>0 &&
			defined($possibleRequest->{'type'}) &&
			$possibleRequest->{'type'} eq @{$parent->{'preferredChildItems'}}[0]) {
				
			# With equal number of priority we should prefer items which filter by nearest parent
			$preferredSupportedParameters = $possibleRequest;
		}

	}
	if(scalar(keys %$preferredSupportedParameters)>0) {
		$supportedParameters = $preferredSupportedParameters;
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
